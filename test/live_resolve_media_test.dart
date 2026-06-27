// LIVE network test for resolveMedia — proves that arbitrary real-world links
// are classified into the right media kind (video / image / gif) and that the
// resulting stream is actually playable and (for video) downloadable, so the
// app never hands an image or a plain page to the video engine. Skipped by
// default. Run explicitly with:
//
//   flutter test test/live_resolve_media_test.dart --dart-define=LIVE=true

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:media_canvas/models/media_item.dart' show MediaKind;
import 'package:media_canvas/services/download/download.dart';
import 'package:media_canvas/services/media_url_resolver.dart';

const _live = bool.fromEnvironment('LIVE', defaultValue: false);

Future<http.Response> _head64k(String url) => http.get(
      Uri.parse(url),
      headers: const {
        'Range': 'bytes=0-65535',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
      },
    );

void _log(String s) {
  // ignore: avoid_print
  print(s);
}

void main() {
  test('direct .mp4 → video, plays + is downloadable', () async {
    const url = 'https://www.w3schools.com/html/mov_bbb.mp4';
    final r = await resolveMedia(url);
    expect(r?.kind, MediaKind.video);

    final stream = await resolvePlayableUrl(url); // playback path
    final resp = await _head64k(stream);
    expect(resp.statusCode, anyOf(200, 206));
    expect(isDownloadableStream(stream), isTrue); // download path
    _log('mp4   → ${r?.kind} | playable + downloadable ✓');
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');

  test('HLS .m3u8 stream → video, plays + is downloadable', () async {
    const url = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
    final r = await resolveMedia(url);
    expect(r?.kind, MediaKind.video);

    final stream = await resolvePlayableUrl(url);
    final resp = await _head64k(stream);
    expect(resp.statusCode, anyOf(200, 206));
    final ct = (resp.headers['content-type'] ?? '').toLowerCase();
    expect(ct.contains('mpegurl') || ct.contains('octet-stream'), isTrue,
        reason: 'HLS playlist content-type was "$ct"');
    expect(isAdaptiveStream(stream), isTrue); // adaptive download path
    _log('m3u8  → ${r?.kind} | streams + adaptive-downloadable ✓');
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');

  test('DASH .mpd stream → video, adaptive-downloadable', () async {
    const url = 'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd';
    final r = await resolveMedia(url);
    expect(r?.kind, MediaKind.video);
    expect(isAdaptiveStream(url), isTrue);
    _log('mpd   → ${r?.kind} | adaptive-downloadable ✓');
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');

  test('a direct image link → image (not fed to the video engine)', () async {
    const url = 'https://www.w3schools.com/w3images/lights.jpg';
    final r = await resolveMedia(url);
    expect(r?.kind, MediaKind.image);
    final resp = await _head64k(url);
    expect((resp.headers['content-type'] ?? '').toLowerCase(),
        startsWith('image/'));
    _log('jpg   → ${r?.kind} | served as image ✓');
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');

  test('a .gif link → gif', () async {
    const url =
        'https://upload.wikimedia.org/wikipedia/commons/2/2c/Rotating_earth_%28large%29.gif';
    final r = await resolveMedia(url);
    expect(r?.kind, MediaKind.gif);
    _log('gif   → ${r?.kind} ✓');
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');

  test('a YouTube watch link → video (original URL kept as source)', () async {
    const url = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';
    final r = await resolveMedia(url);
    expect(r?.kind, MediaKind.video);
    expect(r?.url, url, reason: 'source stays the watch URL for re-resolution');
    _log('yt    → ${r?.kind} ✓');
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');

  test('a plain web page with no video → falls back to its preview image',
      () async {
    // A GitHub repo page has a social-preview og:image and no embedded <video>.
    // Previously such a page would be forced into the video engine and error
    // with "unsupported format"; now it resolves to the preview image so
    // something renders instead.
    const url = 'https://github.com/dart-lang/sdk';
    final r = await resolveMedia(url);
    expect(r?.kind, anyOf(MediaKind.image, MediaKind.gif),
        reason: 'a page with no video should fall back to its preview image');
    expect(r?.url, isNot(url), reason: 'should be the resolved image, not the page');
    final resp = await _head64k(r!.url);
    expect((resp.headers['content-type'] ?? '').toLowerCase(),
        startsWith('image/'));
    _log('page  → ${r.kind} | og:image fallback ✓ (${r.url})');
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');

  test('a non-media https link does not crash and is unclassified-safe',
      () async {
    // example.com has no og:image and no video → resolveMedia returns null and
    // the app honors the manual kind instead of throwing.
    const url = 'https://example.com/';
    final r = await resolveMedia(url);
    expect(r == null || r.kind == MediaKind.image, isTrue);
    _log('plain → ${r?.kind ?? "null (honors manual choice)"} ✓');
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');
}
