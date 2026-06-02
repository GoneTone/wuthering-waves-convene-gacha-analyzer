import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_row.dart';

GachaRecord _r({
  required int rank,
  required DateTime time,
  String resourceType = '角色',
  int resourceId = 1211,
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: rank,
  resourceType: resourceType,
  cardPoolType: '1',
  name: 'x',
  count: 1,
  time: time,
);

void main() {
  group('buildRecordRows', () {
    test('空 list → const []', () {
      expect(buildRecordRows(const []), isEmpty);
    });

    test('totalIndex 從 1 累計，最舊=1、最新=N，輸出順序與輸入一致 (desc by time)', () {
      final records = [
        for (var d = 5; d >= 1; d--) _r(rank: 3, time: DateTime(2025, 1, d)),
      ];
      final rows = buildRecordRows(records);
      expect(rows.map((r) => r.totalIndex).toList(), [5, 4, 3, 2, 1]);
      expect(rows.map((r) => r.record.time.day).toList(), [5, 4, 3, 2, 1]);
    });

    test('全無 5★ → mainPityIndex == totalIndex', () {
      final records = [
        _r(rank: 4, time: DateTime(2025, 1, 3)),
        _r(rank: 3, time: DateTime(2025, 1, 2)),
        _r(rank: 4, time: DateTime(2025, 1, 1)),
      ];
      final rows = buildRecordRows(records);
      expect(rows.map((r) => r.mainPityIndex).toList(), [3, 2, 1]);
    });

    test('5★ 那一抽 = 抵達該 5★ 的累積值，下一抽從 1 重新累計', () {
      // asc：1(3★) 2(3★) 3(5★) 4(3★) 5(5★) → pity asc 1,2,3,1,2
      final records = [
        _r(rank: 5, time: DateTime(2025, 1, 5)),
        _r(rank: 3, time: DateTime(2025, 1, 4)),
        _r(rank: 5, time: DateTime(2025, 1, 3)),
        _r(rank: 3, time: DateTime(2025, 1, 2)),
        _r(rank: 3, time: DateTime(2025, 1, 1)),
      ];
      final rows = buildRecordRows(records);
      final byDay = {for (final r in rows) r.record.time.day: r};
      expect(byDay[1]!.mainPityIndex, 1);
      expect(byDay[2]!.mainPityIndex, 2);
      expect(byDay[3]!.mainPityIndex, 3);
      expect(byDay[4]!.mainPityIndex, 1);
      expect(byDay[5]!.mainPityIndex, 2);
    });

    test('首抽即 5★ → 該抽 pity = 1', () {
      final rows = buildRecordRows([_r(rank: 5, time: DateTime(2025, 1, 1))]);
      expect(rows.first.totalIndex, 1);
      expect(rows.first.mainPityIndex, 1);
    });

    test('itemTypeKey 依 resourceType 映射 canonical（含道具）', () {
      final records = [
        _r(rank: 5, resourceType: '角色', time: DateTime(2025, 1, 3)),
        _r(rank: 4, resourceType: '武器', time: DateTime(2025, 1, 2)),
        _r(rank: 4, resourceType: '道具', time: DateTime(2025, 1, 1)),
      ];
      final rows = buildRecordRows(records);
      expect(rows[0].itemTypeKey, 'kind:character');
      expect(rows[1].itemTypeKey, 'kind:weapon');
      expect(rows[2].itemTypeKey, 'kind:item');
    });
  });
}
