import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/features/comic_source/models.dart';

/// A stale-while-revalidate cache for comic details and their chapter list.
///
/// Opening a comic page shows the last known details immediately (so the user
/// can start reading without waiting for the network) while a background
/// refresh updates the entry. The chapter list lives inside [ComicDetails], so
/// caching details also caches the table of contents.
///
/// Memory is the fast path; a compact disk snapshot survives app restarts.
/// Entries are untrusted input from a previous run, so every read validates
/// the decoded shape and drops malformed snapshots.
class ComicDetailsCache {
  ComicDetailsCache._();

  static final ComicDetailsCache instance = ComicDetailsCache._();

  /// Enough for a long browsing session without holding every comic visited.
  static const _maxMemoryEntries = 32;

  final LinkedHashMap<String, ComicDetails> _memory =
      LinkedHashMap<String, ComicDetails>();

  String key(String sourceKey, String id) => '$sourceKey\u0000$id';

  ComicDetails? peek(String sourceKey, String id) =>
      _memory[key(sourceKey, id)];

  /// Read through memory and then the disk snapshot.
  Future<ComicDetails?> read(String sourceKey, String id) async {
    final k = key(sourceKey, id);
    final cached = _memory.remove(k);
    if (cached != null) {
      _memory[k] = cached;
      return cached;
    }
    final restored = await _readDisk(sourceKey, id);
    if (restored != null) {
      _memory[k] = restored;
      _trim();
    }
    return restored;
  }

  /// Write through memory and disk. Memory is updated synchronously so the UI
  /// sees the entry immediately; the returned future tracks disk persistence
  /// (callers that must not wait should wrap it in `unawaited`). All IO errors
  /// are swallowed so caching can never break a page load.
  Future<void> write(String sourceKey, String id, ComicDetails details) {
    final k = key(sourceKey, id);
    _memory.remove(k);
    _memory[k] = details;
    _trim();
    return _writeDisk(sourceKey, id, details);
  }

  Future<void> invalidate(String sourceKey, String id) async {
    _memory.remove(key(sourceKey, id));
    await _deleteFile(sourceKey, id);
  }

  /// Drop every cached comic of one source.
  ///
  /// Switching a mirror changes the host baked into cached cover and page URLs,
  /// so keeping the entries would leave the user with covers that point at a
  /// host they just replaced.
  Future<void> invalidateSource(String sourceKey) async {
    final prefix = '$sourceKey\u0000';
    for (final k in _memory.keys.toList()) {
      if (k.startsWith(prefix)) _memory.remove(k);
    }
    try {
      final dir = _sourceDir(sourceKey);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (error, stack) {
      Log.error('ComicDetailsCache', error, stack);
    }
  }

  void _trim() {
    while (_memory.length > _maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  Directory _sourceDir(String sourceKey) => Directory(
    FilePath.join(
      App.dataPath,
      'comic_details_cache',
      md5.convert(utf8.encode(sourceKey)).toString(),
    ),
  );

  File _file(String sourceKey, String id) => File(
    FilePath.join(
      _sourceDir(sourceKey).path,
      md5.convert(utf8.encode(id)).toString(),
    ),
  );

  Future<void> _deleteFile(String sourceKey, String id) async {
    try {
      final file = _file(sourceKey, id);
      if (await file.exists()) await file.delete();
    } catch (error, stack) {
      Log.error('ComicDetailsCache', error, stack);
    }
  }

  Future<ComicDetails?> _readDisk(String sourceKey, String id) async {
    try {
      final file = _file(sourceKey, id);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return ComicDetails.fromJson(decoded);
    } catch (error, stack) {
      Log.error('ComicDetailsCache', error, stack);
      return null;
    }
  }

  Future<void> _writeDisk(
    String sourceKey,
    String id,
    ComicDetails details,
  ) async {
    try {
      final json = details.toJson();
      // Upstream fromJson reads "subtitle" while toJson emits "subTitle";
      // mirror both so a restored snapshot keeps its subtitle.
      json['subtitle'] = json['subTitle'];
      json['maxPage'] = details.maxPage;
      final file = _file(sourceKey, id);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(json), flush: false);
    } catch (error, stack) {
      Log.error('ComicDetailsCache', error, stack);
    }
  }
}
