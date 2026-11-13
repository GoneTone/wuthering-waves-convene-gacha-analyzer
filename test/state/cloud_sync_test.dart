import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/accounts_import.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/android_cloud_auth.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_auth.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_auth_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_authorization_gateway.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/cloud_sync.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';

import '../helpers/cloud_sync_fakes.dart';
import '../helpers/no_game_dir.dart';

/// signIn 卡在 completer 不返回，供測試模擬「cancelLink 後瀏覽器仍完成授權」的情境。
class _DelayedSignInAuthService extends FakeAuthService {
  /// 建立 [_DelayedSignInAuthService]，signIn 的結果交由 [_completer] 控制。
  _DelayedSignInAuthService(
    super.store,
    this._completer, {
    super.baseClientFactory,
  });

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

/// 記錄是否已 close 的 fake client。
class _ClosableClient extends FakeAuthClient {
  /// 是否已被 close。
  bool closed = false;

  @override
  void close() => closed = true;
}

/// 不跨輪沿用 client 的 fake 授權，記錄 restoreClient 收到的 email。
class _NonPersistentAuth implements CloudAuth {
  /// restoreClient 每次收到的 expectedEmail。
  final restoredEmails = <String>[];

  /// restoreClient 回傳過的 client。
  final clients = <_ClosableClient>[];

  /// link 要回傳的結果；null 代表不支援 link。
  CloudLinkResult? linkResult;

  @override
  bool get keepsClientAcrossRounds => false;

  @override
  Future<CloudLinkResult> link({
    required void Function(String url) openUrl,
    String? postAuthPage,
  }) async => linkResult ?? (throw UnimplementedError());

  @override
  Future<http.Client?> restoreClient({required String expectedEmail}) async {
    restoredEmails.add(expectedEmail);
    final client = _ClosableClient();
    clients.add(client);
    return client;
  }

  @override
  Future<void> unlink() async {}
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

/// 所有步驟都拋錯的 gateway，模擬 Play services 清理失敗。
class _ThrowingGateway implements GoogleAuthorizationGateway {
  @override
  Future<String?> silentToken() async => throw StateError('down');

  @override
  Future<String> interactiveToken() async => throw StateError('down');

  @override
  Future<void> clearToken(String token) async => throw StateError('down');

  @override
  Future<void> signOut() async => throw StateError('down');
}

/// download 卡在 [_gate] 之前不返回，供測試模擬「同步輪進行中」。
class _GatedRemote extends FakeRemote {
  /// 建立 [_GatedRemote]，download 等 [_gate] 完成才返回。
  _GatedRemote(this._gate);

  /// download 的放行閘門。
  final Future<void> _gate;

  @override
  Future<String?> download() async {
    await _gate;
    return super.download();
  }
}

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
        noGameDirOverride,
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

  ProviderContainer makeNonPersistentContainer(CloudAuth auth) {
    final container = ProviderContainer(
      overrides: [
        appVersionProvider.overrideWithValue('1.5.0'),
        noGameDirOverride,
        gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
        gachaCaptureProvider.overrideWithValue(FakeCapture()),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('', 500)),
            cancel: () {},
          ),
        ),
        tokenStoreProvider.overrideWithValue(tokenStore),
        cloudAuthProvider.overrideWithValue(auth),
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

