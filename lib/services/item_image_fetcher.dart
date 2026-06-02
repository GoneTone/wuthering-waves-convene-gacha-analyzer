import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// Logger 實例（item_image.fetcher 命名空間）。
final _log = Logger('item_image.fetcher');

/// encore API 支援的語系白名單（path 參數 `{lang}` 的合法值）。
const _encoreLangs = {
  'en',
  'zh-Hans',
  'zh-Hant',
  'ja',
  'ko',
  'de',
  'es',
  'fr',
  'id',
  'pt',
  'ru',
  'th',
  'vi',
};

/// 將擷取到的 [languageCode] 映射為 encore `{lang}` 路徑參數：命中白名單原樣
/// 回傳、否則 fallback `'en'`（並記 warning）。**一律帶物品擷取語言、不看 app UI 語言。**
String encoreLang(String languageCode) {
  if (_encoreLangs.contains(languageCode)) return languageCode;
  _log.warning('encoreLang unknown code=$languageCode → en');
  return 'en';
}

/// 組該物品的 encore.moe 前台頁 URL（id-based ＋ `?lang=`，已驗證可用）。
/// 角色 `/character/{id}`、武器 `/weapon/{id}`、道具 `/item/{id}`（道具一般不可點）。
String encoreItemUrl({
  required String kind,
  required int resourceId,
  required String lang,
}) {
  final seg = _kindToSegment[kind] ?? 'character';
  return 'https://encore.moe/$seg/$resourceId?lang=${encoreLang(lang)}';
}

/// encore API base（list／detail 共用）。
const _encoreApiBase = 'https://api-v2.encore.moe/api';

/// kind → encore 端點路徑段。
const _kindToSegment = {
  kItemKindCharacter: 'character',
  kItemKindWeapon: 'weapon',
  kItemKindItem: 'item',
};

/// 單一 lang 的 encore 列表查表結果：kind → (resourceId → icon URL)。
class EncoreCatalog {
  /// 建立 [EncoreCatalog]。
  const EncoreCatalog({required this.iconByKindId});

  /// kind（`kItemKind*`）→ `{resourceId → iconUrl}`。
  final Map<String, Map<int, String>> iconByKindId;

  /// 查 [kind] 的 [id] 對應 icon URL；查無回 null。
  String? iconFor({required String kind, required int id}) =>
      iconByKindId[kind]?[id];
}

/// 單一造型（skin）的 encore 原始欄位（fetcher 暫態，repo 映射為 `ItemSkin`）。
typedef EncoreSkin = ({
  String formationCard,
  String name,
  String subDecName,
  String bgDescription,
});

/// dialog 用的單一 lang 詳情（只取原神版版面所需欄位）。
class EncoreItemDetail {
  /// 建立 [EncoreItemDetail]。
  const EncoreItemDetail({
    required this.intro,
    required this.elementName,
    required this.weaponTypeName,
    required this.skins,
    required this.iconHd,
    this.hasLuckdraw = false,
  });

  /// 簡介：角色 `Introduction.Content`／武器 `BgDescription`（可能含 HTML）。
  final String intro;

  /// 元素名：角色 `ElementName`；武器／道具為空。
  final String elementName;

  /// 武器類型名：角色／武器 `WeaponTypeName`；道具為空。
  final String weaponTypeName;

  /// 造型清單：角色 `Skins[]`（每個有 FormationRoleCard／Name／SubDecName／
  /// BgDescription）；武器／道具為空。
  final List<EncoreSkin> skins;

  /// 高畫質 icon URL：角色 `Skins[0].RoleHeadIconLarge`（256px，取代列表的 150px
  /// `RoleHeadIcon`）；武器／道具為空（其列表 icon 已足夠，由呼叫端沿用）。
  final String iconHd;

  /// 角色是否有喚取（Luckdraw）Spine 立繪：`Luckdraw.LuckdrawSpineSkeletonData`
  /// 存在且非空為 true；武器／道具恆 false。
  final bool hasLuckdraw;
}

/// 取物品圖片的 fetcher：走 encore.moe 列表／詳情，外加通用圖檔下載。
class ItemImageFetcher {
  /// 建立 [ItemImageFetcher]，可調整下載並行度與逾時。
  ItemImageFetcher({
    this.downloadConcurrency = 8,
    this.timeout = const Duration(seconds: 10),
  });

  /// download 階段 worker-pool 同時 in-flight 上限。
  final int downloadConcurrency;

  /// 單次 HTTP 請求超時。
  final Duration timeout;

  /// 對 [kinds] 內每個 kind 打 encore 列表端點一次，組 [EncoreCatalog]。
  ///
  /// 單一 kind 端點失敗（非 2xx／逾時／解析爛）→ 該 kind 回空 map（不 throw），
  /// 該 kind 物品交由呼叫端落負取。
  Future<EncoreCatalog> fetchCatalog({
    required String lang,
    required Set<String> kinds,
    required http.Client client,
  }) async {
    final out = <String, Map<int, String>>{};
    final encLang = encoreLang(lang);
    for (final kind in kinds) {
      final seg = _kindToSegment[kind];
      if (seg == null) continue;
      out[kind] = await _fetchCatalogKind(
        lang: encLang,
        kind: kind,
        seg: seg,
        client: client,
      );
    }
    return EncoreCatalog(iconByKindId: out);
  }

