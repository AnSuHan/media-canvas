// LIVE test for the bundled-yt-dlp path — proves the app can play and download
// videos from sites the built-in extractor can't reach (here: Vimeo, whose
// stream is behind JavaScript). Needs the binary at assets/bin/yt-dlp.exe and
// internet. Skipped by default. Run with:
//
//   flutter test test/live_ytdlp_test.dart --dart-define=LIVE=true

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:media_canvas/models/media_item.dart' show MediaKind;
import 'package:media_canvas/services/media_url_resolver.dart';
import 'package:media_canvas/services/ytdlp.dart';

const _live = bool.fromEnvironment('LIVE', defaultValue: false);

void _log(String s) {
  // ignore: avoid_print
  print(s);
}

void main() {
  // Point the resolver at the repo's bundled binary (in the packaged app it's
  // found automatically next to the executable).
  setUpAll(() {
    final repoBin =
        '${Directory.current.path}${Platform.pathSeparator}assets'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}yt-dlp.exe';
    setYtDlpExecutable(repoBin);
  });

  test('yt-dlp is bundled and runnable', () {
    expect(ytDlpAvailable(), isTrue,
        reason: 'run tool/fetch_ytdlp.ps1 to download assets/bin/yt-dlp.exe');
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');

  test('a JS-driven site (Vimeo) resolves to a playable stream via yt-dlp',
      () async {
    const page = 'https://vimeo.com/76979871'; // long-standing public clip
    final stream = await ytDlpResolveStream(page);
    expect(stream, isNotNull, reason: 'yt-dlp should extract a stream');
    expect(stream, startsWith('http'));

    // The resolved URL really serves bytes.
    final resp = await http.get(Uri.parse(stream!), headers: const {
      'Range': 'bytes=0-65535',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
    });
    expect(resp.statusCode, anyOf(200, 206));
    expect(resp.bodyBytes.isNotEmpty, isTrue);
    _log('vimeo resolved → ${stream.substring(0, 60)}…');
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');

  test('resolveMedia classifies a Vimeo page as video (via yt-dlp fallback)',
      () async {
    final r = await resolveMedia('https://vimeo.com/76979871');
    expect(r?.kind, MediaKind.video);
    _log('resolveMedia(vimeo) → ${r?.kind}');
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');

  test('yt-dlp lists downloadable progressive qualities for the page',
      () async {
    final opts = await ytDlpListOptions('https://vimeo.com/76979871');
    expect(opts, isNotEmpty);
    expect(opts.every((o) => o.isYtDlp), isTrue);
    _log('vimeo options → ${opts.map((o) => o.label).toList()}');
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');

  test('yt-dlp downloads the video to a real file', () async {
    final tmp = Directory.systemTemp.createTempSync('mc_ytdlp');
    final out = '${tmp.path}${Platform.pathSeparator}clip.mp4';
    var last = 0.0;
    final written = await ytDlpDownload(
      'https://vimeo.com/76979871',
      out,
      onProgress: (f) {
        if (f != null) last = f;
      },
    );
    final file = File(written);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(10000));
    _log('downloaded ${file.lengthSync()} bytes (progress→$last) → $written');
    tmp.deleteSync(recursive: true);
  }, skip: _live ? false : 'live (pass --dart-define=LIVE=true)');
}
