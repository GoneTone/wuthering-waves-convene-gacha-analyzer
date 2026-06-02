# 第一個卡池失敗即早退重攔 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 更新喚取資料時，第一個抓取的卡池（pool 0 = 角色活動）一失敗就立刻重新攔截 URL，不再乾等其餘 7 池全部失敗。

**Architecture:** 只改 `lib/state/gacha_repository.dart`：給 `_fetchAllBanners` 加一個 `abortOnFirstPoolFailure` 旗標，迴圈 catch 在「第一輪且 `i == 0`」時立刻丟既有的 `_AllPoolsFailedException` 早退，複用 `_runUpdate` 既有的「全池失敗 → 自動重攔 → 第二輪」骨架（第二輪傳 `false`，行為與現況逐字相同）。同步修正會「說謊」的 log 與 dartdoc，並調整／新增測試。

**Tech Stack:** Flutter、Dart 3、flutter_riverpod、`package:http` + `package:http/testing`（`MockClient`）、`flutter_test`。

**Spec:** [`docs/superpowers/specs/2026-06-05-first-pool-failure-early-recapture-design.md`](../specs/2026-06-05-first-pool-failure-early-recapture-design.md)

**前置：** 已在分支 `feat/first-pool-early-recapture`，spec 已提交（commit `2c1d089`）。

---

## File Structure

無新檔。

- **Modify** `lib/state/gacha_repository.dart`
  - `_AllPoolsFailedException`（約 36–44 行）：dartdoc 補上「早退」觸發來源。
  - `_fetchAllBanners`（約 367–449 行）：簽名加 `required bool abortOnFirstPoolFailure`、dartdoc 補說明、迴圈 catch 加早退分支。
  - `_runUpdate`（約 263–289 行）：第一輪呼叫傳 `true`、第二輪傳 `false`、第一輪 catch 的 log 改寫為不再宣稱「all」。
- **Modify** `test/state/gacha_repository_update_test.dart`
  - 修正 `all pools fail → recapture → success → UpdateCompleted`（約 172 行）的 mock（`hits <= 8` → `hits <= 1`）並補 `expect(hits, 9)`。
  - 新增 C1（pool 0 早退只抓 1 次）、C3（重攔後第二輪 pool 0 又失敗但他池成功）兩個測試。

---

## 背景重點（給零 context 的工程師）

- `gachaTypes` 順序為 `[1,2,3,4,5,6,8,9]`（見 `lib/data/gacha_types.dart`），所以迴圈 `i == 0` 永遠是 `cardPoolType == 1`（角色活動），即 **pool 0**。
- 喚取查詢的 `recordId` 是 8 池共用的同一個 token。過期時 8 池會一起 `code != 0`，所以 **pool 0 失敗 ≈ recordId 全域失效**；pool 0 成功就證明 recordId 有效。
- 測試 harness 用 fake capture class（`_FakeCapture`）＋ `MockClient` ＋ Riverpod provider override，`GachaFetcher(rateLimit: Duration.zero)` 讓 8 池間無延遲。要走「重攔」分支必須先 `storage.save(空 BannerStorage)` ＋ `storage.saveCapturedCredential(...)`，這樣第一輪用 cached cred、`captureCalls` 只計到 fallback 那一次。
- **絕不可**把「pool 0 早退」退化成「立刻 `UpdateFailed`」——早退必須走「全池失敗 → 自動重攔（不彈失敗框）」那條既有分流。

---

## Task 1：pool 0 早退重攔（production + 核心測試 + 修正既有測試）

**Files:**
- Test: `test/state/gacha_repository_update_test.dart`（新增 C1；修正約 172 行的既有測試）
- Modify: `lib/state/gacha_repository.dart`（例外 dartdoc、`_fetchAllBanners` 簽名/dartdoc/迴圈 catch、兩個呼叫點、第一輪 catch log）

- [ ] **Step 1：確認基線全綠**

先確認動工前測試是綠的（避免把既有失敗誤算到本次改動）。

