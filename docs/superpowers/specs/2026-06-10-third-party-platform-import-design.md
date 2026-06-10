# 第三方平台歷史紀錄匯入（WuWa Tracker）設計

- 日期：2026-06-10
- 狀態：設計定稿，待寫實作計畫
- 範圍：在設定頁新增「匯入資料（其他平台）」入口，支援匯入 WuWa Tracker 的喚取歷史；架構需可擴充至未來其他平台。

---

## 一、背景與目標

本軟體已有「匯出／匯入備份檔」功能，但只認得**本軟體自己**匯出的 `AccountsBundle` 格式（檔內 `app` 欄位＝`wuthering_waves_convene_gacha_analyzer`）。使用者另有在第三方平台（如 WuWa Tracker）累積的喚取歷史，希望能匯入本軟體。

**目標**：在設定頁新增「匯入資料（其他平台）」按鈕，點擊開啟平台選擇 Dialog，選定平台後選檔匯入；轉換後接回**現有匯入下游**（帳號挑選 → 確認 → 合併去重 → 寫檔 → 補圖），體驗與既有「匯入資料」一致。架構上每個平台是一個可插拔的 importer，新增平台＝加一個 class＋註冊一行。

**非目標（YAGNI）**：
- 不支援 WuWa Tracker 的遺留檔名格式 `wuwatracker-convene-history.json` / `wuwatracker-data.json`（已查證：這些是一年以上未使用的舊版遺留格式，現役 WuWa Tracker 只匯出 `wuwatracker-pulls.json`；真有舊檔使用者再於同一 importer 內依 shape 分支補上）。
- 不支援 WuWa Tracker 的 `wuwatracker-profiles`（個人檔快照，不含抽卡資料）。
- 不為「未來平台」預先抽象超出當前所需的介面。

---

## 二、WuWa Tracker 匯出格式（`wuwatracker-pulls`）

檔名範例：`701146588_2026-06-07_wuwatracker-pulls.json`。

```jsonc
{
  "siteVersion": "v4.7.19",
  "version": "0.0.2",
  "date": "2026-06-07T10:12:24.472Z",   // 匯出產生時間（真 UTC）
  "playerId": "701146588",              // 單一帳號
  "pulls": [
    {
      "cardPoolType": 1,                 // int，落在已知集合 [1,2,3,4,5,6,8,9,10,11]
      "resourceId": 21020023,            // int，角色 4 碼、武器/道具 8 碼
      "qualityLevel": 3,                 // 5 / 4 / 3
      "name": "Originite: Type II",      // 名稱（此檔為英文）
      "time": "2026-05-21T03:03:18+00:00", // ISO8601 UTC instant
      "isSorted": true,                  // 用不到
      "group": 10                        // 批次內序號；僅作同 time 穩定 tiebreak
    }
  ]
}
```

樣本實測：1130 筆、單一 playerId、`cardPoolType` 出現 {1,2,4}、`qualityLevel` ∈ {3,4,5}、`resourceId` 4 碼 121 筆／8 碼 1009 筆。

---

## 三、欄位對映與關鍵決策

本軟體 `GachaRecord` 必填欄位與 WuWa Tracker 的對映：

| `GachaRecord` 欄位 | 來源 | 處理 |
|---|---|---|
| `resourceId` | `resourceId` | 直接帶。 |
| `qualityLevel` | `qualityLevel` | 直接帶。 |
| `name` | `name` | 直接帶。 |
| `cardPoolType`（String） | `cardPoolType`（int） | `int.toString()`；**不在已知集合者整筆跳過並 log**。 |
| `count` | 無 | 補 `1`（喚取 API 通則，恆為 1）。 |
| `time`（DateTime） | `time`（UTC instant） | **`DateTime.parse(iso).add(kWuwaServerUtcOffset)` 取牆鐘 → `formatGachaTime` 成 `YYYY-MM-DD HH:mm:ss`**。見下〈時間還原〉。 |
| `resourceType` | 無 | **存 canonical kind 鍵**：4 碼→`kItemKindCharacter`、8 碼→`kItemKindWeapon`。見下〈resourceType〉。 |
| `languageCode` | 無 | 預設 `'en'`。見下〈languageCode〉。 |

### 時間還原（核心決策）

WuWa Tracker 的 `time` 是 UTC instant；本軟體存的是官方喚取 API 回的**伺服器在地牆鐘字串**（`YYYY-MM-DD HH:mm:ss`，無時區，原樣搬運、不轉換）。還原規則：

> **一律 `instant + 8h` 取牆鐘**，常數 `kWuwaServerUtcOffset = Duration(hours: 8)`。

