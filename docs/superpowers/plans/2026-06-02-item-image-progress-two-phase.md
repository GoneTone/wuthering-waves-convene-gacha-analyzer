# 物品圖片補抓進度兩階段 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把物品圖片補抓階段的進度從「單階段、全程稱『下載』」改成「取得物品資料 → 下載」兩階段，讓「下載 {total}」反映真正要下載的張數，不再誤導。

**Architecture:** 進度模型 `FetchingItemImages` 增加 `ItemImagePhase`（checking / downloading）；`_fetchItemImages` 由一輪 `runConcurrent`（查+下混做）拆成兩輪——先逐一查官方有無圖並收集待下載清單，再只對確認有圖者下載 icon；UI 依 phase 切換文案。

**Tech Stack:** Flutter、Riverpod（Notifier）、flutter l10n（ARB → generated）、現有 `runConcurrent` 並發 helper。

設計來源：`docs/superpowers/specs/2026-06-02-item-image-progress-two-phase-design.md`

---

## File Structure

- `lib/l10n/app_{zh,zh_Hans,en,ja}.arb` — 新增「取得物品資料」進度文案 key。
- `lib/state/update_progress.dart` — 新增 `ItemImagePhase` enum；`FetchingItemImages` 加 `phase` 欄位。
- `lib/widgets/update_progress_dialog.dart` — `_Body` 的 `FetchingItemImages` 分支依 `phase` 切文案。
- `lib/state/gacha_repository.dart` — `_fetchItemImages` 拆兩階段。
- `test/state/gacha_repository_item_image_test.dart` — 新增兩階段進度斷言測試。

任務順序：Task 1（ARB，獨立）→ Task 2（引入 phase 欄位，行為不變、零回歸）→ Task 3（TDD 拆兩階段）。

---

## Task 1: 新增「取得物品資料」ARB 文案（四語）

**Files:**
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_zh_Hans.arb`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_ja.arb`

- [ ] **Step 1: 四語各新增 `updateProgressItemFetchingData`**

在每個檔案的 `"updateProgressItemDownloading"` 之 `@`-metadata block（結尾 `},`）**後面**插入對應片段。

`lib/l10n/app_zh.arb`：

```json
  "updateProgressItemFetchingData": "取得物品資料 {done}/{total}",
  "@updateProgressItemFetchingData": {
    "placeholders": {
      "done": { "type": "int" },
      "total": { "type": "int" }
    }
  },
```

`lib/l10n/app_zh_Hans.arb`：

```json
  "updateProgressItemFetchingData": "获取物品数据 {done}/{total}",
  "@updateProgressItemFetchingData": {
    "placeholders": {
      "done": {
        "type": "int"
      },
      "total": {
        "type": "int"
      }
    }
  },
```

`lib/l10n/app_en.arb`：

```json
  "updateProgressItemFetchingData": "Fetching item data {done}/{total}",
  "@updateProgressItemFetchingData": {
    "placeholders": {
      "done": {
        "type": "int"
      },
      "total": {
        "type": "int"
      }
    }
  },
```

`lib/l10n/app_ja.arb`：

```json
  "updateProgressItemFetchingData": "アイテムデータを取得中 {done}/{total}",
  "@updateProgressItemFetchingData": {
    "placeholders": {
      "done": {
        "type": "int"
      },
      "total": {
        "type": "int"
      }
    }
  },
```

- [ ] **Step 2: 重新產生 l10n**

Run: `flutter gen-l10n`
Expected: 無錯誤；`lib/l10n/generated/app_localizations*.dart` 重新產生。

- [ ] **Step 3: 驗證 generated 出現新 getter**

Run: `grep -rn "updateProgressItemFetchingData" lib/l10n/generated/app_localizations.dart`
Expected: 找到 `String updateProgressItemFetchingData(int done, int total);` 之類的宣告。

- [ ] **Step 4: 靜態分析**

Run: `flutter analyze`
Expected: `No issues found!`（新增字串尚未被引用也不會有錯，generated 為 part）。

- [ ] **Step 5: Commit**

```bash
git add lib/l10n/
git commit -m "i18n(progress): add item-data fetching progress string"
```

---

## Task 2: 進度模型引入 `ItemImagePhase`（行為不變）

