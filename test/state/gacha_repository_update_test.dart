import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/game_dir_locator.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/client_log_watch.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import '../helpers/no_game_dir.dart';

class _FakeCapture implements GachaCapture {
  _FakeCapture(this._cred);
  final GachaCredential? _cred;
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(_cred), cancel: () async {});
}

/// 結果與取消都由測試手動控制的攔截 fake。
class _ControlledCapture implements GachaCapture {
  /// 建立 fake；[completeOnCancel] 為 true 時 `cancel()` 會以 null 完成結果（模擬真實取消）。
  _ControlledCapture({this.completeOnCancel = false});

  /// 為 true 時 `cancel()` 會以 null 完成 [result]。
  final bool completeOnCancel;

  /// 攔截結果，由測試決定何時完成。
  final result = Completer<GachaCredential?>();

  /// `cancel()` 被呼叫的次數。
  int cancelCalls = 0;

  @override
  CaptureSession start() => CaptureSession(
    result: result.future,
    cancel: () async {
      cancelCalls++;
      if (completeOnCancel && !result.isCompleted) result.complete(null);
    },
  );
}

/// 記錄每次 `start` 的 log 監看 fake；命中與取消都由測試控制。
class _FakeWatch implements ClientLogWatch {
  /// 每個 session 的結果，依 `start` 順序排列。
  final hits = <Completer<GachaCredential?>>[];

  /// 每次 `start` 收到的 Client.log 路徑。
  final paths = <String>[];

  /// 被 `cancel()` 的 session 索引。
  final cancelled = <int>[];

  @override
  CaptureSession start(String clientLogPath) {
    final i = hits.length;
    final c = Completer<GachaCredential?>();
    hits.add(c);
    paths.add(clientLogPath);
    return CaptureSession(
      result: c.future,
      cancel: () async {
        cancelled.add(i);
        if (!c.isCompleted) c.complete(null);
        await cancelGate?.future;
      },
    );
  }

  /// 設定後 `cancel()` 會等它完成才返回（模擬真實監看器等待進行中的輪詢）。
  Completer<void>? cancelGate;
}

/// 回傳固定定位結果並計數的 locator fake。
class _FakeLocator extends GameDirLocator {
  /// 建立 fake，[location] 為 `locate` 的固定回傳值。
  _FakeLocator(this.location);

  /// `locate` 的回傳值；null 代表找不到遊戲資料夾。
  GameDirLocation? location;

  /// 非 null 時 `locate` 丟出它。
  Object? error;

  /// 為 true 時每次 `locate` 改回傳一個存進 [gates] 的 Completer，由測試決定何時完成。
  bool gated = false;

  /// [gated] 模式下各次 `locate` 的待完成結果，依呼叫順序排列。
  final gates = <Completer<GameDirLocation?>>[];

  /// `locate` 被呼叫的次數。
  int calls = 0;

  @override
  Future<GameDirLocation?> locate({String? settingDir}) async {
    calls++;
    if (error != null) throw error!;
    if (gated) {
      final g = Completer<GameDirLocation?>();
      gates.add(g);
      return g.future;
    }
    return location;
  }
}

