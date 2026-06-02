import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';

void main() {
  late Directory tempDir;
  late GachaStorage storage;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gacha_test_');
    storage = GachaStorage(tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  GachaRecord makeRecord(int id) => GachaRecord(
    resourceId: id,
    qualityLevel: 5,
    resourceType: '角色',
    cardPoolType: '1',
    name: '達妮婭',
    count: 1,
    time: DateTime(2026, 5, 21, 10, 39, 3),
  );

  BannerStorage makeStorage(String playerId) => BannerStorage(
    playerId: playerId,
    languageCode: 'zh-Hant',
    lastUpdated: DateTime.utc(2026, 5, 21),
    banners: {
      '1': [makeRecord(1211)],
      '8': [],
    },
  );

  test('save → 檔名為 <playerId>.records.json', () async {
    await storage.save(makeStorage('701000000'));
    expect(
      await File('${tempDir.path}/701000000.records.json').exists(),
      isTrue,
    );
  });

  test('save → load roundtrip', () async {
    await storage.save(makeStorage('701000000'));
    final loaded = await storage.load('701000000');
    expect(loaded, isNotNull);
    expect(loaded!.playerId, '701000000');
    expect(loaded.languageCode, 'zh-Hant');
    expect(loaded.banners['1']!.single.resourceId, 1211);
  });

  test('load 不存在的 playerId → null', () async {
    expect(await storage.load('not_exist'), isNull);
  });

  test('load 遇不相容舊版格式（缺 resource_id）→ 跳過回 null + 不 rethrow', () async {
    // 模擬殘留的不相容舊版 schema 檔（手動以 .records.json 命名）
    await File('${tempDir.path}/legacy.records.json').writeAsString(
      '{"player_id":"legacy","language_code":"zh-tw",'
      '"last_updated":"2026-01-01T00:00:00.000Z",'
      '"banners":{"301":[{"id":"1","uid":"legacy","gacha_type":"301",'
      '"name":"x","item_type":"角色","rank_type":5,'
      '"time":"2025-01-01 00:00:00","lang":"zh-tw"}]}}',
    );
    final loaded = await storage.load('legacy');
    expect(loaded, isNull);
  });

  test('listKnownUids 只列 <playerId>.records.json，忽略 cred 與 metadata', () async {
    await File('${tempDir.path}/701.records.json').writeAsString('{}');
    await File('${tempDir.path}/abc.records.json').writeAsString('{}');
    await File('${tempDir.path}/701.cred.json').writeAsString('{}');
    await File('${tempDir.path}/item_image_index.json').writeAsString('{}');
    await File('${tempDir.path}/garbage.txt').writeAsString('');

    final uids = await storage.listKnownUids();
    expect(uids.toSet(), {'701', 'abc'});
  });

  test(
    'saveCapturedCredential / loadCapturedCredential / deleteCapturedCredential',
    () async {
      const body =
          '{"playerId":"701","cardPoolId":"x","serverId":"y",'
          '"languageCode":"zh-Hant","recordId":"z"}';
      await storage.saveCapturedCredential('701', body);
      expect(await storage.loadCapturedCredential('701'), body);

      await storage.deleteCapturedCredential('701');
      expect(await storage.loadCapturedCredential('701'), isNull);
    },
  );

  test('cred 檔名為 <playerId>.cred.json', () async {
    await storage.saveCapturedCredential('701', '{"playerId":"701"}');
    expect(await File('${tempDir.path}/701.cred.json').exists(), isTrue);
  });

  test('save 用 atomic rename：.tmp 不殘留', () async {
    await storage.save(makeStorage('1'));
    expect(await File('${tempDir.path}/1.records.json.tmp').exists(), isFalse);
  });

  test('save 同一 playerId 兩次 → 第二份覆蓋第一份', () async {
    await storage.save(makeStorage('999'));
    final v2 = makeStorage('999').copyWith(
      lastUpdated: DateTime.utc(2026, 6, 1),
      banners: {
        '1': [makeRecord(9999)],
        '8': [],
      },
    );
    await storage.save(v2);
    final loaded = await storage.load('999');
    expect(loaded!.banners['1']!.single.resourceId, 9999);
    expect(loaded.lastUpdated, DateTime.utc(2026, 6, 1));
  });

  test('delete 移除 records 與 cred 檔', () async {
    await storage.save(makeStorage('701'));
    await storage.saveCapturedCredential('701', '{"playerId":"701"}');
    await storage.delete('701');
    expect(await File('${tempDir.path}/701.records.json').exists(), isFalse);
    expect(await File('${tempDir.path}/701.cred.json').exists(), isFalse);
  });
}
