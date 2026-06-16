import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';

/// 假的 [GachaCapture]，直接回傳固定憑證而不啟動真實 MITM。
class _FakeCapture implements GachaCapture {
  _FakeCapture(this._cred);
  final GachaCredential? _cred;

  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(_cred), cancel: () async {});
}

/// 測試用憑證（語言 `zh-Hant`，屬於 9 個可選語言之一）。
GachaCredential _cred() => GachaCredential(
  playerId: '701000000',
  cardPoolId: '2e23deadbeef2768',
  serverId: '86d5deadbeef9650',
  recordId: '0632deadbeef8550',
  languageCode: 'zh-Hant',
);

String _ok(List<Map<String, dynamic>> data) =>
    jsonEncode({'code': 0, 'message': 'success', 'data': data});

/// 一筆 pool 1 喚取紀錄（resourceId 1211）。
Map<String, dynamic> _row() => {
  'cardPoolType': '1',
  'resourceId': 1211,
  'qualityLevel': 5,
  'resourceType': '角色',
  'name': '達妮婭',
  'count': 1,
  'time': '2026-05-21 10:39:03',
};

/// 建立標準測試容器，允許選擇性注入 [extraOverrides]。
ProviderContainer _makeContainer({
  required GachaStorage storage,
  required http.Client client,
  GachaCredential? captured,
  List<dynamic> extraOverrides = const [],
}) => ProviderContainer(
  overrides: [
    gachaStorageProvider.overrideWithValue(storage),
    gachaCaptureProvider.overrideWithValue(_FakeCapture(captured)),
    gachaFetcherProvider.overrideWithValue(
      GachaFetcher(rateLimit: Duration.zero),
    ),
    cancellableHttpClientFactoryProvider.overrideWithValue(
      () => CancellableHttpClient(client: client, cancel: () {}),
    ),
    ...extraOverrides,
  ],
);

/// Mock HTTP client：pool 1 回傳一筆紀錄，其餘空。
http.Client _mockClient() => MockClient((req) async {
  final body = jsonDecode(req.body) as Map<String, dynamic>;
  final type = body['cardPoolType'] as int;
  return http.Response(
    type == 1 ? _ok([_row()]) : _ok(const []),
    200,
    headers: {'content-type': 'application/json'},
  );
});

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('repo_datalang_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  // ─── 斷言 1：首次更新自動播種資料語言 ───

  test(
    'update() seeds dataLanguage from captured languageCode when unset',
    () async {
      // 未設定 dataLanguage（SharedPreferences 空）→ dataLanguageSeeded = false。
      SharedPreferences.setMockInitialValues({});
      final storage = GachaStorage(tempDir);

      final container = _makeContainer(
        storage: storage,
        client: _mockClient(),
        captured: _cred(),
      );
      addTearDown(container.dispose);

      // 讀入並等待 bootstrap 完成（settings load 發生於此）。
      container.read(gachaRepositoryProvider);
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

      // 更新前確認 dataLanguage 尚未設定。
      expect(container.read(settingsProvider).dataLanguage, isNull);
      expect(container.read(settingsProvider).dataLanguageSeeded, isFalse);

      await container.read(gachaRepositoryProvider.notifier).update();

      // 更新後 dataLanguage 應被播種為擷取語言 zh-Hant。
      expect(container.read(settingsProvider).dataLanguage, 'zh-Hant');
      expect(container.read(settingsProvider).dataLanguageSeeded, isTrue);
      // 同時確認進度正常完成。
      expect(
        container.read(gachaRepositoryProvider).progress,
        isA<UpdateCompleted>(),
      );
    },
  );

  test(
    'update() does not overwrite dataLanguage when already seeded',
    () async {
      // 已設定 dataLanguage = 'en'（seeded=true）→ 不應再被覆寫。
      SharedPreferences.setMockInitialValues({'pref.dataLanguage': 'en'});
      final storage = GachaStorage(tempDir);

      // 注入空目錄的 converter（dataLanguage='en' 但 catalog 空 → 所有紀錄 unresolved，
      // 保持原樣；重點是 seed 不被呼叫）。
      final fakeCatalog = LangCatalog(
        lang: 'en',
        fetchedAt: DateTime.utc(2026),
        byId: const {},
      );
      final fakeConverter = GachaLanguageConverter(
        ensureCatalog: (_) async => fakeCatalog,
      );

      final container = _makeContainer(
        storage: storage,
        client: _mockClient(),
        captured: _cred(),
        extraOverrides: [
          gachaLanguageConverterProvider.overrideWithValue(fakeConverter),
        ],
      );
      addTearDown(container.dispose);

      container.read(gachaRepositoryProvider);
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

      // 確認 settings 初始值正確（已透過 SharedPreferences 注入）。
      expect(container.read(settingsProvider).dataLanguage, 'en');
      expect(container.read(settingsProvider).dataLanguageSeeded, isTrue);

      await container.read(gachaRepositoryProvider.notifier).update();

      // dataLanguage 不應被更新為 zh-Hant。
      expect(container.read(settingsProvider).dataLanguage, 'en');
    },
  );

  // ─── 斷言 2：update() 觸發資料語言轉換 ───

  test(
    'update() converts saved BannerStorage names when dataLanguage is preset',
    () async {
      // 預設 dataLanguage = 'en'（已 seeded），模擬使用者事先選定語言。
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
          // 其他語言（src lang zh-Hant）回空 catalog（backfill 不需要，resourceId 已知）。
          return LangCatalog(
            lang: lang,
            fetchedAt: DateTime.utc(2026),
            byId: const {},
          );
        },
      );

      final container = _makeContainer(
        storage: storage,
        client: _mockClient(),
        captured: _cred(),
        extraOverrides: [
          gachaLanguageConverterProvider.overrideWithValue(fakeConverter),
        ],
      );
      addTearDown(container.dispose);

      container.read(gachaRepositoryProvider);
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

      await container.read(gachaRepositoryProvider.notifier).update();

      expect(
        container.read(gachaRepositoryProvider).progress,
        isA<UpdateCompleted>(),
      );

      // 驗證 in-memory state 中的紀錄已轉成英文名。
      final records = container
          .read(gachaRepositoryProvider)
          .byUid['701000000']
          ?.banners['1'];
      expect(records, isNotNull);
      expect(records, hasLength(1));
      expect(records!.first.name, 'Danjin');
      expect(records.first.languageCode, 'en');

      // 驗證寫入磁碟的存檔也已轉換（重新 load 確認）。
      final saved = await storage.load('701000000');
      expect(saved, isNotNull);
      final savedRecords = saved!.banners['1'];
      expect(savedRecords, hasLength(1));
      expect(savedRecords!.first.name, 'Danjin');
    },
  );
}
