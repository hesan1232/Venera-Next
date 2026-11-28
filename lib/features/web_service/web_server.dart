import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'komga_api.dart';
import 'opds_catalog.dart';
import 'web_api.dart';
import 'web_models.dart';

class WebServerConfig {
  const WebServerConfig({
    required this.host,
    required this.port,
    required this.token,
    required this.allowProgressWrite,
  });

  final String host;
  final int port;

  /// Empty means open access. When set, every /api request needs
  /// `Authorization: Bearer <token>` or `?token=<token>`.
  final String token;
  final bool allowProgressWrite;

  static const localhost = '127.0.0.1';
  static const allInterfaces = '0.0.0.0';
}

class WebImagePayload {
  const WebImagePayload(this.bytes, this.contentType, {this.cacheable = true});
  final Uint8List bytes;
  final String contentType;
  final bool cacheable;
}

/// Raw text payload (Atom feeds, OpenSearch documents) with an explicit type.
class WebTextPayload {
  const WebTextPayload(this.text, this.contentType);
  final String text;
  final String contentType;
}

class _JsonPayload {
  const _JsonPayload(this.value);
  final Object value;
}

/// Empty `204 No Content` response, used by the Komga write endpoints.
class _NoContent {
  const _NoContent();
}

/// Minimal HTTP server for the LAN web reader.
///
/// It depends only on [WebApi] and an injected asset loader so the whole
/// server can be exercised on an ephemeral loopback port in unit tests.
class WebServer {
  WebServer({
    required WebApi api,
    required WebServerConfig config,
    required Future<Uint8List?> Function(String name) assetLoader,
    void Function(String message)? onLog,
  }) : _api = api,
       _config = config,
       _assetLoader = assetLoader,
       _onLog = onLog;

  final WebApi _api;
  final Future<Uint8List?> Function(String name) _assetLoader;
  final void Function(String message)? _onLog;

  WebServerConfig _config;
  HttpServer? _server;

