import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/web_service/opds_catalog.dart';
import 'package:venera_next/features/web_service/store_zip.dart';
import 'package:venera_next/features/web_service/web_api.dart';
import 'package:venera_next/features/web_service/web_models.dart';
import 'package:xml/xml.dart';

void main() {
  late WebApi api;
  late OpdsCatalog catalog;
  late List<List<Object?>> imageCalls;

  setUp(() {
    imageCalls = [];
    api = WebApi(
      WebApiDeps(
        sources: () async => const [
          WebSourceInfo(
            key: 'demo',
            name: 'Demo & Co <Source>',
            searchable: true,
            local: false,
          ),
          WebSourceInfo(
            key: 'offline',
            name: 'Offline',
            searchable: false,
            local: true,
          ),
        ],
        bookshelf: () async => [
          WebComicInfo(
            id: 'a&1',
            source: 'demo',
            title: 'A & B <Comic>',
            cover: webImageUrl(
              ref: 'https://x/cover.png?a=1&b=2',
              kind: WebImageKind.cover,
              source: 'demo',
              cid: 'a&1',
            ),
            progress: const WebProgressInfo(chapter: 3, page: 7),
          ),
        ],
        search: (keyword, source, page, next) async => WebSearchPage(
          comics: [WebComicInfo(id: 'r1', source: source, title: keyword)],
          source: source,
          page: page,
          maxPage: 4,
        ),
        detail: (source, id) async => WebComicDetail(
          comic: WebComicInfo(id: id, source: source, title: 'Detail'),
          chapters: [
            WebChapterInfo(index: 1, id: 'e1', title: 'First'),
            WebChapterInfo(
              index: 2,
              id: 'e2',
              title: 'Second',
              groupTitle: 'Group 2',
            ),
          ],
        ),
        progress: (source, id) async => null,
        saveProgress: (source, id, update) async =>
            WebProgressInfo(chapter: update.chapter, page: update.page),
        chapterImages: (source, id, chapter) async => WebChapterImages(
          chapter: chapter,
          chapterId: 'e$chapter',
          images: [
            webImageUrl(
              ref: 'https://x/1.jpg',
              kind: WebImageKind.page,
              source: source,
              cid: id,
              eid: 'e$chapter',
            ),
            webImageUrl(
              ref: 'https://x/2.jpg',
              kind: WebImageKind.page,
              source: source,
              cid: id,
              eid: 'e$chapter',
            ),
          ],
          title: 'Chapter $chapter',
        ),
        imageBytes: (request) async {
          imageCalls.add([request.kind, request.ref, request.source ?? '']);
          return Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
        },
      ),
    );
    catalog = OpdsCatalog(api, 'http://192.168.1.7:8080');
  });

  test('root is a navigation feed that surfaces the bookshelf', () async {
    final doc = await catalog.root();
    expect(doc.contentType, OpdsCatalog.navigationType);
    expect(doc.body, contains('<?xml version="1.0" encoding="UTF-8"?>'));
    expect(doc.body, contains('<feed xmlns="http://www.w3.org/2005/Atom"'));
    expect(
      doc.body,
      contains('rel="search" href="http://192.168.1.7:8080/opds/search.xml"'),
    );
    // Like Komga's catalog, both directories are navigation subsections.
    // An acquisition-typed subsection here makes readers skip the bookshelf.
    expect(
      doc.body,
      contains(
        'href="http://192.168.1.7:8080/opds/bookshelf" type="${OpdsCatalog.navigationType}"',
      ),
    );
    expect(
      doc.body,
      contains(
        'href="http://192.168.1.7:8080/opds/libraries" type="${OpdsCatalog.navigationType}"',
      ),
    );
    // Sources are browsable under Libraries, not flattened onto the root.
    expect(doc.body, isNot(contains('Demo &amp; Co &lt;Source&gt;')));
    expect('${RegExp(r'rel="start"').allMatches(doc.body).length}', '1');
  });

  test('open search description uses acquisition feed template', () {
    final doc = catalog.searchDescriptor(source: 'demo');
    expect(doc.contentType, OpdsCatalog.openSearchType);
    expect(doc.body, contains('<OpenSearchDescription'));
    expect(
      doc.body,
      contains('q=%7BsearchTerms%7D&page=%7BstartPageIndex%7D&source=demo'),
    );
  });

  test('bookshelf entries carry cover, acquisition and progress', () async {
    final doc = await catalog.bookshelf();
    expect(doc.contentType, OpdsCatalog.acquisitionType);
    expect(doc.body, contains('A &amp; B &lt;Comic&gt;'));
    expect(doc.body, contains('rel="http://opds-spec.org/image/thumbnail"'));
    expect(doc.body, contains('rel="http://opds-spec.org/acquisition"'));
    expect(doc.body, contains('label="Chapter 3, page 7"'));
    expect(
      doc.body,
      contains('href="http://192.168.1.7:8080/opds/comic/demo/a%261"'),
    );
  });

  test('search feed advertises next page', () async {
    final doc = await catalog.search(keyword: 'a & b', source: 'demo', page: 1);
    expect(
      doc.body,
      contains(
        'href="http://192.168.1.7:8080/opds/search?q=a%20%26%20b&amp;source=demo&amp;page=2"',
      ),
    );
    expect(doc.body, contains('Search: a &amp; b'));
  });

  test('comic feed has one acquisition entry per chapter', () async {
    final doc = await catalog.comic('demo', 'id');
    expect(
      RegExp(
        r'rel="http://opds-spec.org/acquisition"',
      ).allMatches(doc.body).length,
      2,
    );
    expect(doc.body, contains('[Group 2] Second'));
    expect(doc.body, contains('/opds/cbz/demo/id/1'));
  });

  test('chapter feed lists pages with image acquisition links', () async {
    final doc = await catalog.chapter('demo', 'id', 1);
    expect(doc.body, contains('<title>Page 1</title>'));
    expect(doc.body, contains('<title>Page 2</title>'));
    expect(
      RegExp(r'rel="http://opds-spec.org/image"').allMatches(doc.body).length,
      2,
    );
    expect(doc.body, contains('type="image/jpeg"'));
  });

  test('CBZ downloads pages through the image pipeline', () async {
    final binary = await catalog.cbz('demo', 'id', 1);
    expect(binary.contentType, OpdsCatalog.cbzType);
    expect(binary.downloadName, 'chapter-1.cbz');
    expect(imageCalls.length, 2);
    expect(imageCalls.first[1], 'https://x/1.jpg');

    final zip = binary.bytes;
    expect(zip[0], 0x50); // PK
    expect(zip[1], 0x4b);
    final text = utf8.decode(zip, allowMalformed: true);
    expect(text, contains('0001.jpg'));
    expect(text, contains('0002.jpg'));
  });

  test('comic feed is well-formed XML with OPDS-PSE streaming links', () async {
    final doc = await catalog.comic('demo', 'id');
    final parsed = XmlDocument.parse(doc.body);
    final links = parsed.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'link')
        .toList();
    final streams = links
        .where(
          (e) =>
              e.getAttribute('rel') ==
              'http://vaemendis.net/opds-pse/stream',
        )
        .toList();
    expect(streams, hasLength(2));
    expect(
      streams.first.getAttribute('href'),
      'http://192.168.1.7:8080/opds/page/demo/id/1/{pageNumber}',
    );
    expect(streams.first.getAttribute('type'), 'image/jpeg');
    // The PSE namespace must be declared or strict readers drop the link.
    expect(
      parsed.rootElement.getAttribute('xmlns:pse'),
      'http://vaemendis.net/opds-pse/2.0/',
    );
  });

  test('libraries feed and per-library acquisition feed', () async {
    final nav = await catalog.libraries();
    expect(nav.contentType, OpdsCatalog.navigationType);
    expect(nav.body, contains('/opds/libraries/demo'));
    expect(nav.body, contains('/opds/libraries/offline'));

    final shelf = await catalog.library('demo');
    expect(shelf.contentType, OpdsCatalog.acquisitionType);
    expect(shelf.body, contains('A &amp; B &lt;Comic&gt;'));

    await expectLater(
      catalog.library('missing'),
      throwsA(isA<WebApiNotFound>()),
    );
  });

  test('page endpoint streams one image through the proxy', () async {
    final binary = await catalog.page('demo', 'id', 1, 2);
    expect(binary.contentType, 'image/jpeg');
    expect(binary.cacheable, isTrue);
    expect(imageCalls.single[1], 'https://x/2.jpg');
    await expectLater(
      catalog.page('demo', 'id', 1, 3),
      throwsA(isA<WebApiNotFound>()),
    );
  });

  test('store zip is readable structure with two entries', () {
    final archive = buildStoreZip([
      ZipEntry('a.txt', Uint8List.fromList([1, 2, 3])),
      ZipEntry('b.bin', Uint8List.fromList([4, 5])),
    ]);
    expect(archive.sublist(0, 4), [0x50, 0x4b, 0x03, 0x04]);
    expect(crc32(Uint8List.fromList([1, 2, 3])), isA<int>());
    final text = utf8.decode(archive, allowMalformed: true);
    expect(text, contains('a.txt'));
    expect(text, contains('b.bin'));
  });
}
