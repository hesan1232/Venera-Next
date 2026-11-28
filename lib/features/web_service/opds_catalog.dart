/// OPDS 1.2 catalog generation on top of the existing [WebApi].
///
/// The catalog is intentionally read-only and stateless: every feed is built
/// from the same functions the JSON API and the web reader use, so there is a
/// single source of truth for bookshelf, search, chapters and progress.
///
/// Wire conventions follow OPDS 1.2 (Atom):
///  * navigation feeds use
///    `application/atom+xml;profile=opds-catalog;kind=navigation`
///  * acquisition feeds use
///    `application/atom+xml;profile=opds-catalog;kind=acquisition`
///  * search is advertised with an OpenSearch description document.
library;

import 'dart:typed_data';

import 'store_zip.dart';
import 'web_api.dart';
import 'web_models.dart';

class OpdsDocument {
  const OpdsDocument(this.body, this.contentType);
  final String body;
  final String contentType;
}

class OpdsBinary {
  const OpdsBinary(
    this.bytes,
    this.contentType, {
    this.downloadName,
    this.cacheable = false,
  });
  final Uint8List bytes;
  final String contentType;
  final String? downloadName;
  final bool cacheable;
}

/// Base URL as seen by the client, e.g. `http://192.168.1.7:8080`.
///
/// Keeping it injected makes generated feeds testable and avoids trusting
/// proxies: the server derives it from the bound host and the Host header.
class OpdsCatalog {
  const OpdsCatalog(this._api, this.baseUrl, {this.appName = 'Venera Next'});

  final WebApi _api;
  final String baseUrl;
  final String appName;

  static const navigationType =
      'application/atom+xml;profile=opds-catalog;kind=navigation';
  static const acquisitionType =
      'application/atom+xml;profile=opds-catalog;kind=acquisition';
  static const openSearchType = 'application/opensearchdescription+xml';
  static const cbzType = 'application/vnd.comicbook+zip';

  static const _atom = 'http://www.w3.org/2005/Atom';
  static const _opds = 'http://opds-spec.org/2010/catalog';
  static const _dcTerms = 'http://purl.org/dc/terms/';
  static const _pse = 'http://vaemendis.net/opds-pse/2.0/';
  static const _imageRel = 'http://opds-spec.org/image';
  static const _thumbnailRel = 'http://opds-spec.org/image/thumbnail';
  static const _acquisitionRel = 'http://opds-spec.org/acquisition';
  static const _pseRel = 'http://vaemendis.net/opds-pse/stream';

  String get _root => '$baseUrl/opds';

  String _url(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return '$baseUrl$path';
  }

  // ------------------------------------------------------------------ feeds

  /// Top-level navigation feed, laid out like Komga's catalog: a short list of
  /// clearly labelled directories instead of one entry per source.
  ///
  /// OPDS readers pick a link by its `type` when rendering an entry. A
  /// subsection inside a *navigation* feed that points at an `acquisition`
  /// feed is treated as a book (or skipped entirely) by most clients - which
  /// is why the bookshelf used to be invisible while the per-source `search`
  /// entries were all that showed up. Komga labels every catalog directory
  /// with a navigation subsection regardless of the target feed's kind; do
  /// the same here so "Bookshelf" is a first-class, visible directory.
  Future<OpdsDocument> root() async {
    final entries = <String>[
      _entry(
        id: 'urn:venera:opds:bookshelf',
        title: 'Bookshelf',
        updated: _now(),
        summary: 'Comics in your favorites',
        links: [
          _link(
            'subsection',
            '$_root/bookshelf',
            type: navigationType,
            title: 'Bookshelf',
          ),
        ],
      ),
      _entry(
        id: 'urn:venera:opds:libraries',
        title: 'Libraries',
        updated: _now(),
        summary: 'Browse comics by source',
        links: [
          _link(
            'subsection',
            '$_root/libraries',
            type: navigationType,
            title: 'Libraries',
          ),
        ],
      ),
    ];

    return _feed(
      title: '$appName catalog',
      id: 'urn:venera:opds:root',
      self: _root,
      kind: navigationType,
      entries: entries,
      extraLinks: [
        _link(
          'search',
          '$_root/search.xml',
          type: openSearchType,
          title: 'Search',
        ),
        _link('alternate', '$baseUrl/', type: 'text/html', title: 'Web reader'),
      ],
    );
  }

