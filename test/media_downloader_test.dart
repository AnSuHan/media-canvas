// Unit tests for the video downloader. Pure-function checks plus a streamed
// download into a real temp file using a mocked HTTP client.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:media_canvas/services/download/download.dart';

void main() {
  group('isDownloadableStream', () {
    test('accepts progressive http(s) files', () {
      expect(isDownloadableStream('https://x.com/a/clip.mp4'), isTrue);
      expect(isDownloadableStream('http://x.com/v.webm'), isTrue);
      expect(isDownloadableStream('https://x.com/stream'), isTrue);
    });

    test('rejects adaptive manifests (HLS / DASH)', () {
      expect(isDownloadableStream('https://x.com/master.m3u8'), isFalse);
      expect(isDownloadableStream('https://x.com/manifest.mpd?x=1'), isFalse);
    });

    test('rejects non-http schemes', () {
      expect(isDownloadableStream('ftp://x.com/a.mp4'), isFalse);
      expect(isDownloadableStream('file:///c:/a.mp4'), isFalse);
    });
  });

  group('suggestFileName', () {
    test('uses the title and keeps the URL extension', () {
      expect(suggestFileName('My Clip', 'https://x.com/v.webm'), 'My Clip.webm');
    });

    test('defaults to .mp4 when the URL has no usable extension', () {
      expect(suggestFileName('Trailer', 'https://x.com/watch?v=abc'),
          'Trailer.mp4');
    });

    test('sanitizes filesystem-illegal characters', () {
      expect(suggestFileName('a/b:c*?', 'https://x.com/v.mp4'), 'a_b_c__.mp4');
    });

    test('falls back to "video" for an empty title', () {
      expect(suggestFileName('   ', 'https://x.com/v.mp4'), 'video.mp4');
    });

    test('does not double up an extension already present', () {
      expect(suggestFileName('clip.mp4', 'https://x.com/v.mp4'), 'clip.mp4');
    });
  });

  group('downloadToFile', () {
    test('streams the body to disk and reports progress', () async {
      final payload =
          List<int>.generate(1000, (i) => i % 256, growable: false);
      final client = MockClient.streaming((req, body) async {
        return http.StreamedResponse(
          Stream.fromIterable([payload.sublist(0, 400), payload.sublist(400)]),
          200,
          contentLength: payload.length,
        );
      });

      final tmp = Directory.systemTemp.createTempSync('mc_dl_test');
      final out = '${tmp.path}${Platform.pathSeparator}out.mp4';
      final progress = <double>[];

      await downloadToFile(
        'https://x.com/v.mp4',
        out,
        client: client,
        onProgress: (received, total) {
          if (total != null) progress.add(received / total);
        },
      );

      final file = File(out);
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), payload.length);
      expect(file.readAsBytesSync(), payload);
      expect(progress.last, 1.0);

      tmp.deleteSync(recursive: true);
    });

    test('throws on a non-2xx response', () async {
      final client = MockClient.streaming((req, body) async =>
          http.StreamedResponse(const Stream.empty(), 404));
      final tmp = Directory.systemTemp.createTempSync('mc_dl_test');
      final out = '${tmp.path}${Platform.pathSeparator}fail.mp4';

      expect(
        () => downloadToFile('https://x.com/v.mp4', out, client: client),
        throwsA(isA<HttpException>()),
      );

      tmp.deleteSync(recursive: true);
    });
  });
}
