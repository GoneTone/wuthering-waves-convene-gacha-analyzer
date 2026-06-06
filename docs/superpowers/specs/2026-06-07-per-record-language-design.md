# 逐筆語言碼＋語言無關分類（per-record language & encore-backed kind）設計

- 日期：2026-06-07
- 狀態：設計定案，待寫實作計畫
- 影響範圍：資料模型、存檔 schema（含遷移）、合併演算法、物品圖片索引、類型分類、統計／表格／分享圖、物品詳情 dialog、圖片／詳情抓取編排

## 背景

鳴潮遷移（`docs/superpowers/specs/2026-06-01-wuwa-convene-migration-design.md`）為了簡化，做了兩個「收斂」決策，現在都要回退：

1. **D8（語言）**：把語言碼從原神版的「逐筆 `record.lang`」收斂成「帳號級單一值 `BannerStorage.languageCode`」。
2. **類型分類**：把原神版「靠外部權威索引（HoYoWiki `menu_id`）判定 kind」改成「靠 `resourceType` 字串語言對應表（`_resourceTypeToKind`）直接映射」（`gacha_stats.dart:57` 註解：「不再依賴外部 index」）。

### 問題一：換語言重抓會覆蓋原本資料

玩家在遊戲內切換語言後重新擷取時，官方 API 以新語言回傳整池全歷史，每筆 `name`／`resourceType` 都變新語言。`record_merge.dart` 的 `recordsEqual` 把 `name` 納入對齊指紋 → 換語言後名稱全變 → anchor 對不上 → 走「replacing with fresh」整池取代，連帳號 `languageCode` 一起被換掉。**原本擷取的紀錄語言被覆蓋。**

### 問題二：語言對應表分類不準確

`_resourceTypeToKind` 只涵蓋 zh-Hant／zh-Hans／en／ja 的 `resourceType` 文案。玩家若用其他語系（韓、法、德…）擷取，`resourceType` 查無對應 → kind 判定失敗 → 分類錯誤、encore endpoint 選錯、無 icon。**用語言對應表分類字詞本質上不可靠。**

## 目標

把「語言」與「類型」都改成**跟著物品（per-item）且語言無關**，恢復原神版行為：

1. **逐筆語言碼**：每筆 `GachaRecord` 帶自己的 `languageCode`。抓新資料時舊紀錄連同它的語言／名稱／類型完全不動，只有「真正新抽到的」用本次擷取語言。
2. **語言無關分類**：類型 kind 改由 **encore.moe catalog 的清單歸屬**（`roleList`／`weapons`／`itemList` 各含一批 `resourceId`）判定——某 `resourceId` 落在哪個清單就是哪個 kind，與語言無關。查不到（encore 未收錄／離線）才 fallback 原始 `resourceType` 字串。此為原神版 `itemTypeKeyOf(r, index)`（靠 HoYoWiki `menu_id`）的等價做法，且 `resourceId` 本身語言無關，比原神 name+lang 更乾淨。
3. **encore 詳情跟著逐筆語言**：詳情 dialog 用「該筆紀錄自己的語言」查 `detailByLang`，抓取階段為每個出現過的語言各補一份。

列表會自然呈現**混語言**（某些物品繁中、某些英文，視當初抽到時遊戲語言而定）——這是 per-record lang 的自然結果、也是原神版既有行為（已與使用者確認為預期）。

## 非目標（YAGNI）

- **不**做 App 內語言切換器：顯示語言由各筆紀錄自己的擷取語言決定。
- **不**保留 `_resourceTypeToKind` 語言對應表（移除）；未分類者只退回**原始字串**（不猜、不用位數啟發式）。
- **不**移除帳號級 `BannerStorage.languageCode`：保留作為「最近擷取語言＋legacy 回填來源」（D5）。
- **不**改 `rust/` MITM 擷取邏輯：`cred.languageCode` 既有，沿用。

## 設計決策

