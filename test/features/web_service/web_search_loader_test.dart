import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/web_service/web_service_runtime.dart';
import 'package:venera_next/foundation/res.dart';

void main() {
  const empty = Res<List<Comic>>(<Comic>[]);

  test('next-only source is searched with a null cursor', () async {
    String? seenNext;
    final data = SearchPageData(null, null, (keyword, next, options) async {
      seenNext = next;
      return empty;
    });
    final loader = webSearchLoader(
      data,
      keyword: 'x',
      page: 1,
      next: null,
      options: const [],
    );
    expect(loader, isNotNull);
    await loader!();
    expect(seenNext, isNull);
  });

  test('numeric loader is used for the first page', () async {
    var page = -1;
    final data = SearchPageData(
      null,
      (keyword, p, options) async {
        page = p;
        return empty;
      },
      (keyword, next, options) async => empty,
    );
    final loader = webSearchLoader(
      data,
      keyword: 'x',
      page: 3,
      next: null,
      options: const [],
    );
    await loader!();
    expect(page, 3);
  });

  test('a saved cursor takes precedence over page numbers', () async {
    String? seenNext;
    var pageCalls = 0;
    final data = SearchPageData(
      null,
      (keyword, p, options) async {
        pageCalls++;
        return empty;
      },
      (keyword, next, options) async {
        seenNext = next;
        return empty;
      },
    );
    final loader = webSearchLoader(
      data,
      keyword: 'x',
      page: 4,
      next: 'cursor-9',
      options: const [],
    );
    await loader!();
    expect(seenNext, 'cursor-9');
    expect(pageCalls, 0);
  });

  test('a source without any loader is reported, not crashed', () {
    const data = SearchPageData(null, null, null);
    expect(
      webSearchLoader(
        data,
        keyword: 'x',
        page: 1,
        next: null,
        options: const [],
      ),
      isNull,
    );
  });
}
