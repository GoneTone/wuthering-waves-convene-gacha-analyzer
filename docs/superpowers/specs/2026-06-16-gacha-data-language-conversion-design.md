# 卡池歷史資料語言轉換（gacha data-language conversion）設計

- 日期：2026-06-16
- 狀態：設計定案，待寫實作計畫
- 影響範圍：設定模型／持久化（`AppSettings`／`SettingsStorage`）、設定頁 UI、encore 目錄抓取（`EncoreCatalog`／`fetchCatalog`）、新增語言目錄快取、新增轉換引擎、`gacha_repository.update()`、第三方匯入流程、物品詳情顯示

## 背景

逐筆語言碼設計（`docs/superpowers/specs/2026-06-07-per-record-language-design.md`）讓每筆 `GachaRecord` 帶自己的 `languageCode`，列表自然呈現**混語言**——某些物品繁中、某些英文、某些日文，取決於當初抽到（擷取）或匯入當下的資料語言。對部分使用者而言，混語言清單不易閱讀。

本功能在設定頁新增一個**獨立於 App UI 語言**的「資料語言」設定，讓使用者把全部卡池歷史資料的顯示文字統一成單一語言。轉換所需的各語言名稱／類型／詳情可透過 encore.moe API 取得，並**本地持久化**，使用者切換語言再切回不需重抓。

### 現況關鍵事實（探索結論）

- `GachaRecord`（`lib/models/gacha_record.dart`）每筆存**翻譯後的 `name` 字串**、語言相關的 `resourceType`（角色／武器／道具）、每筆 `languageCode`、穩定的 `resourceId`（正值）；第三方匯入缺 id 時用名稱 FNV-1a 產生**負值合成 ID**（`syntheticResourceIdForName`），無法回查 encore。
- 存檔為純 JSON（`lib/services/gacha_storage.dart`，`<playerId>.records.json`），`BannerStorage` 帶帳號級 `languageCode` 與 `last_updated`。
- encore `fetchCatalog(lang, kinds, client)`（`lib/services/item_image_fetcher.dart`）可用 `resourceId` 取**各語言名稱**；支援語言白名單 `_encoreLangs` 含本功能 9 種語言全部。已有 per-lang 詳情快取 `ItemImageEntry.detailByLang`（`lib/services/item_image_index.dart`）。
- `gacha_repository.dart` 已有「對紀錄出現過的所有語言逐個 `fetchCatalog`」的 `langsById` 模式可沿用。
- 設定為 SharedPreferences + Riverpod `NotifierProvider`（`lib/state/settings.dart`／`lib/services/settings_storage.dart`）；UI 語言（`LanguagePreference`）與資料語言**本來就分離**，現成 `_LocaleDropdown`（`lib/pages/settings_page.dart`）可作樣式參考。

## 目標

1. 設定頁新增「資料語言」設定（9 種語言 +「未設定」），代碼對齊 encore.moe、**獨立於 App UI 語言**。
2. 設定後，未來不論資料來源是什麼語言，更新／匯入完成都**自動轉換**成設定語言。
3. 提供「統一資料語言」按鈕，把**既有**歷史資料一次轉成設定語言。
4. 各語言資料**本地持久化快取**，切換語言再切回不重抓。
5. 轉換涵蓋**物品名稱 + 詳情**（簡介／元素／武器類型）；**類型標籤（角色／武器／道具）跟 UI 語言**（維持現狀，見 D8）。
6. 預設值＝最新資料的語言（自動播種），新用戶於首次更新／匯入時播種；「未設定」可手動選回以停用轉換。

## 非目標（YAGNI）

- **不**做語言目錄的自動過期／定期刷新：encore 名稱極少變動，缺該語言才抓；日後要手動重抓再加。
- **不**改 `rust/` MITM 擷取邏輯：`cred.languageCode` 沿用。
- **不**移除逐筆 `languageCode`：它仍是每筆紀錄的權威來源語言，轉換成功才改寫。
- **不**為「未設定」狀態保留原始名稱以外的額外備份：轉換成功直接改寫存檔（突變模型），轉不了的保持原狀即為備援。

## 可選語言代碼

