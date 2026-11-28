import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/comic_details_cache.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/foundation/app.dart';

ComicDetails details(String id, {String? subtitle, int chapters = 2}) {
  return ComicDetails.fromJson({
    'title': '漫画 $id',
    'subtitle': subtitle,
    'cover': 'https://example.com/$id.jpg',
    'description': 'desc',
    'tags': {'作者': ['某作者']},
    'chapters': {
      for (var i = 1; i <= chapters; i++) 'ep-$i': '第 $i 话',
    },
    'sourceKey': 'demo',
    'comicId': id,
    'subTitle': subtitle,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = Directory.systemTemp.createTempSync('venera_details_cache_');
  setUp(() {
    App.dataPath = root.path;
  });
  tearDownAll(() {
    root.deleteSync(recursive: true);
  });

  test('write then read restores details, subtitle and chapters', () async {
    final cache = ComicDetailsCache.instance;
    await cache.invalidate('demo', 'a');
    await cache.write('demo', 'a', details('a', subtitle: '副标题'));

    final memory = await cache.read('demo', 'a');
    expect(memory, isNotNull);
    expect(memory!.title, '漫画 a');
    expect(memory.subTitle, '副标题');
    expect(memory.chapters!.length, 2);

    // Drop the memory entry by filling past the LRU cap, then read from disk.
    for (var i = 0; i < 40; i++) {
      await cache.write('demo', 'fill-$i', details('fill-$i'));
    }
    final disk = await cache.read('demo', 'a');
    expect(disk, isNotNull);
    expect(disk!.title, '漫画 a');
    expect(disk.subTitle, '副标题');
    expect(disk.chapters!.length, 2);
  });

  test('invalidate removes both memory and disk entry', () async {
    final cache = ComicDetailsCache.instance;
    await cache.write('demo', 'b', details('b'));
    await cache.invalidate('demo', 'b');
    expect(await cache.read('demo', 'b'), isNull);
  });

  test('invalidateSource drops one source and keeps the others', () async {
    final cache = ComicDetailsCache.instance;
    await cache.write('switch-src', 'one', details('one'));
    await cache.write('switch-src', 'two', details('two'));
    await cache.write('other-src', 'one', details('one'));

    await cache.invalidateSource('switch-src');

    expect(await cache.read('switch-src', 'one'), isNull);
    expect(await cache.read('switch-src', 'two'), isNull);
    expect(await cache.read('other-src', 'one'), isNotNull);
  });
}
