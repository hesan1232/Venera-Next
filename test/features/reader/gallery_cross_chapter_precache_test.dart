import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_next/features/reader/gallery_data.dart';
import 'package:venera_next/features/reader/gallery_view.dart';
import 'package:venera_next/features/reader/page_layout.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';
import 'package:venera_next/foundation/image_work.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final chapters in [0, 1]) {
    testWidgets('gallery warms the next chapter only when enabled: $chapters', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync(
        'gallery-chapter-precache-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final files = <String>[];
      for (var i = 1; i <= 3; i++) {
        final pixels = img.Image(width: 60, height: 90)
          ..clear(img.ColorRgb8(20 * i, 60, 120));
        final file = File('${directory.path}/$i.png')
          ..writeAsBytesSync(img.encodePng(pixels));
        files.add('file://${file.path}');
      }

        final work = ImageWork();
        final viewport = ReaderViewportBinding();
      final loads = <int>[];
      final size = const Size(300, 450);
      late final ReaderGalleryData data;
      late final navigation = ReaderController(
        pageCount: () => data.totalPages,
        chapterCount: () => 3,
        animationEnabled: () => false,
        viewport: () => viewport.current,
        onChanged: () {},
        onPageChanged: () {},
        onError: (error, stack) => fail('$error\n$stack'),
      );
      navigation.replaceChapterImages(files.take(2).toList());
      data = ReaderGalleryData(
        content: navigation.content,
        layout: const ReaderPageLayout(
          imagesPerPage: 1,
          singleImageOnFirstPage: false,
        ),
        vertical: false,
        reverse: false,
        commentsAtEnd: false,
        firstChapter: false,
        lastChapter: false,
        preloadCount: 1,
        preloadChapters: chapters,
        doubleTapCollect: false,
        centerLongPressZoom: true,
        pageAnimation: true,
        sourceKey: null,
        comicId: 'precache-book',
        chapterId: 'eid-1',
      );
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderGalleryView(
            data: data,
            imageWork: work,
            navigation: navigation,
            onViewportChanged: viewport.update,
            onReady: () {},
            onPageReported: (_, _) {},
            onChapterChanged: () {},
            onCollectImage: () {},
            readerSize: () => size,
            readImage: (_) async => null,
            loadChapter: (chapter, scope) async {
              loads.add(chapter);
              return [files[2]];
            },
            chapterIdOf: (chapter) => 'eid-$chapter',
            maxChapter: 3,
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));

      expect(loads, chapters == 0 ? isEmpty : contains(2));
    });
  }

  testWidgets('gallery warms the next chapter from the first page', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('gallery-eager-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final images = <String>[];
    for (var i = 1; i <= 10; i++) {
      final pixels = img.Image(width: 40, height: 60)
        ..clear(img.ColorRgb8(10 * i, 80, 140));
      final file = File('${directory.path}/$i.png')
        ..writeAsBytesSync(img.encodePng(pixels));
      images.add('file://${file.path}');
    }

    final work = ImageWork();
    final viewport = ReaderViewportBinding();
    final loads = <int>[];
    final size = const Size(300, 450);
    late final ReaderGalleryData data;
    late final navigation = ReaderController(
      pageCount: () => data.totalPages,
      chapterCount: () => 3,
      animationEnabled: () => false,
      viewport: () => viewport.current,
      onChanged: () {},
      onPageChanged: () {},
      onError: (error, stack) => fail('$error\n$stack'),
    );
    navigation.replaceChapterImages(images);
    data = ReaderGalleryData(
      content: navigation.content,
      layout: const ReaderPageLayout(
        imagesPerPage: 1,
        singleImageOnFirstPage: false,
      ),
      vertical: false,
      reverse: false,
      commentsAtEnd: false,
      firstChapter: false,
      lastChapter: false,
      preloadCount: 4,
      preloadChapters: 1,
      doubleTapCollect: false,
      centerLongPressZoom: true,
      pageAnimation: false,
      sourceKey: null,
      comicId: 'precache-book',
      chapterId: 'eid-1',
    );
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderGalleryView(
          data: data,
          imageWork: work,
          navigation: navigation,
          onViewportChanged: viewport.update,
          onReady: () {},
          onPageReported: (_, _) {},
          onChapterChanged: () {},
          onCollectImage: () {},
          readerSize: () => size,
          readImage: (_) async => null,
          loadChapter: (chapter, scope) async {
            loads.add(chapter);
            return [images.first];
          },
          chapterIdOf: (chapter) => 'eid-$chapter',
          maxChapter: 3,
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    // Ten pages with four warm pages: the old trigger only fired from page 6.
    expect(navigation.state.page, 1);
    expect(loads, [2]);
  });
}
