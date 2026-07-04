import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
  Future<CloudAuthSession> signIn(void Function(String url) openUrl) async {
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

void main() {
  late Directory tempDir;
  late InMemoryTokenStore tokenStore;
  late FakeAuthService authService;
  late FakeRemote remote;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cloud_sync_test_');
    SharedPreferences.setMockInitialValues({});
    tokenStore = InMemoryTokenStore();
    authService = FakeAuthService(tokenStore);
    remote = FakeRemote();
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
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('', 500)),
            cancel: () {},
          ),
        ),
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
}
