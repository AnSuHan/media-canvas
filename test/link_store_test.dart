// Offline unit tests for the URL library store. They write to a temp dir
// (via overrideDir) so nothing touches the real app-documents folder, and pin
// the add/list/remove/dedupe behavior the "동영상 가져오기" library relies on.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:media_canvas/models/video_source.dart';
import 'package:media_canvas/services/link_store.dart';

void main() {
  late Directory tmp;
  late LinkStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mc_links_test');
    store = LinkStore()..overrideDir = tmp;
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('starts empty', () async {
    expect(await store.list(), isEmpty);
    expect(await store.contains('https://x'), isFalse);
  });

  test('add then list returns the saved link', () async {
    await store.add(SavedLink(url: 'https://a.tv/1', title: 'One'));
    final links = await store.list();
    expect(links.length, 1);
    expect(links.first.url, 'https://a.tv/1');
    expect(links.first.title, 'One');
    expect(await store.contains('https://a.tv/1'), isTrue);
  });

  test('newest links sort first', () async {
    await store.add(SavedLink(
        url: 'https://a.tv/old',
        addedAt: DateTime(2020, 1, 1)));
    await store.add(SavedLink(
        url: 'https://a.tv/new',
        addedAt: DateTime(2025, 1, 1)));
    final links = await store.list();
    expect(links.map((e) => e.url).toList(),
        ['https://a.tv/new', 'https://a.tv/old']);
  });

  test('re-adding the same URL dedupes and bumps to top', () async {
    await store.add(SavedLink(url: 'https://a.tv/1', title: 'first'));
    await store.add(SavedLink(url: 'https://a.tv/2', title: 'second'));
    await store.add(SavedLink(url: 'https://a.tv/1', title: 'updated'));
    final links = await store.list();
    expect(links.length, 2);
    expect(links.first.url, 'https://a.tv/1');
    expect(links.first.title, 'updated');
  });

  test('remove deletes the link', () async {
    await store.add(SavedLink(url: 'https://a.tv/1'));
    await store.add(SavedLink(url: 'https://a.tv/2'));
    final left = await store.remove('https://a.tv/1');
    expect(left.map((e) => e.url), ['https://a.tv/2']);
    expect(await store.contains('https://a.tv/1'), isFalse);
  });

  test('survives a corrupt file (returns empty instead of throwing)', () async {
    await File('${tmp.path}/links.json').writeAsString('{not valid json');
    expect(await store.list(), isEmpty);
  });
}
