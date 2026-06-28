import 'package:http/http.dart' as http;

import '../models/media_item.dart' show MediaKind;
import 'app_log.dart';
import 'ytdlp.dart';
import 'youtube_resolver.dart';

// Re-export so callers that only need the YouTube check can import this one file.
export 'youtube_resolver.dart' show isYouTubeUrl;

/// Resolves *any* page or media link into a direct, playable stream URL that
/// libmpv (media_kit) can open — not just YouTube.
///
/// Why this exists
/// ---------------
/// media_kit plays a *direct* media stream (mp4 / webm / m3u8 / mpd …). Most
/// "video links" people paste are HTML pages (a YouTube watch page, a Vimeo
/// page, a news article with one embedded clip, …), not a raw stream. This
/// module turns such a page into the underlying stream URL.
///
/// Ad blocking, for free
/// ---------------------
/// Because we hand libmpv the *direct stream* and never load the publisher's
/// HTML/JS in a webview, none of the page's ad machinery runs: no pre-roll
/// overlay, no banner, no pop-up, no auto-playing ad iframe. For YouTube the
/// resolved stream is the clean video with no ad segments. So "resolve to the
/// direct stream" *is* the ad blocker for the overwhelming majority of links.
/// We also actively drop any candidate URL that points at a known ad/tracker
/// host (see [_adHostFragments]) so a stitched ad asset is never picked.

/// File extensions we treat as a directly-playable media stream.
const _mediaExtensions = {
  'mp4', 'm4v', 'webm', 'mkv', 'mov', 'avi', 'flv', 'ts', 'ogv', 'mpg', 'mpeg',
  'm3u8', // HLS playlist
  'mpd', // DASH manifest
};

/// File extensions we treat as a still image (rendered as an image, not fed to
/// the video engine). `gif` is handled separately so it maps to [MediaKind.gif].
const _imageExtensions = {
  'jpg', 'jpeg', 'png', 'webp', 'bmp', 'svg', 'avif', 'heic', 'heif', 'tiff',
};

/// Browser-like headers so pages serve their real markup / the right media.
const _browserHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
};

/// Substrings that mark a URL as an ad / tracker / analytics asset. Any
/// candidate stream whose URL contains one of these is discarded so an ad is
/// never chosen as "the video".
const _adHostFragments = [
  'doubleclick.net',
  'googlesyndication.com',
  'googleadservices.com',
  'google-analytics.com',
  'googletagmanager.com',
  'googletagservices.com',
  '/pagead/',
  'adservice.',
  'ad.doubleclick',
  'imasdk.googleapis.com', // IMA ad SDK
  'innovid.com',
  'adsafeprotected.com',
  'moatads.com',
  'scorecardresearch.com',
  'amazon-adsystem.com',
  'adnxs.com',
  'serving-sys.com',
  '/vast', // VAST ad tag endpoints
  '/vmap',
];

/// Resolves [original] to a direct, playable stream URL.
///
/// Strategy, in order:
///   1. YouTube link  → resolve via youtube_explode (ad-free direct stream).
///   2. Already a direct media URL (ends in a media extension) → use as-is.
///   3. Otherwise it's a web page → fetch the HTML and extract the embedded
///      video's stream URL. If the page contains exactly one video, that one
///      is returned; if it has several, the best progressive stream is picked.
///
/// On any failure it falls back to handing the raw URL straight to libmpv,
/// which can still open many direct links on its own.
Future<String> resolvePlayableUrl(String original) async {
  final url = original.trim();
  if (url.isEmpty) return url;

  if (isYouTubeUrl(url)) {
    return resolveYouTube(url);
  }
  if (_isDirectMediaUrl(url)) {
    return url;
  }

  try {
    final extracted = await extractVideoFromPage(url);
    if (extracted != null) return extracted;
  } catch (_) {
    // Fall through to yt-dlp / the raw URL.
  }

  // The built-in scraper found nothing — most likely a JS-driven site (X,
  // TikTok, Facebook, Vimeo, …). Let the bundled yt-dlp extract the direct
  // stream; it supports ~1800 sites. No-op when yt-dlp isn't bundled (tests).
  final viaYtDlp = await ytDlpResolveStream(url);
  if (viaYtDlp != null) return viaYtDlp;

  return url;
}

