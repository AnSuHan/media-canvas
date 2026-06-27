// Offline unit tests for the yt-dlp service wrapper. These never run the real
// binary — they pin the executable-location logic and the graceful behavior
// when yt-dlp isn't bundled (so the app degrades to the built-in path instead
// of crashing). Live, binary-backed coverage is in live_ytdlp_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:media_canvas/services/ytdlp.dart';

void main() {
  tearDown(() => setYtDlpExecutable(null));

  test('unavailable by default in the test runner (no bundled binary)', () {
    setYtDlpExecutable(null);
    expect(ytDlpAvailable(), isFalse);
  });

  test('setYtDlpExecutable makes it report available', () {
    setYtDlpExecutable('C:\\does\\not\\matter\\yt-dlp.exe');
    expect(ytDlpAvailable(), isTrue);
    setYtDlpExecutable(null);
    expect(ytDlpAvailable(), isFalse);
  });

  group('graceful no-op when yt-dlp is unavailable', () {
    setUp(() => setYtDlpExecutable(null));

    test('ytDlpResolveStream returns null (caller falls back)', () async {
      expect(await ytDlpResolveStream('https://x.example/whatever'), isNull);
    });

    test('ytDlpListOptions returns an empty list', () async {
      expect(await ytDlpListOptions('https://x.example/whatever'), isEmpty);
    });

    test('ytDlpDownload throws a ProcessException (nothing to run)', () async {
      expect(
        () => ytDlpDownload('https://x.example/whatever', 'out.mp4'),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}