  /// OpenSearch description, optionally scoped to a single source.
  OpdsDocument searchDescriptor({String? source}) {
    final sourceParam = source == null || source.isEmpty
        ? ''
        : '&source=${Uri.encodeComponent(source)}';
    final body =
        '''<?xml version="1.0" encoding="UTF-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <ShortName>${_escape(appName)}</ShortName>
  <Description>Search the $appName catalog</Description>
  <InputEncoding>UTF-8</InputEncoding>
  <OutputEncoding>UTF-8</OutputEncoding>
  <Url type="$acquisitionType" template="$_root/search?q=%7BsearchTerms%7D&page=%7BstartPageIndex%7D$sourceParam"/>
  <Url type="text/html" template="$baseUrl/?q=%7BsearchTerms%7D"/>
</OpenSearchDescription>''';
    return OpdsDocument(body, openSearchType);
  }

  Future<OpdsDocument> bookshelf() async {
    final comics = await _api.shelfItems();
    final entries = comics.map(_comicEntry).toList();
    return _feed(
      title: 'Bookshelf',
      id: 'urn:venera:opds:bookshelf',
      self: '$_root/bookshelf',
      kind: acquisitionType,
      entries: entries,
      extraLinks: [
        _link(
          'search',
          '$_root/search.xml',
          type: openSearchType,
          title: 'Search',
        ),
      ],
    );
  }

  /// Navigation feed with one entry per source, mirroring Komga's library
  /// list. Kept alphabetical so the order is stable between requests.
  Future<OpdsDocument> libraries() async {
    final sources = await _api.sourceInfos();
    final sorted = List<WebSourceInfo>.of(sources)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final entries = sorted
        .map(
          (source) => _entry(
            id: 'urn:venera:opds:library:${source.key}',
            title: source.name,
            updated: _now(),
            summary: source.local ? 'Local library' : 'Online source',
            links: [
              _link(
                'subsection',
                '$_root/libraries/${Uri.encodeComponent(source.key)}',
                type: acquisitionType,
                title: source.name,
              ),
              if (source.searchable)
                _link(
                  'search',
                  '$_root/search.xml?source=${Uri.encodeComponent(source.key)}',
                  type: openSearchType,
                  title: 'Search ${source.name}',
                ),
            ],
          ),
        )
        .toList();
    return _feed(
      title: 'Libraries',
      id: 'urn:venera:opds:libraries',
      self: '$_root/libraries',
      kind: navigationType,
      entries: entries,
    );
  }

  /// Acquisition feed restricted to one source (a Komga "library").
  Future<OpdsDocument> library(String source) async {
    final comics = (await _api.shelfItems())
        .where((e) => e.source == source)
        .toList();
    String? name;
    for (final info in await _api.sourceInfos()) {
      if (info.key == source) {
        name = info.name;
        break;
      }
    }
    if (name == null) throw const WebApiNotFound('Unknown library');
    return _feed(
      title: name,
      id: 'urn:venera:opds:library:$source',
      self: '$_root/libraries/${Uri.encodeComponent(source)}',
      kind: acquisitionType,
      entries: comics.map(_comicEntry).toList(),
      extraLinks: [
        _link(
          'search',
          '$_root/search.xml?source=${Uri.encodeComponent(source)}',
          type: openSearchType,
          title: 'Search $name',
        ),
      ],
    );
  }

  Future<OpdsDocument> search({
    required String keyword,
    String source = 'all',
    int page = 1,
    String? next,
  }) async {
    final result = await _api.searchPage(
      keyword: keyword,
      source: source,
      page: page,
      next: next,
    );
    final entries = result.comics.map(_comicEntry).toList();

    final links = <String>[];
    if (result.next != null || (result.maxPage != null && page < result.maxPage!)) {
      final cursor = result.next;
      final query = cursor != null
          ? 'q=${Uri.encodeComponent(keyword)}&source=${Uri.encodeComponent(source)}&next=${Uri.encodeComponent(cursor)}'
          : 'q=${Uri.encodeComponent(keyword)}&source=${Uri.encodeComponent(source)}&page=${page + 1}';
      links.add(
        _link(
          'next',
          '$_root/search?$query',
          type: acquisitionType,
          title: 'Next page',
        ),
      );
    }
    links.add(
      _link(
        'search',
        '$_root/search.xml',
        type: openSearchType,
        title: 'Search',
      ),
    );

    return _feed(
      title: 'Search: $keyword',
      id: 'urn:venera:opds:search:${Uri.encodeComponent(source)}:${Uri.encodeComponent(keyword)}:$page',
      self:
          '$_root/search?q=${Uri.encodeComponent(keyword)}&source=${Uri.encodeComponent(source)}&page=$page',
      kind: acquisitionType,
      entries: entries,
      extraLinks: links,
    );
  }