/// All distinct, non-ad stream URLs (m3u8 / mpd / mp4 / …) embedded in [html],
/// best-source first. Public wrapper around the internal extractor so the
/// page-info resolver ([resolveVideoSource]) can reuse the exact same scraping
/// rules the player uses.
List<String> extractStreamCandidates(String html, {required Uri base}) =>
    _extractCandidates(html, base: base);

/// The absolute `content` of the first matching `<meta>` tag among [props]
/// (e.g. `og:image`), resolved to an absolute URL, or null. Use for *URL*-typed
/// meta (thumbnails); for free text (a title) use [extractMetaText].
String? extractMetaContent(String html, List<String> props, {required Uri base}) =>
    _firstMetaContent(html, props, base: base);

/// The raw, unescaped text of the first matching `<meta>` tag among [props]
/// (e.g. `og:title`), or null — *without* resolving it as a URL, so a plain
/// title isn't mangled into `https://…/A%20Title`.
String? extractMetaText(String html, List<String> props) {
  for (final prop in props) {
    final p = RegExp.escape(prop);
    for (final re in [
      RegExp(
        '<meta[^>]*?(?:property|name)\\s*=\\s*["\']$p["\'][^>]*?content\\s*=\\s*["\']([^"\']*)["\']',
        caseSensitive: false,
      ),
      RegExp(
        '<meta[^>]*?content\\s*=\\s*["\']([^"\']*)["\'][^>]*?(?:property|name)\\s*=\\s*["\']$p["\']',
        caseSensitive: false,
      ),
    ]) {
      final m = re.firstMatch(html);
      if (m != null) {
        final v = _unescape(m.group(1)!.trim());
        if (v.isNotEmpty) return v;
      }
    }
  }
  return null;
}

/// True when [streamUrl] is served by a host that blocks normal clients (a
/// Cloudflare TLS-fingerprint block) and therefore must be played/downloaded
/// through the browser-impersonating yt-dlp path instead of libmpv/Dart http.
///
/// Detection is a cheap range probe with Dart's own http client — the exact
/// client that gets rejected — so a `403` (or a Cloudflare challenge body) is a
/// reliable "needs impersonation" signal. Any other outcome (200/206, a network
/// error, a timeout) returns false so normal links keep their fast direct path.
Future<bool> streamNeedsImpersonation(String streamUrl, {http.Client? client}) async {
  final ownClient = client == null;
  final c = client ?? http.Client();
  try {
    final resp = await c.get(
      Uri.parse(streamUrl),
      headers: {..._browserHeaders, 'Range': 'bytes=0-1'},
    ).timeout(const Duration(seconds: 8));
    logDiag('probe', '보호 판별 status=${resp.statusCode} ($streamUrl)');
    if (resp.statusCode == 403) return true;
    // Cloudflare sometimes wraps the block in a 503/429 challenge page.
    if (resp.statusCode == 503 || resp.statusCode == 429) {
      final body = resp.body.toLowerCase();
      return body.contains('cloudflare') &&
          (body.contains('attention required') || body.contains('cf-'));
    }
    return false;
  } catch (e) {
    logDiag('probe', '보호 판별 예외(→일반으로 처리): $e');
    return false;
  } finally {
    if (ownClient) c.close();
  }
}

/// The classified result of a pasted link: the URL to hand the engine plus how
/// it should be rendered (video / image / gif). [forVideoSource] is the URL to
/// store on a *video* item — always the original page link, so re-resolution
/// and quality/download listing keep working; for images it's the direct image
/// URL so it renders immediately.
class ResolvedMedia {
  const ResolvedMedia(this.url, this.kind);
  final String url;
  final MediaKind kind;
}

