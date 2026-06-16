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

/// 從 Luckdraw spine 路徑取角色內部代號（`/Character/C_{Code}_.../`，小寫）；
/// 取不到回 null。
String? _luckdrawSpineCode(Map<dynamic, dynamic> luckdraw) {
  final skel = (luckdraw['LuckdrawSpineSkeletonData'] as String?) ?? '';
  final atlas = (luckdraw['LuckdrawSpineAtlas'] as String?) ?? '';
  final path = skel.isNotEmpty ? skel : atlas;
  final m = RegExp(
    r'/Character/C_([A-Za-z]+)_',
    caseSensitive: false,
  ).firstMatch(path);
  return m?.group(1)?.toLowerCase();
}

/// 從 `FormationRoleCard` URL 取代號（檔名 `T_IconRole_Pile_{code}_UI`，小寫，
/// 拼音命名系）；取不到回 null。
String? _formationCardCode(String url) {
  final m = RegExp(
    r'T_IconRole_Pile_([A-Za-z0-9]+)_UI',
    caseSensitive: false,
  ).firstMatch(url);
  return m?.group(1)?.toLowerCase();
}

/// 從 `RolePortrait` URL 取代號（檔名 `T_ActivityRole{code}`，小寫，拼音命名系）；
/// 取不到回 null。
String? _rolePortraitCode(String url) {
  final m = RegExp(
    r'T_ActivityRole([A-Za-z0-9]+)',
    caseSensitive: false,
  ).firstMatch(url);
  return m?.group(1)?.toLowerCase();
}

/// 從 `UiScenePerformanceABP` 路徑取代號（`..._Performance_{Code}_...`，小寫，
/// 內部代號命名系）；取不到回 null。代號可含數字（與另兩個 extractor 一致），
/// 以免 `Performance_Jiyan1_` 這類帶尾碼者整段解析失敗。
String? _performanceCode(String path) {
  final m = RegExp(
    r'Performance_([A-Za-z0-9]+)_',
    caseSensitive: false,
  ).firstMatch(path);
  return m?.group(1)?.toLowerCase();
}

/// 兩個角色代號是否視為同一角色：正規化後相等，或一方為另一方加上「純數字尾碼」
/// （容忍 `jiyan` / `jiyan1` 這類造型／變體編號差異）。**刻意不接受字母延伸**——
/// 否則 `ling` 會誤配 `lingyang`、`chang` 誤配 `changli` 等不同角色；任一為空、或
/// 較短者 < 4 字元一律回 false。
bool _characterCodeMatches(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  final (shorter, longer) = a.length <= b.length ? (a, b) : (b, a);
  if (shorter.length < 4 || !longer.startsWith(shorter)) return false;
  return RegExp(r'^[0-9]+$').hasMatch(longer.substring(shorter.length));
}

/// 判斷角色詳情 [body] 的 Luckdraw（喚取）立繪是否確實屬於該角色。
///
/// encore 部分角色的 Luckdraw spine 指向別的角色（資料錯位，如秧秧的 Luckdraw 指向
/// 尤諾）。本函式比對 Luckdraw 路徑內嵌的代號與角色三個含代號欄位（`FormationRoleCard`
/// ／`RolePortrait` 為拼音系、`UiScenePerformanceABP` 為內部代號系），**只要對得上
/// 任一基準即視為正確**——因 encore 各欄位皆各自可能錯、且 Luckdraw 命名慣例本身不
/// 一致（有時拼音、有時英文代號），三欄位涵蓋兩種命名系才能同時避免「英文別名誤殺」
/// 與漏判真錯位。
///
/// 保守原則：取不到 Luckdraw 代號、或三個基準皆缺時一律回 true（照常顯示）；只有
/// 「Luckdraw 代號存在＋至少一基準存在＋對不上全部基準」才回 false（隱藏）。
bool luckdrawBelongsToCharacter(Map<String, dynamic> body) {
  final lk = body['Luckdraw'];
  if (lk is! Map) return true;
  final luckCode = _luckdrawSpineCode(lk);
  if (luckCode == null || luckCode.isEmpty) return true;
  final anchors = <String>[
    for (final c in [
      _formationCardCode((body['FormationRoleCard'] as String?) ?? ''),
      _rolePortraitCode((body['RolePortrait'] as String?) ?? ''),
      _performanceCode((body['UiScenePerformanceABP'] as String?) ?? ''),
    ])
      if (c != null && c.isNotEmpty) c,
  ];
  if (anchors.isEmpty) return true;
  final belongs = anchors.any((a) => _characterCodeMatches(luckCode, a));
  if (!belongs) {
    _log.warning(
      'luckdraw mismatch id=${body['Id']} luck=$luckCode anchors=$anchors '
      '→ hidden',
    );
  }
  return belongs;
}

/// 單一 lang 的 encore 列表查表結果：icon（kind → id → URL）與 name→(id, kind)。
class EncoreCatalog {
  /// 建立 [EncoreCatalog]。
  const EncoreCatalog({
    required this.iconByKindId,
    this.nameByKindId = const {},
    this.idByName = const {},
  });

  /// kind（`kItemKind*`）→ `{resourceId → iconUrl}`。
  final Map<String, Map<int, String>> iconByKindId;

