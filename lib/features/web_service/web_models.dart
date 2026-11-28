/// Wire models shared by the embedded web reader HTTP API.
///
/// These types are deliberately independent of Flutter widgets and of the
/// application's database rows so the HTTP layer can be unit tested with fake
/// data providers.
library;

import 'dart:typed_data';

/// How an image reference is resolved by `/api/image`.
enum WebImageKind { cover, page, file }

/// Build the relative URL the web client uses to fetch an image.
///
/// Keeping this as a helper guarantees that the JSON emitted by the API uses
/// exactly the same encoding as the routes served by [WebServer].
String webImageUrl({
  required String ref,
  required WebImageKind kind,
  String? source,
  String? cid,
  String? eid,
}) {
  final query = <String, String>{
    'ref': ref,
    'kind': kind.name,
    if (source != null && source.isNotEmpty) 'source': source,
    if (cid != null && cid.isNotEmpty) 'cid': cid,
    if (eid != null && eid.isNotEmpty) 'eid': eid,
  };
  final encoded = query.entries
      .map(
        (e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
      )
      .join('&');
  return '/api/image?$encoded';
}

class WebSourceInfo {
  const WebSourceInfo({
    required this.key,
    required this.name,
    required this.searchable,
    required this.local,
  });

  final String key;
  final String name;
  final bool searchable;
  final bool local;

  Map<String, Object?> toJson() => {
    'key': key,
    'name': name,
    'searchable': searchable,
    'local': local,
  };
}

class WebProgressInfo {
  const WebProgressInfo({
    required this.chapter,
    required this.page,
    this.group,
    this.chapterTitle,
    this.groupTitle,
    this.maxChapter,
    this.maxPage,
    this.readChapters = const [],
    this.updatedAt,
  });

  /// One-based flattened chapter index.
  final int chapter;

  /// One-based page index inside the chapter.
  final int page;
  final int? group;
  final String? chapterTitle;
  final String? groupTitle;
  final int? maxChapter;
  final int? maxPage;
  final List<String> readChapters;
  final String? updatedAt;

  Map<String, Object?> toJson() => {
    'chapter': chapter,
    'page': page,
    'group': group,
    'chapterTitle': chapterTitle,
    'groupTitle': groupTitle,
    'maxChapter': maxChapter,
    'maxPage': maxPage,
    'readChapters': readChapters,
    'updatedAt': updatedAt,
  };
}

class WebComicInfo {
  const WebComicInfo({
    required this.id,
    required this.source,
    required this.title,
    this.cover,
    this.subtitle = '',
    this.tags = const [],
    this.description,
    this.updateTime,
    this.favoriteAt,
    this.progress,
    this.local = false,
    this.stars,
  });

  final String id;
  final String source;
  final String title;
  final String subtitle;

  /// Relative URL pointing at `/api/image`, or null when no cover exists.
  final String? cover;
  final List<String> tags;
  final String? description;
  final String? updateTime;
  final String? favoriteAt;
  final WebProgressInfo? progress;
  final bool local;
  final double? stars;

  String get key => '$source:$id';

  WebComicInfo copyWith({WebProgressInfo? progress}) => WebComicInfo(
    id: id,
    source: source,
    title: title,
    subtitle: subtitle,
    cover: cover,
    tags: tags,
    description: description,
    updateTime: updateTime,
    favoriteAt: favoriteAt,
    progress: progress ?? this.progress,
    local: local,
    stars: stars,
  );

  Map<String, Object?> toJson() => {
    'key': key,
    'id': id,
    'source': source,
    'title': title,
    'subtitle': subtitle,
    'cover': cover,
    'tags': tags,
    'description': description,
    'updateTime': updateTime,
    'favoriteAt': favoriteAt,
    'local': local,
    'stars': stars,
    'progress': progress?.toJson(),
  };
}

class WebChapterInfo {
  const WebChapterInfo({
    required this.index,
    required this.id,
    required this.title,
    this.group,
    this.groupTitle,
  });

  /// One-based flattened index used by `/api/chapter/.../{index}`.
  final int index;
  final String id;
  final String title;
  final int? group;
  final String? groupTitle;

  Map<String, Object?> toJson() => {
    'index': index,
    'id': id,
    'title': title,
    'group': group,
    'groupTitle': groupTitle,
  };
}

class WebComicDetail {
  const WebComicDetail({
    required this.comic,
    required this.chapters,
    this.groups = const [],
    this.url,
    this.stars,
    this.recommendations = const [],
  });

  final WebComicInfo comic;
  final List<WebChapterInfo> chapters;

  /// Display order of grouped chapter titles, when the source uses groups.
  final List<String> groups;
  final String? url;
  final double? stars;
  final List<WebComicInfo> recommendations;

  Map<String, Object?> toJson() => {
    ...comic.toJson(),
    'chapters': chapters.map((e) => e.toJson()).toList(),
    'groups': groups,
    'url': url,
    'stars': stars,
    'recommendations': recommendations.map((e) => e.toJson()).toList(),
  };
}

class WebSearchPage {
  const WebSearchPage({
    required this.comics,
    required this.source,
    this.page = 1,
    this.maxPage,
    this.next,
    this.partial = false,
  });

  final List<WebComicInfo> comics;
  final String source;
  final int page;
  final int? maxPage;

  /// Opaque cursor used by sources that do not support numeric pages.
  final String? next;

  /// Some cross-source targets did not answer before the deadline.
  final bool partial;

  Map<String, Object?> toJson() => {
    'comics': comics.map((e) => e.toJson()).toList(),
    'source': source,
    'page': page,
    'maxPage': maxPage,
    'next': next,
    'partial': partial,
    'hasMore': next != null || (maxPage != null && page < maxPage!),
  };
}

class WebChapterImages {
  const WebChapterImages({
    required this.chapter,
    required this.chapterId,
    required this.images,
    this.title,
  });

  final int chapter;
  final String chapterId;
  final List<String> images;
  final String? title;

  Map<String, Object?> toJson() => {
    'chapter': chapter,
    'chapterId': chapterId,
    'images': images,
    'title': title,
    'count': images.length,
  };
}

class WebProgressUpdate {
  const WebProgressUpdate({
    required this.chapter,
    required this.page,
    this.group,
    this.chapterTitle,
    this.groupTitle,
  });

  final int chapter;
  final int page;
  final int? group;
  final String? chapterTitle;
  final String? groupTitle;

  factory WebProgressUpdate.fromJson(Map<String, Object?> json) {
    return WebProgressUpdate(
      chapter: _requirePositiveInt(json['chapter'], 'chapter'),
      page: _requirePositiveInt(json['page'], 'page'),
      group: _optionalPositiveInt(json['group']),
      chapterTitle: json['chapterTitle'] as String?,
      groupTitle: json['groupTitle'] as String?,
    );
  }
}

int _requirePositiveInt(Object? value, String name) {
  if (value is int && value > 0) return value;
  if (value is num && value > 0 && value == value.roundToDouble()) {
    return value.round();
  }
  throw ArgumentError.value(value, name, 'must be a positive integer');
}

int? _optionalPositiveInt(Object? value) {
  if (value == null) return null;
  return _requirePositiveInt(value, 'group');
}

/// Sniff an image media type from its magic bytes.
///
/// Shared by the JSON image proxy, the OPDS-PSE page endpoint and the Komga
/// thumbnails so every protocol reports the same type for the same bytes.
String detectImageType(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'image/gif';
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
    return 'image/webp';
  }
  return 'application/octet-stream';
}
