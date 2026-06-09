import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

GachaRecord _r(int id) => GachaRecord(
  resourceId: id,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: '1',
  name: '達妮婭',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, 3),
);

GachaRecord _rt(int id, int sec) => GachaRecord(
  resourceId: id,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: '1',
  name: 'x',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, sec),
);

void main() {
  test('toJson 落 player_id / language_code / 10 個 cardPoolType key', () {
    final storage = BannerStorage(
      playerId: '701000000',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 5, 21, 3, 30),
      banners: {
        '1': [_r(1211)],
        '2': [],
        '3': [],
        '4': [],
        '5': [],
        '6': [],
        '8': [],
        '9': [],
        '10': [],
        '11': [],
      },
    );
    final json = storage.toJson();
    expect(json['player_id'], '701000000');
    expect(json['language_code'], 'zh-Hant');
    expect(json['last_updated'], '2026-05-21T03:30:00.000Z');
    expect((json['banners'] as Map).keys.toSet(), {
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '8',
      '9',
      '10',
      '11',
    });
    expect((json['banners'] as Map)['1'], hasLength(1));
  });

  test('fromJson roundtrip 保留 playerId / languageCode / banners', () {
    final original = BannerStorage(
      playerId: '701000000',
      languageCode: 'en',
      lastUpdated: DateTime.utc(2026, 5, 21, 3, 30),
      banners: {
        '1': [_r(1211)],
        '8': [],
      },
    );
    final restored = BannerStorage.fromJson(original.toJson());
    expect(restored.playerId, '701000000');
    expect(restored.languageCode, 'en');
    expect(restored.lastUpdated, original.lastUpdated);
    expect(restored.banners['1']!.single.resourceId, 1211);
    expect(restored.banners['8'], isEmpty);
  });

  test('allRecords 串接所有 banner', () {
    final storage = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026),
      banners: {
        '1': [_r(1), _r(2)],
        '8': [_r(3)],
      },
    );
    expect(storage.allRecords.map((e) => e.resourceId).toSet(), {1, 2, 3});
  });

  test('copyWith 可覆寫 languageCode / lastUpdated / banners，playerId 不變', () {
    final original = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: const {'1': []},
    );
    final updated = original.copyWith(
      languageCode: 'ja',
      lastUpdated: DateTime.utc(2026, 2, 2),
    );
    expect(updated.playerId, 'p');
    expect(updated.languageCode, 'ja');
    expect(updated.lastUpdated, DateTime.utc(2026, 2, 2));
  });

  test(
    'fromJson backfills per-record languageCode from account-level value',
    () {
      final json = {
        'player_id': '701000000',
        'language_code': 'zh-Hant',
        'last_updated': '2026-05-21T00:00:00.000Z',
        'banners': {
          '1': [
            {
              'resource_id': 1211,
              'quality_level': 5,
              'resource_type': '角色',
              'card_pool_type': '1',
              'name': '達妮婭',
              'count': 1,
              'time': '2026-05-21 10:39:03',
            },
          ],
        },
      };
      final storage = BannerStorage.fromJson(json);
      expect(storage.banners['1']!.single.languageCode, 'zh-Hant');
    },
  );

  test('mergeWith: 逐池對齊去重，保留本機並接上 incoming 較舊尾段', () {
    final local = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 5, 12),
      banners: {
        '1': [_rt(3, 30), _rt(2, 20)],
      },
    );
    final incoming = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: {
        '1': [_rt(2, 20), _rt(1, 10)],
      },
    );
    final merged = local.mergeWith(incoming);
    expect(merged.banners['1']!.map((r) => r.resourceId).toList(), [3, 2, 1]);
  });

  test('mergeWith: banner key 取聯集', () {
    final local = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: {
        '1': [_rt(1, 10)],
      },
    );
    final incoming = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: {
        '8': [_rt(2, 20)],
      },
    );
    final merged = local.mergeWith(incoming);
    expect(merged.banners.keys.toSet(), {'1', '8'});
    expect(merged.banners['1']!.single.resourceId, 1);
    expect(merged.banners['8']!.single.resourceId, 2);
  });

  test('mergeWith: lastUpdated 與 languageCode 取較新一方', () {
    final older = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: const {'1': []},
    );
    final newer = BannerStorage(
      playerId: 'p',
      languageCode: 'en',
      lastUpdated: DateTime.utc(2026, 5, 12),
      banners: const {'1': []},
    );
    final mergedA = older.mergeWith(newer);
    expect(mergedA.lastUpdated, DateTime.utc(2026, 5, 12));
    expect(mergedA.languageCode, 'en');
    final mergedB = newer.mergeWith(older);
    expect(mergedB.lastUpdated, DateTime.utc(2026, 5, 12));
    expect(mergedB.languageCode, 'en');
  });

  test('mergeWith: lastUpdated 相同 → languageCode 保留本機', () {
    final local = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: const {'1': []},
    );
    final incoming = BannerStorage(
      playerId: 'p',
      languageCode: 'ja',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: const {'1': []},
    );
    final merged = local.mergeWith(incoming);
    expect(merged.languageCode, 'zh-Hant'); // 時間相同 → 保留本機
    expect(merged.lastUpdated, DateTime.utc(2026, 1, 1));
  });

  test('mergeWith: 空本機 → 合併為 incoming 內容', () {
    final local = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: const {},
    );
    final incoming = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 5, 12),
      banners: {
        '1': [_rt(2, 20), _rt(1, 10)],
      },
    );
    final merged = local.mergeWith(incoming);
    expect(merged.banners['1']!.map((r) => r.resourceId).toList(), [2, 1]);
  });
}
