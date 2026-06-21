import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'package:xml/xml.dart';

import '../hls_ad_filter.dart';
import 'download_option.dart';

/// Downloads *adaptive* streams (HLS `.m3u8` / DASH `.mpd`) into a single local
/// file by fetching every media segment and concatenating them.
///
/// Adaptive streams aren't one file — they're a manifest plus many small
/// segments. To "download the video" we read the manifest, fetch each segment
/// in order (decrypting AES-128 HLS segments on the fly), and glue them back
/// together:
///   * HLS MPEG-TS segments  → one `.ts` file (TS concatenates natively)
///   * HLS / DASH fMP4 (with an init segment) → one `.mp4`
/// For HLS we reuse the SSAI ad-stripper so the saved file is ad-free too.
///
/// Limits (documented for honesty): DASH with *separate* audio and video
/// representations can't be remuxed into one container without ffmpeg, so for
/// such streams we save the highest-bitrate video representation (no audio).
/// Live manifests that rewrite themselves continuously aren't tracked.

/// True if [url] is an adaptive manifest this module assembles.
bool isAdaptiveStream(String url) {
  final u = url.toLowerCase();
  return u.contains('.m3u8') || u.contains('.mpd');
}

// ---------------------------------------------------------------------------
// Quality listing
// ---------------------------------------------------------------------------

/// Lists the selectable qualities of an adaptive manifest at [url] (HLS master
/// variants or DASH video representations). For a plain media playlist (no
/// variants) returns a single "원본" option.
Future<List<DownloadOption>> listAdaptiveQualities(
  String url, {
  http.Client? client,
}) async {
  final ownClient = client == null;
  final c = client ?? http.Client();
  try {
    final text = await _fetchText(c, url);
    if (url.toLowerCase().contains('.mpd')) {
      return parseDashQualities(text, Uri.parse(url), url);
    }
    if (text.contains('#EXT-X-STREAM-INF')) {
      return parseHlsVariants(text, Uri.parse(url));
    }
    // Already a media playlist — single quality.
    return [DownloadOption(label: '원본', url: url, adaptive: true)];
  } finally {
    if (ownClient) c.close();
  }
}

/// Parses an HLS *master* playlist into one [DownloadOption] per variant,
/// highest resolution first, de-duplicated by resolution (keeping the highest
/// bitrate for each).
List<DownloadOption> parseHlsVariants(String master, Uri base) {
  final lines = master.split(RegExp(r'\r?\n'));
  final byLabel = <String, DownloadOption>{};
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
    final res = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
    final bwM = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
    final height = res != null ? int.parse(res.group(2)!) : null;
    final bandwidth = bwM != null ? int.parse(bwM.group(1)!) : null;
    for (var j = i + 1; j < lines.length; j++) {
      final cand = lines[j].trim();
      if (cand.isEmpty || cand.startsWith('#')) continue;
      final label = height != null
          ? '${height}p'
          : (bandwidth != null ? '${(bandwidth / 1000).round()} kbps' : '원본');
      final opt = DownloadOption(
        label: label,
        url: base.resolve(cand).toString(),
        adaptive: true,
        height: height,
        bandwidth: bandwidth,
      );
      final existing = byLabel[label];
      if (existing == null || (bandwidth ?? 0) > (existing.bandwidth ?? 0)) {
        byLabel[label] = opt;
      }
      break;
    }
  }
  final out = byLabel.values.toList()
    ..sort((a, b) =>
        (b.height ?? b.bandwidth ?? 0).compareTo(a.height ?? a.bandwidth ?? 0));
  return out;
}

