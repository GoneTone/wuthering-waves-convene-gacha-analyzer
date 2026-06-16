import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/lang_catalog.dart';

/// 提供 [GachaLanguageConverter]，其 `ensureCatalog` 接 [langCatalogServiceProvider]。
final gachaLanguageConverterProvider = Provider<GachaLanguageConverter>((ref) {
  final service = ref.watch(langCatalogServiceProvider);
  return GachaLanguageConverter(ensureCatalog: service.ensure);
});
