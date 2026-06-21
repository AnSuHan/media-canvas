import 'dart:io';

import 'package:http/http.dart' as http;

/// Downloads a resolved video stream to a local file.
///
/// Works on the *direct, progressive* stream URL produced by the resolver
/// (a YouTube muxed mp4, a plain .mp4/.webm, …). Adaptive manifests (HLS
/// `.m3u8` / DASH `.mpd`) are made of many separate segments and can't be saved
/// as one file without remuxing, so [isDownloadableStream] reports them as not
/// downloadable and the UI refuses them up front.

/// True if [url] is a single progressive file we can stream straight to disk.
/// False for adaptive manifests (HLS / DASH), which aren't one file.
bool isDownloadableStream(String url) {
  final u = url.toLowerCase();
  if (u.contains('.m3u8') || u.contains('.mpd')) return false;
  return u.startsWith('http');
}

/// Builds a friendly, filesystem-safe file name for the download from the
/// item's [title] and the stream [url] (used to guess the extension).
String suggestFileName(String title, String url) {
  var base = title.trim();
  if (base.isEmpty) base = 'video';
  // Strip characters illegal on Windows/Android file systems.
  base = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  if (base.isEmpty) base = 'video';

  final ext = _extensionFromUrl(url) ?? 'mp4';
  if (base.toLowerCase().endsWith('.$ext')) return base;
  return '$base.$ext';
}

String? _extensionFromUrl(String url) {
  Uri? uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return null;
  }
  final path = uri.path;
  final slash = path.lastIndexOf('/');
  final name = slash >= 0 ? path.substring(slash + 1) : path;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  final ext = name.substring(dot + 1).toLowerCase();
  // Only accept plausible media extensions; otherwise let the caller default.
  const known = {'mp4', 'm4v', 'webm', 'mkv', 'mov', 'avi', 'flv', 'ts'};
  return known.contains(ext) ? ext : null;
}

/// Streams [url] into the file at [savePath], reporting progress.
///
/// [onProgress] receives bytes-received and the total content length (null when
/// the server doesn't send Content-Length). Streaming chunk-by-chunk keeps even
/// a large video off the heap. Throws on a non-2xx response or I/O error.
Future<void> downloadToFile(
  String url,
  String savePath, {
  void Function(int received, int? total)? onProgress,
  http.Client? client,
}) async {
  final ownClient = client == null;
  final c = client ?? http.Client();
  IOSink? sink;
  try {
    final req = http.Request('GET', Uri.parse(url));
    req.headers['User-Agent'] =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';
    final resp = await c.send(req);
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      throw HttpException('Download failed (HTTP ${resp.statusCode})');
    }
    final total = resp.contentLength;
    var received = 0;
    sink = File(savePath).openWrite();
    await for (final chunk in resp.stream) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.flush();
  } finally {
    await sink?.close();
    if (ownClient) c.close();
  }
}
