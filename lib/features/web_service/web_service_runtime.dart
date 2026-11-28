import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/history_contract.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/missing_download_page.dart';
import 'package:venera_next/network/image_stream.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/request_scope.dart';

import 'web_api.dart';
import 'web_models.dart';
import 'web_server.dart';

typedef WebSearchLoader = Future<Res<List<Comic>>> Function();

/// Pick the loader a source actually declared. Some sources only expose the
/// cursor-based `loadNext`; calling `loadPage!` on those fails before any HTTP
/// request is made, which made web search look completely broken.
WebSearchLoader? webSearchLoader(
  SearchPageData data, {
  required String keyword,
  required int page,
  required String? next,
  required List<String> options,
}) {
  if (next != null && data.loadNext != null) {
    return () => data.loadNext!(keyword, next, options);
  }
  if (data.loadPage != null) {
    return () => data.loadPage!(keyword, page, options);
  }
  if (data.loadNext != null) {
    return () => data.loadNext!(keyword, null, options);
  }
  return null;
}

/// Owns the embedded HTTP server and binds it to the application's stores.
///
/// The runtime is a singleton so the settings page can rebind it immediately
/// after a preference changes, while bootstrap registers [closeAndWait] as the
/// single shutdown path.
class WebServiceRuntime {
  WebServiceRuntime._();

  static final WebServiceRuntime instance = WebServiceRuntime._();

  WebServer? _server;
  final _detailCache = <String, ({DateTime time, WebComicDetail detail})>{};

  static const _detailTtl = Duration(minutes: 5);
  static const _imageTimeout = Duration(seconds: 45);

  WebServer? get server => _server;

  bool get isRunning => _server?.isRunning ?? false;

  Future<void> start() => applySettings();

  Future<void> closeAndWait() async {
    final server = _server;
    if (server == null) return;
    await server.stop();
    _detailCache.clear();
  }

  WebServerConfig buildConfig() {
    final prefs = GlobalPreferenceStore(appdata.settings);
    final port = prefs.read(AppPreferences.webServicePort);
    return WebServerConfig(
      host: prefs.read(AppPreferences.webServiceLocalOnly)
          ? WebServerConfig.localhost
          : WebServerConfig.allInterfaces,
      port: port >= 1024 && port <= 65535 ? port : 8080,
      token: prefs.read(AppPreferences.webServiceToken).trim(),
      allowProgressWrite: prefs.read(
        AppPreferences.webServiceAllowProgressWrite,
      ),
    );
  }

  Future<void> applySettings() async {
    final enabled = GlobalPreferenceStore(
      appdata.settings,
    ).read(AppPreferences.webServiceEnabled);
    if (!enabled) {
      await closeAndWait();
      return;
    }
    final config = buildConfig();
    final server = _server;
    try {
      if (server == null) {
        final created = WebServer(
          api: WebApi(_buildDeps()),
          config: config,
          assetLoader: _loadAsset,
          onLog: (message) => Log.info('WebService', message),
        );
        _server = created;
        await created.start();
      } else {
        await server.reconfigure(config);
      }
    } catch (error, stack) {
      Log.error('WebService', 'Failed to start: $error', stack);
      final current = _server;
      _server = null;
      if (current != null) await current.stop();
    }
  }