/// Parses a DASH manifest into one [DownloadOption] per video representation,
/// each carrying its bandwidth so the downloader can fetch that exact quality.
List<DownloadOption> parseDashQualities(String mpdXml, Uri base, String mpdUrl) {
  final root = XmlDocument.parse(mpdXml).rootElement;
  final period = _first(root.findElements('Period'));
  if (period == null) return const [];
  final byLabel = <String, DownloadOption>{};
  for (final aset in period.findElements('AdaptationSet')) {
    if (!_isVideoAdaptation(aset)) continue;
    final setHeight = int.tryParse(aset.getAttribute('maxHeight') ?? '');
    for (final rep in aset.findElements('Representation')) {
      final bw = int.tryParse(rep.getAttribute('bandwidth') ?? '');
      if (bw == null) continue;
      final height = int.tryParse(rep.getAttribute('height') ?? '') ?? setHeight;
      final label = height != null ? '${height}p' : '${(bw / 1000).round()} kbps';
      final opt = DownloadOption(
        label: label,
        url: mpdUrl,
        adaptive: true,
        height: height,
        bandwidth: bw,
        dashBandwidth: bw,
      );
      final existing = byLabel[label];
      if (existing == null || bw > (existing.bandwidth ?? 0)) byLabel[label] = opt;
    }
  }
  final out = byLabel.values.toList()
    ..sort((a, b) => (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0));
  return out;
}

// ---------------------------------------------------------------------------
// Public orchestrator
// ---------------------------------------------------------------------------

/// Downloads the adaptive stream at [url] into [savePath], returning the path
/// actually written (its extension is corrected to `.ts`/`.mp4` to match the
/// segment container). [onProgress] reports completed vs. total segment count.
Future<String> downloadAdaptiveStream(
  String url,
  String savePath, {
  void Function(int done, int total)? onProgress,
  http.Client? client,
  bool stripAds = true,
  int? dashBandwidth,
}) async {
  final ownClient = client == null;
  final c = client ?? http.Client();
  try {
    if (url.toLowerCase().contains('.mpd')) {
      return await _downloadDash(url, savePath, c, onProgress, dashBandwidth);
    }
    return await _downloadHls(url, savePath, c, onProgress, stripAds);
  } finally {
    if (ownClient) c.close();
  }
}

