# Restore Three-Way Convene Fetch Failure Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Revert the migration regression that turned every `code != 0` into a blocking「失敗」dialog, restoring the original three-way failure handling (auto-recapture / per-pool graceful skip / network fail) adapted to Wuthering Waves' shared `recordId`.

**Architecture:** `_fetchAllBanners` becomes per-pool fault-tolerant: a single pool's `code != 0` is recorded into a `failed` list (keep old data, keep going); when **all** pools fail it throws an internal `_AllPoolsFailedException`, which `_runUpdate` catches to auto-recapture once (mirroring the original `AuthExpiredException` path). Partial failures surface as the existing red「部分失敗」text on an otherwise-successful `UpdateCompleted`.

**Tech Stack:** Flutter, Riverpod (`Notifier`), `package:http` + `MockClient`, `flutter_test`, ARB-based l10n (`flutter gen-l10n`).

**Spec:** `docs/superpowers/specs/2026-06-03-convene-fetch-failure-flow-design.md`

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `lib/state/update_progress.dart` | `UpdateProgress` 狀態模型 | Restore `WaitingForCapture.isFallback` |
| `lib/l10n/app_zh.arb` / `app_zh_Hans.arb` / `app_en.arb` / `app_ja.arb` | UI 文案 | Add `progressFallbackHint`; rewrite `errorGachaFailed` |
| `lib/widgets/update_progress_dialog.dart` | 更新進度對話框 | Render fallback hint when `isFallback` |
| `lib/state/gacha_repository.dart` | 更新流程核心 | `_AllPoolsFailedException`; per-pool catch + branching; nested recapture in `_runUpdate`; `_runMitm(isFallback:)` |
| `test/state/gacha_repository_update_test.dart` | 行為驗收 | Rewrite 1 test, add 3 |

Order: model → l10n → dialog → repository (the repository references `WaitingForCapture(isFallback:)`, so the model must land first; l10n/dialog are independent and kept green at every commit).

---

## Task 1: Restore `WaitingForCapture.isFallback`

**Files:**
- Modify: `lib/state/update_progress.dart:16-20`

- [ ] **Step 1: Add the `isFallback` field**

Replace:

```dart
/// 等待 MITM 捕獲喚取憑證。
class WaitingForCapture extends UpdateProgress {
  /// 建立 [WaitingForCapture]。
  const WaitingForCapture();
}
```

with:

```dart
/// 等待 MITM 捕獲喚取憑證。
class WaitingForCapture extends UpdateProgress {
  /// 建立 [WaitingForCapture]；[isFallback] 表示 recordId 全池失效後的二次（fallback）捕獲。
  const WaitingForCapture({this.isFallback = false});

  /// true 表示 recordId 全池失效後的二次捕獲（UI 顯示重新攔取提示）。
  final bool isFallback;
}
```

- [ ] **Step 2: Verify analyze passes**

Run: `flutter analyze`
Expected: `No issues found!` (the new field is unused for now — Dart does not warn on unused public fields).

- [ ] **Step 3: Commit**

```bash
git add lib/state/update_progress.dart
git commit -m "feat(progress): restore WaitingForCapture.isFallback flag"
```

---

## Task 2: l10n — add `progressFallbackHint`, rewrite `errorGachaFailed`

**Files:**
- Modify: `lib/l10n/app_zh.arb` (add after `:140`, rewrite `:196`)
- Modify: `lib/l10n/app_zh_Hans.arb` (add after `:167`, rewrite `:258`)
- Modify: `lib/l10n/app_en.arb` (add after `:171`, rewrite `:262`)
- Modify: `lib/l10n/app_ja.arb` (add after `:171`, rewrite `:262`)

`progressFallbackHint` is a plain string with no placeholders, so no `@`-metadata block is needed (matches `progressOpenGameHint` / `errorGachaFailed`).

- [ ] **Step 1: `app_zh.arb` — add the fallback hint after `progressOpenGameHint`**

Replace:

```json
  "progressOpenGameHint": "請開啟鳴潮 → 喚取 → 喚取記錄",
```

with:

```json
  "progressOpenGameHint": "請開啟鳴潮 → 喚取 → 喚取記錄",
  "progressFallbackHint": "（先前的擷取已失效，請重新開啟喚取記錄頁攔取）",
```

