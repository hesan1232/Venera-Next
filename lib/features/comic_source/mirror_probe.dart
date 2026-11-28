import 'dart:async';
import 'dart:io';

import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/network/proxy.dart';

/// How a mirror answered. Latency is reported separately so a reachable but
/// blocked host is not confused with a host that never answered.
enum MirrorStatus {
  /// Server answered with a usable response (2xx/3xx, or a plain 4xx such as
  /// 404 on the site root, which still proves the origin is alive).
  ok,

  /// Server answered but refused us: 401/403/407/429/451/503 and friends.
  /// Often a WAF or geo block, so it may still work inside the source when it
  /// carries cookies and the right referer.
  blocked,

  /// Server answered with a 5xx: the origin is broken, not our request.
  serverError,

  /// Nothing answered: DNS, connect or TLS failed, or the request timed out.
  unreachable,

  /// The candidate is not an absolute http(s) URL, so it cannot be probed.
  invalid,
}

class MirrorProbeResult {
  const MirrorProbeResult({
    required this.url,
    required this.status,
    this.latencyMs,
    this.samples = 0,
    this.statusCode,
    this.detail,
    this.redirected = false,
    this.measuredAt,
  });

  final String url;
  final MirrorStatus status;

  /// Median time to first byte across the usable samples, in milliseconds.
  final int? latencyMs;

  /// Number of samples that contributed to [latencyMs].
  final int samples;

  final int? statusCode;
  final String? detail;

  /// The host redirected at least once while answering.
  final bool redirected;

  final DateTime? measuredAt;

  bool get isUsable => status == MirrorStatus.ok;

  /// Buckets used by the UI. Only meaningful for reachable hosts.
  MirrorLatencyBucket? get bucket {
    final latency = latencyMs;
    if (!isUsable || latency == null) return null;
    if (latency < 300) return MirrorLatencyBucket.fast;
    if (latency < 1000) return MirrorLatencyBucket.normal;
    return MirrorLatencyBucket.slow;
  }
}

enum MirrorLatencyBucket { fast, normal, slow }

class MirrorProbeOptions {
  const MirrorProbeOptions({
    this.samples = 3,
    this.warmUp = true,
    this.timeout = const Duration(seconds: 5),
    this.referer,
    this.userAgent,
  });

  /// Cheap mode for the global sweep: one shot per host, no warm-up.
  static const sweep = MirrorProbeOptions(
    samples: 1,
    warmUp: false,
    timeout: Duration(seconds: 5),
  );

  final int samples;

  /// Discard one request first. Without it the very first sample carries DNS
  /// resolution plus the TLS handshake and reads as a false 400-800ms penalty,
  /// which would make a fast mirror look slow on its first measurement.
  final bool warmUp;

  final Duration timeout;
  final String? referer;

  /// Defaults to [webUA], the same agent the source runtime uses. Using the
  /// app's own `VeneraNext/v...` agent gets blocked by several WAFs and would
  /// report a perfectly good mirror as unreachable.
  final String? userAgent;

  String get effectiveUserAgent => userAgent ?? webUA;

  MirrorProbeOptions copyWith({String? referer}) => MirrorProbeOptions(
    samples: samples,
    warmUp: warmUp,
    timeout: timeout,
    referer: referer ?? this.referer,
    userAgent: userAgent,
  );
}

/// Measures how fast each mirror of a source answers.
///
/// Deliberately independent of the shared Dio client: that client carries a
/// five second response cache, so a second probe of the same host would report
/// a bogus ~0ms hit instead of a real round trip.
class MirrorProbe {
  MirrorProbe._();

