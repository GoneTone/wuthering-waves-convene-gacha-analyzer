import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import '../helpers/no_game_dir.dart';
import '../helpers/wait_until.dart';

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
        noGameDirOverride,
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

  test('更新完成視窗還開著時照常合併，進度維持原狀', () async {
    final container = makeContainer();
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    final completed = UpdateCompleted(
      totalNewRecords: 0,
      failedBanners: const [],
      updatedAt: DateTime.utc(2026, 11, 21),
      itemImagesDownloaded: 0,
    );
    repo.debugSetProgress(completed);

    final result = await repo.importBundleForCloudSync(_bundle('100000001'));

    expect(result.addedRecords, 1);
    expect(container.read(gachaRepositoryProvider).progress, same(completed));
  });

  test('更新失敗視窗還開著時照常合併', () async {
    final container = makeContainer();
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    repo.debugSetProgress(const UpdateFailed(UpdateErrorUnexpected()));

    final result = await repo.importBundleForCloudSync(_bundle('100000001'));

    expect(result.addedRecords, 1);
  });

  test('更新進行中仍視為忙碌', () async {
    final container = makeContainer();
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    repo.debugSetProgress(const Preparing());

    await expectLater(
      repo.importBundleForCloudSync(_bundle('100000001')),
      throwsA(isA<CloudSyncBusyException>()),
    );
  });

  test(
    '每一種進行中的 progress 都讓 importBundleForCloudSync 拋 CloudSyncBusyException',
    () async {
      const inFlight = <UpdateProgress>[
        Preparing(),
        WaitingForCapture(),
        FetchingBanner(
          displayName: 'x',
          poolIndex: 1,
          poolCount: 10,
          newRecordsSoFar: 0,
        ),
        FetchingItemImages(
          phase: ItemImagePhase.checking,
          doneCount: 0,
          totalCount: 1,
        ),
        FetchingItemImages(
          phase: ItemImagePhase.downloading,
          doneCount: 0,
          totalCount: 1,
        ),
      ];
      final container = makeContainer();
      final repo = container.read(gachaRepositoryProvider.notifier);
      await repo.waitForBootstrap();

      for (final progress in inFlight) {
        repo.debugSetProgress(progress);
        await expectLater(
          repo.importBundleForCloudSync(_bundle('800000001')),
          throwsA(isA<CloudSyncBusyException>()),
          reason: '${progress.runtimeType}',
        );
      }
    },
  );

  group('結果視窗開著時的補圖延後', () {
    late List<String> messages;

    setUp(() {
      messages = [];
      final sub = Logger.root.onRecord
          .where((r) => r.loggerName == 'cloudsync.sync')
          .listen((r) => messages.add(r.message));
      addTearDown(sub.cancel);
    });

    /// 已完成的補圖次數。
    int fetchRuns() =>
        messages.where((m) => m.startsWith('image fetch done')).length;

    test('結果視窗（UpdateCompleted）開著 → 先不補圖，clearProgress 後補一次', () async {
      final container = makeContainer();
      final repo = container.read(gachaRepositoryProvider.notifier);
      await repo.waitForBootstrap();
      final shown = UpdateCompleted(
        totalNewRecords: 0,
        failedBanners: const [],
        updatedAt: DateTime.utc(2026, 7, 2),
        itemImagesDownloaded: 0,
      );
      repo.debugSetProgress(shown);
      await repo.importBundleForCloudSync(_bundle('800000001'));

      await repo.fetchItemImagesForCloudSync();
      expect(fetchRuns(), 0);
      expect(container.read(gachaRepositoryProvider).progress, same(shown));

      repo.clearProgress();
      await waitUntil(() => fetchRuns() == 1);

      repo.clearProgress();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fetchRuns(), 1);
    });

    test('進行中的 progress → 照舊略過，clearProgress 後不補跑', () async {
      final container = makeContainer();
      final repo = container.read(gachaRepositoryProvider.notifier);
      await repo.waitForBootstrap();
      repo.debugSetProgress(const Preparing());

      await repo.fetchItemImagesForCloudSync();
      repo.clearProgress();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fetchRuns(), 0);
      expect(container.read(gachaRepositoryProvider).progress, isNull);
    });
  });
}