  Future<Uint8List?> _loadAsset(String name) async {
    try {
      final data = await rootBundle.load(name);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (error, stack) {
      Log.error('WebService', 'Cannot load $name: $error', stack);
      return null;
    }
  }

  WebApiDeps _buildDeps() => WebApiDeps(
    sources: _sources,
    bookshelf: _bookshelf,
    search: _search,
    detail: detail,
    progress: progress,
    saveProgress: saveProgress,
    chapterImages: chapterImages,
    imageBytes: imageBytes,
    removeProgress: _removeProgress,
  );

  /// Komga clients can reset a book's read state; Venera tracks progress per
  /// comic, so this clears the single history row that owns that book.
  Future<void> _removeProgress(String source, String id) async {
    await HistoryManager().remove(id, ComicType.fromKey(source));
    _detailCache.remove('$source:$id');
  }

  // ---------------------------------------------------------------- sources

  Future<List<WebSourceInfo>> _sources() async {
    final result = <WebSourceInfo>[
      const WebSourceInfo(
        key: 'local',
        name: 'Local',
        searchable: true,
        local: true,
      ),
    ];
    for (final source in ComicSource.all()) {
      result.add(
        WebSourceInfo(
          key: source.key,
          name: source.name,
          searchable: source.searchPageData != null,
          local: false,
        ),
      );
    }
    return result;
  }

  // -------------------------------------------------------------- bookshelf

  Future<List<WebComicInfo>> _bookshelf() async {
    final histories = <String, History>{
      for (final history in HistoryManager().getAll())
        '${history.type.value}:${history.id}': history,
    };
    final local = LocalManager();
    final items = <WebComicInfo>[];
    for (final favorite in LocalFavoritesManager().allComics()) {
      final source = favorite.sourceKey;
      final history = histories[_historyKey(favorite.type, favorite.id)];
      String? cover;
      if (source == 'local') {
        final comic = local.find(favorite.id, ComicType.local);
        if (comic != null) {
          cover = webImageUrl(
            ref: comic.coverFile.path,
            kind: WebImageKind.file,
            cid: favorite.id,
          );
        }
      }
      cover ??= _coverUrl(favorite.coverPath, source, favorite.id);
      items.add(
        WebComicInfo(
          id: favorite.id,
          source: source,
          title: favorite.name,
          subtitle: favorite.author,
          cover: cover,
          tags: List.of(favorite.tags),
          favoriteAt: favorite.time,
          local: source == 'local',
          progress: _toProgress(history),
        ),
      );
    }
    items.sort((a, b) => (b.favoriteAt ?? '').compareTo(a.favoriteAt ?? ''));
    return items;
  }

  // ---------------------------------------------------------------- search

  Future<WebSearchPage> _search(
    String keyword,
    String source,
    int page,
    String? next,
  ) async {
    if (source == 'local') {
      final comics = LocalManager()
          .search(keyword)
          .map((e) => _localComicInfo(e))
          .toList();
      return WebSearchPage(
        comics: comics,
        source: source,
        page: page,
        maxPage: 1,
      );
    }

    final selected = GlobalPreferenceStore(
      appdata.settings,
    ).read(DiscoveryPreferences.searchSources);
    // An empty selection means "no preference yet", not "search nothing":
    // users who never opened the source picker still expect cross-source
    // search to work. The app's aggregated search applies the same fallback.
    final allowed = (selected == null || selected.isEmpty)
        ? null
        : selected.toSet();
    final targets = source == 'all'
        ? ComicSource.all()
              .where(
                (e) =>
                    e.searchPageData != null &&
                    (allowed == null || allowed.contains(e.key)),
              )
              .toList()
        : [ComicSource.find(source)].whereType<ComicSource>().toList();
    if (targets.isEmpty) {
      throw const WebApiNotFound('No searchable source matched');
    }

    // Sources run in parallel but a dead host must not hold the HTTP request
    // forever. Collect whatever answered before the deadline and tell the
    // client the result is partial so the web UI can say so.
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    final pending = targets.map((target) async {
        try {
          final data = target.searchPageData!;
          final options =
              data.searchOptions?.map((e) => e.defaultValue).toList() ??
              <String>[];
          final loader = webSearchLoader(
            data,
            keyword: keyword,
            page: page,
            next: next,
            options: options,
          );
          if (loader == null) {
            throw const WebApiUnsupported('Source has no search loader');
          }
          final res = await loader();
          res.throwIfError();
          final comics = res.data
              .where((e) => e.sourceKey.isNotEmpty)
              .map((e) => _comicInfo(e))
              .toList();
          final sub = res.subData;
          return _SourceSearchResult(
            comics: comics,
            maxPage: sub is int ? sub : null,
            next: sub is String ? sub : null,
          );
        } catch (error, stack) {
          // Cross-source search stays useful when one source is down.
          Log.error('WebService', 'Search ${target.key} failed: $error', stack);
          return const _SourceSearchResult(
            comics: [],
            maxPage: null,
            next: null,
          );
        }
      }).toList();

    final comics = <WebComicInfo>[];
    int? maxPage;
    String? cursor;
    var answered = 0;
    for (final future in pending) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      late final _SourceSearchResult result;
      try {
        result = await future.timeout(remaining);
      } on TimeoutException {
        break;
      }
      answered++;
      comics.addAll(result.comics);
      final resultMax = result.maxPage;
      if (resultMax != null && (maxPage == null || resultMax > maxPage)) {
        maxPage = resultMax;
      }
      cursor ??= result.next;
    }
    return WebSearchPage(
      comics: comics,
      source: source,
      page: page,
      maxPage: maxPage,
      next: cursor,
      partial: answered < targets.length,
    );
  }

