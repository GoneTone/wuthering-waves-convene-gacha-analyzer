import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_remote.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_auth_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/token_store.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/cloud_sync.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';

/// 測試用 in-memory token store。
class InMemoryTokenStore implements TokenStore {
  /// 目前存放的 token。
  String? token;

  @override
  Future<String?> readRefreshToken() async => token;

  @override
  Future<void> writeRefreshToken(String t) async => token = t;

  @override
  Future<void> deleteRefreshToken() async => token = null;
}

/// 不發真請求的 fake AuthClient。
class _FakeAuthClient extends http.BaseClient implements AuthClient {
  @override
  AccessCredentials get credentials => throw UnimplementedError();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();
}

/// 可程式化行為的 fake 授權服務。
class _FakeAuthService extends GoogleAuthService {
  _FakeAuthService(this.store)
    : super(tokenStore: store, baseClientFactory: http.Client.new);

  /// 供斷言的 token store。
  final InMemoryTokenStore store;

  /// restore 是否要拋 invalid_grant。
  bool restoreThrowsReauth = false;

  @override
  Future<CloudAuthSession> signIn(void Function(String url) openUrl) async {
    openUrl('https://accounts.google.com/consent');
    await store.writeRefreshToken('refresh-1');
    return CloudAuthSession(client: _FakeAuthClient(), email: 'u@example.com');
  }

  @override
  Future<AuthClient?> restore() async {
    if (restoreThrowsReauth) throw const CloudReauthRequiredException();
    if (store.token == null) return null;
    return _FakeAuthClient();
  }

  @override
  Future<void> signOut() async => store.deleteRefreshToken();
}

/// 記錄呼叫的 fake 遠端。
class _FakeRemote implements CloudSyncRemote {
  /// 雲端檔內容。
  String? content;

  /// upload 次數。
  int uploads = 0;

  @override
  Future<String?> download() async => content;

  @override
  Future<void> upload(String json) async {
    uploads++;
    content = json;
  }
}

/// 不會被觸發的 fake capture。
class _FakeCapture implements GachaCapture {
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(null), cancel: () async {});
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

void main() {
  late Directory tempDir;
  late InMemoryTokenStore tokenStore;
  late _FakeAuthService authService;
  late _FakeRemote remote;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cloud_sync_test_');
    SharedPreferences.setMockInitialValues({});
    tokenStore = InMemoryTokenStore();
    authService = _FakeAuthService(tokenStore);
    remote = _FakeRemote();
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
        gachaCaptureProvider.overrideWithValue(_FakeCapture()),
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
}
