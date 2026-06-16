import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('setDataLanguage sets value and marks seeded', () async {
    final c = makeContainer();
    await c.read(settingsProvider.notifier).waitForLoad();
    await c.read(settingsProvider.notifier).setDataLanguage('ja');
    expect(c.read(settingsProvider).dataLanguage, 'ja');
    expect(c.read(settingsProvider).dataLanguageSeeded, isTrue);
    expect(c.read(dataLanguageProvider), 'ja');
  });

  test('setDataLanguage(null) = explicit unset, marks seeded', () async {
    final c = makeContainer();
    await c.read(settingsProvider.notifier).waitForLoad();
    await c.read(settingsProvider.notifier).setDataLanguage(null);
    expect(c.read(settingsProvider).dataLanguage, isNull);
    expect(c.read(settingsProvider).dataLanguageSeeded, isTrue);
  });

  test(
    'seedDataLanguageIfUnset seeds only when unseeded & supported',
    () async {
      final c = makeContainer();
      final n = c.read(settingsProvider.notifier);
      await n.waitForLoad();
      await n.seedDataLanguageIfUnset('id'); // not offered
      expect(c.read(settingsProvider).dataLanguage, isNull);
      expect(c.read(settingsProvider).dataLanguageSeeded, isFalse);
      await n.seedDataLanguageIfUnset('ko'); // offered
      expect(c.read(settingsProvider).dataLanguage, 'ko');
      expect(c.read(settingsProvider).dataLanguageSeeded, isTrue);
      await n.seedDataLanguageIfUnset('ja'); // already seeded => no-op
      expect(c.read(settingsProvider).dataLanguage, 'ko');
    },
  );
}
