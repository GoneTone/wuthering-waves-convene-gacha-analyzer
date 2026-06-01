# Fetch Orchestrator (Convene) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Rewrite the capture→fetch→merge→store orchestration to drive the Wuthering Waves convene API: parse the captured POST body into a `GachaCredential`, POST `/gacha/record/query` once per `cardPoolType` in `[1,2,3,4,5,6,8,9]`, treat `{code,message,data[]}` as whole-pool results (empty `data` = success), abort on any `code!=0`, and merge each pool via ordered-list diffing.

**Architecture:** `gacha_capture.dart` parses `event.body` (the new `CapturedRequest.body` from plan 02) into a `GachaCredential` (plan 03) and returns it through `CaptureSession`. `gacha_fetcher.dart` exposes a single `fetchPool` POST call plus `GachaApiException`; `gacha_repository.dart` orchestrates 8 sequential pool fetches, merges with `mergeOrderedRecords` (plan 03), writes one `BannerStorage` keyed by `cred.playerId`/`cred.languageCode`, and on any pool failure aborts and emits `UpdateErrorGachaFailed`. The legacy paging / `end_id` / `probeUid` / retcode-backoff / odes / auto-recapture machinery is removed. The image-fetch stage (`_fetchHoYoWiki`) is owned by plan 06; this plan does **not** rename it (no `_fetchImages` alias) — it keeps calling the existing `_fetchHoYoWiki`, which still compiles, and plan 06 later renames/rewrites it.

**Tech Stack:** Dart 3 (sealed classes, pattern matching), Flutter, Riverpod `Notifier`, `package:http` (`MockClient` for tests), `package:logging`, `flutter_rust_bridge` (consumes `CapturedRequest.body`), `compute` for large-payload JSON decode.

---

## Cross-plan dependencies (read before starting)

This plan **depends on** these types from other plans. During the migration the tree may be red until all plans land; that is expected (see CLAUDE.md migration note). **Execution order is 02 → 03 → 04**: plan 02 lands `CapturedRequest.body`, plan 03 lands `GachaCredential` / `BannerStorage.playerId` / `GachaRecord.fromApiJson`, then this plan (04) wires the orchestrator on top. The orchestrator wiring (Tasks 5–7) cannot compile until plans 02/03 land. Of the additions here, only the truly self-contained ones validate in isolation: Task 1 (`GachaApiException`) and Task 3 (`UpdateErrorGachaFailed`) are pure new types with no plan-03 dependency. Task 4 (`fetchPool`) and its tests reference `GachaCredential` / `GachaRecord.fromApiJson` from plan 03 and therefore do **not** validate in isolation — they go green only after plan 03.

- Plan 02 — Rust: `CapturedRequest` gains `body: String` (frb-regenerated `lib/src/rust/api/capture.dart`). Until then `event.body` does not exist; Task 2 notes the temporary shim.
- Plan 03 — `lib/services/gacha_credential.dart`: `class GachaCredential{ String playerId, cardPoolId, serverId, recordId, languageCode }`, `factory GachaCredential.fromCapturedBody(String json)`, `Map<String,dynamic> toRequestBody(int cardPoolType)`.
- Plan 03 — `lib/models/gacha_record.dart`: `GachaRecord{ int resourceId, qualityLevel, String resourceType, cardPoolType, name, int count, DateTime time }`, `GachaRecord.fromApiJson(Map, {required String cardPoolType})`.
- Plan 03 — `lib/models/banner_storage.dart`: `BannerStorage{ String playerId, languageCode, DateTime lastUpdated, Map<String,List<GachaRecord>> banners }` (keys `'1'..'9'` minus `'7'`).
- Plan 03 — `lib/services/record_merge.dart`: `List<GachaRecord> mergeOrderedRecords(List<GachaRecord> fresh, List<GachaRecord> existing)`.
- Plan 03 — `lib/services/log_sanitize.dart`: `String sanitizeCredential(String bodyJson)`.
- Plan 03 — `lib/data/gacha_types.dart`: `gachaTypes` = 8 entries with `int cardPoolType` and `String get key`.
- Plan 06 — image stage (`item_image_*`) replaces the HoYoWiki pipeline; this plan does **not** rename the hook. It keeps calling the existing `_fetchHoYoWiki` (still present and compilable); plan 06 renames it to `_fetchItemImages` and rewrites the body.

---

## Task 1 — Add `GachaApiException` and remove the three legacy exceptions (pure, TDD-able)

**Files:**
- Modify: `lib/services/gacha_fetcher.dart` (replace lines 10–41: `AuthExpiredException` / `RateLimitedException` / `ApiErrorException`).
- Test: `test/services/gacha_fetcher_test.dart` (rewritten in Task 4; here add a focused exception test file).
- Test (new): `test/services/gacha_api_exception_test.dart`.

- [ ] Create `test/services/gacha_api_exception_test.dart` with the failing test:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_fetcher.dart';

void main() {
  test('GachaApiException carries code and message', () {
    const e = GachaApiException(-1, '请求游戏获取日志异常!');
    expect(e.code, -1);
    expect(e.message, '请求游戏获取日志异常!');
    expect(e, isA<Exception>());
    expect(e.toString(), contains('-1'));
    expect(e.toString(), contains('请求游戏获取日志异常!'));
  });
}
```
- [ ] Run `flutter test test/services/gacha_api_exception_test.dart` — expect failure: `GachaApiException` is not defined (compile error). This confirms the test drives the new type.
- [ ] In `lib/services/gacha_fetcher.dart`, delete the three classes `AuthExpiredException` (lines 10–20), `RateLimitedException` (22–26), `ApiErrorException` (28–41) and replace with:
```dart
/// 喚取記錄 API 回傳 `code != 0` 的失敗（已知 `-1`，語意待累積樣本）。
/// 取代原神版的 [AuthExpiredException] / [RateLimitedException] / [ApiErrorException]。
class GachaApiException implements Exception {
  /// 建立 [GachaApiException]，需提供 API 的 [code] 與 [message]。
  const GachaApiException(this.code, this.message);

  /// API 回傳的 `code`（0 以外即失敗）。
  final int code;

  /// API 回傳的 `message` 字串（簡體中文，不可用於語言判斷）。
  final String message;

  @override
  String toString() => 'GachaApiException(code=$code, $message)';
}
```
- [ ] Run `flutter test test/services/gacha_api_exception_test.dart` — expect `All tests passed!`.
- [ ] Run `dart format lib/services/gacha_fetcher.dart test/services/gacha_api_exception_test.dart`.
- [ ] Commit (skip if not a git repo):
```
git add lib/services/gacha_fetcher.dart test/services/gacha_api_exception_test.dart
git commit -m "feat(fetcher): add GachaApiException replacing legacy fetch exceptions"
```
(Use the trailing `Co-Authored-By` line from CLAUDE.md on every commit.)

---

## Task 2 — Make `CaptureSession` return `GachaCredential` and parse `event.body` (depends on plan 02/03)

**Files:**
- Modify: `lib/state/gacha_capture.dart` (whole file: `CaptureSession.result` type, `RustGachaCapture.start`).
- Test: `test/state/gacha_capture_test.dart` (new).

- [ ] Create `test/state/gacha_capture_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';