  // ---------------------------------------------------------------- detail

  Future<WebComicDetail> detail(String source, String id) async {
    final key = '$source:$id';
    final cached = _detailCache[key];
    if (cached != null && DateTime.now().difference(cached.time) < _detailTtl) {
      return cached.detail;
    }
    final detail = source == 'local'
        ? _localDetail(id)
        : await _onlineDetail(source, id);
    if (_detailCache.length > 64) {
      final oldest = _detailCache.entries.reduce(
        (a, b) => a.value.time.isBefore(b.value.time) ? a : b,
      );
      _detailCache.remove(oldest.key);
    }
    _detailCache[key] = (time: DateTime.now(), detail: detail);
    return detail;
  }

  WebComicDetail _localDetail(String id) {
    final comic = LocalManager().find(id, ComicType.local);
    if (comic == null) {
      throw const WebApiNotFound('Local comic not found');
    }
    final info = _localComicInfo(comic);
    return WebComicDetail(
      comic: info.copyWith(
        progress: _toProgress(
          _history('local', id),
          chapters: comic.chapters,
        ),
      ),
      chapters: _chaptersOf(comic.chapters),
      groups: comic.chapters?.groups.toList() ?? const [],
      url: comic.directory,
    );
  }

  Future<WebComicDetail> _onlineDetail(String source, String id) async {
    final comicSource = ComicSource.find(source);
    if (comicSource == null || comicSource.loadComicInfo == null) {
      throw WebApiUnsupported('Source $source cannot load comic details');
    }
    final res = await comicSource.loadComicInfo!(id);
    res.throwIfError();
    final info = res.data;
    if (info.chapters != null) {
      _onlineChaptersCache['$source:$id'] = info.chapters!;
    }
    final tags = <String>[for (final entry in info.tags.values) ...entry];
    final comic = WebComicInfo(
      id: info.comicId.isEmpty ? id : info.comicId,
      source: source,
      title: info.title,
      subtitle: info.subTitle ?? '',
      cover: _coverUrl(info.cover, source, id),
      tags: tags,
      description: info.description,
      updateTime: info.updateTime,
      progress: _toProgress(_history(source, id), chapters: info.chapters),
      stars: info.stars,
    );
    return WebComicDetail(
      comic: comic,
      chapters: _chaptersOf(info.chapters),
      groups: info.chapters?.groups.toList() ?? const [],
      url: info.url,
      stars: info.stars,
      recommendations: (info.recommend ?? const [])
          .map((e) => _comicInfo(e))
          .toList(),
    );
  }

  List<WebChapterInfo> _chaptersOf(ComicChapters? chapters) {
    if (chapters == null || chapters.length == 0) return const [];
    final titles = chapters.titles.toList();
    final result = <WebChapterInfo>[];
    for (var index = 1; index <= chapters.length; index++) {
      final position = chapters.positionAt(index);
      result.add(
        WebChapterInfo(
          index: index,
          id: position.id,
          title: titles.elementAt(index - 1),
          group: position.group,
          groupTitle: position.group == null
              ? null
              : chapters.groups.elementAt(position.group! - 1),
        ),
      );
    }
    return result;
  }

  // --------------------------------------------------------------- progress

  Future<WebProgressInfo?> progress(String source, String id) async {
    final history = _history(source, id);
    return _toProgress(history);
  }

  Future<WebProgressInfo> saveProgress(
    String source,
    String id,
    WebProgressUpdate update,
  ) async {
    final type = ComicType.fromKey(source);
    var history = HistoryManager().find(id, type);
    final loaded = await detail(source, id);
    if (history == null) {
      final model = source == 'local'
          ? LocalManager().find(id, ComicType.local)
          : await _loadHistoryModel(source, id);
      if (model == null) {
        throw const WebApiNotFound('Comic not found');
      }
      history = History.fromModel(
        model: model,
        ep: update.group == null ? update.chapter : 1,
        page: update.page,
        group: update.group,
        time: DateTime.now(),
      );
    }

    final chapterIndex = update.chapter;
    if (chapterIndex > loaded.chapters.length) {
      throw const WebApiBadRequest('Chapter index out of range');
    }
    final position = loaded.chapters.isEmpty
        ? null
        : loaded.comic.local
        ? _positionOfLocal(id, chapterIndex)
        : _positionOfOnline(source, id, chapterIndex);

    history.ep = position?.chapter ?? chapterIndex;
    history.page = update.page;
    history.group = position?.group ?? update.group;
    history.chapterTitle =
        update.chapterTitle ??
        loaded.chapters.elementAt(chapterIndex - 1).title;
    history.groupTitle =
        update.groupTitle ??
        loaded.chapters.elementAt(chapterIndex - 1).groupTitle;
    history.maxChapter = position?.groupLength ?? loaded.chapters.length;
    history.readEpisode.add(
      position?.historyKey ??
          (history.group == null
              ? '$chapterIndex'
              : '${history.group}-$chapterIndex'),
    );
    history.time = DateTime.now();
    await HistoryManager().addHistory(history);
    return _toProgress(history)!;
  }

