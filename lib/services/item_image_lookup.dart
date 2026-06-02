import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';

/// 判定 [record] 是否有可顯示的角色 icon（D7 權威判定）。
///
/// 唯一依據：[index].lookupImage(resourceId) 有成功下載的 icon（非負取、非缺）。
/// 一律不靠 resourceId 位數或 resourceType 字串推定。所有 icon 消費點與「可否點開
/// 詳情」一律呼叫此函式；無圖（含負取/未抓）走 placeholder。
bool hasItemImage(ItemImageIndex index, GachaRecord record) {
  final entry = index.lookupImage(record.resourceId);
  return entry?.hasIcon ?? false;
}
