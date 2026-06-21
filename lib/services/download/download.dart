/// Video download module.
///
/// A self-contained unit for saving network videos to disk — progressive files
/// and adaptive (HLS / DASH) streams alike. Import this barrel; prefer the
/// [VideoDownloader] facade over the lower-level functions.
///
/// Module boundary (for a future extraction into its own package):
///   * External deps: `http`, `pointycastle`, `xml`.
///   * Internal dep: `../hls_ad_filter.dart` (HLS manifest helpers, shared with
///     playback). Pull that along when extracting.
///   * No dependency on app widgets, controllers or models.
library;

export 'adaptive_downloader.dart';
export 'progressive_downloader.dart';
export 'video_downloader.dart';
