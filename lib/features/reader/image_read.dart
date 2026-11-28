import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/network/images.dart';
import 'image_position.dart';

/// Reads the original address and keeps the accepted cache/file Future. The
/// caller's ImageWork owns cancellation and waits for its actual completion.
Future<Uint8List?> readReaderImageBytes(ReaderImageAddress image) async {
  if (image.imageKey.startsWith('file://')) {
    return File(image.imageKey.substring(7)).readAsBytes();
  }
  final cache = CacheManager();
  // Preserve the legacy raw-URL lookup first (export tests and older builds
  // rely on it), then fall back to the token-free reader key used for new
  // reader pages so shelf/temporary images are still exportable.
  var file = await cache.findCache(image.cacheKey);
  file ??= await cache.findCache(
    ImageDownloader.readerCacheKey(
      image.imageKey,
      image.sourceKey,
      image.comicId,
      image.chapterId,
    ),
  );
  return file?.readAsBytes();
}
