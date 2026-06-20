import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/app_settings.dart';
import '../models/media_item.dart';
import 'youtube_resolver.dart';

/// Bundles a video item's [Player] and [VideoController] together so the UI
/// can render and control it. Non-video items never get one of these.
class PlayerBundle {
  PlayerBundle(this.player, this.controller);
  final Player player;
  final VideoController controller;

  /// Last error from the engine for this item, if any (bad URL / missing file).
  String? error;
}

/// The single source of truth for the board.
///
/// Holds the list of [MediaItem]s and, for each video, a live libmpv [Player].
/// Exposes selection, z-ordering, per-item playback/volume, and global
/// "play all / mute all" actions. Extends [ChangeNotifier] so the UI rebuilds
/// on any change.
class BoardController extends ChangeNotifier {
  final List<MediaItem> _items = [];
  final Map<String, PlayerBundle> _players = {};

  String? _selectedId;
  String _boardName = 'Untitled board';

  /// App-wide preferences. The UI swaps this in after loading from disk.
  AppSettings settings = AppSettings();

  void applySettings(AppSettings s) {
    settings = s;
    // Honor the keep-awake preference immediately (no-op on unsupported OS).
    WakelockPlus.toggle(enable: s.keepAwake);
    notifyListeners();
  }

  List<MediaItem> get items => List.unmodifiable(_items);
  String? get selectedId => _selectedId;
  String get boardName => _boardName;
  set boardName(String v) {
    _boardName = v;
    notifyListeners();
  }

  /// Items sorted back-to-front for stacking in a [Stack].
  List<MediaItem> get itemsByDepth =>
      [..._items]..sort((a, b) => a.zIndex.compareTo(b.zIndex));

  int get _maxZ =>
      _items.isEmpty ? 0 : _items.map((e) => e.zIndex).reduce((a, b) => a > b ? a : b);
  int get _minZ =>
      _items.isEmpty ? 0 : _items.map((e) => e.zIndex).reduce((a, b) => a < b ? a : b);

  PlayerBundle? bundleFor(String id) => _players[id];

  MediaItem? get selected {
    if (_selectedId == null) return null;
    for (final it in _items) {
      if (it.id == _selectedId) return it;
    }
    return null;
  }

  void select(String? id) {
    _selectedId = id;
    notifyListeners();
  }

  // ---- Adding / removing -------------------------------------------------

  Future<void> addItem(MediaItem item) async {
    item.zIndex = _items.isEmpty ? 0 : _maxZ + 1;
    // Apply user defaults from settings (only for video playback prefs).
    if (item.isVideo) {
      item.volume = settings.defaultVolume;
      item.muted = settings.defaultMuted;
      item.loop = settings.defaultLoop;
      item.autoplay = settings.defaultPlayback == DefaultPlayback.play;
    }
    _items.add(item);
    if (item.isVideo) {
      await _spinUpPlayer(item);
    }
    _selectedId = item.id;
    notifyListeners();
  }

  Future<void> _spinUpPlayer(MediaItem item) async {
    final player = Player();
    final controller = VideoController(player);
    final bundle = PlayerBundle(player, controller);
    _players[item.id] = bundle;

    // Surface engine errors (bad URL, missing/corrupt file) to the UI instead
    // of spinning forever.
    player.stream.error.listen((e) {
      bundle.error = e;
      notifyListeners();
    });

    try {
      final playable = await _resolvePlayable(item);
      await player.open(Media(playable), play: item.autoplay);
      await player.setPlaylistMode(
        item.loop ? PlaylistMode.loop : PlaylistMode.none,
      );
      await player.setVolume(item.muted ? 0 : item.volume);
    } catch (e) {
      bundle.error = e.toString();
      notifyListeners();
    }
  }

  /// Turns an item's stored source into a URL the engine can actually open.
  ///
  /// YouTube links are resolved to a direct stream URL on the fly (libmpv
  /// can't play a watch page without yt-dlp). Everything else goes through
  /// [_resolveSource].
  Future<String> _resolvePlayable(MediaItem item) async {
    if (item.sourceKind == SourceKind.network && isYouTubeUrl(item.source)) {
      return resolveYouTube(item.source);
    }
    return _resolveSource(item);
  }