引入 phase 欄位並讓 UI 具備依 phase 切文案的能力；`_fetchItemImages` 現有的單一 emit 暫時固定為 `ItemImagePhase.downloading`，**行為與現狀完全相同、零回歸**。真正的兩階段邏輯在 Task 3。

**Files:**
- Modify: `lib/state/update_progress.dart:105-115`
- Modify: `lib/widgets/update_progress_dialog.dart:199-208`
- Modify: `lib/state/gacha_repository.dart`（`_fetchItemImages` 內唯一的 `FetchingItemImages(...)` emit）

- [ ] **Step 1: 改進度模型**

把 `lib/state/update_progress.dart` 中 `FetchingItemImages` 整段（含其上方 dartdoc，目前約 105-115 行）替換為：

```dart
/// 物品圖片補抓的子步驟。
enum ItemImagePhase {
  /// 查詢各物品在官方是否有圖、寫入 index（取得物品資料階段）。
  checking,

  /// 下載已確認有圖的 icon 檔（下載階段）。
  downloading,
}

/// 主資料抓取完成後，正在補齊各物品的角色圖片。
class FetchingItemImages extends UpdateProgress {
  /// 建立 [FetchingItemImages]。
  const FetchingItemImages({
    required this.phase,
    required this.doneCount,
    required this.totalCount,
  });

  /// 目前所在的子步驟。
  final ItemImagePhase phase;

  /// 目前已完成的工作項數。
  final int doneCount;

  /// 本次需補圖的總工作項數。
  final int totalCount;
}
```

- [ ] **Step 2: UI 依 phase 切文案**

把 `lib/widgets/update_progress_dialog.dart` `_Body` 內的 `FetchingItemImages` 分支（目前約 199-208 行）：

```dart
      FetchingItemImages(:final doneCount, :final totalCount) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: totalCount == 0 ? null : doneCount / totalCount,
          ),
          const SizedBox(height: AppSpacing.l),
          Text(l.updateProgressItemDownloading(doneCount, totalCount)),
        ],
      ),
```

替換為：

```dart
      FetchingItemImages(:final phase, :final doneCount, :final totalCount) =>
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: totalCount == 0 ? null : doneCount / totalCount,
            ),
            const SizedBox(height: AppSpacing.l),
            Text(switch (phase) {
              ItemImagePhase.checking => l.updateProgressItemFetchingData(
                doneCount,
                totalCount,
              ),
              ItemImagePhase.downloading => l.updateProgressItemDownloading(
                doneCount,
                totalCount,
              ),
            }),
          ],
        ),
```

（`_Title` 與 actions 內的 `FetchingItemImages()` pattern 不解構欄位，無需改動。）

- [ ] **Step 3: repository emit 暫填 phase**

把 `lib/state/gacha_repository.dart` `_fetchItemImages` 內唯一的 emit：

```dart
        state = state.copyWith(
          progress: FetchingItemImages(
            doneCount: done,
            totalCount: worklist.length,
          ),
        );
```

替換為：

```dart
        state = state.copyWith(
          progress: FetchingItemImages(
            phase: ItemImagePhase.downloading,
            doneCount: done,
            totalCount: worklist.length,
          ),
        );
```

- [ ] **Step 4: 格式化 + 分析 + 測試（驗證零回歸）**

Run: `dart format lib/ test/ && flutter analyze && flutter test`
Expected: `No issues found!` 與 `All tests passed!`（行為未變，既有圖片測試與全部測試仍綠）。

- [ ] **Step 5: Commit**

```bash
git add lib/state/update_progress.dart lib/widgets/update_progress_dialog.dart lib/state/gacha_repository.dart
git commit -m "refactor(progress): add ItemImagePhase to FetchingItemImages (no behavior change)"
```

---

## Task 3: `_fetchItemImages` 拆成兩階段（TDD）

**Files:**
- Test: `test/state/gacha_repository_item_image_test.dart`
- Modify: `lib/state/gacha_repository.dart`（`_fetchItemImages` 整個 method）

- [ ] **Step 1: 寫 failing test**

