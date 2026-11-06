import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/flutter_adb_session.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_resolver.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/root_shell.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/client_log_source.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/client_log_watch.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import '../helpers/no_game_dir.dart';

/// 依序回傳預先排好結果的 resolver 替身；結果可以是 gate（測試決定何時完成）。
class _FakeResolver extends LogAccessResolver {
  _FakeResolver()
    : super(
        platform: LogAccessPlatform(),
        root: RootShell(),
        keyStore: AdbKeyStore(),
        makeConnector: () => throw UnimplementedError(),
      );

  /// 每次 resolve 的結果，依呼叫順序取用；用完後重複最後一個。
  final results = <FutureOr<LogAccessOutcome> Function()>[];

  /// 每次 resolve 收到的參數。
  final calls = <({LogAccessMethod? preferred, bool force})>[];

  @override
  Future<LogAccessOutcome> resolve({
    LogAccessMethod? preferred,
    bool forceDisableAfterUse = false,
  }) async {
    calls.add((preferred: preferred, force: forceDisableAfterUse));
    final f = results[(calls.length - 1).clamp(0, results.length - 1)];
    return f();
  }
}

/// 記錄 release 次數、可控制 health stream 的 ready 結果。
class _Ready {
  _Ready({this.leftOn = false});

  /// release 回傳值。
  final bool leftOn;

  /// release 被呼叫的次數。
  int released = 0;

  /// 健康狀態事件來源。
  final health = StreamController<bool>.broadcast();

  /// 讀取來源（不會被真正讀，watch 是替身）。
  final source = ShellLogSource(exec: (_) async => Uint8List(0));

  /// 產生 [LogAccessReady]。
  LogAccessReady outcome() => LogAccessReady(
    source: source,
    method: LogAccessMethod.wirelessDebugging,
    healthChanges: health.stream,
    release: () async {
      released++;
      return leftOn;
    },
  );
}

/// 記錄每次 start 的監看替身。
class _FakeWatch implements ClientLogWatch {
  final hits = <Completer<GachaCredential?>>[];
  final sources = <ClientLogSource>[];
  final cancelled = <int>[];

  @override
  Future<CaptureSession> start(ClientLogSource source) async {
    final i = hits.length;
    final c = Completer<GachaCredential?>();
    hits.add(c);
    sources.add(source);
    return CaptureSession(
      result: c.future,
      cancel: () async {
        cancelled.add(i);
        if (!c.isCompleted) c.complete(null);
      },
    );
  }
}

/// 啟動就失敗的攔截（Android 不該被呼叫）。
class _NoCapture implements GachaCapture {
  int starts = 0;

  @override
  CaptureSession start() {
    starts++;
    return CaptureSession(
      result: Completer<GachaCredential?>().future,
      cancel: () async {},
    );
  }
}

GachaCredential _cred() => GachaCredential(
  playerId: '701000000',
  cardPoolId: '2e23deadbeef2768',
  serverId: '86d5deadbeef9650',
  recordId: '0632deadbeef8550',
  languageCode: 'zh-Hant',
);

