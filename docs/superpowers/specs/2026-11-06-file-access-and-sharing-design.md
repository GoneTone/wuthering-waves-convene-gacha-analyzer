# 子專案 4：檔案存取與分享 — 設計

- 狀態：已核准（2026-11-06）
- 路線圖：`docs/superpowers/specs/2026-11-05-android-support-roadmap-design.md`（子專案 4）
- 分支：`feat/android-support`

---

## 一、目的

讓只用手機的玩家也能使用桌面版所有「存出去、拿進來、複製」的功能（路線圖目標：與 PC 版功能對等），並且依手機習慣多一個「分享」。

**目標**

- Android 上能正常使用：匯出備份、匯出日誌、另存物品圖、另存分享圖、複製圖片到剪貼簿。
- 手機上多一個「分享」（系統分享面板），用在分享圖、物品圖、日誌、備份。
- 選檔／存檔統一成一個跨平台套件，兩個平台走同一段程式。

**非目標**

- 桌面版加上「分享」按鈕（桌面維持原樣）。
- iOS。
- 改動備份檔、日誌的內容格式。

**反目標**

- 改壞 Windows 既有的流程或 UX（對話框種類、預設檔名、副檔名篩選、覆蓋確認、成功後的「開啟資料夾」）。
- 匯入備份或讀 Client.log 時再出現中文亂碼（子專案 1 修過的問題）。

## 二、現況（2026-11-06 盤點）

| 功能 | 程式位置 | 用到的 API | Android 現況 |
|---|---|---|---|
| 匯出備份 JSON | `settings_page.dart` `_export`（帳號） | `getSaveLocation` | 壞：`file_selector_android` 沒有實作存檔 |
| 匯出日誌 | `settings_page.dart` `_export`（日誌） | `getSaveLocation` | 壞，同上 |
| 開啟日誌資料夾 | `settings_page.dart` `_openFolder` → `file_reveal.dart` | `launchUrl(Uri.file)` | 不能用：日誌在 App 私有目錄 |
| 匯出成功後「開啟資料夾」 | `export_result_dialog.dart` → `revealInFileManager` | `explorer /select` | 不適用：Android 存檔只回 `content://` |
| 另存物品圖 | `item_image_save.dart` `saveImagePng` | `getSaveLocation` | 壞，同上 |
| 另存分享圖 | `share_image_export.dart` `saveShareImage` | `getSaveLocation` | 壞，同上 |
| 複製物品圖／分享圖 | 同上兩檔 | `super_clipboard` | 應該失敗：manifest 沒有宣告 content provider |
| 匯入備份 | `settings_page.dart` `_import` | `openFile` | 正常 |
| 從其他工具匯入 | `settings_page.dart` `_importFromPlatform` | `openFile` | 正常 |
| 手動輸入網址：選 Client.log | `manual_credential_dialog.dart` `_pickFileBytes` | `openFile` | 正常 |
| 手動輸入網址：貼上 | 同上 | Flutter `Clipboard.getData` | 正常 |
| 選遊戲資料夾（Windows） | `game_dir_picker.dart` | `getDirectoryPath` | 只在 Windows 使用 |
| 開外部連結 | `app_link.dart` 等 | `url_launcher` | 正常 |

`item_image_save.dart` 與 `share_image_export.dart` 幾乎是同一段程式寫兩份（存 PNG、複製 PNG、各自一組測試 seam）。

## 三、做法比較（使用者選 C）

| | 做法 | 取捨 |
|---|---|---|
| A | 存檔改用 `file_picker`，開檔維持 `file_selector` | 動得最少；但會有兩個選檔套件 |
| B | Windows 維持 `file_selector`，Android 自寫 Kotlin 呼叫系統建立文件畫面 | Windows 不動；但要依平台分流、自己維護原生程式，違反「不造輪子」與「優先共用」 |
| **C** | **`file_picker` 全面取代 `file_selector`（開檔、選資料夾、存檔）** | **只剩一個套件、兩個平台同一段程式；代價是要重新驗證匯入、選 Client.log、選遊戲資料夾** |

使用者選 C，理由是比較統一、好維護。

分享只有一個合理選擇：`share_plus`（Flutter Community 維護）。剪貼簿維持 `super_clipboard`，只補 Android manifest。

## 四、各功能在手機上的樣子（使用者已確認）

桌面版全部不變。

| 功能 | 桌面（不變） | 手機 |
|---|---|---|
| 分享圖 | 複製／另存 | 複製／**儲存**／**分享** |
| 物品圖（詳情對話框與看圖的選單） | 複製／另存 | 複製／**儲存**／**分享** |
| 日誌（設定頁） | 匯出／開啟資料夾 | 匯出／**分享**（取代開啟資料夾） |
| 備份（設定頁） | 匯出 | 匯出：選完帳號後，按鈕分成「儲存」與「分享」 |

```
選擇要匯出的帳號
☑ 全選
☑ 701000000 (主號)
             [取消] [分享] [儲存]
```

- 手機存檔成功後的結果訊息顯示**檔名**，不放「開啟資料夾」按鈕。
- 分享完成後不另外提示（系統分享面板本身就有回饋）；分享失敗才提示。
- 「儲存」「分享」只在 Android 出現的判斷用既有的 `isAndroidProvider`（`lib/state/platform.dart`），不是看螢幕寬度：Windows 視窗拉窄時仍是桌面行為。

## 五、技術決定

### 5.1 `file_picker` 取代 `file_selector`

