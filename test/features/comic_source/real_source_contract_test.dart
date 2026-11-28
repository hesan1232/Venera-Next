import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';

/// Contract tests driven by REAL comic source scripts shipped by the
/// community source repository (including the official Tencent source).
///
/// These checks deliberately stay at the static/Dart layer so they run
/// without the QuickJS native library: they verify that real source scripts
/// satisfy the parser's entry-class contract, that their declared metadata
/// agrees with the repository index, and that the callbacks the web service
/// and reader precache depend on are actually declared.
void main() {
  final fixtureDir = Directory('test/fixtures/comic_sources');

  List<dynamic> indexEntries() {
    final decoded =
        jsonDecode(File('${fixtureDir.path}/index.json').readAsStringSync());
    return decoded as List<dynamic>;
  }

  String script(String fileName) =>
      File('${fixtureDir.path}/$fileName').readAsStringSync();

  String declaredField(String js, String field) {
    final match = RegExp(
      '\\b$field\\s*=\\s*["\']([^"\']+)["\']',
    ).firstMatch(js);
    if (match == null) {
      throw StateError('source script has no declared $field');
    }
    return match.group(1)!;
  }

  setUp(() {
    assert(
      fixtureDir.existsSync(),
      'real source fixture is missing: ${fixtureDir.path}',
    );
  });

  test('fixture index is a non-empty real source catalogue', () {
    final entries = indexEntries();
    expect(entries.length, greaterThanOrEqualTo(3));
    for (final entry in entries) {
      final map = entry as Map<String, dynamic>;
      expect(map['fileName'], isA<String>());
      expect(map['key'], isA<String>());
      expect(map['version'], isA<String>());
    }
    expect(
      entries.first['fileName'],
      endsWith('.js'),
      reason: 'index entries must point to source scripts',
    );
  });

  test('official Tencent source parses to its real class and key', () {
    final js = script('tencent_comic_official.js');
    expect(sourceClassName(js), 'TencentComicOfficial');
    expect(declaredField(js, 'key'), 'qq_comic_official_v1');
    expect(declaredField(js, 'name'), '腾讯动漫（正版）');
    expect(declaredField(js, 'version'), '1.0.3');
  });

  test('real sources agree with index metadata and parse their entry class', () {
    final entries = indexEntries().cast<Map<String, dynamic>>();
    final localFiles = fixtureDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.js'))
        .map((f) => f.uri.pathSegments.last)
        .toList()
      ..sort();
    expect(localFiles, ['manga_dex.js', 'manhuagui.js', 'tencent_comic_official.js']);

    for (final entry in entries) {
      final fileName = entry['fileName'] as String;
      if (!localFiles.contains(fileName)) continue;
      final js = script(fileName);
      expect(
        sourceClassName(js),
        isNotEmpty,
        reason: '$fileName must expose a ComicSource entry class',
      );
      expect(declaredField(js, 'key'), entry['key'],
          reason: '$fileName key must match index.json');
      expect(declaredField(js, 'version'), entry['version'],
          reason: '$fileName version must match index.json');
    }
  });

  test('real sources declare the callbacks used by web service and precache', () {
    for (final fileName in [
      'tencent_comic_official.js',
      'manga_dex.js',
      'manhuagui.js',
    ]) {
      final js = script(fileName);
      expect(RegExp(r'\bsearch\s*=').hasMatch(js), isTrue,
          reason: '$fileName must declare search');
      expect(RegExp(r'\bloadInfo\s*:').hasMatch(js), isTrue,
          reason: '$fileName must declare comic.loadInfo');
      expect(RegExp(r'\bloadEp\s*:').hasMatch(js), isTrue,
          reason: '$fileName must declare comic.loadEp');
    }
  });

  test('onImageLoad is optional but honoured where a real source declares it',
      () {
    // manhuagui declares an optional per-image loading config; the official
    // Tencent source and MangaDex omit it and return image URLs directly.
    final manhuagui = script('manhuagui.js');
    expect(RegExp(r'\bonImageLoad\s*[:(]').hasMatch(manhuagui), isTrue);

    for (final fileName in ['tencent_comic_official.js', 'manga_dex.js']) {
      final js = script(fileName);
      expect(RegExp(r'\bloadEp\s*:').hasMatch(js), isTrue);
      expect(js, contains('images'),
          reason: '$fileName returns chapter image URLs from loadEp');
    }
  });
}