/// Classifies [original] into the media kind the app should render, so an
/// arbitrary pasted link "just works" instead of being forced into the video
/// engine (which would fail with a cryptic "unsupported format" on an image or
/// a plain web page).
///
/// Detection order:
///   1. YouTube  → video (resolved lazily at playback time).
///   2. Direct file by extension → image / gif / video.
///   3. Otherwise fetch the link and classify by `Content-Type` (the server may
///      return an image or a stream directly) or, for an HTML page, by whether
///      it embeds a video; failing that, fall back to the page's preview image
///      so *something* shows.
///
/// Returns null when the link can't be classified, so the caller can honor the
/// user's manual Video/Image/GIF choice as a last resort.
///
/// [client] is injectable for tests; production passes none and a one-shot
/// client is used per page fetch.
Future<ResolvedMedia?> resolveMedia(String original, {http.Client? client}) async {
  final url = original.trim();
  if (url.isEmpty) return null;

  // YouTube is always a video; keep the original watch URL as the source so the
  // player/downloader can re-resolve and list qualities later.
  if (isYouTubeUrl(url)) return ResolvedMedia(url, MediaKind.video);

  final ext = _extensionOf(url);
  if (ext != null) {
    if (ext == 'gif') return ResolvedMedia(url, MediaKind.gif);
    if (_imageExtensions.contains(ext)) return ResolvedMedia(url, MediaKind.image);
    if (_mediaExtensions.contains(ext)) return ResolvedMedia(url, MediaKind.video);
  }

  try {
    return await _classifyPage(url, client: client);
  } catch (_) {
    return null;
  }
}

/// Fetches [url] once and classifies it: a direct image/video by `Content-Type`,
/// an HTML page that embeds a video, or an HTML page whose preview image we can
/// show. Returns null if nothing usable is found.
Future<ResolvedMedia?> _classifyPage(String url, {http.Client? client}) async {
  final ownClient = client == null;
  final c = client ?? http.Client();
  try {
    final resp = await c
        .get(Uri.parse(url), headers: _browserHeaders)
        .timeout(const Duration(seconds: 12));
    final ct = (resp.headers['content-type'] ?? '').toLowerCase();

    // The server handed us a raw stream, not a page.
    if (ct.startsWith('image/')) {
      return ResolvedMedia(url, ct.contains('gif') ? MediaKind.gif : MediaKind.image);
    }
    if (ct.startsWith('video/') ||
        ct.contains('mpegurl') ||
        ct.contains('dash+xml')) {
      return ResolvedMedia(url, MediaKind.video);
    }
    if (resp.statusCode != 200 || !ct.contains('text/html')) return null;

    final base = Uri.parse(url);
    // A real video embedded in the page → keep the page URL as a video source so
    // playback re-resolves (and strips ads) through resolvePlayableUrl.
    if (_extractCandidates(resp.body, base: base).isNotEmpty ||
        _firstEmbedPage(resp.body, base: base) != null) {
      return ResolvedMedia(url, MediaKind.video);
    }
    // The stream may be hidden behind JavaScript (X, TikTok, Facebook, …). Ask
    // the bundled yt-dlp — if it can extract a stream, it's a video. (No-op
    // when yt-dlp isn't bundled, e.g. in tests.)
    if (await ytDlpResolveStream(url) != null) {
      return ResolvedMedia(url, MediaKind.video);
    }
    // No video anywhere — show its preview image so the tile isn't an error.
    final image = _firstMetaContent(
      resp.body,
      const ['og:image:secure_url', 'og:image', 'twitter:image'],
      base: base,
    );
    if (image != null) {
      final imgExt = _extensionOf(image);
      return ResolvedMedia(image, imgExt == 'gif' ? MediaKind.gif : MediaKind.image);
    }
    return null;
  } finally {
    if (ownClient) c.close();
  }
}