void main() {
  test('CaptureSession.result resolves to a GachaCredential', () async {
    final cred = GachaCredential(
      playerId: '701000000',
      cardPoolId: '2e23deadbeef2768',
      serverId: '86d5deadbeef9650',
      recordId: '0632deadbeef8550',
      languageCode: 'zh-Hant',
    );
    final session = CaptureSession(
      result: Future.value(cred),
      cancel: () async {},
    );
    final got = await session.result;
    expect(got, isNotNull);
    expect(got!.playerId, '701000000');
    expect(got.languageCode, 'zh-Hant');
  });
}
```
- [ ] Run `flutter test test/state/gacha_capture_test.dart` — expect failure: `CaptureSession.result` is `Future<String?>`, type mismatch on `Future.value(cred)`. Confirms the contract change is needed.
- [ ] In `lib/state/gacha_capture.dart`, update imports (add credential, keep logger). Change the `result` field doc + type:
```dart
  /// 解析為 [GachaCredential]，或 null 代表使用者取消 / MITM 在無命中下關閉。
  final Future<GachaCredential?> result;
```
- [ ] Add import near the top:
```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
```
- [ ] Rewrite `RustGachaCapture.start()` body so it parses the POST body into a credential (uses `event.body` added by plan 02). Replace the method:
```dart
  @override
  CaptureSession start() {
    final completer = Completer<GachaCredential?>();
    GachaCredential? captured;
    _log.info('capture started');

    rust_capture.startCapture().listen(
      (event) {
        // 已命中過就不覆寫；只取第一筆成功解析的 body。
        if (captured != null) return;
        try {
          captured = GachaCredential.fromCapturedBody(event.body);
          _log.fine(
            'captured credential host=${event.host} '
            'body=${sanitizeCredential(event.body)}',
          );
        } catch (e) {
          // 命中目標 host 但 body 非預期 JSON → 視為未命中，繼續等下一筆。
          _log.warning('failed to parse captured body host=${event.host}: $e');
        }
        // 不在此 complete：等 stream onDone（MITM graceful shutdown + system
        // proxy 已還原），此時呼叫 HTTP fetcher 才不會誤走代理。
      },
      onError: (Object e, StackTrace st) {
        _log.severe('capture error', e, st);
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (captured == null) {
          _log.info('capture done with no match');
        } else {
          _log.info(
            'capture done, playerId=${sanitizeUid(captured!.playerId)}',
          );
        }
        if (!completer.isCompleted) completer.complete(captured);
      },
    );

    return CaptureSession(
      result: completer.future,
      cancel: () async {
        _log.info('capture cancelled by user');
        await rust_capture.stopCapture();
      },
    );
  }
```
- [ ] Note for the executor: `event.body` requires plan 02's frb-regenerated `CapturedRequest`. If plan 02 has not landed when you reach this step, the file will not compile against `lib/src/rust/api/capture.dart` (no `body` field). Do **not** add a fallback — leave it referencing `event.body` and proceed; this is the expected transient red state per the migration note. Run the focused test once plan 02 + plan 03 are present.
- [ ] After plan 02/03 are present: run `flutter test test/state/gacha_capture_test.dart` — expect `All tests passed!`.
- [ ] Run `dart format lib/state/gacha_capture.dart test/state/gacha_capture_test.dart`.
- [ ] Commit (skip if not a git repo):
```
git add lib/state/gacha_capture.dart test/state/gacha_capture_test.dart
git commit -m "feat(capture): return GachaCredential parsed from captured POST body"
```

---

## Task 3 — Add `UpdateErrorGachaFailed`, fix `FetchingBanner.pageIndex` semantics (pure-ish)

**Files:**
- Modify: `lib/state/update_error.dart` (add new class; remove `UpdateErrorAuthExpired` / `UpdateErrorRateLimited` / `UpdateErrorServer` per spec §B5 consolidation — keep `UpdateErrorNoRecords`, `UpdateErrorOther`, and leave `UpdateErrorWipeHoYoWikiCache` untouched — its rename is owned by plan 06).
- Modify: `lib/state/update_progress.dart` (`FetchingBanner.pageIndex` dartdoc → pool index). **Do not** touch `HoYoWikiPhase` / `FetchingHoYoWiki` / `UpdateCompleted.hoYoWikiImagesDownloaded` — those are owned by plan 06; leave them so the legacy `_fetchHoYoWiki` keeps compiling.
- Test (new): `test/state/update_error_test.dart`.

- [ ] Create `test/state/update_error_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/update_error.dart';

void main() {
  test('UpdateErrorGachaFailed carries code and message', () {
    const e = UpdateErrorGachaFailed(-1, '请求游戏获取日志异常!');
    expect(e, isA<UpdateError>());
    expect(e.code, -1);
    expect(e.message, '请求游戏获取日志异常!');
  });
}
```
- [ ] Run `flutter test test/state/update_error_test.dart` — expect failure: `UpdateErrorGachaFailed` undefined.
- [ ] In `lib/state/update_error.dart`, delete `UpdateErrorAuthExpired` (lines 6–10), `UpdateErrorRateLimited` (12–16), `UpdateErrorServer` (18–25). Insert after the `UpdateError` sealed declaration:
```dart
/// 喚取記錄 API 回傳 `code != 0`（整併原神版 AuthExpired/RateLimited/ApiError）。
/// 由於無法區分 recordId 過期 vs 其他錯誤，UI 一律以通用措辭提示重開喚取記錄頁。
class UpdateErrorGachaFailed extends UpdateError {
  /// 建立 [UpdateErrorGachaFailed]，[code] / [message] 來自 API 回應。
  const UpdateErrorGachaFailed(this.code, this.message);

  /// API 回傳的 `code`（0 以外）。
  final int code;

