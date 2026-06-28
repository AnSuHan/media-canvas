// Offline unit tests for the local streaming proxy. They never run the real
// yt-dlp binary — they pin the two behaviors that don't need it: a graceful
// null when yt-dlp isn't bundled (so the app just hands libmpv the raw URL),
// and a well-formed loopback URL once a stream is registered. The real
// libmpv⇄yt-dlp piping is covered live in live_protected_vod_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:media_canvas/services/stream_proxy.dart';
import 'package:media_canvas/services/ytdlp.dart';

void main() {
  tearDown(() async {
    await StreamProxy.instance.shutdown();
    setYtDlpExecutable(null);
  });

  test('proxiedUrl returns null when yt-dlp is unavailable', () async {
    setYtDlpExecutable(null);
    final url = await StreamProxy.instance
        .proxiedUrl(streamUrl: 'https://cdn.example/master.m3u8');
    expect(url, isNull);
  });

  test('proxiedUrl returns a loopback URL once yt-dlp is "available"',
      () async {
    // A path that exists is enough for ytDlpAvailable(); no request is made
    // here, so the fake binary is never actually executed.
    setYtDlpExecutable('${Directory.current.path}/pubspec.yaml');
    final url = await StreamProxy.instance.proxiedUrl(
      streamUrl: 'https://cdn.example/master.m3u8',
      referer: 'https://example.tv/vod/1',
    );
    expect(url, isNotNull);
    expect(url, matches(RegExp(r'^http://127\.0\.0\.1:\d+/s/\d+$')));
  });
}
