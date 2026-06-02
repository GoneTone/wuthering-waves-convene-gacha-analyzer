import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/timeline_entries.dart';

GachaRecord _r({
  required String cpt,
  required int rank,
  required DateTime time,
  int resourceId = 1,
  String name = 'x',
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: rank,
  resourceType: '角色',
  cardPoolType: cpt,
  name: name,
  count: 1,
  time: time,
);

void main() {
  group('buildTimelineEntries', () {
    test('empty records → empty list', () {
      expect(buildTimelineEntries(const []), isEmpty);
    });

    test('records without 5★ → empty list', () {
      final records = [
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 1)),
        _r(cpt: '1', rank: 4, time: DateTime(2025, 1, 2)),
      ];
      expect(buildTimelineEntries(records.reversed.toList()), isEmpty);
    });

    test('computes pullsSincePrev counting from start', () {
      final asc = [
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 1)),
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 2)),
        _r(cpt: '1', rank: 5, name: 'A', time: DateTime(2025, 1, 3)),
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 4)),
        _r(cpt: '1', rank: 5, name: 'B', time: DateTime(2025, 1, 5)),
      ];
      final desc = asc.reversed.toList();
      final result = buildTimelineEntries(desc);
      expect(result, hasLength(2));
      expect(result[0].name, 'B');
      expect(result[0].pullsSincePrev, 2);
      expect(result[1].name, 'A');
      expect(result[1].pullsSincePrev, 3);
    });

    test('entry.gachaType 持 cardPoolType 字串', () {
      final records = [_r(cpt: '8', rank: 5, time: DateTime(2025, 1, 1))];
      final result = buildTimelineEntries(records);
      expect(result.single.gachaType, '8');
    });
  });

  group('buildTimelineEntriesAcrossBanners', () {
    test('merges multiple banners and sorts by time desc', () {
      final banners = {
        '1': [
          _r(cpt: '1', rank: 5, name: 'CharB', time: DateTime(2025, 3, 1)),
          _r(cpt: '1', rank: 5, name: 'CharA', time: DateTime(2025, 1, 1)),
        ],
        '2': [_r(cpt: '2', rank: 5, name: 'WepA', time: DateTime(2025, 2, 1))],
      };
      final result = buildTimelineEntriesAcrossBanners(
        banners,
        rankFor: (_) => 5,
      );
      expect(result.map((e) => e.name).toList(), ['CharB', 'WepA', 'CharA']);
    });

    test('per-pool pullsSincePrev preserved (not recomputed across pools)', () {
      final banners = {
        '1': [_r(cpt: '1', rank: 5, time: DateTime(2025, 2, 1))],
        '2': [_r(cpt: '2', rank: 5, time: DateTime(2025, 1, 1))],
      };
      final result = buildTimelineEntriesAcrossBanners(
        banners,
        rankFor: (_) => 5,
      );
      expect(result.every((e) => e.pullsSincePrev == 1), isTrue);
    });
  });

  group('pullsSinceLastRanked', () {
    test('no matching rank → returns total records count', () {
      final records = [
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 2)),
        _r(cpt: '1', rank: 4, time: DateTime(2025, 1, 1)),
      ];
      expect(pullsSinceLastRanked(records, rank: 5), 2);
    });

    test('counts records newer than latest matching rank', () {
      final records = [
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 3)),
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 2)),
        _r(cpt: '1', rank: 5, time: DateTime(2025, 1, 1)),
      ];
      expect(pullsSinceLastRanked(records, rank: 5), 2);
    });

    test('empty records → 0', () {
      expect(pullsSinceLastRanked(const [], rank: 5), 0);
    });
  });

  group('pullsSinceLastRankedAcrossBanners', () {
    test('counts across all pools after cross-pool latest 5★', () {
      final banners = {
        '1': [
          _r(cpt: '1', rank: 3, time: DateTime(2025, 3, 1)),
          _r(cpt: '1', rank: 5, time: DateTime(2025, 2, 1)),
          _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 1)),
        ],
        '2': [_r(cpt: '2', rank: 5, time: DateTime(2025, 2, 15))],
      };
      expect(pullsSinceLastRankedAcrossBanners(banners, rankFor: (_) => 5), 1);
    });

    test('no matching rank anywhere → total cross-pool record count', () {
      final banners = {
        '1': [_r(cpt: '1', rank: 3, time: DateTime(2025, 1, 1))],
        '2': [
          _r(cpt: '2', rank: 4, time: DateTime(2025, 1, 1)),
          _r(cpt: '2', rank: 3, time: DateTime(2025, 1, 2)),
        ],
      };
      expect(pullsSinceLastRankedAcrossBanners(banners, rankFor: (_) => 5), 3);
    });

    test('empty banners → 0', () {
      expect(pullsSinceLastRankedAcrossBanners(const {}, rankFor: (_) => 5), 0);
    });

    test('same-pool same-second: 用清單索引定位 5★，計其後（清單前段）抽數，無唯一 id 也正確', () {
      // 同一十連同秒：清單 desc 順序 r10..r1，5★ 是清單 index 5（第 6 筆）。
      // 其後（在清單前段、抽得較晚的）= index 0..4 共 5 筆。
      final sameSec = DateTime(2025, 4, 19, 14, 32, 0);
      final banners = {
        '1': [
          _r(cpt: '1', rank: 3, time: sameSec, resourceId: 31),
          _r(cpt: '1', rank: 3, time: sameSec, resourceId: 32),
          _r(cpt: '1', rank: 3, time: sameSec, resourceId: 33),
          _r(cpt: '1', rank: 4, time: sameSec, resourceId: 41),
          _r(cpt: '1', rank: 3, time: sameSec, resourceId: 34),
          _r(cpt: '1', rank: 5, time: sameSec, resourceId: 51, name: 'Five'),
          _r(cpt: '1', rank: 3, time: sameSec, resourceId: 35),
          _r(cpt: '1', rank: 3, time: sameSec, resourceId: 36),
          _r(cpt: '1', rank: 3, time: sameSec, resourceId: 37),
          _r(cpt: '1', rank: 3, time: sameSec, resourceId: 38),
        ],
      };
      expect(pullsSinceLastRankedAcrossBanners(banners, rankFor: (_) => 5), 5);
    });

    test('跨池同秒穩定 tie-break：時間相同時取 cardPoolType 較大者為較新', () {
      // 兩池各一筆 5★ 同秒。tie-break：cardPoolType key 較大（'2' > '1'）視為較新。
      // 故定位到 '2' 池那筆；'2' 池其前 0 筆、'1' 池整段（time 不 isAfter）→ 0。
      final sameSec = DateTime(2025, 4, 19, 14, 32, 0);
      final banners = {
        '1': [_r(cpt: '1', rank: 5, time: sameSec, resourceId: 1)],
        '2': [_r(cpt: '2', rank: 5, time: sameSec, resourceId: 2)],
      };
      expect(pullsSinceLastRankedAcrossBanners(banners, rankFor: (_) => 5), 0);
    });
  });
}