在 `test/state/gacha_repository_item_image_test.dart` 檔首的 import 區，補一行：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/state/update_progress.dart';
```

在 `main()` 內最後一個 `test(...)` 之後、`}` 之前，新增兩個案例：

```dart
  test('進度分兩階段：取得物品資料 total=待查數、下載 total=有圖數', () async {
    // 1211 正取（角色），21010024 / 21040084 查無圖（負取）。
    final container = build(characters: {1211});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [
            _rec(1211, 5, '角色'),
            _rec(21010024, 4, '武器'),
            _rec(21040084, 4, '道具'),
          ],
        },
      ),
    );

    final seen = <(ItemImagePhase, int, int)>[];
    container.listen(gachaRepositoryProvider, (prev, next) {
      final p = next.progress;
      if (p is FetchingItemImages) {
        seen.add((p.phase, p.doneCount, p.totalCount));
      }
    });

    await repo.debugRunItemImagesOnly();

    final checking = seen.where((e) => e.$1 == ItemImagePhase.checking);
    final downloading = seen.where((e) => e.$1 == ItemImagePhase.downloading);
    expect(checking, isNotEmpty);
    expect(downloading, isNotEmpty);
    // 取得物品資料階段：待查 3 個物品。
    expect(checking.map((e) => e.$3).toSet(), {3});
    // 下載階段：只有 1 張真正要下載。
    expect(downloading.map((e) => e.$3).toSet(), {1});
  });

  test('全查無圖：只有取得物品資料階段，無下載階段', () async {
    final container = build(characters: <int>{}); // 全部查無圖
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [_rec(21010024, 4, '武器'), _rec(21040084, 4, '道具')],
        },
      ),
    );

    final phases = <ItemImagePhase>[];
    container.listen(gachaRepositoryProvider, (prev, next) {
      final p = next.progress;
      if (p is FetchingItemImages) phases.add(p.phase);
    });

    await repo.debugRunItemImagesOnly();

    expect(phases, contains(ItemImagePhase.checking));
    expect(phases, isNot(contains(ItemImagePhase.downloading)));
  });
