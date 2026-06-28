import 'package:http/http.dart' as http;

import '../models/video_source.dart';
import 'app_log.dart';
import 'media_url_resolver.dart';
import 'ytdlp.dart';

/// Browser-like headers so pages serve their real markup. Mirrors the set used
/// by the player resolver.
const _browserHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
};

/// Inspects [pageUrl] and returns the playable video it embeds — the stream
/// URL, its required Referer, a title and thumbnail for the UI, and whether the
/// stream host blocks normal clients (so play/download must impersonate a
/// browser via yt-dlp).
///
/// This powers the "동영상 가져오기" screen: paste a site link (e.g. a VOD page
/// reached over a VPN), and the app pulls out the underlying stream so it can
/// be played inside the app and saved to the URL library — without ever loading
/// the publisher's ad-serving HTML in a webview.
///
/// Returns null when no playable stream can be found on the page.
///
/// [client] is injectable for tests; production uses a one-shot client.
Future<VideoSource?> resolveVideoSource(
  String pageUrl, {
  http.Client? client,
}) async {
  final url = pageUrl.trim();
  if (url.isEmpty) return null;
  final base = Uri.tryParse(url);
  if (base == null || !(base.scheme == 'http' || base.scheme == 'https')) {
    return null;
  }
  logDiag('fetch', '가져오기 시작: $url');

  final ownClient = client == null;
  final c = client ?? http.Client();
  try {
    final resp = await c
        .get(base, headers: _browserHeaders)
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;

    final ct = (resp.headers['content-type'] ?? '').toLowerCase();
    // The link itself was a direct stream, not a page.
    if (ct.startsWith('video/') ||
        ct.contains('mpegurl') ||
        ct.contains('dash+xml')) {
      return VideoSource(
        pageUrl: url,
        streamUrl: url,
        referer: url,
        needsImpersonation: await streamNeedsImpersonation(url, client: client),
        title: base.host,
      );
    }
    if (!ct.contains('text/html')) return null;

    final html = resp.body;
    final candidates = extractStreamCandidates(html, base: base);
    if (candidates.isEmpty) {
      logDiag('fetch', '페이지에서 재생할 스트림을 찾지 못함');
      return null;
    }

    // Prefer a progressive file (instant seek, has audio); else the first
    // stream (usually the HLS master) — same rule the player uses.
    final streamUrl = _pickBest(candidates);
    final title =
        extractMetaText(html, const ['og:title', 'twitter:title']) ??
            base.host;
    final thumb = extractMetaContent(
        html, const ['og:image:secure_url', 'og:image', 'twitter:image'],
        base: base);

    final needs = await streamNeedsImpersonation(streamUrl, client: client);
    logDiag('fetch', '스트림=$streamUrl 보호=$needs 제목="$title"');
    return VideoSource(
      pageUrl: url,
      streamUrl: streamUrl,
      referer: url,
      needsImpersonation: needs,
      title: title,
      thumbnail: thumb,
    );
  } catch (e) {
    logDiag('fetch', '가져오기 예외: $e');
    return null;
  } finally {
    if (ownClient) c.close();
  }
}

/// Prefers a progressive file over an adaptive manifest, matching the player.
String _pickBest(List<String> candidates) {
  const progressive = {'mp4', 'm4v', 'webm', 'mov', 'mkv'};
  for (final u in candidates) {
    final lower = u.toLowerCase();
    if (progressive.any((e) => lower.contains('.$e'))) return u;
  }
  return candidates.first;
}

/// True if the page-info resolver can reach a stream for [pageUrl] *and* the
/// bundled yt-dlp is available to play/download a host that needs impersonation.
/// (Pure convenience for callers/tests; the real check is [resolveVideoSource].)
bool canImpersonate() => ytDlpAvailable();
