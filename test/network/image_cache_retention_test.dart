import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/cache_scan.dart';
import 'package:venera_next/network/images.dart';

const _timeout = Timeout(Duration(seconds: 120));

void main() {
  late Directory directory;
  late CacheManager cache;
  CacheManager? previous;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('venera-img-retention-');
    previous = CacheManager.instance;
    cache = CacheManager.open(
      dataPath: directory.path,
      cacheRoot: directory.path,
      scanner: (_, _) async => const CacheScanResult(0, []),
    );
    CacheManager.instance = cache;
  });

  tearDown(() async {
    ImageDownloader.cancelAllLoadingImages();
    ImageDownloader.configureImageRetention(null);
    CacheManager.instance = previous;
    await cache.dispose();
    directory.deleteSync(recursive: true);
  });

  test('normalizeImageIdentity drops volatile params but keeps identity', () {
    expect(
      ImageDownloader.normalizeImageIdentity(
        'https://cdn.example.com/a/b/1.jpg?token=abc&t=123#x',
      ),
      'https://cdn.example.com/a/b/1.jpg',
    );
    // Identity-bearing params are preserved, so pages never collide.
    expect(
      ImageDownloader.normalizeImageIdentity(
        'https://cdn.example.com/img?id=42&page=3&sign=xyz',
      ),
      'https://cdn.example.com/img?id=42&page=3',
    );
    // No query: unchanged.
    expect(
      ImageDownloader.normalizeImageIdentity('https://cdn.example.com/1.jpg'),
      'https://cdn.example.com/1.jpg',
    );
  });

  test('stable cache key ignores the changing token', () {
    final a = ImageDownloader.readerCacheKey(
      'https://cdn.example.com/1.jpg?token=abc',
      'src',
      'comic',
      'ep',
    );
    final b = ImageDownloader.readerCacheKey(
      'https://cdn.example.com/1.jpg?token=xyz&t=999',
      'src',
      'comic',
      'ep',
    );
    expect(a, b);

    // Different identity params must not collide.
    final page1 = ImageDownloader.readerCacheKey(
      'https://cdn.example.com/img?id=42&page=1&token=x',
      'src', 'comic', 'ep',
    );
    final page2 = ImageDownloader.readerCacheKey(
      'https://cdn.example.com/img?id=42&page=2&token=x',
      'src', 'comic', 'ep',
    );
    expect(page1, isNot(page2));
  });

  test('reader page hits cache written under a different token', () async {
    // Simulate an older token by writing under its stable key.
    await cache.writeCache(
      ImageDownloader.readerCacheKey(
        'https://cdn.example.com/1.jpg?token=old',
        'src',
        'comic',
        'ep',
      ),
      [1, 2, 3],
    );
    ImageDownloader.configureSourceImageLoading(
      comicImageLoadingConfig: (_, _, _, _) async {
        throw StateError('Cache hit must not resolve a source');
      },
    );
    final events = await ImageDownloader.loadComicImage(
      'https://cdn.example.com/1.jpg?token=new',
      'src',
      'comic',
      'ep',
      stableCacheKey: true,
    ).toList();
    expect(events.single.imageBytes, [1, 2, 3]);
  }, timeout: _timeout);

  test('legacy raw-url cache is still readable after upgrade', () async {
    await cache.writeCache('https://cdn.example.com/1.jpg?token=old@src@comic@ep', [
      4,
      5,
    ]);
    ImageDownloader.configureSourceImageLoading(
      comicImageLoadingConfig: (_, _, _, _) async {
        throw StateError('Cache hit must not resolve a source');
      },
    );
    final events = await ImageDownloader.loadComicImage(
      'https://cdn.example.com/1.jpg?token=old',
      'src',
      'comic',
      'ep',
      stableCacheKey: true,
    ).toList();
    expect(events.single.imageBytes, [4, 5]);
  }, timeout: _timeout);

  test('retention resolver picks persistent for shelf, temporary otherwise', () {
    ImageDownloader.configureImageRetention((cid, sourceKey) => cid == 'shelf');
    final shelf = ImageDownloader.retentionFor('src', 'shelf');
    expect(shelf.persistent, isTrue);
    expect(shelf.type, CacheManager.persistentType);

    final temp = ImageDownloader.retentionFor('src', 'browse-only');
    expect(temp.persistent, isFalse);
    expect(temp.duration, CacheManager.temporaryDuration);
    expect(temp.type, CacheManager.temporaryType);

    final noResolver = ImageDownloader.retentionFor('src', 'x');
    expect(noResolver.persistent, isFalse);
  });
}
