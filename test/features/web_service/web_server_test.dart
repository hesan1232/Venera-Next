import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/web_service/komga_api.dart';
import 'package:venera_next/features/web_service/web_api.dart';
import 'package:venera_next/features/web_service/web_models.dart';
import 'package:venera_next/features/web_service/web_server.dart';

void main() {
  late WebServer server;
  late int port;

  WebServer build({
    String token = '',
    bool allowProgressWrite = true,
    String? cover,
  }) {
    final api = WebApi(
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
          WebComicInfo(id: '1', source: 'demo', title: 'One'),
        ],
        search: (keyword, source, page, next) async {
          return WebSearchPage(
            comics: [WebComicInfo(id: keyword, source: source, title: keyword)],
            source: source,
            page: page,
          );
        },
        detail: (source, id) async => WebComicDetail(
          comic: WebComicInfo(
            id: id,
            source: source,
            title: id,
            cover: cover == null
                ? null
                : webImageUrl(
                    ref: cover,
                    kind: WebImageKind.cover,
                    source: source,
                    cid: id,
                  ),
            progress: const WebProgressInfo(chapter: 1, page: 2),
          ),
          chapters: [WebChapterInfo(index: 1, id: 'ep_1', title: 'Ep 1')],
        ),
        progress: (source, id) async =>
            const WebProgressInfo(chapter: 1, page: 2),
        saveProgress: (source, id, update) async =>
            WebProgressInfo(chapter: update.chapter, page: update.page),
        chapterImages: (source, id, chapter) async => WebChapterImages(
          chapter: chapter,
          chapterId: 'ep_$chapter',
          images: [
            webImageUrl(
              ref: 'https://x/1.png',
              kind: WebImageKind.page,
              source: source,
              cid: id,
              eid: 'ep_$chapter',
            ),
          ],
        ),
        imageBytes: (request) async => Uint8List.fromList([
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
          0,
          0,
        ]),
        removeProgress: (source, id) async {},
      ),
    );
    return WebServer(
      api: api,
      config: WebServerConfig(
        host: WebServerConfig.localhost,
        port: 0,
        token: token,
        allowProgressWrite: allowProgressWrite,
      ),
      assetLoader: (name) async {
        if (name == 'assets/web/index.html') {
          return Uint8List.fromList(utf8.encode('<html>venera</html>'));
        }
        return null;
      },
    );
  }

  Future<(int, HttpClientResponse)> send(
    String method,
    String path, {
    String? bearer,
    Object? body,
  }) async {
    final client = HttpClient();
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    addTearDown(client.close);
    return (response.statusCode, response);
  }

  Future<Map<String, Object?>> jsonOf(HttpClientResponse response) async {
    final text = await response.transform(utf8.decoder).join();
    return jsonDecode(text) as Map<String, Object?>;
  }

  Future<List<Object?>> jsonOfList(HttpClientResponse response) async {
    final text = await response.transform(utf8.decoder).join();
    return jsonDecode(text) as List<Object?>;
  }

  setUp(() async {
    server = build();
    await server.start();
    port = server.boundPort!;
  });

  tearDown(() async {
    await server.stop();
  });

  test('health and CORS preflight', () async {
    final (status, response) = await send('GET', '/api/health');
    expect(status, 200);
    expect(response.headers.value('Access-Control-Allow-Origin'), '*');
    final body = await jsonOf(response);
    expect(body['ok'], isTrue);
    expect(body['apiVersion'], 1);

    final (optionsStatus, options) = await send('OPTIONS', '/api/bookshelf');
    expect(optionsStatus, 204);
    await options.drain();
  });

  test('bookshelf, search and comic routes', () async {
    final (_, shelf) = await send('GET', '/api/bookshelf');
    expect(((await jsonOf(shelf))['comics'] as List).length, 1);

    final (_, search) = await send(
      'GET',
      '/api/search?q=needle&source=demo&page=2',
    );
    final searchBody = await jsonOf(search);
    expect(searchBody['page'], 2);
    expect(searchBody['comics'], isA<List>());

    final (_, detail) = await send('GET', '/api/comic/demo/id%20with%20space');
    final detailBody = await jsonOf(detail);
    expect(detailBody['id'], 'id with space');
    expect((detailBody['chapters'] as List).single, containsPair('id', 'ep_1'));

    final (_, images) = await send('GET', '/api/chapter/demo/id/3');
    expect((await jsonOf(images))['chapter'], 3);
  });

  test('progress can be read and written', () async {
    final (_, read) = await send('GET', '/api/progress/demo/1');
    expect((await jsonOf(read))['progress'], containsPair('page', 2));

    final (status, written) = await send(
      'PUT',
      '/api/progress/demo/1',
      body: {'chapter': 4, 'page': 8},
    );
    expect(status, 200);
    expect((await jsonOf(written))['progress'], containsPair('chapter', 4));
  });

  test('image proxy returns bytes with detected content type', () async {
    final (status, response) = await send('GET', '/api/image?ref=x&kind=page');
    expect(status, 200);
    expect(response.headers.contentType?.mimeType, 'image/png');
    expect(response.headers.value('Cache-Control'), contains('max-age'));
    expect(
      (await response.fold<Uint8List>(
        Uint8List(0),
        (previous, chunk) => Uint8List.fromList([...previous, ...chunk]),
      )).isNotEmpty,
      isTrue,
    );
  });

  test('cover route resolves through detail and reports missing covers', () async {
    final (missing, _) = await send('GET', '/api/cover/demo/1');
    expect(missing, 404);

    await server.stop();
    server = build(cover: 'https://x/cover.png');
    await server.start();
    port = server.boundPort!;
    final (status, response) = await send('GET', '/api/cover/demo/1');
    expect(status, 200);
    expect(response.headers.contentType?.mimeType, 'image/png');
  });

  test('static assets and unknown routes', () async {
    final (status, response) = await send('GET', '/');
    expect(status, 200);
    expect(
      await response.transform(utf8.decoder).join(),
      '<html>venera</html>',
    );

    final (missingStatus, missing) = await send('GET', '/nope');
    expect(missingStatus, 404);
    await missing.drain();

    final (badStatus, bad) = await send('GET', '/api/nope');
    expect(badStatus, 404);
    await bad.drain();
  });

  test('token protects API but not the web shell', () async {
    await server.stop();
    server = build(token: 'secret');
    await server.start();
    port = server.boundPort!;

    final (deniedStatus, denied) = await send('GET', '/api/bookshelf');
    expect(deniedStatus, 401);
    await denied.drain();

    final (okStatus, ok) = await send(
      'GET',
      '/api/bookshelf',
      bearer: 'secret',
    );
    expect(okStatus, 200);
    await ok.drain();

    final (queryStatus, query) = await send(
      'GET',
      '/api/bookshelf?token=secret',
    );
    expect(queryStatus, 200);
    await query.drain();

    final (shellStatus, shell) = await send('GET', '/');
    expect(shellStatus, 200);
    await shell.drain();
  });

  test('OPDS root, search descriptor and bookshelf serve Atom XML', () async {
    final (rootStatus, root) = await send('GET', '/opds');
    expect(rootStatus, 200);
    expect(root.headers.contentType?.toString(), contains('kind=navigation'));
    // OPDS readers that trust the HTTP header need an explicit charset, or
    // Chinese titles encoded as UTF-8 bytes render as mojibake.
    expect(root.headers.contentType?.charset, 'utf-8');
    expect(await root.transform(utf8.decoder).join(), contains('<feed'));

    final (searchStatus, descriptor) = await send('GET', '/opds/search.xml');
    expect(searchStatus, 200);
    expect(
      descriptor.headers.contentType?.mimeType,
      'application/opensearchdescription+xml',
    );
    await descriptor.drain();

    final (shelfStatus, shelf) = await send('GET', '/opds/bookshelf');
    expect(shelfStatus, 200);
    expect(shelf.headers.contentType?.toString(), contains('kind=acquisition'));
    await shelf.drain();
  });

  test('OPDS comic and chapter routes and CBZ download', () async {
    final (detailStatus, detail) = await send('GET', '/opds/comic/demo/id');
    expect(detailStatus, 200);
    expect(await detail.transform(utf8.decoder).join(), contains('Ep 1'));

    final (chapterStatus, chapter) = await send(
      'GET',
      '/opds/chapter/demo/id/1',
    );
    expect(chapterStatus, 200);
    expect(await chapter.transform(utf8.decoder).join(), contains('Page 1'));

    final (cbzStatus, cbz) = await send('GET', '/opds/cbz/demo/id/1');
    expect(cbzStatus, 200);
    expect(cbz.headers.contentType?.mimeType, 'application/vnd.comicbook+zip');
    expect(cbz.headers.value('content-disposition'), contains('chapter-1.cbz'));
    final bytes = await cbz.fold<Uint8List>(
      Uint8List(0),
      (previous, chunk) => Uint8List.fromList([...previous, ...chunk]),
    );
    expect(bytes.sublist(0, 2), [0x50, 0x4b]);
  });

  test('OPDS honors Basic auth challenge', () async {
    await server.stop();
    server = build(token: 'secret');
    await server.start();
    port = server.boundPort!;

    final (deniedStatus, denied) = await send('GET', '/opds');
    expect(deniedStatus, 401);
    expect(denied.headers.value('www-authenticate'), contains('Basic'));
    await denied.drain();

    final client = HttpClient();
    final request = await client.openUrl(
      'GET',
      Uri.parse('http://127.0.0.1:$port/opds'),
    );
    final credentials = base64.encode(utf8.encode('anything:secret'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Basic $credentials');
    final response = await request.close();
    expect(response.statusCode, 200);
    await response.drain();
    client.close();
  });

  test('OPDS advertises PSE streaming and serves single pages', () async {
    final (detailStatus, detail) = await send('GET', '/opds/comic/demo/id');
    expect(detailStatus, 200);
    final body = await detail.transform(utf8.decoder).join();
    expect(body, contains('xmlns:pse="http://vaemendis.net/opds-pse/2.0/"'));
    expect(body, contains('rel="http://vaemendis.net/opds-pse/stream"'));
    expect(body, contains('/opds/page/demo/id/1/{pageNumber}'));

    final (pageStatus, page) = await send('GET', '/opds/page/demo/id/1/1');
    expect(pageStatus, 200);
    expect(page.headers.contentType?.mimeType, 'image/png');
    await page.drain();

    final (missingStatus, missing) = await send('GET', '/opds/page/demo/id/1/9');
    expect(missingStatus, 404);
    await missing.drain();
  });

  test('OPDS accepts the Komga-style /opds/v1.2 alias', () async {
    final (status, response) = await send('GET', '/opds/v1.2/catalog');
    expect(status, 200);
    expect(response.headers.contentType?.toString(), contains('kind=navigation'));
    final body = await response.transform(utf8.decoder).join();
    expect(body, contains('<feed'));
    expect(body, contains('/opds/libraries'));
  });

  test('Komga v1 exposes libraries, series, books and pages', () async {
    final (libStatus, libraries) = await send('GET', '/api/v1/libraries');
    expect(libStatus, 200);
    // Komga returns a bare array for libraries.
    final library = ((await jsonOfList(libraries))).single as Map;
    expect(library['name'], 'Demo');
    expect(library['id'], startsWith('lib_'));

    final (seriesStatus, seriesPage) = await send(
      'GET',
      '/api/v1/series?page=0&size=10',
    );
    expect(seriesStatus, 200);
    final envelope = await jsonOf(seriesPage);
    expect(envelope['number'], 0);
    expect(envelope['totalElements'], 1);
    expect(envelope['last'], isTrue);
    final series = (envelope['content'] as List).single as Map;
    expect(series['name'], 'One');
    final seriesId = series['id'] as String;

    final (booksStatus, booksResponse) = await send(
      'GET',
      '/api/v1/series/$seriesId/books',
    );
    expect(booksStatus, 200);
    final books = await jsonOf(booksResponse);
    final book = (books['content'] as List).single as Map;
    expect(book['name'], 'Ep 1');
    final bookId = book['id'] as String;

    final (pagesStatus, pagesResponse) = await send(
      'GET',
      '/api/v1/books/$bookId/pages',
    );
    expect(pagesStatus, 200);
    expect(await jsonOfList(pagesResponse), hasLength(1));

    final (imageStatus, image) = await send(
      'GET',
      '/api/v1/books/$bookId/pages/1',
    );
    expect(imageStatus, 200);
    expect(image.headers.contentType?.mimeType, 'image/png');
    await image.drain();

    // Komga clients that index from 0 pass zero_based=true.
    final (zeroStatus, zero) = await send(
      'GET',
      '/api/v1/books/$bookId/pages/0?zero_based=true',
    );
    expect(zeroStatus, 200);
    await zero.drain();

    final (thumbStatus, thumb) = await send(
      'GET',
      '/api/v1/series/$seriesId/thumbnail',
    );
    // The fixture comic has no cover, so the series thumbnail is a 404 while
    // book thumbnails fall back to the first page.
    expect(thumbStatus, 404);
    await thumb.drain();
  });

  test('Komga read-progress reads and writes', () async {
    final bookId = KomgaIds.book('demo', '1', 1);
    final (readStatus, read) = await send(
      'GET',
      '/api/v1/books/$bookId/read-progress',
    );
    expect(readStatus, 200);
    expect((await jsonOf(read))['page'], 2);

    final (writeStatus, write) = await send(
      'PATCH',
      '/api/v1/books/$bookId/read-progress',
      body: {'page': 5, 'completed': true},
    );
    expect(writeStatus, 204);
    await write.drain();

    final (deleteStatus, deleted) = await send(
      'DELETE',
      '/api/v1/books/$bookId/read-progress',
    );
    expect(deleteStatus, 204);
    await deleted.drain();
  });

  test('Komga endpoints accept an X-API-Key', () async {
    await server.stop();
    server = build(token: 'secret');
    await server.start();
    port = server.boundPort!;

    final client = HttpClient();
    final request = await client.openUrl(
      'GET',
      Uri.parse('http://127.0.0.1:$port/api/v1/libraries'),
    );
    request.headers.set('x-api-key', 'secret');
    final response = await request.close();
    expect(response.statusCode, 200);
    await response.drain();
    client.close();
  });

  test('bundled web assets are served from the asset bundle', () async {
    await server.stop();
    final api = WebApi(
      WebApiDeps(
        sources: () async => const [],
        bookshelf: () async => const [],
        search: (keyword, source, page, next) async =>
            WebSearchPage(comics: const [], source: source),
        detail: (source, id) async => WebComicDetail(
          comic: WebComicInfo(id: id, source: source, title: id),
          chapters: const [],
        ),
        progress: (source, id) async => null,
        saveProgress: (source, id, update) async =>
            WebProgressInfo(chapter: update.chapter, page: update.page),
        chapterImages: (source, id, chapter) async => WebChapterImages(
          chapter: chapter,
          chapterId: 'ep_$chapter',
          images: const [],
        ),
        imageBytes: (request) async => null,
      ),
    );
    server = WebServer(
      api: api,
      config: const WebServerConfig(
        host: WebServerConfig.localhost,
        port: 0,
        token: '',
        allowProgressWrite: true,
      ),
      assetLoader: (name) async {
        final file = File(name);
        if (!await file.exists()) return null;
        return file.readAsBytes();
      },
    );
    await server.start();
    port = server.boundPort!;

    for (final path in ['/', '/app.js', '/style.css']) {
      final (status, response) = await send('GET', path);
      expect(status, 200, reason: path);
      final text = await response.transform(utf8.decoder).join();
      expect(text, isNotEmpty, reason: path);
    }

    final (indexStatus, index) = await send('GET', '/');
    expect(indexStatus, 200);
    final html = await index.transform(utf8.decoder).join();
    // The shell must point at assets the server actually exposes.
    expect(html, contains('/app.js'));
    expect(html, contains('/style.css'));
    expect(html, contains('id="app"'));
  });

  test('disabled progress writing returns 501', () async {
    await server.stop();
    server = build(allowProgressWrite: false);
    await server.start();
    port = server.boundPort!;
    final (status, response) = await send(
      'PUT',
      '/api/progress/demo/1',
      body: {'chapter': 1, 'page': 1},
    );
    expect(status, 501);
    expect((await jsonOf(response))['error'], contains('disabled'));
  });

  test('reconfigure releases the old port', () async {
    final oldPort = port;
    await server.reconfigure(
      WebServerConfig(
        host: WebServerConfig.localhost,
        port: 0,
        token: '',
        allowProgressWrite: true,
      ),
    );
    port = server.boundPort!;
    expect(port, isNot(oldPort));

    Socket? socket;
    try {
      socket = await Socket.connect(
        '127.0.0.1',
        oldPort,
        timeout: const Duration(seconds: 1),
      );
    } catch (_) {
      // Expected: the old listener was released by reconfigure().
    }
    expect(socket, isNull);
    await socket?.close();
  });
}
