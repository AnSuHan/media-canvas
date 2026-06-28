// Offline unit tests for the page-info resolver behind the "동영상 가져오기"
// screen. A mocked HTTP client makes them deterministic: they verify the
// resolver pulls the embedded stream, title and thumbnail out of a page, and
// that a Cloudflare-style 403 on the stream flips `needsImpersonation` so the
// app routes that link through the browser-impersonating yt-dlp path.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:media_canvas/services/page_video_resolver.dart';

const _pageUrl = 'https://example.tv/vod/abc123';
const _streamUrl = 'https://cdn.example.net/abc/master.m3u8';

const _html = '''
<!doctype html><html><head>
  <meta property="og:title" content="A Sample Clip Title"/>
  <meta property="og:image" content="https://img.example.net/thumb.jpg"/>
</head><body>
  <script>
    var player = { source: "$_streamUrl" };
  </script>
</body></html>
''';

/// Mock client that serves the page HTML and lets the test decide what the
/// stream probe returns (200 = direct-playable, 403 = needs impersonation).
http.Client _client({required int streamStatus}) {
  return MockClient((req) async {
    final url = req.url.toString();
    if (url == _pageUrl) {
      return http.Response(_html, 200, headers: {'content-type': 'text/html'});
    }
    if (url == _streamUrl) {
      if (streamStatus == 200) {
        return http.Response('#EXTM3U', 200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'});
      }
      return http.Response('blocked', streamStatus);
    }
    return http.Response('not found', 404);
  });
}

void main() {
  test('extracts stream, title and thumbnail from a page', () async {
    final src = await resolveVideoSource(_pageUrl,
        client: _client(streamStatus: 200));
    expect(src, isNotNull);
    expect(src!.streamUrl, _streamUrl);
    expect(src.pageUrl, _pageUrl);
    expect(src.referer, _pageUrl); // hotlink protection needs the page
    expect(src.title, 'A Sample Clip Title');
    expect(src.thumbnail, 'https://img.example.net/thumb.jpg');
  });

  test('a directly-playable stream → needsImpersonation is false', () async {
    final src = await resolveVideoSource(_pageUrl,
        client: _client(streamStatus: 200));
    expect(src!.needsImpersonation, isFalse);
  });

  test('a Cloudflare-403 stream → needsImpersonation is true', () async {
    final src = await resolveVideoSource(_pageUrl,
        client: _client(streamStatus: 403));
    expect(src, isNotNull);
    expect(src!.needsImpersonation, isTrue,
        reason: 'a 403 on the stream means libmpv would be blocked too');
  });

  test('returns null when the page embeds no playable stream', () async {
    final client = MockClient((req) async => http.Response(
          '<html><body><p>no video here</p></body></html>',
          200,
          headers: {'content-type': 'text/html'},
        ));
    expect(await resolveVideoSource(_pageUrl, client: client), isNull);
  });

  test('returns null for a non-http(s) link without touching the network',
      () async {
    expect(await resolveVideoSource('ftp://nope/x'), isNull);
    expect(await resolveVideoSource('   '), isNull);
  });
}
