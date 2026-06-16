import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';

/// 假的 [GachaCapture]，不啟動真實 MITM。
class _FakeCapture implements GachaCapture {
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(null), cancel: () async {});
}

/// 建立標準測試容器。
ProviderContainer _makeContainer({
  required GachaStorage storage,
  List<dynamic> extraOverrides = const [],
}) => ProviderContainer(
  overrides: [
    gachaStorageProvider.overrideWithValue(storage),
    gachaCaptureProvider.overrideWithValue(_FakeCapture()),
    cancellableHttpClientFactoryProvider.overrideWithValue(
      () => CancellableHttpClient(
        client: MockClient((_) async => http.Response('{}', 200)),
        cancel: () {},
      ),
    ),
    ...extraOverrides,
  ],
);

/// 建立一筆測試喚取紀錄（resourceId [id]，name [name]，languageCode [lang]）。
GachaRecord _record(int id, String name, String lang) => GachaRecord(
  resourceId: id,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: '1',
  name: name,
  count: 1,
  time: DateTime(2026, 5, 21, 11, 0, 0),
  languageCode: lang,
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('import_datalang_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  // ─── 斷言 1：首次匯入自動播種資料語言 ───

  test(
    'importAccounts seeds dataLanguage from account with newest lastUpdated',
    () async {
      // dataLanguage 未設定（空 SharedPreferences）。
      final storage = GachaStorage(tempDir);

      final container = _makeContainer(storage: storage);
      addTearDown(container.dispose);

      container.read(gachaRepositoryProvider);
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

      // 確認匯入前 dataLanguage 尚未設定。
      expect(container.read(settingsProvider).dataLanguage, isNull);
      expect(container.read(settingsProvider).dataLanguageSeeded, isFalse);

      // 兩個帳號：A 較舊（zh-Hant），B 較新（en）→ 播種應取 B 的語言 'en'。
      final accountA = BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 1, 1),
        banners: const {'1': []},
      );
      final accountB = BannerStorage(
        playerId: '100000002',
        languageCode: 'en',
        lastUpdated: DateTime.utc(2026, 6, 1),
        banners: const {'1': []},
      );
      final bundle = AccountsBundle(
        exportedAt: DateTime.utc(2026, 6, 1),
        appVersion: 'x',
        lastActiveUid: null,
        accounts: [
          ExportedAccount(data: accountA),
          ExportedAccount(data: accountB),
        ],
      );

      await container
          .read(gachaRepositoryProvider.notifier)
          .debugImportOnly(bundle);

      // 播種語言應為最新帳號（B）的語言 'en'。
      expect(container.read(settingsProvider).dataLanguage, 'en');
      expect(container.read(settingsProvider).dataLanguageSeeded, isTrue);
    },
  );

  test(
    'importAccounts does not overwrite dataLanguage when already seeded',
    () async {
      // 已播種 dataLanguage = 'zh-Hant'。
      SharedPreferences.setMockInitialValues({'pref.dataLanguage': 'zh-Hant'});
      final storage = GachaStorage(tempDir);

      final container = _makeContainer(storage: storage);
      addTearDown(container.dispose);

      container.read(gachaRepositoryProvider);
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

      expect(container.read(settingsProvider).dataLanguage, 'zh-Hant');
      expect(container.read(settingsProvider).dataLanguageSeeded, isTrue);

      final bundle = AccountsBundle(
        exportedAt: DateTime.utc(2026, 6, 1),
        appVersion: 'x',
        lastActiveUid: null,
        accounts: [
          ExportedAccount(
            data: BannerStorage(
              playerId: '100000001',
              languageCode: 'en',
              lastUpdated: DateTime.utc(2026, 6, 1),
              banners: const {'1': []},
            ),
          ),
        ],
      );

      await container
          .read(gachaRepositoryProvider.notifier)
          .debugImportOnly(bundle);

      // 已 seeded → 不應被 bundle 帳號語言（en）覆蓋。
      expect(container.read(settingsProvider).dataLanguage, 'zh-Hant');
    },
  );

  test('importAccounts picks newest-lastUpdated account language for seeding '
      'regardless of bundle order', () async {
    // bundle 順序：較新帳號在前、較舊帳號在後；仍應以較新者播種。
    final storage = GachaStorage(tempDir);
    final container = _makeContainer(storage: storage);
    addTearDown(container.dispose);

    container.read(gachaRepositoryProvider);
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    final newer = BannerStorage(
      playerId: '100000001',
      languageCode: 'ja',
      lastUpdated: DateTime.utc(2026, 6, 15),
      banners: const {'1': []},
    );
    final older = BannerStorage(
      playerId: '100000002',
      languageCode: 'ko',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: const {'1': []},
    );
    // bundle 裡較新帳號先放（順序不影響結果）。
    final bundle = AccountsBundle(
      exportedAt: DateTime.utc(2026, 6, 15),
      appVersion: 'x',
      lastActiveUid: null,
      accounts: [
        ExportedAccount(data: newer),
        ExportedAccount(data: older),
      ],
    );

    await container
        .read(gachaRepositoryProvider.notifier)
        .debugImportOnly(bundle);

    expect(container.read(settingsProvider).dataLanguage, 'ja');
  });

  // ─── 斷言 2：convert before save ───

  test(
    'importAccounts converts BannerStorage names to dataLanguage before saving',
    () async {
      // 預設 dataLanguage = 'en'（已 seeded）。
      SharedPreferences.setMockInitialValues({'pref.dataLanguage': 'en'});
      final storage = GachaStorage(tempDir);

      // Fake catalog：resourceId 1211 → 英文名 'Danjin'。
      final enCatalog = LangCatalog(
        lang: 'en',
        fetchedAt: DateTime.utc(2026),
        byId: {1211: (name: 'Danjin', kind: 'character')},
      );
      final fakeConverter = GachaLanguageConverter(
        ensureCatalog: (lang) async {
          if (lang == 'en') return enCatalog;
          return LangCatalog(
            lang: lang,
            fetchedAt: DateTime.utc(2026),
            byId: const {},
          );
        },
      );

      final container = _makeContainer(
        storage: storage,
        extraOverrides: [
          gachaLanguageConverterProvider.overrideWithValue(fakeConverter),
        ],
      );
      addTearDown(container.dispose);

      container.read(gachaRepositoryProvider);
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

      final record = _record(1211, '達妮婭', 'zh-Hant');
      final bundle = AccountsBundle(
        exportedAt: DateTime.utc(2026, 6, 1),
        appVersion: 'x',
        lastActiveUid: null,
        accounts: [
          ExportedAccount(
            data: BannerStorage(
              playerId: '100000001',
              languageCode: 'zh-Hant',
              lastUpdated: DateTime.utc(2026, 6, 1),
              banners: {
                '1': [record],
              },
            ),
          ),
        ],
      );

      await container
          .read(gachaRepositoryProvider.notifier)
          .debugImportOnly(bundle);

      // 驗證 in-memory state 中的紀錄已轉成英文名。
      final inMemory = container
          .read(gachaRepositoryProvider)
          .byUid['100000001']
          ?.banners['1'];
      expect(inMemory, isNotNull);
      expect(inMemory, hasLength(1));
      expect(inMemory!.first.name, 'Danjin');
      expect(inMemory.first.languageCode, 'en');

      // 驗證寫入磁碟的存檔也已轉換（重新 load 確認）。
      final saved = await storage.load('100000001');
      expect(saved, isNotNull);
      final savedRecords = saved!.banners['1'];
      expect(savedRecords, hasLength(1));
      expect(savedRecords!.first.name, 'Danjin');
    },
  );

  test(
    'importAccounts record counts (added/duplicate) are unaffected by conversion',
    () async {
      // conversion 不改變 record 數量，added/duplicate 計算應正確。
      SharedPreferences.setMockInitialValues({'pref.dataLanguage': 'en'});
      final storage = GachaStorage(tempDir);

      // 預先存一筆 record（id 1211）在本機。
      await storage.save(
        BannerStorage(
          playerId: '100000001',
          languageCode: 'zh-Hant',
          lastUpdated: DateTime.utc(2026, 1, 1),
          banners: {
            '1': [_record(1211, '達妮婭', 'zh-Hant')],
          },
        ),
      );

      final enCatalog = LangCatalog(
        lang: 'en',
        fetchedAt: DateTime.utc(2026),
        byId: {
          1211: (name: 'Danjin', kind: 'character'),
          9999: (name: 'NewChar', kind: 'character'),
        },
      );
      final fakeConverter = GachaLanguageConverter(
        ensureCatalog: (lang) async {
          if (lang == 'en') return enCatalog;
          return LangCatalog(
            lang: lang,
            fetchedAt: DateTime.utc(2026),
            byId: const {},
          );
        },
      );

      final container = _makeContainer(
        storage: storage,
        extraOverrides: [
          gachaLanguageConverterProvider.overrideWithValue(fakeConverter),
        ],
      );
      addTearDown(container.dispose);

      container.read(gachaRepositoryProvider);
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

      // bundle：含一筆重複（id 1211）與一筆新增（id 9999）。
      final bundle = AccountsBundle(
        exportedAt: DateTime.utc(2026, 6, 1),
        appVersion: 'x',
        lastActiveUid: null,
        accounts: [
          ExportedAccount(
            data: BannerStorage(
              playerId: '100000001',
              languageCode: 'zh-Hant',
              lastUpdated: DateTime.utc(2026, 6, 1),
              banners: {
                '1': [
                  _record(1211, '達妮婭', 'zh-Hant'),
                  _record(9999, '新角色', 'zh-Hant'),
                ],
              },
            ),
          ),
        ],
      );

      final result = await container
          .read(gachaRepositoryProvider.notifier)
          .debugImportOnly(bundle);

      // 計數不受轉換影響。
      expect(result.addedRecords, 1); // id 9999 是新的
      expect(result.duplicateRecords, 1); // id 1211 已存在
      expect(result.successAccounts, 1);
    },
  );
}
