import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/chapter_precache.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('warms following chapters in order with target chapter ids', () async {
    final work = ImageWork();
    final precache = ReaderChapterPrecache(work: work);
    final loads = <int>[];
    final images = <String>[];
    final firsts = <String>[];

    precache.warm(
      currentChapter: 2,
      maxChapter: 5,
      ahead: 2,
      imageCount: 3,
      loadChapter: (chapter, scope) async {
        loads.add(chapter);
        return List.generate(5, (i) => '$chapter-${i + 1}');
      },
      chapterIdOf: (chapter) => 'eid-$chapter',
      onFirstImage: (key, chapterId) => firsts.add('$chapterId/$key'),
      onImage: (key, chapterId) => images.add('$chapterId/$key'),
    );
    await settle();

    expect(loads, [3, 4]);
    expect(firsts, ['eid-3/3-1', 'eid-4/4-1']);
    expect(images, [
      'eid-3/3-1',
      'eid-3/3-2',
      'eid-3/3-3',
      'eid-4/4-1',
      'eid-4/4-2',
      'eid-4/4-3',
    ]);
    expect(precache.warmedChapterCount, 2);
    final release = await work.prepareForExit();
    release();
  });

  test('stops at the last chapter and never warms one chapter twice', () async {
    final work = ImageWork();
    final precache = ReaderChapterPrecache(work: work);
    final loads = <int>[];

    Future<List<String>> load(int chapter, RequestScope scope) async {
      loads.add(chapter);
      return ['$chapter-1'];
    }

    precache.warm(
      currentChapter: 3,
      maxChapter: 4,
      ahead: 5,
      imageCount: 1,
      loadChapter: load,
      chapterIdOf: (chapter) => 'eid-$chapter',
      onImage: (_, _) {},
    );
    await settle();
    precache.warm(
      currentChapter: 3,
      maxChapter: 4,
      ahead: 5,
      imageCount: 1,
      loadChapter: load,
      chapterIdOf: (chapter) => 'eid-$chapter',
      onImage: (_, _) {},
    );
    await settle();

    expect(loads, [4]);
    final release = await work.prepareForExit();
    release();
  });

  test('dispose cancels an in-flight chain before the next chapter', () async {
    final work = ImageWork();
    final precache = ReaderChapterPrecache(work: work);
    final gate = Completer<List<String>>();
    final loads = <int>[];

    precache.warm(
      currentChapter: 1,
      maxChapter: 4,
      ahead: 3,
      imageCount: 1,
      loadChapter: (chapter, scope) async {
        loads.add(chapter);
        if (chapter == 2) return gate.future;
        return ['$chapter-1'];
      },
      chapterIdOf: (chapter) => 'eid-$chapter',
      onImage: (_, _) {},
    );
    await settle();
    expect(loads, [2]);

    final disposal = precache.dispose();
    gate.complete(['2-1']);
    await disposal;
    await settle();

    expect(loads, [2]);
    final release = await work.prepareForExit();
    release();
  });

  test(
    'source failures stay opportunistic and do not poison image work',
    () async {
      final work = ImageWork();
      final precache = ReaderChapterPrecache(work: work);

      precache.warm(
        currentChapter: 1,
        maxChapter: 3,
        ahead: 2,
        imageCount: 1,
        loadChapter: (chapter, scope) async => throw StateError('source down'),
        chapterIdOf: (chapter) => 'eid-$chapter',
        onImage: (_, _) {},
      );
      await settle();

      final release = await work.prepareForExit();
      release();
    },
  );

  test('a failed chapter is warmed again on the next attempt', () async {
    final work = ImageWork();
    final precache = ReaderChapterPrecache(work: work);
    final loads = <int>[];
    var failuresLeft = 1;

    Future<List<String>> load(int chapter, RequestScope scope) async {
      loads.add(chapter);
      if (failuresLeft > 0) {
        failuresLeft--;
        throw StateError('temporary source error');
      }
      return ['$chapter-1'];
    }

    void warm() => precache.warm(
      currentChapter: 1,
      maxChapter: 2,
      ahead: 1,
      imageCount: 1,
      loadChapter: load,
      chapterIdOf: (chapter) => 'eid-$chapter',
      onImage: (_, _) {},
    );

    warm();
    await settle();
    // A failed chapter must not stay in the warmed set, otherwise one
    // transient error would silently disable warming for the whole chapter.
    expect(precache.warmedChapterCount, 0);

    warm();
    await settle();
    expect(loads, [2, 2]);
    expect(precache.warmedChapterCount, 1);

    final release = await work.prepareForExit();
    release();
  });
}