  /// API 回傳的 `message`（簡體中文，僅供日誌；UI 不直接顯示）。
  final String message;
}
```
- [ ] Note: `UpdateErrorWipeHoYoWikiCache` (now lines ~17–25 after deletion) is renamed by plan 06; leave it untouched here so the repo compiles.
- [ ] Run `flutter test test/state/update_error_test.dart` — expect `All tests passed!`.
- [ ] In `lib/state/update_progress.dart`, change the `FetchingBanner.pageIndex` dartdoc (line 41) to reflect pool index, and rename the field for clarity to `poolIndex`:
  - Replace the constructor param `required this.pageIndex,` with `required this.poolIndex,` and `required this.poolCount,`.
  - Replace the field block (lines 38–45) with:
```dart
  /// 正在拉取的 cardPoolType（字串 key，如 `'1'`、`'8'`）。
  final String gachaType;

  /// 顯示用的卡池名稱 i18n key。
  final String displayName;

  /// 目前正在抓第幾個 cardPoolType（1-based，共 [poolCount] 個）。
  final int poolIndex;

  /// 本次更新需迭代的 cardPoolType 總數（固定 8）。
  final int poolCount;

  /// 到目前為止累積的新紀錄數。
  final int newRecordsSoFar;
```
- [ ] Run `dart format lib/state/update_error.dart lib/state/update_progress.dart test/state/update_error_test.dart`.
- [ ] Commit (skip if not a git repo):
```
git add lib/state/update_error.dart lib/state/update_progress.dart test/state/update_error_test.dart
git commit -m "feat(update): add UpdateErrorGachaFailed and repurpose FetchingBanner to pool index"
```

---

## Task 4 — Rewrite `GachaFetcher` to a single-POST per-pool fetcher (TDD)

**Files:**
- Modify: `lib/services/gacha_fetcher.dart` (delete `FetchedPage`, `FetchProgress`, `fetchPage`, `fetchBannerWithMerge`, `_idGreater`, `probeUid`, `UidProbeResult`; add `FetchedPoolResult` + `fetchPool`; keep `rateLimit` field, drop `retryBackoff`/`_maxRetryOnRateLimit`/`_pageSize`).
- Test: rewrite `test/services/gacha_fetcher_test.dart` (delete old groups, write new POST-based tests).

- [ ] Replace the entire body of `test/services/gacha_fetcher_test.dart` with:
```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_fetcher.dart';

GachaCredential _cred() => GachaCredential(
  playerId: '701000000',
  cardPoolId: '2e23deadbeef2768',
  serverId: '86d5deadbeef9650',
  recordId: '0632deadbeef8550',
  languageCode: 'zh-Hant',
);

Uri get _endpoint =>
    Uri.parse('https://gmserver-api.aki-game2.net/gacha/record/query');