9 種，對齊 encore.moe（與遊戲喚取 API 的 `languageCode` 一致，全在 `_encoreLangs` 白名單）：

| 顯示（母語名） | 代碼 | 顯示（母語名） | 代碼 |
|---|---|---|---|
| 繁體中文 | `zh-Hant` | 한국어 | `ko` |
| 简体中文 | `zh-Hans` | Français | `fr` |
| English | `en` | Deutsch | `de` |
| 日本語 | `ja` | Español | `es` |
| | | ภาษาไทย | `th` |

## 設計決策

| ID | 決策 | 內容 |
|----|------|------|
| **D1** | 突變儲存模型 | 轉換直接改寫 JSON 裡的 `name`／`resourceType`／`languageCode`，與「統一按鈕」「更新/匯入自動同步」的心智模型一致。非顯示層覆寫。 |
| **D2** | 設定三態 | `dataLanguage`（`String?`，`null`=未設定）+ `dataLanguageSeeded`（bool）。pref 不存在＝從未初始化（可自動播種）；`"none"`＝明確未設定（不播種）；語言碼＝已設定。 |
| **D3** | 自動播種 | 僅當 `seeded==false`：(a) bootstrap 取所有 UID 中 `last_updated` 最新者的語言；(b) 首次更新／匯入後取該次資料語言。語言 ∈ 9 選項才播種並標記；否則維持未設定不標記（留待之後）。 |
| **D4** | 改設定不動既有 | 改下拉只記目標語言，**不**自動轉換既有資料（既有資料靠按鈕或之後的更新／匯入）。 |
| **D5** | 語言目錄快取 | 新增持久化 `lang_catalog/<lang>.json`（`resourceId → {name, kind}`）。缺該語言才 `fetchCatalog` 補抓並寫檔。 |
| **D6** | EncoreCatalog 擴充 | `EncoreCatalog` 多帶 `nameByKindId`（id→name per kind，與既有 `iconByKindId` 平行），**複用 `fetchCatalog`**，不另寫抓取。 |
| **D7** | 名稱回查補 ID | 合成／負值 ID 或目標目錄查無者，用「原名 + 原語言」目錄做 `name→id` 回查真實 ID；查到→採用真實 `resourceId`（寫回，順手修圖）再轉；查不到→該筆 `name`/`languageCode`/`resourceId` 完全保持原狀。 |
| **D8** | 類型標籤跟 UI 語言 | 類型顯示走既有 `itemTypeKeyLabel(kind, l)`（`l`=App UI ARB），**轉換不動 `resourceType`**。已轉物品必有 `kind`（靠 catalog 查到才轉得動）→ 類型由 ARB 決定、不顯示存檔 `resourceType`。**不需** kind×lang 標籤表。 |
| **D9** | 詳情自動跟資料語言 | 轉換改寫 `record.languageCode = target` 後，詳情 dialog 既有 `detailByLang[record.languageCode]` 查詢即自動跟上；`_fetchItemImages` 既有 `langsById`（逐筆 `r.languageCode`）會以 target 語言補抓 `detailByLang`。**詳情 dialog 與 `_fetchItemImages` 皆無須改**。 |
| **D10** | 更新／匯入後置轉換 | `update()` 與各 importer 完成後，若 `dataLanguage` 已設定，對該帳號 `BannerStorage` 跑一次轉換再落地。忠實沿用既有流程，轉換為附加後置步驟。 |
| **D11** | 失敗不毀資料 | 補抓目錄網路失敗→轉換優雅中止、既有資料不動；更新／匯入本身仍成功（未轉 + warning log）。 |

---

## Part A：設定模型與持久化

### `AppSettings`（`lib/services/settings_storage.dart`）

新增兩欄：

- `String? dataLanguage`：資料語言代碼（9 種之一）或 `null`（未設定／停用轉換）。
- `bool dataLanguageSeeded`：是否已初始化（含自動播種或使用者明確選擇）。

### `SettingsStorage`（pref key `pref.dataLanguage`）

序列化三態：

