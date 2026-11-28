import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/web_service/web_api.dart';
import 'package:venera_next/features/web_service/web_models.dart';
import 'package:venera_next/features/web_service/web_server.dart';

/// End-to-end HTTP test for the embedded web service, driven by metadata that
/// mirrors the REAL official Tencent source (`qq_comic_official_v1`): its real
/// key/name, a real comic id shape, chapter ids and image URL shape.
///
/// The source script's JS cannot execute here (QuickJS native library requires
/// Windows Developer Mode to build), so the source callbacks are stubbed with
/// these real-shaped values. The HTTP layer, routing, OPDS XML and CBZ packing
/// are all the production implementations running over a real socket.
void main() {
  const sourceKey = 'qq_comic_official_v1';
  const sourceName = '腾讯动漫（正版）';
  const comicId = '505142';
  final chapterImages = List.generate(
    3,
    (i) => 'https://m.ac.qq.com/chapter/img/$comicId/${i + 1}.webp',
  );

  late WebServer server;
  late int port;

  WebServer build() {
    final sources = [
      WebSourceInfo(
        key: sourceKey,
        name: sourceName,
        searchable: true,
        local: false,
      ),
    ];
    WebComicInfo comic(String id) => WebComicInfo(
          id: id,
          source: sourceKey,
          title: '真实漫画 $id',
          cover: webImageUrl(
            ref: 'https://m.ac.qq.com/cover/$id.jpg',
            kind: WebImageKind.cover,
            source: sourceKey,
            cid: id,
          ),
        );
    final chapters = [
      WebChapterInfo(index: 1, id: 'cid_1', title: '第 1 话'),
      WebChapterInfo(index: 2, id: 'cid_2', title: '第 2 话'),
      WebChapterInfo(index: 3, id: 'cid_3', title: '第 3 话'),
    ];

    final api = WebApi(
      WebApiDeps(
        sources: () async => sources,
        bookshelf: () async => [
          comic(comicId).copyWith(
            progress: const WebProgressInfo(
              chapter: 2,
              page: 1,
              maxChapter: 3,
              maxPage: 3,
            ),
          ),
        ],
        search: (keyword, source, page, next) async => WebSearchPage(
          comics: [comic(keyword)],
          source: source,
          page: page,
        ),
        detail: (source, id) async => WebComicDetail(
          comic: comic(id),
          chapters: chapters,
        ),
        progress: (source, id) async => const WebProgressInfo(
          chapter: 2,
          page: 1,
          maxChapter: 3,
          maxPage: 3,
        ),
        saveProgress: (source, id, update) async => WebProgressInfo(
          chapter: update.chapter,
          page: update.page,
          maxChapter: 3,
          maxPage: 3,
        ),
        chapterImages: (source, id, chapter) async => WebChapterImages(
          chapter: chapter,
          chapterId: 'cid_$chapter',
          images: [
            for (final url in chapterImages)
              webImageUrl(
                ref: url,
                kind: WebImageKind.page,
                source: source,
                cid: id,
                eid: 'cid_$chapter',
              ),
          ],
        ),
        imageBytes: (request) async => Uint8List.fromList([
          0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0,
        ]),
      ),
    );
    return WebServer(
      api: api,
      config: WebServerConfig(
        host: WebServerConfig.localhost,
        port: 0,
        token: '',
        allowProgressWrite: true,
      ),
      assetLoader: (name) async => null,
    );
  }

  Future<(int, HttpClientResponse)> send(String method, String path) async {
    final client = HttpClient();
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    final response = await request.close();
    addTearDown(client.close);
    return (response.statusCode, response);
  }

  setUp(() async {
    server = build();
    await server.start();
    port = server.boundPort!;
  });

  tearDown(() async {
    await server.stop();
  });

  test('real source appears in /api/sources with its real key', () async {
    final (status, response) = await send('GET', '/api/sources');
    expect(status, 200);
    final body = jsonDecode(await response.transform(utf8.decoder).join())
        as Map<String, Object?>;
    final sources = (body['sources'] as List).cast<Map<String, Object?>>();
    expect(
      sources.any((s) => s['key'] == sourceKey && s['name'] == sourceName),
      isTrue,
    );
  });

  test('real search, detail and chapter image routes round-trip', () async {
    final (_, search) = await send(
      'GET',
      '/api/search?q=$comicId&source=$sourceKey&page=1',
    );
    final searchBody =
        jsonDecode(await search.transform(utf8.decoder).join())
            as Map<String, Object?>;
    expect((searchBody['comics'] as List), isNotEmpty);

    final (_, detail) =
        await send('GET', '/api/comic/$sourceKey/$comicId');
    final detailBody =
        jsonDecode(await detail.transform(utf8.decoder).join())
            as Map<String, Object?>;
    expect((detailBody['chapters'] as List).length, 3);

    final (_, images) =
        await send('GET', '/api/chapter/$sourceKey/$comicId/2');
    final imageBody =
        jsonDecode(await images.transform(utf8.decoder).join())
            as Map<String, Object?>;
    expect(imageBody['chapterId'], 'cid_2');
    expect((imageBody['images'] as List).length, chapterImages.length);
  });

  test('OPDS bookshelf and comic acquisition feed use the real source', () async {
    final (status, shelf) = await send('GET', '/opds/bookshelf');
    expect(status, 200);
    expect(shelf.headers.contentType?.toString(), contains('kind=acquisition'));
    expect(shelf.headers.contentType?.charset, 'utf-8');
    final shelfXml = await shelf.transform(utf8.decoder).join();
    expect(shelfXml, contains('真实漫画 $comicId'));

    final (detailStatus, detail) =
        await send('GET', '/opds/comic/$sourceKey/$comicId');
    expect(detailStatus, 200);
    final detailXml = await detail.transform(utf8.decoder).join();
    expect(detailXml, contains('<feed'));
    expect(detailXml, contains('第 1 话'));
  });

  test('OPDS CBZ download returns a store-mode ZIP with real image names',
      () async {
    final (status, cbz) =
        await send('GET', '/opds/cbz/$sourceKey/$comicId/1');
    expect(status, 200);
    expect(cbz.headers.contentType?.mimeType, 'application/vnd.comicbook+zip');
    expect(
      cbz.headers.value('content-disposition'),
      contains('.cbz'),
    );
    final builder = BytesBuilder(copy: false);
    await for (final chunk in cbz) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    // Local file header "PK\x03\x04" at the front; the 22-byte EOCD record
    // starts 22 bytes from the end with "PK\x05\x06" (last 2 bytes = comment len).
    expect(bytes.sublist(0, 4), [0x50, 0x4b, 0x03, 0x04]);
    expect(bytes.length, greaterThan(22));
    expect(bytes.sublist(bytes.length - 22, bytes.length - 18), [
      0x50, 0x4b, 0x05, 0x06,
    ]);
  });
}