  /// 抓單一 kind 的列表並解析 `{id → iconUrl}`；任何失敗回空 map。
  Future<Map<int, String>> _fetchCatalogKind({
    required String lang,
    required String kind,
    required String seg,
    required http.Client client,
  }) async {
    final url = Uri.parse('$_encoreApiBase/$lang/$seg');
    try {
      final res = await client.get(url).timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        _log.warning(
          'catalog kind=$seg non-2xx status=${res.statusCode} lang=$lang',
        );
        return const {};
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final (listKey, iconKey) = switch (kind) {
        kItemKindCharacter => ('roleList', 'RoleHeadIcon'),
        kItemKindWeapon => ('weapons', 'Icon'),
        _ => ('itemList', 'Icon'),
      };
      final list = body[listKey];
      if (list is! List) return const {};
      final map = <int, String>{};
      for (final e in list) {
        if (e is! Map<String, dynamic>) continue;
        final id = e['Id'];
        final icon = e[iconKey];
        if (id is int && icon is String && icon.isNotEmpty) map[id] = icon;
      }
      _log.info('catalog kind=$seg lang=$lang n=${map.length}');
      return map;
    } catch (e) {
      _log.warning('catalog kind=$seg failed lang=$lang err=$e');
      return const {};
    }
  }

  /// 抓 [resourceId] 的 encore 詳情（角色／武器）解析 [EncoreItemDetail]。
  ///
  /// `kItemKindItem` 不打 API（道具 id 與 `/item` 體系不符）直接回 null；HTTP 非
  /// 2xx／逾時／解析爛一律回 null（不 throw），呼叫端據此不寫 `detailByLang`。
  Future<EncoreItemDetail?> fetchItemDetail({
    required int resourceId,
    required String kind,
    required String lang,
    required http.Client client,
  }) async {
    final seg = _kindToSegment[kind];
    if (seg == null || kind == kItemKindItem) return null;
    final encLang = encoreLang(lang);
    final url = Uri.parse('$_encoreApiBase/$encLang/$seg/$resourceId');
    try {
      final res = await client.get(url).timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        _log.warning(
          'detail kind=$seg id=$resourceId non-2xx status=${res.statusCode} '
          'lang=$encLang',
        );
        return null;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final String intro;
      final List<EncoreSkin> skins;
      final String iconHd;
      if (kind == kItemKindCharacter) {
        final introObj = body['Introduction'];
        intro = (introObj is Map<String, dynamic>)
            ? (introObj['Content'] as String? ?? '')
            : '';
        final skinsRaw = body['Skins'];
        final skinMaps = (skinsRaw is List)
            ? skinsRaw.whereType<Map<String, dynamic>>().toList()
            : const <Map<String, dynamic>>[];
        skins = [
          for (final s in skinMaps)
            (
              formationCard: s['FormationRoleCard'] as String? ?? '',
              name: s['Name'] as String? ?? '',
              subDecName: s['SubDecName'] as String? ?? '',
              bgDescription: s['BgDescription'] as String? ?? '',
            ),
        ];
        iconHd = skinMaps.isNotEmpty
            ? (skinMaps.first['RoleHeadIconLarge'] as String? ?? '')
            : '';
      } else {
        intro = body['BgDescription'] as String? ?? '';
        skins = const [];
        iconHd = '';
      }
      final lk = body['Luckdraw'];
      final hasLuckdraw =
          kind == kItemKindCharacter &&
          lk is Map &&
          ((lk['LuckdrawSpineSkeletonData'] as String?)?.isNotEmpty ?? false);
      final detail = EncoreItemDetail(
        intro: intro,
        elementName: body['ElementName'] as String? ?? '',
        weaponTypeName: body['WeaponTypeName'] as String? ?? '',
        skins: skins,
        iconHd: iconHd,
        hasLuckdraw: hasLuckdraw,
      );
      _log.info(
        'detail hit kind=$seg id=$resourceId lang=$encLang '
        'intro=${intro.isNotEmpty} skins=${skins.length} '
        'iconHd=${iconHd.isNotEmpty} luckdraw=$hasLuckdraw',
      );
      return detail;
    } catch (e) {
      _log.warning(
        'detail kind=$seg id=$resourceId failed lang=$encLang err=$e',
      );
      return null;
    }
  }

  /// GET [url] 的圖檔 bytes；任何失敗（非 2xx / 例外）回 null，caller 不寫檔
  /// 並於下次更新重試。
  Future<Uint8List?> downloadImage(String url, http.Client client) async {
    try {
      final res = await client.get(Uri.parse(url)).timeout(timeout);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return res.bodyBytes;
      }
      _log.warning(
        'download non-2xx status=${res.statusCode} url=${sanitizeUrl(url)}',
      );
      return null;
    } catch (e) {
      _log.warning('download failed url=${sanitizeUrl(url)} err=$e');
      return null;
    }
  }
}
