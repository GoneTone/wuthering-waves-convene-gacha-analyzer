import 'package:flutter/foundation.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

/// 時間軸條目：一筆目標稀有度紀錄 + 距該卡池上一筆同稀有度的抽數。
@immutable
class TimelineEntry {
  /// 建立 [TimelineEntry]。
  const TimelineEntry({
    required this.name,
    required this.gachaType,
    required this.time,
    required this.pullsSincePrev,
    this.sourceRecord,
  });

  /// 物品名稱。
  final String name;

  /// 所屬卡池類型字串（持 cardPoolType 字串，如 `'1'`、`'8'`）。
  final String gachaType;

  /// 抽取時間。
  final DateTime time;

  /// 距該卡池上一筆相同稀有度的抽數（含自己）。
  final int pullsSincePrev;

  /// 原始 [GachaRecord]，用於 UI 顯示物品 icon；歷史 callsite 未提供時為 null。
  final GachaRecord? sourceRecord;
}

/// 從單一卡池 desc-by-time 排序的 records 萃取 [targetRank] 條目，
/// 並計算每筆距該卡池上一筆 [targetRank] 的抽數。
/// 回傳結果依時間 desc（最新在前）。
List<TimelineEntry> buildTimelineEntries(
  List<GachaRecord> records, {
  int targetRank = 5,
}) {
  final asc = records.reversed.toList(growable: false);
  final out = <TimelineEntry>[];
  var pull = 0;
  for (final r in asc) {
    pull++;
    if (r.qualityLevel == targetRank) {
      out.add(
        TimelineEntry(
          name: r.name,
          gachaType: r.cardPoolType,
          time: r.time,
          pullsSincePrev: pull,
          sourceRecord: r,
        ),
      );
      pull = 0;
    }
  }
  return out.reversed.toList(growable: false);
}

/// 跨卡池：合併所有卡池的 entries，依時間 desc 排序。
/// 每個卡池用 [rankFor] 決定要萃取的稀有度。
/// 每筆 entry 的 pullsSincePrev 仍以「該 entry 所屬卡池的上一筆同稀有度」為基準，
/// 不是「跨卡池上一筆」——保底計算永遠 per-pool。
List<TimelineEntry> buildTimelineEntriesAcrossBanners(
  Map<String, List<GachaRecord>> banners, {
  required int Function(String gachaType) rankFor,
}) {
  final out = <TimelineEntry>[];
  for (final entry in banners.entries) {
    out.addAll(
      buildTimelineEntries(entry.value, targetRank: rankFor(entry.key)),
    );
  }
  out.sort((a, b) => b.time.compareTo(a.time));
  return out;
}

/// 從 desc 排序的 records 計算「最後一個 [rank] 之後又抽了多少抽」。
/// 若無任何符合的，回傳 records.length（視為從頭累計）。
int pullsSinceLastRanked(List<GachaRecord> records, {required int rank}) {
  var count = 0;
  for (final r in records) {
    if (r.qualityLevel == rank) return count;
    count++;
  }
  return count;
}

/// 跨卡池：找跨卡池最新「該卡池主稀有度」記錄，計算其後跨全部卡池 record 總數。
/// 每個卡池用 [rankFor] 決定主稀有度。
///
/// 鳴潮記錄無唯一 id 且同十連同秒，故同池內以**清單索引**（該筆在記錄清單中的
/// 位置）定位該 5★，計其前段（desc 排序中排在前 = 抽得較晚）的 record 數。
/// 跨池同秒以 cardPoolType key 字串比較做穩定 tie-break（較大者視為較新），
/// 避免「同秒」造成定位不穩定。
/// 若所有卡池皆無對應稀有度，回傳全部卡池 record 數總和。
int pullsSinceLastRankedAcrossBanners(
  Map<String, List<GachaRecord>> banners, {
  required int Function(String gachaType) rankFor,
}) {
  // Phase 1：找跨卡池最新的目標稀有度——記錄其所在池 key、在該池清單中的索引、時間。
  String? latestPool;
  int? latestIndex;
  DateTime? latestTime;
  for (final entry in banners.entries) {
    final rank = rankFor(entry.key);
    final records = entry.value;
    for (var i = 0; i < records.length; i++) {
      if (records[i].qualityLevel == rank) {
        // records 已 desc，該池第一筆目標稀有度即該池最新一筆。
        final isNewer =
            latestTime == null ||
            records[i].time.isAfter(latestTime) ||
            (records[i].time.isAtSameMomentAs(latestTime) &&
                entry.key.compareTo(latestPool!) > 0);
        if (isNewer) {
          latestTime = records[i].time;
          latestPool = entry.key;
          latestIndex = i;
        }
        break;
      }
    }
  }
  // 沒有任何符合稀有度：回傳跨卡池 record 總數。
  if (latestTime == null) {
    var total = 0;
    for (final records in banners.values) {
      total += records.length;
    }
    return total;
  }
  // Phase 2：計數。
  // - 目標稀有度所在卡池：清單索引前的筆數（desc 中 = 抽得較晚）即 [latestIndex]。
  // - 其他卡池：用 isAfter 嚴格比較（同秒以 tie-break 已歸屬到 latestPool，不重複算）。
  var count = latestIndex!;
  for (final entry in banners.entries) {
    if (entry.key == latestPool) continue;
    for (final r in entry.value) {
      if (r.time.isAfter(latestTime)) {
        count++;
      } else {
        break; // desc records，可以提早結束。
      }
    }
  }
  return count;
}
