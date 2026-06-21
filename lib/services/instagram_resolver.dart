import 'dart:convert';

import 'package:http/http.dart' as http;

/// Resolves an Instagram post/reel link into *all* of its media (every photo
/// and video of a carousel), so the board can lay them out together.
///
/// How
/// ---
/// Instagram exposes a post's media as JSON. We ask for it with a browser-like
/// request plus the public web `X-IG-App-ID`, then read the carousel children.
/// If that JSON endpoint is unavailable we fall back to scraping the embedded
/// JSON / Open Graph tags out of the post's HTML page.
///
/// Caveat: Instagram aggressively gates unauthenticated access and its CDN URLs
/// are time-limited. This works best for public posts and for immediate
/// viewing; a saved board may need re-adding once the CDN links expire.

/// One piece of media inside an Instagram post.
class InstagramMedia {
  const InstagramMedia(this.url, this.isVideo);
  final String url;
  final bool isVideo;
}

/// The public web app id Instagram's own site sends with its JSON requests.
const _igAppId = '936619743392459';

bool isInstagramUrl(String url) {
  final u = url.trim().toLowerCase();
  return u.contains('instagram.com/p/') ||
      u.contains('instagram.com/reel/') ||
      u.contains('instagram.com/reels/') ||
      u.contains('instagram.com/tv/');
}

/// Extracts the post shortcode from an Instagram URL, or null.
String? instagramShortcode(String url) {
  final m = RegExp(r'instagram\.com/(?:p|reel|reels|tv)/([A-Za-z0-9_-]+)')
      .firstMatch(url);
  return m?.group(1);
}

/// Resolves [url] to every photo/video in the post. Returns an empty list if
/// nothing could be extracted.
Future<List<InstagramMedia>> resolveInstagram(
  String url, {
  http.Client? client,
}) async {
  final shortcode = instagramShortcode(url);
  if (shortcode == null) return const [];

  final ownClient = client == null;
  final c = client ?? http.Client();
  try {
    // 1) Official-ish JSON endpoint used by the web client.
    try {
      final resp = await c.get(
        Uri.parse('https://www.instagram.com/p/$shortcode/?__a=1&__d=dis'),
        headers: const {
          'User-Agent': _ua,
          'X-IG-App-ID': _igAppId,
          'Accept': 'application/json',
        },
      );
      if (resp.statusCode == 200 &&
          (resp.headers['content-type'] ?? '').contains('json')) {
        final media = parseInstagramMedia(resp.body);
        if (media.isNotEmpty) return media;
      }
    } catch (_) {/* fall through */}

    // 2) Fall back to the post page HTML (embedded JSON / OG tags).
    final page = await c.get(
      Uri.parse('https://www.instagram.com/p/$shortcode/'),
      headers: const {'User-Agent': _ua, 'X-IG-App-ID': _igAppId},
    );
    if (page.statusCode == 200) {
      final media = extractInstagramMediaFromHtml(page.body);
      if (media.isNotEmpty) return media;
    }
    return const [];
  } finally {
    if (ownClient) c.close();
  }
}

/// Parses Instagram media JSON into a flat media list. Handles both the classic
/// `graphql.shortcode_media` shape and the newer `items[].carousel_media` shape.
List<InstagramMedia> parseInstagramMedia(String jsonStr) {
  dynamic root;
  try {
    root = jsonDecode(jsonStr);
  } catch (_) {
    return const [];
  }
  if (root is! Map) return const [];

  // Classic web shape: { graphql: { shortcode_media: {...} } }
  final node = _dig(root, ['graphql', 'shortcode_media']) ??
      _dig(root, ['data', 'shortcode_media']) ??
      (root['shortcode_media']);
  if (node is Map) return _fromGraphqlNode(node);

  // Newer private-API shape: { items: [ { carousel_media: [...] } ] }
  final items = root['items'];
  if (items is List && items.isNotEmpty && items.first is Map) {
    return _fromApiItem(items.first as Map);
  }
  return const [];
}

List<InstagramMedia> _fromGraphqlNode(Map node) {
  final out = <InstagramMedia>[];
  final children = _dig(node, ['edge_sidecar_to_children', 'edges']);
  if (children is List) {
    for (final e in children) {
      final n = (e is Map) ? e['node'] : null;
      if (n is Map) _addGraphqlChild(out, n);
    }
  } else {
    _addGraphqlChild(out, node);
  }
  return out;
}

void _addGraphqlChild(List<InstagramMedia> out, Map n) {
  final isVideo = n['is_video'] == true;
  if (isVideo && n['video_url'] is String) {
    out.add(InstagramMedia(n['video_url'] as String, true));
  } else if (n['display_url'] is String) {
    out.add(InstagramMedia(n['display_url'] as String, false));
  }
}

List<InstagramMedia> _fromApiItem(Map item) {
  final out = <InstagramMedia>[];
  final carousel = item['carousel_media'];
  if (carousel is List) {
    for (final cm in carousel) {
      if (cm is Map) _addApiChild(out, cm);
    }
  } else {
    _addApiChild(out, item);
  }
  return out;
}

void _addApiChild(List<InstagramMedia> out, Map m) {
  final videos = m['video_versions'];
  if (videos is List && videos.isNotEmpty && videos.first is Map) {
    final u = (videos.first as Map)['url'];
    if (u is String) {
      out.add(InstagramMedia(u, true));
      return;
    }
  }
  final candidates = _dig(m, ['image_versions2', 'candidates']);
  if (candidates is List && candidates.isNotEmpty && candidates.first is Map) {
    final u = (candidates.first as Map)['url'];
    if (u is String) out.add(InstagramMedia(u, false));
  }
}

/// Best-effort extraction from the post HTML when the JSON endpoint is blocked:
/// reads media URLs out of the page's embedded JSON, falling back to OG tags.
List<InstagramMedia> extractInstagramMediaFromHtml(String html) {
  final out = <InstagramMedia>[];
  final seen = <String>{};

  void add(String? raw, bool isVideo) {
    if (raw == null) return;
    final u = _unescape(raw);
    if (!u.startsWith('http')) return;
    if (seen.add('$isVideo|$u')) out.add(InstagramMedia(u, isVideo));
  }

  // Embedded JSON keys (carousels inline the children here).
  for (final m in RegExp(r'"video_url":"([^"]+)"').allMatches(html)) {
    add(m.group(1), true);
  }
  for (final m in RegExp(r'"display_url":"([^"]+)"').allMatches(html)) {
    add(m.group(1), false);
  }

  if (out.isNotEmpty) return out;

  // Last resort: Open Graph (first media only).
  final ogv = RegExp(
          r'<meta[^>]*property="og:video"[^>]*content="([^"]+)"',
          caseSensitive: false)
      .firstMatch(html);
  if (ogv != null) add(ogv.group(1), true);
  final ogi = RegExp(
          r'<meta[^>]*property="og:image"[^>]*content="([^"]+)"',
          caseSensitive: false)
      .firstMatch(html);
  if (ogi != null) add(ogi.group(1), false);
  return out;
}

/// Digs into nested maps by [path], returning null if any step is missing.
dynamic _dig(Map root, List<String> path) {
  dynamic cur = root;
  for (final key in path) {
    if (cur is Map && cur.containsKey(key)) {
      cur = cur[key];
    } else {
      return null;
    }
  }
  return cur;
}

String _unescape(String s) => s
    .replaceAll(r'\/', '/')
    .replaceAll(RegExp(r'\\u0026', caseSensitive: false), '&')
    .replaceAll('&amp;', '&');

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';