/// Returns the absolute `content` of the first matching `<meta>` tag whose
/// property/name is one of [props], or null. Handles either attribute order.
String? _firstMetaContent(String html, List<String> props, {required Uri base}) {
  for (final prop in props) {
    final p = RegExp.escape(prop);
    for (final re in [
      RegExp(
        '<meta[^>]*?(?:property|name)\\s*=\\s*["\']$p["\'][^>]*?content\\s*=\\s*["\']([^"\']+)["\']',
        caseSensitive: false,
      ),
      RegExp(
        '<meta[^>]*?content\\s*=\\s*["\']([^"\']+)["\'][^>]*?(?:property|name)\\s*=\\s*["\']$p["\']',
        caseSensitive: false,
      ),
    ]) {
      final m = re.firstMatch(html);
      if (m != null) {
        final resolved = _resolveAgainst(base, _unescape(m.group(1)!.trim()));
        if (resolved != null) return resolved;
      }
    }
  }
  return null;
}

/// True if [url]'s path ends in a known media extension (query string ignored),
/// i.e. it's already a stream libmpv can open directly.
bool _isDirectMediaUrl(String url) {
  final ext = _extensionOf(url);
  return ext != null && _mediaExtensions.contains(ext);
}

/// The lowercase file extension of a URL's path, or null if there isn't one.
String? _extensionOf(String url) {
  Uri? uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return null;
  }
  final path = uri.path;
  final slash = path.lastIndexOf('/');
  final name = slash >= 0 ? path.substring(slash + 1) : path;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

/// True if [url] points at a known ad / tracker host or endpoint.
bool _isAdUrl(String url) {
  final u = url.toLowerCase();
  return _adHostFragments.any(u.contains);
}

/// Fetches [pageUrl] and extracts the direct stream URL of the video embedded
/// in the page, or null if no playable video can be found.
///
/// Honors the "one video on the page → show that video" rule: every distinct
/// candidate is collected and ad/tracker URLs are dropped; if exactly one
/// remains it is returned, otherwise the best progressive stream wins.
///
/// [client] and [depth] are for testing / internal recursion respectively.
Future<String?> extractVideoFromPage(
  String pageUrl, {
  http.Client? client,
  int depth = 0,
}) async {
  final ownClient = client == null;
  final c = client ?? http.Client();
  try {
    final resp = await c.get(Uri.parse(pageUrl), headers: _browserHeaders);
    final contentType = resp.headers['content-type'] ?? '';
    // The link was actually a stream (server-decided), not a page.
    if (contentType.startsWith('video/') ||
        contentType.contains('mpegurl') ||
        contentType.contains('dash+xml')) {
      return pageUrl;
    }
    if (resp.statusCode != 200 || !contentType.contains('text/html')) {
      return null;
    }

    final candidates = _extractCandidates(resp.body, base: Uri.parse(pageUrl));
    if (candidates.isNotEmpty) {
      return _pickBest(candidates);
    }

    // No direct stream on the page, but maybe it embeds another player page
    // (e.g. an <iframe> to a dedicated player). Recurse once into it.
    if (depth == 0) {
      final embed = _firstEmbedPage(resp.body, base: Uri.parse(pageUrl));
      if (embed != null && embed != pageUrl) {
        return extractVideoFromPage(embed, client: c, depth: depth + 1);
      }
    }
    return null;
  } finally {
    if (ownClient) c.close();
  }
}

