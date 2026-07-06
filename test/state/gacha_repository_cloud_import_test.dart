import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';

/// 不會被觸發的 fake capture。
class _FakeCapture implements GachaCapture {
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(null), cancel: () async {});
}

/// 單帳號 bundle（1 筆五星紀錄）。
AccountsBundle _bundle(String uid) => AccountsBundle.fromJson(
  jsonDecode(
        jsonEncode({
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
                    'resource_id': 21050016,
                    'quality_level': 5,
                    'resource_type': '武器',
                    'name': '測試武器',
                    'count': 1,
                    'time': '2026-06-30 12:00:00',
                    'language_code': 'zh-Hant',
                  },
                ],
              },
            },
          ],
        }),
      )
      as Map<String, dynamic>,
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cloud_import_test_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
        gachaCaptureProvider.overrideWithValue(_FakeCapture()),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('', 500)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('importBundleForCloudSync 合併進本機且不啟動 progress', () async {
    final container = makeContainer();
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();

    final result = await repo.importBundleForCloudSync(_bundle('100000001'));

    expect(result.successAccounts, 1);
    expect(result.addedRecords, 1);
    final state = container.read(gachaRepositoryProvider);
    expect(state.byUid.keys, contains('100000001'));
    expect(state.progress, isNull);
  });

  test('重複匯入同 bundle → 全數 duplicate', () async {
    final container = makeContainer();
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();

    await repo.importBundleForCloudSync(_bundle('100000001'));
    final second = await repo.importBundleForCloudSync(_bundle('100000001'));

    expect(second.addedRecords, 0);
    expect(second.duplicateRecords, 1);
  });
}