  /// Comic detail feed: one acquisition entry per chapter.
  ///
  /// Each entry advertises three ways to read the chapter:
  ///  * OPDS-PSE streaming (`{pageNumber}` template), understood by Panels,
  ///    Chunky and other page-streaming readers;
  ///  * a CBZ download, which is what KOReader uses;
  ///  * an HTML alternate link into the bundled web reader.
  ///
  /// `pse:count` is only known for the chapter the reader is currently on,
  /// because page counts come from the source and resolving all of them would
  /// mean one request per chapter. Streaming still works without the count;
  /// the attribute is filled in as soon as a chapter has been opened.
  Future<OpdsDocument> comic(String source, String id) async {
    final detail = await _api.comicDetail(source, id);
    final progress = detail.comic.progress;
    final sourcePart = Uri.encodeComponent(source);
    final idPart = Uri.encodeComponent(id);
    final entries = <String>[];
    for (final chapter in detail.chapters) {
      final label = chapter.groupTitle == null
          ? chapter.title
          : '[${chapter.groupTitle}] ${chapter.title}';
      final isCurrent = progress != null && progress.chapter == chapter.index;
      final knownPages = isCurrent ? progress.maxPage : null;
      entries.add(
        _entry(
          id: 'urn:venera:opds:chapter:$sourcePart:$idPart:${chapter.index}',
          title: label,
          updated: _now(),
          summary: 'Read chapter ${chapter.index}',
          links: [
            _link(
              _pseRel,
              '$_root/page/$sourcePart/$idPart/${chapter.index}/{pageNumber}',
              type: 'image/jpeg',
              title: 'Stream pages',
              extra: {
                if (knownPages != null && knownPages > 0)
                  'pse:count': '$knownPages',
                if (isCurrent) 'pse:lastRead': '${progress.page}',
              },
            ),
            _link(
              _acquisitionRel,
              '$_root/cbz/$sourcePart/$idPart/${chapter.index}',
              type: cbzType,
              title: 'Download CBZ',
            ),
            _link(
              'alternate',
              '$_root/chapter/$sourcePart/$idPart/${chapter.index}',
              type: acquisitionType,
              title: 'Read in browser',
            ),
          ],
        ),
      );
    }

    return _feed(
      title: detail.comic.title,
      id: 'urn:venera:opds:comic:$sourcePart:$idPart',
      self: '$_root/comic/$sourcePart/$idPart',
      kind: acquisitionType,
      entries: entries,
      extraLinks: [
        _link('start', _root, type: navigationType, title: 'Catalog'),
      ],
    );
  }

  /// One entry per page, for clients that prefer image-by-image reading.
  Future<OpdsDocument> chapter(String source, String id, int chapter) async {
    final result = await _api.chapterPages(source, id, chapter);
    var index = 0;
    final entries = result.images.map((image) {
      index++;
      return _entry(
        id: 'urn:venera:opds:page:${Uri.encodeComponent(source)}:${Uri.encodeComponent(id)}:$chapter:$index',
        title: 'Page $index',
        updated: _now(),
        links: [
          _link(
            _imageRel,
            _url(image),
            type: 'image/jpeg',
            title: 'Page $index',
          ),
          _link(
            _acquisitionRel,
            _url(image),
            type: 'image/jpeg',
            title: 'Download page $index',
          ),
        ],
      );
    }).toList();

    return _feed(
      title: result.title ?? 'Chapter $chapter',
      id: 'urn:venera:opds:chapter:${Uri.encodeComponent(source)}:${Uri.encodeComponent(id)}:$chapter',
      self:
          '$_root/chapter/${Uri.encodeComponent(source)}/${Uri.encodeComponent(id)}/$chapter',
      kind: acquisitionType,
      entries: entries,
      extraLinks: [
        _link('start', _root, type: navigationType, title: 'Catalog'),
      ],
    );
  }

  /// OPDS-PSE page streaming: resolve one page of a chapter as image bytes.
  Future<OpdsBinary> page(
    String source,
    String id,
    int chapter,
    int pageNumber,
  ) async {
    final result = await _api.chapterPages(source, id, chapter);
    if (pageNumber < 1 || pageNumber > result.images.length) {
      throw const WebApiNotFound('Page not found');
    }
    final request = WebImageRequest.fromUrl(result.images[pageNumber - 1]);
    if (request == null) throw const WebApiNotFound('Page not found');
    final bytes = await _api.image(request);
    if (bytes == null) throw const WebApiNotFound('Page not found');
    return OpdsBinary(bytes, detectImageType(bytes), cacheable: true);
  }

  /// Build a CBZ for one chapter, downloading pages through the same image
  /// pipeline the app uses (cache/headers/cookies are preserved).
  Future<OpdsBinary> cbz(String source, String id, int chapter) async {
    final result = await _api.chapterPages(source, id, chapter);
    final entries = <ZipEntry>[];
    for (var i = 0; i < result.images.length; i++) {
      final request = WebImageRequest.fromUrl(result.images[i]);
      final bytes = request == null ? null : await _api.image(request);
      if (bytes == null) {
        throw WebApiNotFound('Page ${i + 1} is not available');
      }
      final ext = _imageExtension(bytes);
      entries.add(ZipEntry('${(i + 1).toString().padLeft(4, '0')}$ext', bytes));
    }
    if (entries.isEmpty) {
      throw const WebApiNotFound('Chapter has no pages');
    }
    return OpdsBinary(
      buildStoreZip(entries),
      cbzType,
      downloadName: 'chapter-$chapter.cbz',
    );
  }

