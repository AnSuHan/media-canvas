import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit_video/media_kit_video.dart';

import '../models/media_item.dart';
import '../services/board_controller.dart';
import '../services/download/download.dart';
import '../theme.dart';

/// One placeable item on the board. Renders the media, lets the user drag it
/// around, pinch to scale (two fingers) or resize it from the corner, and (for
/// video) shows a compact control strip. Selected items get a viewfinder-style
/// corner-bracket frame.
class BoardItemWidget extends StatefulWidget {
  const BoardItemWidget({
    super.key,
    required this.item,
    required this.controller,
    required this.selected,
    required this.compact,
  });

  final MediaItem item;
  final BoardController controller;
  final bool selected;

  /// On phones we hide the inline title bar to save space.
  final bool compact;

  @override
  State<BoardItemWidget> createState() => _BoardItemWidgetState();
}

class _BoardItemWidgetState extends State<BoardItemWidget> {
  // Geometry captured when a drag/pinch begins, so updates are relative to the
  // gesture start instead of accumulating rounding errors frame to frame.
  double _startW = 0;
  double _startH = 0;
  double _startX = 0;
  double _startY = 0;
  double _startRotation = 0;
  Offset _accumPan = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final controller = widget.controller;
    final selected = widget.selected;
    return Positioned(
      left: item.x,
      top: item.y,
      width: item.width,
      height: item.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => controller.select(item.id),
        // Long-press a URL-registered video to download it to disk.
        onLongPress: _canDownload ? _downloadVideo : null,
        // A single ScaleGesture handles both one-finger drag (scale stays 1)
        // and two-finger pinch-to-zoom / twist-to-rotate.
        onScaleStart: (_) {
          controller.select(item.id);
          _startW = item.width;
          _startH = item.height;
          _startX = item.x;
          _startY = item.y;
          _startRotation = item.rotation;
          _accumPan = Offset.zero;
        },
        onScaleUpdate: (d) {
          _accumPan += d.focalPointDelta;
          final newW = _startW * d.scale;
          final newH = _startH * d.scale;
          // Scale around the item's original center, then apply the drag so the
          // pinch feels anchored under the fingers.
          controller.updateGeometry(
            item.id,
            width: newW,
            height: newH,
            x: _startX - (newW - _startW) / 2 + _accumPan.dx,
            y: _startY - (newH - _startH) / 2 + _accumPan.dy,
            rotation: _startRotation + d.rotation * 180 / math.pi,
          );
        },
        child: Opacity(
          opacity: item.opacity,
          child: Transform.rotate(
            angle: item.rotation * math.pi / 180,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _surface(context),
                if (selected) const Positioned.fill(child: _ViewfinderFrame()),
                if (selected && !widget.compact && controller.settings.showTitleBars)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: _TitleBar(item: item, controller: controller),
                  ),
                if (item.isVideo && selected)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _VideoControls(item: item, controller: controller),
                  ),
                if (selected) _resizeHandle(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _surface(BuildContext context) {
    final item = widget.item;
    final selected = widget.selected;
    final controller = widget.controller;
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.well,
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppColors.brass.withValues(alpha: 0.25),
                    blurRadius: 24,
                    spreadRadius: 1,
                  ),
                ]
              : [
                  const BoxShadow(
                    color: Color(0x55000000),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
        ),
        child: ClipRect(child: _MediaSurface(item: item, controller: controller)),
      ),
    );
  }

  /// Only network-sourced videos can be downloaded (local files already exist
  /// on disk; images/gifs aren't the feature's target).
  bool get _canDownload =>
      widget.item.isVideo && widget.item.sourceKind == SourceKind.network;

  /// Long-press handler: resolve the item to a direct stream, let the user pick
  /// a destination, and download it with a live, cancellable progress dialog.
  Future<void> _downloadVideo() async {
    final item = widget.item;
    final controller = widget.controller;
    controller.select(item.id);

    final messenger = ScaffoldMessenger.of(context);
    void toast(String msg) =>
        messenger.showSnackBar(SnackBar(content: Text(msg)));

    const downloader = VideoDownloader();

    // 1) Resolve to a direct stream / manifest.
    String url;
    try {
      url = await controller.resolveDownloadUrl(item);
    } catch (_) {
      toast('다운로드 주소를 가져오지 못했습니다.');
      return;
    }
    if (!downloader.canDownload(url)) {
      toast('이 주소는 동영상 파일로 저장할 수 없습니다.');
      return;
    }

    // 2) Ask where to save.
    final suggested = downloader.suggestName(item.title, url);
    String? savePath;
    try {
      savePath = await FilePicker.platform.saveFile(
        dialogTitle: '동영상 저장',
        fileName: suggested,
        type: FileType.video,
      );
    } catch (_) {
      savePath = null;
    }
    if (savePath == null) return; // cancelled / unsupported
    if (!savePath.contains('.')) savePath = '$savePath.mp4';
    if (!mounted) return;

    // 3) Download with a cancellable progress dialog. Closing [client] aborts
    //    the in-flight stream so "취소" really stops the transfer.
    final progress = ValueNotifier<double>(0);
    final client = http.Client();
    var cancelled = false;
    var dialogOpen = true;

    void closeDialog() {
      if (dialogOpen && mounted) {
        dialogOpen = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('동영상 다운로드 중…'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: v > 0 ? v : null),
              const SizedBox(height: 10),
              Text(v > 0 ? '${(v * 100).toStringAsFixed(0)}%' : '시작하는 중…'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              dialogOpen = false;
              client.close(); // aborts the stream
              Navigator.of(ctx).pop();
            },
            child: const Text('취소'),
          ),
        ],
      ),
    );

    final saveTo = savePath;
    var writtenPath = saveTo;
    try {
      // The facade picks progressive vs. adaptive (HLS/DASH) and normalizes
      // progress; adaptive streams may return a corrected .ts/.mp4 path.
      writtenPath = await downloader.download(
        url,
        saveTo,
        client: client,
        onProgress: (fraction) {
          if (fraction != null) progress.value = fraction;
        },
      );
      closeDialog();
      toast('저장 완료: $writtenPath');
    } catch (e) {
      closeDialog();
      if (!cancelled) toast('다운로드 실패: $e');
      // Best-effort cleanup of a partial file on cancel/failure.
      try {
        await File(writtenPath).delete();
      } catch (_) {}
    } finally {
      client.close();
      progress.dispose();
    }
  }

  Widget _resizeHandle() {
    return Positioned(
      right: -7,
      bottom: -7,
      child: GestureDetector(
        onPanUpdate: (d) => widget.controller.updateGeometry(
          widget.item.id,
          width: widget.item.width + d.delta.dx,
          height: widget.item.height + d.delta.dy,
        ),
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: AppColors.brass,
            borderRadius: BorderRadius.circular(5),
            boxShadow: const [
              BoxShadow(color: Color(0x66000000), blurRadius: 4),
            ],
          ),
          child: const Icon(Icons.open_in_full, size: 12, color: AppColors.base),
        ),
      ),
    );
  }
}

