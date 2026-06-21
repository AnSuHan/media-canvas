// Unit tests for the Instagram post resolver. Pure parsing only (offline) —
// the network fetch path is best-effort and not exercised here.

import 'package:flutter_test/flutter_test.dart';

import 'package:media_canvas/services/instagram_resolver.dart';

void main() {
  group('isInstagramUrl / shortcode', () {
    test('recognises post, reel and tv links', () {
      expect(isInstagramUrl('https://www.instagram.com/p/ABC123/'), isTrue);
      expect(isInstagramUrl('https://instagram.com/reel/XyZ_9/'), isTrue);
      expect(isInstagramUrl('https://www.instagram.com/tv/Qq-1/'), isTrue);
      expect(isInstagramUrl('https://example.com/p/ABC/'), isFalse);
    });

    test('extracts the shortcode', () {
      expect(instagramShortcode('https://www.instagram.com/p/ABC123/?hl=en'),
          'ABC123');
      expect(instagramShortcode('https://instagram.com/reel/Xy_9-z/'), 'Xy_9-z');
      expect(instagramShortcode('https://example.com/x'), isNull);
    });
  });

  group('parseInstagramMedia — graphql shape', () {
    test('single image', () {
      const j = '''
      {"graphql":{"shortcode_media":{
        "is_video":false,
        "display_url":"https://cdn/img.jpg"
      }}}''';
      final m = parseInstagramMedia(j);
      expect(m.length, 1);
      expect(m.first.url, 'https://cdn/img.jpg');
      expect(m.first.isVideo, isFalse);
    });

    test('single video', () {
      const j = '''
      {"graphql":{"shortcode_media":{
        "is_video":true,
        "display_url":"https://cdn/thumb.jpg",
        "video_url":"https://cdn/v.mp4"
      }}}''';
      final m = parseInstagramMedia(j);
      expect(m.length, 1);
      expect(m.first.url, 'https://cdn/v.mp4');
      expect(m.first.isVideo, isTrue);
    });

    test('carousel (sidecar) with mixed media', () {
      const j = '''
      {"graphql":{"shortcode_media":{
        "edge_sidecar_to_children":{"edges":[
          {"node":{"is_video":false,"display_url":"https://cdn/1.jpg"}},
          {"node":{"is_video":true,"display_url":"https://cdn/2.jpg","video_url":"https://cdn/2.mp4"}},
          {"node":{"is_video":false,"display_url":"https://cdn/3.jpg"}}
        ]}
      }}}''';
      final m = parseInstagramMedia(j);
      expect(m.map((e) => e.url), [
        'https://cdn/1.jpg',
        'https://cdn/2.mp4',
        'https://cdn/3.jpg',
      ]);
      expect(m.map((e) => e.isVideo), [false, true, false]);
    });
  });

  group('parseInstagramMedia — private-API shape', () {
    test('carousel_media with video_versions / image_versions2', () {
      const j = '''
      {"items":[{"carousel_media":[
        {"image_versions2":{"candidates":[{"url":"https://cdn/a.jpg"},{"url":"https://cdn/a-small.jpg"}]}},
        {"video_versions":[{"url":"https://cdn/b.mp4"}],"image_versions2":{"candidates":[{"url":"https://cdn/b.jpg"}]}}
      ]}]}''';
      final m = parseInstagramMedia(j);
      expect(m.length, 2);
      expect(m[0].url, 'https://cdn/a.jpg');
      expect(m[0].isVideo, isFalse);
      expect(m[1].url, 'https://cdn/b.mp4');
      expect(m[1].isVideo, isTrue);
    });

    test('single item (no carousel)', () {
      const j = '''
      {"items":[{"video_versions":[{"url":"https://cdn/only.mp4"}]}]}''';
      final m = parseInstagramMedia(j);
      expect(m.length, 1);
      expect(m.first.url, 'https://cdn/only.mp4');
      expect(m.first.isVideo, isTrue);
    });

    test('invalid JSON yields empty', () {
      expect(parseInstagramMedia('not json'), isEmpty);
    });
  });

  group('extractInstagramMediaFromHtml', () {
    test('reads embedded video_url / display_url with escapes', () {
      const html = r'''
        <script>{"display_url":"https:\/\/cdn\/1.jpg&t=1",
                 "video_url":"https:\/\/cdn\/1.mp4"}</script>''';
      final m = extractInstagramMediaFromHtml(html);
      expect(m.any((e) => e.isVideo && e.url == 'https://cdn/1.mp4'), isTrue);
      expect(m.any((e) => !e.isVideo && e.url == 'https://cdn/1.jpg&t=1'), isTrue);
    });

    test('falls back to Open Graph tags when no embedded JSON', () {
      const html = '''
        <meta property="og:image" content="https://cdn/og.jpg">''';
      final m = extractInstagramMediaFromHtml(html);
      expect(m.length, 1);
      expect(m.first.url, 'https://cdn/og.jpg');
      expect(m.first.isVideo, isFalse);
    });
  });
}
