# 物品圖片補抓進度：拆成「取得物品資料 → 下載」兩階段

- 日期：2026-06-02
- 分支：feat/wuwa-migration
- 狀態：設計定稿，待 review

## 背景與問題

更新流程最後有個物品圖片補抓階段（`GachaRepository._fetchItemImages`，`lib/state/gacha_repository.dart`）。它對每個「尚未抓過圖的 resourceId」去官方 API 查一次有沒有圖：查到有圖才下載 icon，查到沒圖記成負取，查詢失敗則略過。

問題在於進度呈現會誤導使用者：

- 進度文案固定是「下載物品圖片 {done}/{total}」（`updateProgressItemDownloading`），但 `{done}` 是**已處理數**，把「查到沒圖（負取）」「查詢失敗」也一併計入，**不是實際下載數**；`{total}` 是「要查詢的物品數」，不是「要下載的圖片數」。
- 完成摘要「下載 {N} 張物品圖片」（`progressDoneImagesSummary`）的 `{N}` 才是**真正寫入磁碟的張數**。
- 於是會出現「進度條跑到 100/100、文字一路寫『下載物品圖片』，完成卻說『下載 3 張』」的落差——看起來像下載了一大堆，實際多數只是在查詢有沒有新圖。

本質上這是一個「查詢 / 同步」階段，卻全程用「下載」的字眼與數字呈現。

## 目標

把物品圖片補抓階段的進度，從「單階段（查 + 下混做，全程稱『下載』）」改成「**取得物品資料 → 下載**」兩階段，對齊原神版本的 UX（原神為 HoYoWiki 三段：搜尋物品資料 → 抓取物品詳情 → 下載物品圖片；「下載」字樣只在真正下載圖檔那段出現）。鳴潮官方 API 一步即取得圖片 url，無 HoYoWiki 的兩步查詢，因此對應到**兩段**：

- **取得物品資料階段**：逐一查官方各物品有沒有圖，寫入 index（正取 / 負取），並收集「確認有 icon 要下載的」清單。進度文案「取得物品資料 {done}/{total}」，`{total}` = 待查物品數。
- **下載階段**：只對「已確認有圖的」下載 icon 寫檔。進度文案沿用「下載物品圖片 {done}/{total}」，`{total}` = **真正要下載的張數**。檢查後沒有任何新圖時，這段直接跳過。

完成摘要「下載 {N} 張物品圖片」維持不變：`{N}` 是下載成功寫檔的張數，與下載階段的 `{total}`（嘗試下載 = 確認有圖的張數）同屬「下載」語意；下載全成功時兩者相等，個別 `downloadImage` 失敗時 `{N}` 會略小於 `{total}`。

## 設計

### 1. 進度模型（`lib/state/update_progress.dart`）

新增子步驟 enum，並讓 `FetchingItemImages` 帶上 phase：

```dart
/// 物品圖片補抓的子步驟。
enum ItemImagePhase {
  /// 查詢各物品在官方是否有圖，並寫入 index（取得物品資料階段）。
  checking,

  /// 下載已確認有圖的 icon 檔（下載階段）。
  downloading,
}

/// 主資料抓取完成後，正在補齊各物品圖片。
class FetchingItemImages extends UpdateProgress {
  const FetchingItemImages({
    required this.phase,
    required this.doneCount,
    required this.totalCount,
  });

  /// 目前所在的子步驟。
  final ItemImagePhase phase;

  /// 該子步驟目前已完成的工作項數。
  final int doneCount;

  /// 該子步驟的總工作項數。
  final int totalCount;
}
```

對齊原神 `FetchingHoYoWiki`（`HoYoWikiPhase` + doneCount + totalCount）的結構。

### 2. 抓圖邏輯（`lib/state/gacha_repository.dart` `_fetchItemImages`）

維持「worklist = 未抓 or 負取非永久」的計算（現況 L800-821）不變；worklist 為空時仍直接 `return 0`（整段不顯示）。worklist 非空時，把原本「單一 worker 查 + 下混做」拆成**兩輪 `runConcurrent`**：

**取得物品資料階段（checking）**

```text
toDownload = []   // List<(int resourceId, String iconUrl)>
done = 0
runConcurrent(items: worklist, concurrency: fetcher.downloadConcurrency, shouldAbort: isAborted):
  worker(resourceId, lang):
    urls = fetcher.fetchItemImages(resourceId, lang, client)
    if urls == null:
      indexNotifier.mergeItemImage(resourceId, iconUrl: null, illustrationUrl: null,
                                   noImage: true, permanentNoImage: false)   // 負取
    else:
      indexNotifier.mergeItemImage(resourceId, iconUrl: urls.iconUrl,
                                   illustrationUrl: urls.illustrationUrl,
                                   noImage: false, permanentNoImage: false)   // 正取
      toDownload.add((resourceId, urls.iconUrl))
    // 查詢失敗（例外）：warn-log，照舊略過（不寫 index、不加 toDownload）
    done++
    state = FetchingItemImages(phase: checking, doneCount: done, totalCount: worklist.length)
```

**下載階段（downloading）**

