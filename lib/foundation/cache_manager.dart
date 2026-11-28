import 'cache_scan.dart';
import 'log.dart';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';

import 'app.dart';

class CacheManager {
  static CacheManager? instance;

  /// Default disk retention for an ordinary cache entry.
  static const defaultDuration = 7 * 24 * 60 * 60 * 1000;

  /// Short retention for images browsed outside the bookshelf.
  static const temporaryDuration = 24 * 60 * 60 * 1000;

  /// Written to the `type` column for pages of comics kept in the bookshelf.
  /// Persistent entries never expire and are excluded from capacity eviction,
  /// so re-opening a shelved comic always reads from disk (even offline).
  static const String persistentType = 'persistent';

  /// Written to the `type` column for reader pages of comics not on the shelf.
  /// These slide their TTL by [temporaryDuration] on each hit.
  static const String temporaryType = 'temporary';

  /// The compatibility singleton resolves paths once; owned instances can use
  /// independent directories and scanners without global test overrides.
  factory CacheManager() => instance ??= CacheManager.open(
    dataPath: App.dataPath,
    cacheRoot: App.cachePath,
  );

  late final Database _db;
  final String _dbPath;
  final String _cachePath;
  final CacheScanner _scan;
  Future<void> _operations = Future.value();
  Future<void>? _initialScanTask;
  Future<void>? _disposal;
  bool _closing = false;
  bool get isClosing => _closing;
  int _currentSize = 0;
  int get currentSize => _currentSize;
  int _directoryIndex = 0;
  int _limitSize = 2 * 1024 * 1024 * 1024;

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    if (_closing) return Future.error(StateError('CacheManager is closing'));
    final next = _operations.then((_) => operation());
    _operations = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  /// Start one initial scan. Later operations are ordered after it.
  Future<void> start() {
    if (_closing) return Future.error(StateError('CacheManager is closing'));
    return _initialScanTask ??= _enqueue(_runInitialScan);
  }

  /// Finish accepted operations before closing SQLite. No new work is accepted.
  Future<void> dispose() {
    _closing = true;
    return _disposal ??= _operations.then((_) {
      _db.dispose();
      // Do not reopen the singleton while accepted writes are still draining.
      if (identical(instance, this)) instance = null;
    });
  }

