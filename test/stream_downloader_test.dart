// Unit tests for the adaptive (HLS / DASH) stream downloader. Pure parsing and
// crypto checks plus a mocked end-to-end assembly into a temp file.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart';

import 'package:media_canvas/services/download/download.dart';

void main() {
  group('isAdaptiveStream', () {
    test('detects HLS and DASH manifests', () {
      expect(isAdaptiveStream('https://x/a.m3u8'), isTrue);
      expect(isAdaptiveStream('https://x/a.mpd?t=1'), isTrue);
      expect(isAdaptiveStream('https://x/a.mp4'), isFalse);
    });
  });

  group('parseHlsMediaPlaylist', () {
    final base = Uri.parse('https://cdn.example.com/v/index.m3u8');

    test('lists TS segments, absolutized, no init', () {
      const pl = '''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:6.0,
seg0.ts
#EXTINF:6.0,
seg1.ts
#EXT-X-ENDLIST''';
      final plan = parseHlsMediaPlaylist(pl, base);
      expect(plan.isFmp4, isFalse);
      expect(plan.initUri, isNull);
      expect(plan.segments.map((s) => s.uri.toString()), [
        'https://cdn.example.com/v/seg0.ts',
        'https://cdn.example.com/v/seg1.ts',
      ]);
    });

    test('captures an fMP4 init segment (EXT-X-MAP)', () {
      const pl = '''#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:6.0,
seg0.m4s
#EXT-X-ENDLIST''';
      final plan = parseHlsMediaPlaylist(pl, base);
      expect(plan.isFmp4, isTrue);
      expect(plan.initUri.toString(), 'https://cdn.example.com/v/init.mp4');
    });

    test('attaches AES-128 key + sequence numbers to segments', () {
      const pl = '''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:10
#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/key.bin"
#EXTINF:6.0,
seg0.ts
#EXTINF:6.0,
seg1.ts
#EXT-X-ENDLIST''';
      final plan = parseHlsMediaPlaylist(pl, base);
      expect(plan.segments[0].key!.method, 'AES-128');
      expect(plan.segments[0].key!.uri.toString(),
          'https://cdn.example.com/key.bin');
      expect(plan.segments[0].seq, 10);
      expect(plan.segments[1].seq, 11);
    });
  });

  group('AES-128 + IV helpers', () {
    test('ivFromSequence is 16-byte big-endian', () {
      final iv = ivFromSequence(0x0102);
      expect(iv.length, 16);
      expect(iv[14], 0x01);
      expect(iv[15], 0x02);
    });

    test('hexToBytes decodes a 0x-prefixed string', () {
      expect(hexToBytes('0x00ff10'), [0x00, 0xff, 0x10]);
    });

    test('aes128CbcDecrypt reverses AES-128-CBC + PKCS7', () {
      final key = Uint8List.fromList(List.generate(16, (i) => i));
      final iv = Uint8List.fromList(List.generate(16, (i) => 16 - i));
      final plain = Uint8List.fromList(
          List.generate(20, (i) => i)); // not block-aligned → padded

      // Encrypt with PKCS7 padding using the same primitive.
      final enc = PaddedBlockCipher('AES/CBC/PKCS7')
        ..init(true,
            PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), iv), null));
      final cipherText = enc.process(plain);

      final out = aes128CbcDecrypt(cipherText, key, iv);
      expect(out, plain);
    });
  });

  group('parseDashManifest', () {
    final base = Uri.parse('https://cdn.example.com/dash/manifest.mpd');

    test('SegmentTemplate with SegmentTimeline', () {
      const mpd = '''<?xml version="1.0"?>
<MPD mediaPresentationDuration="PT12S">
  <Period>
    <AdaptationSet contentType="video">
      <Representation id="v0" bandwidth="800000"/>
      <Representation id="v1" bandwidth="2400000">
        <SegmentTemplate initialization="init-\$RepresentationID\$.mp4"
                         media="seg-\$RepresentationID\$-\$Number\$.m4s"
                         startNumber="1">
          <SegmentTimeline>
            <S t="0" d="6" r="1"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';
      final plan = parseDashManifest(mpd, base);
      // Picks the higher-bandwidth representation v1.
      expect(plan.initUri.toString(),
          'https://cdn.example.com/dash/init-v1.mp4');
      expect(plan.segments.map((u) => u.toString()), [
        'https://cdn.example.com/dash/seg-v1-1.m4s',
        'https://cdn.example.com/dash/seg-v1-2.m4s',
      ]);
    });

    test('SegmentTemplate with number padding + duration', () {
      const mpd = '''<?xml version="1.0"?>
<MPD mediaPresentationDuration="PT18S">
  <Period>
    <AdaptationSet mimeType="video/mp4">
      <Representation id="v" bandwidth="1000000">
        <SegmentTemplate initialization="init.mp4"
                         media="chunk-\$Number%05d\$.m4s"
                         timescale="1" duration="6" startNumber="1"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';
      final plan = parseDashManifest(mpd, base);
      expect(plan.segments.length, 3); // 18s / 6s
      expect(plan.segments.first.toString(),
          'https://cdn.example.com/dash/chunk-00001.m4s');
    });

    test('SegmentList', () {
      const mpd = '''<?xml version="1.0"?>
<MPD>
  <Period>
    <AdaptationSet contentType="video">
      <Representation id="v" bandwidth="500000">
        <SegmentList>
          <Initialization sourceURL="init.mp4"/>
          <SegmentURL media="s0.m4s"/>
          <SegmentURL media="s1.m4s"/>
        </SegmentList>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';
      final plan = parseDashManifest(mpd, base);
      expect(plan.initUri.toString(), 'https://cdn.example.com/dash/init.mp4');
      expect(plan.segments.length, 2);
    });

    test('honors BaseURL chains', () {
      const mpd = '''<?xml version="1.0"?>
<MPD>
  <BaseURL>cdn/</BaseURL>
  <Period>
    <AdaptationSet contentType="video">
      <Representation id="v" bandwidth="500000">
        <BaseURL>v0/</BaseURL>
        <SegmentList>
          <SegmentURL media="s0.m4s"/>
        </SegmentList>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';
      final plan = parseDashManifest(mpd, base);
      expect(plan.segments.first.toString(),
          'https://cdn.example.com/dash/cdn/v0/s0.m4s');
    });
  });

  group('downloadAdaptiveStream (HLS end-to-end)', () {
    test('master → variant → concatenated TS file', () async {
      const master = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000000
media.m3u8''';
      const media = '''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:6.0,
a.ts
#EXTINF:6.0,
b.ts
#EXT-X-ENDLIST''';

      final client = MockClient((req) async {
        final p = req.url.path;
        if (p.endsWith('master.m3u8')) return http.Response(master, 200);
        if (p.endsWith('media.m3u8')) return http.Response(media, 200);
        if (p.endsWith('a.ts')) {
          return http.Response.bytes([1, 2, 3], 200);
        }
        if (p.endsWith('b.ts')) {
          return http.Response.bytes([4, 5, 6], 200);
        }
        return http.Response('nf', 404);
      });

      final tmp = Directory.systemTemp.createTempSync('mc_hls_dl');
      final out = '${tmp.path}${Platform.pathSeparator}video.mp4';
      final progress = <double>[];

      final written = await downloadAdaptiveStream(
        'https://cdn.example.com/vod/master.m3u8',
        out,
        client: client,
        onProgress: (d, t) => progress.add(d / t),
      );

      // TS segments → extension corrected to .ts.
      expect(written, endsWith('.ts'));
      final bytes = File(written).readAsBytesSync();
      expect(bytes, [1, 2, 3, 4, 5, 6]);
      expect(progress.last, 1.0);

      tmp.deleteSync(recursive: true);
    });

    test('decrypts AES-128 segments while assembling', () async {
      final key = Uint8List.fromList(List.generate(16, (i) => i + 1));
      final iv = ivFromSequence(0); // first segment, seq 0

      final plain = Uint8List.fromList(List.generate(32, (i) => i));
      final enc = PaddedBlockCipher('AES/CBC/PKCS7')
        ..init(true,
            PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), iv), null));
      final cipherText = enc.process(plain);

      const media = '''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/vod/key.bin"
#EXTINF:6.0,
enc.ts
#EXT-X-ENDLIST''';

      final client = MockClient((req) async {
        final p = req.url.path;
        if (p.endsWith('media.m3u8')) return http.Response(media, 200);
        if (p.endsWith('key.bin')) return http.Response.bytes(key, 200);
        if (p.endsWith('enc.ts')) return http.Response.bytes(cipherText, 200);
        return http.Response('nf', 404);
      });

      final tmp = Directory.systemTemp.createTempSync('mc_hls_aes');
      final out = '${tmp.path}${Platform.pathSeparator}v.mp4';
      final written = await downloadAdaptiveStream(
        'https://cdn.example.com/vod/media.m3u8',
        out,
        client: client,
        stripAds: false,
      );

      expect(File(written).readAsBytesSync(), plain);
      tmp.deleteSync(recursive: true);
    });
  });
}
