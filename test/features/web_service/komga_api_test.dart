import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/web_service/komga_api.dart';
import 'package:venera_next/features/web_service/web_api.dart';
import 'package:venera_next/features/web_service/web_models.dart';

void main() {
  group('KomgaIds', () {
    test('round-trips opaque ids without unsafe characters', () {
      final series = KomgaIds.series('source/with:odd chars', '漫画 id/1');
      final book = KomgaIds.book('demo', 'a b', 12);
      final library = KomgaIds.library('demo');

      expect(series, isNot(contains('/')));
      expect(series, isNot(contains('+')));
      expect(book, isNot(contains('=')));
      expect(KomgaIds.seriesRef(series)?.source, 'source/with:odd chars');
      expect(KomgaIds.seriesRef(series)?.comicId, '漫画 id/1');
      expect(KomgaIds.bookRef(book)?.chapter, 12);
      expect(KomgaIds.bookRef(book)?.comicId, 'a b');
      expect(KomgaIds.librarySource(library), 'demo');
    });

    test('rejects garbage and mismatched kinds', () {
      expect(KomgaIds.seriesRef('nope'), isNull);
      expect(KomgaIds.seriesRef('ser_%%%'), isNull);
      expect(KomgaIds.bookRef(KomgaIds.series('demo', '1')), isNull);
      expect(KomgaIds.librarySource(KomgaIds.book('demo', '1', 1)), isNull);
      expect(KomgaIds.bookRef(KomgaIds.book('demo', '1', 0)), isNull);
    });
  });

  group('KomgaPage', () {
    test('emits a Spring page envelope', () {
      final first = KomgaPage.content(
        const [1, 2],
        number: 0,
        size: 2,
        total: 3,
      );
      expect(first['totalElements'], 3);
      expect(first['totalPages'], 2);
      expect(first['numberOfElements'], 2);
      expect(first['first'], isTrue);
      expect(first['last'], isFalse);
      expect(first['empty'], isFalse);
      expect((first['pageable'] as Map)['pageNumber'], 0);
      expect((first['pageable'] as Map)['offset'], 0);

      final last = KomgaPage.content(const [3], number: 1, size: 2, total: 3);
      expect(last['first'], isFalse);
      expect(last['last'], isTrue);

      final empty = KomgaPage.content(const [], number: 0, size: 20, total: 0);
      expect(empty['totalPages'], 0);
      expect(empty['empty'], isTrue);
      expect(empty['first'], isTrue);
      expect(empty['last'], isTrue);
    });
  });

  group('KomgaApi', () {
    late List<Map<String, Object?>> written;

    KomgaApi build() {
      final comics = [
        WebComicInfo(
          id: 'c1',
          source: 'demo',
          title: 'Alpha',
          favoriteAt: '2026-01-01T00:00:00Z',
          progress: const WebProgressInfo(
            chapter: 2,
            page: 4,
            maxChapter: 3,
            readChapters: ['1', '2'],
            updatedAt: '2026-01-03T00:00:00Z',
          ),
        ),
        WebComicInfo(
          id: 'c2',
          source: 'demo',
          title: 'Beta',
          favoriteAt: '2026-01-02T00:00:00Z',
        ),
        WebComicInfo(
          id: 'c3',
          source: 'other',
          title: 'Gamma',
          favoriteAt: '2026-01-03T00:00:00Z',
        ),
      ];
      final chapters = [
        for (var index = 1; index <= 3; index++)
          WebChapterInfo(index: index, id: 'ep_$index', title: 'Ep $index'),
      ];
      final api = WebApi(
        WebApiDeps(
          sources: () async => const [
            WebSourceInfo(key: 'demo', name: 'Demo', searchable: true, local: false),
            WebSourceInfo(key: 'other', name: 'Other', searchable: false, local: false),
          ],
          bookshelf: () async => comics,
          search: (keyword, source, page, next) async =>
              WebSearchPage(comics: const [], source: source),
          detail: (source, id) async => WebComicDetail(
            comic: comics.firstWhere((e) => e.id == id).copyWith(
              progress: const WebProgressInfo(
                chapter: 2,
                page: 4,
                readChapters: ['1'],
              ),
            ),
            chapters: chapters,
          ),
          progress: (source, id) async =>
              const WebProgressInfo(chapter: 2, page: 4),
          saveProgress: (source, id, update) async {
            written.add({
              'source': source,
              'id': id,
              'chapter': update.chapter,
              'page': update.page,
            });
            return WebProgressInfo(chapter: update.chapter, page: update.page);
          },
          chapterImages: (source, id, chapter) async => WebChapterImages(
            chapter: chapter,
            chapterId: 'ep_$chapter',
            images: [
              webImageUrl(
                ref: 'https://x/$chapter-1.jpg',
                kind: WebImageKind.page,
                source: source,
                cid: id,
                eid: 'ep_$chapter',
              ),
              webImageUrl(
                ref: 'https://x/$chapter-2.jpg',
                kind: WebImageKind.page,
                source: source,
                cid: id,
                eid: 'ep_$chapter',
              ),
            ],
          ),
          imageBytes: (request) async =>
              Uint8List.fromList([0xff, 0xd8, 0xff, 0x00]),
          removeProgress: (source, id) async =>
              written.add({'removed': '$source:$id'}),
        ),
      );
      return KomgaApi(api, 'http://127.0.0.1:8080');
    }

    setUp(() => written = []);

    test('libraries map every source', () async {
      final content = await build().libraries();
      expect(content, hasLength(2));
      expect(content.first['id'], KomgaIds.library('demo'));
      expect(content.first['name'], 'Demo');
    });

    test('series pages, filters and searches the bookshelf', () async {
      final api = build();

      final first = await api.series(page: 0, size: 2);
      expect(first['totalElements'], 3);
      expect(first['content'], hasLength(2));
      expect(first['last'], isFalse);
      // Default sort is by name.
      expect(((first['content'] as List).first as Map)['name'], 'Alpha');

      final second = await api.series(page: 1, size: 2);
      expect(second['content'], hasLength(1));
      expect(second['last'], isTrue);

      final filtered = await api.series(libraryId: KomgaIds.library('other'));
      expect(filtered['totalElements'], 1);
      expect(((filtered['content'] as List).single as Map)['name'], 'Gamma');

      final searched = await api.series(search: 'bet');
      expect(searched['totalElements'], 1);
      expect(((searched['content'] as List).single as Map)['name'], 'Beta');
    });

    test('series detail reports the real chapter count', () async {
      final dto = await build().seriesDetail(KomgaIds.series('demo', 'c1'));
      expect(dto['booksCount'], 3);
      expect(dto['booksReadCount'], 1);
      expect(dto['booksUnreadCount'], 2);
      expect((dto['metadata'] as Map)['title'], 'Alpha');
    });

    test('books, pages and read progress line up', () async {
      final api = build();
      final bookId = KomgaIds.book('demo', 'c1', 2);
      final book = await api.book(bookId);
      expect(book['name'], 'Ep 2');
      expect((book['media'] as Map)['pagesCount'], 2);
      expect((book['readProgress'] as Map)['page'], 4);

      final otherBook = await api.book(KomgaIds.book('demo', 'c1', 1));
      expect(otherBook['readProgress'], isNull);

      final pages = await api.bookPages(bookId);
      expect(pages, hasLength(2));
      expect(pages.first['downloadUrl'], '/api/v1/books/$bookId/pages/1');

      final bytes = await api.bookPageImage(bookId, 1);
      expect(bytes, isNotNull);
      expect(bytes!.sublist(0, 3), [0xff, 0xd8, 0xff]);

      final progress = await api.readProgress(bookId);
      expect(progress?['page'], 4);
      expect(await api.readProgress(KomgaIds.book('demo', 'c1', 3)), isNull);
    });

    test('read progress writes through the shared history store', () async {
      final api = build();
      await api.saveReadProgress(KomgaIds.book('demo', 'c1', 2), {
        'page': 7,
        'completed': true,
      });
      expect(written.single, {
        'source': 'demo',
        'id': 'c1',
        'chapter': 2,
        'page': 7,
      });

      await api.deleteReadProgress(KomgaIds.book('demo', 'c1', 2));
      expect(written.last, {'removed': 'demo:c1'});

      // `completed` without a page falls back to the last page.
      await api.saveReadProgress(KomgaIds.book('demo', 'c1', 2), {
        'completed': true,
      });
      expect(written.last['page'], 2);

      // A different book must not clear the comic's progress.
      final before = written.length;
      await api.deleteReadProgress(KomgaIds.book('demo', 'c1', 1));
      expect(written.length, before);
    });

    test('siblings stop at both ends', () async {
      final api = build();
      final next = await api.sibling(KomgaIds.book('demo', 'c1', 2), 1);
      expect(next['number'], 3);
      final previous = await api.sibling(KomgaIds.book('demo', 'c1', 2), -1);
      expect(previous['number'], 1);
      await expectLater(
        api.sibling(KomgaIds.book('demo', 'c1', 1), -1),
        throwsA(isA<WebApiNotFound>()),
      );
      await expectLater(
        api.sibling(KomgaIds.book('demo', 'c1', 3), 1),
        throwsA(isA<WebApiNotFound>()),
      );
    });

    test('search only reports series from the bookshelf', () async {
      final result = await build().search('alpha');
      expect((result['series'] as List), hasLength(1));
      expect((result['books'] as List), isEmpty);
      await expectLater(
        build().search('   '),
        throwsA(isA<WebApiBadRequest>()),
      );
    });
  });
}
