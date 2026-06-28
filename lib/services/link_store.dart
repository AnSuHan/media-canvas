import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/video_source.dart';

/// Persists the in-app **URL library** — the links the user saved on the
/// "동영상 가져오기" screen to replay or re-download later.
///
/// Stored as a single `links.json` in the same app-documents folder the board
/// layouts use, so everything the app keeps lives in one place. Newest links
/// are returned first.
class LinkStore {
  /// Overridable for tests (point it at a temp dir); production resolves the
  /// platform app-documents directory.
  Directory? overrideDir;

  Future<Directory> _dir() async {
    final override = overrideDir;
    if (override != null) {
      if (!await override.exists()) await override.create(recursive: true);
      return override;
    }
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/media_canvas');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file() async => File('${(await _dir()).path}/links.json');

  /// All saved links, newest first. Returns an empty list when nothing is saved
  /// or the file is unreadable.
  Future<List<SavedLink>> list() async {
    final file = await _file();
    if (!await file.exists()) return [];
    try {
      final links = SavedLink.decode(await file.readAsString());
      links.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      return links;
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeAll(List<SavedLink> links) async {
    final file = await _file();
    await file.writeAsString(SavedLink.encode(links));
  }

  /// Adds [link], replacing any existing entry with the same URL (so re-saving
  /// a link just refreshes its title/thumbnail and bumps it to the top).
  Future<List<SavedLink>> add(SavedLink link) async {
    final links = await list();
    links.removeWhere((e) => e.url == link.url);
    links.insert(0, link);
    await _writeAll(links);
    return links;
  }

  /// Removes the link with [url]. Returns the remaining links.
  Future<List<SavedLink>> remove(String url) async {
    final links = await list();
    links.removeWhere((e) => e.url == url);
    await _writeAll(links);
    return links;
  }

  /// True if [url] is already in the library.
  Future<bool> contains(String url) async =>
      (await list()).any((e) => e.url == url);
}