- pref key **不存在** → `dataLanguage=null`、`dataLanguageSeeded=false`。
- pref `"none"` → `dataLanguage=null`、`dataLanguageSeeded=true`。
- pref 語言碼 → `dataLanguage=<code>`、`dataLanguageSeeded=true`。

`save()` 對應寫回（`null`+seeded→`"none"`；`null`+!seeded→刪 key／不寫；有碼→寫碼）。

### `SettingsNotifier`（`lib/state/settings.dart`）

- `setDataLanguage(String? code)`：更新狀態（任何呼叫都令 `seeded=true`，含傳 `null` 代表使用者選「未設定」），持久化。
- `seedDataLanguageIfUnset(String code)`：僅當 `!seeded` 且 `code ∈ 9 選項` 時設定 + 標記；否則 no-op。
- 衍生 `dataLanguageProvider`（`Provider<String?>`）供各處讀目標語言。

### 自動播種（D3）

- **bootstrap**：bootstrap 完成（帳號／存檔載入後），若 `!seeded`，跨所有 UID 取 `last_updated` 最新帳號之 `BannerStorage.languageCode`，呼叫 `seedDataLanguageIfUnset(...)`。
- **首次更新／匯入**：完成後若 `!seeded`，以該次資料語言呼叫 `seedDataLanguageIfUnset(...)`。

> 播種只預填合理值，依 D4 不轉換既有資料。新用戶首次資料本就是該語言，播種後即一致。

---

## Part B：語言目錄快取

### EncoreCatalog 擴充（D6）

`EncoreCatalog`（`lib/services/item_image_fetcher.dart`）新增：

- `Map<String, Map<int, String>> nameByKindId`：kind → id → name，與既有 `iconByKindId` 平行，在 `_fetchCatalogKind` 解析 `Name` 時一併填入。
- 既有 `idByName`（name→(id,kind)，跨 kind 衝突剔除）保留，供回查使用。

### `LangCatalogStorage`（新檔 `lib/services/lang_catalog_storage.dart`）

- 路徑：`<applicationSupport>/lang_catalog/<lang>.json`。
- 結構：`{ "lang", "fetched_at", "items": { "<resourceId>": { "name", "kind" } } }`。
- `load(lang)` / `save(lang, catalog)`：原子寫入（`.tmp` + rename，沿用既有 pattern）；壞檔／缺檔回 `null`。
- 模型 `LangCatalog`：`Map<int, ({String name, String kind})>` + 反查 `idByName`（供 D7 回查）。

### `LangCatalogService`（新檔，或併入轉換引擎）

- `Future<LangCatalog> ensure(lang)`：先讀本地；缺則 `fetchCatalog(lang, kinds: 全部, client)` → 由 `nameByKindId` 組 `LangCatalog` → 持久化 → 回傳。
- 埋 `wish.langconvert.catalog` log（lang、來源 local/remote、筆數）。

---

## Part C：轉換引擎 `GachaLanguageConverter`（新檔 `lib/services/gacha_language_converter.dart`）

### 介面

```text
Future<LangConvertResult> convert(BannerStorage data, String targetLang)
```

回傳 `LangConvertResult { total, converted, backfilledId, unresolved }`。

### 流程

1. `ensure(targetLang)` 取得目標語言目錄。
2. 蒐集需回查的紀錄（`resourceId<=0` 或目標目錄查無 `resourceId`）之**原語言集合**，逐一 `ensure(srcLang)`（沿用 `langsById` 模式）。
3. 逐筆（只改 `name` 與 `languageCode`，**不動 `resourceType`**，見 D8）：
   - `resourceId>0` 且目標目錄有名 → `name`=目標名、`languageCode`=targetLang。`converted++`。
   - 否則用該筆「原名 + 原 `languageCode`」目錄 `idByName` 回查真實 id：
     - 查到 → 採用真實 `resourceId`（寫回）、以目標目錄轉名、`languageCode`=targetLang。`converted++`、`backfilledId++`。
     - 查不到 → `name`/`languageCode`/`resourceId` **完全不動**。`unresolved++`。
4. 詳情無須在轉換引擎內處理：轉換改寫 `languageCode` 後，後續 `update()`／unify 流程既有的 `_fetchItemImages` 會以 target 語言補 `detailByLang`，詳情 dialog 自動跟上（D9）。
5. 回傳摘要。

