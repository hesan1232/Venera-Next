/// Komga-compatible REST surface (`/api/v1`) on top of [WebApi].
///
/// Komga models a library as `Library -> Series -> Book -> Page`. Venera has
/// `source -> comic -> chapter -> image`, which maps one to one:
///
///  * library = comic source (`local` included)
///  * series  = comic
///  * book    = chapter
///  * page    = image
///
/// The mapping is exposed with the wire shapes Komga clients already speak, so
/// tools such as Komelia, Tachidesk-style dashboards or plain `curl` scripts
/// can browse the LAN library without knowing anything about Venera sources.
///
/// Everything here is read-through: no state is duplicated, progress still
/// lives in the history database and is written through [WebApi].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'opds_catalog.dart';
import 'web_api.dart';
import 'web_models.dart';

/// Opaque, URL-safe identifiers.
///
/// Komga ids are arbitrary strings; clients treat them as opaque. Encoding the
/// routing information into the id keeps the layer stateless, which matters
/// because comics come from remote sources and there is no local database row
/// to look up.
class KomgaIds {
  const KomgaIds._();

  static const _seriesPrefix = 'ser_';
  static const _bookPrefix = 'bok_';
  static const _libraryPrefix = 'lib_';

  static String library(String source) =>
      '$_libraryPrefix${_encode([source])}';

  static String series(String source, String comicId) =>
      '$_seriesPrefix${_encode([source, comicId])}';

  static String book(String source, String comicId, int chapter) =>
      '$_bookPrefix${_encode([source, comicId, '$chapter'])}';

  static String? librarySource(String id) {
    final parts = _decode(id, _libraryPrefix, 1);
    return parts == null || parts.first.isEmpty ? null : parts.first;
  }

  static KomgaSeriesRef? seriesRef(String id) {
    final parts = _decode(id, _seriesPrefix, 2);
    if (parts == null || parts[0].isEmpty || parts[1].isEmpty) return null;
    return KomgaSeriesRef(parts[0], parts[1]);
  }

  static KomgaBookRef? bookRef(String id) {
    final parts = _decode(id, _bookPrefix, 3);
    if (parts == null || parts[0].isEmpty || parts[1].isEmpty) return null;
    final chapter = int.tryParse(parts[2]);
    if (chapter == null || chapter < 1) return null;
    return KomgaBookRef(parts[0], parts[1], chapter);
  }

  static String _encode(List<String> parts) => base64Url
      .encode(utf8.encode(parts.join('\u0000')))
      .replaceAll('=', '');

  static List<String>? _decode(String id, String prefix, int expected) {
    if (!id.startsWith(prefix)) return null;
    final body = id.substring(prefix.length);
    if (body.isEmpty) return null;
    try {
      final padded = body.padRight((body.length + 3) ~/ 4 * 4, '=');
      final parts = utf8.decode(base64Url.decode(padded)).split('\u0000');
      return parts.length == expected ? parts : null;
    } catch (_) {
      return null;
    }
  }
}

class KomgaSeriesRef {
  const KomgaSeriesRef(this.source, this.comicId);
  final String source;
  final String comicId;
}

class KomgaBookRef extends KomgaSeriesRef {
  const KomgaBookRef(super.source, super.comicId, this.chapter);
  final int chapter;
}

/// Spring `Page<T>` envelope, which is what every Komga list endpoint returns.
class KomgaPage {
  const KomgaPage._();

  static Map<String, Object?> content(
    List<Object?> items, {
    required int number,
    required int size,
    required int total,
  }) {
    final pages = size <= 0 ? 0 : (total / size).ceil();
    const emptySort = <String, Object?>{
      'empty': true,
      'sorted': false,
      'unsorted': true,
    };
    return {
      'content': items,
      'pageable': {
        'sort': emptySort,
        'offset': number * size,
        'pageNumber': number,
        'pageSize': size,
        'paged': true,
        'unpaged': false,
      },
      'totalPages': pages,
      'totalElements': total,
      'last': number + 1 >= pages,
      'size': size,
      'number': number,
      'sort': emptySort,
      'numberOfElements': items.length,
      'first': number == 0,
      'empty': items.isEmpty,
    };
  }
}

class KomgaApi {
  KomgaApi(this._api, this._baseUrl);

  final WebApi _api;
  final String _baseUrl;

