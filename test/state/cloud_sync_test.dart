import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_auth_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/cloud_sync.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';

import '../helpers/cloud_sync_fakes.dart';

/// signIn 卡在 completer 不返回，供測試模擬「cancelLink 後瀏覽器仍完成授權」的情境。
class _DelayedSignInAuthService extends FakeAuthService {
  /// 建立 [_DelayedSignInAuthService]，signIn 的結果交由 [_completer] 控制。
  _DelayedSignInAuthService(super.store, this._completer);

  /// 控制 signIn 何時、以何結果返回。
  final Completer<CloudAuthSession> _completer;

  @override
  Future<CloudAuthSession> signIn(
    void Function(String url) openUrl, {
    String? postAuthPage,
  }) async {
    openUrl('https://accounts.google.com/consent');
    return _completer.future;
  }
}

/// 產生雲端側 bundle JSON。
String _cloudBundleJson(String uid) => jsonEncode({
  'schema_version': AccountsBundle.currentSchemaVersion,
  'app': accountsBundleAppId,
  'exported_at': '2026-07-04T00:00:00.000Z',
  'app_version': '1.5.0',
  'last_active_uid': uid,
  'accounts': [
    {
      'player_id': uid,
      'language_code': 'zh-Hant',
      'last_updated': '2026-07-01T00:00:00.000Z',
      'banners': {'1': <Object>[]},
    },
  ],
});

/// 產生本機側單帳號存檔（[GachaStorage.save] 用），含 1 筆五星紀錄。
BannerStorage _localBannerStorage(String uid) => BannerStorage.fromJson(
  jsonDecode(
        jsonEncode({
          'player_id': uid,
          'language_code': 'zh-Hant',
          'last_updated': '2026-07-01T00:00:00.000Z',
          'banners': {
            '1': [
              {
                'card_pool_type': '1',
                'resource_id': 21050016,
                'quality_level': 5,
                'resource_type': '武器',
                'name': '本機測試武器',
                'count': 1,
                'time': '2026-06-30 12:00:00',
                'language_code': 'zh-Hant',
              },
            ],
          },
        }),
      )
      as Map<String, dynamic>,
);

/// 產生含 1 筆五星紀錄的雲端側 bundle JSON（觸發靜默補圖用）。
String _cloudBundleJsonWithRecord(String uid) => jsonEncode({
  'schema_version': AccountsBundle.currentSchemaVersion,
  'app': accountsBundleAppId,
  'exported_at': '2026-07-04T00:00:00.000Z',
  'app_version': '1.5.0',
  'last_active_uid': uid,
  'accounts': [
    {
      'player_id': uid,
      'language_code': 'zh-Hant',
      'last_updated': '2026-07-01T00:00:00.000Z',
      'banners': {
        '1': [
          {
            'card_pool_type': '1',
            'resource_id': 21050026,
            'quality_level': 5,
            'resource_type': '武器',
            'name': '雲端測試武器',
            'count': 1,
            'time': '2026-06-29 12:00:00',
            'language_code': 'zh-Hant',
          },
        ],
      },
    },
  ],
});

