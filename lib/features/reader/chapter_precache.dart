import 'dart:async';

import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/request_scope.dart';

/// Warms the first images of upcoming chapters so a gallery page turn across a
/// chapter boundary does not have to wait for the source call and first decode.
///
/// One instance belongs to one reader view/session. Work is registered with
/// [ImageWork] so exit preparation can cancel and drain it like any other
/// image read; prefetch failures are opportunistic and never fail that drain.
class ReaderChapterPrecache {
  ReaderChapterPrecache({required ImageWork work}) : _work = work;

  final ImageWork _work;
  final _warmed = <int>{};
  RequestScope? _scope;
  ImageWorkTask? _task;
  Future<void>? _disposal;

  int get warmedChapterCount => _warmed.length;

  /// Fetch the image lists of up to [ahead] chapters after [currentChapter],
  /// then hand their first [imageCount] images to [onImage].
  ///
  /// Calls are sequential and idempotent per chapter: turning pages back and
  /// forth must not queue duplicate source requests.
  void warm({
    required int currentChapter,
    required int maxChapter,
    required int ahead,
    required int imageCount,
    required Future<List<String>> Function(int chapter, RequestScope scope)
    loadChapter,
    required String Function(int chapter) chapterIdOf,
    required void Function(String imageKey, String chapterId) onImage,
    void Function(String imageKey, String chapterId)? onFirstImage,
  }) {
    if (_disposal != null || _task != null) return;
    if (ahead <= 0 || imageCount <= 0 || currentChapter >= maxChapter) return;
    final scope = RequestScope();
    final task = _work.start(onCancel: scope.cancel);
    if (task == null) {
      scope.dispose();
      return;
    }
    _scope = scope;
    _task = task;
    unawaited(
      _warmAll(
        scope: scope,
        task: task,
        currentChapter: currentChapter,
        maxChapter: maxChapter,
        ahead: ahead,
        imageCount: imageCount,
        loadChapter: loadChapter,
        chapterIdOf: chapterIdOf,
        onImage: onImage,
        onFirstImage: onFirstImage,
      ),
    );
  }

  Future<void> _warmAll({
    required RequestScope scope,
    required ImageWorkTask task,
    required int currentChapter,
    required int maxChapter,
    required int ahead,
    required int imageCount,
    required Future<List<String>> Function(int chapter, RequestScope scope)
    loadChapter,
    required String Function(int chapter) chapterIdOf,
    required void Function(String imageKey, String chapterId) onImage,
    void Function(String imageKey, String chapterId)? onFirstImage,
  }) async {
    int? attempted;
    try {
      for (var offset = 1; offset <= ahead; offset++) {
        final chapter = currentChapter + offset;
        if (chapter > maxChapter) break;
        if (!_warmed.add(chapter)) continue;
        attempted = chapter;
        task.check();
        final images = await _loadInterruptibly(loadChapter, chapter, scope);
        task.check();
        final chapterId = chapterIdOf(chapter);
        final warmImages = images.take(imageCount).toList(growable: false);
        if (warmImages.isNotEmpty) {
          task.check();
          onFirstImage?.call(warmImages.first, chapterId);
        }
        for (final key in warmImages) {
          task.check();
          onImage(key, chapterId);
        }
        attempted = null;
      }
    } on RequestCancelled {
      // The reader changed chapter or is exiting; the next view warms again.
    } on ImageWorkTaskCancelled {
      // Exit preparation revoked admission.
    } catch (error, stack) {
      if (!task.isCancelled) {
        Log.error('Reader chapter precache', error, stack);
      }
    } finally {
      // A chapter only counts as warmed once its source call returned. Leaving
      // a failed chapter in the set would silently disable warming for it, so
      // one transient error would look like the feature never ran.
      if (attempted != null) _warmed.remove(attempted);
      scope.dispose();
      if (identical(_scope, scope)) {
        _scope = null;
        _task = null;
      }
      task.finish();
    }
  }

  /// Chapter loads join their accepted source call even after cancellation so
  /// the real page turn keeps its result. A prefetch must not: exit preparation
  /// drains every registered task, so an uninterruptible warm would hold the
  /// reader open for the length of an abandoned request.
  Future<List<String>> _loadInterruptibly(
    Future<List<String>> Function(int chapter, RequestScope scope) loadChapter,
    int chapter,
    RequestScope scope,
  ) => Future.any<List<String>>([
    loadChapter(chapter, scope),
    scope.whenCancelled.then<List<String>>(
      (_) => throw const RequestCancelled(),
    ),
  ]);

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    final scope = _scope;
    final task = _task;
    final completion = Completer<void>();
    _disposal = completion.future;
    if (task == null || scope == null) {
      completion.complete();
      return completion.future;
    }
    task.cancel();
    completion.complete(task.done.then((_) {}));
    return completion.future;
  }
}
