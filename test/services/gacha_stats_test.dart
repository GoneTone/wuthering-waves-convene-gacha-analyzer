import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_stats.dart';

GachaRecord _r({int rank = 5, String resourceType = '角色'}) => GachaRecord(
  resourceId: 1211,
  qualityLevel: rank,
  resourceType: resourceType,
  cardPoolType: '1',
  name: 'x',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, 3),
);

void main() {
  group('GachaStats', () {
    test('空 list 全 0', () {
      final s = computeGachaStats(const []);
      expect(s.total, 0);
      expect(s.fiveStarCount, 0);
      expect(s.byItemType, isEmpty);
      expect(s.fiveStarRate, 0.0);
    });

    test('混合 list 計數正確（只有 5/4/3，無 2★）', () {
      final records = [
        _r(rank: 5, resourceType: '角色'),
        _r(rank: 4, resourceType: '武器'),
        _r(rank: 4, resourceType: '角色'),
        _r(rank: 3, resourceType: '武器'),
        _r(rank: 3, resourceType: '武器'),
      ];
      final s = computeGachaStats(records);
      expect(s.total, 5);
      expect(s.fiveStarCount, 1);
      expect(s.fourStarCount, 2);
      expect(s.threeStarCount, 2);
      expect(s.fiveStarRate, closeTo(0.2, 1e-9));
    });

    test('byItemType 以 canonical kind 聚合（含道具）', () {
      final records = [
        _r(rank: 5, resourceType: '角色'),
        _r(rank: 4, resourceType: '角色'),
        _r(rank: 4, resourceType: '武器'),
        _r(rank: 4, resourceType: '道具'),
      ];
      final stats = computeGachaStats(records);
      expect(stats.byItemType, {
        'kind:character': 2,
        'kind:weapon': 1,
        'kind:item': 1,
      });
    });

    test('跨語系同類型以 canonical kind 合併，不分裂', () {
      final stats = computeGachaStats([
        _r(rank: 5, resourceType: '角色'),
        _r(rank: 5, resourceType: 'Character'),
        _r(rank: 5, resourceType: 'キャラクター'),
      ]);
      expect(stats.byItemType, {'kind:character': 3});
    });

    test('未知 resourceType fallback 原字串', () {
      final stats = computeGachaStats([_r(rank: 5, resourceType: 'Mystery')]);
      expect(stats.byItemType, {'Mystery': 1});
    });

    test('sortedItemTypes 依 count desc 排序', () {
      final records = <GachaRecord>[
        for (var i = 0; i < 5; i++) _r(resourceType: '武器'),
        for (var i = 0; i < 3; i++) _r(resourceType: '角色'),
        _r(resourceType: '道具'),
      ];
      final stats = computeGachaStats(records);
      expect(stats.sortedItemTypes().map((e) => e.key).toList(), [
        'kind:weapon',
        'kind:character',
        'kind:item',
      ]);
    });
  });
}