  Future<HistoryMixin?> _loadHistoryModel(String source, String id) async {
    final comicSource = ComicSource.find(source);
    if (comicSource?.loadComicInfo == null) return null;
    final res = await comicSource!.loadComicInfo!(id);
    res.throwIfError();
    return res.data;
  }

  ComicChapterPosition? _positionOfLocal(String id, int chapter) {
    final comic = LocalManager().find(id, ComicType.local);
    final chapters = comic?.chapters;
    if (chapters == null || chapter > chapters.length) return null;
    return chapters.positionAt(chapter);
  }

  ComicChapterPosition? _positionOfOnline(
    String source,
    String id,
    int chapter,
  ) {
    // Detail is cached by [detail], so this does not issue a second request.
    final comicSource = ComicSource.find(source);
    final sourceChapters = _onlineChaptersCache['$source:$id'];
    if (comicSource == null || sourceChapters == null) return null;
    if (chapter > sourceChapters.length) return null;
    return sourceChapters.positionAt(chapter);
  }

  final _onlineChaptersCache = <String, ComicChapters>{};

  /// Converts a history row into wire progress.
  ///
  /// [History.ep] is a chapter number *inside its group* for grouped sources,
  /// while every `/api/chapter/...` route uses the flattened index. When the
  /// chapter list is available (detail views) the group-local value is mapped
  /// back to the flattened index so the reader and the chapter list agree.
  WebProgressInfo? _toProgress(History? history, {ComicChapters? chapters}) {
    if (history == null) return null;
    var chapter = history.ep;
    if (chapters != null && history.group != null) {
      chapter = _flatIndexOf(chapters, history) ?? history.ep;
    }
    return WebProgressInfo(
      chapter: chapter,
      page: history.page,
      group: history.group,
      chapterTitle: history.chapterTitle,
      groupTitle: history.groupTitle,
      maxChapter: history.maxChapter,
      maxPage: history.maxPage,
      readChapters: history.readEpisode.toList()..sort(),
      updatedAt: history.time.toIso8601String(),
    );
  }

  int? _flatIndexOf(ComicChapters chapters, History history) {
    for (var index = 1; index <= chapters.length; index++) {
      final position = chapters.positionAt(index);
      if (position.group == history.group && position.chapter == history.ep) {
        return index;
      }
    }
    return null;
  }

  // --------------------------------------------------------------- chapter

  Future<WebChapterImages> chapterImages(
    String source,
    String id,
    int chapter,
  ) async {
    final loaded = await detail(source, id);
    if (chapter < 1 || chapter > loaded.chapters.length) {
      throw const WebApiBadRequest('Chapter index out of range');
    }
    final target = loaded.chapters.elementAt(chapter - 1);
    if (source == 'local') {
      final comic = LocalManager().find(id, ComicType.local);
      if (comic == null) {
        throw const WebApiNotFound('Local comic not found');
      }
      final pages = await LocalManager().getImages(
        id,
        comic.comicType,
        target.id,
      );
      final images = <String>[
        for (final page in pages)
          if (!page.startsWith(missingDownloadPagePrefix))
            _pageUrl(page, source: source, cid: id, eid: target.id),
      ];
      return WebChapterImages(
        chapter: chapter,
        chapterId: target.id,
        images: images,
        title: target.title,
      );
    }

    final comicSource = ComicSource.find(source);
    if (comicSource?.loadComicPages == null) {
      throw WebApiUnsupported('Source $source cannot load chapter images');
    }
    final res = await comicSource!.loadComicPages!(id, target.id);
    res.throwIfError();
    final images = res.data
        .map((e) => _pageUrl(e, source: source, cid: id, eid: target.id))
        .toList();
    return WebChapterImages(
      chapter: chapter,
      chapterId: target.id,
      images: images,
      title: target.title,
    );
  }

