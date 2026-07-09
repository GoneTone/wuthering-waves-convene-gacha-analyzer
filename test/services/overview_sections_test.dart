import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
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

ItemImageIndex _idx(Map<int, String> kinds) => ItemImageIndex(
  items: {
    for (final e in kinds.entries)
      e.key: ItemImageEntry(
        iconUrl: 'u',
        noImage: false,
        permanentNoImage: false,
        kind: e.value,
      ),
  },
);

void main() {
  test('buildOverviewSections 聚合全部 10 池於單段、統計正確', () {
    final t = DateTime(2026, 5, 1, 10);
    final activeBanners = <String, List<GachaRecord>>{
      '1': [_r('1', 5, '達妮婭', t), _r('1', 3, '冷刃', t)],
      '8': [_r('8', 5, '新旅角色', t.add(const Duration(hours: 1)))],
    };

    // 為各 record 的 resourceId 建立 index（hashCode & 0xffff）。
    final idx = _idx({
      '達妮婭'.hashCode & 0xffff: kItemKindCharacter,
      '冷刃'.hashCode & 0xffff: kItemKindWeapon,
      '新旅角色'.hashCode & 0xffff: kItemKindCharacter,
    });

    final sections = buildOverviewSections(activeBanners, idx);

    expect(sections.stats.total, 3);
    expect(sections.stats.fiveStarCount, 2);
    expect(sections.timeline.length, 2);
    expect(sections.timelineRank, 5);
  });

  test('buildOverviewSections 空輸入不拋例外、各欄位回傳零值', () {
    final sections = buildOverviewSections(
      const <String, List<GachaRecord>>{},
      const ItemImageIndex.empty(),
    );

    expect(sections.stats.total, 0);
    expect(sections.fiveStarAvg, isNull);
    expect(sections.fourStarAvg, isNull);
    expect(sections.timeline, isEmpty);
    expect(sections.timelineNowPulls, 0);
  });

  test('types 含全部 12 個卡池', () {
    final sections = buildOverviewSections(
      const <String, List<GachaRecord>>{},
      const ItemImageIndex.empty(),
    );
    expect(sections.types.map((t) => t.cardPoolType).toList(), [
      1,
      2,
      3,
      4,
      5,
      6,
      8,
      9,
      10,
      11,
      12,
      13,
    ]);
  });
}
