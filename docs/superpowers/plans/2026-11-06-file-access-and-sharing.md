# 檔案存取與分享 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓 Android 能存檔、分享、複製圖片（備份、日誌、分享圖、物品圖），選檔／存檔統一改用 `file_picker`，桌面行為不變。

**Architecture:** 新增一個共用服務 `lib/services/file_access.dart`，包住 `file_picker`（開檔、選資料夾、存檔）、`share_plus`（分享）、`super_clipboard`（複製 PNG），取代 `item_image_save.dart` 與 `share_image_export.dart` 裡重複的存檔／複製程式。所有呼叫端改用它；「分享」按鈕只在 `isAndroidProvider` 為 true 時出現。

**Tech Stack:** Flutter（FVM 3.47.5）、Riverpod 3、`file_picker`、`share_plus`、`super_clipboard` 0.9.1、flutter_test。

**Spec:** `docs/superpowers/specs/2026-11-06-file-access-and-sharing-design.md`

## Global Constraints

- 桌面版行為不變：對話框種類、預設檔名、副檔名篩選、覆蓋確認、成功後的「開啟資料夾」（spec 反目標）。
- 「分享」「儲存」只在 Android 出現，判斷用 `isAndroidProvider`（`lib/state/platform.dart`），不看螢幕寬度。
- 匯入與讀檔自己用 `utf8.decode` 解碼 bytes，不依賴套件的字串讀取（防子專案 1 的中文亂碼回歸）。
- Android 存檔成功訊息顯示檔名、不給 `revealPath`；分享成功不提示，分享失敗才提示。
- 新字串只改四份核心 ARB：`app_en.arb`、`app_ja.arb`、`app_zh.arb`、`app_zh_Hans.arb`；之後 `fvm flutter gen-l10n`。
- log 訊息英文、`sanitizeFsPath` 處理路徑；`content:` Uri 只記 scheme 與 authority。
- 每次 commit 前：`fvm dart format lib/ test/`、`fvm flutter analyze`（No issues found!）、`fvm flutter test`（All tests passed!）。
- 所有宣告寫一行 `///` dartdoc；commit message 英文 conventional commits。

## Review Focus

1. 使用者在系統存檔／選檔／分享畫面按取消：不提示、不記 severe、不丟例外。
2. 匯入的檔案不是合法 UTF-8（例如 Big5 或二進位檔）：顯示既有的「無法讀取」訊息，不當機。
3. Android 存檔回傳的 Uri 看不出檔名（`msf:1234`）或副檔名不符：顯示建議檔名。
4. 系統沒有任何 App 能接分享、或分享丟例外：顯示分享失敗訊息。
5. 物品名稱含檔名非法字元（`/`、`:`）時，Android 存檔與分享的檔名仍合法（沿用 `_suggestedFileName` 的替換）。

---

## File Structure

| 檔案 | 責任 |
|---|---|
| `lib/services/file_access.dart`（新） | 開檔、選資料夾、存檔、分享、複製 PNG 的唯一入口；測試 seam 集中在這裡 |
| `lib/services/item_image_save.dart` | 只留 `encodeImageFileToPng` 與 `itemImageEncoder` seam；存檔／複製移走 |
| `lib/services/share_image_export.dart` | 刪除（併入 `file_access.dart`） |
| `lib/widgets/dialogs/item_image_actions.dart`（新） | 物品圖選單項目與複製／儲存／分享的執行，詳情對話框與看圖共用 |
| `lib/models/share_image_options.dart` | `ShareImageAction` 加 `share` |
| `lib/widgets/dialogs/share_image_dialog.dart`、`lib/widgets/share/share_image_helper.dart` | 分享圖的分享按鈕與流程 |
| `lib/widgets/dialogs/accounts_picker_dialog.dart` | 選填的第二個確認鈕（分享） |
| `lib/pages/settings_page.dart` | 備份、日誌的儲存／分享；所有開檔換成 `file_access.dart` |
| `lib/widgets/dialogs/manual_credential_dialog.dart`、`lib/widgets/game_dir_picker.dart` | 換成 `file_access.dart` |
| `android/app/src/main/AndroidManifest.xml` | `super_clipboard` provider |
| `pubspec.yaml` | 加 `file_picker`、`share_plus`；最後移除 `file_selector` |

---

### Task 1: Go／no-go 檢查（不寫任何功能）

**Files:**
- Modify: `pubspec.yaml`（加 `file_picker`、`share_plus`，`file_selector` 先留著）
- Scratch only: session scratchpad 下的獨立 Flutter 專案（不進 repo）

