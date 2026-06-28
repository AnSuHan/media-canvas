import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/media_item.dart';
import '../models/video_source.dart';
import '../services/board_controller.dart';
import '../services/download/download.dart';
import '../services/link_store.dart';
import '../services/page_video_resolver.dart';
import '../services/ytdlp.dart';
import '../theme.dart';
import 'log_page.dart';

/// The "동영상 가져오기" screen: paste a site link (e.g. a VOD page reached over a
/// VPN), and the app pulls the underlying stream out of the page so it can be
/// **played inside the app** or **downloaded** — and saved to a **URL library**
/// for later. Works for Cloudflare-TLS-protected hosts via the bundled,
/// browser-impersonating yt-dlp.
class SourcePage extends StatefulWidget {
  const SourcePage({
    super.key,
    required this.controller,
    required this.linkStore,
    required this.newId,
  });

  final BoardController controller;
  final LinkStore linkStore;

  /// Supplies a unique id when adding a fetched video to the board.
  final String Function() newId;

  @override
  State<SourcePage> createState() => _SourcePageState();
}

class _SourcePageState extends State<SourcePage> {
  final _urlCtrl = TextEditingController();
  bool _busy = false;
  VideoSource? _resolved;
  String? _error;
  List<SavedLink> _links = [];

  @override
  void initState() {
    super.initState();
    _loadLinks();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLinks() async {
    final links = await widget.linkStore.list();
    if (mounted) setState(() => _links = links);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- Fetch page info ---------------------------------------------------

  Future<void> _fetch() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _resolved = null;
    });
    VideoSource? src;
    try {
      src = await resolveVideoSource(url);
    } catch (_) {
      src = null;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _resolved = src;
      _error = src == null
          ? '이 페이지에서 재생할 수 있는 동영상을 찾지 못했어요. 주소를 확인해 주세요.'
          : null;
    });
  }

  // ---- Play in app (add to board) ---------------------------------------

  Future<void> _playInApp(VideoSource src) async {
    // Keep the *page* URL as the item source so the board re-resolves it (and
    // routes through the impersonating proxy when needed) at playback time.
    await widget.controller.addItem(MediaItem(
      id: widget.newId(),
      kind: MediaKind.video,
      sourceKind: SourceKind.network,
      source: src.pageUrl,
      title: src.title.isEmpty ? 'Video' : src.title,
      width: 480,
      height: 270,
    ));
    if (mounted) {
      Navigator.of(context).pop();
      _toast('보드에 추가했어요. 재생을 시작합니다.');
    }
  }

  // ---- Save / remove in library -----------------------------------------

  Future<void> _save(VideoSource src) async {
    final links = await widget.linkStore.add(SavedLink(
      url: src.pageUrl,
      title: src.title,
      thumbnail: src.thumbnail,
    ));
    if (mounted) {
      setState(() => _links = links);
      _toast('라이브러리에 저장했어요.');
    }
  }

  Future<void> _removeLink(SavedLink link) async {
    final links = await widget.linkStore.remove(link.url);
    if (mounted) setState(() => _links = links);
  }

  Future<void> _useLink(SavedLink link) async {
    _urlCtrl.text = link.url;
    await _fetch();
  }

  // ---- Download ----------------------------------------------------------

  /// Downloads [src] to a user-chosen file with a cancellable progress dialog.
  /// Reuses the board's quality listing (which returns a browser-impersonating
  /// yt-dlp option for TLS-protected hosts) so the page download behaves exactly
  /// like the board's long-press download.
  Future<void> _download(VideoSource src) async {
    const downloader = VideoDownloader();

    // A throwaway item lets us reuse BoardController.listDownloadOptions.
    final probe = MediaItem(
      id: 'src-probe',
      kind: MediaKind.video,
      sourceKind: SourceKind.network,
      source: src.pageUrl,
    );

    var version = '';
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    if (!mounted) return;

    // 1) List qualities behind a brief loading dialog.
    _showBlockingLoader('화질 정보를 불러오는 중…');
    List<DownloadOption> options;
    try {
      options = await widget.controller.listDownloadOptions(probe);
    } catch (_) {
      options = const [];
    }
    _dismissDialog();
    options =
        options.where((o) => o.isYtDlp || downloader.canDownload(o.url)).toList();
    if (options.isEmpty) {
      _toast('이 주소는 동영상 파일로 저장할 수 없습니다.');
      return;
    }

    final option = options.first;

    // 2) Ask where to save.
    final suggested = downloader.suggestName(
      src.title,
      option.url,
      version: version,
      quality: option.label,
    );
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
    if (savePath == null) return;
    if (!savePath.contains('.')) savePath = '$savePath.mp4';
    if (!mounted) return;

    // 3) Download with progress + cancel.
    final progress = ValueNotifier<double>(0);
    final client = http.Client();
    Process? ytProc;
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
              client.close();
              ytProc?.kill();
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
      if (option.isYtDlp) {
        writtenPath = await ytDlpDownload(
          option.ytdlpUrl!,
          saveTo,
          format: option.ytdlpFormat,
          impersonate: option.impersonate,
          referer: option.referer,
          onStart: (proc) => ytProc = proc,
          onProgress: (f) {
            if (f != null) progress.value = f;
          },
        );
      } else {
        writtenPath = await downloader.downloadOption(
          option,
          saveTo,
          client: client,
          onProgress: (f) {
            if (f != null) progress.value = f;
          },
        );
      }
      closeDialog();
      _toast('저장 완료: $writtenPath');
    } catch (e) {
      closeDialog();
      if (!cancelled) _toast('다운로드 실패: $e');
      try {
        await File(writtenPath).delete();
      } catch (_) {}
    } finally {
      client.close();
      progress.dispose();
    }
  }

  void _showBlockingLoader(String label) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 16),
            Text(label),
          ],
        ),
      ),
    );
  }

  void _dismissDialog() {
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  // ---- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.base,
      appBar: AppBar(
        backgroundColor: AppColors.panel,
        foregroundColor: AppColors.text,
        title: const Text('동영상 가져오기'),
        actions: [
          IconButton(
            tooltip: '진단 로그',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LogPage()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _inputRow(),
          const SizedBox(height: 12),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) _errorBanner(_error!),
          if (_resolved != null) _preview(_resolved!),
          const SizedBox(height: 24),
          const _SectionLabel('저장한 링크'),
          const SizedBox(height: 8),
          if (_links.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('아직 저장한 링크가 없어요.',
                  style: TextStyle(color: AppColors.textDim)),
            )
          else
            for (final link in _links) _linkTile(link),
        ],
      ),
    );
  }

  Widget _inputRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _urlCtrl,
            autofocus: true,
            style: const TextStyle(color: AppColors.text),
            onSubmitted: (_) => _busy ? null : _fetch(),
            decoration: const InputDecoration(
              hintText: 'https://… (동영상 페이지 주소)',
              hintStyle: TextStyle(color: AppColors.textDim),
              border: OutlineInputBorder(),
              enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.line)),
            ),
          ),
        ),
        const SizedBox(width: 10),
        FilledButton.icon(
          onPressed: _busy ? null : _fetch,
          icon: const Icon(Icons.travel_explore, size: 18),
          label: const Text('가져오기'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.brass,
            foregroundColor: AppColors.base,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
          ),
        ),
      ],
    );
  }

  Widget _errorBanner(String msg) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panelHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        const Icon(Icons.error_outline, color: AppColors.danger, size: 18),
        const SizedBox(width: 8),
        Expanded(
            child:
                Text(msg, style: const TextStyle(color: AppColors.text))),
      ]),
    );
  }

  Widget _preview(VideoSource src) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (src.thumbnail != null)
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(10)),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  src.thumbnail!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      Container(color: AppColors.well),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  src.title.isEmpty ? '(제목 없음)' : src.title,
                  style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  src.pageUrl,
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (src.needsImpersonation)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(children: [
                      const Icon(Icons.shield_outlined,
                          size: 14, color: AppColors.brass),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '보호된 스트림 — 브라우저 위장으로 재생·다운로드합니다.',
                          style: TextStyle(
                              color: AppColors.brass.withValues(alpha: 0.9),
                              fontSize: 11),
                        ),
                      ),
                    ]),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _playInApp(src),
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('앱에서 재생'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brass,
                        foregroundColor: AppColors.base,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _download(src),
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('다운로드'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.text,
                        side: const BorderSide(color: AppColors.line),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _save(src),
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      label: const Text('라이브러리에 저장'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.text,
                        side: const BorderSide(color: AppColors.line),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkTile(SavedLink link) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.line),
      ),
      child: ListTile(
        leading: link.thumbnail != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  link.thumbnail!,
                  width: 56,
                  height: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.movie_outlined, color: AppColors.brass),
                ),
              )
            : const Icon(Icons.movie_outlined, color: AppColors.brass),
        title: Text(
          link.title.isEmpty ? link.url : link.title,
          style: const TextStyle(color: AppColors.text, fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          link.url,
          style: const TextStyle(color: AppColors.textDim, fontSize: 11),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => _useLink(link),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: AppColors.textDim),
          tooltip: '삭제',
          onPressed: () => _removeLink(link),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: AppColors.brass,
          fontSize: 13,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w600,
        ),
      );
}