Run:
```
flutter analyze
flutter test
```
Expected：`flutter analyze` 輸出 `No issues found!`；`flutter test` 輸出 `All tests passed!`。

- [ ] **Step 2：寫下會失敗的核心測試 C1**

在 `test/state/gacha_repository_update_test.dart` 中，於既有 `test('all pools fail → recapture → success → UpdateCompleted', ...)`（約 172 行）**之前**插入下列測試。它驗證「pool 0 失敗時，第一輪只發 1 次請求就早退重攔」。

```dart
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
      await storage.saveCapturedCredential(
        '701000000',
        _cred().toJsonString(),
      );
      var captureCalls = 0;
      var hits = 0;
      // 在 fallback 重攔啟動的瞬間記下 hits = 第一輪已發出的請求數。
      var round1Fetches = -1;
      final mock = MockClient((req) async {
        hits++;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final type = body['cardPoolType'] as int;
        // round 1：pool 0（hit 1）失敗 → 早退重攔；
        // round 2（hits 2-9）：完整 8 池，pool 1 給一筆紀錄。
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
      // 1 次早退 + 8 次第二輪
      expect(hits, 9);
      final progress = container.read(gachaRepositoryProvider).progress;
      expect(progress, isA<UpdateCompleted>());
      expect((progress as UpdateCompleted).totalNewRecords, 1);
      expect(progress.failedBanners, isEmpty);
    },
  );
```

- [ ] **Step 3：執行 C1，確認它失敗**

Run:
```
flutter test test/state/gacha_repository_update_test.dart --plain-name "round 1 aborts after a single fetch"
```
Expected：**FAIL**。現況無早退：第一輪不會重攔，`round1Fetches` 仍為 `-1`（≠ 1）、`captureCalls` 為 `0`（≠ 1）、`hits` 為 `8`（≠ 9）。

- [ ] **Step 4：更新 `_AllPoolsFailedException` 的 dartdoc**

在 `lib/state/gacha_repository.dart`，找到（約 36–43 行）：

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

改為：

```dart
/// recordId 疑似失效訊號，由 [_runUpdate] 接住後自動重攔一次；重攔後第二輪仍全失敗才轉成
/// [UpdateErrorGachaFailed]。兩個觸發來源：①第一輪首抓的角色活動（pool 0）失敗即早退
/// （recordId 為 8 池共用，pool 0 失敗 ≈ 全域失效）②第二輪跑滿 8 池且全部 `code != 0`。
class _AllPoolsFailedException implements Exception {
  /// 建立 [_AllPoolsFailedException]，[apiError] 為觸發訊號的失敗池 [GachaApiException]。
  const _AllPoolsFailedException(this.apiError);

  /// 觸發此訊號的失敗池資訊（早退時為 pool 0，全失敗時為最後一個失敗池；供 log 與錯誤文案）。
  final GachaApiException apiError;
}
```

- [ ] **Step 5：更新 `_fetchAllBanners` 的 dartdoc 與簽名**

找到（約 367–378 行）：

```dart
  /// 依序拉取 8 個 cardPoolType 的整池全歷史，合併存檔。
  ///
  /// 逐池容錯：單池 `code!=0` 保留舊資料、記入 `failed` 後繼續（最終以
  /// `UpdateCompleted.failedBanners` 顯示部分失敗紅字）；**8 池全失敗** → 丟
  /// [_AllPoolsFailedException]（由 [_runUpdate] 自動重攔一次）；全部成功但每池皆空且
  /// 無既有資料 → 丟 [_NoRecordsException]。網路層 [http.ClientException] 不在此攔截。
  Future<void> _fetchAllBanners({
    required GachaCredential cred,
    required GachaFetcher fetcher,
    required GachaStorage storage,
    required http.Client client,
  }) async {
```

改為：