  /// media_kit's [Media] wants a URI for local files. A raw Windows path
  /// (`C:\clips\a.mp4`) or POSIX path must become a `file://` URI; network
  /// sources are passed through unchanged.
  String _resolveSource(MediaItem item) {
    if (item.sourceKind == SourceKind.network) return item.source;
    // Already a URI?
    if (item.source.startsWith('file://') ||
        item.source.startsWith('http')) {
      return item.source;
    }
    return Uri.file(item.source).toString();
  }

  Future<void> removeItem(String id) async {
    _items.removeWhere((e) => e.id == id);
    final bundle = _players.remove(id);
    await bundle?.player.dispose();
    if (_selectedId == id) _selectedId = null;
    notifyListeners();
  }

  // ---- Geometry (called live during drag / resize) -----------------------

  /// The current canvas size, set by the board view, so items can be kept
  /// at least partially on-screen.
  Size canvasSize = Size.zero;

  /// Updates the known canvas size and, on a real layout change in width
  /// (i.e. a portrait↔landscape rotation or a window resize), remaps every
  /// item proportionally so it keeps roughly the same spot on the board.
  ///
  /// We key off the *width* changing so the small height change from the
  /// selection bar toggling on/off doesn't nudge items around.
  void setCanvasSize(Size s) {
    final old = canvasSize;
    canvasSize = s;
    if (old == Size.zero ||
        s == Size.zero ||
        old.width <= 0 ||
        old.height <= 0) {
      return;
    }
    if ((s.width - old.width).abs() < 1) return;

    final sx = s.width / old.width;
    final sy = s.height / old.height;
    for (final it in _items) {
      // Remap by the item's center so it lands proportionally; size is kept.
      final cx = (it.x + it.width / 2) * sx;
      final cy = (it.y + it.height / 2) * sy;
      it.x = cx - it.width / 2;
      it.y = cy - it.height / 2;
    }
    notifyListeners();
  }

  void updateGeometry(
    String id, {
    double? x,
    double? y,
    double? width,
    double? height,
    double? rotation,
    double? opacity,
  }) {
    final it = _byId(id);
    if (it == null) return;
    if (width != null) it.width = width.clamp(80, 4000);
    if (height != null) it.height = height.clamp(60, 4000);
    if (x != null) it.x = x;
    if (y != null) it.y = y;
    if (rotation != null) it.rotation = _snapRotation(rotation);
    if (opacity != null) it.opacity = _snapOpacity(opacity.clamp(0.05, 1.0));

    // Snap to the grid if enabled in settings.
    if (settings.snapToGrid && settings.gridSize > 0) {
      final g = settings.gridSize;
      it.x = (it.x / g).round() * g;
      it.y = (it.y / g).round() * g;
      if (width != null) it.width = (it.width / g).round() * g;
      if (height != null) it.height = (it.height / g).round() * g;
    }

    // Keep at least 48px of the item reachable on each edge.
    if (canvasSize != Size.zero) {
      const margin = 48.0;
      it.x = it.x.clamp(margin - it.width, canvasSize.width - margin);
      it.y = it.y.clamp(0, canvasSize.height - margin);
    }
    notifyListeners();
  }

  /// Magnetic detents for rotation: snap onto the nearest 45° mark (…0, 90,
  /// 180…) when the value lands within [_rotationDetent]° of it, so it's easy
  /// to set a clean angle by hand while still allowing in-between values.
  static const double _rotationDetent = 6;
  double _snapRotation(double v) {
    const marks = [-180.0, -135.0, -90.0, -45.0, 0.0, 45.0, 90.0, 135.0, 180.0];
    for (final m in marks) {
      if ((v - m).abs() <= _rotationDetent) return m;
    }
    return v;
  }

