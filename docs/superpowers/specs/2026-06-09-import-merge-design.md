# 匯入資料改為合併（非覆蓋）設計

## 背景與目標

目前「匯入資料」採**整帳號覆蓋**：對備份檔裡的每個帳號直接 `storage.save(account.data)`，用備份的整包 `BannerStorage` 換掉該 playerId 的磁碟檔，完全不去重。同一 playerId 重複匯入 → 本機既有資料被整包蓋掉；本機有、備份沒有的 playerId 則保留不動。匯入前還要求使用者打字輸入 `IMPORT` 才能確認（破壞性操作的強警告）。

本設計把匯入改為**永遠合併、非破壞性**：匯入是純加法，本機既有的喚取紀錄絕不會因匯入而消失。移除覆蓋模式（不提供切換）、移除打字閘。

本功能對齊姊妹專案（原神版）已上線的同名功能，**使用者體驗層（流程、訊息、badge、計數回報、偏好策略）力求與原神版一致**，讓跨 app 使用者感覺相同。唯一無法照搬的是合併原語的內部實作：原神版以 `GachaRecord.id`（HoYoverse 19 碼遞增流水號）做 union 去重，但**鳴潮喚取紀錄沒有唯一 id、同一十連的多筆 `time` 完全相同**，故鳴潮改用既有 `record_merge.dart` 的**有序序列對齊**去重。

**成功條件**

- 既有 playerId 重複匯入時，本機與備份的喚取紀錄合併去重，兩邊都保留（本機紀錄絕不消失）。
- 本機有、備份沒有的 playerId、紀錄、偏好一律不受影響。
- 匯入流程改為非破壞性語意（移除「輸入 IMPORT」強確認），並回報「新增 / 已存在」筆數。
- `fvm flutter analyze` 全綠、`fvm flutter test` 全綠。

## 決策摘要

| 面向 | 決策 |
|------|------|
| 衝突策略 | 永遠合併（去重），移除覆蓋；不提供切換 |
| 去重方式 | **有序序列對齊**（鳴潮無唯一 id，沿用 `record_merge.dart` 的對齊哲學）；非 union-by-id |
| 重疊那筆保留哪份 | **保留本機（local）那筆**（與既有更新流程 `mergeOrderedRecords` 一致；鳴潮逐筆顯示語言以 `GachaRecord.languageCode` 為準，不需 lang 回填） |
| `lastUpdated` | 合併後取兩者較新者 |
| 帳號層 `languageCode` | 取較新那次擷取的（`lastUpdated` 較新的一方） |
| 別名 | 只補空缺：本機該 playerId 已有別名則保留；僅當本機無別名且備份非空時採用備份；備份空別名不清掉本機別名 |
| 上次選取帳號（active） | 本機已有有效 active 則保留；否則採用備份 `lastActiveUid`（須存在）；再否則 fallback 到 `newOrder.first`（皆無則 null） |
| 帳號顯示順序（`uidOrder`） | 本機既有順序原封不動；這次新出現的 playerId 依備份檔順序接在最後 |
| 確認流程 | 移除打字閘，改一般確認；badge／文案改合併語意；非 danger 配色 |
| 結果回報 | 顯示「已合併 N 個帳號：新增 X 筆、已存在 Y 筆」 |
| i18n 範圍 | 只手改核心 4 個 ARB（`app_zh` / `app_en` / `app_ja` / `app_zh_Hans`），其餘 26 個 Crowdin 空殼交 pipeline |

## 設計

### 1. 合併原語（兩層）

鳴潮的合併拆成「記錄級」與「帳號級」兩層，鏡像原神版的呼叫點（`localBefore.mergeWith(incoming)`），但記錄級改用對齊去重。

#### 1a. 記錄級：`record_merge.dart` 新增 `mergeBackupRecords`

在 `lib/services/record_merge.dart` 新增純函式（複用既有 `recordsEqual`、private `_findAlignment`，**不動** `mergeOrderedRecords`）：

