import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';

class _FakeCapture implements GachaCapture {
  _FakeCapture(this._cred);
  final GachaCredential? _cred;
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(_cred), cancel: () async {});
}

GachaCredential _cred() => GachaCredential(
  playerId: '701000000',
  cardPoolId: '2e23deadbeef2768',
  serverId: '86d5deadbeef9650',
  recordId: '0632deadbeef8550',
  languageCode: 'zh-Hant',
);

String _ok(List<Map<String, dynamic>> data) =>
    jsonEncode({'code': 0, 'message': 'success', 'data': data});

String _fail(int code) =>
    jsonEncode({'code': code, 'message': '请求游戏获取日志异常!', 'data': <dynamic>[]});

Map<String, dynamic> _row(String poolType) => {
  'cardPoolType': poolType,
  'resourceId': 1211,
  'qualityLevel': 5,
  'resourceType': '角色',
  'name': '達妮婭',
  'count': 1,
  'time': '2026-05-21 10:39:03',
};

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('repo_update_');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ProviderContainer makeContainer({
    required GachaStorage storage,
    required http.Client client,
    GachaCredential? captured,
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
    ],
  );

  test('happy path: 12 pools fetched, stored, UpdateCompleted', () async {
    final storage = GachaStorage(tempDir);
    final hitTypes = <int>[];
    final mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final type = body['cardPoolType'] as int;
      hitTypes.add(type);
      // pool 1 returns one record, others empty
      return http.Response(
        type == 1 ? _ok([_row('1')]) : _ok(const []),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final container = makeContainer(
      storage: storage,
      client: mock,
      captured: _cred(),
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await container.read(gachaRepositoryProvider.notifier).update();

    expect(hitTypes, [1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13]);
    final progress = container.read(gachaRepositoryProvider).progress;
    expect(progress, isA<UpdateCompleted>());
    expect((progress as UpdateCompleted).totalNewRecords, 1);
    final state = container.read(gachaRepositoryProvider);
    expect(state.activeUid, '701000000');
    expect(state.byUid['701000000']!.banners['1'], hasLength(1));
    expect(state.byUid['701000000']!.languageCode, 'zh-Hant');
  });

  test(
    'partial pool failure → completes with failedBanners, no recapture',
    () async {
      final storage = GachaStorage(tempDir);
      var captureCalls = 0;
      var poolHits = 0;
      final mock = MockClient((req) async {
        poolHits++;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final type = body['cardPoolType'] as int;
        // pool 1 succeeds with a record, pool 2 fails, the rest succeed empty.
        // gachaTypes[0] 是 cardPoolType 1：pool 0 必須成功，否則第一輪 abortOnFirstPoolFailure
        // 早退會改走重攔，poolHits/captureCalls 斷言就不再驗證「部分失敗」這條路徑。
        final String payload;
        if (type == 1) {
          payload = _ok([_row('1')]);
        } else if (type == 2) {
          payload = _fail(-1);
        } else {
          payload = _ok(const []);
        }
        return http.Response(
          payload,
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = ProviderContainer(
        overrides: [
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWith((ref) {
            captureCalls++;
            return _FakeCapture(_cred());
          }),
          gachaFetcherProvider.overrideWithValue(
            GachaFetcher(rateLimit: Duration.zero),
          ),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(client: mock, cancel: () {}),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await container.read(gachaRepositoryProvider.notifier).update();

      final progress = container.read(gachaRepositoryProvider).progress;
      expect(progress, isA<UpdateCompleted>());
      // exactly one pool (pool 2) recorded as failed
      expect((progress as UpdateCompleted).failedBanners, hasLength(1));
      // all 12 pools attempted (did NOT abort at pool 2)
      expect(poolHits, 12);
      // pool 1's record was still saved despite pool 2 failing
      final state = container.read(gachaRepositoryProvider);
      expect(state.byUid['701000000']!.banners['1'], hasLength(1));
      // capture invoked once (primary), no recapture fallback
      expect(captureCalls, 1);
    },
  );

  test(
    'pool 0 fails → round 1 aborts after a single fetch, triggers recapture',
    () async {
      final storage = GachaStorage(tempDir);
      await storage.save(
        BannerStorage(
          playerId: '701000000',
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
      await storage.saveCapturedCredential('701000000', _cred().toJsonString());
      var captureCalls = 0;
      var hits = 0;
      // 在 fallback 重攔啟動的瞬間記下 hits = 第一輪已發出的請求數。
      var round1Fetches = -1;
      final mock = MockClient((req) async {
        hits++;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final type = body['cardPoolType'] as int;
        // round 1：pool 0（hit 1）失敗 → 早退重攔；
        // round 2（hits 2-13）：完整 12 池，pool 1 給一筆紀錄。
        final String payload = hits == 1
            ? _fail(-1)
            : (type == 1 ? _ok([_row('1')]) : _ok(const []));
        return http.Response(
          payload,
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = ProviderContainer(
        overrides: [
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWith((ref) {
            captureCalls++;
            round1Fetches = hits;
            return _FakeCapture(_cred());
          }),
          gachaFetcherProvider.overrideWithValue(
            GachaFetcher(rateLimit: Duration.zero),
          ),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(client: mock, cancel: () {}),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await container.read(gachaRepositoryProvider.notifier).update();

      // 第一輪只抓了 pool 0 就早退（重攔前累計 1 次請求）
      expect(round1Fetches, 1);
      // cached cred 供第一輪使用，只有 fallback 那次重攔
      expect(captureCalls, 1);
      // 1 次早退 + 12 次第二輪
      expect(hits, 13);
      final progress = container.read(gachaRepositoryProvider).progress;
      expect(progress, isA<UpdateCompleted>());
      expect((progress as UpdateCompleted).totalNewRecords, 1);
      expect(progress.failedBanners, isEmpty);
    },
  );

  test('all pools fail → recapture → success → UpdateCompleted', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '701000000',
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
    await storage.saveCapturedCredential('701000000', _cred().toJsonString());
    var captureCalls = 0;
    var hits = 0;
    // round 1 的 pool 0（首抓角色活動）一失敗就早退重攔：第 1 個 hit 視為過期失敗，第 2
    // 個 hit 起為重攔後新 cred 的成功回應（完整 12 池）。
    final mock = MockClient((req) async {
      hits++;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final type = body['cardPoolType'] as int;
      // round 1 (hit 1): pool 0 fails → early abort; round 2 (hits 2-13): pool 1 yields a record
      final String payload;
      if (hits <= 1) {
        payload = _fail(-1);
      } else {
        payload = type == 1 ? _ok([_row('1')]) : _ok(const []);
      }
      return http.Response(
        payload,
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWith((ref) {
          captureCalls++;
          return _FakeCapture(_cred());
        }),
        gachaFetcherProvider.overrideWithValue(
          GachaFetcher(rateLimit: Duration.zero),
        ),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(client: mock, cancel: () {}),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(gachaRepositoryProvider).activeUid, '701000000');

    await container.read(gachaRepositoryProvider.notifier).update();

    // cached cred used for round 1 (no primary capture); only the fallback captured
    expect(captureCalls, 1);
    // round 1 aborted after a single fetch (pool 0); round 2 fetched all 12 pools
    expect(hits, 13);
    final progress = container.read(gachaRepositoryProvider).progress;
    expect(progress, isA<UpdateCompleted>());
    expect((progress as UpdateCompleted).totalNewRecords, 1);
    expect(progress.failedBanners, isEmpty);
  });

  test(
    'recapture round 2: pool 0 fails again but others succeed → saved, no further recapture',
    () async {
      final storage = GachaStorage(tempDir);
      await storage.save(
        BannerStorage(
          playerId: '701000000',
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
      await storage.saveCapturedCredential('701000000', _cred().toJsonString());
      var captureCalls = 0;
      var hits = 0;
      final mock = MockClient((req) async {
        hits++;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final type = body['cardPoolType'] as int;
        final String payload;
        if (hits == 1) {
          // round 1：pool 0 失敗 → 早退重攔
          payload = _fail(-1);
        } else {
          // round 2（hits 2-13）：pool 0（type 1）仍失敗，pool 2（type 2）給一筆，其餘空
          payload = switch (type) {
            1 => _fail(-1),
            2 => _ok([_row('2')]),
            _ => _ok(const []),
          };
        }
        return http.Response(
          payload,
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = ProviderContainer(
        overrides: [
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWith((ref) {
            captureCalls++;
            return _FakeCapture(_cred());
          }),
          gachaFetcherProvider.overrideWithValue(
            GachaFetcher(rateLimit: Duration.zero),
          ),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(client: mock, cancel: () {}),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await container.read(gachaRepositoryProvider.notifier).update();

      // 只重攔一次：第二輪 pool 0 失敗不觸發第三輪
      expect(captureCalls, 1);
      // 1 次早退 + 12 次第二輪
      expect(hits, 13);
      final progress = container.read(gachaRepositoryProvider).progress;
      expect(progress, isA<UpdateCompleted>());
      // 第二輪只有 pool 0（cardPoolType 1）記為失敗
      expect((progress as UpdateCompleted).failedBanners, hasLength(1));
      // pool 2 的紀錄有存進去
      expect(progress.totalNewRecords, 1);
      final state = container.read(gachaRepositoryProvider);
      expect(state.byUid['701000000']!.banners['2'], hasLength(1));
    },
  );

  test('all pools fail → recapture → still all fail → UpdateFailed', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '701000000',
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
    await storage.saveCapturedCredential('701000000', _cred().toJsonString());
    var captureCalls = 0;
    final mock = MockClient(
      (req) async => http.Response(
        _fail(-1),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWith((ref) {
          captureCalls++;
          return _FakeCapture(_cred());
        }),
        gachaFetcherProvider.overrideWithValue(
          GachaFetcher(rateLimit: Duration.zero),
        ),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(client: mock, cancel: () {}),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await container.read(gachaRepositoryProvider.notifier).update();

    // one fallback recapture attempt, then give up
    expect(captureCalls, 1);
    final progress = container.read(gachaRepositoryProvider).progress;
    expect(progress, isA<UpdateFailed>());
    expect((progress as UpdateFailed).error, isA<UpdateErrorGachaFailed>());
    expect((progress.error as UpdateErrorGachaFailed).code, -1);
  });

  test('all pools fail → recapture cancelled → clears progress', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '701000000',
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
    await storage.saveCapturedCredential('701000000', _cred().toJsonString());
    final mock = MockClient(
      (req) async => http.Response(
        _fail(-1),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    // captured: null → the fallback _runMitm returns null (user cancels recapture)
    final container = makeContainer(
      storage: storage,
      client: mock,
      captured: null,
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await container.read(gachaRepositoryProvider.notifier).update();

    // cancelling recapture must not pop an error dialog…
    expect(container.read(gachaRepositoryProvider).progress, isNull);
    // …and must not destroy the existing cached credential
    expect(await storage.loadCapturedCredential('701000000'), isNotNull);
  });

  test('all 10 pools empty → UpdateErrorNoRecords', () async {
    final storage = GachaStorage(tempDir);
    final mock = MockClient(
      (req) async => http.Response(
        _ok(const []),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final container = makeContainer(
      storage: storage,
      client: mock,
      captured: _cred(),
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await container.read(gachaRepositoryProvider.notifier).update();

    final progress = container.read(gachaRepositoryProvider).progress;
    expect(progress, isA<UpdateFailed>());
    expect((progress as UpdateFailed).error, isA<UpdateErrorNoRecords>());
  });

  test('cached credential reused → capture not invoked', () async {
    final storage = GachaStorage(tempDir);
    await storage.save(
      BannerStorage(
        playerId: '701000000',
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
    await storage.saveCapturedCredential('701000000', _cred().toJsonString());
    var captureCalls = 0;
    final mock = MockClient(
      (req) async => http.Response(
        _ok([_row('1')]),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(storage),
        gachaCaptureProvider.overrideWith((ref) {
          captureCalls++;
          return _FakeCapture(_cred());
        }),
        gachaFetcherProvider.overrideWithValue(
          GachaFetcher(rateLimit: Duration.zero),
        ),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(client: mock, cancel: () {}),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(gachaRepositoryProvider).activeUid, '701000000');

    await container.read(gachaRepositoryProvider.notifier).update();

    expect(captureCalls, 0);
    expect(
      container.read(gachaRepositoryProvider).progress,
      isA<UpdateCompleted>(),
    );
  });

  test(
    'forceRecapture cancelled → existing cached credential preserved',
    () async {
      final storage = GachaStorage(tempDir);
      await storage.save(
        BannerStorage(
          playerId: '701000000',
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
      await storage.saveCapturedCredential('701000000', _cred().toJsonString());
      final mock = MockClient(
        (req) async => http.Response(
          _ok(const []),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      // captured: null → _FakeCapture 模擬「新增帳號後使用者按取消」。
      final container = makeContainer(
        storage: storage,
        client: mock,
        captured: null,
      );
      addTearDown(container.dispose);
      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(gachaRepositoryProvider).activeUid, '701000000');

      await container
          .read(gachaRepositoryProvider.notifier)
          .forceRecaptureAndUpdate();

      // 取消重攔不得破壞既有快取，否則下次「更新」會被迫重新攔截。
      expect(await storage.loadCapturedCredential('701000000'), isNotNull);
      expect(container.read(gachaRepositoryProvider).activeUid, '701000000');
      expect(container.read(gachaRepositoryProvider).progress, isNull);
    },
  );
}