  CacheManager.open({
    required String dataPath,
    required String cacheRoot,
    CacheScanner scanner = scanCacheDirectory,
    Database Function(String)? openDatabase,
  }) : _dbPath = '$dataPath/cache.db',
       _cachePath = '$cacheRoot/cache',
       _scan = scanner {
    Directory(_cachePath).createSync(recursive: true);
    // The manager owns the returned connection, even if schema setup fails.
    final database = (openDatabase ?? openSqliteDatabase)(_dbPath);
    try {
      database.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL,
        type TEXT
      )
      ''');
      _db = database;
    } catch (_) {
      database.dispose();
      rethrow;
    }
  }

  Future<void> _runInitialScan() async {
    try {
      final result = await _scan(_dbPath, _cachePath);
      _currentSize = result.totalSize;
      for (final path in result.unmanagedFiles) {
        final file = File(path);
        final segments = file.uri.pathSegments;
        final name = segments.last;
        final directory = segments.elementAtOrNull(segments.length - 2) ?? '*';
        // Recheck ownership before deleting a file reported by the scan.
        if (_db.select('SELECT key FROM cache WHERE dir = ? AND name = ?', [
          directory,
          name,
        ]).isNotEmpty) {
          continue;
        }
        if (await file.exists()) await file.delete();
      }
      await _checkCache();
    } catch (error, stack) {
      // Preserve the size tracked by accepted writes when scanning fails.
      Log.error('Cache scan', error, stack);
    }
  }

  /// set cache size limit in MB
  void setLimitSize(int size) {
    if (_closing) throw StateError('CacheManager is closing');
    _limitSize = size * 1024 * 1024;
  }

  /// Write cache to disk with the default tier.
  Future<void> writeCache(
    String key,
    List<int> data, [
    int duration = defaultDuration,
  ]) {
    return _enqueue(() => _writeCache(key, Uint8List.fromList(data), duration, null));
  }

  /// Write cache to disk with an explicit retention tier.
  ///
  /// Used by reader pages: [persistent] pages (bookshelf) never expire and
  /// survive capacity cleanup; [temporary] pages slide a one-day TTL. [type]
  /// is stored verbatim in the `type` column.
  Future<void> writeCacheTyped(
    String key,
    List<int> data, {
    required int duration,
    String? type,
  }) {
    return _enqueue(
      () => _writeCache(key, Uint8List.fromList(data), duration, type),
    );
  }

  /// Resolve the sliding TTL for an existing entry from its tier.
  int _slideDuration(String? type) => switch (type) {
    persistentType => defaultDuration,
    temporaryType => temporaryDuration,
    _ => defaultDuration,
  };

  Future<void> _writeCache(
    String key,
    List<int> data,
    int duration,
    String? type,
  ) async {
    await _delete(key);
    _directoryIndex = (_directoryIndex + 1) % 100;
    final dir = _directoryIndex;
    var name = md5.convert(key.codeUnits).toString();
    var file = File('$_cachePath/$dir/$name');
    await file.create(recursive: true);
    await file.writeAsBytes(data);
    // Persistent entries use a far-future expiry as a safety net; expiry is
    // skipped for them in [_findCache] anyway.
    final expires = type == persistentType
        ? DateTime.now().millisecondsSinceEpoch + defaultDuration
        : DateTime.now().millisecondsSinceEpoch + duration;
    _db.execute(
      '''
      INSERT OR REPLACE INTO cache (key, dir, name, expires, type) VALUES (?, ?, ?, ?, ?)
    ''',
      [key, dir.toString(), name, expires, type],
    );
    _currentSize += data.length;
    if (_currentSize > _limitSize) await _checkCache();
  }

  /// Find cache by key.
  /// If cache is expired, it will be deleted and return null.
  /// If cache is not found, it will return null.
  /// If cache is found, it will return the file, and update the expires time.
  Future<File?> findCache(String key) => _enqueue(() => _findCache(key));

  Future<File?> _findCache(String key) async {
    var res = _db.select(
      '''
      SELECT * FROM cache
      WHERE key = ?
    ''',
      [key],
    );
    if (res.isEmpty) {
      return null;
    }
    var row = res.first;
    var dir = row['dir'] as String;
    var name = row['name'] as String;
    var expires = row['expires'] as int;
    final isPersistent = row['type'] == persistentType;
    var file = File('$_cachePath/$dir/$name');
    var now = DateTime.now().millisecondsSinceEpoch;
    if (!isPersistent && expires < now) {
      // expired
      _db.execute(
        '''
        DELETE FROM cache
        WHERE key = ?
      ''',
        [key],
      );
      if (await file.exists()) {
        await file.delete();
      }
      return null;
    }
    if (await file.exists()) {
      if (!isPersistent) {
        // Slide the TTL only for ordinary entries; bookshelf pages are stable.
        var refreshed = now + _slideDuration(row['type'] as String?);
        _db.execute(
          '''
          UPDATE cache
          SET expires = ?
          WHERE key = ?
        ''',
          [refreshed, key],
        );
      }
      return file;
    } else {
      _db.execute(
        '''
        DELETE FROM cache
        WHERE key = ?
      ''',
        [key],
      );
    }
    return null;
  }

  /// Check cache size and delete expired cache.
  /// If current size is greater than limit size,
  /// delete cache until current size is less than limit size.
  Future<void> checkCache() => _enqueue(_checkCache);

  Future<void> _checkCache() async {
    var res = _db.select(
      '''
        SELECT * FROM cache
        WHERE expires < ? AND (type IS NULL OR type != ?)
      ''',
      [DateTime.now().millisecondsSinceEpoch, persistentType],
    );
    for (var row in res) {
      var dir = row['dir'] as String;
      var name = row['name'] as String;
      var file = File('$_cachePath/$dir/$name');
      if (await file.exists()) {
        var size = await file.length();
        _currentSize = _currentSize - size;
        await file.delete();
      }
    }
    if (res.isNotEmpty) {
      _db.execute(
        '''
        DELETE FROM cache
        WHERE expires < ? AND (type IS NULL OR type != ?)
      ''',
        [DateTime.now().millisecondsSinceEpoch, persistentType],
      );
    }

    while (_currentSize > _limitSize) {
      // Only evict non-persistent entries. Bookshelf pages stay on disk even
      // when the ordinary cache is over budget.
      var res = _db.select('''
          SELECT * FROM cache
          WHERE type IS NULL OR type != ?
          ORDER BY expires ASC
          limit 10
        ''', [persistentType]);
      if (res.isEmpty) {
        // Nothing evictable. Do not wipe the directory: that would destroy
        // persistent bookshelf pages. Over-budget non-persistent leftovers are
        // harmless; a later write will retry eviction.
        break;
      }
      for (var row in res) {
        var key = row['key'] as String;
        var dir = row['dir'] as String;
        var name = row['name'] as String;
        var file = File('$_cachePath/$dir/$name');
        if (await file.exists()) {
          var size = await file.length();
          await file.delete();
          _db.execute(
            '''
              DELETE FROM cache
              WHERE key = ?
            ''',
            [key],
          );
          _currentSize = _currentSize - size;
          if (_currentSize <= _limitSize) {
            break;
          }
        } else {
          _db.execute(
            '''
              DELETE FROM cache
              WHERE key = ?
            ''',
            [key],
          );
        }
      }
    }
  }

  /// Delete cache by key.
  Future<void> delete(String key) => _enqueue(() => _delete(key));

  Future<void> _delete(String key) async {
    var res = _db.select(
      '''
      SELECT * FROM cache
      WHERE key = ?
    ''',
      [key],
    );
    if (res.isEmpty) {
      return;
    }
    var row = res.first;
    var dir = row['dir'] as String;
    var name = row['name'] as String;
    var file = File('$_cachePath/$dir/$name');
    var fileSize = 0;
    if (await file.exists()) {
      fileSize = await file.length();
      await file.delete();
    }
    _db.execute(
      '''
      DELETE FROM cache
      WHERE key = ?
    ''',
      [key],
    );
    _currentSize -= fileSize;
  }

  /// Delete all cache.
  Future<void> clear() => _enqueue(_clear);

  Future<void> _clear() async {
    await Directory(_cachePath).delete(recursive: true);
    Directory(_cachePath).createSync(recursive: true);
    _db.execute('''
      DELETE FROM cache
    ''');
    _currentSize = 0;
  }
}