http.Response _ok(List<Map<String, dynamic>> data) => http.Response(
  jsonEncode({'code': 0, 'message': 'success', 'data': data}),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _fail(int code, String message) => http.Response(
  jsonEncode({'code': code, 'message': message, 'data': <dynamic>[]}),
  200,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _row({
  required int resourceId,
  required int quality,
  required String type,
  required String name,
  required String time,
}) => {
  'cardPoolType': '1',
  'resourceId': resourceId,
  'qualityLevel': quality,
  'resourceType': type,
  'name': name,
  'count': 1,
  'time': time,
};

void main() {
  group('GachaFetcher.fetchPool', () {
    test('POSTs JSON body and parses code==0 data list', () async {
      String? capturedBody;
      String? capturedContentType;
      final mock = MockClient((req) async {
        capturedBody = req.body;
        capturedContentType = req.headers['content-type'];
        expect(req.method, 'POST');
        expect(req.url, _endpoint);
        return _ok([
          _row(
            resourceId: 1211,
            quality: 5,
            type: '角色',
            name: '達妮婭',
            time: '2026-05-21 10:39:03',
          ),
        ]);
      });
      final fetcher = GachaFetcher(rateLimit: Duration.zero);
      final result = await fetcher.fetchPool(
        endpoint: _endpoint,
        cred: _cred(),
        cardPoolType: 1,
        client: mock,
      );
      expect(result.records, hasLength(1));
      expect(result.records.first.resourceId, 1211);
      expect(result.records.first.cardPoolType, '1');
      // request body carries the credential + cardPoolType (int)
      final sent = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(sent['playerId'], '701000000');
      expect(sent['cardPoolType'], 1);
      expect(capturedContentType, contains('application/json'));
    });

    test('empty data on code==0 is a successful empty pool (not an error)', () async {
      final mock = MockClient((req) async => _ok(const []));
      final fetcher = GachaFetcher(rateLimit: Duration.zero);
      final result = await fetcher.fetchPool(
        endpoint: _endpoint,
        cred: _cred(),
        cardPoolType: 9,
        client: mock,
      );
      expect(result.records, isEmpty);
    });

    test('code!=0 throws GachaApiException with code+message', () async {
      final mock = MockClient((req) async => _fail(-1, '请求游戏获取日志异常!'));
      final fetcher = GachaFetcher(rateLimit: Duration.zero);
      await expectLater(
        () => fetcher.fetchPool(
          endpoint: _endpoint,
          cred: _cred(),
          cardPoolType: 1,
          client: mock,
        ),
        throwsA(
          isA<GachaApiException>()
              .having((e) => e.code, 'code', -1)
              .having((e) => e.message, 'message', '请求游戏获取日志异常!'),
        ),
      );
    });
  });

  group('logging instrumentation', () {
    setUp(() => Logger.root.level = Level.ALL);
    tearDown(() => Logger.root.clearListeners());

    test('emits SEVERE when code!=0', () async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      final mock = MockClient((req) async => _fail(-1, 'boom'));
      final fetcher = GachaFetcher(rateLimit: Duration.zero);
      await expectLater(
        () => fetcher.fetchPool(
          endpoint: _endpoint,
          cred: _cred(),
          cardPoolType: 1,
          client: mock,
        ),
        throwsA(isA<GachaApiException>()),
      );
      final severe = records.firstWhere(
        (r) => r.level == Level.SEVERE && r.loggerName == 'gacha.fetcher',
        orElse: () => throw StateError('no SEVERE from gacha.fetcher'),
      );
      expect(severe.message, contains('code=-1'));
    });
  });
}
```
- [ ] Run `flutter test test/services/gacha_fetcher_test.dart` — expect failure: `fetchPool` / `FetchedPoolResult` undefined (and `GachaCredential` may be unresolved until plan 03). This is the failing-test gate.
- [ ] In `lib/services/gacha_fetcher.dart`, replace the imports block (lines 1–8) with:
```dart
import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
```
- [ ] Replace the old `FetchedPage` class (lines 43–56) with:
```dart
/// 單一 cardPoolType 的整池全歷史回應（鳴潮 API 無分頁，一次回傳整池）。
class FetchedPoolResult {
  /// 建立 [FetchedPoolResult]，[records] 為該池由新到舊的全歷史。
  const FetchedPoolResult(this.records);

  /// 該池全歷史紀錄（依 API 回傳順序：由新到舊）。
  final List<GachaRecord> records;

  /// 該池是否無紀錄（空池 = 成功非失敗）。
  bool get isEmpty => records.isEmpty;

  /// 該池紀錄數。
  int get length => records.length;
}
```
- [ ] Delete `FetchProgress` (old lines 58–75) entirely. Replace the `GachaFetcher` class (old lines 77–286) and the trailing `UidProbeResult` (288–298) with:
```dart
/// 負責呼叫鳴潮喚取記錄 API（POST `/gacha/record/query`），逐 cardPoolType 各一次。
class GachaFetcher {
  /// 建立 [GachaFetcher]，可調整速率限制與逾時設定。
  GachaFetcher({
    this.rateLimit = const Duration(milliseconds: 600),
    this.timeout = const Duration(seconds: 15),
  });

  /// 兩次 API 呼叫之間的最短間隔（夾在 8 個 cardPoolType 之間，避免被擋）。
  final Duration rateLimit;

  /// 單次 HTTP 請求超時。
  final Duration timeout;

  /// Logger 實例（gacha 抓取）。
  static final _log = Logger('gacha.fetcher');

  /// 單池全歷史可能上千筆，超過此長度改用 [compute] 在 isolate 解析避免卡 UI。
  static const _isolateDecodeThreshold = 50 * 1024;

  /// 抓單一 [cardPoolType] 的整池全歷史。
  ///
  /// 對 [endpoint] 發 POST，body 為 `cred.toRequestBody(cardPoolType)` 的 JSON。
  /// 回應 `{code,message,data[]}`：`code==0` → 取 `data`（空 = 空池，正常）；
  /// `code!=0` → 丟 [GachaApiException]（任一池失敗由呼叫端中止整次更新）。
  Future<FetchedPoolResult> fetchPool({
    required Uri endpoint,
    required GachaCredential cred,
    required int cardPoolType,
    required http.Client client,
  }) async {
    _log.fine(
      'fetchPool cardPoolType=$cardPoolType '
      'playerId=${_maskTail(cred.playerId)}',
    );
    final res = await client
        .post(
          endpoint,
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(cred.toRequestBody(cardPoolType)),
        )
        .timeout(timeout);

    final body = await _decodeJson(res.body);
    final code = (body['code'] as num?)?.toInt() ?? -999;
    final message = body['message'] as String? ?? '';
    if (code != 0) {
      _log.severe(
        'fetchPool failed cardPoolType=$cardPoolType code=$code msg=$message',
      );
      throw GachaApiException(code, message);
    }
    final data = (body['data'] as List<dynamic>?) ?? const [];
    final cardPoolTypeKey = cardPoolType.toString();
    final records = data
        .map(
          (e) => GachaRecord.fromApiJson(
            e as Map<String, dynamic>,
            cardPoolType: cardPoolTypeKey,
          ),
        )
        .toList(growable: false);
    _log.info(
      'fetchPool ok cardPoolType=$cardPoolType records=${records.length}',
    );
    return FetchedPoolResult(records);
  }

  /// 大 payload 在 isolate 解析避免卡 UI；小 payload 直接 [jsonDecode]。
  Future<Map<String, dynamic>> _decodeJson(String raw) async {
    if (raw.length >= _isolateDecodeThreshold) {
      return compute(_jsonDecodeMap, raw);
    }
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// playerId 末段遮罩（僅供 fine log；正式脫敏在 [sanitizeUid]）。
  String _maskTail(String s) =>
      s.length <= 4 ? '***' : '***${s.substring(s.length - 4)}';
}

/// 頂層函式：供 [compute] 在 isolate 內解析 JSON Map。
Map<String, dynamic> _jsonDecodeMap(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;
```
- [ ] Run `flutter test test/services/gacha_fetcher_test.dart` — once plan 03 (`GachaCredential` / `GachaRecord.fromApiJson`) is present, expect `All tests passed!`. (If plan 03 has not landed, the test will not compile against `GachaCredential`; that is the expected transient state — proceed and re-run after plan 03.)
- [ ] Run `dart format lib/services/gacha_fetcher.dart test/services/gacha_fetcher_test.dart`.
- [ ] Commit (skip if not a git repo):
```
git add lib/services/gacha_fetcher.dart test/services/gacha_fetcher_test.dart
git commit -m "feat(fetcher): rewrite GachaFetcher to single POST per cardPoolType"
```

---

## Task 5 — Rewrite `_runUpdate` / `_runMitm` (orchestrator entry, no auto-recapture)

**Files:**
- Modify: `lib/state/gacha_repository.dart`:
  - imports (lines 8–25): drop `gacha_url.dart`; keep others; image-stage imports (`hoyowiki_*`) stay until plan 06.
  - `_NoRecordsException` (lines 27–30): keep (NoRecords still applies, redefined in Task 6).
  - `_runUpdate` (lines 197–307): rewrite credential cache + no auto-recapture fallback.
  - `_runMitm` (lines 309–322): return `GachaCredential?`.
- Test: covered by Task 7 repository tests.

- [ ] Replace `_runUpdate` (lines 197–307) with the version below. Key changes: cache is the credential JSON (`loadCapturedCredential`/`saveCapturedCredential`/`deleteCapturedCredential` from plan 03 storage), `_runMitm` returns a `GachaCredential`, and there is **no** `on AuthExpiredException → recapture` branch — a `GachaApiException` becomes `UpdateFailed(UpdateErrorGachaFailed(...))` directly.
```dart
  /// 實際執行更新流程；[forceRecapture] 為 true 時強制重新 MITM 捕獲。
  Future<void> _runUpdate({required bool forceRecapture}) async {
    if (_isUpdating) return; // 防止重入
    _isUpdating = true;
    _cancelTriggered = false;
    _log.info('update start, forceRecapture=$forceRecapture');

    final cancellable = ref.read(cancellableHttpClientFactoryProvider)();
    _activeCancellable = cancellable;

    // 立刻 set Preparing → ref.listen 立刻觸發 dialog。
    state = state.copyWith(progress: const Preparing());

    try {
      final initialActiveUid = state.activeUid;
      final storage = ref.read(gachaStorageProvider);
      final fetcher = ref.read(gachaFetcherProvider);

      if (forceRecapture && initialActiveUid != null) {
        await storage.deleteCapturedCredential(initialActiveUid);
        if (!ref.mounted) return;
      }

      GachaCredential? cred;

      if (!forceRecapture && initialActiveUid != null) {
        final cachedJson = await storage.loadCapturedCredential(
          initialActiveUid,
        );
        if (!ref.mounted) return;
        if (cachedJson != null) {
          try {
            cred = GachaCredential.fromCapturedBody(cachedJson);
            _log.info(
              'using cached credential for playerId='
              '${sanitizeUid(initialActiveUid)}',
            );
          } catch (e) {
            _log.warning('cached credential malformed, recapturing: $e');
          }
        }
      }

      cred ??= await _runMitm();
      if (!ref.mounted) return;
      if (cred == null) {
        _log.info('update aborted (user cancelled capture)');
        state = state.copyWith(clearProgress: true);
        return;
      }

      try {
        await _fetchAllBanners(
          cred: cred,
          fetcher: fetcher,
          storage: storage,
          client: cancellable.client,
        );
      } on GachaApiException catch (e) {
        // recordId 過期或其他後端錯誤：不自動重打（無效），純提示玩家重開頁。
        if (!ref.mounted) return;
        _log.warning('gacha api failed code=${e.code} msg=${e.message}');
        state = state.copyWith(
          progress: UpdateFailed(UpdateErrorGachaFailed(e.code, e.message)),
        );
      } on _NoRecordsException {
        if (!ref.mounted) return;
        state = state.copyWith(
          progress: const UpdateFailed(UpdateErrorNoRecords()),
        );
      } on http.ClientException catch (e) {
        if (!ref.mounted) return;
        if (_cancelTriggered) {
          _log.info('update cancelled (http client closed)');
          state = state.copyWith(clearProgress: true);
        } else {
          _log.warning(
            'http client error: ${e.message}'
            '${e.uri != null ? " uri=${sanitizeUrl(e.uri!.toString())}" : ""}',
          );
          state = state.copyWith(progress: UpdateFailed(_friendlyError(e)));
        }
      } catch (e, st) {
        if (!ref.mounted) return;
        _log.severe('update unexpected error', e, st);
        state = state.copyWith(progress: UpdateFailed(_friendlyError(e)));
      }
    } finally {
      _activeCancellable?.client.close();
      _activeCancellable = null;
      _cancelTriggered = false;
      _isUpdating = false;
    }
  }
```
- [ ] Replace `_runMitm` (lines 309–322) with (drops `isFallback`, returns credential):
```dart
  /// 啟動 MITM 捕獲會話並等候 [GachaCredential]。
  Future<GachaCredential?> _runMitm() async {
    state = state.copyWith(progress: const WaitingForCapture());
    final session = ref.read(gachaCaptureProvider).start();
    _activeCancel = session.cancel;
    _log.info('MITM session started');
    try {
      final result = await session.result;
      _log.info('MITM session done, hasCredential=${result != null}');
      return result;
    } finally {
      _activeCancel = null;
    }
  }
```
- [ ] Add the import for `GachaCredential` to `lib/state/gacha_repository.dart` (after the existing service imports):
```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
```
- [ ] Remove the now-unused `gacha_url.dart` import (old line 15).
- [ ] In `lib/state/update_progress.dart`, simplify `WaitingForCapture` (remove `isFallback`) since recapture-fallback is gone. Replace its class body:
```dart
/// 等待 MITM 捕獲喚取憑證。
class WaitingForCapture extends UpdateProgress {
  /// 建立 [WaitingForCapture]。
  const WaitingForCapture();
}
```
- [ ] Note: this leaves `update_progress_dialog.dart`'s `WaitingForCapture(:final isFallback)` pattern broken until Task 8; expected.
- [ ] Run `dart format lib/state/gacha_repository.dart lib/state/update_progress.dart`.
- [ ] Commit (skip if not a git repo):
```
git add lib/state/gacha_repository.dart lib/state/update_progress.dart
git commit -m "refactor(repo): credential-based update entry, drop auto-recapture fallback"
```

---

## Task 6 — Rewrite `_fetchAllBanners`, `_NoRecordsException`, `_friendlyError`

**Files:**
- Modify: `lib/state/gacha_repository.dart`:
  - `_NoRecordsException` (lines 27–30): keep name, redefine semantics in dartdoc (8 pools all `code==0` and all `data` empty).
  - `_fetchAllBanners` (lines 324–435): full rewrite.
  - `_friendlyError` (lines 1010–1021): drop removed exceptions.
  - Image hook: **do not** rename or alias it — `_fetchAllBanners` keeps calling the existing `_fetchHoYoWiki(client)` directly. The rename to `_fetchItemImages` and the body rewrite are owned by plan 06.

- [ ] Update `_NoRecordsException` dartdoc (lines 27–30):
```dart
/// 8 個卡池全部 `code==0` 且 `data` 全空（該帳號從未喚取）→ 轉成 [UpdateErrorNoRecords]。
class _NoRecordsException implements Exception {
  const _NoRecordsException();
}
```
- [ ] Replace `_fetchAllBanners` (lines 324–435) with the version below. It iterates `gachaTypes` (8 entries, `int cardPoolType` + `String key`), POSTs each pool once with `rateLimit` between calls, merges with `mergeOrderedRecords`, aborts on `GachaApiException` (rethrown to `_runUpdate`), and detects NoRecords when every pool succeeded but all were empty:
```dart
  /// 依序拉取 8 個 cardPoolType 的整池全歷史，合併存檔。
  ///
  /// 任一池 `code!=0` → 直接 rethrow [GachaApiException]（由 [_runUpdate] 中止整次
  /// 更新並提示重開喚取記錄頁）；全部成功但每池皆空 → 丟 [_NoRecordsException]。
  Future<void> _fetchAllBanners({
    required GachaCredential cred,
    required GachaFetcher fetcher,
    required GachaStorage storage,
    required http.Client client,
  }) async {
    final endpoint = Uri.parse(
      'https://gmserver-api.aki-game2.net/gacha/record/query',
    );
    final playerId = cred.playerId;

    final existing =
        state.byUid[playerId] ??
        BannerStorage(
          playerId: playerId,
          languageCode: cred.languageCode,
          lastUpdated: DateTime.utc(1970),
          banners: {for (final t in gachaTypes) t.key: <GachaRecord>[]},
        );

    final mergedBanners = <String, List<GachaRecord>>{};
    var totalNew = 0;
    var anyNonEmpty = false;

    for (var i = 0; i < gachaTypes.length; i++) {
      final t = gachaTypes[i];
      if (i > 0) {
        await Future<void>.delayed(fetcher.rateLimit);
        if (!ref.mounted) return;
      }
      state = state.copyWith(
        progress: FetchingBanner(
          gachaType: t.key,
          displayName: t.nameKey,
          poolIndex: i + 1,
          poolCount: gachaTypes.length,
          newRecordsSoFar: totalNew,
        ),
      );

      // 不在此 catch GachaApiException：往上拋給 _runUpdate 中止整次更新。
      final result = await fetcher.fetchPool(
        endpoint: endpoint,
        cred: cred,
        cardPoolType: t.cardPoolType,
        client: client,
      );
      if (!ref.mounted) return;

      final existingForPool = existing.banners[t.key] ?? const <GachaRecord>[];
      final merged = mergeOrderedRecords(result.records, existingForPool);
      mergedBanners[t.key] = merged;
      if (merged.isNotEmpty) anyNonEmpty = true;
      totalNew += merged.length - existingForPool.length;
    }

    if (!anyNonEmpty && existing.banners.values.every((l) => l.isEmpty)) {
      throw const _NoRecordsException();
    }

    final updatedAt = DateTime.now().toUtc();
    final newData = BannerStorage(
      playerId: playerId,
      languageCode: cred.languageCode,
      lastUpdated: updatedAt,
      banners: mergedBanners,
    );
    await storage.save(newData);
    if (!ref.mounted) return;
    await storage.saveCapturedCredential(playerId, cred.toJsonString());
    if (!ref.mounted) return;

    final newByUid = Map<String, BannerStorage>.from(state.byUid)
      ..[playerId] = newData;
    _log.info(
      'update completed: playerId=${sanitizeUid(playerId)} totalNew=$totalNew',
    );
    state = state.copyWith(byUid: newByUid, activeUid: playerId);
    if (!ref.mounted) return;
    await ref.read(settingsProvider.notifier).setLastActiveUid(playerId);
    if (!ref.mounted) return;

    // 圖片補抓階段（best-effort，不影響 UpdateCompleted）。實作由 plan 06 重寫；
    // 此處沿用既有 _fetchHoYoWiki（仍可編譯），plan 06 再改名為 _fetchItemImages。
    var imagesDownloaded = 0;
    try {
      imagesDownloaded = await _fetchHoYoWiki(client);
    } catch (e, st) {
      _log.warning('image stage threw (ignored)', e, st);
    }
    if (!ref.mounted) return;
    if (_cancelTriggered) {
      state = state.copyWith(clearProgress: true);
      return;
    }
    state = state.copyWith(
      progress: UpdateCompleted(
        totalNewRecords: totalNew,
        failedBanners: const [],
        updatedAt: updatedAt,
        hoYoWikiImagesDownloaded: imagesDownloaded,
      ),
    );
  }
```
- [ ] Notes for the executor:
  - `cred.toJsonString()` is the credential-serialization helper added to plan 03's `GachaCredential`: it emits the same five-field JSON (`playerId`/`cardPoolId`/`serverId`/`recordId`/`languageCode`) that `GachaCredential.fromCapturedBody` parses, so `fromCapturedBody(cred.toJsonString())` round-trips. Use exactly `cred.toJsonString()` for saving and `GachaCredential.fromCapturedBody(jsonString)` for loading — do **not** use any `toJson` / `toCapturedBody` name (they are not defined).
  - `mergeOrderedRecords` import: add to `lib/state/gacha_repository.dart`:
```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/record_merge.dart';
```
  - `failedBanners` is now always empty (any pool failure aborts the whole update), but `UpdateCompleted.failedBanners` is kept for shape compatibility; plan 08 may drop the field.
- [ ] Do **not** add any `_fetchImages` alias. `_fetchAllBanners` calls the existing `_fetchHoYoWiki(client)` directly (it still exists and compiles). Plan 06 owns renaming it to `_fetchItemImages` and rewriting the body to item_image (guide-server) — this plan leaves the hook untouched.
- [ ] Replace `_friendlyError` (lines 1010–1021) with (removes `RateLimitedException`/`ApiErrorException`/`AuthExpiredException`; `GachaApiException` handled inline in `_runUpdate`, but kept here as defensive fallback):
```dart
  /// 將各種 exception 轉換成對應的 [UpdateError] 子類，供 UI 顯示。
  UpdateError _friendlyError(Object e) => switch (e) {
    _NoRecordsException() => const UpdateErrorNoRecords(),
    GachaApiException(:final code, :final message) => UpdateErrorGachaFailed(
      code,
      message,
    ),
    FormatException(:final message) => UpdateErrorOther(message),
    http.ClientException(:final message, :final uri) => UpdateErrorOther(
      uri != null ? '$message ($uri)' : message,
    ),
    _ => UpdateErrorOther(e.toString()),
  };
```
- [ ] Update the `_runImport` body where it references `account.data.uid` (lines 643, 647, 650, etc.): these now read `account.data.playerId` per plan 03's `BannerStorage`. Apply the rename across `_runImport` (lines 624–716): `account.data.uid` → `account.data.playerId`. (Mechanical; the field type/usage is identical.)
- [ ] Note: the image-stage call sites in `forceRefetchAllHoYoWikiImages` (line 511), `importAccountsAndFetchHoYoWiki` (line 575), and `debugRunHoYoWikiOnly` (line 1004) still call `_fetchHoYoWiki` directly — leave them; plan 06 owns the full image-stage rewrite and rename. This plan does not touch the image hook (no rename, no alias) — `_fetchAllBanners` keeps calling the existing `_fetchHoYoWiki(client)`.
- [ ] Run `dart format lib/state/gacha_repository.dart`.
- [ ] Commit (skip if not a git repo):
```
git add lib/state/gacha_repository.dart
git commit -m "refactor(repo): per-pool fetch+merge over 8 cardPoolTypes, abort on code!=0"
```

---

## Task 7 — Rewrite repository update-path tests for the convene flow (TDD)

**Files:**
- Modify: `test/state/gacha_repository_test.dart`:
  - `_FakeCapture` now returns `GachaCredential?`.
  - All `BannerStorage(uid:..., banners: {'301':...})` literals → `BannerStorage(playerId:..., languageCode:..., banners: {'1':...,'2':...,'3':...,'4':...,'5':...,'6':...,'8':...,'9':...})`.
  - Replace the `AuthExpired 連續 2 次` test (lines 122–181) with a code!=0 abort test (no recapture).
  - Replace the legacy paging-based MockClient responses (the `retcode/data.list` shape) with `{code,message,data[]}`.
- Add: `test/state/gacha_repository_update_test.dart` (new, focused convene update happy + error paths) to avoid editing every bootstrap test at once.

- [ ] Create `test/state/gacha_repository_update_test.dart`:
```dart
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

  test('happy path: 8 pools fetched, stored, UpdateCompleted', () async {
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

    expect(hitTypes, [1, 2, 3, 4, 5, 6, 8, 9]);
    final progress = container.read(gachaRepositoryProvider).progress;
    expect(progress, isA<UpdateCompleted>());
    expect((progress as UpdateCompleted).totalNewRecords, 1);
    final state = container.read(gachaRepositoryProvider);
    expect(state.activeUid, '701000000');
    expect(state.byUid['701000000']!.banners['1'], hasLength(1));
    expect(state.byUid['701000000']!.languageCode, 'zh-Hant');
  });

  test('any pool code!=0 aborts with UpdateErrorGachaFailed (no recapture)', () async {
    final storage = GachaStorage(tempDir);
    var captureCalls = 0;
    var poolHits = 0;
    final mock = MockClient((req) async {
      poolHits++;
      // first pool succeeds, second fails → abort
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final type = body['cardPoolType'] as int;
      return http.Response(
        type == 1 ? _ok(const []) : _fail(-1),
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
    expect(progress, isA<UpdateFailed>());
    expect((progress as UpdateFailed).error, isA<UpdateErrorGachaFailed>());
    expect(
      (progress.error as UpdateErrorGachaFailed).code,
      -1,
    );
    // capture invoked exactly once (no auto-recapture fallback)
    expect(captureCalls, 1);
    // aborted at pool 2 (did NOT iterate all 8)
    expect(poolHits, lessThan(8));
  });

  test('all 8 pools empty → UpdateErrorNoRecords', () async {
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
          '1': [], '2': [], '3': [], '4': [],
          '5': [], '6': [], '8': [], '9': [],
        },
      ),
    );
    await storage.saveCapturedCredential(
      '701000000',
      _cred().toJsonString(),
    );
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
    expect(container.read(gachaRepositoryProvider).progress, isA<UpdateCompleted>());
  });
}
```
- [ ] Run `flutter test test/state/gacha_repository_update_test.dart` — once plans 02/03 and Tasks 5–6 are in place, expect `All tests passed!`. (Before then, expect compile failures against `GachaCredential` / `BannerStorage.playerId` — the intended TDD red.)
- [ ] Update the existing `test/state/gacha_repository_test.dart`:
  - In `_FakeCapture` (lines 21–28), change the field type to `GachaCredential?` and the constructor accordingly; bootstrap tests that pass `null` are unaffected.
  - Globally replace `BannerStorage(uid: '...', lastUpdated: ..., banners: const {'301': [], '302': [], '500': [], '200': [], '100': []})` with the 8-pool convene shape and `playerId`/`languageCode`:
```dart
BannerStorage(
  playerId: '701000001',
  languageCode: 'zh-Hant',
  lastUpdated: DateTime.utc(2026, 1, 1),
  banners: const {
    '1': [], '2': [], '3': [], '4': [],
    '5': [], '6': [], '8': [], '9': [],
  },
)
```
   (Apply the same playerId values the tests already use, e.g. `100000001` → keep as opaque strings; only the `uid:`→`playerId:` keyword, the added `languageCode:`, and the banners keys change.)
  - Delete the `AuthExpired 連續 2 次` test (lines 122–181) and the `cancelPreparing 在 FetchingBanner 階段` test (lines 524–642): both encode legacy paging / recapture semantics. The replacement happy/error coverage lives in `gacha_repository_update_test.dart`. (A pool-stage cancel test can be re-added later if plan 08 needs it; YAGNI for now.)
  - In the `logging instrumentation` group (lines 1195–1324), replace the `getGachaLog?authkey=...` cached-URL seeding and `retcode/data.list` MockClient with the convene shape: `saveCapturedCredential('100000001', _cred().toJsonString())` and a MockClient returning `{code:0,data:[]}`; assert the `gacha.repo` logs `update start` and `update completed`.
  - In `_FailingStorage` (lines 1327–1338), change `data.uid` → `data.playerId`.
- [ ] Run `flutter test test/state/gacha_repository_test.dart` — expect `All tests passed!` (after plan 02/03).
- [ ] Run `dart format test/state/gacha_repository_test.dart test/state/gacha_repository_update_test.dart`.
- [ ] Commit (skip if not a git repo):
```
git add test/state/gacha_repository_test.dart test/state/gacha_repository_update_test.dart
git commit -m "test(repo): cover convene per-pool update, code!=0 abort, NoRecords"
```

---

## Task 8 — Update `update_progress_dialog.dart` copy for pool index and removed states

**Files:**
- Modify: `lib/widgets/update_progress_dialog.dart`:
  - `_Body.resolveBannerName` (lines 151–160): 8 convene nameKeys.
  - `FetchingBanner(... pageIndex ...)` (lines 183–200): use `poolIndex`/`poolCount`.
  - `WaitingForCapture(:final isFallback)` (lines 171–182): drop `isFallback`.
  - `_resolveError` (lines 271–280): map `UpdateErrorGachaFailed` → generic reopen hint; drop removed errors.
- Modify: `lib/l10n/app_zh.arb` (+ `app_zh_Hans.arb`, `app_en.arb`, `app_ja.arb`): **only** add `progressPoolStatus`, `errorGachaFailed`; remove `progressFallbackHint`, `errorAuthExpired`/`errorRateLimited`/`errorServer`. **Do not** touch `progressOpenGameHint` (owned by plan 07) or the 8 `gachaType*` nameKeys (owned by plan 05) — only reference them here.
- Test: widget tests for this dialog are owned by plan 08/UI; here just keep the file compiling and analyze-clean. The l10n nameKeys are produced by plan 05's ARB task.

- [ ] Note dependency: the 8 convene `gachaType*` ARB keys (`gachaTypeCharacter`, `gachaTypeWeapon`, `gachaTypeStandardCharacter`, `gachaTypeStandardWeapon`, `gachaTypeBeginner`, `gachaTypeBeginnerChoice`, `gachaTypeNewVoyageCharacter`, `gachaTypeNewVoyageWeapon`) are added by plan 05's i18n task. `progressOpenGameHint` is owned by plan 07. This task only adds `progressPoolStatus` + `errorGachaFailed`, removes the four legacy keys, and references the convene nameKeys + `progressOpenGameHint` in the dialog switch.
- [ ] In `lib/l10n/app_zh.arb`, replace the `progressPageStatus` entry (lines 142–148) with a pool-status string and add `errorGachaFailed`; remove `progressFallbackHint`. **Do not** add or edit `progressOpenGameHint` here — it is plan 07's key:
```json
  "progressPoolStatus": "第 {index} / {total} 個卡池，已新增 {count} 筆",
  "@progressPoolStatus": {
    "placeholders": {
      "index": { "type": "int" },
      "total": { "type": "int" },
      "count": { "type": "int" }
    }
  },
```
  And in the errors section, replace `errorAuthExpired`/`errorRateLimited`/`errorServer` (lines 199–204) with:
```json
  "errorGachaFailed": "取得記錄失敗，請重開喚取記錄頁再試",
```
  (Keep `errorNoRecords` as-is; any text change to it is out of this plan's ARB scope.)
- [ ] Mirror the same edits in `lib/l10n/app_zh_Hans.arb`, `lib/l10n/app_en.arb`, `lib/l10n/app_ja.arb` with appropriate translations (only `progressPoolStatus` + `errorGachaFailed`; `progressOpenGameHint` stays untouched — plan 07 owns it):
  - en `progressPoolStatus`: "Pool {index} / {total}, {count} new"
  - en `errorGachaFailed`: "Failed to fetch records. Please reopen the Convene History page and try again."
  - ja `progressPoolStatus`: "{total} 件中 {index} 件目の卡池、{count} 件追加"
  - ja `errorGachaFailed`: "記録の取得に失敗しました。集音履歴ページを開き直して再試行してください。"
  - zh_Hans: 简体对应（「第 {index} / {total} 个卡池，已新增 {count} 笔」/「获取记录失败，请重开唤取记录页再试」）。
- [ ] Run `flutter gen-l10n`.
- [ ] In `lib/widgets/update_progress_dialog.dart`, replace `resolveBannerName` (lines 151–160) with the 8 convene keys:
```dart
    String resolveBannerName(String key) => switch (key) {
      'gachaTypeCharacter' => l.gachaTypeCharacter,
      'gachaTypeWeapon' => l.gachaTypeWeapon,
      'gachaTypeStandardCharacter' => l.gachaTypeStandardCharacter,
      'gachaTypeStandardWeapon' => l.gachaTypeStandardWeapon,
      'gachaTypeBeginner' => l.gachaTypeBeginner,
      'gachaTypeBeginnerChoice' => l.gachaTypeBeginnerChoice,
      'gachaTypeNewVoyageCharacter' => l.gachaTypeNewVoyageCharacter,
      'gachaTypeNewVoyageWeapon' => l.gachaTypeNewVoyageWeapon,
      _ => key,
    };
```
- [ ] Replace the `WaitingForCapture` arm (lines 171–182) with (no `isFallback`):
```dart
      WaitingForCapture() => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LinearProgressIndicator(),
          const SizedBox(height: AppSpacing.l),
          Text(l.progressOpenGameHint),
        ],
      ),