void main() {
  late Directory tempDir;
  late InMemoryTokenStore tokenStore;
  late FakeAuthService authService;
  late FakeRemote remote;
  late int httpFactoryCalls;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cloud_sync_test_');
    SharedPreferences.setMockInitialValues({});
    tokenStore = InMemoryTokenStore();
    authService = FakeAuthService(tokenStore);
    remote = FakeRemote();
    httpFactoryCalls = 0;
    debugCloudSyncConfiguredOverride = true;
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
    debugCloudSyncConfiguredOverride = null;
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        appVersionProvider.overrideWithValue('1.5.0'),
        gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
        gachaCaptureProvider.overrideWithValue(FakeCapture()),
        cancellableHttpClientFactoryProvider.overrideWithValue(() {
          httpFactoryCalls++;
          return CancellableHttpClient(
            client: MockClient((_) async => http.Response('', 500)),
            cancel: () {},
          );
        }),
        tokenStoreProvider.overrideWithValue(tokenStore),
        googleAuthServiceProvider.overrideWithValue(authService),
        cloudSyncRemoteFactoryProvider.overrideWithValue((_) => remote),
        cloudSyncUrlOpenerProvider.overrideWithValue((_) {}),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('link 成功 → 寫 email、存 token、跑第一輪同步', () async {
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    await container.read(cloudSyncProvider.notifier).link();

    expect(container.read(settingsProvider).cloudAccountEmail, 'u@example.com');
    expect(tokenStore.token, 'refresh-1');
    expect(remote.uploads, 1);
    expect(container.read(settingsProvider).cloudLastSyncedAt, isNotNull);
    expect(container.read(cloudSyncProvider).phase, CloudSyncPhase.idle);
  });

  test('syncNow 把雲端帳號合併進本機並上傳', () async {
    remote.content = _cloudBundleJson('100000001');
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    await container.read(cloudSyncProvider.notifier).link();

    expect(
      container.read(gachaRepositoryProvider).byUid.keys,
      contains('100000001'),
    );
    final uploaded = jsonDecode(remote.content!) as Map<String, dynamic>;
    final uids = (uploaded['accounts'] as List)
        .map((a) => (a as Map<String, dynamic>)['player_id'])
        .toList();
    expect(uids, contains('100000001'));
  });

  test('雲端 schema 過新 → error(schemaTooNew)、不上傳', () async {
    final map =
        jsonDecode(_cloudBundleJson('100000001')) as Map<String, dynamic>;
    map['schema_version'] = AccountsBundle.currentSchemaVersion + 1;
    remote.content = jsonEncode(map);
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    await container.read(cloudSyncProvider.notifier).link();

    final s = container.read(cloudSyncProvider);
    expect(s.phase, CloudSyncPhase.error);
    expect(s.errorToken, 'schemaTooNew');
    expect(remote.uploads, 0);
  });

  test('start：token 失效 → reauthRequired、不跑同步', () async {
    SharedPreferences.setMockInitialValues({
      'pref.cloudAccountEmail': 'u@example.com',
    });
    authService.restoreThrowsReauth = true;
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    await container.read(cloudSyncProvider.notifier).start();

    expect(
      container.read(cloudSyncProvider).phase,
      CloudSyncPhase.reauthRequired,
    );
    expect(remote.uploads, 0);
  });

  test('unlink → 清 email、刪 token、雲端檔保留', () async {
    remote.content = _cloudBundleJson('100000001');
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    await container.read(cloudSyncProvider.notifier).link();

    await container.read(cloudSyncProvider.notifier).unlink();

    expect(container.read(settingsProvider).cloudAccountEmail, isNull);
    expect(tokenStore.token, isNull);
    expect(remote.content, isNotNull);
  });

  test('queueCloudRemoval → 上傳內容剔除該 UID、清 pendingRemovals', () async {
    remote.content = _cloudBundleJson('100000001');
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    await container.read(cloudSyncProvider.notifier).link();
    // 模擬本機已刪：直接從 repo 移除
    await container
        .read(gachaRepositoryProvider.notifier)
        .removeUid('100000001');

    await container
        .read(cloudSyncProvider.notifier)
        .queueCloudRemoval('100000001');

    final uploaded = jsonDecode(remote.content!) as Map<String, dynamic>;
    final uids = (uploaded['accounts'] as List)
        .map((a) => (a as Map<String, dynamic>)['player_id'])
        .toList();
    expect(uids, isNot(contains('100000001')));
    expect(container.read(settingsProvider).cloudPendingRemovals, isEmpty);
  });

  test('start：bootstrap 完成前本機紀錄不被雲端空 banner 覆蓋 (C1)', () async {
    await GachaStorage(tempDir).save(_localBannerStorage('100000001'));
    remote.content = _cloudBundleJson('100000001');
    SharedPreferences.setMockInitialValues({
      'pref.cloudAccountEmail': 'u@example.com',
    });
    tokenStore.token = 'refresh-1';
    final container = makeContainer();

    // 刻意不先 await waitForBootstrap()：start() 本身必須自己等，
    // 否則會重現「bootstrap 還沒跑完就跑同步」的競態，讓空雲端 banner 蓋掉本機紀錄。
    await container.read(cloudSyncProvider.notifier).start();

    final uploaded = jsonDecode(remote.content!) as Map<String, dynamic>;
    final uploadedAccount = (uploaded['accounts'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((a) => a['player_id'] == '100000001');
    final uploadedRecords =
        (uploadedAccount['banners'] as Map<String, dynamic>)['1'] as List;
    expect(uploadedRecords, isNotEmpty);

    final local = container.read(gachaRepositoryProvider).byUid['100000001'];
    expect(local, isNotNull);
    expect(local!.allRecords, isNotEmpty);
  });

  test('reauthRequired 後 syncNow 不再重試 restore (I2)', () async {
    SharedPreferences.setMockInitialValues({
      'pref.cloudAccountEmail': 'u@example.com',
    });
    authService.restoreThrowsReauth = true;
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    await container.read(cloudSyncProvider.notifier).start();
    expect(
      container.read(cloudSyncProvider).phase,
      CloudSyncPhase.reauthRequired,
    );
    final restoreCallsAfterStart = authService.restoreCalls;

    await container.read(cloudSyncProvider.notifier).syncNow(manual: false);

    expect(
      container.read(cloudSyncProvider).phase,
      CloudSyncPhase.reauthRequired,
    );
    expect(remote.uploads, 0);
    expect(authService.restoreCalls, restoreCallsAfterStart);
  });

  test('cancelLink 後遲到的授權結果不寫入 token store、原地 revoke (I1)', () async {
    final completer = Completer<CloudAuthSession>();
    final delayedAuth = _DelayedSignInAuthService(tokenStore, completer);
    final container = ProviderContainer(
      overrides: [
        appVersionProvider.overrideWithValue('1.5.0'),
        gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
        gachaCaptureProvider.overrideWithValue(FakeCapture()),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('', 500)),
            cancel: () {},
          ),
        ),
        tokenStoreProvider.overrideWithValue(tokenStore),
        googleAuthServiceProvider.overrideWithValue(delayedAuth),
        cloudSyncRemoteFactoryProvider.overrideWithValue((_) => remote),
        cloudSyncUrlOpenerProvider.overrideWithValue((_) {}),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    final linkFuture = container.read(cloudSyncProvider.notifier).link();
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(cloudSyncProvider).phase,
      CloudSyncPhase.awaitingConsent,
    );

    container.read(cloudSyncProvider.notifier).cancelLink();
    completer.complete(
      CloudAuthSession(
        client: FakeAuthClient(),
        email: 'u@example.com',
        refreshToken: 'refresh-1',
      ),
    );
    await linkFuture;

    expect(tokenStore.token, isNull);
    expect(delayedAuth.lastRevokedToken, 'refresh-1');
    expect(container.read(cloudSyncProvider).phase, CloudSyncPhase.idle);
    expect(container.read(settingsProvider).cloudAccountEmail, isNull);
  });

  test('同步合併出新紀錄 → 觸發補圖並以進度／完成摘要呈現', () async {
    remote.content = _cloudBundleJsonWithRecord('100000001');
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    await container.read(cloudSyncProvider.notifier).link();
    // 補圖是 fire-and-forget，等它收尾（factory 於補圖開頭即被呼叫）。
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(httpFactoryCalls, greaterThan(0));
    // 測試環境抓不到任何圖（HTTP 全 500）→ 三個計數全零 → 不該留下
    // 完成訊息（progress 保持 null，對話框不彈或自動關閉）。
    expect(container.read(gachaRepositoryProvider).progress, isNull);
    expect(container.read(cloudSyncProvider).phase, CloudSyncPhase.idle);
  });

  test('同步無新增紀錄 → 不觸發補圖', () async {
    remote.content = _cloudBundleJson('100000001');
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    await container.read(cloudSyncProvider.notifier).link();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(httpFactoryCalls, 0);
  });

  test('同步中 refresh token 失效（invalid_grant）→ reauthRequired 而非網路錯誤', () async {
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    await container.read(cloudSyncProvider.notifier).link();
    expect(container.read(cloudSyncProvider).phase, CloudSyncPhase.idle);

    // 連結後 client 已就位（_ensureClient 短路），token 撤銷只會在
    // 自動續期時自 API 呼叫途中爆出 invalid_grant。
    remote.downloadError = Exception(
      'ServerRequestFailedException: Failed to refresh access token: '
      'invalid_grant',
    );
    await container.read(cloudSyncProvider.notifier).syncNow(manual: true);

    expect(
      container.read(cloudSyncProvider).phase,
      CloudSyncPhase.reauthRequired,
    );

    // reauthRequired 之後不再空轉重試。
    final uploadsBefore = remote.uploads;
    await container.read(cloudSyncProvider.notifier).syncNow(manual: false);
    expect(remote.uploads, uploadsBefore);
  });

  test('busy 重排不做指紋跳過：本機沒變也會補跑並合併雲端新資料', () async {
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    final notifier = container.read(cloudSyncProvider.notifier);
    await notifier.link();
    expect(container.read(cloudSyncProvider).phase, CloudSyncPhase.idle);

    // 模擬該輪撞上更新／匯入 busy 被擋。
    notifier.debounceDelay = Duration.zero;
    remote.downloadError = const CloudSyncBusyException();
    await notifier.syncNow(manual: false);
    expect(container.read(cloudSyncProvider).errorToken, 'busy');

    // busy 解除；雲端此時有新資料、本機完全沒變（指紋與上輪相同）。
    remote.downloadError = null;
    remote.content = _cloudBundleJsonWithRecord('100000001');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 重排的補跑必須執行並把雲端新紀錄合併進本機。
    expect(
      container.read(gachaRepositoryProvider).byUid.keys,
      contains('100000001'),
    );
  });

  test('link 把自訂完成頁 HTML 傳給 signIn', () async {
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    await container
        .read(cloudSyncProvider.notifier)
        .link(postAuthPage: '<html>done</html>');

    expect(authService.lastPostAuthPage, '<html>done</html>');
  });

  test('syncNow log 帶觸發來源標記（spec §9）', () async {
    final messages = <String>[];
    final sub = Logger.root.onRecord.listen((r) {
      if (r.loggerName == 'cloudsync.sync') messages.add(r.message);
    });
    addTearDown(sub.cancel);

    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    await container.read(cloudSyncProvider.notifier).link();

    expect(messages.any((m) => m.contains('trigger=link')), isTrue);

    await container.read(cloudSyncProvider.notifier).syncNow(manual: true);
    expect(messages.any((m) => m.contains('trigger=manual')), isTrue);
  });

  test('link：授權未含 drive.appdata → error(scopeMissing)、不寫入任何狀態', () async {
    authService.signInThrowsScopeMissing = true;
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    await container.read(cloudSyncProvider.notifier).link();

    final s = container.read(cloudSyncProvider);
    expect(s.phase, CloudSyncPhase.error);
    expect(s.errorToken, 'scopeMissing');
    expect(container.read(settingsProvider).cloudAccountEmail, isNull);
    expect(tokenStore.token, isNull);
    expect(remote.uploads, 0);
  });

  test(
    '同步遇 insufficient_scope → reauthRequired(scopeMissing)、停止自動同步',
    () async {
      remote.downloadError = Exception(
        'Access was denied (www-authenticate header was: '
        'Bearer realm="https://accounts.google.com/", '
        'error="insufficient_scope", scope="...").',
      );
      final container = makeContainer();
      await container.read(settingsProvider.notifier).waitForLoad();
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

      await container.read(cloudSyncProvider.notifier).link();

      final s = container.read(cloudSyncProvider);
      expect(s.phase, CloudSyncPhase.reauthRequired);
      expect(s.errorToken, 'scopeMissing');
      expect(remote.uploads, 0);

      // reauthRequired 短路：再手動觸發也不會嘗試同步。
      await container.read(cloudSyncProvider.notifier).syncNow(manual: false);
      expect(remote.uploads, 0);
      expect(
        container.read(cloudSyncProvider).phase,
        CloudSyncPhase.reauthRequired,
      );
    },
  );
}
