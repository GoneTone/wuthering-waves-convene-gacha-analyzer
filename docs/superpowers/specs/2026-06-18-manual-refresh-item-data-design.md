# 手動更新物品詳細資料 — 設計文件

- 日期：2026-06-18
- 狀態：設計已確認，待實作
- 參考：姐妹專案 PR [genshin-impact-wish-gacha-analyzer#121](https://github.com/GoneTone/genshin-impact-wish-gacha-analyzer/pull/121)（HoYoWiki 版），本文件為對映到本專案 encore.moe 架構的版本

> 使用者要求對齊姐妹專案 PR #121 的設計與 UI/UX，不自行修改設計。本文件只做必要的 encore.moe 架構對映。兩處依使用者確認決定：(A) UI 文案**不提資料來源名稱**（姐妹寫死「HoYoWiki」，本專案資料來自 encore.moe，改用中性措辭）；(B) **納入**殘留語言清理（pruneLanguages），完整對齊姐妹最終出貨設計。

## 背景與問題

物品詳細資料（icon、per-lang 詳情、造型 skins 清單、是否有喚取立繪）由 `GachaRepository._fetchItemImages`（`lib/state/gacha_repository.dart`）的管線抓取，存進 `item_image_index.json`（`ItemImageIndex`）。

這條管線是**增量式**的：`needsWork(id)` 判定「icon 已就緒、kind 已分類、各語言 detail 都抓過（`detailByLang.containsKey(lang)`）、角色 hasLuckdraw 已評估」就回傳 `false`，整個物品被跳過、不重抓。內層 worker 另有 `detailAlready` 守衛（`existing?.detailByLang.containsKey(lang)`），detail 已存在即不重抓該語言。

結果是——**若 encore 後來替某角色新增造型 skins（例如新增立繪），正常更新永遠偵測不到**，因為該語言的 detail 早已存在。

設定頁現有的「強制重抓物品圖片」按鈕（`forceRefetchAllItemImages`）雖能拿到新資料，但它先 `resetAll()` **清空整個 index 與所有快取圖**，再全部重抓並 eager 下載所有 icon。這是破壞性的、耗時且浪費頻寬。

使用者需要一個**非破壞性**的入口：只重抓 metadata，讓新增的 skins／頁籤被偵測到，但保留已下載的圖、不 eager 下載新圖；新圖一律維持 lazy，等使用者開啟該物品詳情時才補下載。

## 目標

1. 設定頁新增一顆「更新物品資料」按鈕，點擊後重抓所有物品的詳細資料（非破壞性）。
2. 重抓涵蓋：對先前**沒解析到**的物品重試 catalog 解析；對**所有正取**的物品強制重抓 detail 階段（更新 skins 清單／詳情）。
3. 不重抓已下載的圖；icon 僅在本地缺檔時補下載；造型 skins 大圖一律維持 lazy。
4. 物品詳情頁的頁籤隨 index 更新自動反映新 skins 條目；開啟詳情時補下載缺漏的圖。
5. 完成訊息使用**本流程專屬語意**（「已更新 M 個物品的資料」），不沿用一般更新流程的「新增 N 筆紀錄」。
6. **針對性清理殘留語言**：移除 index 中已不再被任何記錄使用的語言詳情（資料語言轉換後的殘留），維持非破壞性，並在完成訊息統計清理到的物品數。

## 非目標（YAGNI）

- 不做「只更新逾期條目（依時間門檻）」的選擇性更新——所有正取物品都重抓。
- 不改 icon 快取的 key 策略（仍以 id 為 key）；不主動因 icon URL 字串變動而重下 icon。
- 詳情頁不新增任何 per-item 重抓入口（既有圖片區的「重抓」已涵蓋單張需求）。
- 既有「破壞性強制重抓」按鈕原樣保留，與新按鈕職責區隔（破壞性 vs 非破壞性）。
- 殘留語言清理**只清 index 內的 `detailByLang`**，不刪 orphan 造型圖檔（殘留語言的 skins 是 lazy，多半從未下載；少量 orphan 交給既有「清除立繪快取」）。

## 關鍵發現：詳情頁無需改動

`GachaItemDetailDialog.build()`（`lib/widgets/dialogs/gacha_item_detail_dialog.dart`）已 `watch(itemImageIndexProvider)`，從 `detail.skins` 建 chips，且既有的 lazy backfill 對「不在 `_loadStates` 的 chip」逐一檢查：本地有檔 → `_ImageReady`，缺檔 → `_ImageLoading` 並排程背景下載（造型走 `_fetchAndCache`，喚取走 `_captureLuckdraw`）。

每次開啟 dialog 都是全新的 `State`、`_loadStates` 為空，因此**每次開啟都會重新檢查所有 chip（含造型大圖）並補下載缺的**。metadata 更新後，`mergeItemDetail` 以新 detail 覆蓋該語言 → 新 skins 條目進入 index → 下次（或開著時）重建即多出新 chip → 缺檔自動 lazy 補下載。

icon 則在更新階段就補齊（缺檔才下載），詳情頁本身不處理 icon lazy 下載。

**結論：「頁籤跟著更新」與「開啟詳情時補下載缺圖」由既有機制完整涵蓋，本功能在詳情頁零改動，前提僅是 index 要先被更新。**

## 與姐妹專案的架構對映

| 姐妹（HoYoWiki） | 本專案（encore.moe） |
|---|---|
| `_fetchHoYoWiki(forceEntryRefetch, pruneStaleLangs)` | `_fetchItemImages(client, {forceDetailRefetch, pruneStaleLangs})` |
| `refreshAllHoYoWikiMetadata()`（非破壞性，無 resetAll） | `refreshAllItemDetails()`（新增，非破壞性） |
| `mergeEntry` ／ gallery 大圖 lazy | `mergeItemDetail` ／ skins 大圖 lazy |
| `pruneLanguages(keepLangs)` on hoyowiki index | `pruneLanguages(keepLangs)` on `detailByLang` |
| 設定頁新增「物品資料」區 | 設定頁新增「物品資料」區（圖片快取區之前） |
| `UpdateCompleted.hoyoWikiEntriesRefreshed ／ hoyoWikiStaleItemsPruned` | `UpdateCompleted.itemDetailsRefreshed ／ staleItemsPruned` |

## 設計

### 1. 參數化 `_fetchItemImages`（重用既有管線，不造新輪子）

`lib/state/gacha_repository.dart`，最終簽名：

```dart
Future<({int imagesDownloaded, int itemsRefreshed, int staleItemsPruned})>
    _fetchItemImages(
  http.Client client, {
  bool forceDetailRefetch = false,
  bool pruneStaleLangs = false,
})
```

- **回傳改為 record**：`imagesDownloaded`（本次成功寫檔的 icon 張數，沿用既有語意）、`itemsRefreshed`（本次成功重抓 detail 的**相異物品數**）、`staleItemsPruned`（本次清掉殘留語言的相異物品數）。其餘呼叫端（一般更新、匯入、unify）只讀 `.imagesDownloaded`，改為解構取該欄位即可，不受影響。
- **gate（`needsWork`）**：`forceDetailRefetch == false` 維持現狀。`forceDetailRefetch == true` 時**無條件對所有 `langsById` 的 id 回傳 true**，不對任何負取狀態（含 `permanentNoImage`）做例外——這顆手動按鈕就是要給所有物品一次重新嘗試的機會。效果：catalog 重跑 → 先前負取／encore 新增的物品重新嘗試解析；正取物品強制進入 detail 階段。
  - 註：`permanentNoImage` 在本專案目前**從未被設為 true**（model 留著欄位，但 `lib/` 內所有寫入點皆為 false／沿用，屬自原神版移植遺留、未接上的旗標），故實務上不存在永久負取物品；force 路徑無條件重抓在今天沒有任何行為差異，僅是明確不依賴該旗標、並對映姐妹專案「無負快取、人人重抓」的語意。是否一併移除此遺留欄位屬獨立清理，不在本功能範圍。
- **detail 階段內層 worker**：`forceDetailRefetch == true` 時略過 `detailAlready` 守衛，對正取、非道具的 `(id, lang)` 一律重抓 detail（偵測新 skins）。`hasLuckdraw` 維持「一旦為 true 永遠為 true」語意不變。
- **icon**：`needsItemImageFetch` gate 不變 → **缺檔才下載**，已有 icon 不重下；符合「icon 僅缺檔補下載」。
- **skins**：本管線從不 eager 下載造型大圖（既有行為）→ **維持 lazy**，由詳情頁開啟時補下載；符合需求。
- **`itemsRefreshed`**：以 `Set<int> refreshedIds` 在每次成功 `mergeItemDetail` 後 `add(id)`，回傳其 `length`（相異 id，同物品多語言只算 1）。
- **殘留語言清理**：`pruneStaleLangs == true` 時，在算出 `allLangs`（所有記錄語言集合，即既有 `langsById` 的值聯集）後、進入 detail 階段前，以 `allLangs.isNotEmpty` 守衛呼叫 `indexNotifier.pruneLanguages(allLangs)`；`staleItemsPruned` = 該呼叫回傳值；清完重讀 index 快照供後續階段使用。
- **取消／互斥／進度**（`FetchingItemImages` 各 phase）全部沿用既有邏輯；所有 return 點都回傳完整 record（prune 之前的早退點 `staleItemsPruned` 自然為 0、`itemsRefreshed` 為 0）。

### 2. 新增 `refreshAllItemDetails()`

`lib/state/gacha_repository.dart`，比照 `forceRefetchAllItemImages` 的骨架，**但拿掉 `resetAll()`**（非破壞性）：

1. 互斥檢查（`state.progress != null` ／ 既有更新中旗標 → no-op）。
2. emit `Preparing`、建 cancellable client、設 `_activeCancellable`。
3. 呼叫 `_fetchItemImages(cancellable.client, forceDetailRefetch: true, pruneStaleLangs: true)`（不清 index、不清 cache）。
4. 依取消狀態 emit `UpdateCompleted(itemImagesDownloaded: result.imagesDownloaded, itemDetailsRefreshed: result.itemsRefreshed, staleItemsPruned: result.staleItemsPruned)` 或 `clearProgress`。
5. `finally` 收尾關 client、清旗標。

專屬 logger `Logger('wish.itemImage.refreshDetails')`，在開始、各階段、完成／取消處埋 `info`（帶 images／items／pruned 計數）。

### 3. `ItemImageIndexNotifier.pruneLanguages`

`lib/state/item_image_index.dart`：

```dart
Future<int> pruneLanguages(Set<String> keepLangs)
```

- 移除所有 entry 中 `lang ∉ keepLangs` 的 `detailByLang` 條目；保留 `iconUrl` ／ `noImage` ／ `permanentNoImage` ／ `kind` ／ `hasLuckdraw`。
- **空 `keepLangs` 直接 `return 0`**（防呆：空集合會清掉全部）——method 內部第二道防線，呼叫端另有 `allLangs.isNotEmpty` 守衛。
- 有實際縮減才走 `_saveAndEmit`；無變動 `return 0`（不重建 index、不觸發 UI churn）。
- 回傳值 = `detailByLang` 真的有縮減的**相異物品數**，供完成訊息統計。
- 與既有 merge* 一致走 `_lock.synchronized` 保護 read-modify-write。

### 4. 設定頁：新增「物品資料」區

`lib/pages/settings_page.dart`：

- 在 `build` 的 section 清單，於「圖片快取」（`_ImageCacheSection`）之前新增一張 `SectionCard`（圖示 `Icons.dataset_outlined`），把「物品資料更新」與「圖片快取管理」相鄰分組。
- 新增 `_ItemDataSection`（`ConsumerWidget`）：一行說明（`l.settingsRefreshItemDataDesc`）+ 一顆**一般** `FilledButton.icon`（非 danger 樣式，與破壞性按鈕區分）。
- disable 條件比照 `_refetchAll`：`!hasData || progress != null`；`!hasData` 時 `Tooltip` 顯示 `l.settingsRefreshItemDataEmpty`。
- 點擊 → `showConfirmDialog(isDanger: false)` 輕量確認 → `unawaited(refreshAllItemDetails())`。進度 dialog 由 `app_shell.dart` 既有 `ref.listen` 自動彈出。

### 5. 完成訊息設計（語意化）

「更新物品資料」**不可**沿用一般更新流程的「新增 N 筆紀錄」（對 metadata 刷新無意義）。改用本流程專屬摘要。

- `UpdateCompleted`（`lib/state/update_progress.dart`）新增兩個欄位：
  - `int? itemDetailsRefreshed`（預設 null）——非 null 即代表「這是更新物品資料流程的完成」，UI 據此切換到物品資料摘要；值為本次成功刷新的物品數。
  - `int staleItemsPruned`（預設 0）——本次清理殘留語言的物品數。
- `UpdateProgressDialog` 的 `UpdateCompleted` 分支改為**三路**（`lib/widgets/update_progress_dialog.dart`）：
  1. `importSummary != null` → 匯入摘要（既有，不變）。
  2. `itemDetailsRefreshed != null` → 物品資料摘要：
     - 主行：`已更新 {M} 個物品的資料`（`l.progressDoneItemDataSummary`）。
     - 補圖行（僅 `itemImagesDownloaded > 0`）：`補下載 {N} 張物品圖片`（`l.progressDoneItemDataImagesSummary`）。
     - 清理行（僅 `staleItemsPruned > 0`）：`已清理 {K} 個物品的殘留語言資料`（`l.progressDoneItemDataPrunedSummary`）。
  3. else → 一般更新摘要（既有「新增 N 筆紀錄」+「下載 N 張物品圖片」，不變）。
- 標題沿用「更新完成」。

### 6. i18n 字串

依專案慣例：先寫 `app_zh.arb`（template，含 `@` 描述），再以中文為基準翻**已有實體翻譯**的 ARB；不碰空殼（留給 Crowdin pipeline）；省略號半形 `...`。資料來源名稱**不提及**（中性措辭，不寫 encore.moe）。預計 key：

| key | 用途 | 繁中 |
|-----|------|------|
| `settingsItemData` | 區塊標題 | 物品資料 |
| `settingsRefreshItemDataDesc` | 區塊說明 | 重新抓取所有物品的最新詳細資料（簡介、圖片清單等），保留已下載的圖片；新增的圖片會在你開啟該物品詳情時才下載。 |
| `settingsRefreshItemDataTitle` | 按鈕文字 | 更新物品資料 |
| `settingsRefreshItemDataEmpty` | 無資料 tooltip | 尚無卡池記錄，無法更新物品資料 |
| `confirmRefreshItemDataTitle` | 確認標題 | 更新物品資料？ |
| `confirmRefreshItemDataBody` | 確認內文 | 將重新抓取所有物品的詳細資料，保留已下載的圖片，新增的圖片會在開啟詳情時才下載。確定要更新嗎？ |
| `progressDoneItemDataSummary` | 完成主行 | 已更新 {count} 個物品的資料 |
| `progressDoneItemDataImagesSummary` | 完成補圖行 | 補下載 {count} 張物品圖片 |
| `progressDoneItemDataPrunedSummary` | 完成清理行 | 已清理 {count} 個物品的殘留語言資料 |

（實際 key 名與文案以實作時對齊既有 ARB 慣例為準；含 placeholder 的需補 `@` 描述與 `placeholders` 定義。）

## 測試

對齊既有測試風格與姐妹 PR 涵蓋面：

- **repository**：`forceDetailRefetch` 強制重抓行為（detail 已存在仍重抓、偵測新 skins）；skins 不被 eager 下載；icon 不重下；`itemsRefreshed` 相異物品計數（同物品多語言算一次）；`refreshAllItemDetails` 不呼叫 `resetAll`。
- **index notifier**：`pruneLanguages` 移除殘留語言、保留當前語言與 icon／kind／hasLuckdraw；空 `keepLangs` 回 0 不動資料；無縮減回 0 不重建。
- **settings widget**：新區塊與按鈕存在、disable 條件、確認走 `isDanger: false`。
- **progress dialog widget**：三路分支；補圖行／清理行的條件顯示（0 不顯示）。

驗收：`fvm flutter analyze` → `No issues found!`；`fvm flutter test` → `All tests passed!`。