```dart
  /// 依序拉取 8 個 cardPoolType 的整池全歷史，合併存檔。
  ///
  /// 逐池容錯：單池 `code!=0` 保留舊資料、記入 `failed` 後繼續（最終以
  /// `UpdateCompleted.failedBanners` 顯示部分失敗紅字）；**8 池全失敗** → 丟
  /// [_AllPoolsFailedException]（由 [_runUpdate] 自動重攔一次）；全部成功但每池皆空且
  /// 無既有資料 → 丟 [_NoRecordsException]。網路層 [http.ClientException] 不在此攔截。
  ///
  /// [abortOnFirstPoolFailure] 為 true（第一輪）時，首抓的角色活動（pool 0，`i == 0`）一
  /// 失敗就立刻丟 [_AllPoolsFailedException] 早退、不再續抓其餘 7 池（recordId 為 8 池共用，
  /// pool 0 失敗 ≈ 全域失效）；為 false（重攔後第二輪）時維持「跑滿全池、全失敗才判定」的容錯。
  Future<void> _fetchAllBanners({
    required GachaCredential cred,
    required GachaFetcher fetcher,
    required GachaStorage storage,
    required http.Client client,
    required bool abortOnFirstPoolFailure,
  }) async {
```

- [ ] **Step 6：在迴圈 catch 加早退分支**

找到（約 429–437 行）：

```dart
      } on GachaApiException catch (e) {
        // 單池 code!=0：保留舊資料、記入 failed，繼續抓其他池；全池皆失敗時於迴圈後
        // 轉成 _AllPoolsFailedException 觸發自動重攔。http.ClientException 不在此攔截，
        // 往上拋給 _runUpdate 當作網路層失敗。
        _log.warning('pool ${t.key} failed code=${e.code} msg=${e.message}');
        lastApiError = e;
        mergedBanners[t.key] = existing.banners[t.key] ?? const <GachaRecord>[];
        failed.add(t.nameKey);
      }
```

改為：

```dart
      } on GachaApiException catch (e) {
        // 第一輪：首抓的角色活動（pool 0）失敗 ≈ 8 池共用的 recordId 失效。不續抓其餘 7
        // 池，直接丟全池失效訊號交由 _runUpdate 自動重攔。
        if (abortOnFirstPoolFailure && i == 0) {
          _log.warning(
            'first pool ${t.key} failed code=${e.code} msg=${e.message}, '
            'aborting to recapture',
          );
          throw _AllPoolsFailedException(e);
        }
        // 單池 code!=0：保留舊資料、記入 failed，繼續抓其他池；全池皆失敗時於迴圈後
        // 轉成 _AllPoolsFailedException 觸發自動重攔。http.ClientException 不在此攔截，
        // 往上拋給 _runUpdate 當作網路層失敗。
        _log.warning('pool ${t.key} failed code=${e.code} msg=${e.message}');
        lastApiError = e;
        mergedBanners[t.key] = existing.banners[t.key] ?? const <GachaRecord>[];
        failed.add(t.nameKey);
      }
```

- [ ] **Step 7：第一輪呼叫傳 `abortOnFirstPoolFailure: true`，並改寫第一輪 catch 的 log**

找到（約 263–275 行）：

```dart
      try {
        await _fetchAllBanners(
          cred: cred,
          fetcher: fetcher,
          storage: storage,
          client: cancellable.client,
        );
      } on _AllPoolsFailedException catch (e) {
        // 8 池全失敗（≈ recordId 失效）：沿用既有 recordId 失效流程自動重攔一次。
        if (!ref.mounted) return;
        _log.warning(
          'all pools failed (code=${e.apiError.code}), falling back to recapture',
        );
```

改為：

```dart
      try {
        await _fetchAllBanners(
          cred: cred,
          fetcher: fetcher,
          storage: storage,
          client: cancellable.client,
          abortOnFirstPoolFailure: true,
        );
      } on _AllPoolsFailedException catch (e) {
        // 第一輪 pool 0 失敗（≈ recordId 失效）：沿用既有 recordId 失效流程自動重攔一次。
        if (!ref.mounted) return;
        _log.warning(
          'first pool failed (code=${e.apiError.code}), falling back to recapture',
        );
```

