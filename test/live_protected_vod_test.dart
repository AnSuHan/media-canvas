// LIVE end-to-end test for the Cloudflare-TLS-protected VOD path — the exact
// thing this feature exists for. For a protected VOD page it proves the app
// can:
//   1. resolve the page to its embedded stream and detect it needs browser
//      impersonation (libmpv/Dart http would be 403'd),
//   2. PLAY it: the local proxy pipes a real MPEG-TS byte stream (begins with
//      the 0x47 sync byte) that libmpv can open over localhost,
//   3. DOWNLOAD it: yt-dlp with --impersonate + Referer writes real bytes.
//
// Needs assets/bin/yt-dlp.exe, internet, and (region-permitting) a VPN to the
// site. You supply the page to test — no URL is hard-coded. Skipped unless both
// LIVE and a VOD_URL are given. Run with:
//
//   flutter test test/live_protected_vod_test.dart \
//     --dart-define=LIVE=true --dart-define=VOD_URL=https://<vod-site>/vod/<id>

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:media_canvas/services/page_video_resolver.dart';
import 'package:media_canvas/services/stream_proxy.dart';
import 'package:media_canvas/services/ytdlp.dart';

const _live = bool.fromEnvironment('LIVE', defaultValue: false);
const _page = String.fromEnvironment('VOD_URL', defaultValue: '');

/// Run a live case only when LIVE is set *and* a page URL was supplied.
String? get _skip => _live && _page.isNotEmpty
    ? null
    : 'live (pass --dart-define=LIVE=true --dart-define=VOD_URL=...)';

void _log(String s) {
  // ignore: avoid_print
  print(s);
}

void main() {
  setUpAll(() {
    final repoBin = '${Directory.current.path}${Platform.pathSeparator}assets'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}yt-dlp.exe';
    setYtDlpExecutable(repoBin);
  });

  tearDownAll(() async => StreamProxy.instance.shutdown());

  test('yt-dlp is bundled and runnable', () {
    expect(ytDlpAvailable(), isTrue,
        reason: 'run tool/fetch_ytdlp.ps1 to download assets/bin/yt-dlp.exe');
  }, skip: _skip);

  test('resolves the VOD page to a protected stream', () async {
    final src = await resolveVideoSource(_page);
    expect(src, isNotNull, reason: 'should find a stream on the page');
    _log('stream: ${src!.streamUrl}');
    expect(src.streamUrl, contains('.m3u8'));
    expect(src.needsImpersonation, isTrue,
        reason: 'this CDN 403s non-browser clients');
    expect(src.referer, _page);
  }, skip: _skip);

  test('PLAY: the local proxy serves a real MPEG-TS stream', () async {
    final src = await resolveVideoSource(_page);
    expect(src, isNotNull);

    final proxyUrl = await StreamProxy.instance.proxiedUrl(
      streamUrl: src!.streamUrl,
      referer: src.referer,
    );
    expect(proxyUrl, isNotNull, reason: 'proxy needs the bundled yt-dlp');
    _log('proxy: $proxyUrl');

    // Stream the response and grab the first chunk libmpv would see.
    final client = http.Client();
    final req = http.Request('GET', Uri.parse(proxyUrl!));
    final resp = await client.send(req).timeout(const Duration(seconds: 40));
    expect(resp.statusCode, 200);

    final firstChunk = await resp.stream
        .firstWhere((c) => c.isNotEmpty)
        .timeout(const Duration(seconds: 40));
    client.close(); // disconnect → proxy kills yt-dlp

    // 0x47 is the MPEG-TS sync byte; libmpv recognizes the container from it.
    expect(firstChunk.first, 0x47,
        reason: 'proxied bytes should be a playable MPEG-TS stream');
    _log('first ${firstChunk.length} bytes ok (TS sync 0x47)');
  }, skip: _skip);

  test('DOWNLOAD: yt-dlp impersonate+referer writes real bytes', () async {
    final src = await resolveVideoSource(_page);
    expect(src, isNotNull);

    final dir = await Directory.systemTemp.createTemp('mc_vod_dl');
    final out = '${dir.path}${Platform.pathSeparator}clip.mp4';

    Process? proc;
    // Cancel once enough has landed to prove the transfer works (the full VOD
    // is tens of MB; we don't need all of it for the assertion).
    var progressed = false;
    try {
      await ytDlpDownload(
        src!.streamUrl,
        out,
        format: 'best',
        impersonate: true,
        referer: src.referer,
        onStart: (p) => proc = p,
        onProgress: (f) {
          if (f != null && f > 0.05 && !progressed) {
            progressed = true;
            proc?.kill(); // stop early; partial file is enough
          }
        },
      );
    } catch (_) {
      // A kill mid-download surfaces as a ProcessException — expected.
    }
    // Wait for the killed process to fully exit so it releases the file handle
    // before we measure / clean up (Windows locks the file until then).
    try {
      await proc?.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {}

    final file = File(out);
    expect(await file.exists(), isTrue, reason: 'a (partial) file was written');
    final len = await file.length();
    _log('downloaded $len bytes to $out');
    expect(len, greaterThan(100 * 1024),
        reason: 'should have pulled real video bytes');

    // Best-effort cleanup; a lingering OS lock shouldn't fail the test.
    for (var i = 0; i < 5; i++) {
      try {
        await dir.delete(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)), skip: _skip);
}
