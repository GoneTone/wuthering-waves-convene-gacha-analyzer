import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

/// 角色類型聚合鍵；以 `kind:` 前綴與遊戲原始 resourceType 字串（角色／Character…）
/// 區隔，永不碰撞。
const kItemKindCharacter = 'kind:character';

/// 武器類型聚合鍵；`kind:` 前綴的用意參見 [kItemKindCharacter]。
const kItemKindWeapon = 'kind:weapon';

/// 道具類型聚合鍵（鳴潮喚取的第三類；如保底墊的「塵雲旋臂」）。
const kItemKindItem = 'kind:item';

/// 各語系 `resourceType` 原始字串 → canonical kind 的對照表。
///
/// `resourceType` 由 API 回應提供、字串隨 `languageCode` 變化，故需涵蓋各語系
/// 文案（zh-Hant／zh-Hans／en／ja）。查無者由 [itemTypeKeyOf] fallback 原字串。
const _resourceTypeToKind = <String, String>{
  // 角色
  '角色': kItemKindCharacter,
  'Character': kItemKindCharacter,
  'キャラクター': kItemKindCharacter,
  // 武器
  '武器': kItemKindWeapon,
  'Weapon': kItemKindWeapon,
  // 道具
  '道具': kItemKindItem,
  'Item': kItemKindItem,
  'アイテム': kItemKindItem,
};

/// 解析單筆 [r] 的類型聚合鍵：依 API 給的 [GachaRecord.resourceType]（權威類型
/// 欄位）映射 canonical kind（角色／武器／道具），跨語系自然合併；查無時 fallback
/// 回原始 `resourceType` 字串（含空字串）。
///
/// 註：此處用 `resourceType` 是做「類型分類」，與「是否有圖」（spec D7，靠圖片
/// 索引抓取結果）是不同問題，兩者不可混用。
String itemTypeKeyOf(GachaRecord r) =>
    _resourceTypeToKind[r.resourceType] ?? r.resourceType;

/// 將 [key]（[itemTypeKeyOf] 產物）轉成顯示用在地化標籤：canonical 鍵套 [l]
/// 譯名、空字串顯示「未知」、其餘原始字串 fallback 原樣顯示。
String itemTypeKeyLabel(String key, AppLocalizations l) => switch (key) {
  kItemKindCharacter => l.kindCharacter,
  kItemKindWeapon => l.kindWeapon,
  kItemKindItem => l.kindItem,
  '' => l.kindUnknown,
  _ => key,
};