  /// Probe every candidate in parallel, capped at [concurrency] in flight.
  /// Results come back in the same order as [urls].
  static Future<List<MirrorProbeResult>> probeAll(
    List<String> urls, {
    MirrorProbeOptions options = const MirrorProbeOptions(),
    int concurrency = 4,
  }) async {
    if (urls.isEmpty) return const [];
    final results = List<MirrorProbeResult?>.filled(urls.length, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= urls.length) return;
        results[index] = await probe(urls[index], options: options);
      }
    }

    final workers = concurrency.clamp(1, urls.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return [
      for (var i = 0; i < results.length; i++)
        results[i] ?? _invalid(urls[i], '未测速'),
    ];
  }

  static Future<MirrorProbeResult> probe(
    String url, {
    MirrorProbeOptions options = const MirrorProbeOptions(),
  }) async {
    final probeUrl = normalizeMirrorUrl(url);
    if (probeUrl == null) {
      return _invalid(url, '不是有效的 http(s) 地址');
    }
    final uri = Uri.parse(probeUrl);

    final proxy = await _safeProxy();
    final agent = options.effectiveUserAgent;
    // Sources send their own origin as the referer on real requests. Default to
    // the candidate's own origin: sharing one mirror's origin with another
    // mirror is wrong and some hosts reject a foreign referer.
    final referer = options.referer ?? uri.origin;
    final latencies = <int>[];
    int? lastStatus;
    var redirected = false;
    String? detail;
    var status = MirrorStatus.unreachable;

    final attempts = options.samples + (options.warmUp ? 1 : 0);
    final client = HttpClient()
      ..connectionTimeout = options.timeout
      ..idleTimeout = const Duration(seconds: 5)
      ..autoUncompress = false
      ..findProxy = ((_) => proxy == null ? 'DIRECT' : 'PROXY $proxy');

    try {
      for (var attempt = 0; attempt < attempts; attempt++) {
        final isWarmUp = options.warmUp && attempt == 0;
        final stopwatch = Stopwatch()..start();
        try {
          final request = await client
              .openUrl('GET', uri)
              .timeout(options.timeout);
          request.followRedirects = true;
          request.maxRedirects = 5;
          request.headers.set(HttpHeaders.userAgentHeader, agent);
          request.headers.set(HttpHeaders.refererHeader, referer);
          request.headers.set(
            HttpHeaders.acceptHeader,
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          );
          request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

          // close() completes when the response head arrives, which is exactly
          // the time-to-first-byte we want. The body is never downloaded.
          final response = await request.close().timeout(options.timeout);
          stopwatch.stop();

          lastStatus = response.statusCode;
          if (response.redirects.isNotEmpty) redirected = true;
          await _discard(response);

          status = _statusFor(response.statusCode);
          if (!isWarmUp && status == MirrorStatus.ok) {
            latencies.add(stopwatch.elapsedMilliseconds);
          }
          if (status != MirrorStatus.ok) {
            detail = _describeStatus(response.statusCode);
          }
        } on TimeoutException {
          stopwatch.stop();
          status = MirrorStatus.unreachable;
          detail = '超时（${options.timeout.inSeconds}s）';
        } on SocketException catch (error) {
          stopwatch.stop();
          status = MirrorStatus.unreachable;
          detail = '连接失败：${error.osError?.message ?? error.message}';
        } on HandshakeException catch (error) {
          stopwatch.stop();
          status = MirrorStatus.unreachable;
          detail = 'TLS 握手失败：${error.message}';
        } on HttpException catch (error) {
          stopwatch.stop();
          status = MirrorStatus.unreachable;
          detail = 'HTTP 错误：${error.message}';
        } catch (error) {
          stopwatch.stop();
          status = MirrorStatus.unreachable;
          detail = '请求失败：$error';
        }

        if (status == MirrorStatus.unreachable) break;
      }
    } finally {
      client.close(force: true);
    }

    return MirrorProbeResult(
      url: url,
      status: status,
      latencyMs: latencies.isEmpty ? null : _median(latencies),
      samples: latencies.length,
      statusCode: lastStatus,
      detail: detail,
      redirected: redirected,
      measuredAt: DateTime.now(),
    );
  }

  static MirrorProbeResult _invalid(String url, String detail) =>
      MirrorProbeResult(
        url: url,
        status: MirrorStatus.invalid,
        detail: detail,
        measuredAt: DateTime.now(),
      );

  static Future<void> _discard(HttpClientResponse response) async {
    try {
      // Cancel right after the head arrives: this frees the connection without
      // downloading a possibly multi-megabyte page.
      await response.listen(null).cancel();
    } catch (_) {
      // The status code already arrived; a failed cleanup cannot change it.
    }
  }

  static Future<String?> _safeProxy() async {
    try {
      return await getProxy();
    } catch (_) {
      // Proxy lookup touches appdata settings, which unit tests may not boot.
      // Probing without a proxy is the right fallback either way.
      return null;
    }
  }

  static MirrorStatus _statusFor(int code) {
    if (code >= 200 && code < 400) return MirrorStatus.ok;
    if (code >= 500) return MirrorStatus.serverError;
    if (code == 401 ||
        code == 403 ||
        code == 407 ||
        code == 429 ||
        code == 451 ||
        code == 503) {
      return MirrorStatus.blocked;
    }
    // A plain 4xx on the site root still proves the origin answered.
    return MirrorStatus.ok;
  }

  static String _describeStatus(int code) => switch (code) {
    401 => '需要登录（401）',
    403 => '被拒绝访问（403）',
    407 => '需要代理认证（407）',
    429 => '请求过多被限流（429）',
    451 => '因法律原因不可用（451）',
    503 => '服务暂不可用（503）',
    >= 500 => '源站错误（$code）',
    _ => 'HTTP $code',
  };

  static int _median(List<int> values) {
    final sorted = List<int>.from(values)..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return ((sorted[middle - 1] + sorted[middle]) / 2).round();
  }
}