  test('同步自身的合併不觸發 5 秒後的變動檢查（那輪已比對過指紋）', () async {
    final messages = <String>[];
    final sub = Logger.root.onRecord.listen((r) {
      if (r.loggerName == 'cloudsync.sync') messages.add(r.message);
    });
    addTearDown(sub.cancel);

    remote.content = _cloudBundleJsonWithRecord('100000001');
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    final notifier = container.read(cloudSyncProvider.notifier);
    notifier.debounceDelay = const Duration(milliseconds: 10);
    await notifier.link();
    expect(
      container.read(gachaRepositoryProvider).byUid.keys,
      contains('100000001'),
    );

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(messages.where((m) => m.startsWith('dataChange check')), isEmpty);
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

  test('Android unlink → Play services 清理失敗仍清掉 email 並回 idle', () async {
    final container = makeNonPersistentContainer(
      AndroidCloudAuth(
        gateway: _ThrowingGateway(),
        baseClientFactory: () =>
            MockClient((_) async => http.Response('', 500)),
      ),
    );
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    await container
        .read(settingsProvider.notifier)
        .setCloudAccount('u@example.com');

    await container.read(cloudSyncProvider.notifier).unlink();

    expect(container.read(settingsProvider).cloudAccountEmail, isNull);
    expect(container.read(cloudSyncProvider).phase, CloudSyncPhase.idle);
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

  test('啟動那輪途中變動檢查到點 → 等該輪結束再比對指紋，內容沒變就不補跑整輪', () async {
    final messages = <String>[];
    final sub = Logger.root.onRecord.listen((r) {
      if (r.loggerName == 'cloudsync.sync') messages.add(r.message);
    });
    addTearDown(sub.cancel);

    await GachaStorage(tempDir).save(_localBannerStorage('100000001'));
    remote.content = _cloudBundleJson('100000001');
    SharedPreferences.setMockInitialValues({
      'pref.cloudAccountEmail': 'u@example.com',
    });
    tokenStore.token = 'refresh-1';
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    final notifier = container.read(cloudSyncProvider.notifier);
    notifier.debounceDelay = const Duration(milliseconds: 10);

    // 啟動那輪卡在下載時，本機出現一次「內容沒變」的變動（換成同內容的新 Map），
    // 變動檢查在該輪還沒跑完時到點；此時還沒有上一輪的指紋可比。
    remote.downloadGate = Completer<void>();
    final round = notifier.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    container
        .read(gachaRepositoryProvider.notifier)
        .debugSeedAccount(
          container.read(gachaRepositoryProvider).byUid['100000001']!,
        );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    remote.downloadGate!.complete();
    await round;
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(remote.downloads, 1);
    expect(messages.any((m) => m.contains('trigger=rerun')), isFalse);
  });

  test('合併一份與本機相同的資料 → 不重寫記錄檔、不替換記憶體中的紀錄', () async {
    remote.content = _cloudBundleJsonWithRecord('100000001');
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    await container.read(cloudSyncProvider.notifier).link();

    final file = GachaStorage(tempDir).recordsFile('100000001');
    final modifiedBefore = file.lastModifiedSync();
    final byUidBefore = container.read(gachaRepositoryProvider).byUid;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await container
        .read(gachaRepositoryProvider.notifier)
        .importBundleForCloudSync(importAccounts(remote.content!));

    expect(
      identical(container.read(gachaRepositoryProvider).byUid, byUidBefore),
      isTrue,
    );
    expect(file.lastModifiedSync(), modifiedBefore);
  });

  test('上傳內容同時含有記錄檔的帳號（背景讀檔）與只在記憶體的帳號', () async {
    final onDisk = _localBannerStorage('100000001');
    await GachaStorage(tempDir).save(onDisk);
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    container
        .read(gachaRepositoryProvider.notifier)
        .debugSeedAccount(_localBannerStorage('200000002'));
    await container.read(cloudSyncProvider.notifier).link();

    final uploaded = jsonDecode(remote.content!) as Map<String, dynamic>;
    final accounts = (uploaded['accounts'] as List)
        .cast<Map<String, dynamic>>();
    expect(
      accounts.map((a) => a['player_id']),
      containsAll(['100000001', '200000002']),
    );
    // 背景讀檔還原出的內容要與記憶體版的 toJson 完全一致。
    final fromDisk = accounts.firstWhere((a) => a['player_id'] == '100000001');
    expect(fromDisk, onDisk.toJson());
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

  test('cancelLink 後遲到的授權結果不寫入 token store、不撤銷 (I1)', () async {
    final completer = Completer<CloudAuthSession>();
    var baseClientCalls = 0;
    final delayedAuth = _DelayedSignInAuthService(
      tokenStore,
      completer,
      baseClientFactory: () {
        baseClientCalls++;
        return MockClient((_) async => http.Response('', 500));
      },
    );
    final container = ProviderContainer(
      overrides: [
        appVersionProvider.overrideWithValue('1.5.0'),
        noGameDirOverride,
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
    expect(baseClientCalls, 0);
    expect(container.read(cloudSyncProvider).phase, CloudSyncPhase.idle);
    expect(container.read(settingsProvider).cloudAccountEmail, isNull);
  });

  test('link cancelled by the user → idle without error', () async {
    authService.signInThrowsCancelled = true;
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    await container.read(cloudSyncProvider.notifier).link();

    final state = container.read(cloudSyncProvider);
    expect(state.phase, CloudSyncPhase.idle);
    expect(state.errorToken, isNull);
    expect(container.read(settingsProvider).cloudAccountEmail, isNull);
    expect(tokenStore.token, isNull);
  });

  test(
    'non-persistent auth → client restored again on the next round',
    () async {
      final auth = _NonPersistentAuth();
      final container = makeNonPersistentContainer(auth);
      await container.read(settingsProvider.notifier).waitForLoad();
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
      await container
          .read(settingsProvider.notifier)
          .setCloudAccount('u@example.com');

      final notifier = container.read(cloudSyncProvider.notifier);
      await notifier.syncNow(manual: true);
      await notifier.syncNow(manual: true);

      expect(auth.restoredEmails, ['u@example.com', 'u@example.com']);
    },
  );

  test(
    'persistent auth → start keeps the client a completed link established',
    () async {
      final container = makeContainer();
      await container.read(settingsProvider.notifier).waitForLoad();
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
      final notifier = container.read(cloudSyncProvider.notifier);
      await notifier.link();
      expect(authService.restoreCalls, 0);

      await notifier.start();

      expect(authService.restoreCalls, 0);
    },
  );

  test(
    'link: commit throws → client closed, authFailed, no email saved',
    () async {
      final client = _ClosableClient();
      final auth = _NonPersistentAuth()
        ..linkResult = CloudLinkResult(
          client: client,
          email: 'u@example.com',
          commit: () async => throw StateError('commit failed'),
        );
      final container = makeNonPersistentContainer(auth);
      await container.read(settingsProvider.notifier).waitForLoad();
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

      await container.read(cloudSyncProvider.notifier).link();

      final state = container.read(cloudSyncProvider);
      expect(client.closed, isTrue);
      expect(state.phase, CloudSyncPhase.error);
      expect(state.errorToken, 'authFailed');
      expect(container.read(settingsProvider).cloudAccountEmail, isNull);
    },
  );

  test(
    'non-persistent auth + auto-sync on → start restores exactly once',
    () async {
      final auth = _NonPersistentAuth();
      final container = makeNonPersistentContainer(auth);
      await container.read(settingsProvider.notifier).waitForLoad();
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
      await container
          .read(settingsProvider.notifier)
          .setCloudAccount('u@example.com');
      await container
          .read(settingsProvider.notifier)
          .setCloudAutoSyncEnabled(true);

      await container.read(cloudSyncProvider.notifier).start();

      expect(auth.restoredEmails, hasLength(1));
      expect(remote.uploads, 1);
    },
  );

  test(
    'non-persistent auth + auto-sync off → start validates and closes the client',
    () async {
      final auth = _NonPersistentAuth();
      final container = makeNonPersistentContainer(auth);
      await container.read(settingsProvider.notifier).waitForLoad();
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
      await container
          .read(settingsProvider.notifier)
          .setCloudAccount('u@example.com');
      await container
          .read(settingsProvider.notifier)
          .setCloudAutoSyncEnabled(false);

      await container.read(cloudSyncProvider.notifier).start();

      expect(auth.restoredEmails, hasLength(1));
      expect(auth.clients.single.closed, isTrue);
      expect(remote.uploads, 0);
    },
  );

  test(
    'non-persistent auth + sync round running → start skips the restore',
    () async {
      final gate = Completer<void>();
      remote = _GatedRemote(gate.future);
      final auth = _NonPersistentAuth();
      final container = makeNonPersistentContainer(auth);
      await container.read(settingsProvider.notifier).waitForLoad();
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
      await container
          .read(settingsProvider.notifier)
          .setCloudAccount('u@example.com');
      await container
          .read(settingsProvider.notifier)
          .setCloudAutoSyncEnabled(false);

      final notifier = container.read(cloudSyncProvider.notifier);
      final round = notifier.syncNow(manual: true);
      await Future<void>.delayed(Duration.zero);
      await notifier.start();
      gate.complete();
      await round;

      expect(auth.restoredEmails, hasLength(1));
      expect(auth.clients.single.closed, isTrue);
    },
  );

  test('cloudAuthProvider picks the implementation by platform', () {
    ProviderContainer make(bool android) {
      final c = ProviderContainer(
        overrides: [
          isAndroidProvider.overrideWithValue(android),
          googleAuthServiceProvider.overrideWithValue(authService),
          googleAuthorizationGatewayProvider.overrideWithValue(
            _ThrowingGateway(),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    expect(make(true).read(cloudAuthProvider), isA<AndroidCloudAuth>());
    expect(make(false).read(cloudAuthProvider), same(authService));
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