**Interfaces:**
- Produces: 已加入的套件版本；ledger 上的 go／no-go 結論。

- [ ] **Step 1:** 用 ctx7 查 `file_picker` 與 `share_plus` 最新穩定版的安裝需求與 API（`saveFile`、`pickFiles`、`getDirectoryPath`、`SharePlus.instance.share(ShareParams(files: [XFile.fromData(...)]))`），`fvm flutter pub add file_picker share_plus`。
- [ ] **Step 2:** 建置檢查。Run: `fvm flutter build apk --debug` 與 `pwsh ./build_release.ps1`（或專案現有的 Windows release 建置方式）。Expected: 兩者都成功。失敗就停下回報（spec 5.1）。
- [ ] **Step 3:** 在 scratchpad 建一個最小 Flutter Windows App，兩個按鈕分別呼叫 `getSaveLocation(suggestedName: 'wuwa_test.json', acceptedTypeGroups: [XTypeGroup(label: 'JSON', extensions: ['json'])])` 與 `FilePicker.saveFile(fileName: 'wuwa_test.json', bytes: ..., type: FileType.custom, allowedExtensions: ['json'])`。實際開兩個對話框截圖比對：預設檔名、「存檔類型」下拉內容；並對同一個已存在的檔案各存一次，比對有沒有覆蓋確認。
- [ ] **Step 4:** 三項都一樣 → ledger 記 `Task 1: go — <比對結果>`，commit `pubspec.yaml`／`pubspec.lock`（`chore(deps): add file_picker and share_plus`）。任何一項不同 → **停止整個計畫**，帶截圖與差異回報使用者（spec 5.1 使用者決定 a）。

### Task 2: 共用服務 `file_access.dart`

**Files:**
- Create: `lib/services/file_access.dart`
- Test: `test/services/file_access_test.dart`

**Interfaces:**
- Produces（後續 task 都用這些名字）：
  - `class SavedFile { const SavedFile({required this.displayName, this.path}); final String displayName; final String? path; }` — `path` 只在桌面（`file:` Uri）有值，給成功訊息與 `revealPath`。
  - `Future<SavedFile?> saveBytes(Uint8List bytes, {required String suggestedName, required String extension, required String mimeType})` — 取消回 `null`；寫入失敗記 severe 後 rethrow。
  - `String displayNameForSavedUri(Uri uri, {required String suggestedName, required String extension})` — spec 5.3。
  - `Future<bool> shareBytes(Uint8List bytes, {required String fileName, required String mimeType})` — 使用者關掉分享面板也回 `true`；例外記 warning 回 `false`。
  - `Future<bool> copyPngToClipboard(Uint8List png)` — 沿用現有 `super_clipboard` 寫法與語意。
  - `Future<Uint8List?> pickFileBytes({List<String>? extensions})` — 取消回 `null`。
  - `Future<String?> pickTextFile({required List<String> extensions})` — `utf8.decode`；不合法 UTF-8 丟 `FormatException`。
  - `Future<String?> pickDirectory()`。
  - 測試 seam（`@visibleForTesting`）：`fileSaveDialog`、`fileOpenDialog`、`directoryDialog`、`fileSharer`、`pngClipboardWriter`，以及 `resetFileAccessSeams()`。
  - Logger：`Logger('io.file')`。

- [ ] **Step 1: 寫會失敗的測試**（`test/services/file_access_test.dart`）
  - `saveBytes returns null and writes nothing when the user cancels`
  - `saveBytes on desktop returns the file path and its basename`：seam 回 `Uri.file(r'C:\tmp\a.json')` → `path == r'C:\tmp\a.json'`、`displayName == 'a.json'`
  - `saveBytes on Android returns no path`：seam 回 `Uri.parse('content://com.android.externalstorage.documents/document/primary%3ADownload%2Fa.json')` → `path == null`、`displayName == 'a.json'`
  - `displayNameForSavedUri falls back to the suggested name when the uri has no file name`：`content://com.android.providers.downloads.documents/document/msf%3A1234` → `'wuwa.json'`
  - `displayNameForSavedUri falls back when the extension does not match`
  - `saveBytes rethrows when the dialog fails`
  - `shareBytes passes the name and mime type and returns true`
  - `shareBytes returns false when sharing throws`
  - `pickTextFile decodes UTF-8 Chinese text`：bytes 為 `utf8.encode('{"alias":"主號"}')` → 原字串
  - `pickTextFile throws FormatException on invalid UTF-8`：`[0xff, 0xfe, 0x00]`
  - `pickTextFile returns null when cancelled`
