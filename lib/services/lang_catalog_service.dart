import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';

/// 解析某語言的物品目錄：先讀本地快取，缺則抓 encore 三清單、建檔、回傳。
/// 同一實例以記憶體 memo 避免單次轉換內重複讀檔／抓取。
class LangCatalogService {
  /// 建立 [LangCatalogService]。
  LangCatalogService({
    required this.storage,
    required this.fetcher,
    required this.clientFactory,
  });

  /// Logger 實例。
  static final _log = Logger('wish.langconvert.catalog');

  /// 目錄持久化。
  final LangCatalogStorage storage;

  /// encore 抓取器。
  final ItemImageFetcher fetcher;

  /// 建立 http client 的工廠（每次抓取用後即關）。
  final http.Client Function() clientFactory;

  /// 單次執行的記憶體快取；刻意不設過期／刷新路徑（disk 為真相，spec 非目標），
  /// 來回切換資料語言會重用已抓的目錄而不重抓。
  final Map<String, LangCatalog> _memo = {};

  /// 抓三清單時用的 kind 集合。
  static const _allKinds = {kItemKindCharacter, kItemKindWeapon, kItemKindItem};

  /// 取得 [lang] 目錄：memo → 本地 → 抓取並落地。網路失敗時拋出（呼叫端決定如何處理）。
  ///
  /// [forceRefresh] 為 true 時略過 memo／本地快取，強制重抓並覆寫（供「目錄過期、
  /// 出現新物品」時刷新；見 `GachaLanguageConverter` 的未命中自動刷新）。
  Future<LangCatalog> ensure(String lang, {bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final memo = _memo[lang];
      if (memo != null) return memo;

      final cached = await storage.load(lang);
      if (cached != null) {
        _memo[lang] = cached;
        _log.fine('lang catalog from disk lang=$lang');
        return cached;
      }
    }

    final client = clientFactory();
    try {
      final catalog = await fetcher.fetchCatalog(
        lang: lang,
        kinds: _allKinds,
        client: client,
      );
      final lc = LangCatalog.fromEncore(
        lang: lang,
        fetchedAt: DateTime.now().toUtc(),
        catalog: catalog,
      );
      await storage.save(lc);
      _memo[lang] = lc;
      _log.info('lang catalog fetched lang=$lang items=${lc.byId.length}');
      return lc;
    } finally {
      client.close();
    }
  }
}
