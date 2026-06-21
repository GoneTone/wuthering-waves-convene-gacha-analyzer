# 分享圖按鈕「儲存／複製」選擇 — 設計文件

- 日期：2026-06-21
- 範圍：分享圖匯出流程（OverviewPage / BannerPage 共用）

## 背景與目標

目前點分享圖按鈕的流程為：

1. 開啟設定 dialog（`showShareImageDialog`），選主題（深／淺）與是否顯示完整 UID。
2. 按「生成」→ 渲染 PNG → `exportShareImage()` **一次同時**寫剪貼簿 + 開存檔對話框。
3. 依結果（同時存檔並複製／僅存檔／僅複製）以 `showExportResultDialog` 回報。

問題：使用者無法選擇「只存檔」或「只複製」，永遠被強制兩件事一起做。

目標：讓使用者在設定 dialog 內**明確選擇**要「儲存圖片」還是「複製圖片」，二選一執行。

## 既有可重用資產（不重造輪子）

- `lib/widgets/dialogs/zoomable_image_overlay.dart`：已有「複製圖片／儲存圖片」選單 pattern，使用在地化字串 `actionCopyImage`、`actionSaveImage`。本案沿用這兩個字串。
- `lib/services/item_image_save.dart`：已有 `saveImagePng()` / `copyImagePngToClipboard()` 的拆分式存檔／複製能力（供物品圖使用，不在本案改動範圍）。
- `lib/services/share_image_export.dart`：分享圖專用的存檔／複製 seam（`shareSaveLocationPicker`、`shareClipboardWriter`、`shareFileWriter`）與 `share.image` logger，測試已依賴；本案保留 seam，只重組對外方法。

## 設計

### 1. 資料模型（`lib/models/share_image_options.dart`）

新增 enum：

```dart
/// 使用者在分享圖設定 dialog 選擇的終端動作。
enum ShareImageAction { save, copy }
```

`ShareImageOptions`（`brightness`、`showFullUid`）維持不變，只管渲染選項，與動作解耦。

### 2. 設定 dialog（`lib/widgets/dialogs/share_image_dialog.dart`）

- 回傳型別由 `Future<ShareImageOptions?>` 改為
  `Future<({ShareImageOptions options, ShareImageAction action})?>`（取消回 `null`）。
- 內部 `_brightness` / `_showFullUid` state 與內容區（主題 SegmentedButton、UID SwitchListTile）不變。
- 底部 action 列由單一「生成」鈕改為三鈕：
  - `取消`（`TextButton`，`actionCancel`）→ `pop(null)`
  - `複製圖片`（`TextButton`，`actionCopyImage`）→ `pop((options: ..., action: ShareImageAction.copy))`
  - `儲存圖片`（`FilledButton` 主鈕，`actionSaveImage`）→ `pop((options: ..., action: ShareImageAction.save))`
- 兩顆動作鈕建構同一份 `ShareImageOptions(brightness: _brightness, showFullUid: _showFullUid)`，差別僅在 `action`。
- 順序與主次：以「儲存」為主要動作（FilledButton），符合「匯出分享圖」最常見意圖；複製／儲存的相對順序與 lightbox 選單一致（複製在前、儲存在後）。
- `shareImageGenerate`（「生成」）字串於 dialog 不再使用（保留與否見「在地化」一節）。

### 3. 服務層（`lib/services/share_image_export.dart`）

移除合併式 API，改為兩個獨立方法。沿用既有 seam 與 `share.image` logger。

移除：
- `enum ShareExportStatus`（savedAndCopied / savedOnly / copiedOnly）
- `class ShareExportResult`
- `Future<ShareExportResult> exportShareImage(...)`

新增：

```dart
/// 讓使用者選位置存 PNG。成功回實際存檔路徑（供呼叫端顯示完整路徑）；
/// 使用者取消回 null（非錯誤）；已選路徑但寫檔失敗記 severe log 後 rethrow。
Future<String?> saveShareImage(Uint8List png, {required String suggestedName});

/// 把 PNG 寫入系統剪貼簿。成功回 true；平台不支援回 false；例外記 warning 後回 false。
Future<bool> copyShareImage(Uint8List png);
```

保留不變：`shareSaveLocationPicker`、`shareClipboardWriter`、`shareFileWriter`、
`resetShareImageExportSeams()`。`saveShareImage` 行為對齊 `item_image_save.dart`
的 `saveImagePng`（取消回 null、寫檔失敗 rethrow），`copyShareImage` 對齊
`copyImagePngToClipboard`（例外吞掉回 false）。

### 4. 流程串接（`lib/widgets/share/share_image_helper.dart`）

`generateAndShareImage`：