  /// Magnetic detents for opacity: snap onto 25 / 50 / 75 / 100% when close,
  /// so common levels are easy to hit. ([opacity] is kept in 0..1.)
  static const double _opacityDetent = 0.03;
  double _snapOpacity(double v) {
    const marks = [0.25, 0.5, 0.75, 1.0];
    for (final m in marks) {
      if ((v - m).abs() <= _opacityDetent) return m;
    }
    return v;
  }

  // ---- Z-ordering (depth) ------------------------------------------------

  void bringToFront(String id) {
    final it = _byId(id);
    if (it == null) return;
    it.zIndex = _maxZ + 1;
    notifyListeners();
  }

  void sendToBack(String id) {
    final it = _byId(id);
    if (it == null) return;
    it.zIndex = _minZ - 1;
    notifyListeners();
  }

  void bringForward(String id) {
    final ordered = itemsByDepth;
    final i = ordered.indexWhere((e) => e.id == id);
    if (i < 0 || i == ordered.length - 1) return;
    final a = ordered[i];
    final b = ordered[i + 1];
    final tmp = a.zIndex;
    a.zIndex = b.zIndex;
    b.zIndex = tmp;
    notifyListeners();
  }

  void sendBackward(String id) {
    final ordered = itemsByDepth;
    final i = ordered.indexWhere((e) => e.id == id);
    if (i <= 0) return;
    final a = ordered[i];
    final b = ordered[i - 1];
    final tmp = a.zIndex;
    a.zIndex = b.zIndex;
    b.zIndex = tmp;
    notifyListeners();
  }

  // ---- Per-item playback / audio ----------------------------------------

  Future<void> togglePlay(String id) async {
    final b = _players[id];
    if (b == null) return;
    await b.player.playOrPause();
    notifyListeners();
  }

  Future<void> setVolume(String id, double v) async {
    final it = _byId(id);
    final b = _players[id];
    if (it == null) return;
    it.volume = v;
    it.muted = v == 0;
    await b?.player.setVolume(v);
    notifyListeners();
  }

  Future<void> toggleMute(String id) async {
    final it = _byId(id);
    final b = _players[id];
    if (it == null) return;
    it.muted = !it.muted;
    await b?.player.setVolume(it.muted ? 0 : it.volume);
    notifyListeners();
  }

  Future<void> setLoop(String id, bool loop) async {
    final it = _byId(id);
    final b = _players[id];
    if (it == null) return;
    it.loop = loop;
    await b?.player
        .setPlaylistMode(loop ? PlaylistMode.loop : PlaylistMode.none);
    notifyListeners();
  }

  // ---- Global controls ---------------------------------------------------

  Future<void> playAll() async {
    for (final b in _players.values) {
      await b.player.play();
    }
    notifyListeners();
  }

  Future<void> pauseAll() async {
    for (final b in _players.values) {
      await b.player.pause();
    }
    notifyListeners();
  }

  /// Unmute every video and restore its individual saved volume.
  Future<void> unmuteAll() async {
    for (final it in _items.where((e) => e.isVideo)) {
      it.muted = false;
      await _players[it.id]?.player.setVolume(it.volume);
    }
    notifyListeners();
  }

  Future<void> muteAll() async {
    for (final it in _items.where((e) => e.isVideo)) {
      it.muted = true;
      await _players[it.id]?.player.setVolume(0);
    }
    notifyListeners();
  }

  // ---- Persistence -------------------------------------------------------

  BoardState exportState() => BoardState(name: _boardName, items: [..._items]);

  /// Replace the whole board with a loaded one, spinning up fresh players.
  Future<void> loadState(BoardState state) async {
    for (final b in _players.values) {
      await b.player.dispose();
    }
    _players.clear();
    _items
      ..clear()
      ..addAll(state.items);
    _boardName = state.name;
    _selectedId = null;
    for (final it in _items.where((e) => e.isVideo)) {
      await _spinUpPlayer(it);
    }
    notifyListeners();
  }

  MediaItem? _byId(String id) {
    for (final it in _items) {
      if (it.id == id) return it;
    }
    return null;
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    for (final b in _players.values) {
      b.player.dispose();
    }
    _players.clear();
    super.dispose();
  }
}