```

- [ ] **Step 2: Run，確認 fail**

Run: `flutter test test/state/gacha_repository_item_image_test.dart --plain-name "進度分兩階段"`
Expected: FAIL。目前是單階段（Task 2 後固定 emit `downloading`、`totalCount = worklist.length = 3`），所以 `checking` 為空、且 `downloading` 的 total 是 3 而非 1。

- [ ] **Step 3: 重構 `_fetchItemImages` 為兩階段**

把 `lib/state/gacha_repository.dart` 的整個 `_fetchItemImages` method 替換為：

```dart
  Future<int> _fetchItemImages(http.Client client) async {
    var downloaded = 0;
    final fetcher = ref.read(itemImageFetcherProvider);
    final indexNotifier = ref.read(itemImageIndexProvider.notifier);
    final cacheDir = ref.read(itemImageCacheDirProvider);
    await indexNotifier.waitForLoad();

    // (1) 逐帳號收集 (resourceId, languageCode)；同 id 取首見 languageCode。
    final langByResourceId = <int, String>{};
    for (final data in state.byUid.values) {
      final lang = data.languageCode;
      if (lang.isEmpty) continue;
      for (final list in data.banners.values) {
        for (final r in list) {
          langByResourceId.putIfAbsent(r.resourceId, () => lang);
        }
      }
    }

    // (2) worklist：未抓 or 負取非永久。
    final index = ref.read(itemImageIndexProvider);
    final worklist = <(int resourceId, String lang)>[];
    for (final entry in langByResourceId.entries) {
      final existing = index.lookupImage(entry.key);
      final needFetch =
          existing == null || (existing.noImage && !existing.permanentNoImage);
      if (needFetch) worklist.add((entry.key, entry.value));
    }
    if (worklist.isEmpty) return downloaded;

    bool isAborted() => !ref.mounted || _cancelTriggered;

    // (3) 取得物品資料階段：逐一查官方有無圖、寫 index，收集待下載 icon。
    final toDownload = <(int resourceId, String iconUrl)>[];
    var checkedDone = 0;
    await runConcurrent<(int, String)>(
      items: worklist,
      concurrency: fetcher.downloadConcurrency,
      shouldAbort: isAborted,
      worker: (item) async {
        final resourceId = item.$1;
        final lang = item.$2;
        try {
          final urls = await fetcher.fetchItemImages(
            resourceId: resourceId,
            languageCode: lang,
            client: client,
          );
          if (urls == null) {
            // 負取（非永久）：官方後補圖會在下次更新由負取翻成正取。
            await indexNotifier.mergeItemImage(
              resourceId: resourceId,
              iconUrl: null,
              illustrationUrl: null,
              noImage: true,
              permanentNoImage: false,
            );
          } else {
            await indexNotifier.mergeItemImage(
              resourceId: resourceId,
              iconUrl: urls.iconUrl,
              illustrationUrl: urls.illustrationUrl,
              noImage: false,
              permanentNoImage: false,
            );
            toDownload.add((resourceId, urls.iconUrl));
          }
        } catch (e) {
          _log.warning('item image fetch failed resourceId=$resourceId err=$e');
        }
        if (!ref.mounted) return;
        checkedDone++;
        state = state.copyWith(
          progress: FetchingItemImages(
            phase: ItemImagePhase.checking,
            doneCount: checkedDone,
            totalCount: worklist.length,
          ),
        );
      },
    );

    // (4) 下載階段：只對確認有圖者下載 icon。icon 列表常駐 → 立即下載；
    // illustration 大圖只在詳情用，走 lazy（不在此預下載）。
    if (toDownload.isEmpty) return downloaded;
    var downloadedDone = 0;
    await runConcurrent<(int, String)>(
      items: toDownload,
      concurrency: fetcher.downloadConcurrency,
      shouldAbort: isAborted,
      worker: (item) async {
        final resourceId = item.$1;
        final iconUrl = item.$2;
        try {
          final iconBytes = await fetcher.downloadImage(iconUrl, client);
          if (iconBytes != null) {
            final file = itemIconCacheFile(
              baseDir: cacheDir,
              resourceId: resourceId,
              url: iconUrl,
            );
            await file.writeAsBytes(iconBytes, flush: true);
            indexNotifier.bumpCacheRevision();
            downloaded++;
          }
        } catch (e) {
          _log.warning(
            'item icon download failed resourceId=$resourceId err=$e',
          );
        }
        if (!ref.mounted) return;
        downloadedDone++;
        state = state.copyWith(
          progress: FetchingItemImages(
            phase: ItemImagePhase.downloading,
            doneCount: downloadedDone,
            totalCount: toDownload.length,
          ),
        );
      },
    );
    return downloaded;
  }
```

- [ ] **Step 4: Run 新測試，確認 pass**

Run: `flutter test test/state/gacha_repository_item_image_test.dart`
Expected: PASS（含新增的兩個案例與原有三個案例）。

- [ ] **Step 5: 全套品質檢查**

Run: `dart format lib/ test/ && flutter analyze && flutter test`
Expected: `No issues found!` 與 `All tests passed!`。

- [ ] **Step 6: Commit**

```bash
git add lib/state/gacha_repository.dart test/state/gacha_repository_item_image_test.dart
git commit -m "feat(progress): split item-image stage into fetch-data then download"
```

---

## Self-Review 紀錄

- **Spec 覆蓋**：進度模型（Task 2）、兩階段邏輯（Task 3）、UI 依 phase 切文案（Task 2）、ARB 四語（Task 1）、完成摘要不變（未動 `UpdateCompleted` / `progressDoneImagesSummary`）、worklist 全空整段不顯示（Task 3 保留 `if (worklist.isEmpty) return`）、三個入口共用 `_fetchItemImages`（未改其呼叫端）、測試（Task 3）——皆有對應。
- **Type consistency**：`ItemImagePhase { checking, downloading }`、`FetchingItemImages({phase, doneCount, totalCount})`、`updateProgressItemFetchingData(int done, int total)` 在 Task 1-3 一致；`runConcurrent<T>({items, concurrency, shouldAbort, worker})`、`fetcher.fetchItemImages` / `downloadImage` / `downloadConcurrency`、`itemIconCacheFile({baseDir, resourceId, url})`、`indexNotifier.mergeItemImage` / `bumpCacheRevision` 均沿用現有簽名。
- **No placeholders**：每步皆含完整程式碼與確切指令。
