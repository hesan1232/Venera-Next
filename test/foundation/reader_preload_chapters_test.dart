import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/reader_preferences.dart';
import 'package:venera_next/foundation/reader_settings.dart';

void main() {
  test('preload chapters preference has a bounded integer schema', () {
    final preference = ReaderPreferences.preloadChapters;
    expect(preference.key, 'preloadChapters');
    expect(preference.normalize(null), 1);
    expect(preference.normalize(-2), 0);
    expect(preference.normalize(99), 5);
    expect(preference.normalize(3.7), 3);
    expect(ReaderPreferences.storageDefaults['preloadChapters'], 1);
    expect(ReaderPreferences.all, contains(preference));
  });

  test('reader settings resolve chapter preload across scopes', () {
    final global = <String, Object?>{'preloadChapters': 2};
    expect(ReaderSettings.resolve(global: global).preloadChapters, 2);
    expect(
      ReaderSettings.resolve(
        global: global,
        device: {'enabled': true, 'preloadChapters': 3},
      ).preloadChapters,
      3,
    );
    expect(
      ReaderSettings.resolve(
        global: global,
        device: {'enabled': true, 'preloadChapters': 3},
        comic: {'enabled': true, 'preloadChapters': 0},
      ).preloadChapters,
      0,
    );
  });

  test('TV low-memory mode disables chapter preloading', () {
    final settings = ReaderSettings.resolve(
      global: {'preloadChapters': 5},
      tvLowMemory: true,
    );
    expect(settings.preloadChapters, 0);
    expect(settings.preloadImageCount, 1);
  });
}
