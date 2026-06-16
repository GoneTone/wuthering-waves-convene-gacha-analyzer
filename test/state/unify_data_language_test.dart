import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';

// ─── Helper: GachaRecord ──────────────────────────────────────────────────────

/// 建立測試用 [GachaRecord]，[name] 代表資源名。
GachaRecord _rec(int resourceId, String name, {String lang = 'zh-Hant'}) =>
    GachaRecord(
      resourceId: resourceId,
      qualityLevel: 5,
      resourceType: '角色',
      cardPoolType: '1',
      name: name,
      count: 1,
      time: DateTime.utc(2026, 1, 1),
      languageCode: lang,
    );

// ─── Fake GachaLanguageConverter ─────────────────────────────────────────────

/// 假轉換器：把每筆紀錄的 [name] 附上 `@$targetLang` 後綴並更新該筆 `languageCode`；
/// 比照 production 不動帳號級 `BannerStorage.languageCode`。
///
/// 不呼叫任何網路，藉此隔離 unify 轉換邏輯與圖片補抓。
class _FakeConverter extends GachaLanguageConverter {
  /// 建立 [_FakeConverter]。
  _FakeConverter()
    : super(
        ensureCatalog: (_, {bool forceRefresh = false}) async => LangCatalog(
          lang: 'fake',
          fetchedAt: DateTime.utc(2026),
          byId: const {},
        ),
      );

  @override
  Future<({BannerStorage data, LangConvertResult result})> convert(
    BannerStorage data,
    String targetLang,
  ) async {
    final newBanners = <String, List<GachaRecord>>{};
    var total = 0;
    var converted = 0;
    data.banners.forEach((key, list) {
      final out = <GachaRecord>[];
      for (final r in list) {
        total++;
        out.add(
          r.copyWith(name: '${r.name}@$targetLang', languageCode: targetLang),
        );
        converted++;
      }
      newBanners[key] = out;
    });
    return (
      data: data.copyWith(banners: newBanners),
      result: LangConvertResult(total: total, converted: converted),
    );
  }
}

// ─── Container builder ────────────────────────────────────────────────────────

