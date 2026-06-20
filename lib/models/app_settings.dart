import 'dart:convert';

/// What a freshly added video should do.
enum DefaultPlayback { play, pause }

/// Background style for the board canvas.
enum CanvasBackground { dots, grid, solid }

/// App-wide settings, persisted to disk separately from any board.
///
/// These are preferences that shape new items and the workspace, not the
/// content of a board itself.
class AppSettings {
  AppSettings({
    this.defaultVolume = 80,
    this.defaultMuted = false,
    this.defaultLoop = true,
    this.defaultPlayback = DefaultPlayback.play,
    this.snapToGrid = false,
    this.gridSize = 28,
    this.canvasBackground = CanvasBackground.dots,
    this.keepAwake = true,
    this.showTitleBars = true,
    this.confirmRemove = false,
  });

  /// Starting volume (0..100) applied to newly added videos.
  double defaultVolume;
  bool defaultMuted;
  bool defaultLoop;
  DefaultPlayback defaultPlayback;

  /// Snap item position/size to [gridSize] increments while dragging.
  bool snapToGrid;
  double gridSize;

  CanvasBackground canvasBackground;

  /// Prevent the screen from sleeping while the board is open (mobile).
  bool keepAwake;

  /// Show the inline title bar on selected items (desktop).
  bool showTitleBars;

  /// Ask before removing an item.
  bool confirmRemove;

  AppSettings copy() => AppSettings(
        defaultVolume: defaultVolume,
        defaultMuted: defaultMuted,
        defaultLoop: defaultLoop,
        defaultPlayback: defaultPlayback,
        snapToGrid: snapToGrid,
        gridSize: gridSize,
        canvasBackground: canvasBackground,
        keepAwake: keepAwake,
        showTitleBars: showTitleBars,
        confirmRemove: confirmRemove,
      );

  Map<String, dynamic> toJson() => {
        'defaultVolume': defaultVolume,
        'defaultMuted': defaultMuted,
        'defaultLoop': defaultLoop,
        'defaultPlayback': defaultPlayback.name,
        'snapToGrid': snapToGrid,
        'gridSize': gridSize,
        'canvasBackground': canvasBackground.name,
        'keepAwake': keepAwake,
        'showTitleBars': showTitleBars,
        'confirmRemove': confirmRemove,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        defaultVolume: (j['defaultVolume'] as num?)?.toDouble() ?? 80,
        defaultMuted: (j['defaultMuted'] as bool?) ?? false,
        defaultLoop: (j['defaultLoop'] as bool?) ?? true,
        defaultPlayback: DefaultPlayback.values.byName(
            (j['defaultPlayback'] as String?) ?? 'play'),
        snapToGrid: (j['snapToGrid'] as bool?) ?? false,
        gridSize: (j['gridSize'] as num?)?.toDouble() ?? 28,
        canvasBackground: CanvasBackground.values.byName(
            (j['canvasBackground'] as String?) ?? 'dots'),
        keepAwake: (j['keepAwake'] as bool?) ?? true,
        showTitleBars: (j['showTitleBars'] as bool?) ?? true,
        confirmRemove: (j['confirmRemove'] as bool?) ?? false,
      );

  String toJsonString() => jsonEncode(toJson());
  factory AppSettings.fromJsonString(String s) =>
      AppSettings.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