  bool get isRunning => _server != null;
  int? get boundPort => _server?.port;
  WebServerConfig get config => _config;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(_config.host, _config.port);
    _server = server;
    server.listen(
      _onRequest,
      onError: (error, stack) => _log('request error: $error'),
      cancelOnError: false,
    );
    _log('listening on ${server.address.host}:${server.port}');
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server == null) return;
    await server.close(force: true);
    _log('stopped');
  }

  /// Rebind when port/host/token changed. A failure leaves the server stopped.
  Future<void> reconfigure(WebServerConfig config) async {
    await stop();
    _config = config;
    await start();
  }

  void _log(String message) => _onLog?.call('WebService: $message');

  Future<void> _onRequest(HttpRequest request) async {
    final response = request.response;
    _addCors(response);
    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    final path = request.uri.path;
    final isApi = path.startsWith('/api/');
    final isOpds = path == '/opds' || path.startsWith('/opds/');
    final isStatic = !isApi && !isOpds;
    if ((isApi || isOpds) && !_authorized(request)) {
      if (isOpds) {
        // OPDS readers discover credentials via a WWW-Authenticate challenge.
        response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Basic realm="Venera OPDS", charset="UTF-8"',
        );
      }
      await _writeJson(response, HttpStatus.unauthorized, {
        'error': 'Unauthorized',
      });
      return;
    }

    Object payload;
    String contentType = 'application/json; charset=utf-8';
    int status = HttpStatus.ok;
    var cacheable = false;
    String? downloadName;
    try {
      final result = isApi
          ? await _handleApi(request, path)
          : isOpds
          ? await _handleOpds(request, path)
          : await _handleStatic(path);
      if (result == null) {
        payload = {'error': 'Not found'};
        status = HttpStatus.notFound;
      } else if (result is WebImagePayload) {
        payload = result.bytes;
        contentType = result.contentType;
        cacheable = result.cacheable;
      } else if (result is OpdsBinary) {
        payload = result.bytes;
        contentType = result.contentType;
        cacheable = result.cacheable;
        downloadName = result.downloadName;
      } else if (result is WebTextPayload) {
        payload = result.text;
        contentType = result.contentType;
      } else if (result is _NoContent) {
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      } else {
        payload = (result as _JsonPayload).value;
      }
    } on WebApiBadRequest catch (error) {
      payload = {'error': error.message};
      status = HttpStatus.badRequest;
    } on WebApiNotFound catch (error) {
      payload = {'error': error.message};
      status = HttpStatus.notFound;
    } on WebApiUnsupported catch (error) {
      payload = {'error': error.message};
      status = HttpStatus.notImplemented;
    } on FormatException catch (error) {
      payload = {'error': error.message};
      status = HttpStatus.badRequest;
    } on ArgumentError catch (error) {
      payload = {'error': error.message};
      status = HttpStatus.badRequest;
    } catch (error, stack) {
      _log('$path failed: $error\n$stack');
      payload = {'error': 'Internal server error'};
      status = HttpStatus.internalServerError;
    }

    response.statusCode = status;
    // Text payloads are written as UTF-8 bytes below. Atom/OPDS media types
    // carry profile/kind parameters but no charset, so readers that trust the
    // HTTP header over the XML declaration decode Chinese titles as latin1
    // and show mojibake. Declare UTF-8 whenever the body is textual.
    final wireContentType =
        payload is String && !contentType.toLowerCase().contains('charset=')
        ? '$contentType; charset=utf-8'
        : contentType;
    response.headers.contentType = ContentType.parse(wireContentType);
    if (isStatic) {
      // The bundled client changes with the app. A stale cached app.js makes
      // new routes (including /api/search) look broken after an app update.
      response.headers.set('Cache-Control', 'no-cache');
    }
    if (downloadName != null) {
      response.headers.set(
        'content-disposition',
        'attachment; filename="$downloadName"',
      );
    }
    if (payload is Uint8List) {
      if (status == HttpStatus.ok && cacheable) {
        response.headers.set('Cache-Control', 'public, max-age=3600');
      }
      await response.addStream(Stream.value(payload));
      await response.close();
    } else if (payload is String) {
      // HttpResponse.write() encodes as latin1 by default, which throws on
      // non-latin1 text (e.g. Chinese comic titles in OPDS feeds). Write the
      // UTF-8 bytes explicitly so real-world source metadata is safe.
      response.add(utf8.encode(payload));
      await response.close();
    } else {
      response.add(utf8.encode(jsonEncode(payload)));
      await response.close();
    }
  }

  bool _authorized(HttpRequest request) {
    final expected = _config.token;
    if (expected.isEmpty) return true;
    // Bearer for the bundled web client, Basic for OPDS readers, X-API-Key for
    // Komga-style integrations (Komelia, Tachiyomi extensions, cron scripts).
    if (request.headers.value('x-api-key') == expected) return true;
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == 'Bearer $expected') return true;
    // OPDS readers use HTTP Basic: any username, the access token as password.
    if (header != null && header.startsWith('Basic ')) {
      try {
        final decoded = utf8.decode(base64.decode(header.substring(6).trim()));
        final separator = decoded.indexOf(':');
        if (separator >= 0 && decoded.substring(separator + 1) == expected) {
          return true;
        }
      } catch (_) {
        // Malformed Basic header falls through to the query token check.
      }
    }
    final query = request.uri.queryParameters;
    return query['token'] == expected || query['apiKey'] == expected;
  }

  void _addCors(HttpResponse response) {
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, PUT, PATCH, POST, DELETE, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Content-Type, Authorization')
      ..set('Access-Control-Expose-Headers', 'Content-Type');
  }

  /// OPDS 1.2 catalog routes. All feeds are derived from [WebApi], so the
  /// catalog and the JSON API always agree on what is in the library.
  ///
  /// `/opds/v1.2/...` is accepted as an alias so readers preconfigured for
  /// Komga (`<host>/opds/v1.2/catalog`) work after only changing the host.
  Future<Object?> _handleOpds(HttpRequest request, String path) async {
    if (request.method != 'GET') {
      throw const WebApiNotFound('Unknown OPDS endpoint');
    }
    final normalized = path.startsWith('/opds/v1.2')
        ? '/opds${path.substring('/opds/v1.2'.length)}'
        : path;
    final q = request.uri.queryParameters;
    final segments = normalized
        .split('/')
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final catalog = OpdsCatalog(
      _api,
      _baseUrl(request),
      appName: 'Venera Next',
    );

    if (normalized == '/opds' ||
        normalized == '/opds/' ||
        normalized == '/opds/catalog' ||
        normalized == '/opds/catalog.xml' ||
        normalized == '/opds/index.xml') {
      final doc = await catalog.root();
      return WebTextPayload(doc.body, doc.contentType);
    }
    if (normalized == '/opds/libraries') {
      final doc = await catalog.libraries();
      return WebTextPayload(doc.body, doc.contentType);
    }
    if (segments.length == 3 && segments[1] == 'libraries') {
      final doc = await catalog.library(segments[2]);
      return WebTextPayload(doc.body, doc.contentType);
    }
    if (normalized == '/opds/search.xml') {
      final doc = catalog.searchDescriptor(source: q['source']);
      return WebTextPayload(doc.body, doc.contentType);
    }
    if (normalized == '/opds/bookshelf') {
      final doc = await catalog.bookshelf();
      return WebTextPayload(doc.body, doc.contentType);
    }
    if (normalized == '/opds/search') {
      final keyword = q['q'] ?? '';
      if (keyword.trim().isEmpty) {
        throw const WebApiBadRequest('Missing search keyword');
      }
      final doc = await catalog.search(
        keyword: keyword,
        source: q['source'] ?? 'all',
        page: int.tryParse(q['page'] ?? '1') ?? 1,
        next: q['next'],
      );
      return WebTextPayload(doc.body, doc.contentType);
    }
    if (segments.length == 4 && segments[1] == 'comic') {
      final doc = await catalog.comic(segments[2], segments[3]);
      return WebTextPayload(doc.body, doc.contentType);
    }
    if (segments.length == 5 && segments[1] == 'chapter') {
      final chapter = int.tryParse(segments[4]);
      if (chapter == null) {
        throw const WebApiBadRequest('Invalid chapter index');
      }
      final doc = await catalog.chapter(segments[2], segments[3], chapter);
      return WebTextPayload(doc.body, doc.contentType);
    }
    if (segments.length == 5 && segments[1] == 'cbz') {
      final chapter = int.tryParse(segments[4]);
      if (chapter == null) {
        throw const WebApiBadRequest('Invalid chapter index');
      }
      return catalog.cbz(segments[2], segments[3], chapter);
    }
    // OPDS-PSE page streaming: one image per request, addressed by the
    // `{pageNumber}` template the acquisition feed advertises.
    if (segments.length == 6 && segments[1] == 'page') {
      final chapter = int.tryParse(segments[4]);
      final page = int.tryParse(segments[5]);
      if (chapter == null || page == null) {
        throw const WebApiBadRequest('Invalid page request');
      }
      return catalog.page(segments[2], segments[3], chapter, page);
    }
    throw const WebApiNotFound('Unknown OPDS endpoint');
  }

  /// The address clients actually used, so generated links stay on the same
  /// host (LAN IP, not the bind address 0.0.0.0).
  String _baseUrl(HttpRequest request) {
    final host = request.headers.value(HttpHeaders.hostHeader);
    if (host != null && host.isNotEmpty) return 'http://$host';
    return 'http://${_config.host}:${_server?.port ?? _config.port}';
  }

  Future<Object?> _handleApi(HttpRequest request, String path) async {
    // Komga-compatible surface. Kept as a separate branch so the legacy
    // /api/* routes stay byte-for-byte identical for the bundled web client.
    if (path.startsWith('/api/v1/')) {
      return _handleKomga(request, path);
    }
    final q = request.uri.queryParameters;
    // pathSegments splits before percent-decoding, so an encoded slash in a
    // comic id stays inside one segment.
    final segments = request.uri.pathSegments;

    if (path == '/api/health' && request.method == 'GET') {
      return _JsonPayload(await _api.health());
    }
    if (path == '/api/sources' && request.method == 'GET') {
      return _JsonPayload(await _api.sources());
    }
    if (path == '/api/bookshelf' && request.method == 'GET') {
      return _JsonPayload(await _api.bookshelf());
    }
    if (path == '/api/search' && request.method == 'GET') {
      final page = int.tryParse(q['page'] ?? '1') ?? 1;
      return _JsonPayload(
        await _api.search(
          keyword: q['q'] ?? '',
          source: q['source'] ?? 'all',
          page: page,
          next: q['next'],
        ),
      );
    }
    if (segments.length == 4 &&
        segments[0] == 'api' &&
        segments[1] == 'comic' &&
        request.method == 'GET') {
      return _JsonPayload(await _api.detail(segments[2], segments[3]));
    }
    if (segments.length == 4 &&
        segments[0] == 'api' &&
        segments[1] == 'progress') {
      if (request.method == 'GET') {
        return _JsonPayload(await _api.progress(segments[2], segments[3]));
      }
      if (request.method == 'PUT') {
        if (!_config.allowProgressWrite) {
          throw const WebApiUnsupported('Progress writing is disabled');
        }
        final body = await _readJsonBody(request);
        return _JsonPayload(
          await _api.saveProgress(segments[2], segments[3], body),
        );
      }
    }
    if (segments.length == 5 &&
        segments[0] == 'api' &&
        segments[1] == 'chapter' &&
        request.method == 'GET') {
      final chapter = int.tryParse(segments[4]);
      if (chapter == null) {
        throw const WebApiBadRequest('Invalid chapter index');
      }
      return _JsonPayload(
        await _api.chapterImages(segments[2], segments[3], chapter),
      );
    }
    if (segments.length == 4 &&
        segments[0] == 'api' &&
        segments[1] == 'cover' &&
        request.method == 'GET') {
      final bytes = await _api.cover(segments[2], segments[3]);
      if (bytes == null) throw const WebApiNotFound('Image not found');
      return WebImagePayload(bytes, _detectImageType(bytes));
    }
    if (path == '/api/image' && request.method == 'GET') {
      final kindName = q['kind'] ?? 'page';
      final kind = WebImageKind.values.firstWhere(
        (e) => e.name == kindName,
        orElse: () => WebImageKind.page,
      );
      final bytes = await _api.image(
        WebImageRequest(
          kind: kind,
          ref: q['ref'] ?? '',
          source: q['source'],
          cid: q['cid'],
          eid: q['eid'],
        ),
      );
      if (bytes == null) throw const WebApiNotFound('Image not found');
      return WebImagePayload(bytes, _detectImageType(bytes));
    }
    throw const WebApiNotFound('Unknown API endpoint');
  }

  /// Komga v1 API. Routes mirror the upstream shape so existing clients work:
  ///
  /// ```
  /// GET    /api/v1/users/me
  /// GET    /api/v1/libraries[/{id}]
  /// GET    /api/v1/series?page=&size=&search=&library_id=&sort=
  /// GET    /api/v1/series/{id}[/books][/thumbnail]
  /// GET    /api/v1/books/{id}[/pages][/pages/{n}][/thumbnail][/file]
  /// GET    /api/v1/books/{id}/{next|previous}
  /// GET    PUT DELETE /api/v1/books/{id}/read-progress
  /// GET    /api/v1/search?q=
  /// ```
  Future<Object?> _handleKomga(HttpRequest request, String path) async {
    final komga = KomgaApi(_api, _baseUrl(request));
    final q = request.uri.queryParameters;
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final segments = normalized
        .split('/')
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final tail = segments.length > 2 ? segments.sublist(2) : const <String>[];
    final method = request.method;
    final page = (int.tryParse(q['page'] ?? '0') ?? 0).clamp(0, 100000);
    final size = (int.tryParse(q['size'] ?? '20') ?? 20).clamp(1, 500);

    if (method != 'GET' &&
        method != 'PUT' &&
        method != 'PATCH' &&
        method != 'DELETE') {
      throw const WebApiNotFound('Unknown API endpoint');
    }

    if (_is(tail, ['users', 'me']) && method == 'GET') {
      return _JsonPayload(await komga.me());
    }
    if (_is(tail, ['libraries']) && method == 'GET') {
      // Komga returns a bare array here.
      return _JsonPayload(await komga.libraries());
    }
    if (tail.length == 2 && tail[0] == 'libraries' && method == 'GET') {
      return _JsonPayload(await komga.library(tail[1]));
    }
    if (_is(tail, ['series']) && method == 'GET') {
      return _JsonPayload(
        await komga.series(
          page: page,
          size: size,
          search: q['search'],
          libraryId: q['library_id'],
          sort: q['sort'],
        ),
      );
    }
    if (tail.length == 2 && tail[0] == 'series' && method == 'GET') {
      return _JsonPayload(await komga.seriesDetail(tail[1]));
    }
    if (tail.length == 3 && tail[0] == 'series') {
      if (tail[2] == 'books' && method == 'GET') {
        return _JsonPayload(
          await komga.seriesBooks(tail[1], page: page, size: size),
        );
      }
      if (tail[2] == 'thumbnail' && method == 'GET') {
        final bytes = await komga.seriesThumbnail(tail[1]);
        if (bytes == null) throw const WebApiNotFound('No thumbnail');
        return WebImagePayload(bytes, _detectImageType(bytes));
      }
    }
    if (tail.length == 2 && tail[0] == 'books' && method == 'GET') {
      return _JsonPayload(await komga.book(tail[1]));
    }
    if (tail.length == 3 && tail[0] == 'books') {
      if (tail[2] == 'pages' && method == 'GET') {
        // Komga returns a bare array of PageDto here.
        return _JsonPayload(await komga.bookPages(tail[1]));
      }
      if (tail[2] == 'thumbnail' && method == 'GET') {
        final bytes = await komga.bookThumbnail(tail[1]);
        if (bytes == null) throw const WebApiNotFound('No thumbnail');
        return WebImagePayload(bytes, _detectImageType(bytes));
      }
      if (tail[2] == 'file' && method == 'GET') {
        return komga.bookFile(tail[1]);
      }
      if (tail[2] == 'next' && method == 'GET') {
        return _JsonPayload(await komga.sibling(tail[1], 1));
      }
      if (tail[2] == 'previous' && method == 'GET') {
        return _JsonPayload(await komga.sibling(tail[1], -1));
      }
      if (tail[2] == 'read-progress') {
        if (method == 'GET') {
          final progress = await komga.readProgress(tail[1]);
          if (progress == null) return const _NoContent();
          return _JsonPayload(progress);
        }
        if (method == 'PUT' || method == 'PATCH') {
          if (!_config.allowProgressWrite) {
            throw const WebApiUnsupported('Progress writing is disabled');
          }
          final body = await _readJsonBody(request);
          await komga.saveReadProgress(tail[1], body);
          return const _NoContent();
        }
        if (method == 'DELETE') {
          await komga.deleteReadProgress(tail[1]);
          return const _NoContent();
        }
      }
    }
    if (tail.length == 4 &&
        tail[0] == 'books' &&
        tail[2] == 'pages' &&
        method == 'GET') {
      final number = int.tryParse(tail[3]);
      if (number == null) throw const WebApiBadRequest('Invalid page number');
      // Komga page numbers are 1-based; `zero_based=true` shifts them.
      final resolved = q['zero_based'] == 'true' ? number + 1 : number;
      final bytes = await komga.bookPageImage(tail[1], resolved);
      if (bytes == null) throw const WebApiNotFound('Page not found');
      return WebImagePayload(bytes, _detectImageType(bytes));
    }
    if (_is(tail, ['search']) && method == 'GET') {
      return _JsonPayload(await komga.search(q['q'] ?? ''));
    }
    throw const WebApiNotFound('Unknown API endpoint');
  }

  static bool _is(List<String> tail, List<String> expected) {
    if (tail.length != expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (tail[i] != expected[i]) return false;
    }
    return true;
  }

  static const _staticFiles = <String, (String, String)>{
    '/': ('assets/web/index.html', 'text/html; charset=utf-8'),
    '/index.html': ('assets/web/index.html', 'text/html; charset=utf-8'),
    '/app.js': ('assets/web/app.js', 'text/javascript; charset=utf-8'),
    '/style.css': ('assets/web/style.css', 'text/css; charset=utf-8'),
    '/favicon.svg': ('assets/web/favicon.svg', 'image/svg+xml'),
  };

  Future<Object?> _handleStatic(String path) async {
    final entry = _staticFiles[path];
    if (entry == null) return null;
    final bytes = await _assetLoader(entry.$1);
    if (bytes == null) return null;
    return WebImagePayload(bytes, entry.$2, cacheable: false);
  }

  static String _detectImageType(Uint8List bytes) => detectImageType(bytes);

  static Future<Map<String, Object?>> _readJsonBody(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    if (text.trim().isEmpty) return {};
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const WebApiBadRequest('JSON object expected');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  static Future<void> _writeJson(
    HttpResponse response,
    int status,
    Object body,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.parse(
      'application/json; charset=utf-8',
    );
    response.write(jsonEncode(body));
    await response.close();
  }

  /// LAN addresses suitable for showing in the settings page.
  static Future<List<String>> localAddresses() async {
    final result = <String>{};
    try {
      for (final interface in await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      )) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) result.add(address.address);
        }
      }
    } catch (_) {
      // Network enumeration is best effort.
    }
    return result.toList()..sort();
  }
}
