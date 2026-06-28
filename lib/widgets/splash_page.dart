import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/app_log.dart';
import '../services/ytdlp.dart';
import '../theme.dart';

/// First screen shown on launch. It prepares the playback engine before the
/// board opens:
///
/// * **Windows** — if the bundled `yt-dlp.exe` is missing (antivirus removed it,
///   single-exe extraction failed, …), it downloads the official build here,
///   with a progress bar, so Cloudflare-protected sites work right away.
/// * **Android** — yt-dlp can't run (Windows-only binary; Android blocks
///   executing downloaded binaries), so this just reports readiness. Protected
///   sites fall back to the in-app WebView player and **may not always play**.
///
/// Either way the splash hands off to the board quickly; it never blocks longer
/// than the (one-time) Windows download.
class SplashPage extends StatefulWidget {
  const SplashPage({super.key, required this.onReady});

  /// Builds the screen to show once preparation finishes.
  final WidgetBuilder onReady;

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  String _status = '준비 중…';
  double? _progress; // null = indeterminate

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    logDiag('app', '시작 — ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    try {
      final info = await PackageInfo.fromPlatform();
      logDiag('app', '버전 ${info.version} (${info.buildNumber})');
    } catch (_) {}

    if (Platform.isWindows) {
      if (ytDlpAvailable()) {
        logDiag('app', 'yt-dlp 사용 가능: ${ytDlpExecutable()}');
        _set('재생 엔진 준비 완료', 1);
      } else {
        _set('yt-dlp 준비 중… (최초 1회 다운로드)', null);
        final path = await ensureYtDlpAvailable(onProgress: (f) {
          if (mounted) {
            setState(() {
              _progress = f;
              _status = f == null
                  ? 'yt-dlp 준비 중…'
                  : 'yt-dlp 다운로드 ${(f * 100).toStringAsFixed(0)}%';
            });
          }
        });
        _set(
          path != null
              ? '재생 엔진 준비 완료'
              : 'yt-dlp 준비 실패 — 보호 사이트는 안 될 수 있어요(설정→진단 로그 확인)',
          1,
        );
      }
    } else {
      // Android / others: nothing to provision (no runnable yt-dlp).
      logDiag('app', '${Platform.operatingSystem}: yt-dlp 미지원 — 보호 사이트는 WebView 로 시도(재생 안 될 수 있음)');
      _set('준비 완료', 1);
    }

    // Brief beat so the user perceives the splash, then hand off.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: widget.onReady),
    );
  }

  void _set(String status, double? progress) {
    if (mounted) {
      setState(() {
        _status = status;
        _progress = progress;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.base,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_filter_outlined,
                size: 72, color: AppColors.brass),
            const SizedBox(height: 18),
            const Text(
              'Media Canvas',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 240,
              child: LinearProgressIndicator(
                value: _progress,
                backgroundColor: AppColors.panelHi,
                color: AppColors.brass,
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: 280,
              child: Text(
                _status,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textDim, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