/// Four corner brackets — like a camera viewfinder — instead of a full border.
class _ViewfinderFrame extends StatelessWidget {
  const _ViewfinderFrame();
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(painter: _BracketPainter()),
    );
  }
}

class _BracketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = AppColors.brass
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    const len = 16.0;
    // TL
    canvas.drawLine(const Offset(0, 0), const Offset(len, 0), p);
    canvas.drawLine(const Offset(0, 0), const Offset(0, len), p);
    // TR
    canvas.drawLine(Offset(size.width, 0), Offset(size.width - len, 0), p);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, len), p);
    // BL
    canvas.drawLine(Offset(0, size.height), Offset(len, size.height), p);
    canvas.drawLine(Offset(0, size.height), Offset(0, size.height - len), p);
    // BR
    canvas.drawLine(
        Offset(size.width, size.height), Offset(size.width - len, size.height), p);
    canvas.drawLine(
        Offset(size.width, size.height), Offset(size.width, size.height - len), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MediaSurface extends StatelessWidget {
  const _MediaSurface({required this.item, required this.controller});
  final MediaItem item;
  final BoardController controller;

  @override
  Widget build(BuildContext context) {
    switch (item.kind) {
      case MediaKind.video:
        final bundle = controller.bundleFor(item.id);
        if (bundle == null) return const _Loading();
        if (bundle.error != null) return _ErrorTile(message: bundle.error!);
        return Video(
          controller: bundle.controller,
          controls: NoVideoControls,
          fit: BoxFit.contain,
        );
      case MediaKind.image:
      case MediaKind.gif:
        final img = item.sourceKind == SourceKind.network
            ? Image.network(
                item.source,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                loadingBuilder: (c, child, p) =>
                    p == null ? child : const _Loading(),
                errorBuilder: (_, __, ___) =>
                    const _ErrorTile(message: 'Could not load image'),
              )
            : Image.file(
                File(item.source),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) =>
                    const _ErrorTile(message: 'File not found'),
              );
        return RepaintBoundary(child: img);
    }
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.brass,
          ),
        ),
      );
}

