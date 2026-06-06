import 'package:flutter/foundation.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

/// 附帶計算後序號的喚取紀錄行（表格顯示用）。
@immutable
class RecordRow {
  /// 建立 [RecordRow]。
  const RecordRow({
    required this.record,
    required this.totalIndex,
    required this.mainPityIndex,
    required this.itemTypeKey,
  });

  /// 原始喚取紀錄。
  final GachaRecord record;

  /// 該抽在該卡池所有抽中的累積序號（asc）；最舊 = 1，最新 = N。
  final int totalIndex;

  /// 距上一個「主稀有度」紀錄後的第幾抽（含自己）。「主稀有度」由
  /// [buildRecordRows.mainRank] 決定（鳴潮所有卡池主稀有度皆 5★）。
  /// 該主稀有度那一抽 = 抵達該主稀有度的累積值；下一抽從 1 重新累計。
  /// 若該卡池從未出現符合主稀有度的紀錄，則持續累計，與 totalIndex 相同。
  final int mainPityIndex;

  /// 跨語言無關的類型聚合鍵（[itemTypeKeyOf] 產物：kind:character / kind:weapon
  /// ／kind:item／未知字串 fallback）。供表格類型欄顯示、排序、篩選共用。
  final String itemTypeKey;
}

/// records 必須以時間 desc 排序（與 gacha_repository 一致）。
/// 回傳順序與 records 相同（desc by time）。
/// [index] 提供 encore catalog 歸屬的 kind，供 [itemTypeKeyOf] 語言無關分類。
/// [mainRank] 預設 5（鳴潮卡池主稀有度）。
List<RecordRow> buildRecordRows(
  List<GachaRecord> records,
  ItemImageIndex index, {
  int mainRank = 5,
}) {
  if (records.isEmpty) return const [];
  // 以 asc 順序累計再 reverse，保持輸出順序與輸入一致。
  final asc = records.reversed.toList(growable: false);
  final out = <RecordRow>[];
  var total = 0;
  var pity = 0;
  for (final r in asc) {
    total++;
    pity++;
    out.add(
      RecordRow(
        record: r,
        totalIndex: total,
        mainPityIndex: pity,
        itemTypeKey: itemTypeKeyOf(r, index),
      ),
    );
    if (r.qualityLevel == mainRank) {
      pity = 0;
    }
  }
  return out.reversed.toList(growable: false);
}