- 接 dialog 回傳的 `({options, action})`；`null` 時 early return（同現況）。
- 渲染 PNG 流程不變（preload icon、`buildShareRenderTree`、`renderWidgetToPng`）。
- 移除 `_shareResultToDialog` 三態映射，改依 `action` 分流：
  - **save**：`final path = await saveShareImage(png, suggestedName: ...)`
    - `path == null`（使用者取消存檔對話框）→ 不彈任何結果（同現況 copiedOnly 以外的取消語意，保持安靜）。
    - 成功 → `showExportResultDialog(success: true, message: l.shareImageSaved(path), revealPath: path)`。
    - 例外 → `showExportResultDialog(success: false, message: l.shareImageFailed)`（沿用既有失敗訊息）。
  - **copy**：`final ok = await copyShareImage(png)`
    - `ok == true` → `showExportResultDialog(success: true, message: l.shareImageCopiedOnly, revealPath: null)`。
    - `ok == false` → `showExportResultDialog(success: false, message: l.shareImageCopyFailed)`。
- 其餘 try/catch（渲染失敗）、`finally`（dispose icon / preloaded）維持不變。

### 5. 在地化（核心 4 ARB：`app_zh`、`app_zh_Hans`、`app_en`、`app_ja`）

- **沿用**：`actionSaveImage`、`actionCopyImage`（按鈕文字）；`shareImageCopiedOnly`（「已複製到剪貼簿」）當複製成功訊息。
- **新增**：
  - `shareImageSaved` = 「已儲存：{path}」（帶 `path` placeholder metadata）。繁中用「已儲存」而非「已存檔」；其餘語言維持各自的 saved 語意（en `Saved: {path}`、ja `保存しました：{path}`、簡中 `已保存：{path}`）。
  - `shareImageCopyFailed` = 「複製到剪貼簿失敗」。
  - `shareImageGenerating` = 「圖片生成中...」（渲染進度視窗用，見第 7 節；省略號用 ASCII `...`）。
- **移除**（新流程不再同時做兩件事，成死字串）：`shareImageSavedAndCopied`、`shareImageSavedOnly`。
- `shareImageGenerate`（「生成」）若無其他引用一併移除；實作時以搜尋確認無殘留引用再決定。
- 標點依語言慣例：繁中／日文全形「：」，英文半形冒號。`{path}` 前後不留空格。

### 6. 測試

- `test/services/share_image_export_test.dart`：改寫，分別覆蓋 `saveShareImage`（成功回路徑、取消回 null、寫檔失敗 rethrow）與 `copyShareImage`（成功 true、平台不支援 false、例外 false）。
- `test/widgets/dialogs/share_image_dialog_test.dart`：更新為新 record 回傳；驗證三顆鈕存在、按「儲存」回 `action: save`、按「複製」回 `action: copy`、取消回 null，主題／UID 選項仍正確帶出。
- `test/models/share_image_options_test.dart`：補 `ShareImageAction` enum 基本覆蓋（值存在）。
- helper 層既有測試（若有引用舊 `exportShareImage`／三態）隨之調整為新分流。
- `test/widgets/dialogs/share_progress_dialog_test.dart`（第 7 節）：驗證顯示生成中文字與 `LinearProgressIndicator`、`PopScope.canPop == false`。

## 7. 渲染進度視窗（後續追加需求）

實作 1-6 後使用者回報：選完動作後設定 dialog 直接關閉，要等離屏渲染（`renderWidgetToPng`
+ 預載物品圖）才跳結果，中間只剩工具列小 spinner，回饋不明顯。追加一個渲染期間的
「生成中」狀態。

- **決策**：關閉設定 dialog 後彈一個獨立、不可關閉的進度視窗（`ShareProgressDialog`，
  `PopScope canPop: false` + `AppDialog` + 圖示 + 文字 + `LinearProgressIndicator`，
  風格對齊既有 `UpdateProgressDialog`），渲染完成（早於系統存檔視窗 / 複製結果通知）即關閉。
- **落點**：新檔 `lib/widgets/dialogs/share_progress_dialog.dart`
  （`showShareProgressDialog(BuildContext)` + `ShareProgressDialog`）；
  `generateAndShareImage` 在預載前彈出、以 idempotent 的 `closeProgress()`
  （`Navigator.of(context, rootNavigator: true).pop()` + 旗標）在渲染完成 / catch / finally 關閉；
  preload 收進 `try` 避免失敗時視窗卡住，`icon`/`preloaded` 改 null-safe dispose。
- **測試注意**：`LinearProgressIndicator` 是無限動畫，widget 測試用 `pump()`，
  不可用 `pumpAndSettle()`（永不收斂會逾時）。

## 非目標（YAGNI）

- 不新增「同時存檔並複製」的第三選項（移除即是為了簡化）。
- 不把分享圖按鈕改成 PopupMenu（已選定方案 A：折進設定 dialog）。
- 不合併 `share_image_export.dart` 與 `item_image_save.dart` 的重複 seam（超出本案範圍）。

## 驗收條件

- `fvm dart format lib/ test/` 無變更殘留。
- `fvm flutter analyze` → `No issues found!`。
- `fvm flutter test` → `All tests passed!`。
- 手動：點分享鈕 → 設定 dialog 顯示「取消／複製圖片／儲存圖片」三鈕；選動作後先彈不可關閉的「圖片生成中...」進度視窗（渲染期間），完成後關閉；選「儲存」只開存檔對話框並回報「已儲存」；選「複製」只寫剪貼簿並回報「已複製到剪貼簿」；皆不再強制兩件事一起做。