```
- [ ] Replace the `FetchingBanner(...)` arm (lines 183–200) with `poolIndex`/`poolCount`:
```dart
      FetchingBanner(
        :final displayName,
        :final poolIndex,
        :final poolCount,
        :final newRecordsSoFar,
      ) =>
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: AppSpacing.l),
            Text(l.progressFetchingBanner(resolveBannerName(displayName))),
            const SizedBox(height: AppSpacing.xs),
            Text(
              l.progressPoolStatus(poolIndex, poolCount, newRecordsSoFar),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
```
- [ ] Replace `_resolveError` (lines 271–280) with:
```dart
  /// 將 [UpdateError] 轉為對應的本地化錯誤訊息。
  String _resolveError(UpdateError error, AppLocalizations l) =>
      switch (error) {
        UpdateErrorGachaFailed() => l.errorGachaFailed,
        UpdateErrorNoRecords() => l.errorNoRecords,
        UpdateErrorOther(:final message) => message,
        UpdateErrorWipeHoYoWikiCache(:final detail) =>
          l.updateErrorWipeHoyoWikiCache(detail),
      };
```
- [ ] Note: `FetchingHoYoWiki` title/body arms (lines 112–116, 201–222) and `updateErrorWipeHoyoWikiCache` are owned by plan 06's image-stage rename — leave them so the dialog compiles now.
- [ ] Run `dart format lib/widgets/update_progress_dialog.dart`.
- [ ] Commit (skip if not a git repo):
```
git add lib/widgets/update_progress_dialog.dart lib/l10n/ lib/l10n/generated/
git commit -m "feat(ui): update progress dialog copy for per-pool fetch and gacha-failed error"
```

---

## Task 9 — Full-suite verification (run after plans 02/03/06/07 have landed)

**Files:** none (verification only).

- [ ] Run `dart format lib/ test/` — expect no diffs (or only formatting fixes already committed).
- [ ] Run `flutter analyze` — expect `No issues found!`. If residual references to removed symbols (`AuthExpiredException`, `FetchedPage`, `probeUid`, `pageIndex`, `isFallback`, `loadCapturedUrl`) appear, they belong to call sites outside this plan's scope (plan 06 image stage, plan 05 ARB nameKeys, plan 07 UI/i18n) — confirm each is in another plan's task; do not silently patch unrelated code.
- [ ] Run `flutter test` — expect `All tests passed!`.
- [ ] Run `cargo test --manifest-path rust/Cargo.toml` — expect pass (Rust body is plan 02; this confirms the workspace still builds).
- [ ] If all four pass, the fetch-orchestrator slice is complete. No `git push`.

---

## Notes & invariants for the executor

- **Single endpoint constant**: `https://gmserver-api.aki-game2.net/gacha/record/query` appears in `gacha_fetcher_test.dart`, `gacha_repository.dart` `_fetchAllBanners`, and the convene repo tests. Keep them identical (international server only; no national-server parameterization — YAGNI).
- **`cardPoolType` int↔string boundary (D4)**: the request body uses `int` (`cred.toRequestBody(cardPoolType)` and `t.cardPoolType`); storage map keys and `GachaRecord.cardPoolType` use `String` (`t.key`, `cardPoolType.toString()`). Do not introduce other conversion points.
- **Empty `data` is success**: never treat `code==0 && data==[]` as an error. NoRecords is only when **all 8** pools are `code==0` and every pool (fresh + existing) is empty.
- **No auto-recapture**: a `GachaApiException` (recordId expired or other) must surface as `UpdateFailed(UpdateErrorGachaFailed(...))`; the user reopens the in-game Convene History page to re-capture a fresh `recordId`. Re-firing the same expired credential is useless.
- **Sequential, rate-limited**: 8 pools are fetched in order with `fetcher.rateLimit` between calls (not concurrent) — safer against backend throttling.
- **Large payloads**: `GachaFetcher._decodeJson` offloads to `compute` past `_isolateDecodeThreshold`; a single convene pool can be thousands of rows.
- **Logging (CLAUDE.md)**: `gacha.fetcher` logs pool index, record count, and `code`/`message` on failure; `gacha.repo` logs `update start` / `update completed` with `sanitizeUid(playerId)`; `gacha.capture` logs `sanitizeCredential(event.body)` (never raw body). Sanitize before writing.
- **Migration red-light / execution order (02 → 03 → 04)**: type replacements (`GachaCredential`, `BannerStorage.playerId`, `GachaRecord.fromApiJson` new signature) come from plans 02/03 and must land before this plan's wiring compiles. Only the genuinely self-contained additions validate in isolation: Task 1 (`GachaApiException`) and Task 3 (`UpdateErrorGachaFailed`) are pure new types with no plan-03 dependency. Task 4 (`fetchPool` and its tests) references plan 03's `GachaCredential` / `GachaRecord.fromApiJson` — it does **not** validate in isolation and goes green only after plan 03. The orchestrator (Tasks 5–7) and its repository tests go green only once plans 02/03 land. This is expected per the migration note in CLAUDE.md.