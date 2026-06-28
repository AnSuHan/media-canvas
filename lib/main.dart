import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'models/app_settings.dart';
import 'models/media_item.dart';
import 'services/app_log.dart';
import 'services/board_controller.dart';
import 'services/board_exporter.dart';
import 'services/instagram_resolver.dart';
import 'services/layout_store.dart';
import 'services/media_url_resolver.dart';
import 'services/ytdlp.dart';
import 'theme.dart';
import 'services/link_store.dart';
import 'widgets/board_item_widget.dart';
import 'widgets/settings_page.dart';
import 'widgets/source_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // required on Windows & Android
  _logStartup();
  runApp(const MultimediaBoardApp());
}

/// Records environment facts at launch so the diagnostic log always opens with
/// which build is running and whether the bundled yt-dlp was found (the #1
/// reason protected-VOD play/download fails).
Future<void> _logStartup() async {
  logDiag('app', '시작 — ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  logDiag('app',
      'yt-dlp ${ytDlpAvailable() ? "사용 가능: ${ytDlpExecutable()}" : "없음 (보호 사이트 재생/다운로드 불가)"}');
  try {
    final info = await PackageInfo.fromPlatform();
    logDiag('app', '버전 ${info.version} (${info.buildNumber})');
  } catch (_) {}
}

class MultimediaBoardApp extends StatelessWidget {
  const MultimediaBoardApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Media Canvas',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const BoardPage(),
    );
  }
}