```dart
/// 將兩份同 UID、同卡池的喚取紀錄（皆由新到舊）做非破壞性雙向合併。
List<GachaRecord> mergeBackupRecords(
  List<GachaRecord> local,
  List<GachaRecord> incoming,
)
```

**為何不能直接用 `mergeOrderedRecords`**：後者是**單向**的——假設 `fresh` 涵蓋到 `existing` 最新一筆、且 `fresh` 較新；對不到錨點時回傳 `fresh`、**丟掉另一段**。匯入的「還原舊備份」情境剛好相反（匯入的較舊），直接套用會把匯入的舊資料整段丟掉，違反「絕不漏資料」。

**演算法**（保留 `local` 整段，只把 `incoming` 的「更新的頭」與「更舊的尾」接上）：

```
若 local 空 → 回 incoming 副本；若 incoming 空 → 回 local 副本

// Case 1：local 的開頭出現在 incoming 中（incoming 較新，或頭部對齊）
for anchorLen = min(local.length, 3) downTo 1:
    j = _findAlignment(incoming, local, anchorLen)        // local 開頭落在 incoming[j]
    if j != null:
        overlapLen = min(local.length, incoming.length - j)
        if _overlapEquals(incoming, j, local, 0, overlapLen):   // ← 逐筆驗證整段重疊
            olderStart = min(j + local.length, incoming.length)
            return [...incoming.sublist(0, j), ...local, ...incoming.sublist(olderStart)]

// Case 2：incoming 的開頭出現在 local 中（incoming 較舊，或被 local 包含）
for anchorLen = min(incoming.length, 3) downTo 1:
    i = _findAlignment(local, incoming, anchorLen)        // incoming 開頭落在 local[i]
    if i != null:
        overlapLen = min(incoming.length, local.length - i)
        if _overlapEquals(local, i, incoming, 0, overlapLen):
            olderStart = min(local.length - i, incoming.length)
            return [...local, ...incoming.sublist(olderStart)]

// Case 3：對不到「連續」重疊（不相交／重疊中段缺筆／非連續輸入）→ 改用 gap-tolerant
// 序列合併（見 1c）：以 LCS 找共同骨幹去重、只補各自真正缺的筆、依 time 交錯，永不重複。
return _mergeBySupersequence(local, incoming);
```

`_overlapEquals(a, aStart, b, bStart, len)` = 對 `k ∈ [0, len)` 全部 `recordsEqual(a[aStart+k], b[bStart+k])`。

**設計要點（皆來自對抗審查發現）**：

- **逐筆驗證整段重疊**：錨點只比對開頭 1~3 筆，命中後**必須**驗證整段重疊逐筆相等才縫合，否則退而試更短錨點。避免「短錨點在重複片段誤命中錯位置」導致縫錯（漏或重）。
- **保留 `local` 整段**：兩個 Case 都讓 `local` 原封出現在輸出，只把 `incoming` 不重疊的兩端接上 → 對本機**結構性不漏**，且重疊那筆自然保留本機版本（與既有 `mergeOrderedRecords` 行為一致）。
- **containment 正確**：`olderStart` 的 `min(..., length)` clamp 同時涵蓋「`incoming` 更舊（接尾）」與「`incoming` 被 `local` 完全包含（接空）」兩種。
- **快路徑 + gap-tolerant fallback（不漏且不重）**：Cases 1-2 是 O(n) 快路徑，處理「連續重疊」（自家連續匯出檔恆走這裡）。一旦對不到連續重疊（不相交、或重疊中段缺筆、或非連續輸入），落到 Case 3 的 [1c] LCS 序列合併——即使中段有洞也能去重共同筆、只補真正缺的、永不重複，故 `added`／`duplicate` 計數正確（不會「整批算新增」）。對 WuWa 這種無 id 的脆弱資料是 defense-in-depth。
- **絕不做全域時間排序**：同一十連 10 筆共用同一 `time`，全域 sort 會打亂十連內順序、破壞日後對齊。Cases 1-2 保留 `local` 整段；Case 3 的 SCS 沿兩份既有的「新到舊」子序列順序縫合，僅在 LCS 不偏好任一邊的平手點以 `time` 決定先後（同 time 保留本機），不做全域排序。