Future<String> _downloadHls(
  String url,
  String savePath,
  http.Client c,
  void Function(int, int)? onProgress,
  bool stripAds,
) async {
  var mediaUrl = url;
  var text = await _fetchText(c, mediaUrl);

  // Master playlist → pick the best variant's media playlist.
  if (text.contains('#EXT-X-STREAM-INF')) {
    final variant = selectVariant(text, Uri.parse(mediaUrl));
    if (variant == null) throw const HttpException('No HLS variant found');
    mediaUrl = variant;
    text = await _fetchText(c, mediaUrl);
  }

  final base = Uri.parse(mediaUrl);
  if (stripAds) {
    final cleaned = stripHlsAdsFromMediaPlaylist(text, base);
    if (cleaned != null) text = cleaned; // already absolutized
  }

  final plan = parseHlsMediaPlaylist(text, base);
  if (plan.segments.isEmpty) throw const HttpException('No HLS segments found');

  final outPath = _withExtension(savePath, plan.isFmp4 ? 'mp4' : 'ts');
  final sink = File(outPath).openWrite();
  final total = plan.segments.length + (plan.initUri != null ? 1 : 0);
  var done = 0;
  final keyCache = <String, Uint8List>{};

  try {
    if (plan.initUri != null) {
      sink.add(await _fetchBytes(c, plan.initUri.toString()));
      onProgress?.call(++done, total);
    }
    for (final seg in plan.segments) {
      var bytes = await _fetchBytes(c, seg.uri.toString());
      final key = seg.key;
      if (key != null && key.method == 'AES-128' && key.uri != null) {
        final keyBytes = keyCache[key.uri.toString()] ??=
            await _fetchBytes(c, key.uri.toString());
        final iv = key.iv ?? ivFromSequence(seg.seq);
        bytes = aes128CbcDecrypt(bytes, keyBytes, iv);
      }
      sink.add(bytes);
      onProgress?.call(++done, total);
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
  return outPath;
}

Future<String> _downloadDash(
  String url,
  String savePath,
  http.Client c,
  void Function(int, int)? onProgress,
  int? preferBandwidth,
) async {
  final text = await _fetchText(c, url);
  final plan =
      parseDashManifest(text, Uri.parse(url), preferBandwidth: preferBandwidth);
  if (plan.segments.isEmpty) throw const HttpException('No DASH segments found');

  final outPath = _withExtension(savePath, 'mp4');
  final sink = File(outPath).openWrite();
  final total = plan.segments.length + (plan.initUri != null ? 1 : 0);
  var done = 0;
  try {
    if (plan.initUri != null) {
      sink.add(await _fetchBytes(c, plan.initUri.toString()));
      onProgress?.call(++done, total);
    }
    for (final seg in plan.segments) {
      sink.add(await _fetchBytes(c, seg.toString()));
      onProgress?.call(++done, total);
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
  return outPath;
}

// ---------------------------------------------------------------------------
// HLS parsing (pure)
// ---------------------------------------------------------------------------

/// One HLS media segment plus the key (if any) needed to decrypt it.
class HlsSegment {
  HlsSegment(this.uri, this.key, this.seq);
  final Uri uri;
  final HlsKey? key;

  /// Media sequence number — the IV for AES-128 when none is given explicitly.
  final int seq;
}

/// An `#EXT-X-KEY` declaration.
class HlsKey {
  HlsKey(this.method, this.uri, this.iv);
  final String method; // AES-128, SAMPLE-AES, NONE…
  final Uri? uri;
  final Uint8List? iv;
}

/// The assembled download plan for an HLS media playlist.
class HlsPlan {
  HlsPlan(this.initUri, this.segments, this.isFmp4);
  final Uri? initUri;
  final List<HlsSegment> segments;
  final bool isFmp4;
}

/// Parses an HLS *media* playlist into a [HlsPlan]: its init segment (fMP4),
/// every media segment, and the encryption key in force for each.
HlsPlan parseHlsMediaPlaylist(String playlist, Uri base) {
  final lines = playlist.split(RegExp(r'\r?\n'));
  var seq = 0;
  HlsKey? currentKey;
  Uri? initUri;
  final segments = <HlsSegment>[];

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
      seq = int.tryParse(line.substring(line.indexOf(':') + 1).trim()) ?? 0;
    } else if (line.startsWith('#EXT-X-KEY:')) {
      currentKey = _parseKey(line.substring(line.indexOf(':') + 1), base);
    } else if (line.startsWith('#EXT-X-MAP:')) {
      final attrs = _parseAttributes(line.substring(line.indexOf(':') + 1));
      final uri = attrs['URI'];
      if (uri != null) initUri = base.resolve(uri);
    } else if (!line.startsWith('#')) {
      segments.add(HlsSegment(base.resolve(line), currentKey, seq));
      seq++;
    }
  }

  return HlsPlan(initUri, segments, initUri != null);
}

HlsKey _parseKey(String attrText, Uri base) {
  final attrs = _parseAttributes(attrText);
  final method = (attrs['METHOD'] ?? 'NONE').toUpperCase();
  final uri = attrs['URI'];
  final ivStr = attrs['IV'];
  return HlsKey(
    method,
    uri != null ? base.resolve(uri) : null,
    ivStr != null ? hexToBytes(ivStr) : null,
  );
}

/// Parses an attribute list like `METHOD=AES-128,URI="k",IV=0x00…` into a map.
Map<String, String> _parseAttributes(String s) {
  final map = <String, String>{};
  final re = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');
  for (final m in re.allMatches(s)) {
    var v = m.group(2)!;
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    map[m.group(1)!] = v;
  }
  return map;
}

// ---------------------------------------------------------------------------
// DASH parsing (pure)
// ---------------------------------------------------------------------------

/// The assembled download plan for a DASH manifest.
class DashPlan {
  DashPlan(this.initUri, this.segments);
  final Uri? initUri;
  final List<Uri> segments;
}

/// Parses a DASH `.mpd` manifest, selecting a video representation and
/// resolving its initialization + media segment URLs.
///
/// By default the highest-bitrate video representation is chosen; pass
/// [preferBandwidth] to download a specific quality (matched by @bandwidth),
/// falling back to the best if no representation matches.
DashPlan parseDashManifest(String mpdXml, Uri base, {int? preferBandwidth}) {
  final mpd = XmlDocument.parse(mpdXml).rootElement;
  var b = _applyBaseUrl(mpd, base);

  final period = _first(mpd.findElements('Period'));
  if (period == null) return DashPlan(null, const []);
  b = _applyBaseUrl(period, b);

  // Pick the requested (or highest-bandwidth) video representation.
  XmlElement? bestSet;
  XmlElement? bestRep;
  var bestBw = -1;
  for (final aset in period.findElements('AdaptationSet')) {
    if (!_isVideoAdaptation(aset)) continue;
    for (final rep in aset.findElements('Representation')) {
      final bw = int.tryParse(rep.getAttribute('bandwidth') ?? '') ?? 0;
      if (preferBandwidth != null && bw == preferBandwidth) {
        bestSet = aset;
        bestRep = rep;
        bestBw = bw;
        break;
      }
      if (bw > bestBw) {
        bestBw = bw;
        bestRep = rep;
        bestSet = aset;
      }
    }
    if (preferBandwidth != null && bestBw == preferBandwidth) break;
  }
  if (bestRep == null || bestSet == null) return DashPlan(null, const []);

  var rb = _applyBaseUrl(bestSet, b);
  rb = _applyBaseUrl(bestRep, rb);
  final repId = bestRep.getAttribute('id') ?? '';
  final bw = bestRep.getAttribute('bandwidth') ?? '';

  final template = _first(bestRep.findElements('SegmentTemplate')) ??
      _first(bestSet.findElements('SegmentTemplate'));
  if (template != null) {
    return _planFromTemplate(template, rb, repId, bw, mpd);
  }

  final list = _first(bestRep.findElements('SegmentList')) ??
      _first(bestSet.findElements('SegmentList'));
  if (list != null) {
    final initEl = _first(list.findElements('Initialization'));
    final init = initEl?.getAttribute('sourceURL');
    final segs = list
        .findElements('SegmentURL')
        .map((e) => e.getAttribute('media'))
        .whereType<String>()
        .map(rb.resolve)
        .toList();
    return DashPlan(init != null ? rb.resolve(init) : null, segs);
  }

  // SegmentBase or a plain BaseURL: the representation is a single file.
  return DashPlan(null, [rb]);
}

DashPlan _planFromTemplate(
  XmlElement st,
  Uri base,
  String repId,
  String bw,
  XmlElement mpd,
) {
  final media = st.getAttribute('media');
  if (media == null) return DashPlan(null, const []);
  final initTmpl = st.getAttribute('initialization');
  final startNumber = int.tryParse(st.getAttribute('startNumber') ?? '1') ?? 1;
  final timeline = _first(st.findElements('SegmentTimeline'));

  final init = initTmpl != null
      ? base.resolve(_fillTemplate(initTmpl, repId: repId, bandwidth: bw))
      : null;

  final segs = <Uri>[];
  if (timeline != null) {
    var number = startNumber;
    var time = 0;
    for (final s in timeline.findElements('S')) {
      final t = int.tryParse(s.getAttribute('t') ?? '');
      if (t != null) time = t;
      final d = int.tryParse(s.getAttribute('d') ?? '');
      if (d == null) continue;
      final r = int.tryParse(s.getAttribute('r') ?? '0') ?? 0;
      for (var i = 0; i <= r; i++) {
        segs.add(base.resolve(_fillTemplate(media,
            repId: repId, bandwidth: bw, number: number, time: time)));
        number++;
        time += d;
      }
    }
  } else {
    final duration = int.tryParse(st.getAttribute('duration') ?? '');
    final timescale = int.tryParse(st.getAttribute('timescale') ?? '1') ?? 1;
    final total = _mpdDurationSeconds(mpd.getAttribute('mediaPresentationDuration'));
    if (duration != null && duration > 0 && total != null) {
      final segDur = duration / timescale;
      final count = (total / segDur).ceil();
      for (var i = 0; i < count; i++) {
        segs.add(base.resolve(_fillTemplate(media,
            repId: repId,
            bandwidth: bw,
            number: startNumber + i,
            time: duration * i)));
      }
    }
  }
  return DashPlan(init, segs);
}

/// Substitutes `$RepresentationID$`, `$Bandwidth$`, `$Number$` (with optional
/// `%0Nd` padding) and `$Time$` placeholders in a DASH template.
String _fillTemplate(
  String tmpl, {
  required String repId,
  required String bandwidth,
  int? number,
  int? time,
}) {
  return tmpl.replaceAllMapped(RegExp(r'\$(\$|RepresentationID|Bandwidth|Number|Time)(%0\d+d)?\$'),
      (m) {
    final token = m.group(1)!;
    final fmt = m.group(2);
    String value;
    switch (token) {
      case r'$':
        return r'$';
      case 'RepresentationID':
        value = repId;
        break;
      case 'Bandwidth':
        value = bandwidth;
        break;
      case 'Number':
        value = (number ?? 0).toString();
        break;
      case 'Time':
        value = (time ?? 0).toString();
        break;
      default:
        value = '';
    }
    if (fmt != null) {
      final width = int.tryParse(RegExp(r'%0(\d+)d').firstMatch(fmt)!.group(1)!) ?? 0;
      value = value.padLeft(width, '0');
    }
    return value;
  });
}

bool _isVideoAdaptation(XmlElement aset) {
  final ct = aset.getAttribute('contentType')?.toLowerCase();
  if (ct != null) return ct == 'video';
  final mime = aset.getAttribute('mimeType')?.toLowerCase() ?? '';
  if (mime.startsWith('video')) return true;
  // No type hints: treat a set that has width/height (or video reps) as video.
  if (aset.getAttribute('maxWidth') != null) return true;
  return aset
      .findElements('Representation')
      .any((r) => (r.getAttribute('mimeType')?.toLowerCase() ?? '').startsWith('video') ||
          r.getAttribute('width') != null);
}

Uri _applyBaseUrl(XmlElement el, Uri current) {
  final bu = _first(el.findElements('BaseURL'))?.innerText.trim();
  if (bu != null && bu.isNotEmpty) return current.resolve(bu);
  return current;
}

/// Parses an ISO-8601 duration (`PT1H2M3.5S`) into seconds, or null.
double? _mpdDurationSeconds(String? iso) {
  if (iso == null) return null;
  final m = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?').firstMatch(iso);
  if (m == null) return null;
  final h = double.tryParse(m.group(1) ?? '0') ?? 0;
  final min = double.tryParse(m.group(2) ?? '0') ?? 0;
  final s = double.tryParse(m.group(3) ?? '0') ?? 0;
  return h * 3600 + min * 60 + s;
}

XmlElement? _first(Iterable<XmlElement> it) => it.isEmpty ? null : it.first;

// ---------------------------------------------------------------------------
// Crypto / helpers
// ---------------------------------------------------------------------------

/// Decrypts AES-128-CBC HLS segment [data] with [key] and [iv], stripping the
/// PKCS#7 padding HLS applies.
Uint8List aes128CbcDecrypt(Uint8List data, Uint8List key, Uint8List iv) {
  if (data.isEmpty || data.length % 16 != 0) return data;
  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(data.length);
  for (var off = 0; off < data.length; off += 16) {
    cipher.processBlock(data, off, out, off);
  }
  final pad = out.last;
  if (pad >= 1 && pad <= 16 && pad <= out.length) {
    return Uint8List.sublistView(out, 0, out.length - pad);
  }
  return out;
}

/// The 16-byte big-endian IV HLS derives from a segment's media sequence number
/// when `#EXT-X-KEY` carries no explicit IV.
Uint8List ivFromSequence(int seq) {
  final iv = Uint8List(16);
  var v = seq;
  for (var i = 15; i >= 0 && v != 0; i--) {
    iv[i] = v & 0xff;
    v >>= 8;
  }
  return iv;
}

/// Decodes a hex string (optionally `0x`-prefixed) to bytes.
Uint8List hexToBytes(String hex) {
  var h = hex.trim();
  if (h.startsWith('0x') || h.startsWith('0X')) h = h.substring(2);
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Replaces (or appends) the file extension of [path] with [ext].
String _withExtension(String path, String ext) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  final dot = path.lastIndexOf('.');
  if (dot > slash && dot >= 0) return '${path.substring(0, dot)}.$ext';
  return '$path.$ext';
}

Future<String> _fetchText(http.Client c, String url) async {
  final resp = await c.get(Uri.parse(url), headers: _headers);
  if (resp.statusCode != 200) {
    throw HttpException('HTTP ${resp.statusCode} for $url');
  }
  return resp.body;
}

Future<Uint8List> _fetchBytes(http.Client c, String url) async {
  final resp = await c.get(Uri.parse(url), headers: _headers);
  if (resp.statusCode != 200 && resp.statusCode != 206) {
    throw HttpException('HTTP ${resp.statusCode} for $url');
  }
  return resp.bodyBytes;
}

const _headers = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
};