| ID | 決策 | 內容 |
|----|------|------|
| **D1** | 逐筆語言碼 | `GachaRecord` 新增 `languageCode`，為該筆紀錄的權威語言。 |
| **D2** | 新紀錄標語言 | `GachaRecord.fromApiJson` 多收 `languageCode`，由 `GachaFetcher.fetchPool` 帶入 `cred.languageCode`。 |
| **D3** | 合併語言無關 | `record_merge.dart` 對齊指紋去掉 `name`，改比 `(time, resourceId, qualityLevel, count)`。 |
| **D4** | 詳情查逐筆語言 | 詳情 dialog 改用 `record.languageCode` 查 `detailByLang`／組 encore URL／luckdraw 語言；移除 `activeLanguageCodeProvider`。 |
| **D5** | 帳號級語言留用 | 保留 `BannerStorage.languageCode`，重定義為「最近擷取語言＋legacy 回填來源」，仍由 `cred.languageCode` 寫入。 |
| **D6** | 透明遷移 | `BannerStorage.fromJson` 對缺 `language_code` 的舊紀錄回填帳號級值；無獨立 migration 步驟。 |
| **D7** | 逐筆收集語言抓圖 | `_fetchItemImages` 的 `langsById` 從「逐帳號 `data.languageCode`」改為「逐筆 `r.languageCode`」累積。 |
| **D8** | 分類來源＝encore 歸屬 | kind 由 encore catalog 清單歸屬（`roleList`→角色／`weapons`→武器／`itemList`→道具）以 `resourceId` 判定，語言無關。 |
| **D9** | kind 持久化 | `ItemImageEntry` 新增 `kind` 欄位（canonical 鍵或 null），由 catalog 歸屬寫入並 persist；離線時供分類用。 |
| **D10** | `itemTypeKeyOf` 還原 index 簽名 | 改 `itemTypeKeyOf(GachaRecord r, ItemImageIndex index)`：回 `index.lookupImage(r.resourceId)?.kind ?? r.resourceType`（fallback 原始字串）。移除 `_resourceTypeToKind`。 |
| **D11** | catalog 固定抓三清單 | `_fetchItemImages` 不再用語言表決定抓哪些 catalog，固定抓 `roleList`／`weapons`／`itemList` 三清單、由歸屬反推 kind。icon／歸屬語言無關（沿用既有「icon lang-agnostic」前提）。 |

---

## Part A：逐筆語言碼

### `GachaRecord`（`lib/models/gacha_record.dart`）

- 新增欄位 `final String languageCode;`（建構子 **required**）。
- `fromApiJson({required String cardPoolType, required String languageCode})`：寫入每筆。
- `fromStorageJson(Map json, {required String fallbackLanguageCode})`：讀 `json['language_code']`，缺／空時用 `fallbackLanguageCode`（D6 遷移）。
- `toStorageJson()`：新增 `'language_code': languageCode`。

### `BannerStorage`（`lib/models/banner_storage.dart`）

- `languageCode` 保留，dartdoc 改述為「最近一次擷取語言；亦為載入時對舊紀錄回填逐筆語言的來源」。
- `fromJson`：先取自身 `language_code`，再以 `GachaRecord.fromStorageJson(e, fallbackLanguageCode: bannerLang)` 還原每筆（D6 遷移點）。
- `toJson`／`copyWith`：不變（每筆 record 由 `toStorageJson` 各自帶 `language_code`）。

### 合併（`lib/services/record_merge.dart`）

- `recordsEqual` 比對欄位改為 `(time, resourceId, qualityLevel, count)`，**刻意排除 `name`／`resourceType`／`languageCode`**；dartdoc 補述「語言無關對齊指紋」。
- `mergeOrderedRecords` 結構不變——`[...newOnes, ...existing]`：`newOnes`（fresh，本次擷取語言）＋`existing`（原封不動，保留原語言）。
- 副作用修掉：不再因名稱差異誤判 anchor 失敗、不再無謂 replace、不再因部分卡池失敗放大跨池混語言。「anchor 找不到 → replace with fresh」分支保留（僅在語言無關序列真的對不上時觸發，如換帳號）。

### 抓取（`lib/services/gacha_fetcher.dart`）

- `fetchPool` 把 `cred.languageCode` 傳入 `GachaRecord.fromApiJson`。

---

## Part B：語言無關分類（encore-backed kind）

### `ItemImageEntry`（`lib/services/item_image_index.dart`）

- 新增 `final String? kind;`（值為 `kItemKindCharacter`／`kItemKindWeapon`／`kItemKindItem`，未分類為 null）。
- `toJson`／`fromJson`／storage `load`／`save`：新增 `kind` 欄位讀寫（向後相容：缺欄位 → null）。

### `ItemImageIndexNotifier`（`lib/state/item_image_index.dart`）

- `mergeIcon` 新增可選 `String? kind` 參數，寫入時 `kind: kind ?? prev?.kind`（HD icon 升級與 `mergeItemDetail` 不帶 kind 時保留既有值）。

### `itemTypeKeyOf`（`lib/services/item_type_kind.dart`）