#### 1c. gap-tolerant fallback：`_mergeBySupersequence`（private，同檔）

當 Cases 1-2 對不到「連續」重疊時，`mergeBackupRecords` 不再盲目把兩段接起來（會在重疊中段缺筆時複製共同筆、把整批算成新增），改呼叫此 private 函式做「最短共同超序列」(SCS) 合併：

```dart
List<GachaRecord> _mergeBySupersequence(
  List<GachaRecord> local,
  List<GachaRecord> incoming,
)
```

- 兩份皆由新到舊、且同為某條真實歷史的子序列。步驟：(1) 以 `recordsEqual` 跑 LCS DP（`dp[i][j] = LCS(local[i..], incoming[j..])`），回溯產生 SCS（共同筆取本機那份、各自獨有的筆按子序列順序插入、LCS 平手點以 `time` 較新者先、同 time 保留本機）；(2) **多重數封頂**：對每個指紋（time/resourceId/qualityLevel/count）將輸出次數上限設為 `max(在 local 的次數, 在 incoming 的次數)`。
- 性質：每個指紋的輸出數量 = `max(local 次數, incoming 次數)` → 任一來源的紀錄「數量」都不漏（**不漏**），且**無條件不重複**（SCS 為同時滿足兩序列順序而生的多餘複本被封頂移除）。`added = 輸出筆數 − local 筆數` 恰為「incoming 有而 local 沒有的筆數」，不會虛報「整批新增」。
- 兩份若對「同一十連內重複道具」的順序不一致（只可能來自手改／第三方），無法同時滿足兩種順序 → 以本機順序為準、取不重複的那份（仍不漏任何指紋的數量）。
- 對不相交（LCS 為 0）退化為依 `time` 交錯接合（等同舊 Case 3 的「較新在前」，但不複製）。
- 複雜度 O(n·m)：僅在「非連續」這個少見 fallback 才付出（自家連續匯出檔走 Cases 1-2）；匯入為一次性操作，可接受。落到此路徑時寫一筆 `info` log（帶兩段長度）供診斷。

#### 1b. 帳號級：`BannerStorage.mergeWith`

在 `lib/models/banner_storage.dart` 新增（純函式、可獨立單測）：

```dart
/// 將 [incoming]（同一 playerId 的另一份存檔）合併進本份，回傳新的 [BannerStorage]。
/// 逐 banner 以 [mergeBackupRecords] 對齊去重；本機既有紀錄一律保留。
/// [lastUpdated] 與 [languageCode] 取較新者（incoming 的 lastUpdated 較新時採 incoming）。
BannerStorage mergeWith(BannerStorage incoming)
```

行為：

- **逐 banner（cardPoolType）union**：兩邊 `banners` 的 key 取聯集；每個 banner 內呼叫 `mergeBackupRecords(local[key] ?? const [], incoming[key] ?? const [])`。
- **`lastUpdated`**：取 `this.lastUpdated` 與 `incoming.lastUpdated` 較新者。
- **`languageCode`**：`incoming.lastUpdated` 較新時採 `incoming.languageCode`，否則保留本機；逐筆顯示語言仍以 `GachaRecord.languageCode` 為準，本欄位僅為帳號級擷取語言記錄。
- `playerId` 不變。

> 註：`record_merge.dart` 既有的 `mergeOrderedRecords`（更新流程用，靠網路分頁掃到對齊點即停的增量抓取）**維持原樣、不在本次改動範圍**（YAGNI、控制 blast radius）。匯入與更新的合併語意不同，故各用各的原語。

### 2. `_runImport` 改寫（`lib/state/gacha_repository.dart`）

