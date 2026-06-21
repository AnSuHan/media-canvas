import 'package:http/http.dart' as http;

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
    // Fall through to the raw URL.
  }
  return url;
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
    final resp = await c.get(
      Uri.parse(pageUrl),
      headers: const {
        // Look like a normal browser so pages serve their real markup.
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
    );
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