> 改動後第一輪的 `_AllPoolsFailedException` 必然來自 pool 0 早退（pool 0 成功就不會早退，而 pool 0 成功時收尾的 `failed.length == gachaTypes.length` 不可能成立），故這裡的 log 不再宣稱「all」。

- [ ] **Step 8：重攔後第二輪呼叫傳 `abortOnFirstPoolFailure: false`**

找到（約 283–289 行，注意此處是 `cred: newCred`）：

```dart
        try {
          await _fetchAllBanners(
            cred: newCred,
            fetcher: fetcher,
            storage: storage,
            client: cancellable.client,
          );
```

改為：

```dart
        try {
          await _fetchAllBanners(
            cred: newCred,
            fetcher: fetcher,
            storage: storage,
            client: cancellable.client,
            abortOnFirstPoolFailure: false,
          );
```

- [ ] **Step 9：執行 C1，確認它通過**

Run:
```
flutter test test/state/gacha_repository_update_test.dart --plain-name "round 1 aborts after a single fetch"
```
Expected：**PASS**（`round1Fetches == 1`、`captureCalls == 1`、`hits == 9`、`UpdateCompleted` 且 `totalNewRecords == 1`、`failedBanners` 為空）。

> 注意：此時既有測試 `all pools fail → recapture → success → UpdateCompleted`（約 172 行）會 **暫時變紅**（它仍假設第一輪打滿 8 池），下一步修正。

- [ ] **Step 10：修正既有測試 `all pools fail → recapture → success → UpdateCompleted` 的 mock**

在 `test/state/gacha_repository_update_test.dart` 找到（約 194–212 行）：

```dart
    // 假設 round 1 會把 8 池都打過一輪才觸發重攔（迴圈不因成功提早結束）：前 8 個 hit
    // 視為過期全失敗，第 9 個 hit 起為重攔後新 cred 的成功回應。
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
```

改為：

```dart
    // round 1 的 pool 0（首抓角色活動）一失敗就早退重攔：第 1 個 hit 視為過期失敗，第 2
    // 個 hit 起為重攔後新 cred 的成功回應（完整 8 池）。
    final mock = MockClient((req) async {
      hits++;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final type = body['cardPoolType'] as int;
      // round 1 (hit 1): pool 0 fails → early abort; round 2 (hits 2-9): pool 1 yields a record
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
```

- [ ] **Step 11：在同一個測試補上 `hits` 斷言**

在同一個測試找到（約 235–237 行）：

```dart
    // cached cred used for round 1 (no primary capture); only the fallback captured
    expect(captureCalls, 1);
    final progress = container.read(gachaRepositoryProvider).progress;
```

改為：

```dart
    // cached cred used for round 1 (no primary capture); only the fallback captured
    expect(captureCalls, 1);
    // round 1 aborted after a single fetch (pool 0); round 2 fetched all 8 pools
    expect(hits, 9);
    final progress = container.read(gachaRepositoryProvider).progress;
```

- [ ] **Step 12：跑完整測試與靜態分析、格式化**

Run:
```
dart format lib/ test/
flutter analyze
flutter test
```
Expected：`dart format` 不報錯；`flutter analyze` 輸出 `No issues found!`；`flutter test` 輸出 `All tests passed!`。

> 若 `all pools fail → recapture → still all fail → UpdateFailed`（約 243 行）或 `... cancelled → clears progress`（約 300 行）有問題，請檢查：它們的 mock 對所有請求一律回 `_fail(-1)`、不依賴 hit 數，行為應仍正確（第一輪 pool 0 失敗早退 → 重攔 → 第二輪 8 池全失敗 → 各自的預期結果），不需修改。

- [ ] **Step 13：Commit**

