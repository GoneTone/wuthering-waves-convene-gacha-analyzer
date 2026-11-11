import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/flutter_adb_session.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_resolver.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/root_shell.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/wuwa_game_package.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/client_log_source.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/client_log_watch.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/adb_pairing.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/app_foreground.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import '../helpers/no_game_dir.dart';
import '../helpers/wait_until.dart';

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
  final calls =
      <
        ({LogAccessMethod? preferred, String? game, bool force, bool request})
      >[];

  /// 每次 resolve 收到的 abort。
  final aborts = <Future<void>?>[];

  @override
  Future<LogAccessOutcome> resolve({
    LogAccessMethod? preferred,
    String? preferredGame,
    bool forceDisableAfterUse = false,
    bool requestPermissions = true,
    Future<void>? abort,
  }) async {
    aborts.add(abort);
    calls.add((
      preferred: preferred,
      game: preferredGame,
      force: forceDisableAfterUse,
      request: requestPermissions,
    ));
    final f = results[(calls.length - 1).clamp(0, results.length - 1)];
    return f();
  }
}

/// 記錄 release 次數、可控制 health stream 的 ready 結果。
class _Ready {
  _Ready({this.leftOn = false, this.games = const [wuwaGlobalPackage]});

  /// 手機上裝的版本；讀的是第一個。
  final List<String> games;

  /// release 回傳值。
  final bool leftOn;

  /// release 被呼叫的次數。
  int released = 0;

  /// 健康狀態事件來源。
  final health = StreamController<bool>.broadcast();

  /// 讀取來源（不會被真正讀，watch 是替身）。
  late final source = ShellLogSource(
    exec: (_) async => Uint8List(0),
    path: androidClientLogPathFor(games.first),
  );

  /// 產生 [LogAccessReady]。
  LogAccessReady outcome() => LogAccessReady(
    source: source,
    method: LogAccessMethod.wirelessDebugging,
    game: games.first,
    games: games,
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

  /// 設定後 cancel 會等它完成才返回，模擬還在讀取的輪詢。
  Completer<void>? cancelGate;

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
        await cancelGate?.future;
        if (!c.isCompleted) c.complete(null);
      },
    );
  }
}

/// 前景狀態可控制的替身。
class _Foreground extends AppForeground {
  bool foreground = true;
  Completer<void> resumed = Completer<void>();