/// 反覆讓出事件迴圈直到 [cond] 成立（避免固定延遲造成 flake）。
Future<void> _until(bool Function() cond) async {
  for (var i = 0; i < 1000 && !cond(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(cond(), isTrue, reason: 'condition never became true');
}

/// 讓出事件迴圈數輪，讓尚在排程中的非同步工作有機會執行。
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
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
    GachaCapture? capture,
  }) => ProviderContainer(
    overrides: [
      noGameDirOverride,
      gachaStorageProvider.overrideWithValue(storage),
      gachaCaptureProvider.overrideWithValue(capture ?? _FakeCapture(captured)),
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
          noGameDirOverride,
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
          noGameDirOverride,
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
        noGameDirOverride,
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
          noGameDirOverride,
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
        noGameDirOverride,
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
    // 使用者在 fallback 重攔的等待畫面按取消。
    final container = makeContainer(
      storage: storage,
      client: mock,
      capture: _ControlledCapture(completeOnCancel: true),
    );
    addTearDown(container.dispose);
    container.read(gachaRepositoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final repo = container.read(gachaRepositoryProvider.notifier);
    final done = repo.update();
    await _until(
      () =>
          container.read(gachaRepositoryProvider).progress is WaitingForCapture,
    );
    await repo.cancelCapture();
    await done;

    // cancelling recapture must not pop an error dialog…
    expect(container.read(gachaRepositoryProvider).progress, isNull);
    // …and must not destroy the existing cached credential
    expect(await storage.loadCapturedCredential('701000000'), isNotNull);
  });

  test('all 12 pools empty → UpdateErrorNoRecords', () async {
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
        noGameDirOverride,
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
      // 新增帳號後使用者在等待畫面按取消。
      final container = makeContainer(
        storage: storage,
        client: mock,
        capture: _ControlledCapture(completeOnCancel: true),
      );
      addTearDown(container.dispose);
      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(gachaRepositoryProvider).activeUid, '701000000');

      final repo = container.read(gachaRepositoryProvider.notifier);
      final done = repo.forceRecaptureAndUpdate();
      await _until(
        () =>
            container.read(gachaRepositoryProvider).progress
                is WaitingForCapture,
      );
      await repo.cancelCapture();
      await done;

      // 取消重攔不得破壞既有快取，否則下次「更新」會被迫重新攔截。
      expect(await storage.loadCapturedCredential('701000000'), isNotNull);
      expect(container.read(gachaRepositoryProvider).activeUid, '701000000');
      expect(container.read(gachaRepositoryProvider).progress, isNull);
    },
  );

  group('client log race', () {
    const gameDir = r'D:\Games\Wuthering Waves Game';
    const loc = GameDirLocation(gameDir, GameDirSource.setting);

    /// 建立比快測試用的 container，並回傳 HTTP 請求計數器。
    ({ProviderContainer container, List<int> hits}) raceContainer({
      required _ControlledCapture capture,
      required _FakeWatch watch,
      required _FakeLocator locator,
      GachaStorage? storage,
      String Function(int hit, int type)? respond,
    }) {
      final hits = <int>[];
      final mock = MockClient((req) async {
        final type =
            (jsonDecode(req.body) as Map<String, dynamic>)['cardPoolType']
                as int;
        hits.add(type);
        final payload =
            respond?.call(hits.length, type) ??
            (type == 1 ? _ok([_row('1')]) : _ok(const []));
        return http.Response(
          payload,
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = ProviderContainer(
        overrides: [
          gachaStorageProvider.overrideWithValue(
            storage ?? GachaStorage(tempDir),
          ),
          gachaCaptureProvider.overrideWithValue(capture),
          clientLogWatchProvider.overrideWithValue(watch),
          gameDirLocatorProvider.overrideWithValue(locator),
          gachaFetcherProvider.overrideWithValue(
            GachaFetcher(rateLimit: Duration.zero),
          ),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(client: mock, cancel: () {}),
          ),
        ],
      );
      addTearDown(container.dispose);
      return (container: container, hits: hits);
    }

    /// 讀出 repository notifier 並等 bootstrap 完成。
    Future<GachaRepository> bootstrap(ProviderContainer c) async {
      c.read(gachaRepositoryProvider);
      final n = c.read(gachaRepositoryProvider.notifier);
      await n.waitForBootstrap();
      return n;
    }

    test('log wins: waits capture teardown before fetching', () async {
      final capture = _ControlledCapture();
      final watch = _FakeWatch();
      final t = raceContainer(
        capture: capture,
        watch: watch,
        locator: _FakeLocator(loc),
      );
      final repo = await bootstrap(t.container);

      final done = repo.update();
      await _until(() => watch.hits.isNotEmpty);
      expect(watch.paths.single, GameDirLocator.clientLogPath(gameDir));
      watch.hits[0].complete(_cred());

      await _until(() => capture.cancelCalls > 0);
      await _settle();
      expect(t.hits, isEmpty, reason: 'no fetch before capture teardown');

      capture.result.complete(null);
      await done;

      expect(t.hits, hasLength(12));
      expect(
        t.container.read(gachaRepositoryProvider).progress,
        isA<UpdateCompleted>(),
      );
    });

    test('log wins: capture teardown error is ignored', () async {
      final capture = _ControlledCapture();
      final watch = _FakeWatch();
      final t = raceContainer(
        capture: capture,
        watch: watch,
        locator: _FakeLocator(loc),
      );
      final repo = await bootstrap(t.container);

      final done = repo.update();
      await _until(() => watch.hits.isNotEmpty);
      watch.hits[0].complete(_cred());
      await _until(() => capture.cancelCalls > 0);
      capture.result.completeError(Exception('helper stop failed'));
      await done;

      expect(
        t.container.read(gachaRepositoryProvider).progress,
        isA<UpdateCompleted>(),
      );
    });

    test('capture wins: log watch cancelled', () async {
      final capture = _ControlledCapture();
      final watch = _FakeWatch();
      final t = raceContainer(
        capture: capture,
        watch: watch,
        locator: _FakeLocator(loc),
      );
      final repo = await bootstrap(t.container);

      final done = repo.update();
      await _until(() => watch.hits.isNotEmpty);
      capture.result.complete(_cred());
      await done;

      expect(watch.cancelled, [0]);
      expect(capture.cancelCalls, 0);
      expect(
        t.container.read(gachaRepositoryProvider).progress,
        isA<UpdateCompleted>(),
      );
    });

    test(
      'capture error with log active: keeps waiting on log and tells user',
      () async {
        final capture = _ControlledCapture();
        final watch = _FakeWatch();
        final t = raceContainer(
          capture: capture,
          watch: watch,
          locator: _FakeLocator(loc),
        );
        final repo = await bootstrap(t.container);

        final done = repo.update();
        await _until(() => watch.hits.isNotEmpty);
        capture.result.completeError(Exception('uac denied'));
        await _settle();

        final waiting = t.container.read(gachaRepositoryProvider).progress;
        expect(waiting, isA<WaitingForCapture>());
        expect((waiting! as WaitingForCapture).captureUnavailable, isTrue);
        expect(watch.cancelled, isEmpty);

        watch.hits[0].complete(_cred());
        await done;

        expect(t.hits, hasLength(12));
        expect(
          t.container.read(gachaRepositoryProvider).progress,
          isA<UpdateCompleted>(),
        );
      },
    );

    test(
      'capture error without game dir: shows pick-folder notice, recovers after pick',
      () async {
        final capture = _ControlledCapture();
        final watch = _FakeWatch();
        final locator = _FakeLocator(null);
        final t = raceContainer(
          capture: capture,
          watch: watch,
          locator: locator,
        );
        final repo = await bootstrap(t.container);

        final done = repo.update();
        await _until(() => locator.calls > 0);
        capture.result.completeError(Exception('uac denied'));
        await _settle();

        var waiting =
            t.container.read(gachaRepositoryProvider).progress!
                as WaitingForCapture;
        expect(waiting.captureUnavailable, isTrue);
        expect(waiting.gameDirMissing, isTrue);

        // 使用者在說明視窗選好資料夾 → 監看啟動，提示換成「只靠 log」。
        locator.location = loc;
        await repo.restartClientLogWatch();
        await _until(() => watch.hits.isNotEmpty);
        waiting =
            t.container.read(gachaRepositoryProvider).progress!
                as WaitingForCapture;
        expect(waiting.captureUnavailable, isTrue);
        expect(waiting.gameDirMissing, isFalse);

        watch.hits[0].complete(_cred());
        await done;
        expect(t.hits, hasLength(12));
        expect(
          t.container.read(gachaRepositoryProvider).progress,
          isA<UpdateCompleted>(),
        );
      },
    );

    test(
      'capture ends without hit and no game dir: notice instead of silent close',
      () async {
        final capture = _ControlledCapture();
        final watch = _FakeWatch();
        final locator = _FakeLocator(null);
        final t = raceContainer(
          capture: capture,
          watch: watch,
          locator: locator,
        );
        final repo = await bootstrap(t.container);

        final done = repo.update();
        await _until(() => locator.calls > 0);
        capture.result.complete(null);
        await _settle();

        final waiting =
            t.container.read(gachaRepositoryProvider).progress!
                as WaitingForCapture;
        expect(waiting.gameDirMissing, isTrue);

        await repo.cancelCapture();
        await done;
        expect(t.container.read(gachaRepositoryProvider).progress, isNull);
      },
    );

    test(
      'capture ends without hit (not cancelled) with log active: falls back',
      () async {
        final capture = _ControlledCapture();
        final watch = _FakeWatch();
        final t = raceContainer(
          capture: capture,
          watch: watch,
          locator: _FakeLocator(loc),
        );
        final repo = await bootstrap(t.container);

        final done = repo.update();
        await _until(() => watch.hits.isNotEmpty);
        capture.result.complete(null);
        await _settle();

        final waiting = t.container.read(gachaRepositoryProvider).progress;
        expect((waiting! as WaitingForCapture).captureUnavailable, isTrue);

        watch.hits[0].complete(_cred());
        await done;
        expect(
          t.container.read(gachaRepositoryProvider).progress,
          isA<UpdateCompleted>(),
        );
      },
    );

    test('user cancel during log-only wait clears progress', () async {
      final capture = _ControlledCapture();
      final watch = _FakeWatch();
      final t = raceContainer(
        capture: capture,
        watch: watch,
        locator: _FakeLocator(loc),
      );
      final repo = await bootstrap(t.container);

      final done = repo.update();
      await _until(() => watch.hits.isNotEmpty);
      capture.result.completeError(Exception('uac denied'));
      await _settle();
      await repo.cancelCapture();
      await done;

      expect(watch.cancelled, contains(0));
      expect(t.hits, isEmpty);
      expect(t.container.read(gachaRepositoryProvider).progress, isNull);
    });

    test('user cancel stops both', () async {
      final capture = _ControlledCapture(completeOnCancel: true);
      final watch = _FakeWatch();
      final t = raceContainer(
        capture: capture,
        watch: watch,
        locator: _FakeLocator(loc),
      );
      final repo = await bootstrap(t.container);

      final done = repo.update();
      await _until(() => watch.hits.isNotEmpty);
      await repo.cancelCapture();
      await done;

      expect(capture.cancelCalls, greaterThan(0));
      expect(watch.cancelled, contains(0));
      expect(t.hits, isEmpty);
      expect(t.container.read(gachaRepositoryProvider).progress, isNull);
    });

    test('user cancel during log-won teardown aborts', () async {
      final capture = _ControlledCapture();
      final watch = _FakeWatch();
      final t = raceContainer(
        capture: capture,
        watch: watch,
        locator: _FakeLocator(loc),
      );
      final repo = await bootstrap(t.container);

      final done = repo.update();
      await _until(() => watch.hits.isNotEmpty);
      watch.hits[0].complete(_cred());
      await _until(() => capture.cancelCalls > 0);
      await repo.cancelCapture();
      capture.result.complete(null);
      await done;

      expect(t.hits, isEmpty);
      expect(t.container.read(gachaRepositoryProvider).progress, isNull);
    });

    test('no game dir: capture only', () async {
      final capture = _ControlledCapture();
      final watch = _FakeWatch();
      final locator = _FakeLocator(null);
      final t = raceContainer(capture: capture, watch: watch, locator: locator);
      final repo = await bootstrap(t.container);

      final done = repo.update();
      await _until(() => locator.calls > 0);
      await _settle();
      capture.result.complete(_cred());
      await done;

      expect(watch.hits, isEmpty);
      expect(t.hits, hasLength(12));
      expect(
        t.container.read(gachaRepositoryProvider).progress,
        isA<UpdateCompleted>(),
      );
    });

    test('restartClientLogWatch re-locates and restarts', () async {
      final capture = _ControlledCapture();
      final watch = _FakeWatch();
      final locator = _FakeLocator(loc);
      final t = raceContainer(capture: capture, watch: watch, locator: locator);
      final repo = await bootstrap(t.container);

      // 不在等待攔截時呼叫應為 no-op。
      await repo.restartClientLogWatch();
      expect(locator.calls, 0);

      final done = repo.update();
      await _until(() => watch.hits.isNotEmpty);
      await repo.restartClientLogWatch();

      expect(locator.calls, 2);
      expect(watch.hits, hasLength(2));
      expect(watch.cancelled, [0]);

      watch.hits[1].complete(_cred());
      await _until(() => capture.cancelCalls > 0);
      capture.result.complete(null);
      await done;

      expect(t.hits, hasLength(12));
      expect(
        t.container.read(gachaRepositoryProvider).progress,
        isA<UpdateCompleted>(),
      );
    });

    test('fallback recapture also races the client log', () async {
      final storage = GachaStorage(tempDir);
      await storage.save(
        BannerStorage(
          playerId: '701000000',
          languageCode: 'zh-Hant',
          lastUpdated: DateTime.utc(2026),
          banners: const {'1': [], '2': []},
        ),
      );
      await storage.saveCapturedCredential('701000000', _cred().toJsonString());
      final capture = _ControlledCapture();
      final watch = _FakeWatch();
      final t = raceContainer(
        capture: capture,
        watch: watch,
        locator: _FakeLocator(loc),
        storage: storage,
        // 第一輪 pool 0（第 1 個請求）失敗 → 重攔；第二輪正常。
        respond: (hit, type) => hit == 1
            ? _fail(-1)
            : (type == 1 ? _ok([_row('1')]) : _ok(const [])),
      );
      final repo = await bootstrap(t.container);

      final done = repo.update();
      await _until(() => watch.hits.isNotEmpty);
      final waiting = t.container.read(gachaRepositoryProvider).progress;
      expect((waiting as WaitingForCapture).isFallback, isTrue);
      watch.hits[0].complete(_cred());
      await _until(() => capture.cancelCalls > 0);
      capture.result.complete(null);
      await done;

      expect(t.hits, hasLength(13));
      expect(
        t.container.read(gachaRepositoryProvider).progress,
        isA<UpdateCompleted>(),
      );
    });
    test('locator failure is logged and never fails the update', () async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);
      final capture = _ControlledCapture();
      final watch = _FakeWatch();
      final locator = _FakeLocator(loc)..error = StateError('boom');
      final t = raceContainer(capture: capture, watch: watch, locator: locator);
      final repo = await bootstrap(t.container);

      final done = repo.update();
      await _until(() => locator.calls > 0);
      await repo.restartClientLogWatch();
      capture.result.complete(_cred());
      await done;

      expect(locator.calls, 2);
      expect(watch.hits, isEmpty);
      expect(
        records.where(
          (r) =>
              r.loggerName == 'gacha.clientLog' &&
              r.level == Level.WARNING &&
              r.message.startsWith('client log watch start failed'),
        ),
        hasLength(2),
      );
      expect(
        t.container.read(gachaRepositoryProvider).progress,
        isA<UpdateCompleted>(),
      );
    });

    test('cancel during slow watcher stop aborts before fetching', () async {
      final capture = _ControlledCapture();
      final watch = _FakeWatch()..cancelGate = Completer<void>();
      final t = raceContainer(
        capture: capture,
        watch: watch,
        locator: _FakeLocator(loc),
      );
      final repo = await bootstrap(t.container);

      final done = repo.update();
      await _until(() => watch.hits.isNotEmpty);
      capture.result.complete(_cred());
      await _until(() => watch.cancelled.isNotEmpty);
      await repo.cancelCapture();
      watch.cancelGate!.complete();
      await done;

      expect(t.hits, isEmpty);
      expect(t.container.read(gachaRepositoryProvider).progress, isNull);
    });

    test('stale locate result is dropped after restart', () async {
      const newDir = r'E:\Moved\Wuthering Waves Game';
      final capture = _ControlledCapture();
      final watch = _FakeWatch();
      final locator = _FakeLocator(loc)..gated = true;
      final t = raceContainer(capture: capture, watch: watch, locator: locator);
      final repo = await bootstrap(t.container);

      final done = repo.update();
      await _until(() => locator.gates.length == 1);
      final restart = repo.restartClientLogWatch();
      await _until(() => locator.gates.length == 2);
      locator.gates[1].complete(
        const GameDirLocation(newDir, GameDirSource.setting),
      );
      await restart;
      locator.gates[0].complete(loc);
      await _settle();

      expect(watch.paths, [GameDirLocator.clientLogPath(newDir)]);
      await repo.cancelCapture();
      capture.result.complete(null);
      await done;
      expect(watch.cancelled, [0]);
    });

    test('restart without game dir stops old session', () async {
      final capture = _ControlledCapture();
      final watch = _FakeWatch();
      final locator = _FakeLocator(loc);
      final t = raceContainer(capture: capture, watch: watch, locator: locator);
      final repo = await bootstrap(t.container);

      final done = repo.update();
      await _until(() => watch.hits.isNotEmpty);
      locator.location = null;
      await repo.restartClientLogWatch();

      expect(watch.cancelled, [0]);
      expect(watch.hits, hasLength(1));
      capture.result.complete(_cred());
      await done;
      expect(
        t.container.read(gachaRepositoryProvider).progress,
        isA<UpdateCompleted>(),
      );
    });
  });
}