/// All distinct, non-ad, media-like stream URLs found in [html], in priority
/// order (explicit <video>/<source> first, then OG/Twitter meta, then any
/// stream URL appearing in inline scripts).
List<String> _extractCandidates(String html, {required Uri base}) {
  final ordered = <String>[];
  final seen = <String>{};

  void add(String? raw) {
    if (raw == null) return;
    var u = raw.trim();
    if (u.isEmpty) return;
    u = _unescape(u);
    final resolved = _resolveAgainst(base, u);
    if (resolved == null) return;
    if (_isAdUrl(resolved)) return;
    if (!_looksLikeMedia(resolved)) return;
    if (seen.add(resolved)) ordered.add(resolved);
  }

  // 1) <video src> and <source src> inside players.
  for (final m in RegExp(
    r'''<(?:video|source)\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).allMatches(html)) {
    add(m.group(1));
  }

  // 2) Open Graph / Twitter video meta tags.
  for (final prop in const [
    'og:video:secure_url',
    'og:video:url',
    'og:video',
    'twitter:player:stream',
  ]) {
    final p = RegExp.escape(prop);
    for (final m in RegExp(
      '<meta[^>]*?(?:property|name)\\s*=\\s*["\']$p["\'][^>]*?content\\s*=\\s*["\']([^"\']+)["\']',
      caseSensitive: false,
    ).allMatches(html)) {
      add(m.group(1));
    }
    // content="" can also come *before* property="".
    for (final m in RegExp(
      '<meta[^>]*?content\\s*=\\s*["\']([^"\']+)["\'][^>]*?(?:property|name)\\s*=\\s*["\']$p["\']',
      caseSensitive: false,
    ).allMatches(html)) {
      add(m.group(1));
    }
  }

  // 3) JSON-LD VideoObject contentUrl.
  for (final m in RegExp(
    r'"contentUrl"\s*:\s*"([^"]+)"',
    caseSensitive: false,
  ).allMatches(html)) {
    add(m.group(1));
  }

  // 4) Any stream URL appearing in inline scripts / data attributes — the
  //    catch-all that handles custom HTML5 players.
  for (final m in RegExp(
    r'''https?:\\?/\\?/[^"'\s<>]+?\.(?:m3u8|mpd|mp4|webm|mov|m4v)(?:\?[^"'\s<>]*)?''',
    caseSensitive: false,
  ).allMatches(html)) {
    add(m.group(0));
  }

  return ordered;
}

/// Picks the best stream from [candidates]. Progressive files (mp4/webm/…) are
/// preferred over adaptive manifests (m3u8/mpd) because a single libmpv player
/// opens them with audio and seeks instantly; otherwise the first candidate
/// (highest-priority source) wins.
String _pickBest(List<String> candidates) {
  const progressive = {'mp4', 'm4v', 'webm', 'mov', 'mkv'};
  for (final u in candidates) {
    final ext = _extensionOf(u);
    if (ext != null && progressive.contains(ext)) return u;
  }
  return candidates.first;
}

/// True if [url] looks like a playable media stream (by extension or by a
/// manifest hint in the path/query).
bool _looksLikeMedia(String url) {
  final ext = _extensionOf(url);
  if (ext != null && _mediaExtensions.contains(ext)) return true;
  final u = url.toLowerCase();
  return u.contains('.m3u8') || u.contains('.mpd');
}

/// Finds the first plausible embedded player page (iframe / og:url to a player)
/// so we can recurse one level to reach the actual stream.
String? _firstEmbedPage(String html, {required Uri base}) {
  for (final m in RegExp(
    r'''<iframe\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).allMatches(html)) {
    final raw = _unescape(m.group(1)!.trim());
    final resolved = _resolveAgainst(base, raw);
    if (resolved == null) continue;
    if (_isAdUrl(resolved)) continue;
    final low = resolved.toLowerCase();
    // Skip obvious non-video iframes (social buttons, comments, maps).
    if (low.contains('player') ||
        low.contains('embed') ||
        low.contains('video')) {
      return resolved;
    }
  }
  return null;
}

/// Resolves a possibly-relative [ref] against [base], returning an absolute
/// http(s) URL or null if it isn't web media.
String? _resolveAgainst(Uri base, String ref) {
  try {
    final resolved = base.resolve(ref);
    if (resolved.scheme == 'http' || resolved.scheme == 'https') {
      return resolved.toString();
    }
    // Protocol-relative (//host/…) already handled by resolve(); anything
    // non-http (data:, blob:, javascript:) is unusable.
    return null;
  } catch (_) {
    return null;
  }
}

/// Decodes the handful of escapes that show up in HTML attributes and inside
/// JSON embedded in <script> tags (`\/`, `&`, `&amp;`, …).
String _unescape(String s) {
  return s
      .replaceAll(r'\/', '/')
      .replaceAll(RegExp(r'\\u0026', caseSensitive: false), '&')
      .replaceAll('&amp;', '&')
      .replaceAll('&#38;', '&');
}
