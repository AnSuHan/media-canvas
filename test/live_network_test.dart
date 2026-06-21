// LIVE network test — hits the real internet to prove the resolver returns a
// genuinely playable stream for real-world links. Skipped by default (needs
// internet + remote services up). Run explicitly with:
//
//   flutter test test/live_network_test.dart --dart-define=LIVE=1
//
// It (1) resolves a real link to a direct stream URL via the same code path the
// app uses, then (2) actually fetches the first bytes of that stream to confirm
// it serves video.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'dart:io';

import 'package:media_canvas/services/download/download.dart';
import 'package:media_canvas/services/hls_ad_filter.dart';
import 'package:media_canvas/services/media_url_resolver.dart';

const _live = bool.fromEnvironment('LIVE', defaultValue: false);

Future<void> _expectStreamsVideo(String url) async {
  final resp = await http.get(
    Uri.parse(url),
    // Ask for just the first 64 KB so we don't download the whole file.
    headers: const {
      'Range': 'bytes=0-65535',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
    },
  );
  expect(resp.statusCode, anyOf(200, 206),
      reason: 'stream URL should be fetchable: $url');
  expect(resp.bodyBytes.isNotEmpty, isTrue, reason: 'stream returned no bytes');
  final ct = (resp.headers['content-type'] ?? '').toLowerCase();
  expect(
    ct.startsWith('video/') ||
        ct.contains('mp4') ||
        ct.contains('octet-stream') ||
        ct.contains('mpegurl'),
    isTrue,
    reason: 'unexpected content-type "$ct" for $url',
  );
}

void main() {
  test('resolves a real YouTube link to a playable stream', () async {
    // "Me at the zoo" — the very first YouTube video; about as permanent as a
    // YouTube URL gets.
    const watch = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';
    final stream = await resolvePlayableUrl(watch);

    expect(stream, isNot(watch), reason: 'should resolve to a direct stream');
    expect(stream, contains('googlevideo.com'));
    await _expectStreamsVideo(stream);
    // ignore: avoid_print
    print('YouTube resolved → ${stream.substring(0, 60)}…');
  }, skip: _live ? false : 'live network test (pass --dart-define=LIVE=1)');

  test('passes a real direct .mp4 through and it streams', () async {
    // A long-standing public sample clip that supports range requests.
    const mp4 = 'https://www.w3schools.com/html/mov_bbb.mp4';
    final stream = await resolvePlayableUrl(mp4);

    expect(stream, mp4, reason: 'a direct mp4 needs no resolution');
    await _expectStreamsVideo(stream);
  }, skip: _live ? false : 'live network test (pass --dart-define=LIVE=1)');

  test('runs the HLS ad pipeline on a real master playlist', () async {
    // A real multi-bitrate HLS master. It carries no SSAI ad markers, so the
    // filter should cleanly decide there's nothing to strip (returns null) —
    // proving the real fetch + master-variant selection path works without
    // breaking an ordinary stream. We test the strip logic itself with crafted
    // playlists in hls_ad_filter_test.dart.
    const master = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

    // Variant selection against the real master.
    final resp = await http.get(Uri.parse(master));
    final variant = selectVariant(resp.body, Uri.parse(master));
    expect(variant, isNotNull);
    expect(variant, startsWith('https://test-streams.mux.dev/x36xhzz/'));

    // The full pipeline returns null (no ads to strip) and never throws.
    final filtered = await filterHlsAds(master);
    expect(filtered, isNull);
    // ignore: avoid_print
    print('HLS variant selected → $variant');
  }, skip: _live ? false : 'live network test (pass --dart-define=LIVE=1)');

  test('downloads a real video to a file', () async {
    const mp4 = 'https://www.w3schools.com/html/mov_bbb.mp4';
    expect(isDownloadableStream(mp4), isTrue);

    final tmp = Directory.systemTemp.createTempSync('mc_live_dl');
    final out = '${tmp.path}${Platform.pathSeparator}bbb.mp4';
    var lastPct = 0.0;
    await downloadToFile(
      mp4,
      out,
      onProgress: (received, total) {
        if (total != null && total > 0) lastPct = received / total;
      },
    );

    final file = File(out);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(10000));
    expect(lastPct, 1.0);
    // ignore: avoid_print
    print('downloaded ${file.lengthSync()} bytes → $out');
    tmp.deleteSync(recursive: true);
  }, skip: _live ? false : 'live network test (pass --dart-define=LIVE=1)');

  test('parses a real HLS playlist and fetches real TS segments', () async {
    // Real master → our variant pick → real media playlist → real segments.
    const master = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
    final variant =
        selectVariant((await http.get(Uri.parse(master))).body, Uri.parse(master));
    expect(variant, isNotNull);

    final mediaText = (await http.get(Uri.parse(variant!))).body;
    final plan = parseHlsMediaPlaylist(mediaText, Uri.parse(variant));
    expect(plan.segments.length, greaterThan(1));

    // Fetch the first two real segments and confirm they're MPEG-TS
    // (every TS packet starts with the 0x47 sync byte).
    for (final seg in plan.segments.take(2)) {
      final bytes = (await http.get(seg.uri)).bodyBytes;
      expect(bytes.isNotEmpty, isTrue);
      expect(bytes.first, 0x47, reason: 'TS sync byte for ${seg.uri}');
    }
    // ignore: avoid_print
    print('HLS: ${plan.segments.length} real segments, TS verified');
  }, skip: _live ? false : 'live network test (pass --dart-define=LIVE=1)');
}
