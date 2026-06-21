import 'package:http/http.dart' as http;

import 'adaptive_downloader.dart';
import 'progressive_downloader.dart';

/// Progress callback: [fraction] is 0..1, or null when the total size is not
/// yet known (indeterminate).
typedef DownloadProgress = void Function(double? fraction);

/// The single public entry point of the **video download module**.
///
/// This module ([lib/services/download]) is deliberately self-contained so it
/// can later be lifted into its own package:
///   * It depends only on `http` (+ `pointycastle`/`xml` for adaptive streams)
///     and the manifest helpers in `../hls_ad_filter.dart`.
///   * It knows nothing about the app's widgets, [BoardController] or models —
///     callers pass plain URLs and file paths.
///
/// Callers should use [VideoDownloader] rather than the lower-level
/// `downloadToFile` / `downloadAdaptiveStream` functions directly, so the
/// progressive-vs-adaptive decision and progress normalization live in one
/// place.
class VideoDownloader {
  const VideoDownloader();

  /// Whether [url] can be saved to a single file (progressive file *or* an
  /// HLS/DASH manifest we can assemble).
  bool canDownload(String url) =>
      isAdaptiveStream(url) || isDownloadableStream(url);

  /// A friendly, filesystem-safe file name derived from [title] and [url].
  String suggestName(String title, String url) => suggestFileName(title, url);

  /// Downloads [url] to [savePath], returning the path actually written. For
  /// adaptive streams the extension is corrected (`.ts`/`.mp4`) to match the
  /// assembled container, so the returned path may differ from [savePath].
  ///
  /// Pass a [client] to allow cancellation: closing it aborts the transfer.
  /// [onProgress] receives a normalized 0..1 fraction (or null when unknown).
  Future<String> download(
    String url,
    String savePath, {
    DownloadProgress? onProgress,
    http.Client? client,
  }) async {
    if (isAdaptiveStream(url)) {
      return downloadAdaptiveStream(
        url,
        savePath,
        client: client,
        onProgress: (done, total) =>
            onProgress?.call(total > 0 ? done / total : null),
      );
    }
    await downloadToFile(
      url,
      savePath,
      client: client,
      onProgress: (received, total) =>
          onProgress?.call(total != null && total > 0 ? received / total : null),
    );
    return savePath;
  }
}
