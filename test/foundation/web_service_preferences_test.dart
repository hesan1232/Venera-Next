import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/application_preferences.dart';

void main() {
  test('web service preferences ship with safe defaults', () {
    final defaults = applicationPreferenceDefaults;
    expect(defaults[AppPreferences.webServiceEnabled.key], isFalse);
    expect(defaults[AppPreferences.webServicePort.key], 8080);
    expect(defaults[AppPreferences.webServiceLocalOnly.key], isFalse);
    expect(defaults[AppPreferences.webServiceToken.key], '');
    expect(defaults[AppPreferences.webServiceAllowProgressWrite.key], isTrue);
  });

  test('web service preferences are registered in AppPreferences.all', () {
    final keys = AppPreferences.all.map((e) => e.key).toSet();
    for (final key in [
      'webServiceEnabled',
      'webServicePort',
      'webServiceLocalOnly',
      'webServiceToken',
      'webServiceAllowProgressWrite',
    ]) {
      expect(keys, contains(key));
    }
  });

  test('numeric port preference clamps editor bounds', () {
    expect(AppPreferences.webServicePort.min, 1024);
    expect(AppPreferences.webServicePort.max, 65535);
  });
}
