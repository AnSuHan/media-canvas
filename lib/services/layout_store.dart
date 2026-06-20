import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../models/media_item.dart';

/// Saves and loads board layouts + app settings, and exports boards to a
/// user-chosen file via the native save dialog.
///
/// Boards live as `<name>.board.json` in the app documents directory; settings
/// live in a single `settings.json`.
class LayoutStore {
  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/media_canvas');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _safe(String name) =>
      name.replaceAll(RegExp(r'[^a-zA-Z0-9 _-]'), '_').trim();

  Future<File> _fileFor(String name) async {
    final dir = await _dir();
    return File('${dir.path}/${_safe(name)}.board.json');
  }

  // ---- Boards (internal storage) ----------------------------------------

  Future<void> save(BoardState board) async {
    final file = await _fileFor(board.name);
    await file.writeAsString(board.toJsonString());
  }

  Future<BoardState> load(String name) async {
    final file = await _fileFor(name);
    return BoardState.fromJsonString(await file.readAsString());
  }

  Future<List<String>> listSaved() async {
    final dir = await _dir();
    final files =
        await dir.list().where((e) => e.path.endsWith('.board.json')).toList();
    return files
        .map((e) => e.uri.pathSegments.last.replaceAll('.board.json', ''))
        .toList()
      ..sort();
  }

  Future<void> delete(String name) async {
    final file = await _fileFor(name);
    if (await file.exists()) await file.delete();
  }

  // ---- Export / import to an arbitrary file -----------------------------

  /// Write the board JSON to a location the user picks. Returns the saved
  /// path, or null if cancelled.
  Future<String?> exportBoardToFile(BoardState board) async {
    final bytes = utf8.encode(board.toJsonString());
    return FilePicker.platform.saveFile(
      dialogTitle: 'Export board',
      fileName: '${_safe(board.name)}.board.json',
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
  }

  /// Write raw bytes (e.g. a PNG snapshot) to a user-picked location.
  Future<String?> exportBytes(
    List<int> bytes,
    String fileName,
    List<String> extensions,
  ) async {
    return FilePicker.platform.saveFile(
      dialogTitle: 'Export',
      fileName: fileName,
      bytes: Uint8List.fromList(bytes),
      type: FileType.custom,
      allowedExtensions: extensions,
    );
  }

  /// Let the user pick a `.board.json` and parse it.
  Future<BoardState?> importBoardFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import board',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final f = result.files.first;
    String content;
    if (f.bytes != null) {
      content = utf8.decode(f.bytes!);
    } else if (f.path != null) {
      content = await File(f.path!).readAsString();
    } else {
      return null;
    }
    return BoardState.fromJsonString(content);
  }

  // ---- Settings ----------------------------------------------------------

  Future<File> _settingsFile() async {
    final dir = await _dir();
    return File('${dir.path}/settings.json');
  }

  Future<AppSettings> loadSettings() async {
    final file = await _settingsFile();
    if (!await file.exists()) return AppSettings();
    try {
      return AppSettings.fromJsonString(await file.readAsString());
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings s) async {
    final file = await _settingsFile();
    await file.writeAsString(s.toJsonString());
  }

  Future<String> get directoryPath async => (await _dir()).path;
}