class BoardPage extends StatefulWidget {
  const BoardPage({super.key});
  @override
  State<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends State<BoardPage> {
  final BoardController controller = BoardController();
  final LayoutStore store = LayoutStore();
  final LinkStore linkStore = LinkStore();
  int _idSeed = 0;

  /// Whether the top toolbar is shown. Tapping the empty canvas toggles it,
  /// so the board can go (almost) full-bleed.
  bool _chromeVisible = true;

  String _newId() => 'm${DateTime.now().millisecondsSinceEpoch}_${_idSeed++}';

  @override
  void initState() {
    super.initState();
    controller.addListener(_rebuild);
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final loaded = await store.loadSettings();
    controller.applySettings(loaded);
  }

  void _rebuild() => setState(() {});

  /// Tapping the empty canvas deselects any item and toggles the top toolbar.
  void _onBackgroundTap() {
    controller.select(null);
    setState(() => _chromeVisible = !_chromeVisible);
  }

  @override
  void dispose() {
    controller.removeListener(_rebuild);
    controller.dispose();
    super.dispose();
  }

  // ---- Add media ---------------------------------------------------------

  Future<void> _pickLocal(bool compact) async {
    final result = await FilePicker.platform
        .pickFiles(allowMultiple: true, type: FileType.media);
    if (result == null) return;
    final w = compact ? 200.0 : 360.0;
    for (final f in result.files) {
      final path = f.path;
      if (path == null) continue;
      final kind = _kindFromExt(path.split('.').last.toLowerCase());
      await controller.addItem(MediaItem(
        id: _newId(),
        kind: kind,
        sourceKind: SourceKind.file,
        source: path,
        title: f.name,
        width: kind == MediaKind.video ? w : w * 0.72,
        height: kind == MediaKind.video ? w * 0.5625 : w * 0.55,
      ));
    }
  }

  Future<void> _addUrl(bool compact) async {
    final ctrl = TextEditingController();
    MediaKind kind = MediaKind.video;
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Add from URL'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'https://… (video/이미지 링크, YouTube, Instagram 게시물)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            SegmentedButton<MediaKind>(
              segments: const [
                ButtonSegment(value: MediaKind.video, label: Text('Video')),
                ButtonSegment(value: MediaKind.image, label: Text('Image')),
                ButtonSegment(value: MediaKind.gif, label: Text('GIF')),
              ],
              selected: {kind},
              onSelectionChanged: (s) => setLocal(() => kind = s.first),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Add')),
          ],
        ),
      ),
    );
    if (added == true && ctrl.text.trim().isNotEmpty) {
      final url = ctrl.text.trim();
      // An Instagram post link expands into all of its photos/videos.
      if (isInstagramUrl(url)) {
        await _addInstagramPost(url, compact);
        return;
      }

      // Auto-detect what the link actually is (video / image / gif) so any URL
      // — a direct .mp4, an HLS/DASH stream, an image, or a web page with one
      // embedded clip — is routed to the right surface instead of being forced
      // into the video engine (which would error with "unsupported format").
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(const SnackBar(
        content: Text('링크 확인 중…'),
        duration: Duration(seconds: 13),
      ));
      ResolvedMedia? resolved;
      try {
        resolved = await resolveMedia(url);
      } catch (_) {}
      messenger.hideCurrentSnackBar();

      // Fall back to the user's manual Video/Image/GIF choice if we couldn't
      // classify the link. For a video, keep the original page URL as the
      // source so playback re-resolves and downloads/quality listing still
      // work; for an image, use the resolved direct image URL so it renders.
      final youtube = isYouTubeUrl(url);
      final resolvedKind = youtube ? MediaKind.video : (resolved?.kind ?? kind);
      final source =
          resolvedKind == MediaKind.video ? url : (resolved?.url ?? url);
      final w = compact ? 200.0 : 360.0;
      await controller.addItem(MediaItem(
        id: _newId(),
        kind: resolvedKind,
        sourceKind: SourceKind.network,
        source: source,
        title: youtube
            ? 'YouTube'
            : (resolvedKind == MediaKind.video ? 'Video' : 'URL ${resolvedKind.name}'),
        width: resolvedKind == MediaKind.video ? w : w * 0.72,
        height: resolvedKind == MediaKind.video ? w * 0.5625 : w * 0.55,
      ));
    }
  }

  /// Resolves an Instagram post and adds all of its photos/videos, with a
  /// loading + result snackbar.
  Future<void> _addInstagramPost(String url, bool compact) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
        content: Text('인스타그램 게시물을 불러오는 중…'),
        duration: Duration(seconds: 30)));
    int count;
    try {
      count = await controller.addInstagramPost(
        url,
        idFor: (_) => _newId(),
        compact: compact,
      );
    } catch (_) {
      count = 0;
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(count > 0
          ? '인스타그램 미디어 $count개를 추가했습니다.'
          : '인스타그램 게시물을 불러오지 못했습니다. (비공개이거나 로그인이 필요할 수 있어요)'),
    ));
  }

  MediaKind _kindFromExt(String ext) {
    const video = {'mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v', 'flv', 'ts'};
    if (ext == 'gif') return MediaKind.gif;
    if (video.contains(ext)) return MediaKind.video;
    return MediaKind.image;
  }

  // ---- Save / load -------------------------------------------------------

  Future<void> _save() async {
    final ctrl = TextEditingController(text: controller.boardName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save board'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Board name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      controller.boardName =
          ctrl.text.trim().isEmpty ? 'Untitled board' : ctrl.text.trim();
      await store.save(controller.exportState());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved "${controller.boardName}"')),
        );
      }
    }
  }

  Future<void> _load() async {
    final names = await store.listSaved();
    if (!mounted) return;
    if (names.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No saved boards yet')),
      );
      return;
    }
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Load board'),
        children: [
          for (final n in names)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, n),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  const Icon(Icons.dashboard_customize_outlined,
                      size: 18, color: AppColors.brass),
                  const SizedBox(width: 10),
                  Expanded(child: Text(n)),
                ]),
              ),
            ),
        ],
      ),
    );
    if (chosen != null) {
      final state = await store.load(chosen);
      await controller.loadState(state);
    }
  }

  // ---- Export / import to file ------------------------------------------

  Future<void> _exportBoardFile() async {
    final path = await store.exportBoardToFile(controller.exportState());
    if (!mounted) return;
    _toast(path != null
        ? 'Exported to ${_basename(path)}'
        : 'Export cancelled');
  }

  Future<void> _importBoardFile() async {
    final state = await store.importBoardFromFile();
    if (state == null) {
      if (mounted) _toast('Import cancelled');
      return;
    }
    await controller.loadState(state);
    if (mounted) _toast('Imported "${state.name}"');
  }

  /// Capture the board to a PNG — including live video frames — and save it.
  Future<void> _exportImage() async {
    if (controller.items.isEmpty) {
      _toast('Nothing to capture yet');
      return;
    }
    _toast('Rendering image…');
    try {
      final bytes = await BoardExporter(controller).renderPng(scale: 2.0);
      if (bytes == null) {
        if (mounted) _toast('Could not render image');
        return;
      }
      final name =
          '${controller.boardName.replaceAll(RegExp(r"[^a-zA-Z0-9 _-]"), "_")}.png';
      final path = await store.exportBytes(bytes, name, const ['png']);
      if (!mounted) return;
      _toast(path != null
          ? 'Saved image to ${_basename(path)}'
          : 'Export cancelled');
    } catch (e) {
      if (mounted) _toast('Image export failed');
    }
  }

  // ---- Fetch from a web page (URL library) -------------------------------

  /// Opens the "동영상 가져오기" screen, where the user pastes a site link to pull
  /// the embedded stream, play it in-app, download it, and save it for later.
  Future<void> _openSourcePage() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourcePage(
          controller: controller,
          linkStore: linkStore,
          newId: _newId,
        ),
      ),
    );
  }

  // ---- Settings ----------------------------------------------------------

  Future<void> _openSettings() async {
    final result = await Navigator.push<AppSettings?>(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(initial: controller.settings),
      ),
    );
    if (result != null) {
      controller.applySettings(result);
      await store.saveSettings(result);
      if (mounted) _toast('Settings saved');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  String _basename(String path) =>
      path.split(RegExp(r'[\\/]')).last;

  // ---- Mobile bottom sheet for layer / depth ----------------------------

  void _openLayerSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _LayerSheet(controller: controller),
    );
  }

  // ---- UI ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Responsive breakpoint: phones get the compact layout.
            final compact = constraints.maxWidth < 720;
            return Column(
              children: [
                if (_chromeVisible)
                  compact
                    ? _CompactBar(
                        boardName: controller.boardName,
                        count: controller.items.length,
                        onAddLocal: () => _pickLocal(true),
                        onAddUrl: () => _addUrl(true),
                        onFetch: _openSourcePage,
                        onPlayAll: controller.playAll,
                        onPauseAll: controller.pauseAll,
                        onMuteAll: controller.muteAll,
                        onUnmuteAll: controller.unmuteAll,
                        onSave: _save,
                        onLoad: _load,
                        onExportFile: _exportBoardFile,
                        onImportFile: _importBoardFile,
                        onExportImage: _exportImage,
                        onSettings: _openSettings,
                      )
                    : _WideBar(
                        boardName: controller.boardName,
                        count: controller.items.length,
                        onAddLocal: () => _pickLocal(false),
                        onAddUrl: () => _addUrl(false),
                        onFetch: _openSourcePage,
                        onPlayAll: controller.playAll,
                        onPauseAll: controller.pauseAll,
                        onMuteAll: controller.muteAll,
                        onUnmuteAll: controller.unmuteAll,
                        onSave: _save,
                        onLoad: _load,
                        onExportFile: _exportBoardFile,
                        onImportFile: _importBoardFile,
                        onExportImage: _exportImage,
                        onSettings: _openSettings,
                      ),
                Expanded(
                  child: _Canvas(
                    controller: controller,
                    compact: compact,
                    onBackgroundTap: _onBackgroundTap,
                  ),
                ),
                // Depth/rotation: inline dock on desktop, sheet trigger on mobile.
                if (controller.selected != null)
                  compact
                      ? _CompactSelectionBar(
                          controller: controller,
                          onMore: _openLayerSheet,
                        )
                      : _DepthDock(controller: controller),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ============================ Canvas ====================================

class _Canvas extends StatelessWidget {
  const _Canvas({
    required this.controller,
    required this.compact,
    required this.onBackgroundTap,
  });
  final BoardController controller;
  final bool compact;
  final VoidCallback onBackgroundTap;

  @override
  Widget build(BuildContext context) {
    final ordered = controller.itemsByDepth;
    return LayoutBuilder(
      builder: (context, c) {
        // Report canvas size so the controller can keep items on-screen.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          controller.setCanvasSize(Size(c.maxWidth, c.maxHeight));
        });
        return GestureDetector(
          onTap: onBackgroundTap,
          child: Container(
            width: double.infinity,
            height: double.infinity,
            color: AppColors.baseHi,
            child: Stack(
              children: [
                Positioned.fill(
                  child: _CanvasBackdrop(
                    style: controller.settings.canvasBackground,
                    gridSize: controller.settings.gridSize,
                  ),
                ),
                if (ordered.isEmpty) const _EmptyState(),
                for (final it in ordered)
                  BoardItemWidget(
                    key: ValueKey(it.id),
                    item: it,
                    controller: controller,
                    selected: controller.selectedId == it.id,
                    compact: compact,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CanvasBackdrop extends StatelessWidget {
  const _CanvasBackdrop({required this.style, required this.gridSize});
  final CanvasBackground style;
  final double gridSize;
  @override
  Widget build(BuildContext context) {
    if (style == CanvasBackground.solid) return const SizedBox.expand();
    return CustomPaint(
      painter: _BackdropPainter(style: style, step: gridSize.clamp(16, 80)),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({required this.style, required this.step});
  final CanvasBackground style;
  final double step;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.045);
    if (style == CanvasBackground.dots) {
      for (double x = step; x < size.width; x += step) {
        for (double y = step; y < size.height; y += step) {
          canvas.drawCircle(Offset(x, y), 1.0, paint);
        }
      }
    } else {
      paint.strokeWidth = 1;
      for (double x = step; x < size.width; x += step) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
      for (double y = step; y < size.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BackdropPainter old) =>
      old.style != style || old.step != step;
}

// ============================ Wide (desktop) bar ========================

class _WideBar extends StatelessWidget {
  const _WideBar({
    required this.boardName,
    required this.count,
    required this.onAddLocal,
    required this.onAddUrl,
    required this.onFetch,
    required this.onPlayAll,
    required this.onPauseAll,
    required this.onMuteAll,
    required this.onUnmuteAll,
    required this.onSave,
    required this.onLoad,
    required this.onExportFile,
    required this.onImportFile,
    required this.onExportImage,
    required this.onSettings,
  });
  final String boardName;
  final int count;
  final VoidCallback onAddLocal, onAddUrl, onFetch, onPlayAll, onPauseAll;
  final VoidCallback onMuteAll, onUnmuteAll, onSave, onLoad;
  final VoidCallback onExportFile, onImportFile, onExportImage, onSettings;

  @override
  Widget build(BuildContext context) {
    return _BarShell(
      child: Row(children: [
        const _Wordmark(),
        const SizedBox(width: 14),
        Flexible(
          child: Text(boardName,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: AppColors.text)),
        ),
        const SizedBox(width: 8),
        MicroLabel('$count items'),
        const Spacer(),
        // Controls scroll horizontally if the window gets narrow.
        Flexible(
          flex: 0,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(children: [
              _SegGroup(children: [
                _TBtn(Icons.video_call_outlined, 'Add files', onAddLocal),
                _TBtn(Icons.link, 'Add URL', onAddUrl),
                _TBtn(Icons.travel_explore, '동영상 가져오기', onFetch),
              ]),
              const SizedBox(width: 8),
              _SegGroup(children: [
                _TBtn(Icons.play_arrow_rounded, 'Play all', onPlayAll),
                _TBtn(Icons.pause_rounded, 'Pause all', onPauseAll),
                _TBtn(Icons.volume_up_rounded, 'Unmute all', onUnmuteAll),
                _TBtn(Icons.volume_off_rounded, 'Mute all', onMuteAll),
              ]),
              const SizedBox(width: 8),
              _SegGroup(children: [
                _TBtn(Icons.save_outlined, 'Save', onSave),
                _TBtn(Icons.folder_open_outlined, 'Load', onLoad),
                _ExportMenu(
                  onExportFile: onExportFile,
                  onImportFile: onImportFile,
                  onExportImage: onExportImage,
                ),
              ]),
              const SizedBox(width: 8),
              _SegGroup(children: [
                _TBtn(Icons.settings_outlined, 'Settings', onSettings),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Export / import overflow used in both layouts.
class _ExportMenu extends StatelessWidget {
  const _ExportMenu({
    required this.onExportFile,
    required this.onImportFile,
    required this.onExportImage,
  });
  final VoidCallback onExportFile, onImportFile, onExportImage;
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Export / import',
      icon: const Icon(Icons.ios_share, size: 20, color: AppColors.text),
      color: AppColors.panelHi,
      onSelected: (v) {
        switch (v) {
          case 'export':
            onExportFile();
          case 'image':
            onExportImage();
          case 'import':
            onImportFile();
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
            value: 'export',
            child: _MenuRow(Icons.description_outlined, 'Export board file')),
        PopupMenuItem(
            value: 'image',
            child: _MenuRow(Icons.image_outlined, 'Export as image')),
        PopupMenuDivider(),
        PopupMenuItem(
            value: 'import',
            child: _MenuRow(Icons.file_download_outlined, 'Import board file')),
      ],
    );
  }
}

// ============================ Compact (mobile) bar ======================

class _CompactBar extends StatelessWidget {
  const _CompactBar({
    required this.boardName,
    required this.count,
    required this.onAddLocal,
    required this.onAddUrl,
    required this.onFetch,
    required this.onPlayAll,
    required this.onPauseAll,
    required this.onMuteAll,
    required this.onUnmuteAll,
    required this.onSave,
    required this.onLoad,
    required this.onExportFile,
    required this.onImportFile,
    required this.onExportImage,
    required this.onSettings,
  });
  final String boardName;
  final int count;
  final VoidCallback onAddLocal, onAddUrl, onFetch, onPlayAll, onPauseAll;
  final VoidCallback onMuteAll, onUnmuteAll, onSave, onLoad;
  final VoidCallback onExportFile, onImportFile, onExportImage, onSettings;

  @override
  Widget build(BuildContext context) {
    return _BarShell(
      child: Row(children: [
        const _Wordmark(),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(boardName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: AppColors.text)),
              MicroLabel('$count items'),
            ],
          ),
        ),
        // Primary actions stay visible; the rest live in the overflow menu.
        _TBtn(Icons.play_arrow_rounded, 'Play all', onPlayAll),
        _TBtn(Icons.volume_up_rounded, 'Unmute all', onUnmuteAll),
        PopupMenuButton<String>(
          icon: const Icon(Icons.add_circle_outline, color: AppColors.brass),
          color: AppColors.panelHi,
          onSelected: (v) {
            switch (v) {
              case 'files':
                onAddLocal();
              case 'url':
                onAddUrl();
              case 'fetch':
                onFetch();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
                value: 'files',
                child: _MenuRow(Icons.video_call_outlined, 'Add files')),
            PopupMenuItem(
                value: 'url', child: _MenuRow(Icons.link, 'Add URL')),
            PopupMenuItem(
                value: 'fetch',
                child: _MenuRow(Icons.travel_explore, '동영상 가져오기')),
          ],
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: AppColors.text),
          color: AppColors.panelHi,
          onSelected: (v) {
            switch (v) {
              case 'pause':
                onPauseAll();
              case 'mute':
                onMuteAll();
              case 'save':
                onSave();
              case 'load':
                onLoad();
              case 'export':
                onExportFile();
              case 'image':
                onExportImage();
              case 'import':
                onImportFile();
              case 'settings':
                onSettings();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
                value: 'pause',
                child: _MenuRow(Icons.pause_rounded, 'Pause all')),
            PopupMenuItem(
                value: 'mute',
                child: _MenuRow(Icons.volume_off_rounded, 'Mute all')),
            PopupMenuDivider(),
            PopupMenuItem(
                value: 'save', child: _MenuRow(Icons.save_outlined, 'Save')),
            PopupMenuItem(
                value: 'load',
                child: _MenuRow(Icons.folder_open_outlined, 'Load')),
            PopupMenuItem(
                value: 'export',
                child: _MenuRow(
                    Icons.description_outlined, 'Export board file')),
            PopupMenuItem(
                value: 'image',
                child: _MenuRow(Icons.image_outlined, 'Export as image')),
            PopupMenuItem(
                value: 'import',
                child:
                    _MenuRow(Icons.file_download_outlined, 'Import board file')),
            PopupMenuDivider(),
            PopupMenuItem(
                value: 'settings',
                child: _MenuRow(Icons.settings_outlined, 'Settings')),
          ],
        ),
      ]),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label);
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 18, color: AppColors.text),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: AppColors.text)),
      ]);
}

// ============================ Shared chrome =============================

class _BarShell extends StatelessWidget {
  const _BarShell({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: SizedBox(height: 44, child: child),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: AppColors.brass,
          borderRadius: BorderRadius.circular(5),
        ),
        child: const Icon(Icons.layers_rounded, size: 14, color: AppColors.base),
      ),
    ]);
  }
}

/// A grouped pill of icon buttons — the console's repeated structural device.
class _SegGroup extends StatelessWidget {
  const _SegGroup({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panelHi,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.line),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _TBtn extends StatelessWidget {
  const _TBtn(this.icon, this.tip, this.onTap);
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, size: 20),
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(foregroundColor: AppColors.text),
      ),
    );
  }
}

// ============================ Depth dock (desktop) ======================

class _DepthDock extends StatelessWidget {
  const _DepthDock({required this.controller});
  final BoardController controller;
  @override
  Widget build(BuildContext context) {
    final sel = controller.selected!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Row(children: [
        const MicroLabel('Layer'),
        const SizedBox(width: 8),
        Flexible(
          child: Text(sel.title.isEmpty ? sel.kind.name : sel.title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.text)),
        ),
        const Spacer(),
        _SegGroup(children: [
          _TBtn(Icons.vertical_align_top, 'Bring to front',
              () => controller.bringToFront(sel.id)),
          _TBtn(Icons.arrow_upward, 'Forward',
              () => controller.bringForward(sel.id)),
          _TBtn(Icons.arrow_downward, 'Backward',
              () => controller.sendBackward(sel.id)),
          _TBtn(Icons.vertical_align_bottom, 'Send to back',
              () => controller.sendToBack(sel.id)),
        ]),
        const SizedBox(width: 12),
        _LabeledSlider(
          icon: Icons.rotate_right,
          value: sel.rotation,
          min: -180,
          max: 180,
          onChanged: (v) => controller.updateGeometry(sel.id, rotation: v),
        ),
        const SizedBox(width: 8),
        _LabeledSlider(
          icon: Icons.opacity,
          value: sel.opacity * 100,
          min: 5,
          max: 100,
          onChanged: (v) =>
              controller.updateGeometry(sel.id, opacity: v / 100),
        ),
      ]),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });
  final IconData icon;
  final double value, min, max;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 16, color: AppColors.textDim),
      SizedBox(
        width: 110,
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ),
    ]);
  }
}

