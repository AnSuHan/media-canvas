import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Helpers for turning a YouTube page/share link into a direct media URL that
/// libmpv (media_kit) can open.
///
/// libmpv can only play a YouTube watch URL if yt-dlp is installed alongside
/// it — which it is not, on a packaged app. So we resolve the stream URL in
/// pure Dart with `youtube_explode_dart` and hand the resulting direct URL to
/// the player. The board always stores the *original* YouTube link, so a saved
/// board keeps working even after the resolved URL expires — we re-resolve on
/// every load.
bool isYouTubeUrl(String url) {
  final u = url.trim().toLowerCase();
  return u.contains('youtube.com/watch') ||
      u.contains('youtu.be/') ||
      u.contains('youtube.com/shorts') ||
      u.contains('youtube.com/embed') ||
      u.contains('youtube.com/live') ||
      u.contains('m.youtube.com');
}

/// Resolves [url] to a direct, playable stream URL.
///
/// Prefers a *muxed* stream (audio + video in one file) so a single [Player]
/// can play it with sound. Muxed tops out at ~360p, which also keeps several
/// simultaneous videos light on the device. Falls back to the best video-only
/// stream (no audio) if a video has no muxed stream.
Future<String> resolveYouTube(String url) async {
  final yt = YoutubeExplode();
  try {
    final manifest = await yt.videos.streamsClient.getManifest(url);
    if (manifest.muxed.isNotEmpty) {
      return manifest.muxed.withHighestBitrate().url.toString();
    }
    return manifest.videoOnly.withHighestBitrate().url.toString();
  } finally {
    yt.close();
  }
}