```text
if toDownload.isEmpty: return downloaded   // 沒有新圖，跳過下載段
done = 0
runConcurrent(items: toDownload, concurrency: fetcher.downloadConcurrency, shouldAbort: isAborted):
  worker(resourceId, iconUrl):
    iconBytes = fetcher.downloadImage(iconUrl, client)
    if iconBytes != null:
      file = itemIconCacheFile(baseDir: cacheDir, resourceId: resourceId, url: iconUrl)
      file.writeAsBytes(iconBytes, flush: true)
      indexNotifier.bumpCacheRevision()
      downloaded++
    done++
    state = FetchingItemImages(phase: downloading, doneCount: done, totalCount: toDownload.length)
return downloaded
```

- 並發、取消（`isAborted = !ref.mounted || _cancelTriggered`）、負取 / 正取的 index 寫法、icon 快取檔路徑、`downloaded` 計數語意、illustration 走 lazy（此階段不預下載大圖）——全部維持現況，只是把「查」與「下」拆到兩輪迴圈、各自 emit 對應 phase 的進度。
- 三個入口（正常更新 `_fetchAllBanners`、強制重抓 `forceRefetchAllItemImages`、匯入後補圖 `importAccountsAndFetchItemImages`、以及測試用 `debugRunItemImagesOnly`）都共用 `_fetchItemImages`，改動一處即全數套用。

### 3. UI（`lib/widgets/update_progress_dialog.dart`）

`_Body` 的 `FetchingItemImages` 分支改為依 `phase` 切換內文文案，進度條與版面不變：

```dart
FetchingItemImages(:final phase, :final doneCount, :final totalCount) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    LinearProgressIndicator(
      value: totalCount == 0 ? null : doneCount / totalCount,
    ),
    const SizedBox(height: AppSpacing.l),
    Text(switch (phase) {
      ItemImagePhase.checking =>
        l.updateProgressItemFetchingData(doneCount, totalCount),
      ItemImagePhase.downloading =>
        l.updateProgressItemDownloading(doneCount, totalCount),
    }),
  ],
),
```

標題列（`_Title`）的 `FetchingItemImages` 維持 `Icons.image_outlined` + `l.progressFetching`（「抓取中…」），不分 phase。

### 4. 文案（`lib/l10n/app_{zh,zh_Hans,en,ja}.arb`）

新增 `updateProgressItemFetchingData`（取得物品資料階段），placeholders 同 `updateProgressItemDownloading`（done / total 皆 int）：

| 語言 | 文案 |
|---|---|
| app_zh（繁中） | `取得物品資料 {done}/{total}` |
| app_zh_Hans（簡中） | `获取物品数据 {done}/{total}` |
| app_en | `Fetching item data {done}/{total}` |
| app_ja | `アイテムデータを取得中 {done}/{total}` |

`updateProgressItemDownloading`（「下載物品圖片 {done}/{total}」等四語）原樣保留，語意現在正確（`{total}` = 真正要下載的張數）。新增字串後需重跑 l10n codegen（`flutter gen-l10n` 或隨 build 自動產生）讓 `app_localizations*.dart` 更新。

## 不做（YAGNI）

- 不照原神切成三段——鳴潮官方 API 一步取得 url，沒有「抓取物品詳情」這一步。
- illustration 大圖仍走 lazy（打開物品詳情時才下載），不納入此階段、不另開進度。
- 完成摘要不改（已是真實下載數）。
- 不在「取得物品資料」階段預先估算「會下載幾張」以外的任何統計；只在進入下載階段時用 `toDownload.length` 當 total。

## 測試與驗收

### 既有測試（須維持綠）

`test/state/gacha_repository_item_image_test.dart` 三個測試只斷言 index 結果與 icon 檔存在、不碰進度數字，行為不變應全綠：

- 「角色寫正取 + 下載 icon；武器/道具寫負取」
- 「正取者第二次跑不重抓；負取者每次重試」
- 「被拒的不相容舊版 v1 匯入不觸發補圖」

### 新增測試（證明誤導已修）

在 `gacha_repository_item_image_test.dart` 新增一個案例，用 `ProviderContainer.listen(gachaRepositoryProvider, ...)` 蒐集進度序列，種一個「1 正取 + 2 負取」情境，斷言：

- 出現過 `FetchingItemImages(phase: checking, totalCount: 3)`（待查 3 個物品）。
- 出現過 `FetchingItemImages(phase: downloading, totalCount: 1)`（**只有 1 張真正要下載**）——這是修正的關鍵斷言：下載階段 `totalCount` 等於實際有圖數，而非待查數。
- 全負取情境（characters 空集合）：出現 checking 階段，但**不**出現 downloading 階段（`toDownload` 為空跳過）；`downloaded == 0`。

### 驗收條件

1. `dart format lib/ test/`
2. `flutter analyze` → `No issues found!`
3. `flutter test` → `All tests passed!`
4. 人工 / 邏輯確認：含負取的更新，進度先顯示「取得物品資料 {done}/{total}」，再顯示「下載物品圖片 {done}/{有圖張數}」；下載階段 total 等於確認有圖的張數（非待查數），完成摘要張數等於下載成功寫檔數（下載全成功時 = 下載階段 total）。

## 影響檔案

- `lib/state/update_progress.dart`（新增 enum + 改 `FetchingItemImages`）
- `lib/state/gacha_repository.dart`（`_fetchItemImages` 拆兩階段）
- `lib/widgets/update_progress_dialog.dart`（依 phase 切文案）
- `lib/l10n/app_zh.arb`、`app_zh_Hans.arb`、`app_en.arb`、`app_ja.arb`（新增 `updateProgressItemFetchingData`）
- `test/state/gacha_repository_item_image_test.dart`（新增進度斷言測試）