**紀錄合併**（帳號迴圈約 `740-758`）：把「直接覆蓋」改為「合併」——

- 備份的 playerId 本機**沒有** → 直接 `storage.save(account.data)`（等同合併進空存檔）。
- 備份的 playerId 本機**已有** → `final toSave = localBefore.mergeWith(account.data); await storage.save(toSave);` 並以 `toSave` 更新 `newByUid[playerId]`。
- 保留現有 per-account `try/catch`：單一 playerId 寫入失敗 → 加入 `failedUids`、其餘帳號繼續；保留 `ref.mounted` 檢查與提前返回。

**新增 / 已存在計數**（用既有 `BannerStorage.allRecords` getter；公式演算法無關，沿用原神版）：

- 每帳號：`added = toSave.allRecords.length - (localBefore?.allRecords.length ?? 0)`（合併非破壞且去重正確 → 恰等於「備份紀錄中本機原本沒有的數量」）；`duplicate = account.data.allRecords.length - added`。
- 新 playerId（本機無）時 `localBefore` 為 null → `added` ＝ 備份全部、`duplicate` ＝ 0。
- 累加為整體 `addedRecords` / `duplicateRecords`；三處 `ImportResult(...)` 建構（兩處 unmount 提前返回約 `744-748`、`800-804`，與最終返回約 `818-822`）一併帶當前累計值。

**偏好「只補空缺」**：

- **別名**（約 `761-770`）：**移除**鳴潮現有「備份空別名 → `mergedAliases.remove(playerId)`」的覆蓋邏輯。改為：僅當 `currentSettings.uidAliases` 不含該 playerId（本機無別名）且備份別名非空時，才 `mergedAliases[playerId] = a`；本機已有別名則保留不動。
- **`uidOrder`**（約 `772-780`）：**改掉**現有「匯入順序優先」（`[...exportedOrder, ...remaining]`）。改為本機既有順序原封不動，這次新出現的 playerId 依備份順序接最後：

  ```dart
  final localOrder = currentSettings.uidOrder; // 本機既有順序原封不動
  final localSet = localOrder.toSet();
  final appended = bundle.accounts
      .where((a) => !failed.contains(a.data.playerId))
      .map((a) => a.data.playerId)
      .where((uid) => !localSet.contains(uid))
      .toList(growable: false);
  final newOrder = [...localOrder, ...appended];
  ```

- **active playerId**（約 `782-792`）：**改掉**現有「優先用備份 `lastActiveUid`」。改為本機目前若已有有效 active（`state.activeUid != null && newByUid.containsKey(state.activeUid)`）→ 保留本機；否則才採用備份的 `lastActiveUid`（仍須存在於 `newByUid`）；再否則 fallback 到 `newOrder.first`；皆無則 null。此選擇在所有 per-account `save()` 與 `applyImportedPreferences()` 之後才定案。

**收尾 log**（約 `813-817`）：原本印 `records=$totalRecords`，改印 `added=$addedRecords duplicate=$duplicateRecords`；含 playerId 的 log 一律經 `sanitizeUid` 脫敏（對齊 CLAUDE.md log 規範）。`importAccountsAndFetchItemImages`（約 `620-707`）若另有印 totalRecords 的 log，同步改欄位。

### 3. 確認流程改非破壞性

涉及 `lib/pages/settings_page.dart`（`_import`）、`lib/widgets/dialogs/confirm_dialog.dart`、`lib/widgets/dialogs/accounts_picker_dialog.dart`。

**共用一般確認 dialog（不重造輪子）**：`settings_page.dart` 內 `_refetchAll`（約 `766-795`）與 `_clearGallery`（約 `798-841`）已各自手寫一份「`showDialog<bool>` + `AppDialog` + 取消/確認」的無打字確認（兩者目前都用 danger 紅）。依 CLAUDE.md「抽出來共用」，在 `confirm_dialog.dart` 新增一支抽取自這兩處的 `showConfirmDialog`，並把 `_refetchAll`／`_clearGallery` 改呼叫它（兩者傳 `isDanger: true` 維持現有紅色，不改其視覺）：