/// 建立可測試的 [ProviderContainer]；[useRealConverter] 為 false 時注入 [_FakeConverter]。
ProviderContainer _buildContainer({
  required Directory tempDir,
  bool useRealConverter = false,
}) {
  final mockClient = MockClient(
    (_) async => http.Response.bytes([1, 2, 3], 200),
  );
  return ProviderContainer(
    overrides: [
      gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
      itemImageIndexStorageProvider.overrideWithValue(
        ItemImageIndexStorage(tempDir),
      ),
      itemImageCacheDirProvider.overrideWithValue(tempDir),
      cancellableHttpClientFactoryProvider.overrideWithValue(
        () => CancellableHttpClient(client: mockClient, cancel: () {}),
      ),
      if (!useRealConverter)
        gachaLanguageConverterProvider.overrideWithValue(_FakeConverter()),
    ],
  );
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('unify_lang_test_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  // ── Assertion 1: Bootstrap seeding ─────────────────────────────────────────

  test('bootstrap seeding: 兩帳號不同語言，播種最新帳號（ja）', () async {
    final storage = GachaStorage(tempDir);
    // 較舊帳號：語言 en。
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'en',
        lastUpdated: DateTime.utc(2025, 1, 1),
        banners: const {'1': [], '2': []},
      ),
    );
    // 較新帳號：語言 ja（應被播種）。
    await storage.save(
      BannerStorage(
        playerId: '100000002',
        languageCode: 'ja',
        lastUpdated: DateTime.utc(2026, 6, 1),
        banners: const {'1': [], '2': []},
      ),
    );
    // SharedPreferences 初始為空（dataLanguage 未設定）。
    SharedPreferences.setMockInitialValues({});

    final container = _buildContainer(tempDir: tempDir);
    addTearDown(container.dispose);

    container.read(gachaRepositoryProvider);
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    final settings = container.read(settingsProvider);
    expect(settings.dataLanguage, 'ja', reason: '應播種最新帳號（100000002）的語言 ja');
    expect(settings.dataLanguageSeeded, isTrue);
  });

  test('bootstrap seeding: dataLanguage 已設定時不覆寫', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'ja',
        lastUpdated: DateTime.utc(2026, 6, 1),
        banners: const {'1': [], '2': []},
      ),
    );
    // 已播種 zh-Hant，不應被 ja 覆寫。
    SharedPreferences.setMockInitialValues({'pref.dataLanguage': 'zh-Hant'});

    final container = _buildContainer(tempDir: tempDir);
    addTearDown(container.dispose);

    container.read(gachaRepositoryProvider);
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    expect(container.read(settingsProvider).dataLanguage, 'zh-Hant');
  });

  test('bootstrap seeding: byUid 為空時不播種', () async {
    // 無任何帳號資料。
    SharedPreferences.setMockInitialValues({});

    final container = _buildContainer(tempDir: tempDir);
    addTearDown(container.dispose);

    container.read(gachaRepositoryProvider);
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    final settings = container.read(settingsProvider);
    expect(settings.dataLanguage, isNull);
    expect(settings.dataLanguageSeeded, isFalse);
  });

  // ── Assertion 2: unifyDataLanguage converts + aggregates ───────────────────

  test('unifyDataLanguage: 轉換兩帳號並聚合 LangConvertResult', () async {
    // 預設 dataLanguage = 'en'。
    SharedPreferences.setMockInitialValues({'pref.dataLanguage': 'en'});

    final storage = GachaStorage(tempDir);
    // 帳號 A：2 筆 zh-Hant 紀錄。
    final dataA = BannerStorage(
      playerId: '100000001',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: {
        '1': [_rec(1001, '角色A'), _rec(1002, '角色B')],
      },
    );
    // 帳號 B：1 筆 zh-Hant 紀錄。
    final dataB = BannerStorage(
      playerId: '100000002',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 2, 1),
      banners: {
        '1': [_rec(2001, '角色C')],
      },
    );
    await storage.save(dataA);
    await storage.save(dataB);

    final container = _buildContainer(tempDir: tempDir);
    addTearDown(container.dispose);

    final notifier = container.read(gachaRepositoryProvider.notifier);
    await notifier.waitForBootstrap();

    final result = await notifier.unifyDataLanguage();

    // 聚合計數：2 + 1 = 3 total、全部 converted。
    expect(result.total, 3);
    expect(result.converted, 3);

    // 驗證 in-memory state 已轉換。
    final stateAfter = container.read(gachaRepositoryProvider);
    final storedA = stateAfter.byUid['100000001']!;
    final storedB = stateAfter.byUid['100000002']!;

    // _FakeConverter 附加 @en 後綴。
    expect(storedA.banners['1']!.first.name, '角色A@en');
    expect(storedA.banners['1']![1].name, '角色B@en');
    expect(storedB.banners['1']!.first.name, '角色C@en');

    // 每筆紀錄的 languageCode 更新為目標語言（帳號級 languageCode 比照 production 不動）。
    expect(storedA.banners['1']!.first.languageCode, 'en');
    expect(storedB.banners['1']!.first.languageCode, 'en');

    // 驗證 storage 已持久化（重新載入並比較第一筆名稱）。
    final reloadedA = await storage.load('100000001');
    expect(reloadedA!.banners['1']!.first.name, '角色A@en');
    final reloadedB = await storage.load('100000002');
    expect(reloadedB!.banners['1']!.first.name, '角色C@en');
  });

  test('unifyDataLanguage: 立即設 Preparing 進度（dialog 即時彈出）', () async {
    SharedPreferences.setMockInitialValues({'pref.dataLanguage': 'en'});

    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 1, 1),
        banners: {
          '1': [_rec(1001, '角色A')],
        },
      ),
    );

    final container = _buildContainer(tempDir: tempDir);
    addTearDown(container.dispose);

    final notifier = container.read(gachaRepositoryProvider.notifier);
    await notifier.waitForBootstrap();

    // 不 await：async 函式同步執行到首個 await 前，應已設好 Preparing。
    final future = notifier.unifyDataLanguage();
    expect(container.read(gachaRepositoryProvider).progress, isA<Preparing>());
    await future;
  });

  test('unifyDataLanguage: 結束後清掉進度（避免 UpdateProgressDialog 卡住）', () async {
    // _fetchItemImages 會 emit FetchingItemImages 進度，app_shell 監聽 progress
    // 非 null 即彈出 UpdateProgressDialog（barrierDismissible:false、無關閉鈕）。
    // unify 結束必須把 progress 清回 null，否則該 dialog 永久卡在「取得物品資料」。
    SharedPreferences.setMockInitialValues({'pref.dataLanguage': 'en'});

    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 1, 1),
        banners: {
          '1': [_rec(1001, '角色A')],
        },
      ),
    );

    final container = _buildContainer(tempDir: tempDir);
    addTearDown(container.dispose);

    final notifier = container.read(gachaRepositoryProvider.notifier);
    await notifier.waitForBootstrap();

    await notifier.unifyDataLanguage();

    // 補圖階段結束後，progress 必須清空，否則進度 dialog 卡住不關。
    expect(container.read(gachaRepositoryProvider).progress, isNull);
  });

  test('unifyDataLanguage: dataLanguage 未設定時回零結果，不轉換', () async {
    // pref.dataLanguage = 'none' → dataLanguage = null、dataLanguageSeeded = true
    // （防止 bootstrap seeding 自動播種帳號語言覆蓋測試前提）。
    SharedPreferences.setMockInitialValues({'pref.dataLanguage': 'none'});

    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 1, 1),
        banners: {
          '1': [_rec(1001, '角色A')],
        },
      ),
    );

    final container = _buildContainer(tempDir: tempDir);
    addTearDown(container.dispose);

    final notifier = container.read(gachaRepositoryProvider.notifier);
    await notifier.waitForBootstrap();

    final result = await notifier.unifyDataLanguage();

    // 未設定語言 → 零結果、資料不動。
    expect(result.total, 0);
    expect(result.converted, 0);

    final stateAfter = container.read(gachaRepositoryProvider);
    // 名稱不應有 @xx 後綴。
    expect(stateAfter.byUid['100000001']!.banners['1']!.first.name, '角色A');
  });

  test('unifyDataLanguage: 單一帳號轉換失敗時吞例外、不中斷其他帳號', () async {
    SharedPreferences.setMockInitialValues({'pref.dataLanguage': 'en'});

    final storage = GachaStorage(tempDir);
    final dataA = BannerStorage(
      playerId: '100000001',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: {
        '1': [_rec(1001, '角色A')],
      },
    );
    final dataB = BannerStorage(
      playerId: 'FAIL_UID',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 2, 1),
      banners: {
        '1': [_rec(2001, '角色C')],
      },
    );
    await storage.save(dataA);
    await storage.save(dataB);

    // 針對 FAIL_UID 的 storage.save 注入失敗。
    final failStorage = _FailingStorage(tempDir, failOnUid: 'FAIL_UID');

    final mockClient = MockClient(
      (_) async => http.Response.bytes([1, 2, 3], 200),
    );
    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(failStorage),
        itemImageIndexStorageProvider.overrideWithValue(
          ItemImageIndexStorage(tempDir),
        ),
        itemImageCacheDirProvider.overrideWithValue(tempDir),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(client: mockClient, cancel: () {}),
        ),
        gachaLanguageConverterProvider.overrideWithValue(_FakeConverter()),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(gachaRepositoryProvider.notifier);
    await notifier.waitForBootstrap();

    // 不應拋出例外。
    final result = await notifier.unifyDataLanguage();

    // FAIL_UID 轉換失敗被吞，100000001 成功轉換。
    expect(result.total, greaterThanOrEqualTo(1));
    expect(result.converted, greaterThanOrEqualTo(1));

    // 100000001 的名稱已轉換（附後綴）。
    final stateAfter = container.read(gachaRepositoryProvider);
    expect(stateAfter.byUid['100000001']!.banners['1']!.first.name, '角色A@en');
  });
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// 對指定 [failOnUid] 的 [save] 會拋出例外的測試用 storage。
class _FailingStorage extends GachaStorage {
  /// 建立 [_FailingStorage]。
  _FailingStorage(super.baseDir, {required this.failOnUid});

  /// 儲存失敗的目標 UID。
  final String failOnUid;

  @override
  Future<void> save(BannerStorage data) async {
    if (data.playerId == failOnUid) throw Exception('simulated save failure');
    return super.save(data);
  }
}