### 日誌

`wish.langconvert.*`：補抓目錄、逐 banner 進度、`unresolved` 數、`backfilledId` 數，帶脫敏 uid。敏感 URL／uid 經 `sanitizeUrl`／`sanitizeUid`。

---

## Part D：設定頁 UI（`lib/pages/settings_page.dart`）

新增「資料語言」區塊（置於語言偏好附近）：

- **下拉選單**：9 語言（母語名）+「未設定」。沿用 `_LocaleDropdown` 視覺，但用**獨立**的 9 語言常數清單（不接 `releasedLocalesProvider`）。`onChanged` → `setDataLanguage(code|null)`。
- 說明文字：點出此設定獨立於 App 介面語言、會把資料統一成該語言。
- **「統一資料語言」按鈕**：
  - `dataLanguage==null` 時禁用。
  - 點擊對所有已知 UID（`GachaStorage.listKnownUids`）逐帳號跑 `convert`，顯示進度（`AppDialog`），完成後顯示摘要（轉換 N 筆／回查補 ID M 筆／K 筆無法轉換）。
  - 失敗（如網路）→ `AppDialog` 顯示錯誤，資料不動。
- 所有 dialog 一律用 `AppDialog`（`size: AppDialogSize.sm/md`）。

---

## Part E：串接更新／匯入（D10）

- `gacha_repository.update()`：抓取＋合併後、存檔前（或存檔後再轉一次落地），若 `dataLanguage!=null` 則 `convert(data, dataLanguage)`。
- importer（`wuwa_tracker_importer` 經 `accounts_import`／import 流程）：匯入合併後若 `dataLanguage!=null` 則對結果 `convert`。
- 首次更新／匯入若 `!seeded` 先播種（Part A）；播種到該次語言時轉換為 no-op。
- 忠實沿用既有失敗三分流／流程（見 `2026-06-03-convene-fetch-failure-flow-design.md`），轉換僅為成功路徑後置；轉換失敗不影響更新／匯入既有結果（D11）。

---

## 錯誤處理

- 目錄補抓網路失敗 → 轉換優雅中止、既有資料**不動**；按鈕情境顯示錯誤，更新／匯入仍回報原本成功結果 + warning log。
- 目錄與紀錄寫檔沿用既有 `.tmp` + rename 原子寫入，避免半寫檔。
- 無法轉換者只計數回報，不視為錯誤、不中斷其他筆。
- 播種語言落在 9 選項外 → 維持未設定、不標記 seeded。

---

## 測試

- **轉換引擎**：真實 id 對應；合成／負值 id 回查成功（採真實 id + 轉名）；回查失敗保持原狀（name/lang/id 不變）；`resourceType` 不被改動；多原語言蒐集；摘要計數正確。
- **語言目錄快取**：save/load round-trip；缺檔→抓取→落地；壞檔回退 null 後重抓。
- **EncoreCatalog**：`nameByKindId` 由 fake API 回應正確填入。
- **設定三態**：pref 不存在／`"none"`／語言碼三種讀寫；`setDataLanguage(null)` 標記 seeded；`seedDataLanguageIfUnset` 僅未 seeded 且 ∈9 才生效。
- **播種**：bootstrap 取最新 `last_updated` 語言；首次更新／匯入播種；語言外維持未設定。
- **串接**：`update`／import 設定後自動轉；`dataLanguage==null` 為 no-op；轉換失敗不影響更新／匯入結果。
- 遵循 `waitForBootstrap()`（避免固定 delay flake，見記憶 flaky-bootstrap-wait-tests）。
- 全部過 `fvm dart format lib/ test/`、`fvm flutter analyze`（No issues found!）、`fvm flutter test`（All tests passed!）。

---

## 開放實作細節（寫計畫時定）

- 轉換在 `update()` 中插入的精確位置（存檔前轉一次，或存檔後重寫；以最少改動既有合併流程為準）。
- 「統一」按鈕多帳號跑轉換的進度呈現粒度（逐帳號／逐 banner）。