/// One `select` setting that holds several interchangeable site URLs.
class MirrorSettingGroup {
  const MirrorSettingGroup({
    required this.sourceKey,
    required this.sourceName,
    required this.settingKey,
    required this.title,
    required this.candidates,
    required this.current,
  });

  final String sourceKey;
  final String sourceName;
  final String settingKey;
  final String title;

  /// Only the absolute http(s) option values, in declaration order.
  final List<String> candidates;

  /// The value the source will actually use right now.
  final String? current;

  String get currentOrFirst =>
      candidates.contains(current) ? current! : candidates.first;
}

/// Bare hosts such as `bzmgcn.com` are a common way for sources to declare a
/// mirror: the script prefixes `https://` itself (包子漫画 does exactly that).
/// At least one dot is required so option values like `cn`, `all` or `/w640`
/// are not mistaken for hosts.
final RegExp _bareMirrorHost = RegExp(
  r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?'
  r'(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+'
  r'(?::\d{1,5})?(?:/.*)?$',
  caseSensitive: false,
);

/// Returns the URL to probe for a raw setting value, or null when the value is
/// not a host candidate. The raw value is kept as [MirrorProbeResult.url] so a
/// picked result can be written straight back into the source settings.
String? normalizeMirrorUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri != null &&
      uri.host.isNotEmpty &&
      (uri.isScheme('http') || uri.isScheme('https'))) {
    return value;
  }
  if (_bareMirrorHost.hasMatch(value)) return 'https://$value';
  return null;
}

/// A mirror `select` is one whose options carry at least two hosts, either as
/// absolute http(s) URLs or as bare domains. This keeps the feature
/// source-agnostic: laimanhua declares full URLs and 包子漫画 bare domains, and
/// neither source has to change for the health page to find them.
bool isMirrorSetting(Map<String, dynamic> setting) =>
    mirrorCandidatesOf(setting).length >= 2;

List<String> mirrorCandidatesOf(Map<String, dynamic> setting) {
  if (setting['type'] != 'select') return const [];
  final options = setting['options'];
  if (options is! List) return const [];
  final hosts = <String>[];
  for (final option in options) {
    if (option is! Map) continue;
    final value = option['value'];
    if (value is! String || normalizeMirrorUrl(value) == null) continue;
    final raw = value.trim();
    if (!hosts.contains(raw)) hosts.add(raw);
  }
  return hosts;
}

/// Every mirror group declared by [source]. Uses the statically declared
/// settings so this stays usable from a page with no JS callback scope.
List<MirrorSettingGroup> mirrorGroupsOf(ComicSource source) {
  final settings = source.settings;
  if (settings == null) return const [];
  final groups = <MirrorSettingGroup>[];
  for (final entry in settings.entries) {
    final setting = entry.value;
    final candidates = mirrorCandidatesOf(setting);
    if (candidates.length < 2) continue;
    final title = setting['title'];
    final current = source.data['settings']?[entry.key];
    groups.add(
      MirrorSettingGroup(
        sourceKey: source.key,
        sourceName: source.name,
        settingKey: entry.key,
        title: title is String ? title : entry.key,
        candidates: candidates,
        current: current is String ? current : null,
      ),
    );
  }
  return groups;
}
