/// One selectable download quality for a video source.
///
/// Produced by the quality-listing helpers (YouTube muxed streams, HLS master
/// variants, DASH video representations) and consumed by
/// [VideoDownloader.downloadOption]. Carries everything the downloader needs to
/// fetch *this specific* quality.
class DownloadOption {
  const DownloadOption({
    required this.label,
    required this.url,
    required this.adaptive,
    this.height,
    this.bandwidth,
    this.dashBandwidth,
    this.ytdlpUrl,
    this.ytdlpFormat,
    this.impersonate = false,
    this.referer,
  });

  /// What the picker shows, e.g. `720p` or `1200 kbps`.
  final String label;

  /// The URL the downloader should fetch for this quality. For HLS this is the
  /// chosen variant's media-playlist URL; for DASH it's the manifest URL (the
  /// representation is selected via [dashBandwidth]); otherwise a direct file.
  final String url;

  /// Whether [url] is an adaptive manifest (HLS/DASH) needing segment assembly.
  final bool adaptive;

  /// Vertical resolution in pixels, when known (used for labelling/sorting).
  final int? height;

  /// Stream bitrate in bits/s, when known.
  final int? bandwidth;

  /// For DASH only: the bandwidth of the representation to download, so the
  /// manifest parser can pick exactly this quality instead of the best.
  final int? dashBandwidth;

  /// When set, this option is downloaded by **yt-dlp** (not the http path):
  /// [ytdlpUrl] is the original page URL and [ytdlpFormat] the yt-dlp format
  /// selector/id. Used for sites the built-in extractor can't reach.
  final String? ytdlpUrl;
  final String? ytdlpFormat;

  /// When true, yt-dlp impersonates a browser (TLS handshake + headers) to get
  /// past a Cloudflare-TLS block on the stream host, sending [referer] as the
  /// page the stream was found on (hotlink protection). Only meaningful
  /// together with [ytdlpUrl].
  final bool impersonate;
  final String? referer;

  /// True if this option must be fetched via yt-dlp.
  bool get isYtDlp => ytdlpUrl != null;
}
