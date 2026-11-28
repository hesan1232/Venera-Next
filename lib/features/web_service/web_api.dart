import 'dart:typed_data';

import 'web_models.dart';

class WebApiBadRequest implements Exception {
  const WebApiBadRequest(this.message);
  final String message;
  @override
  String toString() => message;
}

class WebApiNotFound implements Exception {
  const WebApiNotFound(this.message);
  final String message;
  @override
  String toString() => message;
}

class WebApiUnsupported implements Exception {
  const WebApiUnsupported(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Resolved image request produced by `/api/image`.
class WebImageRequest {
  const WebImageRequest({
    required this.kind,
    required this.ref,
    this.source,
    this.cid,
    this.eid,
  });

  final WebImageKind kind;
  final String ref;
  final String? source;
  final String? cid;
  final String? eid;

  /// Reverse of [webImageUrl]: turn a relative `/api/image?...` URL back into a
  /// request. Used by the Komga and OPDS layers, which receive URLs built by
  /// [ComicSource]s but need to resolve them through the same image pipeline.
  static WebImageRequest? fromUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final query = uri.queryParameters;
    final ref = query['ref'] ?? '';
    if (ref.isEmpty) return null;
    final kindName = query['kind'] ?? 'page';
    final kind = WebImageKind.values.firstWhere(
      (e) => e.name == kindName,
      orElse: () => WebImageKind.page,
    );
    return WebImageRequest(
      kind: kind,
      ref: ref,
      source: query['source'],
      cid: query['cid'],
      eid: query['eid'],
    );
  }
}

/// Everything the HTTP layer needs from the application.
///
/// The web service never imports managers directly; keeping the boundary as
/// functions makes the whole API testable without Flutter bindings or a
/// database.
class WebApiDeps {
  const WebApiDeps({
    required this.sources,
    required this.bookshelf,
    required this.search,
    required this.detail,
    required this.progress,
    required this.saveProgress,
    required this.chapterImages,
    required this.imageBytes,
    this.removeProgress,
  });

  final Future<List<WebSourceInfo>> Function() sources;
  final Future<List<WebComicInfo>> Function() bookshelf;
  final Future<WebSearchPage> Function(
    String keyword,
    String source,
    int page,
    String? next,
  )
  search;
  final Future<WebComicDetail> Function(String source, String id) detail;
  final Future<WebProgressInfo?> Function(String source, String id) progress;
  final Future<WebProgressInfo> Function(
    String source,
    String id,
    WebProgressUpdate update,
  )
  saveProgress;
  final Future<WebChapterImages> Function(String source, String id, int chapter)
  chapterImages;
  final Future<Uint8List?> Function(WebImageRequest request) imageBytes;

  /// Clears the reading history entry for one comic. Optional so the HTTP layer
  /// stays testable without a history database.
  final Future<void> Function(String source, String id)? removeProgress;
}

class WebApi {
  const WebApi(this._deps);

  final WebApiDeps _deps;

  Future<Map<String, Object?>> health() async => {
    'ok': true,
    'service': 'venera-next-web',
    'apiVersion': 1,
    'time': DateTime.now().toUtc().toIso8601String(),
  };

  Future<Map<String, Object?>> sources() async {
    final items = await sourceInfos();
    return {'sources': items.map((e) => e.toJson()).toList()};
  }

  Future<Map<String, Object?>> bookshelf() async {
    final items = await shelfItems();
    return {
      'comics': items.map((e) => e.toJson()).toList(),
      'total': items.length,
    };
  }

  Future<Map<String, Object?>> search({
    required String keyword,
    required String source,
    required int page,
    String? next,
  }) async {
    final result = await searchPage(
      keyword: keyword,
      source: source,
      page: page,
      next: next,
    );
    return result.toJson();
  }

  Future<WebSearchPage> searchPage({
    required String keyword,
    required String source,
    required int page,
    String? next,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      throw const WebApiBadRequest('Missing search keyword');
    }
    if (trimmed.length > 200) {
      throw const WebApiBadRequest('Search keyword is too long');
    }
    if (page < 1 || page > 10000) {
      throw const WebApiBadRequest('Invalid page number');
    }
    return _deps.search(trimmed, source, page, next);
  }

  Future<Map<String, Object?>> detail(String source, String id) async {
    final result = await comicDetail(source, id);
    return result.toJson();
  }

  /// Resolve a cover through the comic detail instead of trusting the URL a
  /// search result happened to carry.
  ///
  /// Many sources return a stale/host-specific cover URL in search results
  /// (or no cover at all) but a working one from `loadComicInfo`. The detail
  /// call is cached by the runtime, so this stays cheap even for a full grid.
  Future<Uint8List?> cover(String source, String id) async {
    final result = await comicDetail(source, id);
    final request = WebImageRequest.fromUrl(result.comic.cover);
    if (request == null) {
      throw const WebApiNotFound('This comic has no cover');
    }
    return image(request);
  }

  Future<Map<String, Object?>> progress(String source, String id) async {
    final result = await comicProgress(source, id);
    return {'progress': result?.toJson()};
  }

  Future<Map<String, Object?>> saveProgress(
    String source,
    String id,
    Map<String, Object?> body,
  ) async {
    final update = WebProgressUpdate.fromJson(body);
    final result = await writeProgress(source, id, update);
    return {'progress': result.toJson()};
  }

  Future<Map<String, Object?>> chapterImages(
    String source,
    String id,
    int chapter,
  ) async {
    final result = await chapterPages(source, id, chapter);
    return result.toJson();
  }

  Future<Uint8List?> image(WebImageRequest request) {
    if (request.ref.isEmpty) {
      throw const WebApiBadRequest('Missing image reference');
    }
    return _deps.imageBytes(request);
  }

  // ------------------------------------------------------- typed accessors
  //
  // The JSON routes and the Komga/OPDS layers share these; keeping the
  // validation in one place means an invalid id fails the same way on every
  // protocol.

  Future<List<WebSourceInfo>> sourceInfos() => _deps.sources();

  Future<List<WebComicInfo>> shelfItems() => _deps.bookshelf();

  Future<WebComicDetail> comicDetail(String source, String id) {
    _checkComic(source, id);
    return _deps.detail(source, id);
  }

  Future<WebProgressInfo?> comicProgress(String source, String id) {
    _checkComic(source, id);
    return _deps.progress(source, id);
  }

  Future<WebProgressInfo> writeProgress(
    String source,
    String id,
    WebProgressUpdate update,
  ) {
    _checkComic(source, id);
    return _deps.saveProgress(source, id, update);
  }

  Future<WebChapterImages> chapterPages(
    String source,
    String id,
    int chapter,
  ) {
    _checkComic(source, id);
    if (chapter < 1) {
      throw const WebApiBadRequest('Invalid chapter index');
    }
    return _deps.chapterImages(source, id, chapter);
  }

  Future<void> removeProgress(String source, String id) async {
    _checkComic(source, id);
    final remove = _deps.removeProgress;
    if (remove == null) {
      throw const WebApiUnsupported('Progress removal is not available');
    }
    await remove(source, id);
  }

  void _checkComic(String source, String id) {
    if (source.isEmpty || id.isEmpty) {
      throw const WebApiBadRequest('Missing comic source or id');
    }
  }
}
