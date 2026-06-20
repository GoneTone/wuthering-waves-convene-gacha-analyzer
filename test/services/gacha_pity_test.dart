import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_pity.dart';

GachaRecord _r({required int rank, DateTime? time}) => GachaRecord(
  resourceId: 1211,
  qualityLevel: rank,
  resourceType: '角色',
  cardPoolType: '1',
  name: 'x',
  count: 1,
  time: time ?? DateTime(2025),
);

void main() {
  group('computePity', () {
    test('空 list → current=0、lastRecordAt=null', () {
      final p = computePity(const [], threshold: 90);
      expect(p.current, 0);
      expect(p.threshold, 90);
      expect(p.lastRecordAt, isNull);
    });

    test('從未抽中 5★ → current = total 抽數', () {
      final records = [
        _r(rank: 4, time: DateTime(2025, 1, 3)),
        _r(rank: 3, time: DateTime(2025, 1, 2)),
        _r(rank: 3, time: DateTime(2025, 1, 1)),
      ];
      final p = computePity(records, threshold: 90);
      expect(p.current, 3);
      expect(p.lastRecordAt, isNull);
    });

    test('上次 5★ 之後 N 抽 → current=N', () {
      final records = [
        _r(rank: 4, time: DateTime(2025, 1, 5)),
        _r(rank: 4, time: DateTime(2025, 1, 4)),
        _r(rank: 4, time: DateTime(2025, 1, 3)),
        _r(rank: 5, time: DateTime(2025, 1, 2)),
        _r(rank: 3, time: DateTime(2025, 1, 1)),
      ];
      final p = computePity(records, threshold: 90);
      expect(p.current, 3);
      expect(p.lastRecordAt, DateTime(2025, 1, 2));
    });

    test('首抽即 5★ → current=0、lastRecordAt 為該筆時間', () {
      final records = [_r(rank: 5, time: DateTime(2025, 1, 1))];
      final p = computePity(records, threshold: 90);
      expect(p.current, 0);
      expect(p.lastRecordAt, DateTime(2025, 1, 1));
    });

    test('最新即 5★ → current=0', () {
      final records = [
        _r(rank: 5, time: DateTime(2025, 1, 3)),
        _r(rank: 4, time: DateTime(2025, 1, 2)),
        _r(rank: 3, time: DateTime(2025, 1, 1)),
      ];
      final p = computePity(records, threshold: 90);
      expect(p.current, 0);
      expect(p.lastRecordAt, DateTime(2025, 1, 3));
    });

    test('剛好 threshold-1 抽未保底 → progress 接近 1.0', () {
      final records = List.generate(
        89,
        (i) => _r(rank: 4, time: DateTime(2025, 1, 1 + i)),
      ).reversed.toList(growable: false);
      final p = computePity(records, threshold: 90);
      expect(p.current, 89);
      expect(p.progress, closeTo(89 / 90, 0.001));
      expect(p.distance, 1);
    });

    test('progress 永遠在 0..1 之間，超過 threshold 也 clamp', () {
      final records = List.generate(
        100,
        (i) => _r(rank: 4, time: DateTime(2025, 1, 1 + i)),
      ).reversed.toList(growable: false);
      final p = computePity(records, threshold: 90);
      expect(p.progress, 1.0);
      expect(p.distance, 0);
    });

    test('rank=4 → 中途 5★ 重置距離（但平均仍只算 4★）', () {
      // records (新→舊): 3★(1/5), 5★(1/4), 3★(1/3), 4★(1/2), 3★(1/1)
      final records = [
        GachaRecord(
          resourceId: 1211,
          qualityLevel: 3,
          resourceType: '角色',
          cardPoolType: '1',
          name: 'a',
          count: 1,
          time: DateTime(2025, 1, 5),
        ),
        GachaRecord(
          resourceId: 1211,
          qualityLevel: 5,
          resourceType: '角色',
          cardPoolType: '1',
          name: 'b',
          count: 1,
          time: DateTime(2025, 1, 4),
        ),
        GachaRecord(
          resourceId: 1211,
          qualityLevel: 3,
          resourceType: '角色',
          cardPoolType: '1',
          name: 'c',
          count: 1,
          time: DateTime(2025, 1, 3),
        ),
        GachaRecord(
          resourceId: 1211,
          qualityLevel: 4,
          resourceType: '角色',
          cardPoolType: '1',
          name: 'd',
          count: 1,
          time: DateTime(2025, 1, 2),
        ),
        GachaRecord(
          resourceId: 1211,
          qualityLevel: 3,
          resourceType: '角色',
          cardPoolType: '1',
          name: 'e',
          count: 1,
          time: DateTime(2025, 1, 1),
        ),
      ];
      final p = computePity(records, threshold: 10, rank: 4);
      // 距離：最近重置事件是 1/4 的 5★，其後只有 1/5 的 3★ → current=1。
      expect(p.current, 1);
      expect(p.lastRecordAt, DateTime(2025, 1, 4));
      // 平均仍只算 4★：上次 4★ 是 1/2，分子 = 5 − 3 = 2，命中 1 → avg=2.0。
      expect(p.hitCount, 1);
      expect(p.completedInterval, 2);
      expect(p.averageInterval, 2.0);
    });

    test('rank=4 距離吃 5★ 重置，但平均間隔不被 5★ 影響', () {
      // records (新→舊): 5★, 3★, 3★, 4★, 未中×6
      // 距離：最近重置事件即首筆 5★ → current=0。
      // 平均：唯一 4★ 在 time 第 7 筆，純 4★ 分子 = 10 − 3 = 7，命中 1 → avg=7.0
      //       （中途的 5★ 被算進間隔、不視為 4★ 命中）。
      final records = [
        _r(rank: 5, time: DateTime(2025, 3, 10)),
        _r(rank: 3, time: DateTime(2025, 3, 9)),
        _r(rank: 3, time: DateTime(2025, 3, 8)),
        _r(rank: 4, time: DateTime(2025, 3, 7)),
        for (var i = 0; i < 6; i++) _r(rank: 3, time: DateTime(2025, 3, 6 - i)),
      ];
      final p = computePity(records, threshold: 10, rank: 4);
      expect(p.current, 0);
      expect(p.distance, 10);
      expect(p.lastRecordAt, DateTime(2025, 3, 10));
      expect(p.hitCount, 1);
      expect(p.averageInterval, 7.0);
    });

    test('rank=5 不受 >= 重置影響（5★ 為最高星，等同 == 5）', () {
      // records (新→舊): 4★, 4★, 5★, 4★ → 距離與平均皆只看 5★。
      final records = [
        _r(rank: 4, time: DateTime(2025, 1, 4)),
        _r(rank: 4, time: DateTime(2025, 1, 3)),
        _r(rank: 5, time: DateTime(2025, 1, 2)),
        _r(rank: 4, time: DateTime(2025, 1, 1)),
      ];
      final p = computePity(records, threshold: 80, rank: 5);
      expect(p.current, 2);
      expect(p.lastRecordAt, DateTime(2025, 1, 2));
      expect(p.hitCount, 1);
      expect(p.completedInterval, 2);
      expect(p.averageInterval, 2.0);
    });

    test('空 list → hitCount=0、averageInterval=null', () {
      final p = computePity(const [], threshold: 90);
      expect(p.hitCount, 0);
      expect(p.averageInterval, isNull);
    });

    test('有抽但無命中 → hitCount=0、averageInterval=null', () {
      final records = List.generate(
        10,
        (i) => _r(rank: 4, time: DateTime(2025, 1, 1 + i)),
      ).reversed.toList(growable: false);
      final p = computePity(records, threshold: 90, rank: 5);
      expect(p.hitCount, 0);
      expect(p.averageInterval, isNull);
    });

    test('最舊抽即 5★ → averageInterval=1.0', () {
      // records (新→舊): 4×未中, 5★
      final records = [
        _r(rank: 4, time: DateTime(2025, 1, 5)),
        _r(rank: 4, time: DateTime(2025, 1, 4)),
        _r(rank: 4, time: DateTime(2025, 1, 3)),
        _r(rank: 4, time: DateTime(2025, 1, 2)),
        _r(rank: 5, time: DateTime(2025, 1, 1)),
      ];
      final p = computePity(records, threshold: 90);
      expect(p.current, 4);
      expect(p.hitCount, 1);
      expect(p.averageInterval, 1.0);
    });

    test('兩件命中 → averageInterval=4.5', () {
      // records (新→舊): 未中×3, 5★, 未中×7, 5★
      final records = [
        for (var i = 0; i < 3; i++)
          _r(rank: 4, time: DateTime(2025, 2, 12 - i)),
        _r(rank: 5, time: DateTime(2025, 2, 9)),
        for (var i = 0; i < 7; i++) _r(rank: 4, time: DateTime(2025, 2, 8 - i)),
        _r(rank: 5, time: DateTime(2025, 2, 1)),
      ];
      final p = computePity(records, threshold: 90);
      expect(p.current, 3);
      expect(p.hitCount, 2);
      expect(p.averageInterval, 4.5);
    });

    test('最新抽即 5★ + 5 抽歷史 → averageInterval=6.0', () {
      // records (新→舊): 5★, 未中×5
      final records = [
        _r(rank: 5, time: DateTime(2025, 1, 6)),
        for (var i = 0; i < 5; i++) _r(rank: 4, time: DateTime(2025, 1, 5 - i)),
      ];
      final p = computePity(records, threshold: 90);
      expect(p.current, 0);
      expect(p.hitCount, 1);
      expect(p.averageInterval, 6.0);
    });

    test('rank=4 查詢 → 只算 4★ 命中', () {
      // records (新→舊): 未中×3, 4★, 未中×2, 5★
      // 對 rank=4: current=3, hitCount=1, completed=4, avg=4.0
      final records = [
        for (var i = 0; i < 3; i++) _r(rank: 3, time: DateTime(2025, 2, 7 - i)),
        _r(rank: 4, time: DateTime(2025, 2, 4)),
        for (var i = 0; i < 2; i++) _r(rank: 3, time: DateTime(2025, 2, 3 - i)),
        _r(rank: 5, time: DateTime(2025, 2, 1)),
      ];
      final p = computePity(records, threshold: 10, rank: 4);
      expect(p.current, 3);
      expect(p.hitCount, 1);
      expect(p.averageInterval, 4.0);
    });

    test('帶小數 → averageInterval≈3.333…', () {
      // records (新→舊): 5★, 未中×3, 5★, 未中×4, 5★
      // current=0, hitCount=3, completed=10, avg=10/3
      final records = [
        _r(rank: 5, time: DateTime(2025, 2, 10)),
        for (var i = 0; i < 3; i++) _r(rank: 4, time: DateTime(2025, 2, 9 - i)),
        _r(rank: 5, time: DateTime(2025, 2, 6)),
        for (var i = 0; i < 4; i++) _r(rank: 4, time: DateTime(2025, 2, 5 - i)),
        _r(rank: 5, time: DateTime(2025, 2, 1)),
      ];
      final p = computePity(records, threshold: 90);
      expect(p.current, 0);
      expect(p.hitCount, 3);
      expect(p.averageInterval, closeTo(10 / 3, 1e-9));
      expect(p.averageInterval!.toStringAsFixed(2), '3.33');
    });

    test('resourceType=道具 的 qualityLevel 一樣計入保底命中', () {
      // desc by time：最新一筆是 4★ 道具，視為命中 rank 4。
      final records = [
        GachaRecord(
          resourceId: 21040084,
          qualityLevel: 4,
          resourceType: '道具',
          cardPoolType: '1',
          name: '塵雲旋臂',
          count: 1,
          time: DateTime(2026, 2, 7, 16, 19, 41),
        ),
        GachaRecord(
          resourceId: 21020023,
          qualityLevel: 3,
          resourceType: '武器',
          cardPoolType: '1',
          name: '源能迅刀·測貳',
          count: 1,
          time: DateTime(2026, 2, 7, 16, 19, 40),
        ),
      ];
      final p = computePity(records, threshold: 10, rank: 4);
      expect(p.hitCount, 1);
      expect(p.current, 0); // 最新一筆即命中 → 距上次命中 0 抽
    });
  });

  group('averageIntervalAcrossBanners', () {
    test('全空 banners → null', () {
      final result = averageIntervalAcrossBanners(const {
        '1': <GachaRecord>[],
        '2': <GachaRecord>[],
      }, rankFor: (_) => 5);
      expect(result, isNull);
    });

    test('單卡池有命中 → 與 single-banner averageInterval 相同', () {
      // '1': 未中×3, 5★, 未中×7, 5★ → completed=9, hits=2 → 4.5
      final records = [
        for (var i = 0; i < 3; i++)
          _r(rank: 4, time: DateTime(2025, 2, 12 - i)),
        _r(rank: 5, time: DateTime(2025, 2, 9)),
        for (var i = 0; i < 7; i++) _r(rank: 4, time: DateTime(2025, 2, 8 - i)),
        _r(rank: 5, time: DateTime(2025, 2, 1)),
      ];
      final result = averageIntervalAcrossBanners({
        '1': records,
      }, rankFor: (_) => 5);
      expect(result, 4.5);
    });

    test('多卡池合併分子分母 → (1+9)/(1+2)≈3.333', () {
      // '1': 未中×4, 5★ → completed=1, hits=1
      // '2': 未中×3, 5★, 未中×7, 5★ → completed=9, hits=2
      final r1 = [
        for (var i = 0; i < 4; i++) _r(rank: 4, time: DateTime(2025, 1, 5 - i)),
        _r(rank: 5, time: DateTime(2025, 1, 1)),
      ];
      final r2 = [
        for (var i = 0; i < 3; i++)
          _r(rank: 4, time: DateTime(2025, 2, 12 - i)),
        _r(rank: 5, time: DateTime(2025, 2, 9)),
        for (var i = 0; i < 7; i++) _r(rank: 4, time: DateTime(2025, 2, 8 - i)),
        _r(rank: 5, time: DateTime(2025, 2, 1)),
      ];
      final result = averageIntervalAcrossBanners({
        '1': r1,
        '2': r2,
      }, rankFor: (_) => 5);
      expect(result, closeTo(10 / 3, 1e-9));
    });

    test('空卡池被略過 → 只計入有資料的卡池', () {
      final r2 = [
        for (var i = 0; i < 4; i++) _r(rank: 4, time: DateTime(2025, 1, 5 - i)),
        _r(rank: 5, time: DateTime(2025, 1, 1)),
      ];
      final result = averageIntervalAcrossBanners({
        '1': const <GachaRecord>[],
        '2': r2,
      }, rankFor: (_) => 5);
      expect(result, 1.0);
    });

    test('rankFor 切換 rank → 無命中時回傳 null', () {
      final r1 = [
        for (var i = 0; i < 4; i++) _r(rank: 4, time: DateTime(2025, 1, 5 - i)),
        _r(rank: 5, time: DateTime(2025, 1, 1)),
      ];
      // 該 records 沒有 rank=3 命中
      final result = averageIntervalAcrossBanners({'1': r1}, rankFor: (_) => 3);
      expect(result, isNull);
    });
  });
}