```dart
Future<bool?> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String body,
  required String cancelLabel,
  required String confirmLabel,
  IconData? confirmIcon,
  bool isDanger = false, // true → stateDanger 紅；false → 中性（預設）配色
})
```

匯入確認改用 `showConfirmDialog(..., isDanger: false)`，取代原本的 `showConfirmTypeDialog(expectedText: 'IMPORT')`（約 `607-615`）。`settings_page.dart` 另兩處危險打字確認——`_clearActive`（約 `632`，打 uid）與 `_clearAll`（約 `648`，打 `DELETE`）——維持打字閘，不動。

**Picker badge**：既有 playerId 的 badge 文字由 `settingsImportOverwriteBadge`（「覆蓋」）改為 `settingsImportMergeBadge`（「合併」）。`accounts_picker_dialog.dart` 的 `_PickerRow`（約 `217-232`）目前把 badge 底色／文字硬編為 `tokens.stateDanger`；由於 badge 唯一消費者就是這個匯入流程（export picker 不帶 badge），直接把該處改為中性 token `tokens.accentPrimary`，不另加 enum 參數（YAGNI）。同檔 `AccountPickerEntry.badge` 的 dartdoc（約 `32-33`「可選的紅色警示徽章文字…」）改為中性描述。

**內文改寫**（`_import` 約 `581-621`）：

- 前言改合併語意（改寫 `settingsImportConfirmIntro`：「即將匯入…」→「即將合併…」），沿用既有 `• playerId (別名)` 清單格式。
- 衝突區塊：把「覆蓋」標頭（`settingsImportConfirmOverwriteHeader`）改為新 key `settingsImportConfirmMergeHeader`（「下列帳號將與本機資料合併，不會刪除既有紀錄：」），列出衝突 playerId。
- 移除危險警告句（刪 `_import` 對 `settingsImportConfirmWarning` 的引用與該 ARB key）。
- 保留「未匯入的帳號維持不動」footer（`settingsImportConfirmPreserveFooter`）與「無資料衝突」（`settingsImportConfirmNoConflict`）。

### 4. 結果回報「新增 / 已存在」（`lib/state/update_progress.dart` 與 `lib/widgets/update_progress_dialog.dart`）

- `ImportResult` 欄位（約 `49-65`）改為：`successAccounts`、`addedRecords`、`duplicateRecords`、`failedUids`（移除 `totalRecords`）。`_runImport` 三處建構一併改用新欄位；計數公式見段 2。
- `progressDoneImportSummary`（呼叫點 `update_progress_dialog.dart` 約 `229-235`）由 2 個 placeholder（accounts、records）改為 3 個（successAccounts、addedRecords、duplicateRecords），文案如「已合併 {accounts} 個帳號：新增 {added} 筆、已存在 {duplicate} 筆」。
- `progressPartialImportFailed`（失敗 playerId 警示，約 `249-258`）維持不動。

### 5. 受影響檔案清單

| 檔案 | 變更 |
|------|------|
| `lib/services/record_merge.dart` | 新增 `mergeBackupRecords` + `_overlapEquals` helper（複用 `_findAlignment`/`recordsEqual`；不動 `mergeOrderedRecords`） |
| `lib/models/banner_storage.dart` | 新增 `mergeWith`（逐 banner 呼叫 `mergeBackupRecords`、`lastUpdated`/`languageCode` 取較新） |
| `lib/state/gacha_repository.dart` | `_runImport`：紀錄合併、added/duplicate 計數、偏好只補空缺、`uidOrder` append、active 保留本機、log 改欄位；`importAccountsAndFetchItemImages` log 若有 totalRecords 同步改 |
| `lib/state/update_progress.dart` | `ImportResult` 欄位改版 |
| `lib/widgets/update_progress_dialog.dart` | 改用新 `ImportResult` 欄位與新 `progressDoneImportSummary` 簽名 |
| `lib/widgets/dialogs/confirm_dialog.dart` | 新增 `showConfirmDialog`（無打字閘、`isDanger` 參數） |
| `lib/pages/settings_page.dart` | `_import`：badge 改合併、改用 `showConfirmDialog`、內文改寫；`_refetchAll`／`_clearGallery` 改用抽取後的 `showConfirmDialog` |
| `lib/widgets/dialogs/accounts_picker_dialog.dart` | `_PickerRow` badge 改中性 token、`AccountPickerEntry.badge` dartdoc 改中性描述 |
| `lib/l10n/app_zh.arb` + `app_en` / `app_ja` / `app_zh_Hans` | 見 i18n 段 |

