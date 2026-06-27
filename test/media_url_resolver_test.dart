// Unit tests for the generic media URL resolver. These run pure Dart and use
// a mocked HTTP client so they're deterministic and offline — they verify the
// page-scraping, ad-filtering and "one video → show it" rules.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:media_canvas/models/media_item.dart' show MediaKind;
import 'package:media_canvas/services/media_url_resolver.dart';
import 'package:media_canvas/services/ytdlp.dart';

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

  // resolveMedia classifies a pasted link into the kind the app should render,
  // so any URL is routed correctly instead of being forced into the video
  // engine (which would error with "unsupported format"). These cover the
  // offline branches that decide before any network fetch.
  group('resolveMedia — extension/type classification', () {
    Future<MediaKind?> kindOf(String url) async => (await resolveMedia(url))?.kind;

    test('a YouTube link is a video (original URL kept as source)', () async {
      final r = await resolveMedia('https://youtu.be/abc123');
      expect(r?.kind, MediaKind.video);
      expect(r?.url, 'https://youtu.be/abc123');
    });

    test('a direct .mp4 is a video', () async {
      expect(await kindOf('https://cdn.example.com/clip.mp4'), MediaKind.video);
    });

    test('an HLS .m3u8 stream is a video', () async {
      expect(await kindOf('https://cdn.example.com/live/stream.m3u8'),
          MediaKind.video);
    });

    test('a DASH .mpd stream is a video', () async {
      expect(await kindOf('https://cdn.example.com/v/manifest.mpd'),
          MediaKind.video);
    });

    test('a .jpg/.png link is an image', () async {
      expect(await kindOf('https://img.example.com/a.jpg'), MediaKind.image);
      expect(await kindOf('https://img.example.com/a.png'), MediaKind.image);
    });

    test('a .gif link is a gif', () async {
      expect(await kindOf('https://img.example.com/loop.gif'), MediaKind.gif);
    });

    test('empty input is unclassified (null)', () async {
      expect(await resolveMedia('   '), isNull);
    });
  });

  // The page-classification path (no usable extension) decides by the server's
  // Content-Type or by scraping the HTML. A mocked client keeps it offline and
  // deterministic. This is what stops an image or a plain web page from being
  // forced into the video engine ("unsupported format").
  group('resolveMedia — page classification (offline)', () {
    http.Client serving(String body, String contentType, {int status = 200}) {
      return MockClient((req) async =>
          http.Response(body, status, headers: {'content-type': contentType}));
    }

    test('a server-served image stream → image', () async {
      final r = await resolveMedia('https://x.example/photo',
          client: serving('bytes', 'image/jpeg'));
      expect(r?.kind, MediaKind.image);
      expect(r?.url, 'https://x.example/photo');
    });

    test('a server-served gif → gif', () async {
      final r = await resolveMedia('https://x.example/anim',
          client: serving('bytes', 'image/gif'));
      expect(r?.kind, MediaKind.gif);
    });

    test('a server-served video stream → video', () async {
      final r = await resolveMedia('https://x.example/streamendpoint',
          client: serving('bytes', 'video/mp4'));
      expect(r?.kind, MediaKind.video);
    });

    test('an HLS endpoint with no extension → video (by content-type)', () async {
      final r = await resolveMedia('https://x.example/live?token=abc',
          client: serving('#EXTM3U', 'application/vnd.apple.mpegurl'));
      expect(r?.kind, MediaKind.video);
    });

    test('an HTML page that embeds a video → video', () async {
      const html =
          '<html><body><video src="https://cdn.example/clip.mp4"></video></body></html>';
      final r = await resolveMedia('https://news.example/article',
          client: serving(html, 'text/html'));
      expect(r?.kind, MediaKind.video);
      // The source stays the page URL so playback re-resolves (and strips ads).
      expect(r?.url, 'https://news.example/article');
    });

    test('an HTML page with no video falls back to its og:image → image',
        () async {
      const html = '<html><head>'
          '<meta property="og:image" content="https://cdn.example/preview.jpg">'
          '</head><body><p>An article, no video.</p></body></html>';
      final r = await resolveMedia('https://blog.example/post',
          client: serving(html, 'text/html'));
      expect(r?.kind, MediaKind.image);
      expect(r?.url, 'https://cdn.example/preview.jpg');
    });

    test('an HTML page with neither video nor preview image → null', () async {
      const html = '<html><body><p>Just words.</p></body></html>';
      final r = await resolveMedia('https://blog.example/empty',
          client: serving(html, 'text/html'));
      expect(r, isNull);
    });

    test('a non-200 response → null (caller honors the manual kind)', () async {
      final r = await resolveMedia('https://x.example/gone',
          client: serving('nope', 'text/html', status: 404));
      expect(r, isNull);
    });
  });

  // yt-dlp is only a *fallback* for sites the built-in extractor can't reach
  // (JS-driven players). Ordinary, non-JS links — a direct file, or a plain
  // HTML page with an embedded <video> / OpenGraph tags — must still classify
  // correctly with yt-dlp completely unavailable. These pin that guarantee by
  // forcing yt-dlp off.
  group('resolveMedia — non-JS links work without yt-dlp', () {
    setUp(() => setYtDlpExecutable(null)); // ensure the binary is unavailable
    tearDown(() => setYtDlpExecutable(null));

    http.Client serving(String body, String contentType, {int status = 200}) {
      return MockClient((req) async =>
          http.Response(body, status, headers: {'content-type': contentType}));
    }

    test('yt-dlp is reported unavailable in this configuration', () {
      expect(ytDlpAvailable(), isFalse);
    });

    test('a direct .mp4 → video (no network, no yt-dlp)', () async {
      expect((await resolveMedia('https://cdn.example/clip.mp4'))?.kind,
          MediaKind.video);
    });

    test('a non-JS page with an embedded <video> → video (built-in scrape)',
        () async {
      const html = '<html><body>'
          '<video><source src="https://cdn.example/v.mp4"></video>'
          '</body></html>';
      final r = await resolveMedia('https://site.example/watch',
          client: serving(html, 'text/html'));
      expect(r?.kind, MediaKind.video);
      expect(r?.url, 'https://site.example/watch');
    });

    test('a non-JS page exposing og:video → video (built-in scrape)', () async {
      const html = '<html><head>'
          '<meta property="og:video" content="https://cdn.example/og.mp4">'
          '</head><body>article</body></html>';
      final r = await resolveMedia('https://news.example/story',
          client: serving(html, 'text/html'));
      expect(r?.kind, MediaKind.video);
    });

    test('a non-JS page with only a preview image → image (graceful fallback)',
        () async {
      const html = '<html><head>'
          '<meta property="og:image" content="https://cdn.example/p.jpg">'
          '</head><body>no video here</body></html>';
      final r = await resolveMedia('https://blog.example/post',
          client: serving(html, 'text/html'));
      expect(r?.kind, MediaKind.image);
      expect(r?.url, 'https://cdn.example/p.jpg');
    });
  });
}
