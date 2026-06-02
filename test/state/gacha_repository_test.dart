import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/settings_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCapture implements GachaCapture {
  _FakeCapture(this._cred);
  final GachaCredential? _cred;

  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(_cred), cancel: () async {});
}

/// 測試用虛假憑證。
GachaCredential _fakeCred() => GachaCredential(
  playerId: '100000001',
  cardPoolId: '2e23deadbeef2768',
  serverId: '86d5deadbeef9650',
  recordId: '0632deadbeef8550',
  languageCode: 'zh-Hant',
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('repo_test_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('bootstrap load 空目錄 → state 為空', () async {
    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async {
              throw 'unreachable';
            }),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final initial = container.read(gachaRepositoryProvider);
    expect(initial.activeUid, isNull);
    expect(initial.byUid, isEmpty);

    // 等 bootstrap fire-and-forget 完成
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final after = container.read(gachaRepositoryProvider);
    expect(after.activeUid, isNull);
  });

  test('bootstrap load 有 2 個 UID 檔 → activeUid = 較新者', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 1, 1),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    await storage.save(
      BannerStorage(
        playerId: '100000002',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 9), // 較新
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );

    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('{}', 200)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(gachaRepositoryProvider);
    expect(state.knownUids.toSet(), {'100000001', '100000002'});
    expect(state.activeUid, '100000002');
  });

  test('update() 立刻設定 Preparing（在第一個 await 之前）', () async {
    final storage = GachaStorage(tempDir);
    // seed cached credential，update 走 fetch 路徑（不進 MITM）
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    await storage.saveCapturedCredential(
      '100000001',
      _fakeCred().toJsonString(),
    );

    // 用一個永遠不 complete 的 Completer 阻塞 HTTP，這樣 _runUpdate
    // 在進到 probe 階段時會卡住，state 維持在 Preparing
    final block = Completer<http.Response>();
    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) => block.future),
            cancel: () {
              if (!block.isCompleted) {
                block.completeError(http.ClientException('cancelled'));
              }
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50)); // bootstrap

    final notifier = container.read(gachaRepositoryProvider.notifier);
    final updateFut = notifier.update();

    // update() 在第一個 await 之前同步 emit Preparing；此刻尚未跑任何 microtask，
    // state.progress 應已是 Preparing（ref.listen 可立刻彈出 dialog）。
    expect(
      container.read(gachaRepositoryProvider).progress,
      isA<Preparing>(),
      reason: 'update() 應在第一個 await 之前同步設定 Preparing',
    );

    // 跑數輪 microtask，讓 loadCapturedCredential 完成、進到第一池 fetchPool 並
    // await 永不 complete 的 mock client；此刻 state 已推進到 FetchingBanner。
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      container.read(gachaRepositoryProvider).progress,
      isA<FetchingBanner>(),
      reason: '取得快取憑證後直接進首池抓取，state 應為 FetchingBanner',
    );

    // cleanup
    notifier.cancelPreparing();
    await updateFut;
  });

  test('cancelPreparing → 中斷 HTTP → progress 回到 null', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    await storage.saveCapturedCredential(
      '100000001',
      _fakeCred().toJsonString(),
    );

    final block = Completer<http.Response>();
    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) => block.future),
            cancel: () {
              if (!block.isCompleted) {
                block.completeError(http.ClientException('cancelled by test'));
              }
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final notifier = container.read(gachaRepositoryProvider.notifier);
    final updateFut = notifier.update();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    notifier.cancelPreparing();
    await updateFut;

    // progress 應為 null（取消），不是 UpdateFailed
    expect(container.read(gachaRepositoryProvider).progress, isNull);
    // 既有資料保留
    expect(container.read(gachaRepositoryProvider).activeUid, '100000001');
  });

  test('probe 階段真實 ClientException（非取消） → UpdateFailed', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    await storage.saveCapturedCredential(
      '100000001',
      _fakeCred().toJsonString(),
    );

    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((req) {
              throw http.ClientException('network down', req.url);
            }),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await container.read(gachaRepositoryProvider.notifier).update();

    final progress = container.read(gachaRepositoryProvider).progress;
    expect(progress, isA<UpdateFailed>());
    expect((progress as UpdateFailed).error, isA<UpdateErrorOther>());
  });

  test('clearProgress 把 progress 重設為 null', () async {
    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('{}', 200)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(gachaRepositoryProvider.notifier);
    // 等 bootstrap 完成，避免 async 工作洩漏到測試邊界後
    await Future<void>.delayed(const Duration(milliseconds: 50));

    notifier.debugSetProgress(const UpdateFailed(UpdateErrorOther('test')));
    expect(
      container.read(gachaRepositoryProvider).progress,
      isA<UpdateFailed>(),
    );

    notifier.clearProgress();
    expect(container.read(gachaRepositoryProvider).progress, isNull);
  });

  test('bootstrap：lastActiveUid 命中 → 用它（不用最新）', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 1, 1),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    await storage.save(
      BannerStorage(
        playerId: '100000002',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 9), // 較新
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    SharedPreferences.setMockInitialValues({'pref.lastActiveUid': '100000001'});

    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('{}', 200)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(gachaRepositoryProvider).activeUid, '100000001');
  });

  test(
    'bootstrap：lastActiveUid 失效 → fallback 為 mergeUidOrder.first 並寫回',
    () async {
      final storage = GachaStorage(tempDir);
      await storage.save(
        BannerStorage(
          playerId: '100000001',
          languageCode: 'zh-Hant',
          lastUpdated: DateTime.utc(2026, 1, 1),
          banners: const {
            '1': [],
            '2': [],
            '3': [],
            '4': [],
            '5': [],
            '6': [],
            '8': [],
            '9': [],
          },
        ),
      );
      await storage.save(
        BannerStorage(
          playerId: '100000002',
          languageCode: 'zh-Hant',
          lastUpdated: DateTime.utc(2026, 5, 9),
          banners: const {
            '1': [],
            '2': [],
            '3': [],
            '4': [],
            '5': [],
            '6': [],
            '8': [],
            '9': [],
          },
        ),
      );
      SharedPreferences.setMockInitialValues({'pref.lastActiveUid': 'GHOST'});

      final container = ProviderContainer(
        overrides: [
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(
              client: MockClient((_) async => http.Response('{}', 200)),
              cancel: () {},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        container.read(gachaRepositoryProvider).activeUid,
        '100000002',
      ); // 較新
      // 寫回 settings
      final reloaded = await SettingsStorage.load();
      expect(reloaded.lastActiveUid, '100000002');
    },
  );

  test('bootstrap：lastActiveUid 為 null → fallback 為最新並寫回', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 9),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );

    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('{}', 200)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(gachaRepositoryProvider).activeUid, '100000001');
    final reloaded = await SettingsStorage.load();
    expect(reloaded.lastActiveUid, '100000001');
  });

  test('bootstrap：uidOrder 影響 fallback 順序', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 1, 1),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    await storage.save(
      BannerStorage(
        playerId: '100000002',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 9),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    SharedPreferences.setMockInitialValues({
      'pref.uidOrder': '["100000001","100000002"]', // 自訂 100000001 在前
    });

    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('{}', 200)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // lastActiveUid 為 null → fallback 走 mergeUidOrder.first → 自訂順序的第一個 = 100000001
    expect(container.read(gachaRepositoryProvider).activeUid, '100000001');
  });

  test('setActiveUid 寫入 settings.lastActiveUid', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 1, 1),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    await storage.save(
      BannerStorage(
        playerId: '100000002',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 9),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );

    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('{}', 200)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await container
        .read(gachaRepositoryProvider.notifier)
        .setActiveUid('100000001');
    expect(container.read(gachaRepositoryProvider).activeUid, '100000001');
    final reloaded = await SettingsStorage.load();
    expect(reloaded.lastActiveUid, '100000001');
  });

  test('removeUid（非 active）→ 清 alias/order，lastActiveUid 不變', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 9),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    await storage.save(
      BannerStorage(
        playerId: '100000002',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 1, 1),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    SharedPreferences.setMockInitialValues({
      'pref.lastActiveUid': '100000001',
      'pref.uidAliases': '{"100000001":"主","100000002":"小"}',
      'pref.uidOrder': '["100000001","100000002"]',
    });

    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('{}', 200)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await container
        .read(gachaRepositoryProvider.notifier)
        .removeUid('100000002');
    expect(container.read(gachaRepositoryProvider).activeUid, '100000001');
    final s = await SettingsStorage.load();
    expect(s.lastActiveUid, '100000001');
    expect(s.uidAliases, {'100000001': '主'});
    expect(s.uidOrder, ['100000001']);
  });

  test('removeUid（active）→ fallback 新 active 並寫回 lastActiveUid', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 9),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    await storage.save(
      BannerStorage(
        playerId: '100000002',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 1, 1),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    SharedPreferences.setMockInitialValues({'pref.lastActiveUid': '100000001'});

    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('{}', 200)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await container
        .read(gachaRepositoryProvider.notifier)
        .removeUid('100000001');
    expect(container.read(gachaRepositoryProvider).activeUid, '100000002');
    final s = await SettingsStorage.load();
    expect(s.lastActiveUid, '100000002');
  });

  test('removeUid（最後一個）→ activeUid = null 且 lastActiveUid = null', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 9),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    SharedPreferences.setMockInitialValues({'pref.lastActiveUid': '100000001'});

    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('{}', 200)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await container
        .read(gachaRepositoryProvider.notifier)
        .removeUid('100000001');
    expect(container.read(gachaRepositoryProvider).activeUid, isNull);
    final s = await SettingsStorage.load();
    expect(s.lastActiveUid, isNull);
  });

  test('clearActive 委派給 removeUid', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 9),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    await storage.save(
      BannerStorage(
        playerId: '100000002',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 1, 1),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    SharedPreferences.setMockInitialValues({'pref.lastActiveUid': '100000001'});

    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('{}', 200)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await container.read(gachaRepositoryProvider.notifier).clearActive();
    expect(container.read(gachaRepositoryProvider).activeUid, '100000002');
    final s = await SettingsStorage.load();
    expect(s.lastActiveUid, '100000002');
  });

  test('clearAll 清掉所有 UID 偏好', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 9),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );
    SharedPreferences.setMockInitialValues({
      'pref.lastActiveUid': '100000001',
      'pref.uidAliases': '{"100000001":"主"}',
      'pref.uidOrder': '["100000001"]',
    });

    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('{}', 200)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await container.read(gachaRepositoryProvider.notifier).clearAll();
    expect(container.read(gachaRepositoryProvider).activeUid, isNull);
    final s = await SettingsStorage.load();
    expect(s.lastActiveUid, isNull);
    expect(s.uidAliases, isEmpty);
    expect(s.uidOrder, isEmpty);
  });

  test('setActiveUid 不存在的 UID → 不變、不寫 settings', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 9),
        banners: const {
          '1': [],
          '2': [],
          '3': [],
          '4': [],
          '5': [],
          '6': [],
          '8': [],
          '9': [],
        },
      ),
    );

    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('{}', 200)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final beforeReload = await SettingsStorage.load();
    await container
        .read(gachaRepositoryProvider.notifier)
        .setActiveUid('GHOST');
    expect(
      container.read(gachaRepositoryProvider).activeUid,
      '100000001',
    ); // 不變
    final afterReload = await SettingsStorage.load();
    expect(afterReload.lastActiveUid, beforeReload.lastActiveUid);
  });

  test(
    'importAccounts: per-UID overwrite preserves non-imported accounts',
    () async {
      final storage = GachaStorage(tempDir);
      // Existing: 100000001 (old data), 100000003 (untouched)
      await storage.save(
        BannerStorage(
          playerId: '100000001',
          languageCode: 'zh-Hant',
          lastUpdated: DateTime.utc(2026, 1, 1),
          banners: const {'301': []},
        ),
      );
      await storage.save(
        BannerStorage(
          playerId: '100000003',
          languageCode: 'zh-Hant',
          lastUpdated: DateTime.utc(2026, 1, 1),
          banners: const {'301': []},
        ),
      );
      SharedPreferences.setMockInitialValues({
        'pref.uidAliases': jsonEncode({'100000003': '另一支'}),
      });

      final container = ProviderContainer(
        overrides: [
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(
              client: MockClient((_) async => http.Response('{}', 200)),
              cancel: () {},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final newA = BannerStorage(
        playerId: '100000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 12),
        banners: const {'301': [], '302': []},
      );
      final newB = BannerStorage(
        playerId: '100000002',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 12),
        banners: const {'301': []},
      );
      final bundle = AccountsBundle(
        exportedAt: DateTime.utc(2026, 5, 12),
        appVersion: 'x',
        lastActiveUid: '100000001',
        accounts: [
          ExportedAccount(data: newA, alias: '主號'),
          ExportedAccount(data: newB),
        ],
      );

      final result = await container
          .read(gachaRepositoryProvider.notifier)
          .debugImportOnly(bundle);

      expect(result.failedUids, isEmpty);
      expect(result.successAccounts, 2);

      final state = container.read(gachaRepositoryProvider);
      expect(state.byUid.keys.toSet(), {'100000001', '100000002', '100000003'});
      // 100000001 overwritten
      expect(state.byUid['100000001']!.lastUpdated, DateTime.utc(2026, 5, 12));
      // 100000003 preserved
      expect(state.byUid['100000003']!.lastUpdated, DateTime.utc(2026, 1, 1));
      expect(state.activeUid, '100000001');

      // Settings: alias on 100000001 (from bundle), alias on 100000003 (pre-existing, preserved)
      final settings = container.read(settingsProvider);
      expect(settings.uidAliases, {'100000001': '主號', '100000003': '另一支'});
      expect(settings.uidOrder.take(2).toList(), ['100000001', '100000002']);
      expect(settings.lastActiveUid, '100000001');
    },
  );

  test(
    'importAccounts: uidOrder merges imported order first, then remaining',
    () async {
      final storage = GachaStorage(tempDir);
      for (final uid in ['100000001', '100000003', '100000004']) {
        await storage.save(
          BannerStorage(
            playerId: uid,
            languageCode: 'zh-Hant',
            lastUpdated: DateTime.utc(2026, 1, 1),
            banners: const {'301': []},
          ),
        );
      }

      SharedPreferences.setMockInitialValues({
        'pref.uidOrder': jsonEncode(['100000004', '100000001', '100000003']),
      });

      final container = ProviderContainer(
        overrides: [
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(
              client: MockClient((_) async => http.Response('{}', 200)),
              cancel: () {},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final bundle = AccountsBundle(
        exportedAt: DateTime.utc(2026, 5, 12),
        appVersion: 'x',
        lastActiveUid: null,
        accounts: [
          ExportedAccount(
            data: BannerStorage(
              playerId: '100000002',
              languageCode: 'zh-Hant',
              lastUpdated: DateTime.utc(2026, 5, 12),
              banners: const {'301': []},
            ),
          ),
          ExportedAccount(
            data: BannerStorage(
              playerId: '100000001',
              languageCode: 'zh-Hant',
              lastUpdated: DateTime.utc(2026, 5, 12),
              banners: const {'301': []},
            ),
          ),
        ],
      );

      await container
          .read(gachaRepositoryProvider.notifier)
          .debugImportOnly(bundle);

      final order = container.read(settingsProvider).uidOrder;
      // imported [100000002, 100000001] first, then remaining custom order minus imported = [100000004, 100000003]
      expect(order, ['100000002', '100000001', '100000004', '100000003']);
    },
  );

  test(
    'importAccounts: storage write failure marks UID failed and skips it',
    () async {
      // Inject a storage that fails on UID == "100000002"
      final storage = _FailingStorage(tempDir, failOnUid: '100000002');
      final container = ProviderContainer(
        overrides: [
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(
              client: MockClient((_) async => http.Response('{}', 200)),
              cancel: () {},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final bundle = AccountsBundle(
        exportedAt: DateTime.utc(2026, 5, 12),
        appVersion: 'x',
        lastActiveUid: '100000002',
        accounts: [
          ExportedAccount(
            data: BannerStorage(
              playerId: '100000001',
              languageCode: 'zh-Hant',
              lastUpdated: DateTime.utc(2026, 5, 12),
              banners: const {'301': []},
            ),
            alias: '主號',
          ),
          ExportedAccount(
            data: BannerStorage(
              playerId: '100000002',
              languageCode: 'zh-Hant',
              lastUpdated: DateTime.utc(2026, 5, 12),
              banners: const {'301': []},
            ),
          ),
        ],
      );

      final result = await container
          .read(gachaRepositoryProvider.notifier)
          .debugImportOnly(bundle);

      expect(result.failedUids, ['100000002']);
      expect(result.successAccounts, 1);

      final state = container.read(gachaRepositoryProvider);
      expect(state.byUid.keys, ['100000001']);
      // lastActiveUid asked for 100000002 (failed) → falls back to 100000001
      expect(state.activeUid, '100000001');
      // uidOrder doesn't contain failed 100000002
      expect(
        container.read(settingsProvider).uidOrder.contains('100000002'),
        isFalse,
      );
    },
  );

  test(
    'importAccounts: bundle lastActiveUid switches active to it when imported',
    () async {
      final storage = GachaStorage(tempDir);
      // Existing active = 200000001 (will remain after import)
      await storage.save(
        BannerStorage(
          playerId: '200000001',
          languageCode: 'zh-Hant',
          lastUpdated: DateTime.utc(2026, 1, 1),
          banners: const {'301': []},
        ),
      );
      SharedPreferences.setMockInitialValues({
        'pref.lastActiveUid': '200000001',
      });

      final container = ProviderContainer(
        overrides: [
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(
              client: MockClient((_) async => http.Response('{}', 200)),
              cancel: () {},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(gachaRepositoryProvider).activeUid, '200000001');

      final bundle = AccountsBundle(
        exportedAt: DateTime.utc(2026, 5, 12),
        appVersion: 'x',
        lastActiveUid: '200000002',
        accounts: [
          ExportedAccount(
            data: BannerStorage(
              playerId: '200000002',
              languageCode: 'zh-Hant',
              lastUpdated: DateTime.utc(2026, 5, 12),
              banners: const {'301': []},
            ),
          ),
        ],
      );

      await container
          .read(gachaRepositoryProvider.notifier)
          .debugImportOnly(bundle);

      expect(container.read(gachaRepositoryProvider).activeUid, '200000002');
      expect(container.read(settingsProvider).lastActiveUid, '200000002');
    },
  );
  group('logging instrumentation', () {
    setUp(() {
      Logger.root.level = Level.ALL;
    });

    tearDown(() {
      Logger.root.clearListeners();
    });

    test('emits update start and update completed on happy path', () async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      final storage = GachaStorage(tempDir);
      await storage.save(
        BannerStorage(
          playerId: '100000001',
          languageCode: 'zh-Hant',
          lastUpdated: DateTime.utc(2026),
          banners: const {
            '1': [],
            '2': [],
            '3': [],
            '4': [],
            '5': [],
            '6': [],
            '8': [],
            '9': [],
          },
        ),
      );
      await storage.saveCapturedCredential(
        '100000001',
        _fakeCred().toJsonString(),
      );

      final container = ProviderContainer(
        overrides: [
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(
              client: MockClient((req) async {
                // 第一池回傳一筆紀錄、其餘空 → 走 happy path（非 NoRecords），
                // 確保抵達 `update completed` log。
                final body = jsonDecode(req.body) as Map<String, dynamic>;
                final type = body['cardPoolType'] as int;
                final data = type == 1
                    ? <Map<String, dynamic>>[
                        {
                          'cardPoolType': '1',
                          'resourceId': 1211,
                          'qualityLevel': 5,
                          'resourceType': '角色',
                          'name': '達妮婭',
                          'count': 1,
                          'time': '2026-05-21 10:39:03',
                        },
                      ]
                    : const <Map<String, dynamic>>[];
                return http.Response(
                  jsonEncode({'code': 0, 'message': 'success', 'data': data}),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }),
              cancel: () {},
            ),
          ),
          gachaFetcherProvider.overrideWithValue(
            GachaFetcher(rateLimit: Duration.zero),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await container.read(gachaRepositoryProvider.notifier).update();

      expect(
        records.where(
          (r) =>
              r.loggerName == 'gacha.repo' &&
              r.message.startsWith('update start'),
        ),
        isNotEmpty,
        reason: 'expected `update start` log',
      );
      expect(
        records.where(
          (r) =>
              r.loggerName == 'gacha.repo' &&
              r.message.startsWith('update completed'),
        ),
        isNotEmpty,
        reason: 'expected `update completed` log',
      );
    });
  });
}

class _FailingStorage extends GachaStorage {
  _FailingStorage(super.baseDir, {required this.failOnUid});
  final String failOnUid;

  @override
  Future<void> save(BannerStorage data) async {
    if (data.playerId == failOnUid) {
      throw Exception('simulated failure');
    }
    return super.save(data);
  }
}
