import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/overview_sections.dart';

GachaRecord _r(String cpt, int rank, String name, DateTime t) => GachaRecord(
  resourceId: name.hashCode & 0xffff,
  qualityLevel: rank,
  resourceType: rank == 5 ? '角色' : '武器',
  cardPoolType: cpt,
  name: name,
  count: 1,
  time: t,
);

void main() {
  test('buildOverviewSections 聚合全部 8 池於單段、統計正確', () {
    final t = DateTime(2026, 5, 1, 10);
    final activeBanners = <String, List<GachaRecord>>{
      '1': [_r('1', 5, '達妮婭', t), _r('1', 3, '冷刃', t)],
      '8': [_r('8', 5, '新旅角色', t.add(const Duration(hours: 1)))],
    };

    final sections = buildOverviewSections(activeBanners);

    expect(sections.stats.total, 3);
    expect(sections.stats.fiveStarCount, 2);
    expect(sections.timeline.length, 2);
    expect(sections.timelineRank, 5);
  });

  test('buildOverviewSections 空輸入不拋例外、各欄位回傳零值', () {
    final sections = buildOverviewSections(const <String, List<GachaRecord>>{});

    expect(sections.stats.total, 0);
    expect(sections.fiveStarAvg, isNull);
    expect(sections.fourStarAvg, isNull);
    expect(sections.timeline, isEmpty);
    expect(sections.timelineNowPulls, 0);
  });

  test('types 含全部 8 個卡池', () {
    final sections = buildOverviewSections(const <String, List<GachaRecord>>{});
    expect(sections.types.map((t) => t.cardPoolType).toList(), [
      1,
      2,
      3,
      4,
      5,
      6,
      8,
      9,
    ]);
  });
}
