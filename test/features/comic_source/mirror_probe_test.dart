import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/mirror_probe.dart';

void main() {
  group('mirrorCandidatesOf', () {
    test('collects absolute http(s) option values in order', () {
      final setting = <String, dynamic>{
        'type': 'select',
        'title': '搜索',
        'options': [
          {'value': 'https://www.example-a.com', 'text': 'A'},
          {'value': 'http://www.example-b.com', 'text': 'B'},
        ],
      };
      expect(mirrorCandidatesOf(setting), [
        'https://www.example-a.com',
        'http://www.example-b.com',
      ]);
      expect(isMirrorSetting(setting), isTrue);
    });

    test('keeps the url subset when other options are not urls', () {
      final setting = <String, dynamic>{
        'type': 'select',
        'options': [
          {'value': 'https://www.example-a.com'},
          {'value': 'custom'},
          {'value': 'https://m.example-a.com'},
        ],
      };
      expect(mirrorCandidatesOf(setting), [
        'https://www.example-a.com',
        'https://m.example-a.com',
      ]);
      expect(isMirrorSetting(setting), isTrue);
    });

    test('needs at least two urls', () {
      final setting = <String, dynamic>{
        'type': 'select',
        'options': [
          {'value': 'https://only-one.example.com'},
          {'value': 'text-only'},
        ],
      };
      expect(mirrorCandidatesOf(setting), ['https://only-one.example.com']);
      expect(isMirrorSetting(setting), isFalse);
    });

    test('ignores non-select settings', () {
      final setting = <String, dynamic>{
        'type': 'input',
        'default': 'https://a.example.com',
      };
      expect(mirrorCandidatesOf(setting), isEmpty);
      expect(isMirrorSetting(setting), isFalse);
    });

    test('dedupes repeated urls', () {
      final setting = <String, dynamic>{
        'type': 'select',
        'options': [
          {'value': 'https://a.example.com'},
          {'value': 'https://a.example.com'},
          {'value': 'https://b.example.com'},
        ],
      };
      expect(mirrorCandidatesOf(setting), [
        'https://a.example.com',
        'https://b.example.com',
      ]);
    });

    test('accepts bare domains but rejects non-host values', () {
      final setting = <String, dynamic>{
        'type': 'select',
        'options': [
          {'value': 'www.example.com'},
          {'value': '/search'},
          {'value': 'ftp://example.com'},
          {'value': 'cn'},
        ],
      };
      expect(mirrorCandidatesOf(setting), ['www.example.com']);
    });

    test('finds the multi-domain settings used by baozi', () {
      final domains = <String, dynamic>{
        'type': 'select',
        'title': '主域名',
        'options': [
          {'value': 'bzmgcn.com'},
          {'value': 'baozimhcn.com'},
          {'value': 'webmota.com'},
        ],
      };
      final cdn = <String, dynamic>{
        'type': 'select',
        'title': '图片资源站域名',
        'options': [
          {'value': 'as-rsa1-usla.baozicdn.com'},
          {'value': 'ascn-a3.bzcdn.net'},
          {'value': ''},
        ],
      };
      expect(mirrorCandidatesOf(domains), [
        'bzmgcn.com',
        'baozimhcn.com',
        'webmota.com',
      ]);
      expect(isMirrorSetting(domains), isTrue);
      expect(mirrorCandidatesOf(cdn), [
        'as-rsa1-usla.baozicdn.com',
        'ascn-a3.bzcdn.net',
      ]);
      expect(isMirrorSetting(cdn), isTrue);
      expect(normalizeMirrorUrl('bzmgcn.com'), 'https://bzmgcn.com');
      expect(normalizeMirrorUrl('/w640'), isNull);
    });

    test('normalization covers ports and keeps explicit schemes', () {
      expect(normalizeMirrorUrl('example.com:8080/path'),
          'https://example.com:8080/path');
      expect(normalizeMirrorUrl('http://a.example.com'),
          'http://a.example.com');
      expect(normalizeMirrorUrl(''), isNull);
    });
  });

  group('MirrorProbeResult', () {
    test('buckets usable latencies', () {
      MirrorProbeResult at(int ms) => MirrorProbeResult(
        url: 'https://a.example.com',
        status: MirrorStatus.ok,
        latencyMs: ms,
      );
      expect(at(120).bucket, MirrorLatencyBucket.fast);
      expect(at(300).bucket, MirrorLatencyBucket.normal);
      expect(at(999).bucket, MirrorLatencyBucket.normal);
      expect(at(1000).bucket, MirrorLatencyBucket.slow);
    });

    test('unusable results have no bucket', () {
      const result = MirrorProbeResult(
        url: 'https://a.example.com',
        status: MirrorStatus.unreachable,
        latencyMs: 40,
      );
      expect(result.isUsable, isFalse);
      expect(result.bucket, isNull);
    });
  });

  group('MirrorProbe against a local host', () {
    late HttpServer server;
    late String base;

    const fastOptions = MirrorProbeOptions(
      samples: 1,
      warmUp: false,
      timeout: Duration(seconds: 2),
    );

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) {
        final status = switch (request.uri.path) {
          '/ok' => 200,
          '/blocked' => 403,
          '/gone' => 404,
          '/boom' => 500,
          _ => 418,
        };
        request.response.statusCode = status;
        request.response.write('probe');
        request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('reports a reachable mirror with latency', () async {
      final result = await MirrorProbe.probe('$base/ok', options: fastOptions);
      expect(result.status, MirrorStatus.ok);
      expect(result.statusCode, 200);
      expect(result.latencyMs, isNotNull);
      expect(result.latencyMs, greaterThanOrEqualTo(0));
      expect(result.isUsable, isTrue);
    });

    test('treats 4xx other than block codes as reachable', () async {
      final result = await MirrorProbe.probe(
        '$base/gone',
        options: fastOptions,
      );
      expect(result.status, MirrorStatus.ok);
      expect(result.statusCode, 404);
    });

    test('marks 403 as blocked, not unreachable', () async {
      final result = await MirrorProbe.probe(
        '$base/blocked',
        options: fastOptions,
      );
      expect(result.status, MirrorStatus.blocked);
      expect(result.statusCode, 403);
      expect(result.detail, isNotNull);
      expect(result.isUsable, isFalse);
    });

    test('marks 5xx as server error', () async {
      final result = await MirrorProbe.probe('$base/boom', options: fastOptions);
      expect(result.status, MirrorStatus.serverError);
      expect(result.statusCode, 500);
    });

    test('reports unreachable when nothing listens', () async {
      // Bind then close to get a port that is certainly free.
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final result = await MirrorProbe.probe(
        'http://127.0.0.1:$port/',
        options: fastOptions,
      );
      expect(result.status, MirrorStatus.unreachable);
      expect(result.latencyMs, isNull);
    });

    test('rejects a non-http candidate without touching the network', () async {
      final result = await MirrorProbe.probe('not-a-url', options: fastOptions);
      expect(result.status, MirrorStatus.invalid);
    });

    test('times out a host that never answers', () async {
      final silent = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final slowBase = 'http://127.0.0.1:${silent.port}';
      silent.listen((request) {
        // Never respond.
      });
      try {
        final result = await MirrorProbe.probe(
          '$slowBase/',
          options: const MirrorProbeOptions(
            samples: 1,
            warmUp: false,
            timeout: Duration(milliseconds: 300),
          ),
        );
        expect(result.status, MirrorStatus.unreachable);
        expect(result.detail, contains('超时'));
      } finally {
        await silent.close(force: true);
      }
    });

    test('probeAll keeps the input order', () async {
      final results = await MirrorProbe.probeAll([
        '$base/blocked',
        '$base/ok',
        '$base/boom',
      ], options: fastOptions);
      expect(results.map((result) => result.status), [
        MirrorStatus.blocked,
        MirrorStatus.ok,
        MirrorStatus.serverError,
      ]);
      expect(results.map((result) => result.url), [
        '$base/blocked',
        '$base/ok',
        '$base/boom',
      ]);
    });

    test('probeAll copes with an empty candidate list', () async {
      expect(await MirrorProbe.probeAll(const []), isEmpty);
    });
  });
}
