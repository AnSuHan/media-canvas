import 'dart:convert';

/// The result of inspecting a web page for a playable video — what the
/// "동영상 가져오기" (fetch from page) screen shows and what the board needs to
/// play or download the clip.
///
/// [pageUrl] is the original link the user pasted (kept as the item source so
/// the stream can be re-resolved later). [streamUrl] is the direct media stream
/// extracted from the page (m3u8 / mp4 / …). [referer] is the page the stream
/// must be requested with (hotlink protection). [needsImpersonation] is true
/// when the stream host blocks non-browser clients, so playback/download must
/// go through the browser-impersonating yt-dlp path.
class VideoSource {
  const VideoSource({
    required this.pageUrl,
    required this.streamUrl,
    this.referer,
    this.needsImpersonation = false,
    this.title = '',
    this.thumbnail,
  });

  final String pageUrl;
  final String streamUrl;
  final String? referer;
  final bool needsImpersonation;
  final String title;
  final String? thumbnail;
}

/// One entry in the in-app URL library — a link the user saved to replay or
/// re-download later. Persisted by `LinkStore` as JSON.
class SavedLink {
  SavedLink({
    required this.url,
    this.title = '',
    this.thumbnail,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  /// The page/link the user saved (always the original, re-resolvable URL).
  final String url;

  /// A friendly label (the page's og:title when known, else the host).
  final String title;

  /// Optional preview image URL for the list tile.
  final String? thumbnail;

  /// When it was added — newest links sort to the top of the library.
  final DateTime addedAt;

  SavedLink copyWith({String? title, String? thumbnail}) => SavedLink(
        url: url,
        title: title ?? this.title,
        thumbnail: thumbnail ?? this.thumbnail,
        addedAt: addedAt,
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        if (thumbnail != null) 'thumbnail': thumbnail,
        'addedAt': addedAt.toIso8601String(),
      };

  factory SavedLink.fromJson(Map<String, dynamic> j) => SavedLink(
        url: j['url'] as String,
        title: (j['title'] as String?) ?? '',
        thumbnail: j['thumbnail'] as String?,
        addedAt:
            DateTime.tryParse((j['addedAt'] as String?) ?? '') ?? DateTime.now(),
      );

  static String encode(List<SavedLink> links) =>
      jsonEncode(links.map((e) => e.toJson()).toList());

  static List<SavedLink> decode(String s) {
    final list = (jsonDecode(s) as List?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(SavedLink.fromJson)
        .toList();
  }
}
