import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';

/// 提供建構好的 [LangCatalogService]（注入 storage、fetcher、client 工廠）。
final langCatalogServiceProvider = Provider<LangCatalogService>((ref) {
  final cacheDir = ref.watch(itemImageCacheDirProvider);
  final fetcher = ref.watch(itemImageFetcherProvider);
  return LangCatalogService(
    storage: LangCatalogStorage(cacheDir),
    fetcher: fetcher,
    clientFactory: http.Client.new,
  );
});
