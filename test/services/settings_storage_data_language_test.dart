import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/settings_storage.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('absent key => unset & not seeded', () async {
    final s = await SettingsStorage.load();
    expect(s.dataLanguage, isNull);
    expect(s.dataLanguageSeeded, isFalse);
  });

  test('round-trip: language code => set & seeded', () async {
    await SettingsStorage.save(
      AppSettings.defaults.copyWith(
        dataLanguage: 'ja',
        dataLanguageSeeded: true,
      ),
    );
    final s = await SettingsStorage.load();
    expect(s.dataLanguage, 'ja');
    expect(s.dataLanguageSeeded, isTrue);
  });

  test('round-trip: explicit none => unset but seeded', () async {
    await SettingsStorage.save(
      AppSettings.defaults.copyWith(
        clearDataLanguage: true,
        dataLanguageSeeded: true,
      ),
    );
    final s = await SettingsStorage.load();
    expect(s.dataLanguage, isNull);
    expect(s.dataLanguageSeeded, isTrue);
  });
}