## 錯誤處理

- 合併為純記憶體運算，唯一 I/O 風險在 `storage.save`，維持既有 `_atomicWrite`（寫 `.tmp` 後 rename 到目標；rename 失敗則該帳號磁碟資料不變、`.tmp` 殘留）與 per-account `try/catch`。
- 本機檔案損毀的容錯維持現狀：合併以已載入記憶體的 `state.byUid` 為來源，不重讀磁碟。
- `ref.mounted` 檢查與提前返回路徑全部保留，且提前返回也回傳正確的 `addedRecords` / `duplicateRecords` 累計值。
- 合併原語對「非同一段歷史／損毀輸入」採「保留兩段 + warning log」（不漏優先），不靜默丟資料。

## 測試計畫

- **`mergeBackupRecords` 單元測試**（加在既有 `test/services/record_merge_test.dart`）：
  - incoming 較新（接頭）；incoming 較舊（補尾）；containment（一段包另一段，兩個方向）；完全不相交（退化為依 time 交錯、不複製）；partial 十連邊界（重疊落在同 `time` 連續段中段）；同十連同 `time` 多筆（含同道具重複，多重數正確、不誤併）；空 local／空 incoming。
  - **gap-tolerant fallback（`_mergeBySupersequence`）**：重疊中段缺一筆（incoming 少 t8）→ 去重不複製、共同筆只一份；同十連 incoming 缺幾筆 → 補齊不複製；「錨點對齊但整段驗證失敗」→ 退回序列合併、去重（取代舊版「兩段全保留」的長度斷言）。
  - **不漏資料性質測試**：構造重疊／含洞／不相交輸入，斷言 `local` 與 `incoming` 皆為輸出的子序列、輸出為 newest→oldest、且長度 = `local + incoming − 共同筆`（不重複）。
- **`_runImport` gap 計數測試**（`test/state/gacha_repository_test.dart`）：既有 UID 重匯入一份「重疊中段缺筆」的池 → `addedRecords` 只計真正新筆、無「整批新增」、存檔無複製。
- **`BannerStorage.mergeWith` 單元測試**（加在既有 `test/models/banner_storage_test.dart`）：banner key 聯集（其中一邊缺某卡池）；逐 banner 走 `mergeBackupRecords`；`lastUpdated` 取較新；`languageCode` 隨較新方；空本機 / 空備份邊界。
- **`_runImport`（`debugImportOnly`）測試**（`test/state/gacha_repository_test.dart`，改既有四個匯入測試到合併語意 + 新增）：
  - 既有 playerId **合併不覆蓋**：本機某池對齊重疊、補上備份新筆 → 本機原紀錄全在、`addedRecords`/`duplicateRecords` 計數正確。
  - 本機獨有 playerId 完全不動。
  - 備份新 playerId 加入，且 `uidOrder` append 在最後、本機既有順序不變。
  - 別名只補空缺：本機已有別名不被備份覆蓋；備份空別名不清掉本機別名。
  - active 三層 fallback：(1) 本機有效 → 保留本機；(2) 本機無效、備份有效 → 採用備份；(3) 兩者皆無、`newOrder` 非空 → `newOrder.first`。
  - 需改寫的既有測試：`importAccounts: per-UID overwrite preserves non-imported accounts`（約 `969-1053`）、`importAccounts: uidOrder merges imported order first, then remaining`（約 `1055-1122`）、`importAccounts: bundle lastActiveUid switches active to it when imported`（約 `1189-1247`）；`storage write failure marks UID failed and skips it`（約 `1124-1187`）視欄位調整。任何斷言 `ImportResult.totalRecords` 之處改為 `addedRecords`/`duplicateRecords`。