**依據（已查證，非「亞洲假設」）**：鳴潮為**全球統一伺服器時間 = 中國標準時間 CST（UTC+8）**，五服（Asia/America/Europe/SEA/HMT）同一瞬間重置。這與原神「各服各自時區」本質不同——故喚取時間戳對**所有區服玩家**都是 CST，與玩家地理位置無關。因此 `+8` 對全球玩家皆正確；反而「匯入時讓使用者選地理區服」會弄錯（選非亞洲區會加錯 offset）。詳見記憶 `wuwa-unified-cst-server-time`。

**驗證**：以本樣本對官方 API 參考資料逐秒往返吻合（源能迅刀 3★ `T03:03:18Z`＋8＝`11:03:18`；達妮婭 5★ `T02:39:03Z`＋8＝`10:39:03`）。

**殘留假設與安全網**：唯一無法 100% 驗證者為「WuWa Tracker 以伺服器 CST（而非瀏覽器時區）編碼 UTC」——已由真實檔逐秒往返佐證其為正確 CST 處理。安全網：offset 抽成**單一具名常數** `kWuwaServerUtcOffset`，並於匯入後 log 時間範圍／跨度作合理性檢查；萬一日後出現非亞洲服偏移回報，一行可改。**不加任何時區選擇 UI（YAGNI）。**

### resourceType（存 canonical kind 鍵）

WuWa Tracker 無 `resourceType`。**已驗證**：全 lib 內 `GachaRecord.resourceType` **只透過 `itemTypeKeyOf(r, index)` → `itemTypeKeyLabel(key, l)` 消費，從不原樣顯示**（型別聚合 `computeGachaStats`、detail dialog 的 `isCharacter`／encore URL／capture kind 皆走此路）。`itemTypeKeyOf` 的歸屬為 `index.lookupImage(resourceId)?.kind ?? r.resourceType`——即 encore catalog 有分類就用 encore 的 `kind`，否則 fallback 回 `resourceType`。

故最佳存法為**直接存 canonical kind 鍵**（`item_type_kind.dart` 既有常數）：

- 4 碼 `resourceId` → `kItemKindCharacter`（`'kind:character'`）
- 8 碼 `resourceId` → `kItemKindWeapon`（`'kind:weapon'`）

如此即使 encore 尚未分類，fallback 仍是 canonical 鍵：`itemTypeKeyLabel` 會套正確在地化標籤（`l.kindCharacter`／`l.kindWeapon`），`isCharacter` 判斷正確，統計分組與 encore URL 也正確——且**語言無關**（不依 `languageCode`，無需臆測各語系型別字串）。少數 8 碼「道具」（如塵雲旋臂）在 encore 分類前暫歸武器，**匯入後補圖管線跑 encore 分類即修正為 `kItemKindItem`**。此 fallback **不影響保底／合併／icon**（合併 `recordsEqual` 刻意排除 `resourceType`；icon 靠 `resourceId`）。

> 註：`GachaRecord.resourceType` 的 dartdoc 原述「角色／武器／道具，隨 languageCode 變化」（官方 API 來源語意）。第三方匯入存 canonical 鍵屬刻意例外，與實際唯一消費點（`itemTypeKeyOf`／`itemTypeKeyLabel`，本就以 canonical 鍵為主要分支）一致；實作時於 dartdoc 補一行說明此 fallback 允用 canonical 鍵。

### languageCode

WuWa Tracker 無 `languageCode`。預設 `'en'`（此檔名稱為英文、亦 Tracker 常見預設）。**僅影響顯示語言與 encore 詳情挑 `detailByLang`；不影響統計／合併／icon**（合併刻意排除 `languageCode`；icon 與型別聚合皆語言無關）。輕量 CJK 偵測列為非目標。

### 排序

依 `cardPoolType` 分組後，每池**依 `time` 由新到舊排序**（對齊本軟體存檔「由新到舊」慣例）；同 `time` 以 WuWa Tracker 陣列順序為穩定 tiebreak。同 `time` 內順序不影響統計與合併（`mergeBackupRecords` 的 `capMultiplicity` 已容忍同十連順序不一致）。

---

## 四、架構

### 取向決策

採 **Adapter → `AccountsBundle` → 接回現有下游**：每個平台只負責「外部格式 → 本軟體 `AccountsBundle`」，之後完全重用既有匯入下游（帳號挑選 → 確認 → `importAccountsAndFetchItemImages`，含 `mergeBackupRecords` 合併去重、寫檔、補圖）。

理由：最大化重用（合併演算法、去重、補圖、picker、確認、進度 dialog 全部現成），新增面積最小，`parse` 是純函式易測；天生支援未來多帳號平台（picker 本就支援多帳號）。否決「每平台各自完整流程」（大量重複、違反嚴禁重造輪子）。

### 可擴充抽象

新檔 `lib/services/platform_import.dart`：

