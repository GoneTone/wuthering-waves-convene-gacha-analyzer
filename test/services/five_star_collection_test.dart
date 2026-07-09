import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/five_star_collection.dart';

GachaRecord _r({
  required int resourceId,
  required int rank,
  required DateTime time,
  String cardPoolType = '1',
  String name = 'x',
  String resourceType = '角色',
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: rank,
  resourceType: resourceType,
  cardPoolType: cardPoolType,
  name: name,
  count: 1,
  time: time,
);

void main() {
  group('buildFiveStarCollection', () {
    test('empty records → empty list', () {
      expect(buildFiveStarCollection(const []), isEmpty);
    });

    test('只取 5★，排除 4★／3★', () {
      final records = [
        _r(resourceId: 1, rank: 5, name: 'A', time: DateTime(2025, 1, 1)),
        _r(resourceId: 2, rank: 4, name: 'B', time: DateTime(2025, 1, 2)),
        _r(resourceId: 3, rank: 3, name: 'C', time: DateTime(2025, 1, 3)),
      ];
      final result = buildFiveStarCollection(records);
      expect(result, hasLength(1));
      expect(result.single.representative.name, 'A');
      expect(result.single.count, 1);
    });

    test('同 resourceId 去重計數，代表 record 取最近一次', () {
      final records = [
        _r(resourceId: 1211, rank: 5, name: 'A', time: DateTime(2025, 1, 1)),
        _r(resourceId: 1211, rank: 5, name: 'A', time: DateTime(2025, 3, 1)),
        _r(resourceId: 1211, rank: 5, name: 'A', time: DateTime(2025, 2, 1)),
      ];
      final result = buildFiveStarCollection(records);
      expect(result, hasLength(1));
      expect(result.single.count, 3);
      expect(result.single.representative.time, DateTime(2025, 3, 1));
    });

    test('排序：次數降冪，同次數以最近時間降冪', () {
      final records = [
        _r(resourceId: 10, rank: 5, name: 'A', time: DateTime(2025, 1, 1)),
        _r(resourceId: 10, rank: 5, name: 'A', time: DateTime(2025, 1, 2)),
        _r(resourceId: 20, rank: 5, name: 'B', time: DateTime(2025, 5, 1)),
        _r(resourceId: 30, rank: 5, name: 'C', time: DateTime(2025, 4, 1)),
      ];
      final result = buildFiveStarCollection(records);
      expect(result.map((e) => e.representative.name).toList(), [
        'A',
        'B',
        'C',
      ]);
    });

    test('跨語系：同 resourceId 不同語系名稱合併為一', () {
      final records = [
        _r(resourceId: 1211, rank: 5, name: '達妮婭', time: DateTime(2025, 1, 1)),
        _r(
          resourceId: 1211,
          rank: 5,
          name: 'Dania',
          time: DateTime(2025, 2, 1),
        ),
      ];
      final result = buildFiveStarCollection(records);
      expect(result, hasLength(1));
      expect(result.single.count, 2);
      expect(result.single.representative.name, 'Dania'); // 最近一筆
    });

    test('不同 resourceId 不誤併', () {
      final records = [
        _r(resourceId: 1, rank: 5, name: 'A', time: DateTime(2025, 1, 1)),
        _r(resourceId: 2, rank: 5, name: 'B', time: DateTime(2025, 2, 1)),
      ];
      expect(buildFiveStarCollection(records), hasLength(2));
    });

    test('不再排除任何卡池（所有 12 池的 5★ 都納入）', () {
      final records = [
        _r(
          resourceId: 1,
          rank: 5,
          name: '活動角色',
          cardPoolType: '1',
          time: DateTime(2025, 1, 1),
        ),
        _r(
          resourceId: 2,
          rank: 5,
          name: '新旅角色',
          cardPoolType: '8',
          time: DateTime(2025, 1, 2),
        ),
      ];
      expect(buildFiveStarCollection(records), hasLength(2));
    });
  });

  group('buildFiveStarCollectionAcrossBanners', () {
    test('同 resourceId 跨卡池合併、次數相加', () {
      final banners = {
        '1': [
          _r(resourceId: 1301, rank: 5, name: '某角', time: DateTime(2025, 1, 1)),
        ],
        '3': [
          _r(
            resourceId: 1301,
            rank: 5,
            name: '某角',
            cardPoolType: '3',
            time: DateTime(2025, 3, 1),
          ),
          _r(
            resourceId: 1301,
            rank: 5,
            name: '某角',
            cardPoolType: '3',
            time: DateTime(2025, 2, 1),
          ),
        ],
      };
      final result = buildFiveStarCollectionAcrossBanners(banners);
      expect(result, hasLength(1));
      expect(result.single.count, 3);
      expect(result.single.representative.time, DateTime(2025, 3, 1));
    });

    test('empty banners → empty list', () {
      expect(buildFiveStarCollectionAcrossBanners(const {}), isEmpty);
    });
  });
}
