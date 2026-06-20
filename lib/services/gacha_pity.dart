import 'package:flutter/foundation.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

/// 單一卡池的保底狀態計算結果。
@immutable
class Pity {
  /// 建立 [Pity]。
  const Pity({
    required this.current,
    required this.threshold,
    required this.lastRecordAt,
    required this.averageInterval,
    required this.hitCount,
    required this.completedInterval,
  });

  /// 距上次保底重置事件（`qualityLevel >= rank`，含更高星）已抽幾抽。沒有則 =
  /// 總抽數。供距離／進度使用：例如算 4★ 保底時，中途的 5★ 也會重置此計數。
  final int current;

  /// 該卡池的保底閾值。
  final int threshold;

  /// 上次保底重置事件（`qualityLevel >= rank`）的紀錄時間；用於判斷「暫無 N★」。
  final DateTime? lastRecordAt;

  /// 已落地週期的平均抽數，hitCount == 0 時為 null。
  /// 語意為「平均幾抽出一張剛好 rank 星」（中途更高星算進間隔、不視為命中），
  /// 與 [hitCount]／[completedInterval] 同採 `== rank`，刻意與 [current] 的
  /// `>= rank` 重置語意解耦。
  final double? averageInterval;

  /// 剛好 rank 星（`== rank`）在 records 中的總命中次數，即平均間隔的分母。
  final int hitCount;

  /// 平均間隔的分子：已落地（剛好 rank 星）週期的總抽數，
  /// = `records.length − 距上次 == rank 命中的抽數`。跨卡池合併平均時取用。
  final int completedInterval;

  /// 保底進度（0.0–1.0），超過閾值時夾到 1.0。
  double get progress {
    if (threshold <= 0) return 0;
    final raw = current / threshold;
    return raw > 1 ? 1.0 : raw;
  }

  /// 距保底還剩幾抽；已超過閾值時為 0。
  int get distance {
    final d = threshold - current;
    return d < 0 ? 0 : d;
  }
}

/// 計算單一卡池對指定 [rank] 的保底狀態。預設 rank=5，4★ pity 傳 rank=4。
///
/// 距離／進度（[Pity.current]）以「`qualityLevel >= rank`」為重置事件 ——
/// 抽到更高星也滿足該 rank 的保底，會一併重置（如 4★ 保底遇到 5★ 即重置）。
/// 平均間隔（[Pity.averageInterval]）則以「`== rank`」為命中，刻意與距離解耦，
/// 維持「平均幾抽出一張剛好 rank 星」的語意。對 rank=5 兩者等價、無差異。
Pity computePity(
  List<GachaRecord> records, {
  required int threshold,
  int rank = 5,
}) {
  var current = 0; // 距上次 >= rank（保底重置）的抽數 → 距離／進度
  var currentPure = 0; // 距上次 == rank 命中的抽數 → 平均間隔分子
  var hitCount = 0;
  DateTime? lastAt; // 上次 >= rank 事件時間
  var pureLocked = false; // 首次 == rank 命中後鎖定 currentPure
  for (final r in records) {
    if (r.qualityLevel >= rank) {
      lastAt ??= r.time; // 首次重置事件後鎖定，之後不再累加 current
    } else if (lastAt == null) {
      current++;
    }
    if (r.qualityLevel == rank) {
      hitCount++;
      pureLocked = true;
    } else if (!pureLocked) {
      currentPure++;
    }
  }
  final completedInterval = records.length - currentPure;
  final averageInterval = hitCount > 0 ? completedInterval / hitCount : null;
  return Pity(
    current: current,
    threshold: threshold,
    lastRecordAt: lastAt,
    averageInterval: averageInterval,
    hitCount: hitCount,
    completedInterval: completedInterval,
  );
}

/// 跨卡池合併平均:對每個卡池各自算 [Pity.completedInterval] 與 hitCount,
/// 把分子分母分別累加再相除。與單卡池 [Pity.averageInterval] 語意一致,
/// 每個卡池各算各的純 rank 分子,不會把多個卡池「未命中當前 pity」合計進分子。
double? averageIntervalAcrossBanners(
  Map<String, List<GachaRecord>> banners, {
  required int Function(String gachaType) rankFor,
}) {
  var sumCompleted = 0;
  var sumHits = 0;
  for (final entry in banners.entries) {
    // threshold: 0 — 跨卡池場景不需要 pity progress/distance,此參數被忽略。
    final p = computePity(entry.value, threshold: 0, rank: rankFor(entry.key));
    sumCompleted += p.completedInterval;
    sumHits += p.hitCount;
  }
  return sumHits > 0 ? sumCompleted / sumHits : null;
}
