import 'dart:async';

/// A tiny in-app diagnostic log so the user can see *why* a video failed to
/// play or download, right inside the app (no console needed).
///
/// Every interesting step — page resolution, the impersonation probe, the local
/// proxy spawning yt-dlp, libmpv's own errors, download exit codes — appends a
/// timestamped line here. The log viewer ([LogPage]) renders these and lets the
/// user copy them.
///
/// Deliberately depends on `dart:async` only (no Flutter), so the lowest-level
/// services can record to it without pulling in UI dependencies.
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const _max = 800;
  final List<String> _lines = [];
  final _changes = StreamController<void>.broadcast();

  /// Notifies whenever a line is added or the log is cleared.
  Stream<void> get changes => _changes.stream;

  List<String> get lines => List.unmodifiable(_lines);

  /// Appends a timestamped `HH:mm:ss.mmm [tag] message` line.
  void log(String tag, String message) {
    final t = DateTime.now().toIso8601String();
    // keep just the HH:mm:ss.mmm part
    final hms = t.length >= 23 ? t.substring(11, 23) : t;
    _lines.add('$hms [$tag] $message');
    if (_lines.length > _max) _lines.removeRange(0, _lines.length - _max);
    if (!_changes.isClosed) _changes.add(null);
  }

  void clear() {
    _lines.clear();
    if (!_changes.isClosed) _changes.add(null);
  }

  /// The whole log as one string (for copy-to-clipboard).
  String dump() => _lines.join('\n');
}

/// Convenience shorthand used throughout the services.
void logDiag(String tag, String message) => AppLog.instance.log(tag, message);