class _ErrorTile extends StatelessWidget {
  const _ErrorTile({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.well,
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFD98C6A), size: 22),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textDim, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.item, required this.controller});
  final MediaItem item;
  final BoardController controller;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Container(
        height: 28,
        padding: const EdgeInsets.only(left: 8, right: 2),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.base.withValues(alpha: 0.85),
              AppColors.base.withValues(alpha: 0.0),
            ],
          ),
        ),
        child: Row(
          children: [
            Icon(_iconFor(item.kind), size: 13, color: AppColors.brass),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                item.title.isEmpty ? item.kind.name.toUpperCase() : item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 11,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            _MiniBtn(Icons.close, 'Remove',
                () => controller.removeItem(item.id)),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(MediaKind k) => switch (k) {
        MediaKind.video => Icons.movie_outlined,
        MediaKind.image => Icons.image_outlined,
        MediaKind.gif => Icons.gif_box_outlined,
      };
}

class _VideoControls extends StatelessWidget {
  const _VideoControls({required this.item, required this.controller});
  final MediaItem item;
  final BoardController controller;

  @override
  Widget build(BuildContext context) {
    final bundle = controller.bundleFor(item.id);
    return ClipRect(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              AppColors.base.withValues(alpha: 0.9),
              AppColors.base.withValues(alpha: 0.0),
            ],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Seek bar: play/pause + scrubbable position + time readout.
            Row(
              children: [
                if (bundle != null)
                  StreamBuilder<bool>(
                    stream: bundle.player.stream.playing,
                    builder: (context, snap) {
                      final playing = snap.data ?? false;
                      return _MiniBtn(
                        playing ? Icons.pause : Icons.play_arrow,
                        playing ? 'Pause' : 'Play',
                        () => controller.togglePlay(item.id),
                      );
                    },
                  ),
                if (bundle != null)
                  Expanded(child: _SeekBar(bundle: bundle))
                else
                  const Expanded(child: SizedBox.shrink()),
              ],
            ),
            // Audio row: mute + volume.
            Row(
              children: [
                _MiniBtn(
                  item.muted ? Icons.volume_off : Icons.volume_up,
                  item.muted ? 'Unmute' : 'Mute',
                  () => controller.toggleMute(item.id),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: AppColors.brass,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: AppColors.brass,
                    ),
                    child: Slider(
                      value: item.muted ? 0 : item.volume.clamp(0, 100),
                      min: 0,
                      max: 100,
                      onChanged: (v) => controller.setVolume(item.id, v),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A scrubbable position bar for a video. Follows the player's live position,
/// but while the user is dragging it shows the dragged value and only commits
/// the seek when the drag ends — so the thumb doesn't fight the stream.
class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.bundle});
  final PlayerBundle bundle;
  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragMs;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.bundle.player;
    return StreamBuilder<Duration>(
      stream: player.stream.duration,
      initialData: player.state.duration,
      builder: (context, durSnap) {
        final dur = durSnap.data ?? Duration.zero;
        final maxMs = dur.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final curMs = _dragMs ?? pos.inMilliseconds.toDouble();
            final hasDuration = maxMs > 0;
            return Row(
              children: [
                Text(
                  _fmt(Duration(milliseconds: curMs.round())),
                  style: const TextStyle(color: AppColors.text, fontSize: 10),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: AppColors.brass,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: AppColors.brass,
                    ),
                    child: Slider(
                      value: hasDuration ? curMs.clamp(0, maxMs) : 0,
                      min: 0,
                      max: hasDuration ? maxMs : 1,
                      onChanged: hasDuration
                          ? (v) => setState(() => _dragMs = v)
                          : null,
                      onChangeEnd: hasDuration
                          ? (v) async {
                              await player.seek(
                                  Duration(milliseconds: v.round()));
                              if (mounted) setState(() => _dragMs = null);
                            }
                          : null,
                    ),
                  ),
                ),
                Text(
                  _fmt(dur),
                  style: const TextStyle(color: AppColors.textDim, fontSize: 10),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _MiniBtn extends StatelessWidget {
  const _MiniBtn(this.icon, this.tip, this.onTap);
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 17, color: AppColors.text),
        ),
      ),
    );
  }
}
