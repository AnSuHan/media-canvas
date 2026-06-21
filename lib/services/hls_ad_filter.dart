import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Strips *server-stitched* ads (SSAI) out of an HLS stream.
///
/// The problem
/// -----------
/// Some platforms don't serve ads as a separate file — they splice ad segments
/// directly into the same `.m3u8` timeline as the real video (Server-Side Ad
/// Insertion). Because the bytes are part of the one stream, dropping the page
/// (our other ad defence) can't remove them: the player would just play the ad
/// then the show.
///
/// The fix
/// -------
/// SSAI streams are honest about where the ads are — they fence each ad break
/// with SCTE-35 markers in the playlist (`#EXT-X-CUE-OUT` … `#EXT-X-CUE-IN`, or
/// `#EXT-X-DATERANGE` carrying `SCTE35-OUT`/`SCTE35-IN`). We download the
/// playlist, delete every segment that falls inside an ad break, absolutize the
/// remaining segment URLs, and hand libmpv a rewritten local playlist. The
/// player never sees the ad segments, so the ad is skipped and the video plays
/// straight through.
///
/// This works for VOD HLS (the common case). Live SSAI re-writes its playlist
/// continuously, which a one-shot rewrite can't track; there we leave the
/// stream untouched and just play it.

/// Writes a rewritten playlist somewhere libmpv can open it, returning a URI.
/// Injectable so the rewrite logic can be tested without touching disk.
typedef PlaylistWriter = Future<String> Function(String contents, String name);

/// If [m3u8Url] is an HLS playlist containing ad markers, returns a `file://`
/// URI to an ad-free rewritten playlist. Returns null when the stream isn't
/// HLS, has no ads to strip, or anything goes wrong (caller then plays the
/// original URL unchanged).
Future<String?> filterHlsAds(
  String m3u8Url, {
  http.Client? client,
  PlaylistWriter? writer,
}) async {
  if (!_looksLikeHls(m3u8Url)) return null;

  final ownClient = client == null;
  final c = client ?? http.Client();
  try {
    var url = m3u8Url;
    var text = await _fetch(c, url);
    if (text == null) return null;

    // A master playlist points at per-bitrate media playlists; pick one and
    // fetch the actual segment list, since ad markers live there.
    if (_isMaster(text)) {
      final variant = selectVariant(text, Uri.parse(url));
      if (variant == null) return null;
      url = variant;
      text = await _fetch(c, url);
      if (text == null) return null;
    }

    final cleaned = stripHlsAdsFromMediaPlaylist(text, Uri.parse(url));
    if (cleaned == null) return null; // No ad markers → nothing to do.

    final write = writer ?? _defaultWriter;
    return await write(cleaned, 'mc_hls_${url.hashCode.toUnsigned(32)}.m3u8');
  } catch (_) {
    return null;
  } finally {
    if (ownClient) c.close();
  }
}

Future<String?> _fetch(http.Client c, String url) async {
  final resp = await c.get(Uri.parse(url), headers: const {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
  });
  if (resp.statusCode != 200) return null;
  return resp.body;
}

bool _looksLikeHls(String url) {
  final u = url.toLowerCase();
  return u.contains('.m3u8');
}

bool _isMaster(String playlist) => playlist.contains('#EXT-X-STREAM-INF');

/// Picks the highest-bandwidth variant from a master playlist and returns its
/// absolute URL, or null if none found.
String? selectVariant(String master, Uri base) {
  final lines = master.split(RegExp(r'\r?\n'));
  int bestBandwidth = -1;
  String? bestUri;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
    final bw = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
    final bandwidth = bw != null ? int.parse(bw.group(1)!) : 0;
    // The URI is on the next non-comment line.
    for (var j = i + 1; j < lines.length; j++) {
      final cand = lines[j].trim();
      if (cand.isEmpty || cand.startsWith('#')) continue;
      if (bandwidth > bestBandwidth) {
        bestBandwidth = bandwidth;
        bestUri = cand;
      }
      break;
    }
  }
  if (bestUri == null) return null;
  return base.resolve(bestUri).toString();
}

/// Rewrites an HLS *media* playlist, removing every segment inside an ad break,
/// and making all segment / key / map URIs absolute against [base].
///
/// Returns the rewritten playlist, or null if the playlist contains no ad
/// markers at all (so the caller can skip rewriting entirely).
String? stripHlsAdsFromMediaPlaylist(String playlist, Uri base) {
  final lines = playlist.split(RegExp(r'\r?\n'));
  if (!_hasAdMarkers(lines)) return null;

  final out = <String>[];
  var inAd = false;
  // After an ad break we must signal a decode discontinuity before the next
  // content segment (the encoder params changed across the splice).
  var needDiscontinuity = false;

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (_isAdStart(line)) {
      inAd = true;
      continue; // drop the marker itself
    }
    if (_isAdEnd(line)) {
      inAd = false;
      needDiscontinuity = true;
      continue; // drop the marker itself
    }

    if (inAd) {
      // Drop everything that belongs to the ad: its EXTINF, byterange,
      // discontinuity, key changes, and the segment URI lines.
      continue;
    }

    // CUE-OUT-CONT appears mid-ad on some live carries; if we ever see it
    // outside a detected break, treat as ad too.
    if (line.startsWith('#EXT-X-CUE-OUT-CONT')) {
      inAd = true;
      continue;
    }

    // Content line we keep.
    if (line.startsWith('#EXTINF') && needDiscontinuity) {
      out.add('#EXT-X-DISCONTINUITY');
      needDiscontinuity = false;
    }

    if (line.startsWith('#')) {
      out.add(_absolutizeTagUri(line, base));
    } else {
      // A segment URI.
      out.add(base.resolve(line).toString());
    }
  }

  return '${out.join('\n')}\n';
}

bool _hasAdMarkers(List<String> lines) {
  for (final raw in lines) {
    final l = raw.trim();
    if (l.startsWith('#EXT-X-CUE-OUT') ||
        l.startsWith('#EXT-X-CUE-IN') ||
        (l.startsWith('#EXT-X-DATERANGE') &&
            (l.contains('SCTE35-OUT') ||
                l.contains('SCTE35-IN') ||
                l.toUpperCase().contains('CLASS="AD') ||
                l.toLowerCase().contains('ad-')))) {
      return true;
    }
  }
  return false;
}

bool _isAdStart(String line) {
  if (line.startsWith('#EXT-X-CUE-OUT') &&
      !line.startsWith('#EXT-X-CUE-OUT-CONT')) {
    return true;
  }
  if (line.startsWith('#EXT-X-DATERANGE') && line.contains('SCTE35-OUT')) {
    return true;
  }
  return false;
}

bool _isAdEnd(String line) {
  if (line.startsWith('#EXT-X-CUE-IN')) return true;
  if (line.startsWith('#EXT-X-DATERANGE') && line.contains('SCTE35-IN')) {
    return true;
  }
  return false;
}

/// Absolutizes a `URI="..."` attribute inside tags that carry one
/// (`#EXT-X-KEY`, `#EXT-X-MAP`); other tags pass through unchanged.
String _absolutizeTagUri(String line, Uri base) {
  if (!line.contains('URI="')) return line;
  return line.replaceAllMapped(RegExp(r'URI="([^"]*)"'), (m) {
    final abs = base.resolve(m.group(1)!).toString();
    return 'URI="$abs"';
  });
}

/// Default writer: drops the rewritten playlist in the system temp dir and
/// returns a `file://` URI libmpv can open.
Future<String> _defaultWriter(String contents, String name) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsString(contents);
  return file.uri.toString();
}