// ============================ Mobile selection bar + sheet ==============

class _CompactSelectionBar extends StatelessWidget {
  const _CompactSelectionBar(
      {required this.controller, required this.onMore});
  final BoardController controller;
  final VoidCallback onMore;
  @override
  Widget build(BuildContext context) {
    final sel = controller.selected!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Row(children: [
        Expanded(
          child: Text(sel.title.isEmpty ? sel.kind.name : sel.title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.text)),
        ),
        _TBtn(Icons.vertical_align_top, 'Front',
            () => controller.bringToFront(sel.id)),
        _TBtn(Icons.vertical_align_bottom, 'Back',
            () => controller.sendToBack(sel.id)),
        _TBtn(Icons.tune, 'Adjust', onMore),
        _TBtn(Icons.delete_outline, 'Remove',
            () => controller.removeItem(sel.id)),
      ]),
    );
  }
}

class _LayerSheet extends StatefulWidget {
  const _LayerSheet({required this.controller});
  final BoardController controller;
  @override
  State<_LayerSheet> createState() => _LayerSheetState();
}

class _LayerSheetState extends State<_LayerSheet> {
  @override
  Widget build(BuildContext context) {
    final sel = widget.controller.selected;
    if (sel == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
              color: AppColors.line, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 16),
        Align(
            alignment: Alignment.centerLeft,
            child: MicroLabel('Adjust layer')),
        const SizedBox(height: 16),
        _sheetRow(Icons.rotate_right, 'Rotation', sel.rotation, -180, 180,
            (v) {
          widget.controller.updateGeometry(sel.id, rotation: v);
          setState(() {});
        }),
        _sheetRow(Icons.opacity, 'Opacity', sel.opacity * 100, 5, 100, (v) {
          widget.controller.updateGeometry(sel.id, opacity: v / 100);
          setState(() {});
        }),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () {
                widget.controller.bringForward(sel.id);
                setState(() {});
              },
              icon: const Icon(Icons.arrow_upward, size: 18),
              label: const Text('Forward'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () {
                widget.controller.sendBackward(sel.id);
                setState(() {});
              },
              icon: const Icon(Icons.arrow_downward, size: 18),
              label: const Text('Backward'),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _sheetRow(IconData icon, String label, double value, double min,
      double max, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(icon, size: 18, color: AppColors.textDim),
        const SizedBox(width: 10),
        SizedBox(width: 64, child: Text(label,
            style: const TextStyle(color: AppColors.textDim, fontSize: 12))),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ]),
    );
  }
}

// ============================ Empty state ===============================

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.line),
            ),
            child: const Icon(Icons.add_to_queue_rounded,
                size: 30, color: AppColors.brass),
          ),
          const SizedBox(height: 18),
          const Text('Build your board',
              style: TextStyle(
                  color: AppColors.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text(
            'Add videos, images, or GIFs. Drag to place,\nresize from the corner, layer with depth.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textDim, fontSize: 13, height: 1.5),
          ),
        ]),
      ),
    );
  }
}
