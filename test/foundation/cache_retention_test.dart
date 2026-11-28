import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/cache_scan.dart';

const _timeout = Timeout(Duration(seconds: 120));

({CacheManager manager, Directory root}) fixture() {
  final root = Directory.systemTemp.createTempSync('venera-retention-');
  final manager = CacheManager.open(
    dataPath: root.path,
    cacheRoot: root.path,
    // No start() in these tests, so a fake scanner avoids spawning an isolate
    // on an already loaded machine.
    scanner: (_, _) async => const CacheScanResult(0, []),
  );
  addTearDown(() async {
    await manager.dispose();
    if (root.existsSync()) await root.delete(recursive: true);
  });
  return (manager: manager, root: root);
}

void main() {
  test('persistent entries survive expiry sweep', () async {
    final f = fixture();
    await f.manager.writeCacheTyped(
      'shelf-page',
      [1, 2, 3],
      duration: CacheManager.defaultDuration,
      type: CacheManager.persistentType,
    );
    await f.manager.writeCache('normal-page', [4, 5], -1000);
    await f.manager.checkCache();

    expect(await f.manager.findCache('normal-page'), isNull);
    expect(
      await (await f.manager.findCache('shelf-page'))!.readAsBytes(),
      [1, 2, 3],
    );
  }, timeout: _timeout);

  test('persistent entries are excluded from capacity eviction', () async {
    final f = fixture();
    await f.manager.writeCacheTyped(
      'shelf',
      [1, 2, 3, 4],
      duration: CacheManager.defaultDuration,
      type: CacheManager.persistentType,
    );
    await f.manager.writeCache('temp', [5, 6]);

    f.manager.setLimitSize(0);
    await f.manager.checkCache();

    expect(await f.manager.findCache('temp'), isNull);
    expect(
      await (await f.manager.findCache('shelf'))!.readAsBytes(),
      [1, 2, 3, 4],
    );
  }, timeout: _timeout);

  test('temporary tier is written and read with its short duration', () async {
    final f = fixture();
    await f.manager.writeCacheTyped(
      'temp-page',
      [7, 8],
      duration: CacheManager.temporaryDuration,
      type: CacheManager.temporaryType,
    );
    expect(
      await (await f.manager.findCache('temp-page'))!.readAsBytes(),
      [7, 8],
    );
  }, timeout: _timeout);

  test('temporary entry expires with a short TTL', () async {
    final f = fixture();
    await f.manager.writeCacheTyped(
      'stale',
      [9],
      duration: -1000,
      type: CacheManager.temporaryType,
    );
    await f.manager.checkCache();
    expect(await f.manager.findCache('stale'), isNull);
  }, timeout: _timeout);
}
