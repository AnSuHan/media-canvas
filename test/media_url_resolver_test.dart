// Unit tests for the generic media URL resolver. These run pure Dart and use
// a mocked HTTP client so they're deterministic and offline — they verify the
// page-scraping, ad-filtering and "one video → show it" rules.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:media_canvas/services/media_url_resolver.dart';

http.Client _html(String body, {String contentType = 'text/html'}) {
  return MockClient((req) async => http.Response(
        body,
        200,
        headers: {'content-type': contentType},
      ));
}

void main() {
  group('resolvePlayableUrl — direct links', () {
    test('passes a direct .mp4 through unchanged', () async {
      const url = 'https://cdn.example.com/path/clip.mp4';
      expect(await resolvePlayableUrl(url), url);
    });

    test('passes an HLS .m3u8 through unchanged (with query)', () async {
      const url = 'https://cdn.example.com/live/stream.m3u8?token=abc';
      expect(await resolvePlayableUrl(url), url);
    });

    test('passes a DASH .mpd through unchanged', () async {
      const url = 'https://cdn.example.com/v/manifest.mpd';
      expect(await resolvePlayableUrl(url), url);
    });

    test('recognises YouTube links', () {
      expect(isYouTubeUrl('https://www.youtube.com/watch?v=abc'), isTrue);
      expect(isYouTubeUrl('https://youtu.be/abc'), isTrue);
      expect(isYouTubeUrl('https://example.com/clip.mp4'), isFalse);
    });
  });

  group('extractVideoFromPage — single video on the page', () {
    test('finds a lone <video src>', () async {
      final client = _html('''
        <html><body>
          <video src="https://cdn.example.com/lone.mp4" controls></video>
        </body></html>
      ''');
      final got = await extractVideoFromPage(
        'https://news.example.com/article',
        client: client,
      );
      expect(got, 'https://cdn.example.com/lone.mp4');
    });

    test('finds a <source> inside <video>', () async {
      final client = _html('''
        <video controls>
          <source src="https://cdn.example.com/inner.webm" type="video/webm">
        </video>
      ''');
      final got = await extractVideoFromPage(
        'https://example.com/p',
        client: client,
      );
      expect(got, 'https://cdn.example.com/inner.webm');
    });

    test('finds an og:video meta tag', () async {
      final client = _html('''
        <head>
          <meta property="og:video:secure_url"
                content="https://cdn.example.com/og.mp4">
        </head>
      ''');
      final got = await extractVideoFromPage(
        'https://example.com/p',
        client: client,
      );
      expect(got, 'https://cdn.example.com/og.mp4');
    });

    test('resolves a relative source against the page URL', () async {
      final client = _html('''
        <video src="/media/relative.mp4"></video>
      ''');
      final got = await extractVideoFromPage(
        'https://host.example.com/watch/123',
        client: client,
      );
      expect(got, 'https://host.example.com/media/relative.mp4');
    });

    test('extracts an .m3u8 buried in an inline player script', () async {
      final client = _html('''
        <script>
          var player = new Hls();
          player.loadSource("https:\\/\\/cdn.example.com\\/hls\\/master.m3u8");
        </script>
      ''');
      final got = await extractVideoFromPage(
        'https://example.com/p',
        client: client,
      );
      expect(got, 'https://cdn.example.com/hls/master.m3u8');
    });
  });

  group('extractVideoFromPage — ad blocking', () {
    test('drops ad/tracker stream URLs and keeps the real video', () async {
      final client = _html('''
        <html><body>
          <video src="https://pubads.g.doubleclick.net/preroll/ad.mp4"></video>
          <script>
            googletag; // ima ad sdk
            var src = "https://imasdk.googleapis.com/ad/break.mp4";
            var real = "https://cdn.example.com/content/feature.mp4";
          </script>
        </body></html>
      ''');
      final got = await extractVideoFromPage(
        'https://example.com/watch',
        client: client,
      );
      expect(got, 'https://cdn.example.com/content/feature.mp4');
    });

    test('returns null when the only media is an ad', () async {
      final client = _html('''
        <video src="https://ad.doubleclick.net/spot.mp4"></video>
      ''');
      final got = await extractVideoFromPage(
        'https://example.com/p',
        client: client,
      );
      expect(got, isNull);
    });
  });

  group('extractVideoFromPage — picking among several', () {
    test('prefers a progressive mp4 over an HLS manifest', () async {
      final client = _html('''
        <script>
          var hls = "https://cdn.example.com/a/master.m3u8";
        </script>
        <video src="https://cdn.example.com/a/progressive.mp4"></video>
      ''');
      final got = await extractVideoFromPage(
        'https://example.com/p',
        client: client,
      );
      expect(got, 'https://cdn.example.com/a/progressive.mp4');
    });
  });

  group('extractVideoFromPage — no playable media', () {
    test('returns null for a page with no video', () async {
      final client = _html('<html><body><p>Just text.</p></body></html>');
      final got = await extractVideoFromPage(
        'https://example.com/p',
        client: client,
      );
      expect(got, isNull);
    });

    test('returns the URL itself when the server serves a video stream', () async {
      final client = _html('binary-bytes', contentType: 'video/mp4');
      final got = await extractVideoFromPage(
        'https://example.com/streamendpoint',
        client: client,
      );
      expect(got, 'https://example.com/streamendpoint');
    });
  });
}