  /// Chapter page lists are expensive (one source call each) and are needed by
  /// both/books/{id} (page count) and /pages, so they are cached briefly.
  final _pages = <String, ({DateTime at, WebChapterImages value})>{};
  static const _pagesTtl = Duration(minutes: 10);

  // ------------------------------------------------------------- libraries

  Future<Map<String, Object?>> me() async => {
    'id': 'venera-next',
    'email': 'lan@venera.local',
    'roles': const ['USER', 'ADMIN'],
  };

  /// Komga returns a bare array here, not a page envelope.
  Future<List<Map<String, Object?>>> libraries() async {
    final sources = await _api.sourceInfos();
    final sorted = List<WebSourceInfo>.of(sources)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return sorted.map(_libraryDto).toList();
  }

  Future<Map<String, Object?>> library(String id) async {
    final source = KomgaIds.librarySource(id);
    if (source == null) throw const WebApiNotFound('Unknown library');
    final sources = await _api.sourceInfos();
    for (final info in sources) {
      if (info.key == source) return _libraryDto(info);
    }
    throw const WebApiNotFound('Unknown library');
  }

  // ---------------------------------------------------------------- series

  Future<Map<String, Object?>> series({
    int page = 0,
    int size = 20,
    String? search,
    String? libraryId,
    String? sort,
  }) async {
    final all = await _api.shelfItems();
    var items = all;
    if (libraryId != null && libraryId.trim().isNotEmpty) {
      final source = KomgaIds.librarySource(libraryId.trim());
      if (source == null) throw const WebApiNotFound('Unknown library');
      items = items.where((e) => e.source == source).toList();
    }
    final keyword = (search ?? '').trim().toLowerCase();
    if (keyword.isNotEmpty) {
      items = items
          .where(
            (e) =>
                e.title.toLowerCase().contains(keyword) ||
                e.subtitle.toLowerCase().contains(keyword),
          )
          .toList();
    }
    items = _sorted(items, sort);
    final total = items.length;
    final start = page * size;
    final slice = start >= total
        ? const <WebComicInfo>[]
        : items.sublist(start, (start + size).clamp(0, total));
    return KomgaPage.content(
      [for (final comic in slice) _seriesDto(comic)],
      number: page,
      size: size,
      total: total,
    );
  }

  Future<Map<String, Object?>> seriesDetail(String id) async {
    final ref = KomgaIds.seriesRef(id);
    if (ref == null) throw const WebApiNotFound('Unknown series');
    final detail = await _api.comicDetail(ref.source, ref.comicId);
    return _seriesDto(
      detail.comic,
      booksCount: detail.chapters.length,
      booksReadCount: detail.comic.progress?.readChapters.length,
    );
  }

  Future<Map<String, Object?>> seriesBooks(
    String id, {
    int page = 0,
    int size = 20,
  }) async {
    final ref = KomgaIds.seriesRef(id);
    if (ref == null) throw const WebApiNotFound('Unknown series');
    final detail = await _api.comicDetail(ref.source, ref.comicId);
    final total = detail.chapters.length;
    final start = page * size;
    final slice = start >= total
        ? const <WebChapterInfo>[]
        : detail.chapters.sublist(start, (start + size).clamp(0, total));
    final progress = detail.comic.progress;
    return KomgaPage.content(
      [
        for (final chapter in slice)
          _bookDto(
            ref.source,
            ref.comicId,
            detail.comic.title,
            chapter,
            progress: progress,
          ),
      ],
      number: page,
      size: size,
      total: total,
    );
  }

  // ----------------------------------------------------------------- books

  Future<Map<String, Object?>> book(String id) async {
    final ref = KomgaIds.bookRef(id);
    if (ref == null) throw const WebApiNotFound('Unknown book');
    final detail = await _api.comicDetail(ref.source, ref.comicId);
    final chapter = _chapterOf(detail, ref.chapter);
    final pages = await _pagesOf(ref);
    return _bookDto(
      ref.source,
      ref.comicId,
      detail.comic.title,
      chapter,
      pagesCount: pages?.images.length ?? 0,
      progress: detail.comic.progress,
    );
  }

