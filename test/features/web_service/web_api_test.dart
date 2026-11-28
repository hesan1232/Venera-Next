import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/web_service/web_api.dart';
import 'package:venera_next/features/web_service/web_models.dart';

void main() {
  WebComicInfo comic(String id) => WebComicInfo(
    id: id,
    source: 'demo',
    title: 'Title $id',
    cover: webImageUrl(
      ref: 'https://example.com/$id.jpg',
      kind: WebImageKind.cover,
    ),
  );

  late List<Object?> calls;
  late WebApi api;

  setUp(() {
    calls = [];
    api = WebApi(
      WebApiDeps(
        sources: () async => const [
          WebSourceInfo(
            key: 'demo',
            name: 'Demo',
            searchable: true,
            local: false,
          ),
        ],
        bookshelf: () async => [
          comic('1').copyWith(
            progress: const WebProgressInfo(chapter: 3, page: 7, maxPage: 20),
          ),
        ],
        search: (keyword, source, page, next) async {
          calls.add(['search', keyword, source, page, next]);
          return WebSearchPage(
            comics: [comic(keyword)],
            source: source,
            page: page,
          );
        },
        detail: (source, id) async {
          calls.add(['detail', source, id]);
          return WebComicDetail(
            comic: comic(id),
            chapters: const [
              WebChapterInfo(index: 1, id: 'ep_1', title: 'One'),
            ],
          );
        },
        progress: (source, id) async =>
            const WebProgressInfo(chapter: 2, page: 4),
        saveProgress: (source, id, update) async {
          calls.add(['save', source, id, update.chapter, update.page]);
          return WebProgressInfo(chapter: update.chapter, page: update.page);
        },
        chapterImages: (source, id, chapter) async {
          calls.add(['images', source, id, chapter]);
          return WebChapterImages(
            chapter: chapter,
            chapterId: 'ep_$chapter',
            images: ['/api/image?ref=x'],
          );
        },
        imageBytes: (request) async {
          calls.add(['image', request.kind, request.ref]);
          return Uint8List.fromList(utf8.encode('bytes'));
        },
      ),
    );
  });

  test('health and sources expose a stable shape', () async {
    expect((await api.health())['ok'], isTrue);
    final sources = await api.sources();
    expect(sources['sources'], isA<List>());
    expect((sources['sources'] as List).first, containsPair('key', 'demo'));
  });

  test('bookshelf serializes progress', () async {
    final result = await api.bookshelf();
    expect(result['total'], 1);
    final item = (result['comics'] as List).single as Map<String, Object?>;
    expect(item['key'], 'demo:1');
    expect((item['progress'] as Map)['chapter'], 3);
    expect(item['cover'], contains('/api/image?'));
  });

  test('search validates input and forwards arguments', () async {
    await expectLater(
      api.search(keyword: '  ', source: 'all', page: 1),
      throwsA(isA<WebApiBadRequest>()),
    );
    await expectLater(
      api.search(keyword: 'abc', source: 'all', page: 0),
      throwsA(isA<WebApiBadRequest>()),
    );
    final result = await api.search(
      keyword: '  needle  ',
      source: 'demo',
      page: 2,
    );
    expect(result['hasMore'], isFalse);
    expect(result['partial'], isFalse);
    expect(calls.first, ['search', 'needle', 'demo', 2, null]);
  });

  test('detail and chapter routes validate comic identity', () async {
    await expectLater(api.detail('', '1'), throwsA(isA<WebApiBadRequest>()));
    final detail = await api.detail('demo', 'a');
    expect((detail['chapters'] as List).single, containsPair('id', 'ep_1'));
    expect(calls.last, ['detail', 'demo', 'a']);

    await expectLater(
      api.chapterImages('demo', '1', 0),
      throwsA(isA<WebApiBadRequest>()),
    );
    final images = await api.chapterImages('demo', '1', 1);
    expect(images['count'], 1);
  });

  test('progress update parses positive integers', () async {
    final result = await api.saveProgress('demo', '1', {
      'chapter': 2.0,
      'page': 9,
      'chapterTitle': 'Two',
    });
    expect(result['progress'], containsPair('page', 9));
    expect(calls.last, ['save', 'demo', '1', 2, 9]);

    await expectLater(
      api.saveProgress('demo', '1', {'chapter': 0, 'page': 1}),
      throwsArgumentError,
    );
  });

  test('image URL encoding round-trips through Uri', () {
    final url = webImageUrl(
      ref: 'https://host/a b.png?x=1&y=2',
      kind: WebImageKind.page,
      source: 'demo',
      cid: 'id/1',
      eid: 'ep_1',
    );
    final uri = Uri.parse(url);
    expect(uri.path, '/api/image');
    expect(uri.queryParameters['ref'], 'https://host/a b.png?x=1&y=2');
    expect(uri.queryParameters['cid'], 'id/1');
    expect(uri.queryParameters['kind'], 'page');
  });
}
