import 'package:flutter/services.dart';
import 'package:venera_next/foundation/app.dart';

/// Android battery-optimization whitelist state.
///
/// The web service is a plain Dart `HttpServer` living inside the app process:
/// once Android deep-sleeps the process, LAN browsers and OPDS clients simply
/// get connection refused. Querying and requesting the whitelist goes through
/// the existing host channel so the pure-Dart layers stay platform agnostic.
class BatteryOptimization {
  const BatteryOptimization._();

  static const _channel = MethodChannel('venera/method_channel');

  static bool get supported => App.isAndroid;

  /// `null` means the platform cannot answer (non-Android or an old host).
  static Future<bool?> isIgnoring() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return null;
    }
  }

  /// Opens the system whitelist dialog. Returns the state after the user
  /// leaves the settings screen, or `false` when the request was declined.
  static Future<bool> requestIgnore() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
