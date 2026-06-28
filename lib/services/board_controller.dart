import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/app_settings.dart';
import '../models/media_item.dart';
import 'download/download.dart';
import 'hls_ad_filter.dart';
import 'instagram_resolver.dart';
import 'media_url_resolver.dart';
import 'stream_proxy.dart';
import 'ytdlp.dart';
import 'youtube_resolver.dart' show listYouTubeStreams;

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

  /// Resolves an Instagram post link and adds **every** photo/video in it to
  /// the board, cascaded so they don't fully overlap. Returns the number of
  /// items added (0 if nothing could be resolved). [idFor] supplies a unique
  /// id per item; [compact] picks phone-friendly sizing.
  Future<int> addInstagramPost(
    String url, {
    required String Function(int index) idFor,
    bool compact = false,
  }) async {
    final media = await resolveInstagram(url);
    if (media.isEmpty) return 0;

    final w = compact ? 200.0 : 320.0;
    const step = 28.0;
    for (var i = 0; i < media.length; i++) {
      final m = media[i];
      await addItem(MediaItem(
        id: idFor(i),
        kind: m.isVideo ? MediaKind.video : MediaKind.image,
        sourceKind: SourceKind.network,
        source: m.url,
        title: m.isVideo ? 'Instagram ${i + 1}' : 'Instagram ${i + 1}',
        x: 40 + i * step,
        y: 40 + i * step,
        width: m.isVideo ? w : w * 0.8,
        height: m.isVideo ? w * 0.5625 : w,
      ));
    }
    return media.length;
  }

  Future<void> _spinUpPlayer(MediaItem item) async {
    final player = Player();
    final controller = VideoController(player);
    final bundle = PlayerBundle(player, controller);
    _players[item.id] = bundle;

    // Surface engine errors (bad URL, missing/corrupt file) to the UI instead
    // of spinning forever — but as a friendly message, never the raw libmpv
    // "Failed to recognize file format" string.
    player.stream.error.listen((e) {
      bundle.error = _friendlyError(e);
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
      bundle.error = _friendlyError(e);
      notifyListeners();
    }
  }

  /// Turns a raw engine/IO error into a short, user-readable Korean message so
  /// the board never shows libmpv's cryptic "unsupported format" text.
  static String _friendlyError(Object raw) {
    final s = raw.toString().toLowerCase();
    if (s.contains('format') ||
        s.contains('recognize') ||
        s.contains('demux') ||
        s.contains('no stream') ||
        s.contains('no video') ||
        s.contains('codec') ||
        s.contains('failed to open')) {
      return '이 링크에서 재생할 수 있는 영상을 찾지 못했어요.';
    }
    if (s.contains('404') || s.contains('not found') || s.contains('no such')) {
      return '링크를 찾을 수 없어요. 주소를 확인해 주세요.';
    }
    if (s.contains('network') ||
        s.contains('timed out') ||
        s.contains('timeout') ||
        s.contains('connection')) {
      return '네트워크 문제로 불러오지 못했어요. 잠시 후 다시 시도해 주세요.';
    }
    return '영상을 불러오지 못했어요.';
  }

  /// Turns an item's stored source into a URL the engine can actually open.
  ///
  /// Any network link — YouTube, Vimeo, a news page with one embedded clip, or
  /// a direct .mp4 — is resolved to a direct stream URL on the fly (see
  /// [resolvePlayableUrl]). Resolving to the raw stream also strips the page's
  /// ads, since libmpv never loads the publisher's ad-serving HTML/JS. Local
  /// files go through [_resolveSource].
  Future<String> _resolvePlayable(MediaItem item) async {
    if (item.sourceKind == SourceKind.network) {
      final url = await resolvePlayableUrl(item.source);
      // Some CDNs (a Cloudflare TLS-fingerprint block) 403 libmpv no matter the
      // headers. When detected, route the stream through the local proxy, which
      // fetches it with a browser-impersonating yt-dlp and pipes MPEG-TS to
      // libmpv over localhost. The original page URL is the required Referer.
      // (YouTube resolves to googlevideo, never TLS-blocked — skip the probe so
      // the common case keeps its fast path.)
      if (!isYouTubeUrl(item.source) && await streamNeedsImpersonation(url)) {
        final proxied = await StreamProxy.instance
            .proxiedUrl(streamUrl: url, referer: item.source);
        if (proxied != null) return proxied;
      }
      // If the resolved stream is HLS with server-stitched ads (SSAI), hand
      // libmpv a rewritten playlist that skips the ad segments. Falls back to
      // the original URL when there's nothing to strip or it can't be fetched.
      final adFree = await filterHlsAds(url);
      return adFree ?? url;
    }
    return _resolveSource(item);
  }

  /// Resolves a network item to the *direct, progressive* stream URL to
  /// download (e.g. a YouTube muxed mp4). Unlike playback this skips the HLS
  /// ad-filter rewrite, since a download wants the original single file.
  Future<String> resolveDownloadUrl(MediaItem item) {
    return resolvePlayableUrl(item.source);
  }

  /// Lists the selectable download qualities for a network [item].
  ///
  /// Stitches together the source-specific listers: YouTube muxed streams, HLS
  /// master variants, or DASH representations. For a single-quality source
  /// (a plain mp4) returns one "원본" option so callers can treat all sources
  /// uniformly.
  Future<List<DownloadOption>> listDownloadOptions(MediaItem item) async {
    final src = item.source;
    if (isYouTubeUrl(src)) {
      final streams = await listYouTubeStreams(src);
      return [
        for (final s in streams)
          DownloadOption(
              label: s.label, url: s.url, adaptive: false, height: s.height),
      ];
    }
    final url = await resolvePlayableUrl(src);
    // Cloudflare-TLS-protected stream: the built-in http path 403s, so download
    // it with the browser-impersonating yt-dlp (Referer = the page it's on).
    if (await streamNeedsImpersonation(url)) {
      return [
        DownloadOption(
          label: '원본',
          url: url,
          adaptive: false,
          ytdlpUrl: url,
          ytdlpFormat: 'best',
          impersonate: true,
          referer: src,
        ),
      ];
    }
    if (isAdaptiveStream(url)) {
      final qualities = await listAdaptiveQualities(url);
      return qualities.isNotEmpty
          ? qualities
          : [DownloadOption(label: '원본', url: url, adaptive: true)];
    }
    if (isDownloadableStream(url)) {
      return [DownloadOption(label: '원본', url: url, adaptive: false)];
    }
    // The built-in http path can't fetch this (a JS-driven page like X/TikTok).
    // Let the bundled yt-dlp enumerate qualities and perform the download.
    final viaYtDlp = await ytDlpListOptions(src);
    if (viaYtDlp.isNotEmpty) return viaYtDlp;
    // Last resort: hand the resolved URL to the http path anyway.
    return [DownloadOption(label: '원본', url: url, adaptive: false)];
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
    // Stop any browser-impersonating yt-dlp processes feeding the proxy.
    StreamProxy.instance.shutdown();
    for (final b in _players.values) {
      b.player.dispose();
    }
    _players.clear();
    super.dispose();
  }
}