- [ ] **Step 2:** Run `fvm flutter test test/services/file_access_test.dart`。Expected: 編譯失敗（檔案不存在）。
- [ ] **Step 3:** 實作。預設 seam 呼叫 `file_picker`／`share_plus`／`super_clipboard`；`pickFileBytes` 用 `withData: true`，拿不到 `bytes` 時讀 `path`。
- [ ] **Step 4:** Run 同上。Expected: All tests passed!
- [ ] **Step 5:** Commit `feat(files): add a shared file access service`。

### Task 3: 分享圖改用共用服務，Android 加「分享」，補剪貼簿 provider

**Files:**
- Delete: `lib/services/share_image_export.dart`、`test/services/share_image_export_test.dart`
- Modify: `lib/models/share_image_options.dart`、`lib/widgets/dialogs/share_image_dialog.dart`、`lib/widgets/share/share_image_helper.dart`、`android/app/src/main/AndroidManifest.xml`、四份核心 ARB
- Test: `test/widgets/dialogs/share_image_dialog_test.dart`、分享圖流程的既有測試（`grep -rln saveShareImage test`）

**Interfaces:**
- Consumes: Task 2 的 `saveBytes`、`shareBytes`、`copyPngToClipboard`、seam。
- Produces: `ShareImageAction.share`；ARB `actionShare`（en `Share`／ja `共有`／zh `分享`／zh_Hans `分享`）、`shareFailed`（en `Couldn't share`／ja `共有できませんでした`／zh `無法分享`／zh_Hans `无法分享`）。

- [ ] **Step 1: 寫會失敗的測試**
  - `share image dialog shows a share button only on Android`（Android variant 有 `actionShare`；Windows 沒有）
  - `choosing share sends the png with a .png name and shows nothing on success`
  - `share failure shows shareFailed`
  - 既有「存檔成功顯示路徑與開啟資料夾」改用 Task 2 seam，Windows 行為斷言不變
- [ ] **Step 2:** Run 相關測試。Expected: FAIL。
- [ ] **Step 3:** 實作。對話框按鈕順序 `[取消][複製][分享][儲存]`（分享只在 Android）。Android 存檔成功訊息用 `displayName`、不給 `revealPath`。Manifest 在 `<application>` 內加：
  ```xml
  <provider
      android:name="com.superlist.super_native_extensions.DataProvider"
      android:authorities="${applicationId}.SuperClipboardDataProvider"
      android:exported="true"
      android:grantUriPermissions="true" />
  ```
- [ ] **Step 4:** Run 相關測試＋全套。Expected: All tests passed!
- [ ] **Step 5:** Commit `feat(share): save, share and copy share images on Android`。

### Task 4: 物品圖選單共用化，Android 加「分享」

**Files:**
- Create: `lib/widgets/dialogs/item_image_actions.dart`
- Modify: `lib/services/item_image_save.dart`（移除存檔／複製與其 seam）、`lib/widgets/dialogs/gacha_item_detail_dialog.dart`、`lib/widgets/dialogs/zoomable_image_overlay.dart`
- Delete or rewrite: `test/services/item_image_save_test.dart`（只留編碼相關）
- Test: `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`、`test/widgets/dialogs/zoomable_image_overlay_test.dart`

**Interfaces:**
- Consumes: Task 2；Task 3 的 `actionShare`、`shareFailed`。
- Produces:
  - `List<PopupMenuEntry<String>> itemImageMenuItems(AppLocalizations l, {required bool share})` — 依序 copy／save／（share）。
  - `Future<void> runItemImageAction(String value, {required File file, required String suggestedName, required bool android, required AppLocalizations l, required void Function(String message) toast})` — 處理 `copy`／`save`／`share`，其他值不處理。

- [ ] **Step 1: 寫會失敗的測試**
  - `item image menu offers share only on Android`（詳情對話框與看圖各一）
  - `sharing an item image sends a png named after the item`
  - `item image share failure shows shareFailed`
  - 既有 copy／save 測試改用 Task 2 seam，Windows 存檔訊息仍含完整路徑
