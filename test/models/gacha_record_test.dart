import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

void main() {
  group('parseGachaTime / formatGachaTime', () {
    test('parse "YYYY-MM-DD HH:mm:ss" → DateTime（本地時間語意）', () {
      final t = parseGachaTime('2026-05-21 11:03:18');
      expect(t, DateTime(2026, 5, 21, 11, 3, 18));
    });

    test('format DateTime → "YYYY-MM-DD HH:mm:ss" 補零', () {
      final s = formatGachaTime(DateTime(2026, 2, 7, 16, 19, 41));
      expect(s, '2026-02-07 16:19:41');
    });

    test('format 個位數月日時分秒皆補零', () {
      final s = formatGachaTime(DateTime(2026, 1, 2, 3, 4, 5));
      expect(s, '2026-01-02 03:04:05');
    });

    test('parse → format roundtrip', () {
      const raw = '2026-05-21 10:39:03';
      expect(formatGachaTime(parseGachaTime(raw)), raw);
    });
  });

  group('GachaRecord.fromApiJson', () {
    test('解析角色 5★ 記錄', () {
      final json = {
        'cardPoolType': '1',
        'resourceId': 1211,
        'qualityLevel': 5,
        'resourceType': '角色',
        'name': '達妮婭',
        'count': 1,
        'time': '2026-05-21 10:39:03',
      };
      final r = GachaRecord.fromApiJson(json, cardPoolType: '1');
      expect(r.resourceId, 1211);
      expect(r.qualityLevel, 5);
      expect(r.resourceType, '角色');
      expect(r.cardPoolType, '1');
      expect(r.name, '達妮婭');
      expect(r.count, 1);
      expect(r.time, DateTime(2026, 5, 21, 10, 39, 3));
    });

    test('解析道具 4★ 記錄（同卡池可混入道具）', () {
      final json = {
        'cardPoolType': '1',
        'resourceId': 21040084,
        'qualityLevel': 4,
        'resourceType': '道具',
        'name': '塵雲旋臂',
        'count': 1,
        'time': '2026-02-07 16:19:41',
      };
      final r = GachaRecord.fromApiJson(json, cardPoolType: '1');
      expect(r.resourceType, '道具');
      expect(r.qualityLevel, 4);
      expect(r.resourceId, 21040084);
    });

    test('cardPoolType 以呼叫端傳入值為準（回應內字串一致時不衝突）', () {
      final json = {
        'cardPoolType': '1',
        'resourceId': 1601,
        'qualityLevel': 4,
        'resourceType': '角色',
        'name': '桃祈',
        'count': 1,
        'time': '2026-05-21 11:03:18',
      };
      final r = GachaRecord.fromApiJson(json, cardPoolType: '8');
      expect(r.cardPoolType, '8');
    });
  });

  group('GachaRecord 存檔序列化', () {
    test('toStorageJson key 為鳴潮 snake_case', () {
      final r = GachaRecord(
        resourceId: 1211,
        qualityLevel: 5,
        resourceType: '角色',
        cardPoolType: '1',
        name: '達妮婭',
        count: 1,
        time: DateTime(2026, 5, 21, 10, 39, 3),
      );
      final json = r.toStorageJson();
      expect(json['resource_id'], 1211);
      expect(json['quality_level'], 5);
      expect(json['resource_type'], '角色');
      expect(json['card_pool_type'], '1');
      expect(json['name'], '達妮婭');
      expect(json['count'], 1);
      expect(json['time'], '2026-05-21 10:39:03');
    });

    test('toStorageJson / fromStorageJson roundtrip', () {
      final original = GachaRecord(
        resourceId: 21020023,
        qualityLevel: 3,
        resourceType: '武器',
        cardPoolType: '1',
        name: '源能迅刀·測貳',
        count: 1,
        time: DateTime(2026, 5, 21, 11, 3, 18),
      );
      final restored = GachaRecord.fromStorageJson(original.toStorageJson());
      expect(restored.resourceId, original.resourceId);
      expect(restored.qualityLevel, original.qualityLevel);
      expect(restored.resourceType, original.resourceType);
      expect(restored.cardPoolType, original.cardPoolType);
      expect(restored.name, original.name);
      expect(restored.count, original.count);
      expect(restored.time, original.time);
    });
  });
}
