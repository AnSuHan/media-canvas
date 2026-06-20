// Unit tests for the board/settings models. These run pure Dart (no native
// media_kit), so they verify the serialization that powers save/load/export.

import 'package:flutter_test/flutter_test.dart';

import 'package:media_canvas/models/app_settings.dart';
import 'package:media_canvas/models/media_item.dart';

void main() {
  test('MediaItem survives a JSON round-trip', () {
    final item = MediaItem(
      id: 'abc',
      kind: MediaKind.video,
      sourceKind: SourceKind.network,
      source: 'https://example.com/clip.mp4',
      title: 'Clip',
      x: 12,
      y: 34,
      width: 320,
      height: 180,
      zIndex: 3,
      rotation: 45,
      opacity: 0.5,
      volume: 70,
      muted: true,
      autoplay: false,
      loop: false,
    );

    final restored = MediaItem.fromJson(item.toJson());

    expect(restored.id, item.id);
    expect(restored.kind, MediaKind.video);
    expect(restored.sourceKind, SourceKind.network);
    expect(restored.source, item.source);
    expect(restored.zIndex, 3);
    expect(restored.rotation, 45);
    expect(restored.opacity, 0.5);
    expect(restored.volume, 70);
    expect(restored.muted, true);
    expect(restored.autoplay, false);
    expect(restored.loop, false);
  });

  test('BoardState serializes its items and name', () {
    final board = BoardState(name: 'My Board', items: [
      MediaItem(
        id: '1',
        kind: MediaKind.image,
        sourceKind: SourceKind.file,
        source: r'C:\pics\a.png',
      ),
      MediaItem(
        id: '2',
        kind: MediaKind.gif,
        sourceKind: SourceKind.network,
        source: 'https://example.com/a.gif',
      ),
    ]);

    final restored = BoardState.fromJsonString(board.toJsonString());

    expect(restored.name, 'My Board');
    expect(restored.items.length, 2);
    expect(restored.items[0].kind, MediaKind.image);
    expect(restored.items[1].kind, MediaKind.gif);
  });

  test('AppSettings survives a JSON round-trip', () {
    final settings = AppSettings(
      defaultVolume: 55,
      defaultMuted: true,
      defaultLoop: false,
      defaultPlayback: DefaultPlayback.pause,
      snapToGrid: true,
      gridSize: 40,
      canvasBackground: CanvasBackground.grid,
      keepAwake: false,
      showTitleBars: false,
      confirmRemove: true,
    );

    final restored = AppSettings.fromJsonString(settings.toJsonString());

    expect(restored.defaultVolume, 55);
    expect(restored.defaultMuted, true);
    expect(restored.defaultPlayback, DefaultPlayback.pause);
    expect(restored.snapToGrid, true);
    expect(restored.gridSize, 40);
    expect(restored.canvasBackground, CanvasBackground.grid);
    expect(restored.keepAwake, false);
    expect(restored.confirmRemove, true);
  });

  test('MediaItem.fromJson tolerates missing optional fields', () {
    final restored = MediaItem.fromJson({
      'id': 'x',
      'kind': 'image',
      'sourceKind': 'file',
      'source': '/tmp/a.png',
      'x': 0,
      'y': 0,
      'width': 100,
      'height': 100,
      'zIndex': 0,
    });
    expect(restored.opacity, 1.0);
    expect(restored.volume, 100);
    expect(restored.loop, true);
  });
}