  // ---------------------------------------------------------------- images

  Future<Uint8List?> imageBytes(WebImageRequest request) async {
    if (request.kind == WebImageKind.file) return _readFile(request.ref);
    if (request.ref.startsWith('file://')) return _readFile(request.ref);
    return _sourceImage(request);
  }

  Future<Uint8List?> _sourceImage(WebImageRequest request) async {
    final scope = RequestScope(timeout: _imageTimeout);
    try {
      final stream = request.kind == WebImageKind.cover
          ? ImageDownloader.loadThumbnail(
              request.ref,
              request.source,
              request.cid,
            )
          : ImageDownloader.loadComicImage(
              request.ref,
              request.source,
              request.cid ?? '',
              request.eid ?? '',
            );
      return await readImageStream(
        stream,
        cancelSignal: scope.whenCancelled,
        checkStop: scope.check,
      );
    } finally {
      scope.cancel();
      scope.dispose();
    }
  }

  Future<Uint8List?> _readFile(String ref) async {
    final raw = ref.startsWith('file://') ? ref.substring(7) : ref;
    if (raw.isEmpty || !p.isAbsolute(raw)) return null;
    try {
      final file = File(p.canonicalize(raw));
      if (!_isAllowedPath(file.path)) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Never expose arbitrary files through the LAN API. Only the app data
  /// directory (favorite covers) and the local comic library are readable.
  bool _isAllowedPath(String filePath) {
    String normalize(String value) {
      final canonical = p.canonicalize(value);
      return Platform.isWindows ? canonical.toLowerCase() : canonical;
    }

    final target = normalize(filePath);
    final roots = <String>[normalize(App.dataPath)];
    try {
      roots.add(normalize(LocalManager().path));
    } catch (_) {
      // Local library may not be initialized yet.
    }
    for (final root in roots) {
      if (target == root || target.startsWith(root + p.separator)) {
        return true;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------- helpers

  static String _historyKey(ComicType type, String id) => '${type.value}:$id';

  History? _history(String source, String id) =>
      HistoryManager().find(id, ComicType.fromKey(source));

  String? _coverUrl(String ref, String source, String cid) {
    if (ref.isEmpty) return null;
    if (ref.startsWith('http://') || ref.startsWith('https://')) {
      return webImageUrl(
        ref: ref,
        kind: WebImageKind.cover,
        source: source,
        cid: cid,
      );
    }
    if (ref.startsWith('file://') || p.isAbsolute(ref)) {
      return webImageUrl(ref: ref, kind: WebImageKind.file, cid: cid);
    }
    // Relative covers belong to a local comic directory.
    final comic = LocalManager().find(cid, ComicType.local);
    if (comic == null) return null;
    return webImageUrl(
      ref: comic.coverFile.path,
      kind: WebImageKind.file,
      cid: cid,
    );
  }

  String _pageUrl(
    String ref, {
    required String source,
    required String cid,
    required String eid,
  }) {
    if (ref.startsWith('file://')) {
      return webImageUrl(ref: ref, kind: WebImageKind.file, cid: cid);
    }
    return webImageUrl(
      ref: ref,
      kind: WebImageKind.page,
      source: source,
      cid: cid,
      eid: eid,
    );
  }

  WebComicInfo _comicInfo(Comic comic) => WebComicInfo(
    id: comic.id,
    source: comic.sourceKey,
    title: comic.title,
    subtitle: comic.subtitle ?? '',
    cover: _coverUrl(comic.cover, comic.sourceKey, comic.id),
    tags: List.of(comic.tags ?? []),
    description: comic.description,
  );

  WebComicInfo _localComicInfo(LocalComic comic) => WebComicInfo(
    id: comic.id,
    source: 'local',
    title: comic.title,
    subtitle: comic.subtitle,
    cover: webImageUrl(
      ref: comic.coverFile.path,
      kind: WebImageKind.file,
      cid: comic.id,
    ),
    tags: List.of(comic.tags),
    local: true,
    progress: _toProgress(_history('local', comic.id)),
  );
}

class _SourceSearchResult {
  const _SourceSearchResult({
    required this.comics,
    required this.maxPage,
    required this.next,
  });

  final List<WebComicInfo> comics;
  final int? maxPage;
  final String? next;
}
