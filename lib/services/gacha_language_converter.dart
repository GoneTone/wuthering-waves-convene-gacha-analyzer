import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 轉換結果計數（可相加聚合多帳號）。
class LangConvertResult {
  /// 建立 [LangConvertResult]。
  const LangConvertResult({
    this.total = 0,
    this.converted = 0,
    this.backfilledId = 0,
    this.unresolved = 0,
  });

  /// 處理總筆數。
  final int total;

  /// 成功轉換筆數（含回查補 ID）。
  final int converted;

  /// 其中靠名稱回查補上真實 ID 的筆數。
  final int backfilledId;

  /// 無法轉換、保持原狀的筆數。
  final int unresolved;

  /// 逐項相加。
  LangConvertResult operator +(LangConvertResult o) => LangConvertResult(
    total: total + o.total,
    converted: converted + o.converted,
    backfilledId: backfilledId + o.backfilledId,
    unresolved: unresolved + o.unresolved,
  );
}

/// 把一份 [BannerStorage] 的紀錄名稱統一成目標語言。
///
/// 只改 `name`／`resourceId`（回查補）／`languageCode`，不動 `resourceType`
/// （類型標籤跟 UI 語言，見 spec D8）。轉不了的紀錄完全保持原狀。
class GachaLanguageConverter {
  /// 建立 [GachaLanguageConverter]；[ensureCatalog] 取得某語言目錄（生產環境接
  /// `LangCatalogService.ensure`，測試注入 fake）。
  GachaLanguageConverter({required this.ensureCatalog});

  /// Logger 實例。
  static final _log = Logger('wish.langconvert');

  /// 取得某語言目錄的解析器。
  final Future<LangCatalog> Function(String lang) ensureCatalog;

  /// 轉換 [data] 為 [targetLang]，回傳新的存檔與計數摘要。
  Future<({BannerStorage data, LangConvertResult result})> convert(
    BannerStorage data,
    String targetLang,
  ) async {
    final targetCat = await ensureCatalog(targetLang);

    // 蒐集需回查的紀錄之原語言（合成／負值 id，或目標目錄查無 id）。
    // 已是目標語言者免轉、不需來源目錄。
    final srcLangs = <String>{};
    for (final list in data.banners.values) {
      for (final r in list) {
        if (r.languageCode == targetLang) continue;
        final needsBackfill =
            r.resourceId <= 0 || !targetCat.byId.containsKey(r.resourceId);
        if (needsBackfill && r.languageCode.isNotEmpty) {
          srcLangs.add(r.languageCode);
        }
      }
    }
    final srcCats = <String, LangCatalog>{};
    for (final lang in srcLangs) {
      srcCats[lang] = await ensureCatalog(lang);
    }

    var result = const LangConvertResult();
    final newBanners = <String, List<GachaRecord>>{};
    data.banners.forEach((key, list) {
      final out = <GachaRecord>[];
      for (final r in list) {
        result = result + const LangConvertResult(total: 1);

        // 已是目標語言：免轉、原樣保留、不計入「已轉換」（同語言不記錄）。
        if (r.languageCode == targetLang) {
          out.add(r);
          continue;
        }

        // 直接以 resourceId 對應目標名。
        final direct = r.resourceId > 0 ? targetCat.byId[r.resourceId] : null;
        if (direct != null) {
          out.add(r.copyWith(name: direct.name, languageCode: targetLang));
          result = result + const LangConvertResult(converted: 1);
          continue;
        }

        // 以原名 + 原語言回查真實 id，再以目標目錄轉名。
        final realId = srcCats[r.languageCode]?.idByName[r.name];
        final viaBackfill = realId != null ? targetCat.byId[realId] : null;
        if (realId != null && viaBackfill != null) {
          out.add(
            r.copyWith(
              resourceId: realId,
              name: viaBackfill.name,
              languageCode: targetLang,
            ),
          );
          result =
              result + const LangConvertResult(converted: 1, backfilledId: 1);
          continue;
        }

        // 轉不了：完全保持原狀。
        out.add(r);
        result = result + const LangConvertResult(unresolved: 1);
      }
      newBanners[key] = out;
    });

    _log.info(
      'converted playerId=${sanitizeUid(data.playerId)} target=$targetLang '
      'total=${result.total} converted=${result.converted} '
      'backfilledId=${result.backfilledId} unresolved=${result.unresolved}',
    );
    return (data: data.copyWith(banners: newBanners), result: result);
  }
}