- [ ] **Step 2:** Run。Expected: FAIL。
- [ ] **Step 3:** 實作；兩處原本的 `_copyImage`／`_saveImage`／選單項目刪除，改呼叫共用函式；詳情對話框在共用項目後接自己的「重抓圖片」。
- [ ] **Step 4:** Run 相關測試＋全套。Expected: All tests passed!
- [ ] **Step 5:** Commit `feat(share): share item images on Android`。

### Task 5: 設定頁的備份與日誌

**Files:**
- Modify: `lib/widgets/dialogs/accounts_picker_dialog.dart`、`lib/pages/settings_page.dart`、四份核心 ARB
- Test: `test/widgets/dialogs/accounts_picker_dialog_test.dart`、`test/pages/settings_page_test.dart`（或現有設定頁測試檔）

**Interfaces:**
- Consumes: Task 2；`actionShare`、`shareFailed`。
- Produces:
  - `showAccountsPickerDialog` 新增選填 `String? secondaryConfirmLabel`，回傳改為 `({List<String> uids, bool secondary})?`（按第二顆鈕時 `secondary == true`）。所有呼叫端一併更新。
  - ARB `actionSave`（en `Save`／ja `保存`／zh `儲存`／zh_Hans `保存`）、`settingsLogsShare`（en `Share logs`／ja `ログを共有`／zh `分享日誌`／zh_Hans `分享日志`）。

- [ ] **Step 1: 寫會失敗的測試**
  - `accounts picker shows share and save on Android export`、Windows 仍只有 `confirmExport`
  - `exporting a backup on Android saves through saveBytes and shows the file name`
  - `sharing a backup sends wuwa_convene_backup_<stamp>.json as application/json`
  - `Android logs section shows share instead of open folder`
  - `sharing logs sends wwcga_logs_<stamp>.log as text/plain`
  - Windows 匯出成功仍有「開啟資料夾」
- [ ] **Step 2:** Run。Expected: FAIL。
- [ ] **Step 3:** 實作。備份與日誌改成先組好字串再 `utf8.encode` 交給 `saveBytes`／`shareBytes`；檔名與現在相同。
- [ ] **Step 4:** Run 相關測試＋全套。Expected: All tests passed!
- [ ] **Step 5:** Commit `feat(settings): save and share backups and logs on Android`。

### Task 6: 開檔全面改用 `file_access.dart`，移除 `file_selector`

**Files:**
- Modify: `lib/pages/settings_page.dart`（`_import`、`_importFromPlatform`）、`lib/widgets/dialogs/manual_credential_dialog.dart`（`_pickFileBytes`）、`lib/widgets/game_dir_picker.dart`、`pubspec.yaml`
- Test: `test/services/accounts_import_test.dart`（移除 `XFile.fromData` 那個 cross_file 測試，改由 Task 2 的 UTF-8 測試涵蓋）、相關設定頁測試

**Interfaces:**
- Consumes: Task 2 的 `pickTextFile`、`pickFileBytes`、`pickDirectory`。

- [ ] **Step 1: 寫會失敗的測試**
  - `importing a backup with invalid UTF-8 shows the unreadable message`（Review Focus 2）
  - `importing reads Chinese aliases correctly through pickTextFile`
- [ ] **Step 2:** Run。Expected: FAIL。
- [ ] **Step 3:** 實作；`_import`、`_importFromPlatform` 用 `pickTextFile`，`FormatException` 走既有 `importReasonUnreadable`。全專案 `grep -rn file_selector lib test` 為空後，從 `pubspec.yaml` 移除 `file_selector`、`fvm flutter pub get`。
- [ ] **Step 4:** Run 全套＋`fvm flutter analyze`。Expected: All tests passed!、No issues found!
- [ ] **Step 5:** Commit `refactor(files): open files through file_picker and drop file_selector`。

### Task 7: 實機驗證與文件

**Files:**
- Modify: `docs/Android移植筆記.md`（新增「八、檔案存取與分享（子專案 4）」）

- [ ] **Step 1:** `fvm flutter build apk --debug` 安裝到 ROG Phone，逐項跑 spec 第六節的 Android 實機清單；發現問題回到對應 task 以 TDD 修正。
- [ ] **Step 2:** Windows 跑 spec 第六節的 Windows 清單（預設檔名、篩選、覆蓋確認、開啟資料夾、匯入、選遊戲資料夾、選 Client.log）。
- [ ] **Step 3:** 寫筆記：`file_selector` 在 Android 沒有存檔、`super_clipboard` 的 provider、`content:` Uri 取檔名的限制、Windows 比對結果。
- [ ] **Step 4:** Commit `docs(android): record file access and sharing findings`。
