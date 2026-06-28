import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_log.dart';
import '../theme.dart';

/// In-app diagnostic log viewer. Shows the timestamped trace of resolution,
/// the impersonation probe, the local proxy, yt-dlp and libmpv — so when a
/// video won't play or download, the user (or a bug report) can see exactly
/// where it failed. Auto-follows new lines; copy/clear available.
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    AppLog.instance.changes.listen((_) {
      if (mounted) {
        setState(() {});
        // Auto-scroll to the newest line after the frame lays out.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Saves the entire log to a user-chosen `.txt` file in one action (the
  /// native save dialog), so it can be attached to a bug report or kept.
  Future<void> _saveToFile() async {
    final messenger = ScaffoldMessenger.of(context);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '')
        .replaceAll('-', '')
        .substring(0, 15);
    final bytes = utf8.encode(AppLog.instance.dump());
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '로그 저장',
        fileName: 'media_canvas_log_$stamp.txt',
        bytes: bytes, // required on Android/iOS; honored on desktop too
        type: FileType.custom,
        allowedExtensions: const ['txt'],
      );
      messenger.showSnackBar(SnackBar(
        content: Text(path != null ? '로그를 저장했습니다: $path' : '저장이 취소되었습니다.'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('로그 저장 실패: $e')));
    }
  }

  Color _tagColor(String line) {
    if (line.contains('실패') ||
        line.contains('오류') ||
        line.contains('error') ||
        line.contains('ERROR') ||
        line.contains('예외') ||
        line.contains('불가')) {
      return AppColors.danger;
    }
    if (line.contains('[libmpv]') ||
        line.contains('[yt-dlp]') ||
        line.contains('[proxy]')) {
      return AppColors.brass;
    }
    return AppColors.textDim;
  }

  @override
  Widget build(BuildContext context) {
    final lines = AppLog.instance.lines;
    return Scaffold(
      backgroundColor: AppColors.base,
      appBar: AppBar(
        backgroundColor: AppColors.panel,
        foregroundColor: AppColors.text,
        title: const Text('진단 로그'),
        actions: [
          IconButton(
            tooltip: '복사',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: lines.isEmpty
                ? null
                : () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(
                        ClipboardData(text: AppLog.instance.dump()));
                    messenger.showSnackBar(
                      const SnackBar(content: Text('로그를 복사했습니다.')),
                    );
                  },
          ),
          IconButton(
            tooltip: '파일로 저장(다운로드)',
            icon: const Icon(Icons.download_outlined),
            onPressed: lines.isEmpty ? null : _saveToFile,
          ),
          IconButton(
            tooltip: '지우기',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => AppLog.instance.clear(),
          ),
        ],
      ),
      body: lines.isEmpty
          ? const Center(
              child: Text(
                '아직 기록된 로그가 없습니다.\n동영상을 재생하거나 다운로드해 보세요.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textDim),
              ),
            )
          : Scrollbar(
              controller: _scroll,
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                itemCount: lines.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1.5),
                  child: SelectableText(
                    lines[i],
                    style: TextStyle(
                      color: _tagColor(lines[i]),
                      fontSize: 12,
                      fontFamily: 'monospace',
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