- [ ] **Step 2: `app_zh.arb` — rewrite `errorGachaFailed`**

Replace:

```json
  "errorGachaFailed": "取得記錄失敗，請重開喚取記錄頁再試",
```

with:

```json
  "errorGachaFailed": "重新擷取後仍無法取得記錄，伺服器可能暫時異常，請稍後再試",
```

- [ ] **Step 3: `app_zh_Hans.arb` — add the fallback hint after `progressOpenGameHint`**

Replace:

```json
  "progressOpenGameHint": "请开启鸣潮 → 唤取 → 唤取记录",
```

with:

```json
  "progressOpenGameHint": "请开启鸣潮 → 唤取 → 唤取记录",
  "progressFallbackHint": "（先前的拦取已失效，请重新开启唤取记录页拦取）",
```

- [ ] **Step 4: `app_zh_Hans.arb` — rewrite `errorGachaFailed`**

Replace:

```json
  "errorGachaFailed": "获取记录失败，请重开唤取记录页再试",
```

with:

```json
  "errorGachaFailed": "重新拦取后仍无法获取记录，服务器可能暂时异常，请稍后再试",
```

- [ ] **Step 5: `app_en.arb` — add the fallback hint after `progressOpenGameHint`**

Replace:

```json
  "progressOpenGameHint": "Open Wuthering Waves → Convene → Convene History",
```

with:

```json
  "progressOpenGameHint": "Open Wuthering Waves → Convene → Convene History",
  "progressFallbackHint": "(The previous capture expired. Please reopen the Convene History page.)",
```

- [ ] **Step 6: `app_en.arb` — rewrite `errorGachaFailed`**

Replace:

```json
  "errorGachaFailed": "Failed to fetch records. Please reopen the Convene History page and try again.",
```

with:

```json
  "errorGachaFailed": "Still couldn't fetch records after re-capturing. The server may be temporarily unavailable — please try again later.",
```

- [ ] **Step 7: `app_ja.arb` — add the fallback hint after `progressOpenGameHint`**

Replace:

```json
  "progressOpenGameHint": "鳴潮 → 集音 → 集音履歴 を開いてください",
```

with:

```json
  "progressOpenGameHint": "鳴潮 → 集音 → 集音履歴 を開いてください",
  "progressFallbackHint": "（前回の取得が失効しました。集音履歴ページを開き直してください）",
```

- [ ] **Step 8: `app_ja.arb` — rewrite `errorGachaFailed`**

Replace:

```json
  "errorGachaFailed": "記録の取得に失敗しました。集音履歴ページを開き直して再試行してください。",
```

with:

```json
  "errorGachaFailed": "再取得しても記録を取得できませんでした。サーバーが一時的に不安定な可能性があります。しばらくしてから再試行してください。",
```

- [ ] **Step 9: Regenerate localizations and verify analyze**

Run: `flutter gen-l10n && flutter analyze`
Expected: gen-l10n succeeds (generates the `progressFallbackHint` getter); `flutter analyze` prints `No issues found!`.

- [ ] **Step 10: Commit**

```bash
git add lib/l10n/app_zh.arb lib/l10n/app_zh_Hans.arb lib/l10n/app_en.arb lib/l10n/app_ja.arb
git commit -m "i18n: add progressFallbackHint, rewrite errorGachaFailed for recapture flow"
```

---

## Task 3: Dialog — render fallback hint

**Files:**
- Modify: `lib/widgets/update_progress_dialog.dart:172-179`

`theme` is already in scope at the top of `_Body.build` (`final theme = Theme.of(context);` at `:148`).

- [ ] **Step 1: Render the hint when `isFallback`**

Replace:

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

with:

```dart
      WaitingForCapture(:final isFallback) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LinearProgressIndicator(),
          const SizedBox(height: AppSpacing.l),
          Text(l.progressOpenGameHint),
          if (isFallback) ...[
            const SizedBox(height: AppSpacing.s),
            Text(l.progressFallbackHint, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
```