- 移除 `_resourceTypeToKind` 語言對應表。
- 簽名改為 `String itemTypeKeyOf(GachaRecord r, ItemImageIndex index)`，實作：

  ```dart
  String itemTypeKeyOf(GachaRecord r, ItemImageIndex index) =>
      index.lookupImage(r.resourceId)?.kind ?? r.resourceType;
  ```

- `itemTypeKeyLabel` 不變（canonical 鍵套譯名、空字串「未知」、其餘原始字串 fallback）。

### 分類來源的穿線（還原原神 `itemTypeKeyOf(r, index)` 模式）

| 函式 | 改動 | 呼叫端如何拿 index |
|------|------|------------------|
| `buildRecordRows(records, index, {mainRank})` | 多收 `index`，`itemTypeKeyOf(r, index)` | `banner_page`（Consumer）`ref.watch(itemImageIndexProvider)` |
| `computeGachaStats(records, index)` | 多收 `index` | `banner_page`／`buildOverviewSections`／`ShareCard.banner`／`ShareCard.overview` |
| `buildOverviewSections(activeBanners, index)` | 多收 `index`，傳給 `computeGachaStats` | `overview_page`（Consumer）、分享流程 |
| `ShareCard.banner/.overview(...)` | 工廠多收 `index`，傳給 `computeGachaStats`／`buildOverviewSections` | 分享 dialog／export（Consumer）讀 index 後注入（與既有「所有相依由建構子注入」一致） |
| 詳情 dialog | `itemTypeKeyOf(record, ref.watch(itemImageIndexProvider))` | dialog 自身 |

---

## `_fetchItemImages` 重寫（合併 A＋B；`lib/state/gacha_repository.dart`）

1. **收集**：逐筆掃 `state.byUid` 的所有 record，建 `langsById[resourceId] = {各筆 r.languageCode}`（D7）；同時收集全部 `resourceId`。**不再**預先用 `itemTypeKeyOf` 算 kind。
2. **判定是否有事要做**（gate catalog 抓取）：某 id 需處理 = `needsItemImageFetch`（icon 未就緒）**或** `existing.kind == null`（kind 未分類，含既有快取 icon 但無 kind 的升級回填）**或** 任一 `r.languageCode` 詳情未抓。全無 → early return。
3. **抓 catalog（D11）**：對每個出現過的語言抓 `roleList`／`weapons`／`itemList` 三清單，union 成 `iconById`／`kindById`（icon 與歸屬語言無關，union 容忍個別語系缺漏）。某清單請求失敗 → 該清單空（沿用既有逐 kind 容錯）。
4. **分類＋icon 正負取**：對每個「需處理」的 id，由歸屬決定 `(kind, iconUrl)`：
   - 命中某清單：
     - icon 未就緒 → `mergeIcon(id, iconUrl, kind: kind, noImage: false)`，加入 `toDownload`／`positiveIds`。
     - icon 已快取但 `kind==null`（既有使用者升級回填）→ `mergeIcon(id, iconUrl: existing.iconUrl, kind: kind, noImage: false)`，**只補 kind、不重下載**（不加入 `toDownload`）；仍列入 `positiveIds`。
   - 三清單皆無 → `mergeIcon(id, iconUrl: null, kind: null, noImage: true)`（負取；`itemTypeKeyOf` 對此 id 退回原始字串）。
5. **詳情預抓（per-lang）**：worklist 改為「kind∈{角色,武器} 且該 `r.languageCode` 未在 `detailByLang`」的 `(id, lang)`，並行 `fetchItemDetail`（用歸屬 kind 選正確 endpoint，根治語言表選錯端點）→ `mergeItemDetail`。`checking` 進度對此 worklist 計數。
6. **HD icon 升級**（角色 256px）、**下載階段**：不變。

> kind 由歸屬決定後，詳情 endpoint 一律正確（角色 `/character`、武器 `/weapon`、道具不打）。「道具」若不在任何 encore 清單 → 負取無圖＋`itemTypeKeyOf` 退原始字串，與現況一致。

---

## 遷移策略

- 現有鳴潮存檔：每筆有 `resource_id`、有帳號級 `language_code`，但**無逐筆 `language_code`**、`ItemImageEntry` 無 `kind`。
  - 逐筆語言：載入時 `BannerStorage.fromJson` 回填帳號級值（D6），無損透明。
  - kind：`ItemImageEntry.kind` 缺欄位 → null。**既有快取 icon 但 kind==null 的物品，下次更新會被 `_fetchItemImages` step 2 的 gate 納入、step 4 只補 kind 不重下載**（升級回填，不需強制重抓）；補上前 `itemTypeKeyOf` 退回原始字串（與原神「wiki index 未下載前退原始字串」一致）。