  Future<List<Map<String, Object?>>> bookPages(String id) async {
    final ref = KomgaIds.bookRef(id);
    if (ref == null) throw const WebApiNotFound('Unknown book');
    final pages = await _pagesOf(ref);
    if (pages == null) throw const WebApiNotFound('Chapter has no pages');
    final result = <Map<String, Object?>>[];
    for (var i = 0; i < pages.images.length; i++) {
      final number = i + 1;
      result.add({
        'number': number,
        'fileName': 'page-${number.toString().padLeft(3, '0')}.jpg',
        'mediaType': 'image/jpeg',
        'width': 0,
        'height': 0,
        'sizeBytes': 0,
        'downloadUrl': '/api/v1/books/$id/pages/$number',
      });
    }
    return result;
  }

  Future<Uint8List?> bookPageImage(String id, int number) async {
    final ref = KomgaIds.bookRef(id);
    if (ref == null) throw const WebApiNotFound('Unknown book');
    final pages = await _pagesOf(ref);
    if (pages == null || number < 1 || number > pages.images.length) {
      throw const WebApiNotFound('Page not found');
    }
    final request = WebImageRequest.fromUrl(pages.images[number - 1]);
    if (request == null) throw const WebApiNotFound('Page not found');
    return _api.image(request);
  }

  Future<Uint8List?> seriesThumbnail(String id) async {
    final ref = KomgaIds.seriesRef(id);
    if (ref == null) throw const WebApiNotFound('Unknown series');
    final detail = await _api.comicDetail(ref.source, ref.comicId);
    final cover = detail.comic.cover;
    if (cover == null || cover.isEmpty) return null;
    final request = WebImageRequest.fromUrl(cover);
    if (request == null) return null;
    return _api.image(request);
  }

  /// Chapters have no cover of their own; the first page is the closest match
  /// to what Komga returns for a book thumbnail.
  Future<Uint8List?> bookThumbnail(String id) async {
    final ref = KomgaIds.bookRef(id);
    if (ref == null) throw const WebApiNotFound('Unknown book');
    final pages = await _pagesOf(ref);
    if (pages == null || pages.images.isEmpty) return null;
    final request = WebImageRequest.fromUrl(pages.images.first);
    if (request == null) return null;
    return _api.image(request);
  }

  Future<OpdsBinary> bookFile(String id) async {
    final ref = KomgaIds.bookRef(id);
    if (ref == null) throw const WebApiNotFound('Unknown book');
    return OpdsCatalog(_api, _baseUrl).cbz(
      ref.source,
      ref.comicId,
      ref.chapter,
    );
  }

  Future<Map<String, Object?>> sibling(String id, int delta) async {
    final ref = KomgaIds.bookRef(id);
    if (ref == null) throw const WebApiNotFound('Unknown book');
    final detail = await _api.comicDetail(ref.source, ref.comicId);
    final target = ref.chapter + delta;
    if (target < 1 || target > detail.chapters.length) {
      throw const WebApiNotFound('No such book');
    }
    return _bookDto(
      ref.source,
      ref.comicId,
      detail.comic.title,
      _chapterOf(detail, target),
      progress: detail.comic.progress,
    );
  }

  // -------------------------------------------------------------- progress

  Future<Map<String, Object?>?> readProgress(String id) async {
    final ref = KomgaIds.bookRef(id);
    if (ref == null) throw const WebApiNotFound('Unknown book');
    // Detail carries the flattened chapter index; the raw history row is
    // group-local for grouped sources, so it cannot be compared directly.
    final detail = await _api.comicDetail(ref.source, ref.comicId);
    final progress = detail.comic.progress;
    if (progress == null || progress.chapter != ref.chapter) return null;
    final date = progress.updatedAt ?? _nowIso();
    return {
      'page': progress.page,
      'completed': progress.maxPage != null
          ? progress.page >= progress.maxPage!
          : false,
      'readDate': date,
      'created': date,
      'lastModified': date,
    };
  }

  /// Writes the same history record the native reader writes.
  ///
  /// Komga clients PATCH `{page, completed}`; `page` may be omitted when the
  /// book is marked read, in which case the last page is used.
  Future<void> saveReadProgress(String id, Map<String, Object?> body) async {
    final ref = KomgaIds.bookRef(id);
    if (ref == null) throw const WebApiNotFound('Unknown book');
    final detail = await _api.comicDetail(ref.source, ref.comicId);
    final chapter = _chapterOf(detail, ref.chapter);
    final completed = body['completed'] == true;
    var page = body['page'];
    if (page == null && completed) {
      final pages = await _pagesOf(ref);
      page = pages?.images.length ?? 1;
    }
    if (page is! num || page < 1) {
      throw const WebApiBadRequest('Invalid page');
    }
    await _api.writeProgress(
      ref.source,
      ref.comicId,
      WebProgressUpdate(
        chapter: ref.chapter,
        page: page.round(),
        group: chapter.group,
        chapterTitle: chapter.title,
        groupTitle: chapter.groupTitle,
      ),
    );
  }