```dart
/// 第三方平台匯入器：把該平台的匯出檔轉成本軟體的 AccountsBundle。
abstract interface class PlatformImporter {
  /// 穩定識別鍵（如 'wuwa_tracker'）。
  String get id;
  /// 在地化平台顯示名。
  String displayName(AppLocalizations l);
  /// 選填的清單副標（如來源網域、檔案格式提示）。
  String? subtitle(AppLocalizations l);
  /// 平台選擇清單列的前置 icon。
  IconData get icon;
  /// 可接受的副檔名（如 ['json']）。
  List<String> get fileExtensions;
  /// 解析檔案內容 → AccountsBundle。
  /// 非此平台格式丟 [ForeignBundleException]；結構／型別錯丟 [FormatException]。
  AccountsBundle parse(String content);
}

/// 已支援平台清單（新增平台＝加一個 class＋在此註冊）。
const List<PlatformImporter> kPlatformImporters = [WuwaTrackerImporter()];
```

刻意**重用既有例外型別**（`ForeignBundleException`／`FormatException`），使 UI 錯誤處理可與原生匯入共用。

### `WuwaTrackerImporter`

新檔 `lib/services/importers/wuwa_tracker_importer.dart`，`parse(content)`：

1. `jsonDecode`；失敗 → `FormatException`。
2. 非 `Map` 或缺 `pulls`（List）／`playerId`（String）→ **`ForeignBundleException`**（即「此檔不是 WuWa Tracker 匯出檔」的判別）。
3. 逐筆 `pulls` → `GachaRecord`（依〈三〉欄位對映；未知 `cardPoolType` 整筆跳過並計數 log）。
4. 依 `cardPoolType` 分組 → `Map<String, List<GachaRecord>>`，每池由新到舊排序。
5. 組 `BannerStorage(playerId, languageCode:'en', lastUpdated: 解析自 `date`（失敗則 `DateTime.now().toUtc()`）, banners)`。
6. 包成 1 個 `ExportedAccount` → `AccountsBundle(exportedAt: `date`, appVersion:'', lastActiveUid: playerId, accounts:[account])`。

`kWuwaServerUtcOffset` 常數置於本 importer 檔內（單一來源）。

---

## 五、資料流

```
設定頁「匯入資料（其他平台）」按鈕
  → showPlatformPickerDialog()              // 單選平台清單
  → openFile(extensions: platform.fileExtensions)
  → file.readAsString()                     // 讀檔（失敗 → importReasonUnreadable）
  → platform.parse(content)                 // 外部格式 → AccountsBundle
        ForeignBundleException → importReasonNotPlatformFile(platform name)
        FormatException        → importReasonInvalidFormat
  → _runBundleImport(ctx, ref, bundle)      // ★ 與原生匯入共用的下游
        → showAccountsPickerDialog(...)
        → 過濾 bundle（依勾選 uid）
        → showConfirmDialog(...)            // incoming／conflicts／preserved
        → importAccountsAndFetchItemImages(jsonEncode(filteredBundle.toJson()))
                                            // 合併去重 + 寫檔 + 補圖；進度 dialog 由 app_shell 既有 ref.listen 接管
```

註：`AccountsBundle.toJson()` 會寫 `app: accountsBundleAppId`，故下游 re-parse 時被當原生備份信任，不會被 foreign 擋掉。

---

## 六、UI

### 設定頁按鈕

`lib/pages/settings_page.dart` 的 `_DataManagement` 之 `Wrap` 內，於現有「匯入資料」旁新增一顆 `OutlinedButton.icon`：

- label：`l.settingsImportOtherPlatform`（「匯入資料（其他平台）」）
- icon：`Icons.cloud_sync_outlined`（或同風格者）
- `onPressed`：`progress != null ? null : () => _importFromPlatform(ctx, ref)`（與既有匯入一致，匯入進行中停用）

### 平台選擇 Dialog

新檔 `lib/widgets/dialogs/platform_picker_dialog.dart`，`showPlatformPickerDialog(context) → Future<PlatformImporter?>`：

- 用 `AppDialog`（`size: AppDialogSize.sm`），不自行手寫 `AlertDialog`。
- `ListView`（內容自帶捲動，`scrollable: false`）列出 `kPlatformImporters`，每列 `ListTile`：`leading`＝`importer.icon`、`title`＝`importer.displayName(l)`、`subtitle`＝`importer.subtitle(l)`。
- **單選導覽式**：點一列即 `Navigator.pop(context, importer)`。
- actions：取消鈕 `Navigator.pop(context)`（回 null）。
- 標題：`l.platformPickerTitle`（「選擇匯入來源平台」）。

---

## 七、共用重構（嚴禁重造輪子）

把現有 `_import`（`settings_page.dart:544-637`，自「Picker」起至 `importAccountsAndFetchItemImages` 止）抽成：

