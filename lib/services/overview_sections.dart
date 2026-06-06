import 'package:flutter/foundation.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/data/gacha_types.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_pity.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_stats.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/timeline_entries.dart';

/// OverviewPage 與 ShareCard 共用的喚取彙整結果（鳴潮單段喚取）。
///
/// 扁平結構（R8）：直接持有全部 10 池的彙整欄位，無 `GachaSectionData` wrapper、
/// 無 `.gacha` 中介層。消費端（plan 07 的 `overview_page`／`share_card`）直接用
/// `sec.stats`／`sec.banners`／`sec.timeline` 直取。
@immutable
class OverviewSections {
  /// 建立 [OverviewSections]。
  const OverviewSections({
    required this.types,
    required this.banners,
    required this.stats,
    required this.timeline,
    required this.timelineRank,
    required this.timelineNowPulls,
    required this.fiveStarAvg,
    required this.fourStarAvg,
  });

  /// 包含的卡池類型清單（全部 10 池）。
  final List<GachaType> types;

  /// 各卡池的抽卡記錄，key 為 cardPoolType 字串。
  final Map<String, List<GachaRecord>> banners;

  /// 全部卡池合計統計。
  final GachaStats stats;

  /// 跨卡池合併的時間軸條目。
  final List<TimelineEntry> timeline;

  /// 時間軸目標星級（鳴潮所有卡池主保底皆 5★）。
  final int timelineRank;

  /// 距上次 timelineRank 出貨的累積抽數（供 TimelineVertical「現在」row 顯示）。
  final int timelineNowPulls;

  /// 5★ 平均間隔抽數；無出貨記錄時為 null。
  final double? fiveStarAvg;

  /// 4★ 平均間隔抽數；無出貨記錄時為 null。
  final double? fourStarAvg;
}

/// 從 [activeBanners]（key = cardPoolType 字串）建構 [OverviewSections]，供
/// OverviewPage 與 ShareCard 共用，避免兩處複製分組邏輯。
OverviewSections buildOverviewSections(
  Map<String, List<GachaRecord>> activeBanners,
) {
  final gachaList = gachaTypes.toList(growable: false);

  final gachaBanners = <String, List<GachaRecord>>{
    for (final t in gachaList)
      t.key: activeBanners[t.key] ?? const <GachaRecord>[],
  };
  final gachaAll = gachaBanners.values.expand((r) => r).toList(growable: false);

  final typesByKey = <String, GachaType>{for (final t in gachaList) t.key: t};
  final timelineRank = gachaList.first.primaryPity.rank;
  int rankFor(String key) => typesByKey[key]!.primaryPity.rank;

  final timeline = buildTimelineEntriesAcrossBanners(
    gachaBanners,
    rankFor: rankFor,
  );
  final timelineNowPulls = pullsSinceLastRankedAcrossBanners(
    gachaBanners,
    rankFor: rankFor,
  );

  return OverviewSections(
    types: gachaList,
    banners: gachaBanners,
    stats: computeGachaStats(gachaAll),
    timeline: timeline,
    timelineRank: timelineRank,
    timelineNowPulls: timelineNowPulls,
    fiveStarAvg: averageIntervalAcrossBanners(gachaBanners, rankFor: (_) => 5),
    fourStarAvg: averageIntervalAcrossBanners(gachaBanners, rankFor: (_) => 4),
  );
}
