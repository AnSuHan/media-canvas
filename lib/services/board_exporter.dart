import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/media_item.dart';
import 'board_controller.dart';

/// Renders the board to a PNG by drawing each item onto an off-screen canvas.
///
/// Unlike a `RepaintBoundary` snapshot, this captures live video frames too:
/// for each video it asks the player for `screenshot()` (the current frame as
/// PNG bytes) and paints it at the item's position, size, rotation, and
/// opacity. Images and GIFs are decoded from disk or network. The result is a
/// faithful composite of what's on the board.
class BoardExporter {
  BoardExporter(this.controller);
  final BoardController controller;

  /// Build the composite PNG at [scale]x the logical canvas size.
  /// Returns null if there's nothing to draw.
  Future<Uint8List?> renderPng({double scale = 2.0}) async {
    final size = controller.canvasSize;
    if (size == Size.zero) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Match the on-screen canvas background.
    canvas.scale(scale);
    final bg = Paint()..color = const Color(0xFF201D1A);
    canvas.drawRect(Offset.zero & size, bg);

    // Draw items back-to-front so stacking matches the board.
    for (final item in controller.itemsByDepth) {
      final image = await _imageFor(item);
      if (image == null) continue;
      _drawItem(canvas, item, image);
      image.dispose();
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(
      (size.width * scale).ceil(),
      (size.height * scale).ceil(),
    );
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    img.dispose();
    return data?.buffer.asUint8List();
  }

  /// Decode the source for an item into a [ui.Image].
  Future<ui.Image?> _imageFor(MediaItem item) async {
    try {
      Uint8List? bytes;
      if (item.isVideo) {
        // Live current frame from the player (PNG-encoded).
        final bundle = controller.bundleFor(item.id);
        bytes = await bundle?.player.screenshot();
      } else if (item.sourceKind == SourceKind.network) {
        final res = await http
            .get(Uri.parse(item.source))
            .timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) bytes = res.bodyBytes;
      } else {
        final file = File(item.source);
        if (await file.exists()) bytes = await file.readAsBytes();
      }
      if (bytes == null) return null;
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  /// Paint one item with its transform (position, size, rotation, opacity),
  /// preserving aspect ratio inside its box (BoxFit.contain).
  void _drawItem(Canvas canvas, MediaItem item, ui.Image image) {
    canvas.save();

    // Move to the item's centre and rotate there, mirroring Transform.rotate.
    final cx = item.x + item.width / 2;
    final cy = item.y + item.height / 2;
    canvas.translate(cx, cy);
    canvas.rotate(item.rotation * 3.1415926535 / 180);
    canvas.translate(-item.width / 2, -item.height / 2);

    final box = Offset.zero & Size(item.width, item.height);

    // Black well behind the media (matches the on-board look).
    canvas.drawRect(box, Paint()..color = const Color(0xFF0E0D0C));

    // BoxFit.contain: scale so the whole image fits, keeping aspect ratio.
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    final fit =
        (item.width / imgW) < (item.height / imgH) ? item.width / imgW : item.height / imgH;
    final drawW = imgW * fit;
    final drawH = imgH * fit;
    final dx = (item.width - drawW) / 2;
    final dy = (item.height - drawH) / 2;

    final paint = Paint()
      ..filterQuality = FilterQuality.high
      ..color = Color.fromRGBO(255, 255, 255, item.opacity.clamp(0.05, 1.0));

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, imgW, imgH),
      Rect.fromLTWH(dx, dy, drawW, drawH),
      paint,
    );

    canvas.restore();
  }
}