```
git add lib/state/gacha_repository.dart test/state/gacha_repository_update_test.dart
git commit -m "feat(gacha): recapture immediately when the first convene pool fails

Abort the convene update loop as soon as pool 0 (the character banner,
fetched first) returns code != 0, throwing _AllPoolsFailedException early
to trigger the existing recapture path, instead of waiting for all 8
pools to fail. Because recordId is shared across all pools, a pool 0
failure already implies it is invalid. The post-recapture second round
keeps the original 'all pools failed' semantics (abortOnFirstPoolFailure
false). Update the now-misleading 'all pools failed' log and dartdocs,
and adjust the affected test plus add coverage for the early abort.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2：補上「重攔後第二輪 pool 0 又失敗但他池成功」的迴歸測試（C3）

驗證第二輪 `abortOnFirstPoolFailure: false` 下，pool 0 失敗只記 `failed`、不再早退、也不會觸發第三輪重攔。此行為已由 Task 1 的 production 實作，本測試為迴歸鎖。

**Files:**
- Test: `test/state/gacha_repository_update_test.dart`（新增 C3）

- [ ] **Step 1：寫下 C3 測試**

在 `test/state/gacha_repository_update_test.dart` 中，於 `all pools fail → recapture → still all fail → UpdateFailed`（約 243 行）**之前**插入：

```dart
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
      await storage.saveCapturedCredential(
        '701000000',
        _cred().toJsonString(),
      );
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
          // round 2（hits 2-9）：pool 0（type 1）仍失敗，pool 2（type 2）給一筆，其餘空
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
      // 1 次早退 + 8 次第二輪
      expect(hits, 9);
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
```

- [ ] **Step 2：執行 C3，確認它通過**

Run:
```
flutter test test/state/gacha_repository_update_test.dart --plain-name "pool 0 fails again but others succeed"
```
Expected：**PASS**（行為已由 Task 1 實作；本測試鎖住第二輪不早退、不觸發第三輪）。

- [ ] **Step 3：跑完整測試與靜態分析、格式化**

Run:
```
dart format lib/ test/
flutter analyze
flutter test
```
Expected：`flutter analyze` 輸出 `No issues found!`；`flutter test` 輸出 `All tests passed!`。

- [ ] **Step 4：Commit**

```
git add test/state/gacha_repository_update_test.dart
git commit -m "test(gacha): cover round-2 first-pool failure after recapture

Lock in that the post-recapture second round does not early-abort on a
pool 0 failure (abortOnFirstPoolFailure false): pool 0 is recorded as a
failed banner while the other pools still save, and no third recapture
is triggered.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review（撰寫者自查，已完成）

**Spec 覆蓋：**
- 加 `abortOnFirstPoolFailure` 旗標 → Task 1 Step 5。
- pool 0 早退分支 → Task 1 Step 6。
- 兩個呼叫點各傳旗標 → Task 1 Step 7、Step 8。
- log 區分早退 vs 全失敗 → Task 1 Step 6（早退 log）＋ Step 7（第一輪 catch log 改寫）。
- dartdoc/註解更新 → Task 1 Step 4、Step 5、Step 6。
- 必改測試（172 行 `hits <= 8` → `hits <= 1` ＋ `hits` 斷言）→ Task 1 Step 10、Step 11。
- 新增 C1 → Task 1 Step 2；新增 C3 → Task 2 Step 1。
- 驗收（format/analyze/test 全綠）→ Task 1 Step 12、Task 2 Step 3。

**Placeholder 掃描：** 無 TBD/TODO；每個 code step 皆附完整 old→new 程式碼與確切指令。

**型別/命名一致性：** 參數名 `abortOnFirstPoolFailure` 在簽名、兩個呼叫點、迴圈 catch 一致；例外型別 `_AllPoolsFailedException` 沿用；測試 helper（`_ok`/`_fail`/`_row`/`_cred`/`_FakeCapture`）皆為現有檔案既有定義，未引入未定義符號。

**範圍：** 聚焦單一資料流改動，無跨子系統，適合單一 plan。
