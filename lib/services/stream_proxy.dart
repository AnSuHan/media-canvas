import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'ytdlp.dart';

/// A tiny local HTTP server that lets libmpv play streams whose CDN blocks
/// non-browser clients (a Cloudflare TLS-fingerprint block).
///
/// Why it's needed
/// ---------------
/// Some VOD hosts 403 *every* non-browser client — libmpv, Dart's http, plain
/// curl — regardless of headers; only a real browser TLS handshake passes. The
/// bundled yt-dlp ships curl_cffi and can reproduce that handshake
/// (`--impersonate chrome`). libmpv can't. So we put yt-dlp in the middle:
///
///   libmpv ──http──▶ 127.0.0.1:PORT ──spawns──▶ yt-dlp --impersonate chrome
///                                                  │ (browser TLS + Referer)
///                                                  ▼
///                                          Cloudflare-protected CDN
///
/// yt-dlp streams the muxed video as MPEG-TS to its stdout; this server pipes
/// those bytes straight to libmpv over plain localhost http (no Cloudflare in
/// the way). The TS container is playable while still downloading.
class StreamProxy {
  StreamProxy._();
  static final StreamProxy instance = StreamProxy._();

  HttpServer? _server;
  int _seq = 0;

  /// Pending stream descriptors keyed by id, consumed when libmpv connects.
  final Map<String, _Stream> _streams = {};

  /// Live yt-dlp processes, so [shutdown] can kill any still running.
  final Set<Process> _live = {};

  /// Registers [streamUrl] and returns a `http://127.0.0.1:PORT/s/<id>` URL for
  /// libmpv to open. Returns null when yt-dlp isn't bundled (caller falls back
  /// to handing the raw URL to libmpv).
  Future<String?> proxiedUrl({
    required String streamUrl,
    String? referer,
    String format = 'best',
  }) async {
    if (!ytDlpAvailable()) {
      logDiag('proxy', 'yt-dlp 없음 → 위장 프록시 사용 불가 (재생/다운로드 실패 가능)');
      return null;
    }
    final server = await _ensureServer();
    final id = (++_seq).toString();
    _streams[id] = _Stream(streamUrl, referer, format);
    final url = 'http://127.0.0.1:${server.port}/s/$id';
    logDiag('proxy', '등록 id=$id → $url (referer=$referer)');
    return url;
  }

  Future<HttpServer> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing;
    // Bind to loopback only — this is a private bridge, never exposed.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (_) {});
    return server;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    if (segments.length != 2 || segments.first != 's') {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final stream = _streams[segments[1]];
    if (stream == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    logDiag('proxy', 'libmpv 연결: ${request.method} ${request.uri.path}');
    Process? proc;
    try {
      proc = await ytDlpStreamMpegTs(
        stream.url,
        referer: stream.referer,
        format: stream.format,
      );
      _live.add(proc);
      logDiag('proxy', 'yt-dlp 스폰(impersonate) pid=${proc.pid}, 첫 바이트 대기…');
      // A continuous MPEG-TS byte stream — served without a Content-Length so
      // libmpv reads it progressively as a live source.
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType('video', 'mp2t');
      response.headers.set(HttpHeaders.acceptRangesHeader, 'none');
      response.headers.set(HttpHeaders.connectionHeader, 'close');
      response.bufferOutput = false;

      // Flush the response headers *immediately*, before yt-dlp has produced
      // any bytes. yt-dlp needs a few seconds to warm up (browser-TLS handshake
      // + fetch the m3u8 + first segment); without this, libmpv would sit with
      // no HTTP response and hit its open-timeout, failing with "Failed to open"
      // even though bytes were on the way.
      await response.flush();
      logDiag('proxy', 'HTTP 200 헤더 전송 완료 (libmpv 가 연결 유지)');

      // Surface yt-dlp's stderr (warnings/errors) into the in-app log so a
      // failure cause is visible; also drains the pipe so it never stalls.
      var bytes = 0;
      proc.stderr
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final l = line.trim();
        if (l.isNotEmpty) logDiag('yt-dlp', l);
      }, onError: (_) {});

      await response.addStream(proc.stdout.map((chunk) {
        bytes += chunk.length;
        return chunk;
      }));
      await response.close();
      final code = await proc.exitCode;
      logDiag('proxy', 'yt-dlp 종료 code=$code, 전송 ${bytes ~/ 1024}KB');
    } catch (e) {
      logDiag('proxy', '오류: $e');
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    } finally {
      if (proc != null) {
        proc.kill(); // stop yt-dlp the moment libmpv disconnects
        _live.remove(proc);
      }
    }
  }

  /// Stops the server and kills any in-flight yt-dlp processes. Safe to call
  /// when nothing is running.
  Future<void> shutdown() async {
    for (final p in _live) {
      p.kill();
    }
    _live.clear();
    _streams.clear();
    await _server?.close(force: true);
    _server = null;
  }
}

class _Stream {
  _Stream(this.url, this.referer, this.format);
  final String url;
  final String? referer;
  final String format;
}
