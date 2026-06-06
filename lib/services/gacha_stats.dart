import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

/// 單一卡池的喚取統計摘要。
class GachaStats {
  /// 建立 [GachaStats]。
  const GachaStats({
    required this.total,
    required this.fiveStarCount,
    required this.fourStarCount,
    required this.threeStarCount,
    required this.byItemType,
  });

  /// 總抽數。
  final int total;

  /// 5★ 數量。
  final int fiveStarCount;

  /// 4★ 數量。
  final int fourStarCount;

  /// 3★ 數量。
  final int threeStarCount;

  /// 各物品類型的抽數，key = [itemTypeKeyOf] 產物（canonical 鍵如 `kind:character`／
  /// `kind:item`，或未知 resourceType 的 fallback 原始字串）。
  final Map<String, int> byItemType;

  /// 計算 [n] 在總抽數中的占比；總抽數為 0 時回傳 0.0。
  double _rate(int n) => total == 0 ? 0.0 : n / total;

  /// 5★ 出率。
  double get fiveStarRate => _rate(fiveStarCount);

  /// 4★ 出率。
  double get fourStarRate => _rate(fourStarCount);

  /// 3★ 出率。
  double get threeStarRate => _rate(threeStarCount);

  /// 依 count desc 排序的 entries（給 pie / legend 用）。
  List<MapEntry<String, int>> sortedItemTypes() {
    final list = byItemType.entries.toList();
    list.sort((a, b) => b.value.compareTo(a.value));
    return list;
  }
}

/// 喚取統計 logger。
final _log = Logger('gacha.stats');

/// 從 [records] 計算統計摘要；類型聚合以 [index] 的 encore catalog 歸屬 kind
/// 判定（[itemTypeKeyOf]），跨語系天然一致；index 無此 id 或尚未分類時 fallback
/// 原始 `resourceType` 字串。
GachaStats computeGachaStats(List<GachaRecord> records, ItemImageIndex index) {
  var five = 0, four = 0, three = 0;
  var canonical = 0, fallback = 0;
  final byItemType = <String, int>{};
  for (final r in records) {
    switch (r.qualityLevel) {
      case 5:
        five++;
      case 4:
        four++;
      case 3:
        three++;
    }
    final key = itemTypeKeyOf(r, index);
    if (key == kItemKindCharacter ||
        key == kItemKindWeapon ||
        key == kItemKindItem) {
      canonical++;
    } else {
      fallback++;
    }
    byItemType[key] = (byItemType[key] ?? 0) + 1;
  }
  if (records.isNotEmpty) {
    _log.fine(
      'computeGachaStats: total=${records.length} '
      'canonicalKind=$canonical rawFallback=$fallback',
    );
  }
  return GachaStats(
    total: records.length,
    fiveStarCount: five,
    fourStarCount: four,
    threeStarCount: three,
    byItemType: byItemType,
  );
}
