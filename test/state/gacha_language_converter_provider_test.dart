import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/lang_catalog.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';

void main() {
  test('gachaLanguageConverterProvider builds a converter', () {
    final dir = Directory.systemTemp.createTempSync('conv');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c = ProviderContainer(
      overrides: [itemImageCacheDirProvider.overrideWithValue(dir)],
    );
    addTearDown(c.dispose);
    final conv = c.read(gachaLanguageConverterProvider);
    expect(conv, isA<GachaLanguageConverter>());
    expect(c.read(langCatalogServiceProvider), isNotNull);
  });
}