  @override
  bool get isForeground => foreground;
  @override
  Future<void> untilForeground() => resumed.future;
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

void main() {
  late Directory tempDir;
  late _FakeResolver resolver;
  late _FakeWatch watch;
  late _NoCapture capture;
  late List<int> fetches;
  late ProviderContainer container;
  late bool failFirstPool;
  late _Foreground foreground;
  late ProviderContainer Function({bool android, List<Override> extra})
  makeContainer;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('repo_android_');
    SharedPreferences.setMockInitialValues({});
    resolver = _FakeResolver();
    watch = _FakeWatch();
    capture = _NoCapture();
    fetches = [];
    failFirstPool = false;
    foreground = _Foreground();
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
    makeContainer = ({bool android = true, List<Override> extra = const []}) =>
        ProviderContainer(
          overrides: [
            ...extra,
            noGameDirOverride,
            isAndroidProvider.overrideWithValue(android),
            appForegroundProvider.overrideWithValue(foreground),
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
    await waitUntil(() => watch.hits.isNotEmpty);
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

  test('refreshes pairing status after connecting', () async {
    // 連上時可能順便補回授權，設定頁開著的話要重讀狀態。
    var computes = 0;
    container.dispose();
    container = makeContainer(
      extra: [
        wirelessPairingStatusProvider.overrideWith((ref) async {
          computes++;
          return (paired: true, canToggle: true);
        }),
      ],
    );
    final sub = container.listen(wirelessPairingStatusProvider, (_, _) {});
    await container.read(wirelessPairingStatusProvider.future);
    expect(computes, 1);

    final ready = _Ready();
    resolver.results.add(ready.outcome);
    final r = await repo();
    final done = r.update();
    await waitUntil(() => watch.hits.isNotEmpty);
    watch.hits[0].complete(_cred());
    await done;

    await container.read(wirelessPairingStatusProvider.future);
    expect(computes, 2);
    sub.close();
  });

  test('ready: waiting state names the game being read', () async {
    final ready = _Ready(games: [wuwaSamsungPackage, wuwaGlobalPackage]);
    resolver.results.add(ready.outcome);
    final r = await repo();
    final done = r.update();
    await waitUntil(() => watch.hits.isNotEmpty);
    final p = progress()! as WaitingForCapture;
    expect(p.gamePackage, wuwaSamsungPackage);
    expect(p.installedGames, [wuwaSamsungPackage, wuwaGlobalPackage]);
    ready.health.add(false);
    await waitUntil(() => (progress()! as WaitingForCapture).logConnectionLost);
    expect((progress()! as WaitingForCapture).gamePackage, wuwaSamsungPackage);
    await r.cancelCapture();
    await done;
  });

  test('choose game: the pick is saved and used for the next try', () async {
    final ready = _Ready(games: [wuwaSamsungPackage, wuwaGlobalPackage]);
    resolver.results
      ..add(
        () => const LogAccessBlocked(
          LogAccessUnavailable.chooseGame,
          games: [wuwaGlobalPackage, wuwaSamsungPackage],
        ),
      )
      ..add(ready.outcome);
    final r = await repo();
    final done = r.update();
    await waitUntil(
      () => (progress() as WaitingForCapture?)?.logAccessUnavailable != null,
    );
    expect((progress()! as WaitingForCapture).installedGames, [
      wuwaGlobalPackage,
      wuwaSamsungPackage,
    ]);

    await r.selectGame(wuwaSamsungPackage);
    await waitUntil(() => watch.hits.isNotEmpty);
    expect(container.read(settingsProvider).gamePackage, wuwaSamsungPackage);
    expect(resolver.calls[0].game, isNull);
    expect(resolver.calls[1].game, wuwaSamsungPackage);
    // 選版本前還沒試過讀取方式，權限詢問要留給選完後那一次。
    expect(resolver.calls[1].request, isTrue);
    await r.cancelCapture();
    await done;
  });

  test(
    'switching version waits for the slow cancel, then asks again',
    () async {
      // 連線中斷時進行中的讀取要等逾時才停；只等固定秒數的話，重新開始會被防重入擋掉。
      final ready = _Ready(games: [wuwaSamsungPackage, wuwaGlobalPackage]);
      resolver.results
        ..add(ready.outcome)
        ..add(
          () => const LogAccessBlocked(
            LogAccessUnavailable.chooseGame,
            games: [wuwaGlobalPackage, wuwaSamsungPackage],
          ),
        );
      final r = await repo();
      await container
          .read(settingsProvider.notifier)
          .setGamePackage(wuwaSamsungPackage);
      final first = r.update();
      await waitUntil(() => watch.hits.isNotEmpty);
      final gate = watch.cancelGate = Completer<void>();

      final switching = r.switchGameVersion();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(resolver.calls, hasLength(1), reason: 'still cancelling');
      expect(container.read(settingsProvider).gamePackage, isNull);

      gate.complete();
      await first;
      await waitUntil(
        () =>
            (progress() as WaitingForCapture?)?.logAccessUnavailable ==
            LogAccessUnavailable.chooseGame,
      );
      expect(resolver.calls, hasLength(2));
      expect(resolver.calls[1].game, isNull);
      await r.cancelCapture();
      await switching;
    },
  );

  test('blocked: root denial is shown in the waiting state', () async {
    resolver.results.add(
      () => const LogAccessBlocked(
        LogAccessUnavailable.notPaired,
        rootDenied: true,
      ),
    );
    final r = await repo();
    final done = r.update();
    await waitUntil(
      () => (progress() as WaitingForCapture?)?.logAccessUnavailable != null,
    );
    expect((progress()! as WaitingForCapture).rootDenied, isTrue);
    await r.cancelCapture();
    await done;
  });

  test(
    'retry after the app had turned wireless on turns it off after use',
    () async {
      // 玩家在系統視窗按「允許」後是系統把無線偵錯打開的；重試時不能當成玩家原本就開著而留著。
      final ready = _Ready();
      resolver.results
        ..add(
          () => const LogAccessBlocked(
            LogAccessUnavailable.networkNotAllowed,
            enabledWireless: true,
          ),
        )
        ..add(ready.outcome);
      final r = await repo();
      final done = r.update();
      await waitUntil(
        () => (progress() as WaitingForCapture?)?.logAccessUnavailable != null,
      );
      await r.retryLogAccess();
      await waitUntil(() => watch.hits.isNotEmpty);
      expect(resolver.calls[0].force, isFalse);
      expect(resolver.calls[1].force, isTrue);
      await r.cancelCapture();
      await done;
    },
  );

  test('blocked: waits for manual input without watching', () async {
    resolver.results.add(
      () => const LogAccessBlocked(LogAccessUnavailable.notPaired),
    );
    final r = await repo();

    final done = r.update();
    await waitUntil(
      () =>
          (progress() as WaitingForCapture?)?.logAccessUnavailable ==
          LogAccessUnavailable.notPaired,
    );
    expect(watch.hits, isEmpty);
    await r.submitManualCredential(_cred());
    await done;
    expect(progress(), isA<UpdateCompleted>());
  });

  test('cancel releases only after the in-flight poll stops', () async {
    // 輪詢還在讀取時就 release，讀取失敗會觸發重連、把無線偵錯又打開。
    final ready = _Ready();
    resolver.results.add(ready.outcome);
    watch.cancelGate = Completer<void>();
    final r = await repo();

    final done = r.update();
    await waitUntil(() => watch.hits.isNotEmpty);
    unawaited(r.cancelCapture());
    await waitUntil(() => watch.cancelled.isNotEmpty);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(ready.released, 0);
    watch.cancelGate!.complete();
    await done;
    expect(ready.released, 1);
  });

  test(
    'cancel while resolving returns at once and releases a late ready',
    () async {
      // root 授權視窗最多等 60 秒；這段期間按取消要立刻有反應。
      final ready = _Ready();
      final gate = Completer<LogAccessOutcome>();
      resolver.results.add(() => gate.future);
      final r = await repo();
      final done = r.update();
      await waitUntil(() => resolver.calls.isNotEmpty);
      await r.cancelCapture();
      await done;
      expect(progress(), isNull);
      var aborted = false;
      unawaited(resolver.aborts.single!.then((_) => aborted = true));
      await waitUntil(() => aborted);
      gate.complete(ready.outcome());
      await waitUntil(() => ready.released == 1);
      expect(watch.hits, isEmpty);
    },
  );

  test('checking state lasts until the resolver answers', () async {
    // 判斷完成前不能引導玩家開遊戲，否則進遊戲後才發現不能自動讀取。
    bool checking() => (progress()! as WaitingForCapture).checkingLogAccess;
    final first = Completer<LogAccessOutcome>();
    final second = Completer<LogAccessOutcome>();
    final ready = _Ready();
    resolver.results
      ..add(() => first.future)
      ..add(() => second.future);
    final r = await repo();
    final done = r.update();
    await waitUntil(() => resolver.calls.isNotEmpty);
    expect(checking(), isTrue);

    first.complete(const LogAccessBlocked(LogAccessUnavailable.notPaired));
    await waitUntil(
      () => (progress() as WaitingForCapture?)?.logAccessUnavailable != null,
    );
    expect(checking(), isFalse);

    await r.retryLogAccess();
    await waitUntil(() => resolver.calls.length == 2);
    expect(checking(), isTrue);
    expect((progress()! as WaitingForCapture).logAccessUnavailable, isNull);

    second.complete(ready.outcome());
    await waitUntil(() => watch.hits.isNotEmpty);
    expect(checking(), isFalse);
    watch.hits[0].complete(_cred());
    await done;
  });

  test('manual input while resolving is used at once', () async {
    final gate = Completer<LogAccessOutcome>();
    resolver.results.add(() => gate.future);
    final r = await repo();
    final done = r.update();
    await waitUntil(() => resolver.calls.isNotEmpty);
    await r.submitManualCredential(_cred());
    await done;
    expect(progress(), isA<UpdateCompleted>());
    gate.complete(const LogAccessBlocked(LogAccessUnavailable.notPaired));
  });

  test('blocked: cancel clears progress', () async {
    resolver.results.add(
      () => const LogAccessBlocked(LogAccessUnavailable.noWifi),
    );
    final r = await repo();
    final done = r.update();
    await waitUntil(
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
    await waitUntil(
      () => (progress() as WaitingForCapture?)?.logAccessUnavailable != null,
    );
    await r.retryLogAccess();
    await waitUntil(() => watch.hits.isNotEmpty);
    expect((progress()! as WaitingForCapture).logAccessUnavailable, isNull);
    watch.hits[0].complete(_cred());
    await done;
    expect(progress(), isA<UpdateCompleted>());
    // 只有第一次可以跳權限詢問；回到前景的自動重試不行，否則永久拒絕時會一直跳去設定頁。
    expect(resolver.calls.map((c) => c.request), [true, false]);
  });

  test(
    'cancel during slow resolve releases access and never watches',
    () async {
      final gate = Completer<LogAccessOutcome>();
      final ready = _Ready();
      resolver.results.add(() => gate.future);
      final r = await repo();

      final done = r.update();
      await waitUntil(() => resolver.calls.isNotEmpty);
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
    await waitUntil(() => watch.hits.isNotEmpty);
    watch.hits[0].complete(_cred());
    await waitUntil(() => watch.hits.length == 2);
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
    await waitUntil(() => watch.hits.isNotEmpty);
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
    await waitUntil(() => watch.hits.isNotEmpty);
    watch.hits[0].complete(_cred());
    await done;
    expect(resolver.calls.single.preferred, LogAccessMethod.root);
  });

  test('release left wireless debugging on is reported', () async {
    resolver.results.add(_Ready(leftOn: true).outcome);
    final r = await repo();
    final done = r.update();
    await waitUntil(() => watch.hits.isNotEmpty);
    watch.hits[0].complete(_cred());
    await done;
    expect((progress()! as UpdateCompleted).wirelessDebuggingLeftOn, isTrue);
  });

  test('health false shows connection lost, true clears it', () async {
    final ready = _Ready();
    resolver.results.add(ready.outcome);
    final r = await repo();
    final done = r.update();
    await waitUntil(() => watch.hits.isNotEmpty);

    ready.health.add(false);
    await waitUntil(() => (progress()! as WaitingForCapture).logConnectionLost);
    ready.health.add(true);
    await waitUntil(
      () => !(progress()! as WaitingForCapture).logConnectionLost,
    );

    watch.hits[0].complete(_cred());
    await done;
    expect(progress(), isA<UpdateCompleted>());
  });

  test('hit while in background waits for the app before fetching', () async {
    final ready = _Ready();
    resolver.results.add(ready.outcome);
    final r = await repo();
    final done = r.update();
    await waitUntil(() => watch.hits.isNotEmpty);
    foreground.foreground = false;
    watch.hits[0].complete(_cred());
    await waitUntil(
      () => (progress() as WaitingForCapture?)?.credentialReady ?? false,
    );
    expect(fetches, isEmpty, reason: 'background network is blocked');
    foreground.resumed.complete();
    await done;
    expect(fetches, isNotEmpty);
    expect(progress(), isA<UpdateCompleted>());
  });

  test('cancel while waiting for the app clears progress', () async {
    resolver.results.add(_Ready().outcome);
    final r = await repo();
    final done = r.update();
    await waitUntil(() => watch.hits.isNotEmpty);
    foreground.foreground = false;
    watch.hits[0].complete(_cred());
    await waitUntil(
      () => (progress() as WaitingForCapture?)?.credentialReady ?? false,
    );
    await r.cancelCapture();
    await done;
    expect(fetches, isEmpty);
    expect(progress(), isNull);
  });

  test('windows path still uses capture', () async {
    final c = makeContainer(android: false);
    addTearDown(c.dispose);
    c.read(gachaRepositoryProvider);
    final r = c.read(gachaRepositoryProvider.notifier);
    await r.waitForBootstrap();
    unawaited(r.update());
    await waitUntil(() => capture.starts == 1);
    expect(resolver.calls, isEmpty);
    await r.cancelCapture();
  });
}
