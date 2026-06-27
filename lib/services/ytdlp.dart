import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'download/download_option.dart';

/// Drives the **bundled yt-dlp** binary so the app plays and downloads videos
/// from the ~1800 sites yt-dlp already supports (X/Twitter, TikTok, Facebook,
/// Vimeo, Twitch VODs, news embeds, …) — sites the built-in regex extractor
/// can't reach because they hide the stream behind JavaScript.
///
/// We don't reimplement any site logic: we shell out to yt-dlp and use whatever
/// it resolves. Keeping yt-dlp updated automatically widens support.
///
/// The executable ships next to the app under Flutter's asset tree
/// (`assets/bin/yt-dlp.exe`). Tests point [setYtDlpExecutable] at the repo copy.

String? _executableOverride;

/// Overrides the resolved yt-dlp path. Tests set this to the repo's
/// `assets/bin/yt-dlp.exe`; production leaves it null and the bundled copy is
/// located next to the app binary.
void setYtDlpExecutable(String? path) => _executableOverride = path;

/// Absolute path to the bundled yt-dlp executable, or null if not found.
///
/// In the packaged Windows app, declared assets are laid out on disk under
/// `<app dir>/data/flutter_assets/assets/bin/yt-dlp.exe`, so we can run it in
/// place without extracting anything.
String? ytDlpExecutable() {
  if (_executableOverride != null) return _executableOverride;
  if (!Platform.isWindows) return null; // only the Windows binary is bundled
  final dir = File(Platform.resolvedExecutable).parent.path;
  final sep = Platform.pathSeparator;
  final path =
      [dir, 'data', 'flutter_assets', 'assets', 'bin', 'yt-dlp.exe'].join(sep);
  return File(path).existsSync() ? path : null;
}

/// True if the bundled yt-dlp is present and runnable.
bool ytDlpAvailable() => ytDlpExecutable() != null;

const _baseArgs = ['--no-playlist', '--no-warnings'];

/// Picks a *single-file* (progressive, muxed) format so playback has audio and
/// downloads need no ffmpeg merge. Falls back through best-with-audio to best.
const _muxedFormat = 'best[ext=mp4]/best[acodec!=none][vcodec!=none]/best';

/// Resolves [url] to a direct stream URL libmpv can open, using yt-dlp. Returns
/// null when yt-dlp is unavailable or can't extract a stream.
///
/// Prefers a muxed format and, if yt-dlp prints separate video+audio lines,
/// takes the first so we hand the player one playable URL.
Future<String?> ytDlpResolveStream(String url) async {
  final exe = ytDlpExecutable();
  if (exe == null) return null;
  try {
    final res = await Process.run(
      exe,
      [..._baseArgs, '-f', _muxedFormat, '-g', url],
    ).timeout(const Duration(seconds: 30));
    if (res.exitCode != 0) return null;
    final out = (res.stdout as String).trim();
    if (out.isEmpty) return null;
    return out.split(RegExp(r'[\r\n]+')).first.trim();
  } catch (_) {
    return null;
  }
}

/// Lists the downloadable single-file qualities yt-dlp sees for [url], best
/// first. Each option carries the page URL + yt-dlp format id so the download
/// is performed by yt-dlp itself (see [ytDlpDownload]). Returns an empty list
/// when yt-dlp is unavailable or the link isn't a yt-dlp-supported video.
Future<List<DownloadOption>> ytDlpListOptions(String url) async {
  final exe = ytDlpExecutable();
  if (exe == null) return const [];
  Map<String, dynamic> info;
  try {
    final res = await Process.run(exe, [..._baseArgs, '-J', url])
        .timeout(const Duration(seconds: 30));
    if (res.exitCode != 0) return const [];
    info = jsonDecode(res.stdout as String) as Map<String, dynamic>;
  } catch (_) {
    return const [];
  }

  final formats = (info['formats'] as List?) ?? const [];
  final options = <DownloadOption>[];
  final seenHeights = <int>{};
  // Progressive formats only (both audio and video in one file) so we never
  // need ffmpeg to merge. Highest resolution first.
  final progressive = formats
      .whereType<Map<String, dynamic>>()
      .where((f) =>
          f['vcodec'] != null &&
          f['vcodec'] != 'none' &&
          f['acodec'] != null &&
          f['acodec'] != 'none')
      .toList()
    ..sort((a, b) => ((b['height'] as num?) ?? 0).compareTo((a['height'] as num?) ?? 0));

  for (final f in progressive) {
    final h = (f['height'] as num?)?.toInt();
    final id = f['format_id']?.toString();
    if (id == null) continue;
    final label = h != null ? '${h}p' : (f['format_note']?.toString() ?? id);
    if (h != null && !seenHeights.add(h)) continue; // dedupe by resolution
    options.add(DownloadOption(
      label: label,
      url: url,
      adaptive: false,
      height: h,
      ytdlpUrl: url,
      ytdlpFormat: id,
    ));
  }

  // Always offer a safe "best available" fallback (covers sites that expose no
  // explicit progressive list, e.g. a single muxed mp4).
  if (options.isEmpty) {
    options.add(DownloadOption(
      label: '원본',
      url: url,
      adaptive: false,
      ytdlpUrl: url,
      ytdlpFormat: _muxedFormat,
    ));
  }
  return options;
}

/// Progress callback for a yt-dlp download: [fraction] is 0..1, or null while
/// indeterminate.
typedef YtDlpProgress = void Function(double? fraction);

/// Downloads [url] to [savePath] with yt-dlp using [format] (a format id or
/// selector), returning the path written. Streams progress parsed from
/// yt-dlp's `--newline` output.
///
/// [onStart] receives the spawned [Process] so the caller can kill it to cancel
/// (mirrors how the http path cancels by closing its client).
Future<String> ytDlpDownload(
  String url,
  String savePath, {
  String? format,
  YtDlpProgress? onProgress,
  void Function(Process proc)? onStart,
}) async {
  final exe = ytDlpExecutable();
  if (exe == null) {
    throw const ProcessException('yt-dlp', [], 'yt-dlp is not available', 1);
  }
  final fmt = format ?? _muxedFormat;
  final proc = await Process.start(exe, [
    ..._baseArgs,
    '--newline',
    '--no-part',
    '-f', fmt,
    '-o', savePath,
    url,
  ]);
  onStart?.call(proc);

  final pct = RegExp(r'\[download\]\s+([\d.]+)%');
  final stderrBuf = StringBuffer();
  proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final m = pct.firstMatch(line);
    if (m != null) {
      final v = double.tryParse(m.group(1)!);
      if (v != null) onProgress?.call(v / 100);
    }
  });
  proc.stderr.transform(utf8.decoder).listen(stderrBuf.write);

  final code = await proc.exitCode;
  if (code != 0) {
    throw ProcessException('yt-dlp', ['-f', fmt, url],
        stderrBuf.isEmpty ? 'download failed' : stderrBuf.toString().trim(), code);
  }
  return savePath;
}