- `pubspec.yaml` 移除 `file_selector`、加入 `file_picker`（版本由實作時查 pub.dev 最新穩定版）。
- **第一步是 go／no-go 檢查，在寫任何功能之前完成**（使用者 2026-11-06 選定）：
  1. 能在現有建置環境編過（Gradle 9／AGP 9、`android/cargokit_gradle9_shim.gradle`、Windows release build）。
  2. Windows 實際開一次 `FilePicker.saveFile`，和現在的 `getSaveLocation` 比對：預設檔名、副檔名篩選（例如「JSON (*.json)」）、檔案已存在時的覆蓋確認。
  
  兩項都一樣才繼續。任何一項不一樣就**停下來回報**（附截圖與差異），由使用者決定接受差異、或改用其他做法；不要自行修套件或改成混用。
  
  背景：官方文件對 Windows 存檔是否帶副檔名篩選說法不一（舊版 wiki 說會帶，新版 API 簽章看起來沒傳給平台端），覆蓋確認也沒有記載，只能實測。
- 存檔：`FilePicker.saveFile(fileName:, bytes:, type: FileType.custom, allowedExtensions: [...])`，由套件寫入，回傳 `Uri?`（取消為 `null`）。Windows 回 `file:` Uri，取 `toFilePath()` 給既有的成功訊息與「開啟資料夾」；Android 回 `content:` Uri。
- 開檔：`FilePicker.pickFiles(type: FileType.custom, allowedExtensions: [...])` 讀出 bytes，**自己用 `utf8.decode` 解碼**（不依賴套件的字串讀取），避免子專案 1 的亂碼問題重現。Client.log 是二進位混淆檔，維持讀 bytes。
- 選資料夾：`FilePicker.getDirectoryPath()`。
- 所有開檔點都換：匯入備份、從其他工具匯入、手動輸入網址的選 Client.log。Client.log 要不要加副檔名篩選由實作者決定。

### 5.2 共用的匯出服務（我的判斷：合併重複程式）

把 `item_image_save.dart` 與 `share_image_export.dart` 的重複部分合併成一個服務（例如 `lib/services/file_export.dart`），提供：

- `saveBytes`：跳存檔對話框寫入，回傳結果（取消／成功含顯示用名稱與桌面路徑／失敗）。
- `shareBytes`：用 `share_plus` 分享記憶體中的資料（`XFile.fromData` 帶檔名與 MIME）。
- `copyPngToClipboard`：維持現有 `super_clipboard` 寫法。

各呼叫端（設定頁的備份與日誌、分享圖、物品圖）都改用這個服務。測試 seam 集中在這一個檔，取代目前兩組重複的 seam。PNG 編碼（`encodeImageFileToPng`）維持原位。

### 5.3 Android 存檔成功時顯示的名稱

`content:` Uri 不一定帶得出檔名（例如下載資料夾的 provider 只給 `msf:1234`）。規則：

- Uri 最後一段解碼後，取最後一個 `/` 之後的字串；**副檔名符合預期**就用它（使用者在系統畫面改過檔名時也正確）。
- 否則顯示我們建議的檔名。

### 5.4 剪貼簿

`android/app/src/main/AndroidManifest.xml` 加上 `super_clipboard` 要求的 provider，authority 用 `${applicationId}.SuperClipboardDataProvider`（不寫死，避免日後加 build variant 時衝突）。

### 5.5 日誌與結果對話框

- Android 隱藏「開啟日誌資料夾」，改放「分享日誌」。
- `showExportResultDialog` 在 Android 不給 `revealPath`。

### 5.6 文字

新增字串只改四份核心 ARB（依 `l10n-and-riverpod-facts`），例如「分享」「儲存」「分享日誌」與分享失敗訊息；能沿用既有字串的就沿用。

### 5.7 log

依 CLAUDE.md 在存檔、分享、剪貼簿、選檔的成功／取消／失敗都記 log（英文、Logger 命名沿用 `share.image`、`gacha.itemimage.save`、`accounts.io` 等既有樹），路徑經 `sanitizeFsPath`，`content:` Uri 只記 scheme 與 authority。

## 六、驗收

**自動測試**（`fvm flutter analyze` 無問題、`fvm flutter test` 全過）

- 匯出服務：存檔取消／成功／失敗、分享、複製的行為與 log。
- Android 名稱推導（5.3）的幾種 Uri。
- 匯入：含中文的 UTF-8 備份讀回內容正確。
- 設定頁、分享圖、物品圖選單：Android 才出現「分享」，Windows 不出現；Android 不出現「開啟資料夾」。
- 帳號挑選對話框在 Android 有「分享」「儲存」兩個確認鈕。

**實機（ROG Phone）**

- 匯出備份：儲存到下載資料夾、分享到雲端硬碟／LINE；再匯入剛存的備份（含中文別名）。
- 匯出日誌：儲存、分享。
- 分享圖、物品圖：複製（貼到 LINE 確認是圖片）、儲存、分享。
- 手動輸入網址：選 Client.log 讀取成功。

**Windows 實機**

- 存檔對話框的預設檔名、副檔名篩選、覆蓋確認和現在一樣；成功後「開啟資料夾」會選中檔案。
- 匯入備份、選遊戲資料夾、手動選 Client.log 正常。

## 七、留給實作者決定

- `file_picker` 的確切版本與是否需要調整 Android 設定（依官方文件）。
- 共用服務的檔名、函式簽名與回傳型別。
- 分享按鈕的圖示（建議 Material 的 `Icons.share`）與在選單中的順序（建議 複製／儲存／分享）。

## 八、文件

完成後在 `docs/Android移植筆記.md` 新增「八、檔案存取與分享（子專案 4）」：`file_selector` 在 Android 沒有存檔、`super_clipboard` 需要 provider、`content:` Uri 取檔名的限制、Windows 換套件後的驗證結果。
