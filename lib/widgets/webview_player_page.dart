import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/app_log.dart';
import '../theme.dart';

/// Android fallback player for Cloudflare-TLS-protected sites.
///
/// The desktop path (yt-dlp browser impersonation) isn't available on Android,
/// so for these sites we open the page in a real WebView — which carries
/// Chrome's TLS fingerprint and therefore passes the same Cloudflare check.
/// The site plays in its own embedded player.
///
/// This is best-effort: some sites still won't play in a WebView (aggressive
/// anti-embedding, login walls, codecs), so playback is **not guaranteed** on
/// Android.
class WebViewPlayerPage extends StatefulWidget {
  const WebViewPlayerPage({super.key, required this.url, this.title = ''});

  final String url;
  final String title;

  @override
  State<WebViewPlayerPage> createState() => _WebViewPlayerPageState();
}

class _WebViewPlayerPageState extends State<WebViewPlayerPage> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    logDiag('webview', '열기: ${widget.url}');
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/124.0 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (e) {
          logDiag('webview', '오류: ${e.errorCode} ${e.description}');
          if (mounted && e.isForMainFrame == true) {
            setState(() => _error = e.description);
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.base,
      appBar: AppBar(
        backgroundColor: AppColors.panel,
        foregroundColor: AppColors.text,
        title: Text(widget.title.isEmpty ? '웹 재생' : widget.title,
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '새로고침',
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_error == null)
            WebViewWidget(controller: _controller)
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '이 사이트는 Android 에서 재생되지 않을 수 있어요.\n($_error)\n\n'
                  '데스크톱(Windows) 앱에서는 정상 재생·다운로드됩니다.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textDim),
                ),
              ),
            ),
          if (_loading && _error == null)
            const Center(
              child: CircularProgressIndicator(color: AppColors.brass),
            ),
        ],
      ),
    );
  }
}
