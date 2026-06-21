// Unit tests for the HLS server-side-ad-insertion (SSAI) stripper. Pure Dart,
// offline — they verify that ad segments fenced by SCTE-35 markers are removed
// and the surviving segment URLs are absolutized.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:media_canvas/services/hls_ad_filter.dart';

void main() {
  final base = Uri.parse('https://cdn.example.com/vod/playlist.m3u8');

  group('stripHlsAdsFromMediaPlaylist', () {
    test('returns null when there are no ad markers', () {
      const pl = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
seg0.ts
#EXTINF:6.0,
seg1.ts
#EXT-X-ENDLIST''';
      expect(stripHlsAdsFromMediaPlaylist(pl, base), isNull);
    });

    test('removes a CUE-OUT/CUE-IN ad break and keeps content', () {
      const pl = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
content0.ts
#EXT-X-CUE-OUT:12.0
#EXTINF:6.0,
ad0.ts
#EXTINF:6.0,
ad1.ts
#EXT-X-CUE-IN
#EXTINF:6.0,
content1.ts
#EXT-X-ENDLIST''';

      final out = stripHlsAdsFromMediaPlaylist(pl, base)!;

      // Ad segments gone.
      expect(out, isNot(contains('ad0.ts')));
      expect(out, isNot(contains('ad1.ts')));
      // Markers gone.
      expect(out, isNot(contains('CUE-OUT')));
      expect(out, isNot(contains('CUE-IN')));
      // Content survives, absolutized.
      expect(out, contains('https://cdn.example.com/vod/content0.ts'));
      expect(out, contains('https://cdn.example.com/vod/content1.ts'));
      // A discontinuity is inserted where the ad was removed.
      expect(out, contains('#EXT-X-DISCONTINUITY'));
      // Header + endlist preserved.
      expect(out, startsWith('#EXTM3U'));
      expect(out, contains('#EXT-X-ENDLIST'));
    });

    test('removes a DATERANGE SCTE35-OUT/IN ad break', () {
      const pl = '''#EXTM3U
#EXT-X-VERSION:3
#EXTINF:6.0,
content0.ts
#EXT-X-DATERANGE:ID="ad1",START-DATE="2024-01-01T00:00:00Z",SCTE35-OUT=0xFC
#EXTINF:6.0,
ad0.ts
#EXT-X-DATERANGE:ID="ad1",SCTE35-IN=0xFC
#EXTINF:6.0,
content1.ts
#EXT-X-ENDLIST''';

      final out = stripHlsAdsFromMediaPlaylist(pl, base)!;
      expect(out, isNot(contains('ad0.ts')));
      expect(out, contains('content0.ts'));
      expect(out, contains('content1.ts'));
    });

    test('absolutizes #EXT-X-KEY and #EXT-X-MAP URIs', () {
      const pl = '''#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXT-X-MAP:URI="init.mp4"
#EXTINF:6.0,
content0.ts
#EXT-X-CUE-OUT:6.0
#EXTINF:6.0,
ad0.ts
#EXT-X-CUE-IN
#EXTINF:6.0,
content1.ts
#EXT-X-ENDLIST''';

      final out = stripHlsAdsFromMediaPlaylist(pl, base)!;
      expect(out, contains('URI="https://cdn.example.com/vod/key.bin"'));
      expect(out, contains('URI="https://cdn.example.com/vod/init.mp4"'));
    });

    test('handles absolute segment URLs in the ad and content', () {
      const pl = '''#EXTM3U
#EXTINF:6.0,
https://cdn.example.com/vod/c0.ts
#EXT-X-CUE-OUT:6.0
#EXTINF:6.0,
https://ads.example.net/spot/a0.ts
#EXT-X-CUE-IN
#EXTINF:6.0,
https://cdn.example.com/vod/c1.ts
#EXT-X-ENDLIST''';

      final out = stripHlsAdsFromMediaPlaylist(pl, base)!;
      expect(out, isNot(contains('ads.example.net')));
      expect(out, contains('https://cdn.example.com/vod/c0.ts'));
      expect(out, contains('https://cdn.example.com/vod/c1.ts'));
    });
  });

  group('selectVariant', () {
    test('picks the highest-bandwidth variant, absolutized', () {
      const master = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
high/index.m3u8''';
      final got = selectVariant(
        master,
        Uri.parse('https://cdn.example.com/vod/master.m3u8'),
      );
      expect(got, 'https://cdn.example.com/vod/high/index.m3u8');
    });
  });

  group('filterHlsAds (orchestration)', () {
    test('non-HLS URL returns null without any fetch', () async {
      var fetched = false;
      final client = MockClient((req) async {
        fetched = true;
        return http.Response('', 200);
      });
      final got = await filterHlsAds('https://x.com/clip.mp4', client: client);
      expect(got, isNull);
      expect(fetched, isFalse);
    });

    test('follows a master playlist, strips ads, and writes a file', () async {
      const master = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000000
media.m3u8''';
      const media = '''#EXTM3U
#EXTINF:6.0,
c0.ts
#EXT-X-CUE-OUT:6.0
#EXTINF:6.0,
ad0.ts
#EXT-X-CUE-IN
#EXTINF:6.0,
c1.ts
#EXT-X-ENDLIST''';

      final client = MockClient((req) async {
        final p = req.url.path;
        if (p.endsWith('master.m3u8')) return http.Response(master, 200);
        if (p.endsWith('media.m3u8')) return http.Response(media, 200);
        return http.Response('not found', 404);
      });

      String? written;
      Future<String> writer(String contents, String name) async {
        written = contents;
        return 'file:///tmp/$name';
      }

      final got = await filterHlsAds(
        'https://cdn.example.com/vod/master.m3u8',
        client: client,
        writer: writer,
      );

      expect(got, startsWith('file:///tmp/'));
      expect(written, isNotNull);
      expect(written, isNot(contains('ad0.ts')));
      expect(written, contains('c0.ts'));
      expect(written, contains('c1.ts'));
    });

    test('returns null (plays original) when playlist has no ads', () async {
      const media = '''#EXTM3U
#EXTINF:6.0,
c0.ts
#EXT-X-ENDLIST''';
      final client = MockClient((req) async => http.Response(media, 200));
      final got = await filterHlsAds(
        'https://cdn.example.com/vod/clean.m3u8',
        client: client,
        writer: (c, n) async => 'file:///should-not-be-used',
      );
      expect(got, isNull);
    });
  });
}