- 之後任一次更新存回，逐筆 `language_code` 與 `kind` 自動落地。
- 舊原神格式（缺 `resource_id`）的「跳過不相容舊檔」邏輯不受影響（`resource_id` 仍是辨識鍵）。
- 匯出／匯入走同一套 `toStorageJson`／`fromStorageJson`，round-trip 保留逐筆語言；舊 bundle 由同一回填路徑補上。

## 已知限制

- encore 未收錄的物品（部分「道具」）或離線時，分類退回原始 `resourceType` 字串——此時跨語言可能分裂為多組，但與原神 fallback 行為一致、且不猜測。待 encore 收錄後自動轉為 canonical。

## 測試計畫

- `test/services/record_merge_test.dart`：跨語言重抓對齊（existing 語言 A、fresh 語言 B 同序列 → 保留 existing、只前插新筆 B）；既有以 name 差異驅動的案例改寫為語言無關語意。
- `test/models/gacha_record_test.dart`：逐筆 `language_code` round-trip；缺欄位 `fallbackLanguageCode` 回填。
- `test/models/banner_storage_test.dart`：載入舊格式（record 無 `language_code`）回填帳號級語言。
- `test/services/item_type_kind_test.dart`（新增）：`itemTypeKeyOf(r, index)` 由 index.kind 回 canonical；index 無 entry → 回原始 `resourceType`；同 id 不同語言兩筆 → 同一 kind（跨語言合併）。
- `test/services/gacha_stats_test.dart`／`gacha_row_test.dart`：傳 index；canonical 聚合；跨語言不分裂。
- `test/services/item_image_index_test.dart`／`test/state/item_image_index_test.dart`：`kind` 欄位 round-trip；`mergeIcon` 帶／不帶 kind 的保留語意。
- `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`：移除 `activeLanguageCodeProvider` override，改以 `record.languageCode` 驗證詳情；`itemTypeKeyOf` 改吃 index。
- `test/state/gacha_repository_item_image_test.dart`：混語言帳號 → 每語言各抓詳情；encore 歸屬寫 kind；不在 encore 的 id → 負取＋原始字串 fallback。
- `test/widgets/luckdraw_chip_test.dart`：改用 record.languageCode。

## 受影響檔案

| 檔案 | 變更 |
|------|------|
| `lib/models/gacha_record.dart` | 新增 `languageCode`；三個 JSON 方法調整 |
| `lib/models/banner_storage.dart` | `fromJson` 回填逐筆語言；dartdoc 重述 |
| `lib/services/gacha_fetcher.dart` | `fetchPool` 傳 `cred.languageCode` |
| `lib/services/record_merge.dart` | `recordsEqual` 語言無關 |
| `lib/services/item_type_kind.dart` | 移除語言表；`itemTypeKeyOf(r, index)` |
| `lib/services/item_image_index.dart` | `ItemImageEntry.kind` 欄位＋讀寫 |
| `lib/state/item_image_index.dart` | `mergeIcon` 加 `kind` 參數 |
| `lib/services/gacha_row.dart` | `buildRecordRows` 收 index |
| `lib/services/gacha_stats.dart` | `computeGachaStats` 收 index |
| `lib/services/overview_sections.dart` | `buildOverviewSections` 收 index |
| `lib/widgets/share/share_card.dart` | 工廠收 index |
| `lib/pages/banner_page.dart`／`overview_page.dart`／分享 dialog | 傳入 `ref.watch(itemImageIndexProvider)` |
| `lib/state/gacha_repository.dart` | `_fetchItemImages` 重寫；移除 `activeLanguageCodeProvider` |
| `lib/widgets/dialogs/gacha_item_detail_dialog.dart` | 詳情／URL／luckdraw 用 `record.languageCode`；`itemTypeKeyOf` 吃 index |
| 上述對應測試檔 | 見「測試計畫」 |

## 驗收條件

1. `fvm dart format lib/ test/`、`fvm flutter analyze`（`No issues found!`）、`fvm flutter test`（`All tests passed!`）全綠。
2. 切遊戲語言重抓後，舊紀錄的名稱／類型／語言不變，僅新抽到的為新語言；列表呈現混語言。
3. 物品詳情 dialog 對混語言列表中的不同筆，各自顯示其擷取語言的 encore 詳情。
4. 類型分類不再依賴 `resourceType` 語言對應表：以任意語系（含韓／法／德）擷取，抓過 catalog 後角色／武器皆正確 canonical 分類、統計不跨語言分裂。
5. 既有帳號存檔載入無損（舊紀錄回填帳號級語言、kind 抓 catalog 後補上），不需使用者重抓。