  // ---------------------------------------------------------------- helpers

  OpdsDocument _feed({
    required String title,
    required String id,
    required String self,
    required String kind,
    required List<String> entries,
    List<String> extraLinks = const [],
  }) {
    final links = <String>[
      _link('self', self, type: kind, title: title),
      _link('start', _root, type: navigationType, title: 'Catalog'),
      ...extraLinks,
    ];
    final body = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<feed xmlns="$_atom" xmlns:opds="$_opds" xmlns:dcterms="$_dcTerms" xmlns:pse="$_pse">',
      )
      ..writeln('<title>${_escape(title)}</title>')
      ..writeln('<id>${_escape(id)}</id>')
      ..writeln('<updated>${_now()}</updated>')
      ..writeln('<author><name>${_escape(appName)}</name></author>')
      ..writeAll(links, '\n')
      ..writeln();

    for (final entry in entries) {
      body.writeln(entry);
    }
    body.writeln('</feed>');
    return OpdsDocument(body.toString(), kind);
  }

  String _comicEntry(WebComicInfo comic) {
    final source = Uri.encodeComponent(comic.source);
    final id = Uri.encodeComponent(comic.id);
    final links = <String>[
      if (comic.cover != null)
        _link(
          _thumbnailRel,
          _url(comic.cover!),
          type: 'image/jpeg',
          title: 'Cover',
        ),
      if (comic.cover != null)
        _link(
          _imageRel,
          _url(comic.cover!),
          type: 'image/jpeg',
          title: 'Cover',
        ),
      _link(
        _acquisitionRel,
        '$_root/comic/$source/$id',
        type: acquisitionType,
        title: 'Chapters',
      ),
    ];

    final buffer = StringBuffer()
      ..writeln('<entry>')
      ..writeln('<title>${_escape(comic.title)}</title>')
      ..writeln('<id>urn:venera:opds:comic:$source:$id</id>')
      ..writeln('<updated>${_escape(comic.updateTime ?? _now())}</updated>');

    if (comic.subtitle.isNotEmpty || comic.description != null) {
      buffer.writeln(
        '<summary>${_escape(comic.description ?? comic.subtitle)}</summary>',
      );
    }
    final progress = comic.progress;
    if (progress != null) {
      // Reading progress is not part of OPDS; expose it as a standard
      // category so clients can surface it without breaking feed validity.
      buffer.writeln(
        '<category term="progress" label="Chapter ${progress.chapter}, page ${progress.page}"/>',
      );
    }
    buffer.writeln(
      '<author><name>${_escape(comic.subtitle.isEmpty ? appName : comic.subtitle)}</name></author>',
    );
    for (final tag in comic.tags.take(8)) {
      buffer.writeln(
        '<category term="${_escape(tag)}" label="${_escape(tag)}"/>',
      );
    }
    for (final link in links) {
      buffer.writeln(link);
    }
    buffer.writeln('</entry>');
    return buffer.toString();
  }

  String _entry({
    required String id,
    required String title,
    required String updated,
    String? summary,
    List<String> links = const [],
  }) {
    final buffer = StringBuffer()
      ..writeln('<entry>')
      ..writeln('<title>${_escape(title)}</title>')
      ..writeln('<id>${_escape(id)}</id>')
      ..writeln('<updated>${_escape(updated)}</updated>');
    if (summary != null) {
      buffer.writeln('<summary>${_escape(summary)}</summary>');
    }
    for (final link in links) {
      buffer.writeln(link);
    }
    buffer.writeln('</entry>');
    return buffer.toString();
  }

  String _link(
    String rel,
    String href, {
    String? type,
    String? title,
    Map<String, String> extra = const {},
  }) {
    final attrs = StringBuffer()
      ..write('rel="${_escape(rel)}"')
      ..write(' href="${_escape(href)}"');
    if (type != null) attrs.write(' type="${_escape(type)}"');
    if (title != null) attrs.write(' title="${_escape(title)}"');
    for (final entry in extra.entries) {
      attrs.write(' ${entry.key}="${_escape(entry.value)}"');
    }
    return '<link $attrs/>';
  }

  String _now() => DateTime.now().toUtc().toIso8601String();

  String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String _imageExtension(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return '.jpg';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return '.gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }
    return '.img';
  }
}