- [ ] **Step 2: Verify analyze passes**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add lib/widgets/update_progress_dialog.dart
git commit -m "feat(dialog): show fallback recapture hint on WaitingForCapture"
```

---

## Task 4: Repository — three-way failure flow (TDD core)

**Files:**
- Test: `test/state/gacha_repository_update_test.dart` (rewrite 1 test `:112-159`, add 3)
- Modify: `lib/state/gacha_repository.dart` (`_AllPoolsFailedException` near `:30`; `_runMitm` `:289`; primary call `:236`; `_fetchAllBanners` `:303-409`; `_runUpdate` inner try `:244-279`)

### Tests first

- [ ] **Step 1: Rewrite the stale "aborts" test to assert partial-failure handling**

In `test/state/gacha_repository_update_test.dart`, replace the entire existing test block that starts with:

```dart
  test(
    'any pool code!=0 aborts with UpdateErrorGachaFailed (no recapture)',
    () async {
```

(through its closing `);` — the whole `:112-159` block) with:

```dart
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
        // pool 1 succeeds with a record, pool 2 fails, the rest succeed empty
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
      // all 8 pools attempted (did NOT abort at pool 2)
      expect(poolHits, 8);
      // pool 1's record was still saved despite pool 2 failing
      final state = container.read(gachaRepositoryProvider);
      expect(state.byUid['701000000']!.banners['1'], hasLength(1));
      // capture invoked once (primary), no recapture fallback
      expect(captureCalls, 1);
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
          '1': [], '2': [], '3': [], '4': [],
          '5': [], '6': [], '8': [], '9': [],
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
      // round 1 (hits 1-8): all fail; round 2 (hits 9+): pool 1 yields a record
      final String payload;
      if (hits <= 8) {
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
    final progress = container.read(gachaRepositoryProvider).progress;
    expect(progress, isA<UpdateCompleted>());
    expect((progress as UpdateCompleted).totalNewRecords, 1);
  });

  test('all pools fail → recapture → still all fail → UpdateFailed', () async {
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
          '1': [], '2': [], '3': [], '4': [],
          '5': [], '6': [], '8': [], '9': [],
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
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run: `flutter test test/state/gacha_repository_update_test.dart`
Expected: FAIL. The current repo aborts on the first `code != 0`, so `partial...` sees `UpdateFailed` (not `UpdateCompleted`), and the three new `all pools fail...` tests do not get a recapture. (Compilation succeeds — all referenced symbols already exist.)

### Implementation

- [ ] **Step 3: Add `_AllPoolsFailedException`**

In `lib/state/gacha_repository.dart`, immediately after the `_NoRecordsException` class (`:30-32`), add:

```dart
/// 8 個卡池**全部** `code != 0`（≈ recordId 失效或後端整體異常）。由 [_runUpdate]
/// 接住後自動重攔一次；重攔後仍全失敗才轉成 [UpdateErrorGachaFailed]。
class _AllPoolsFailedException implements Exception {
  /// 建立 [_AllPoolsFailedException]，[apiError] 為最後一個失敗池的 [GachaApiException]。
  const _AllPoolsFailedException(this.apiError);

  /// 觸發此訊號的最後一個池失敗資訊（供 log 與最終錯誤文案）。
  final GachaApiException apiError;
}
```

- [ ] **Step 4: Restore `isFallback` on `_runMitm` and its primary call site**

Replace the primary call (`:236`):

```dart
      cred ??= await _runMitm();
```

with:

```dart
      cred ??= await _runMitm(isFallback: false);
```

Then replace the `_runMitm` method (`:288-301`):

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

with:

```dart
  /// 啟動 MITM 捕獲會話並等候 [GachaCredential]；[isFallback] 為 recordId 全池失效後的二次捕獲。
  Future<GachaCredential?> _runMitm({required bool isFallback}) async {
    state = state.copyWith(progress: WaitingForCapture(isFallback: isFallback));
    final session = ref.read(gachaCaptureProvider).start();
    _activeCancel = session.cancel;
    _log.info('MITM ${isFallback ? "fallback" : "primary"} session started');
    try {
      final result = await session.result;
      _log.info('MITM session done, hasCredential=${result != null}');
      return result;
    } finally {
      _activeCancel = null;
    }
  }
```

- [ ] **Step 5: Make `_fetchAllBanners` per-pool fault-tolerant**

Replace the doc comment (`:303-306`):

```dart
  /// 依序拉取 8 個 cardPoolType 的整池全歷史，合併存檔。
  ///
  /// 任一池 `code!=0` → 直接 rethrow [GachaApiException]（由 [_runUpdate] 中止整次
  /// 更新並提示重開喚取記錄頁）；全部成功但每池皆空 → 丟 [_NoRecordsException]。
```

with:

```dart
  /// 依序拉取 8 個 cardPoolType 的整池全歷史，合併存檔。
  ///
  /// 逐池容錯：單池 `code!=0` 保留舊資料、記入 `failed` 後繼續（最終以
  /// `UpdateCompleted.failedBanners` 顯示部分失敗紅字）；**8 池全失敗** → 丟
  /// [_AllPoolsFailedException]（由 [_runUpdate] 自動重攔一次）；全部成功但每池皆空且
  /// 無既有資料 → 丟 [_NoRecordsException]。網路層 [http.ClientException] 不在此攔截。
```

Replace the accumulator declarations (`:327-329`):

```dart
    final mergedBanners = <String, List<GachaRecord>>{};
    var totalNew = 0;
    var anyNonEmpty = false;
```

with:

```dart
    final mergedBanners = <String, List<GachaRecord>>{};
    final failed = <String>[];
    GachaApiException? lastApiError;
    var totalNew = 0;
    var anyNonEmpty = false;
```

Replace the loop body + `_NoRecordsException` check (`:331-365`):

```dart
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
```

with:

```dart
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

      try {
        final result = await fetcher.fetchPool(
          endpoint: endpoint,
          cred: cred,
          cardPoolType: t.cardPoolType,
          client: client,
        );
        if (!ref.mounted) return;

        final existingForPool =
            existing.banners[t.key] ?? const <GachaRecord>[];
        final merged = mergeOrderedRecords(result.records, existingForPool);
        mergedBanners[t.key] = merged;
        if (merged.isNotEmpty) anyNonEmpty = true;
        totalNew += merged.length - existingForPool.length;
      } on GachaApiException catch (e) {
        // 單池 code!=0：保留舊資料、記入 failed，繼續抓其他池；全池皆失敗時於迴圈後
        // 轉成 _AllPoolsFailedException 觸發自動重攔。http.ClientException 不在此攔截，
        // 往上拋給 _runUpdate 當作網路層失敗。
        _log.warning('pool ${t.key} failed code=${e.code} msg=${e.message}');
        lastApiError = e;
        mergedBanners[t.key] = existing.banners[t.key] ?? const <GachaRecord>[];
        failed.add(t.nameKey);
      }
    }

    if (failed.length == gachaTypes.length) {
      throw _AllPoolsFailedException(lastApiError!);
    }
    if (failed.isEmpty &&
        !anyNonEmpty &&
        existing.banners.values.every((l) => l.isEmpty)) {
      throw const _NoRecordsException();
    }
```

Replace the `UpdateCompleted` emit (`:401-408`) — only the `failedBanners` line changes:

```dart
    state = state.copyWith(
      progress: UpdateCompleted(
        totalNewRecords: totalNew,
        failedBanners: const [],
        updatedAt: updatedAt,
        itemImagesDownloaded: itemImagesDownloaded,
      ),
    );
```

with:

```dart
    state = state.copyWith(
      progress: UpdateCompleted(
        totalNewRecords: totalNew,
        failedBanners: failed,
        updatedAt: updatedAt,
        itemImagesDownloaded: itemImagesDownloaded,
      ),
    );
```

- [ ] **Step 6: Wire the auto-recapture into `_runUpdate`**

Replace the inner try/catch (`:244-279`):

```dart
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
```

with:

```dart
      try {
        await _fetchAllBanners(
          cred: cred,
          fetcher: fetcher,
          storage: storage,
          client: cancellable.client,
        );
      } on _AllPoolsFailedException catch (e) {
        // 8 池全失敗（≈ recordId 失效）：比照原神 AuthExpired 流程自動重攔一次。
        if (!ref.mounted) return;
        _log.warning(
          'all pools failed (code=${e.apiError.code}), falling back to recapture',
        );
        final newCred = await _runMitm(isFallback: true);
        if (!ref.mounted) return;
        if (newCred == null) {
          _log.info('recapture cancelled by user');
          state = state.copyWith(clearProgress: true);
          return;
        }
        try {
          await _fetchAllBanners(
            cred: newCred,
            fetcher: fetcher,
            storage: storage,
            client: cancellable.client,
          );
        } on _AllPoolsFailedException catch (e2) {
          // 重攔後仍全失敗才放棄；文案已改為不再要求重開頁（errorGachaFailed）。
          if (!ref.mounted) return;
          _log.warning(
            'still all-failing after recapture, code=${e2.apiError.code}',
          );
          state = state.copyWith(
            progress: UpdateFailed(
              UpdateErrorGachaFailed(e2.apiError.code, e2.apiError.message),
            ),
          );
        } on _NoRecordsException {
          if (!ref.mounted) return;
          state = state.copyWith(
            progress: const UpdateFailed(UpdateErrorNoRecords()),
          );
        } on http.ClientException catch (e2) {
          if (!ref.mounted) return;
          if (_cancelTriggered) {
            state = state.copyWith(clearProgress: true);
          } else {
            _log.warning('http client error (post-recapture): ${e2.message}');
            state = state.copyWith(progress: UpdateFailed(_friendlyError(e2)));
          }
        } catch (e2, st) {
          if (!ref.mounted) return;
          _log.severe('update unexpected error (post-recapture)', e2, st);
          state = state.copyWith(progress: UpdateFailed(_friendlyError(e2)));
        }
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
```

- [ ] **Step 7: Run the update tests and verify they pass**

Run: `flutter test test/state/gacha_repository_update_test.dart`
Expected: PASS (all tests, including the 1 rewritten + 3 new).

- [ ] **Step 8: Format, analyze, full test suite**

Run: `dart format lib/ test/ && flutter analyze && flutter test`
Expected: formatter reports its changes (or none), `flutter analyze` prints `No issues found!`, `flutter test` prints `All tests passed!`.

- [ ] **Step 9: Commit**

```bash
git add lib/state/gacha_repository.dart test/state/gacha_repository_update_test.dart
git commit -m "fix(update): auto-recapture on full failure, keep partial pool failures non-fatal"
```

---

## Self-Review

**Spec coverage:**
- 三分流（部分失敗紅字 / 全掛自動重攔 / 網路失敗）→ Task 4 Step 5-6 ✅
- 全掛→重攔→仍失敗的新文案 `errorGachaFailed` → Task 2 ✅
- fallback 小字提示 `progressFallbackHint` + `isFallback` 欄位 + dialog 渲染 → Task 1 / 2 / 3 ✅
- `_NoRecordsException` 條件收緊（含 `failed` 為空）→ Task 4 Step 5 ✅
- 測試（改寫 1 + 新增 3）→ Task 4 Step 1 ✅
- 微決策 1（fallback 不刪快取憑證）→ 計畫未加任何 `deleteCapturedCredential` 呼叫，`all pools fail → recapture cancelled` 測試斷言 cred 仍保留 ✅
- 微決策 2（fallback 小灰字、紅字留給部分失敗）→ Task 3 用 `theme.textTheme.bodySmall`；紅字渲染（`stateDanger`）沿用既有 `failedBanners` 路徑 ✅
- 微決策 3（沿用 `UpdateErrorGachaFailed` 型別，改文案）→ Task 4 Step 6 不新增型別 ✅

**Type consistency:** `_AllPoolsFailedException(GachaApiException apiError)` 定義（Step 3）與用法 `e.apiError.code` / `e.apiError.message`（Step 6）一致；`_runMitm({required bool isFallback})`（Step 4）與兩個呼叫點（`isFallback: false` / `isFallback: true`）一致；`WaitingForCapture({this.isFallback})`（Task 1）與 dialog 解構 `WaitingForCapture(:final isFallback)`（Task 3）一致。

**Placeholder scan:** 無 TBD/TODO；每個 code step 都附完整程式碼與精確 before/after。

**Non-goals honored:** 不細分 code 語意、不加退避/重試設定、不動 `fetchPool` 對外行為、不動 import/forceRefetch/物品圖片流程。