- **Widget 測試**：
  - `test/widgets/dialogs/confirm_dialog_test.dart`：新增 `showConfirmDialog`（不需打字即可確認、`isDanger` 配色、取消回 false）測試；既有 `showConfirmTypeDialog` 測試不動。
  - `test/widgets/dialogs/accounts_picker_dialog_test.dart`：badge 文案斷言（約 `162-167`，找 `'覆蓋'`）改為「合併」。

## i18n

ARB key 異動（先寫 `lib/l10n/app_zh.arb`，再以中文為基準翻核心三語系 `app_en` / `app_ja` / `app_zh_Hans`；其餘 26 個 Crowdin 空殼不主動補，交 pipeline）。詞彙沿用鳴潮既有用語（`紀錄`、`喚取`），en/ja/zh_Hans 沿用原神版既有（內容 game-neutral）以維持跨 app 一致：

- **新增**：
  - `settingsImportMergeBadge`：zh `合併` / en `Merge` / ja `結合` / zh_Hans `合并`
  - `settingsImportConfirmMergeHeader`：zh `下列帳號將與本機資料合併，不會刪除既有紀錄：` / en `The following accounts will be merged with local data; existing records won't be deleted:` / ja `以下のアカウントはローカルデータと結合されます。既存の記録は削除されません：` / zh_Hans `以下账号将与本机数据合并，不会删除既有记录：`
- **改寫**：
  - `settingsImportConfirmIntro`：「即將匯入 {accounts} 個帳號（共 {records} 筆紀錄）：」→「即將合併 {accounts} 個帳號（共 {records} 筆紀錄）：」（en `About to merge {accounts} accounts ({records} records total):` / ja `{accounts} 個のアカウントを結合します（合計 {records} 件の記録）：` / zh_Hans `即将合并 {accounts} 个账号（共 {records} 条记录）：`）
  - `progressDoneImportSummary`：2 → 3 placeholder（successAccounts、addedRecords、duplicateRecords）。zh `已合併 {accounts} 個帳號：新增 {added} 筆、已存在 {duplicate} 筆` / en `{accounts, plural, =1{Merged 1 account} other{Merged {accounts} accounts}}: {added} new, {duplicate} already present` / ja `{accounts} 個のアカウントを結合しました：新規 {added} 件、既存 {duplicate} 件` / zh_Hans `已合并 {accounts} 个账号：新增 {added} 条、已存在 {duplicate} 条`
- **刪除**（核心四語系；刪前再全域 grep 確認 `lib/`、`test/` 無其他引用）：`settingsImportOverwriteBadge`、`settingsImportConfirmWarning`、`settingsImportConfirmOverwriteHeader`
- **保留**：`settingsImportConfirmNoConflict`、`settingsImportConfirmPreserveFooter`、`settingsImportConfirmTitle`、`confirmImport`、`actionCancel`
- CJK 全形標點；結尾省略號一律半形 `...`。

## 非目標（YAGNI）

- 不提供「合併／覆蓋」切換（永遠合併）。
- 不支援 UIGF / SRGF / Excel 等外部格式（維持自家 `AccountsBundle` JSON）。
- 不重構 `mergeOrderedRecords` 更新抓取流程。
- 不改 `_refetchAll`／`_clearGallery` 的危險紅色語意（僅抽取共用 helper，傳 `isDanger: true` 維持現狀）。
- 不為 picker badge 加 enum 樣式參數（唯一消費者直接改色即可）。