  Future<void> deleteReadProgress(String id) async {
    final ref = KomgaIds.bookRef(id);
    if (ref == null) throw const WebApiNotFound('Unknown book');
    final detail = await _api.comicDetail(ref.source, ref.comicId);
    final progress = detail.comic.progress;
    // Progress is stored per comic, not per chapter. Only clear it when the
    // book being reset is the one the reader is actually on.
    if (progress == null || progress.chapter != ref.chapter) return;
    await _api.removeProgress(ref.source, ref.comicId);
  }

  // ---------------------------------------------------------------- search

  Future<Map<String, Object?>> search(String keyword) async {
    final q = keyword.trim().toLowerCase();
    if (q.isEmpty) throw const WebApiBadRequest('Missing search query');
    final shelf = await _api.shelfItems();
    final matched = shelf.where(
      (e) =>
          e.title.toLowerCase().contains(q) ||
          e.subtitle.toLowerCase().contains(q) ||
          e.tags.any((tag) => tag.toLowerCase().contains(q)),
    );
    return {
      'series': matched.map(_seriesDto).toList(),
      'books': const <Object?>[],
      'collections': const <Object?>[],
      'readlists': const <Object?>[],
      'authors': const <Object?>[],
      'tags': const <Object?>[],
      'publishers': const <Object?>[],
      'genres': const <Object?>[],
      'languages': const <Object?>[],
      'sharingLabels': const <Object?>[],
    };
  }

  // --------------------------------------------------------------- helpers

  Future<WebChapterImages?> _pagesOf(KomgaBookRef ref) async {
    final key = '${ref.source}\u0000${ref.comicId}\u0000${ref.chapter}';
    final cached = _pages[key];
    if (cached != null && DateTime.now().difference(cached.at) < _pagesTtl) {
      return cached.value;
    }
    try {
      final value = await _api.chapterPages(
        ref.source,
        ref.comicId,
        ref.chapter,
      );
      _pages[key] = (at: DateTime.now(), value: value);
      if (_pages.length > 64) _pages.remove(_pages.keys.first);
      return value;
    } catch (_) {
      // Missing pages are reported by /pages; /books keeps working with an
      // unknown page count, which is what many clients tolerate.
      return null;
    }
  }

  WebChapterInfo _chapterOf(WebComicDetail detail, int index) {
    if (index < 1 || index > detail.chapters.length) {
      throw const WebApiNotFound('Chapter not found');
    }
    return detail.chapters[index - 1];
  }

  List<WebComicInfo> _sorted(List<WebComicInfo> items, String? sort) {
    final value = (sort ?? 'name,asc').split(',').first.trim();
    final ascending = !(sort ?? '').contains('desc');
    int compare(WebComicInfo a, WebComicInfo b) {
      switch (value) {
        case 'lastModified':
        case 'updated':
          return (a.progress?.updatedAt ?? '').compareTo(
            b.progress?.updatedAt ?? '',
          );
        case 'created':
        case 'added':
          return (a.favoriteAt ?? '').compareTo(b.favoriteAt ?? '');
        default:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      }
    }

    final copy = List<WebComicInfo>.of(items)..sort(compare);
    return ascending ? copy : copy.reversed.toList();
  }

  Map<String, Object?> _libraryDto(WebSourceInfo source) => {
    'id': KomgaIds.library(source.key),
    'name': source.name,
    'root': source.local ? 'local' : 'source:${source.key}',
    'importComicInfoBook': true,
    'importComicInfoSeries': true,
    'importComicInfoCollection': false,
    'importComicInfoReadList': false,
    'importEpubBook': false,
    'importEpubSeries': false,
    'importMylarSeries': false,
    'importLocalArtwork': false,
    'importBarcodeIsbn': false,
    'scanOnStartup': false,
    'scanCbx': true,
    'scanPdf': false,
    'scanEpub': false,
    'scanForceModifiedTime': false,
    'scanInterval': 'DISABLED',
    'repairExtensions': false,
    'convertToCbz': false,
    'emptyTrashAfterScan': false,
    'seriesCover': 'FIRST',
    'hashFiles': false,
    'hashPages': false,
    'hashKoreader': false,
    'oneshotsDirectory': null,
    'unavailable': false,
  };

