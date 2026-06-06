import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';

/// 角色類型聚合鍵；以 `kind:` 前綴與遊戲原始 resourceType 字串（角色／Character…）
/// 區隔，永不碰撞。
const kItemKindCharacter = 'kind:character';

/// 武器類型聚合鍵；`kind:` 前綴的用意參見 [kItemKindCharacter]。
const kItemKindWeapon = 'kind:weapon';

/// 道具類型聚合鍵（鳴潮喚取的第三類；如保底墊的「塵雲旋臂」）。
const kItemKindItem = 'kind:item';

/// 解析單筆 [r] 的類型聚合鍵：以 [index] 的 encore 歸屬 kind（`resourceId → kind`）
/// 判定（角色／武器／道具），跨語系天然一致；index 無此 id 或尚未分類（kind==null）
/// 時 fallback 回原始 `resourceType` 字串（含空字串）。
///
/// 取代前身版本的 `resourceType` 語言對應表（只涵蓋 4 語系、不可靠）；改用語言無關
/// 的 encore 清單歸屬，等價於原神版 `itemTypeKeyOf(r, HoYoWikiIndex)`。
String itemTypeKeyOf(GachaRecord r, ItemImageIndex index) =>
    index.lookupImage(r.resourceId)?.kind ?? r.resourceType;

/// 將 [key]（[itemTypeKeyOf] 產物）轉成顯示用在地化標籤：canonical 鍵套 [l]
/// 譯名、空字串顯示「未知」、其餘原始字串 fallback 原樣顯示。
String itemTypeKeyLabel(String key, AppLocalizations l) => switch (key) {
  kItemKindCharacter => l.kindCharacter,
  kItemKindWeapon => l.kindWeapon,
  kItemKindItem => l.kindItem,
  '' => l.kindUnknown,
  _ => key,
};