/// 反覆讓出事件迴圈直到 [cond] 成立。
Future<void> _until(bool Function() cond) async {
  for (var i = 0; i < 1000 && !cond(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(cond(), isTrue, reason: 'condition never became true');
}

void main() {
  late Directory tempDir;
  late _FakeResolver resolver;
  late _FakeWatch watch;
  late _NoCapture capture;
  late List<int> fetches;
  late ProviderContainer container;
  late bool failFirstPool;
  late ProviderContainer Function({bool android}) makeContainer;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('repo_android_');
    SharedPreferences.setMockInitialValues({});
    resolver = _FakeResolver();
    watch = _FakeWatch();
    capture = _NoCapture();
    fetches = [];
    failFirstPool = false;
    final mock = MockClient((req) async {
      final type =
          (jsonDecode(req.body) as Map<String, dynamic>)['cardPoolType'] as int;
      fetches.add(type);
      final body = failFirstPool && fetches.length == 1
          ? {'code': -1, 'message': 'expired', 'data': <dynamic>[]}
          : {'code': 0, 'message': 'success', 'data': <dynamic>[]};
      if (type == 1 && !(failFirstPool && fetches.length == 1)) {
        body['data'] = [
          {
            'cardPoolType': '1',
            'resourceId': 1211,
            'qualityLevel': 5,
            'resourceType': '角色',
            'name': '達妮婭',
            'count': 1,
            'time': '2026-05-21 10:39:03',
          },
        ];
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    makeContainer = ({bool android = true}) => ProviderContainer(
      overrides: [
        noGameDirOverride,
        isAndroidProvider.overrideWithValue(android),
        logAccessResolverProvider.overrideWithValue(resolver),
        clientLogWatchProvider.overrideWithValue(watch),
        gachaCaptureProvider.overrideWithValue(capture),
        gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
        gachaFetcherProvider.overrideWithValue(
          GachaFetcher(rateLimit: Duration.zero),
        ),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(client: mock, cancel: () {}),
        ),
      ],
    );
    container = makeContainer();
  });

  tearDown(() async {
    container.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<GachaRepository> repo() async {
    container.read(gachaRepositoryProvider);
    final n = container.read(gachaRepositoryProvider.notifier);
    await n.waitForBootstrap();
    return n;
  }

  UpdateProgress? progress() =>
      container.read(gachaRepositoryProvider).progress;

  test('ready: watches source, persists method, releases after hit', () async {
    final ready = _Ready();
    resolver.results.add(ready.outcome);
    final r = await repo();

    final done = r.update();
    await _until(() => watch.hits.isNotEmpty);
    expect(watch.sources.single, same(ready.source));
    expect(progress(), isA<WaitingForCapture>());
    watch.hits[0].complete(_cred());
    await done;

    expect(capture.starts, 0);
    expect(ready.released, 1);
    expect(
      container.read(settingsProvider).logAccessMethod,
      LogAccessMethod.wirelessDebugging,
    );
    expect(progress(), isA<UpdateCompleted>());
    expect((progress()! as UpdateCompleted).wirelessDebuggingLeftOn, isFalse);
  });

  test('blocked: waits for manual input without watching', () async {
    resolver.results.add(
      () => const LogAccessBlocked(LogAccessUnavailable.notPaired),
    );
    final r = await repo();

    final done = r.update();
    await _until(
      () =>
          (progress() as WaitingForCapture?)?.logAccessUnavailable ==
          LogAccessUnavailable.notPaired,
    );
    expect(watch.hits, isEmpty);
    await r.submitManualCredential(_cred());
    await done;
    expect(progress(), isA<UpdateCompleted>());
  });

  test('blocked: cancel clears progress', () async {
    resolver.results.add(
      () => const LogAccessBlocked(LogAccessUnavailable.noWifi),
    );
    final r = await repo();
    final done = r.update();
    await _until(
      () => (progress() as WaitingForCapture?)?.logAccessUnavailable != null,
    );
    await r.cancelCapture();
    await done;
    expect(progress(), isNull);
    expect(fetches, isEmpty);
  });

  test('retryLogAccess switches blocked wait to watching', () async {
    final ready = _Ready();
    resolver.results
      ..add(
        () => const LogAccessBlocked(LogAccessUnavailable.wirelessDebuggingOff),
      )
      ..add(ready.outcome);
    final r = await repo();

    final done = r.update();
    await _until(
      () => (progress() as WaitingForCapture?)?.logAccessUnavailable != null,
    );
    await r.retryLogAccess();
    await _until(() => watch.hits.isNotEmpty);
    expect((progress()! as WaitingForCapture).logAccessUnavailable, isNull);
    watch.hits[0].complete(_cred());
    await done;
    expect(progress(), isA<UpdateCompleted>());
  });

  test(
    'cancel during slow resolve releases access and never watches',
    () async {
      final gate = Completer<LogAccessOutcome>();
      final ready = _Ready();
      resolver.results.add(() => gate.future);
      final r = await repo();

      final done = r.update();
      await _until(() => resolver.calls.isNotEmpty);
      await r.cancelCapture();
      gate.complete(ready.outcome());
      await done;

      expect(watch.hits, isEmpty);
      expect(ready.released, 1);
      expect(progress(), isNull);
    },
  );

  test('fallback after all pools fail waits again on android', () async {
    failFirstPool = true;
    final first = _Ready();
    final second = _Ready();
    resolver.results
      ..add(first.outcome)
      ..add(second.outcome);
    final r = await repo();

    final done = r.update();
    await _until(() => watch.hits.isNotEmpty);
    watch.hits[0].complete(_cred());
    await _until(() => watch.hits.length == 2);
    expect((progress()! as WaitingForCapture).isFallback, isTrue);
    watch.hits[1].complete(_cred());
    await done;
    expect(first.released, 1);
    expect(second.released, 1);
    expect(progress(), isA<UpdateCompleted>());
  });

  test('afterPairing passes forceDisableAfterUse', () async {
    resolver.results.add(_Ready().outcome);
    final r = await repo();
    final done = r.update(afterPairing: true);
    await _until(() => watch.hits.isNotEmpty);
    watch.hits[0].complete(_cred());
    await done;
    expect(resolver.calls.single.force, isTrue);
  });

  test('preferred method comes from settings', () async {
    final settings = container.read(settingsProvider.notifier);
    await settings.waitForLoad();
    await settings.setLogAccessMethod(LogAccessMethod.root);
    resolver.results.add(_Ready().outcome);
    final r = await repo();
    final done = r.update();
    await _until(() => watch.hits.isNotEmpty);
    watch.hits[0].complete(_cred());
    await done;
    expect(resolver.calls.single.preferred, LogAccessMethod.root);
  });

  test('release left wireless debugging on is reported', () async {
    resolver.results.add(_Ready(leftOn: true).outcome);
    final r = await repo();
    final done = r.update();
    await _until(() => watch.hits.isNotEmpty);
    watch.hits[0].complete(_cred());
    await done;
    expect((progress()! as UpdateCompleted).wirelessDebuggingLeftOn, isTrue);
  });

  test('health false shows connection lost, true clears it', () async {
    final ready = _Ready();
    resolver.results.add(ready.outcome);
    final r = await repo();
    final done = r.update();
    await _until(() => watch.hits.isNotEmpty);

    ready.health.add(false);
    await _until(() => (progress()! as WaitingForCapture).logConnectionLost);
    ready.health.add(true);
    await _until(() => !(progress()! as WaitingForCapture).logConnectionLost);

    watch.hits[0].complete(_cred());
    await done;
    expect(progress(), isA<UpdateCompleted>());
  });

  test('windows path still uses capture', () async {
    final c = makeContainer(android: false);
    addTearDown(c.dispose);
    c.read(gachaRepositoryProvider);
    final r = c.read(gachaRepositoryProvider.notifier);
    await r.waitForBootstrap();
    unawaited(r.update());
    await _until(() => capture.starts == 1);
    expect(resolver.calls, isEmpty);
    await r.cancelCapture();
  });
}
