import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/data_language.dart';

void main() {
  test('9 options, encore-aligned codes, native labels', () {
    expect(kDataLanguageOptions.length, 9);
    expect(kDataLanguageOptions.map((o) => o.code).toList(), [
      'zh-Hant',
      'zh-Hans',
      'en',
      'ja',
      'ko',
      'fr',
      'de',
      'es',
      'th',
    ]);
    expect(kDataLanguageOptions.first.label, '繁體中文');
  });

  test('isSupportedDataLanguage', () {
    expect(isSupportedDataLanguage('ja'), isTrue);
    expect(isSupportedDataLanguage('zh-Hant'), isTrue);
    expect(
      isSupportedDataLanguage('id'),
      isFalse,
    ); // encore supports it, we don't offer it
    expect(isSupportedDataLanguage(''), isFalse);
  });
}