  Map<String, Object?> _seriesDto(
    WebComicInfo comic, {
    int? booksCount,
    int? booksReadCount,
  }) {
    final progress = comic.progress;
    final count = booksCount ?? progress?.maxChapter ?? 0;
    final read = (booksReadCount ?? progress?.readChapters.length ?? 0).clamp(
      0,
      count,
    );
    final created = _iso(comic.favoriteAt) ?? _nowIso();
    final modified = _iso(progress?.updatedAt) ?? created;
    return {
      'id': KomgaIds.series(comic.source, comic.id),
      'libraryId': KomgaIds.library(comic.source),
      'name': comic.title,
      'url': '',
      'created': created,
      'lastModified': modified,
      'fileLastModified': created,
      'booksCount': count,
      'booksReadCount': read,
      'booksUnreadCount': count - read,
      'booksInProgressCount': progress == null ? 0 : 1,
      'metadata': {
        'title': comic.title,
        'titleLock': false,
        'titleSort': comic.title,
        'titleSortLock': false,
        'summary': comic.description ?? comic.subtitle,
        'summaryLock': false,
        'publisher': comic.subtitle,
        'publisherLock': false,
        'readingDirection': 'LEFT_TO_RIGHT',
        'readingDirectionLock': false,
        'ageRating': null,
        'ageRatingLock': false,
        'status': 'ONGOING',
        'statusLock': false,
        'genres': comic.tags.take(8).toList(),
        'genresLock': false,
        'tags': comic.tags,
        'tagsLock': false,
        'language': 'zh',
        'languageLock': false,
        'totalBookCount': count,
        'totalBookCountLock': false,
        'sharingLabels': const <String>[],
        'sharingLabelsLock': false,
        'links': const <Object?>[],
        'linksLock': false,
        'alternateTitles': const <String>[],
        'alternateTitlesLock': false,
        'created': created,
        'lastModified': modified,
      },
      'booksMetadata': {
        'authors': comic.subtitle.isEmpty
            ? const <Object?>[]
            : [
                {'name': comic.subtitle, 'role': 'writer'},
              ],
        'tags': comic.tags,
        'releaseDate': null,
        'summary': comic.subtitle,
        'summaryNumber': '',
        'created': created,
        'lastModified': modified,
      },
      'deleted': false,
    };
  }

  Map<String, Object?> _bookDto(
    String source,
    String comicId,
    String seriesTitle,
    WebChapterInfo chapter, {
    int pagesCount = 0,
    WebProgressInfo? progress,
  }) {
    final id = KomgaIds.book(source, comicId, chapter.index);
    final read = progress != null && progress.chapter == chapter.index;
    final date = _iso(progress?.updatedAt) ?? _nowIso();
    return {
      'id': id,
      'seriesId': KomgaIds.series(source, comicId),
      'seriesTitle': seriesTitle,
      'libraryId': KomgaIds.library(source),
      'name': chapter.title,
      'url': '',
      'number': chapter.index,
      'created': date,
      'lastModified': date,
      'fileLastModified': date,
      'sizeBytes': 0,
      'media': {
        'status': 'READY',
        'mediaType': 'application/zip',
        'pagesCount': pagesCount,
        'comment': chapter.groupTitle ?? '',
        'epubDivinaCompatible': false,
        'mediaProfile': 'DIVINA',
      },
      'metadata': {
        'title': chapter.title,
        'titleLock': false,
        'summary': chapter.groupTitle ?? '',
        'summaryLock': false,
        'number': '${chapter.index}',
        'numberLock': false,
        'numberSort': chapter.index.toDouble(),
        'numberSortLock': false,
        'releaseDate': null,
        'releaseDateLock': false,
        'authors': const <Object?>[],
        'authorsLock': false,
        'tags': const <String>[],
        'tagsLock': false,
        'isbn': '',
        'isbnLock': false,
        'links': const <Object?>[],
        'linksLock': false,
        'created': date,
        'lastModified': date,
      },
      'readProgress': read
          ? {
              'page': progress.page,
              'completed':
                  progress.maxPage != null &&
                  progress.page >= progress.maxPage!,
              'readDate': date,
              'created': date,
              'lastModified': date,
            }
          : null,
      'deleted': false,
    };
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();

  String? _iso(String? value) {
    if (value == null || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc().toIso8601String();
  }
}
