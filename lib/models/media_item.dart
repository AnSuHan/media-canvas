import 'dart:convert';

/// The kind of media a board item holds.
enum MediaKind { video, image, gif }

/// Whether a source points at a file on disk or a remote URL.
enum SourceKind { file, network }

/// A single placeable item on the board: a video, image, or GIF.
///
/// Holds everything needed to render and restore the item — its source,
/// position, size, stacking order (zIndex), rotation, and (for video) its
/// own volume and play state. Every item is independently controllable.
class MediaItem {
  MediaItem({
    required this.id,
    required this.kind,
    required this.sourceKind,
    required this.source,
    this.title = '',
    this.x = 40,
    this.y = 40,
    this.width = 320,
    this.height = 180,
    this.zIndex = 0,
    this.rotation = 0,
    this.opacity = 1.0,
    this.volume = 100,
    this.muted = false,
    this.autoplay = true,
    this.loop = true,
  });

  final String id;
  final MediaKind kind;
  final SourceKind sourceKind;

  /// File path or URL.
  final String source;

  /// Friendly label shown in the item's title bar.
  String title;

  // Layout.
  double x;
  double y;
  double width;
  double height;

  /// Higher zIndex draws on top. This is the "depth" in the Stack.
  int zIndex;

  /// Rotation in degrees.
  double rotation;

  /// 0..1 — lets stacked layers blend.
  double opacity;

  // Per-video audio (ignored for image/gif).
  double volume; // 0..100
  bool muted;

  // Playback preferences (video/gif).
  bool autoplay;
  bool loop;

  bool get isVideo => kind == MediaKind.video;

  MediaItem copyWith({
    String? title,
    double? x,
    double? y,
    double? width,
    double? height,
    int? zIndex,
    double? rotation,
    double? opacity,
    double? volume,
    bool? muted,
    bool? autoplay,
    bool? loop,
  }) {
    return MediaItem(
      id: id,
      kind: kind,
      sourceKind: sourceKind,
      source: source,
      title: title ?? this.title,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      zIndex: zIndex ?? this.zIndex,
      rotation: rotation ?? this.rotation,
      opacity: opacity ?? this.opacity,
      volume: volume ?? this.volume,
      muted: muted ?? this.muted,
      autoplay: autoplay ?? this.autoplay,
      loop: loop ?? this.loop,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'sourceKind': sourceKind.name,
        'source': source,
        'title': title,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'zIndex': zIndex,
        'rotation': rotation,
        'opacity': opacity,
        'volume': volume,
        'muted': muted,
        'autoplay': autoplay,
        'loop': loop,
      };

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        id: j['id'] as String,
        kind: MediaKind.values.byName(j['kind'] as String),
        sourceKind: SourceKind.values.byName(j['sourceKind'] as String),
        source: j['source'] as String,
        title: (j['title'] as String?) ?? '',
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        width: (j['width'] as num).toDouble(),
        height: (j['height'] as num).toDouble(),
        zIndex: (j['zIndex'] as num).toInt(),
        rotation: (j['rotation'] as num?)?.toDouble() ?? 0,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 1.0,
        volume: (j['volume'] as num?)?.toDouble() ?? 100,
        muted: (j['muted'] as bool?) ?? false,
        autoplay: (j['autoplay'] as bool?) ?? true,
        loop: (j['loop'] as bool?) ?? true,
      );
}

/// The whole board: an ordered list of items plus a name.
class BoardState {
  BoardState({this.name = 'Untitled board', List<MediaItem>? items})
      : items = items ?? [];

  String name;
  final List<MediaItem> items;

  String toJsonString() => jsonEncode({
        'name': name,
        'version': 1,
        'items': items.map((e) => e.toJson()).toList(),
      });

  factory BoardState.fromJsonString(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return BoardState(
      name: (j['name'] as String?) ?? 'Untitled board',
      items: ((j['items'] as List?) ?? [])
          .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