```dart
/// 拿到（已解析的）[bundle] 後的共用匯入下游：帳號挑選 → 確認 → 寫入＋補圖。
Future<void> _runBundleImport(BuildContext ctx, WidgetRef ref, AccountsBundle bundle);
```

- `_import`：維持讀檔＋`importAccounts` 解析（含其三種既有錯誤對映），解析成功後改呼叫 `_runBundleImport(ctx, ref, bundle)`。
- `_importFromPlatform`：`showPlatformPickerDialog` → `openFile` → 讀檔 → `platform.parse`（錯誤對映見〈五〉）→ `_runBundleImport(ctx, ref, bundle)`。

兩者解析階段各自處理錯誤訊息差異，下游完全共用。

---

## 八、l10n（只改核心四 ARB：en／zh／zh_Hans／ja，對齊既有慣例）

新增字串：

| key | en | zh（繁中台灣） |
|---|---|---|
| `settingsImportOtherPlatform` | `Import data (other platforms)` | `匯入資料（其他平台）` |
| `platformPickerTitle` | `Select a source platform` | `選擇匯入來源平台` |
| `platformWuwaTracker` | `WuWa Tracker` | `WuWa Tracker` |
| `platformWuwaTrackerSubtitle` | `wuwatracker.com・pulls JSON` | `wuwatracker.com・pulls JSON` |
| `importReasonNotPlatformFile`（帶 `{platform}`） | `This file is not a valid {platform} export` | `此檔案不是有效的 {platform} 匯出檔` |

沿用既有：`settingsImportFailed`、`settingsImportSelectTitle`、`confirmContinue`、`settingsImportConfirm*`、`confirmImport`、`importReasonInvalidFormat`、`importReasonUnreadable` 等。改 ARB 後跑 `fvm flutter gen-l10n`。

---

## 九、Logging（對齊 CLAUDE.md）

`Logger('wish.import.platform')`（對齊既有 `wish.*` 樹）。關鍵節點：

- 進入平台匯入：平台 id。
- 解析結果：總筆數、各池筆數、跳過的未知 `cardPoolType` 筆數、**time 範圍（min/max）與跨度**（安全網合理性檢查）。
- 解析失敗分支：`ForeignBundleException`／`FormatException`／讀檔錯，帶足夠 context（脫敏後的 playerId 等）。

敏感資料經既有 `sanitizeUid` 等脫敏後再寫入。

---

## 十、邊界與已知取捨

- **格式範圍**：v1 僅 `wuwatracker-pulls`（現役唯一抽卡匯出格式，已涵蓋所有現役使用者）。遺留 `convene-history`／`data` 不支援；遇不認得 shape 給明確錯誤。
- **時間殘留假設**：見〈三・時間還原〉安全網。
- **與官方擷取共存**：time 精準還原成 CST 牆鐘，`recordsEqual`（time＋id＋quality＋count）能正確對齊，匯入與官方擷取同抽不重複（走既有 `mergeBackupRecords` 雙向合併）。
- **單帳號**：WuWa Tracker 檔為單 `playerId`；picker 仍走多帳號流程（只是清單一筆），與既有一致。

---

## 十一、測試計畫

- **`WuwaTrackerImporter.parse` golden 測試**（用真實檔脫敏縮樣為 fixture）：
  - banners 依 `cardPoolType` 正確分組、各池筆數正確。
  - time `+8` 還原逐秒正確（至少一筆 5★／一筆 3★ 對照）。
  - `count` 補 1；`resourceType` 位數推定（4 碼→角色、8 碼→武器）；`languageCode`＝`'en'`。
  - 未知 `cardPoolType` 筆數被跳過。
  - 每池由新到舊排序。
- **例外**：非 WuWa Tracker 物件／缺 `pulls`／缺 `playerId` → `ForeignBundleException`；壞 JSON → `FormatException`。
- **重構回歸**：`_runBundleImport` 抽出後，既有匯入相關測試需續綠。
- 提交前：`fvm dart format lib/ test/`、`fvm flutter analyze`（`No issues found!`）、`fvm flutter test`（`All tests passed!`）全綠。

---

## 十二、驗收條件

1. 設定頁出現「匯入資料（其他平台）」按鈕，點擊開啟單選平台 Dialog（含 WuWa Tracker 一項）。
2. 選 WuWa Tracker → 選 `wuwatracker-pulls.json` → 走帳號挑選＋確認 → 成功匯入，紀錄出現於對應卡池，時間正確（CST 牆鐘）、保底／統計正確。
3. 匯入後補圖管線正常分類型別與抓 icon。
4. 餵非 WuWa Tracker 檔／壞檔 → 對應在地化錯誤訊息，不崩潰。
5. 新增第二個假想平台僅需「加一個 `PlatformImporter` class＋註冊一行」即可出現在 Dialog（架構可擴充性自證）。
6. analyze／test／format 全綠。