  /// kind（`kItemKind*`）→ `{resourceId → 物品名稱}`，與 [iconByKindId] 平行，
  /// 供資料語言轉換以 `resourceId` 取該語言名稱。
  final Map<String, Map<int, String>> nameByKindId;

  /// 物品名稱 → (resourceId, kind)；跨 kind union，同名以首個命中為準。
  /// 供第三方匯入回填缺 id 紀錄（見 `wuwa_tracker_importer`）。
  final Map<String, ({int id, String kind})> idByName;

  /// 查 [kind] 的 [id] 對應 icon URL；查無回 null。
  String? iconFor({required String kind, required int id}) =>
      iconByKindId[kind]?[id];

  /// 以物品名稱查 (resourceId, kind)；查無回 null。
  ({int id, String kind})? resolveByName(String name) => idByName[name];
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

  /// 對 [kinds] 內每個 kind 打 encore 列表端點一次，組 [EncoreCatalog]
  /// （icon 與 name→(id, kind) 兩表）。
  ///
  /// 單一 kind 端點失敗（非 2xx／逾時／解析爛）→ 該 kind 回空（不 throw），
  /// 該 kind 物品交由呼叫端落負取／解析器無命中。
  ///
  /// `idByName` 對「跨 kind 同名但不同 id」（如某角色與某武器同名）一律剔除該名稱：
  /// 名稱無法判定歸屬時寧可不解析（呼叫端落合成 fallback），也不臆測錯誤的 (id, kind)。
  Future<EncoreCatalog> fetchCatalog({
    required String lang,
    required Set<String> kinds,
    required http.Client client,
  }) async {
    final iconByKindId = <String, Map<int, String>>{};
    final nameByKindId = <String, Map<int, String>>{};
    final idByName = <String, ({int id, String kind})>{};
    final ambiguousNames = <String>{};
    final encLang = encoreLang(lang);
    for (final kind in kinds) {
      final seg = _kindToSegment[kind];
      if (seg == null) continue;
      final parsed = await _fetchCatalogKind(
        lang: encLang,
        kind: kind,
        seg: seg,
        client: client,
      );
      iconByKindId[kind] = parsed.icons;
      nameByKindId[kind] = {
        for (final e in parsed.names.entries) e.value: e.key,
      };
      parsed.names.forEach((name, id) {
        if (ambiguousNames.contains(name)) return;
        final existing = idByName[name];
        if (existing == null) {
          idByName[name] = (id: id, kind: kind);
        } else if (existing.id != id) {
          // 同名跨 kind 對到不同 id → 無法由名稱判定，剔除並標記，後續同名一律略過。
          idByName.remove(name);
          ambiguousNames.add(name);
        }
      });
    }
    if (ambiguousNames.isNotEmpty) {
      _log.warning(
        'catalog: ${ambiguousNames.length} ambiguous name(s) excluded from '
        'idByName (same name across kinds) e.g. '
        '${ambiguousNames.take(5).toList()}',
      );
    }
    return EncoreCatalog(
      iconByKindId: iconByKindId,
      nameByKindId: nameByKindId,
      idByName: idByName,
    );
  }

  /// 抓單一 kind 的列表並解析 `{id → iconUrl}` 與 `{name → id}`；任何失敗回兩空 map。
  Future<({Map<int, String> icons, Map<String, int> names})> _fetchCatalogKind({
    required String lang,
    required String kind,
    required String seg,
    required http.Client client,
  }) async {
    const empty = (icons: <int, String>{}, names: <String, int>{});
    final url = Uri.parse('$_encoreApiBase/$lang/$seg');
    try {
      final res = await client.get(url).timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        _log.warning(
          'catalog kind=$seg non-2xx status=${res.statusCode} lang=$lang',
        );
        return empty;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final (listKey, iconKey) = switch (kind) {
        kItemKindCharacter => ('roleList', 'RoleHeadIcon'),
        kItemKindWeapon => ('weapons', 'Icon'),
        _ => ('itemList', 'Icon'),
      };
      final list = body[listKey];
      if (list is! List) return empty;
      final icons = <int, String>{};
      final names = <String, int>{};
      for (final e in list) {
        if (e is! Map<String, dynamic>) continue;
        final id = e['Id'];
        if (id is! int) continue;
        final icon = e[iconKey];
        if (icon is String && icon.isNotEmpty) icons[id] = icon;
        final name = e['Name'];
        if (name is String && name.isNotEmpty) {
          names.putIfAbsent(name, () => id);
        }
      }
      _log.info(
        'catalog kind=$seg lang=$lang icons=${icons.length} names=${names.length}',
      );
      return (icons: icons, names: names);
    } catch (e) {
      _log.warning('catalog kind=$seg failed lang=$lang err=$e');
      return empty;
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
      final hasLuckdrawData =
          kind == kItemKindCharacter &&
          lk is Map &&
          ((lk['LuckdrawSpineSkeletonData'] as String?)?.isNotEmpty ?? false);
      // encore 部分角色的 Luckdraw 指向別的角色（資料錯位）→ 驗證歸屬，錯位即視為
      // 無喚取立繪（chip 不出現、擷取不觸發）。
      final hasLuckdraw = hasLuckdrawData && luckdrawBelongsToCharacter(body);
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
