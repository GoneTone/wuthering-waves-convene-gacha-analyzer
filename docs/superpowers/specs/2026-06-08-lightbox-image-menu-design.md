# Lightbox 大圖影像選單（copy／save） — Design Spec

- **Date**: 2026-06-08
- **Branch**: feat/discord-style-image-viewer
- **Status**: Approved, ready for plan

## 背景與目標

`ZoomableImageOverlay`（`lib/widgets/dialogs/zoomable_image_overlay.dart`）是從 `GachaItemDetailDialog` 縮圖點開的全螢幕 lightbox。縮圖本身已有一套影像選單（複製圖片／儲存圖片／──/重抓圖片），可由右上角 `...` 鈕或右鍵叫出（`gacha_item_detail_dialog.dart`）。

使用者希望在**已開啟的 lightbox 大圖**上也能叫出影像選單。經討論確定範圍：

- 選單只放 **複製圖片／儲存圖片**（refetch 不放——詳見「為何不放 refetch」）。
- 兩種觸發：**右鍵** 與 **右上角 `...` 按鈕**。

## 範圍

**在範圍內**：

- `ZoomableImageOverlay` 內，圖片上**右鍵**與右上按鈕列新增的 **`...` 鈕**都能叫出「複製圖片／儲存圖片」選單。
- copy／save 重用既有共用函式（`lib/services/item_image_save.dart` 的 `encodeImageFileToPng`／`copyImagePngToClipboard`／`saveImagePng`）。
- 結果回饋以 lightbox **自帶的 SnackBar** 顯示（解決原 SnackBar 被全螢幕 overlay 蓋住的問題）。
- `showZoomableImageOverlay` 新增可選參數 `suggestedFileName`，由 detail dialog 帶入「角色名_標籤.png」。

**不在範圍內**：

- **refetch（重抓圖片）**：不放。
- 多圖左右切換、detail dialog 縮圖選單改動、任何新 ARB 字串。

### 為何不放 refetch

refetch 依賴 detail dialog 的整套狀態機（chip kind 分派、URL、providers、cache evict、`setState` loading→ready）。lightbox 是自包含、只持有一個 `File` 的元件，沒有等價狀態機；即便能在磁碟上重抓，開著的大圖也**不會即時刷新**（縮圖能刷新正是靠 loading→ready 轉場重建 Image，lightbox 沒有）。為避免「按了像沒反應」的困惑，refetch 留在縮圖。

## 取捨過的做法

- **採用：overlay 自包含 copy/save，重用底層 helper。** copy/save 只需 `File`，overlay 直接呼叫共用 helper，沿用 detail dialog 既有選單結構，維持 overlay「不耦合 caller、可重用任意 File」原則。
- **不採用：caller 把選單傳進來。** 那是為 refetch 才需要的耦合；refetch 既不在範圍，overlay 自己能做就不外包。
- **不採用：抽 ImageActions service。** 真正會重複的 PNG 編碼／剪貼簿／存檔**已是共用層**；orchestration 兩處只差「回饋目標、檔名來源」，再抽一層屬過度設計（YAGNI）。

## 架構與元件

鏡像 `GachaItemDetailDialog` 既有 pattern（`_imageMenuItems`／`_onImageMenuSelected`／`_showImageContextMenu` + `PopupMenuButton`），在 `ZoomableImageOverlay` 內新增對應成員：

### API 改動

```dart
Future<void> showZoomableImageOverlay(
  BuildContext context, {
  required File imageFile,
  String? suggestedFileName,   // 新增；存檔對話框建議檔名，null 時 fallback 用 file basename
});

class ZoomableImageOverlay extends StatefulWidget {
  const ZoomableImageOverlay({
    super.key,
    required this.imageFile,
    this.suggestedFileName,
  });
  final File imageFile;
  final String? suggestedFileName;
}
```

### `_ZoomableImageOverlayState` 新增成員

- `List<PopupMenuEntry<String>> _imageMenuItems(AppLocalizations l)` — 只含 `copy`／`save` 兩個 `PopupMenuItem`（`ListTile(dense, contentPadding: zero, leading: Icon, title: Text)`，icon 用 `Icons.copy`／`Icons.save_alt`），與 dialog 視覺一致但**無 divider、無 refetch**。
- `void _onImageMenuSelected(String value)` — `copy → _copyImage()`／`save → _saveImage()`。
- `Future<void> _copyImage()` — `encodeImageFileToPng(widget.imageFile)` → null 則彈 `itemImageCopyFailed`；否則 `copyImagePngToClipboard(png)`，依結果彈 `itemImageCopied`／`itemImageCopyFailed`。
- `Future<void> _saveImage()` — `encodeImageFileToPng` → null 則彈 `itemImageSaveFailed`；否則 `saveImagePng(png, suggestedName: _suggestedName())`，成功彈 `itemImageSavedTo(path)`、取消（null）不彈、丟例外彈 `itemImageSaveFailed`。
- `String _suggestedName()` — `widget.suggestedFileName ?? widget.imageFile.uri.pathSegments.last`（不引入額外套件取 basename）。
- `Future<void> _showImageContextMenu(Offset globalPosition)` — `showMenu`（位置跟游標，重用 dialog 的 `RelativeRect.fromRect(globalPosition & Size.zero, Offset.zero & overlay.size)` 寫法），選後呼叫 `_onImageMenuSelected`。

### 呼叫端改動

`gacha_item_detail_dialog.dart`（目前 line 389 `showZoomableImageOverlay(context, imageFile: file)`）改為帶入建議檔名：

```dart
showZoomableImageOverlay(
  context,
  imageFile: file,
  suggestedFileName: _suggestedFileName(current),
);
```

## 回饋機制（lightbox 內部 SnackBar）

全螢幕 overlay 會蓋住 app Scaffold 的 SnackBar。解法：把 overlay 內容包一層**自帶的 `ScaffoldMessenger > Scaffold(backgroundColor: transparent)`**，copy/save 用 `ScaffoldMessenger.of(context)` 在 lightbox 內彈 SnackBar，顯示於黑底之上。重用 Flutter 原生 SnackBar 與既有訊息 key，不自製 toast。

```
Dialog(transparent)
  ScaffoldMessenger
    Scaffold(backgroundColor: transparent)
      <既有 Stack：backdrop / 圖片區 / 右上按鈕列>
```

- `Scaffold` 不加 AppBar、body 即既有 Stack，layout 與手勢與現況等價。
- 回饋輔助：`void _showSnack(String message)` → `ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(...)`。

## 兩種觸發

### 右鍵

圖片像素的內層 `GestureDetector`（現有 `onTapUp: _onTapZoom`）加：

```dart
onSecondaryTapDown: (d) => unawaited(_showImageContextMenu(d.globalPosition)),
```

次要鍵不與單擊縮放（primary tap）／拖曳（pan）／滾輪競爭，互不影響。

### `...` 按鈕

右上按鈕列由 `[縮放切換] [X]` 改為 **`[...] [縮放切換] [X]`**（`...` 最左、X 維持最右角）。`...` 用 `PopupMenuButton`（自動定位選單），外面包既有半透明黑底圓鈕樣式（`Material(color: black α0.4, shape: CircleBorder)`），與另兩顆視覺一致：

```dart
Material(
  color: Colors.black.withValues(alpha: 0.4),
  shape: const CircleBorder(),
  child: PopupMenuButton<String>(
    icon: const Icon(Icons.more_vert, color: Colors.white),
    tooltip: '',
    onSelected: _onImageMenuSelected,
    itemBuilder: (_) => _imageMenuItems(l),
  ),
),
```

`itemBuilder` / `onSelected` 與右鍵共用同一份 `_imageMenuItems` / `_onImageMenuSelected`。

### RWD

`...` 鈕加入後右上列為 3 顆圓鈕（`mainAxisSize: min` + `SizedBox(width: 8)` 間隔，約 160px），全螢幕 lightbox 寬度充足，窄視窗亦不溢出。

## i18n / logging

### i18n

**不新增任何 ARB key**，全部重用既有：`actionCopyImage`、`actionSaveImage`、`itemImageCopied`、`itemImageCopyFailed`、`itemImageSavedTo`、`itemImageSaveFailed`。

### logging

沿用 `gacha.itemimage.zoom` 樹：

| Level | When |
|---|---|
| info | `menu open source=rightclick\|button`（叫出選單） |
| info | `copy ok` / warning `copy failed`（複製結果） |
| info | `save ok path=...` / `save cancelled` / warning `save failed`（存檔結果，路徑經 `sanitizeFsPath`） |

（底層 helper 內部已有自己的 log；此處補 overlay 視角的事件。）

## 測試計畫

修改 `test/widgets/dialogs/zoomable_image_overlay_test.dart`（沿用既有 1×1 PNG fixture 與 `openOverlay` helper，並讓 helper 可選帶 `suggestedFileName`）：

### 新增

- **選單觸發**：`find.byIcon(Icons.more_vert)` 找得到 `...` 鈕；點 `...` 開出選單後，`actionCopyImage`／`actionSaveImage` 文字各 `findsOneWidget`，且 `actionRefetchImage`（重抓）`findsNothing`。
- **右鍵**：對圖片送 secondary tap（`TestPointer(kind: mouse)` 的 secondary down/up，或 `tester.tapAt(..., buttons: kSecondaryButton)`）後，同樣開出 copy/save 選單。
- **copy 路徑**：覆寫 `itemImageClipboardWriter` 攔截，選「複製圖片」→ 驗證 writer 被呼叫、overlay 內出現 `itemImageCopied`（或失敗時 `itemImageCopyFailed`）SnackBar。
- **save 路徑**：覆寫 `itemImageSaveLocationPicker` + `itemImageFileWriter`，選「儲存圖片」→ 驗證 writer 被呼叫、overlay 內出現 `itemImageSavedTo(...)` SnackBar；picker 回 null 時不彈 SnackBar。
- **suggestedFileName**：覆寫 `itemImageSaveLocationPicker` 捕捉傳入的 suggestedName，驗證帶 `suggestedFileName` 時用該值、不帶時 fallback 為 file basename。

> 測試前置：在 `setUp`／`tearDown` 設定與還原這些可注入 seam（參考 `gacha_item_detail_dialog_test.dart` 既有用法），並沿用 memory `project_image_cache_cross_test_race` 的 ImageCache 清理。

### 不回歸

- 既有 22 個 overlay 測試（單擊縮放、游標、縮放鈕、關閉路徑、wheel、結構）——多包一層 Scaffold/ScaffoldMessenger 與右上多一顆鈕，不影響既有 find/expect（既有測試以 type／tooltip／icon 尋找，皆仍解析）。

### Manual checklist

- `fvm flutter run --release` → 開 5★ 角色 detail → 點主圖開 lightbox：
  - 右鍵圖片、按右上 `...`，都能開出「複製圖片／儲存圖片」（無「重抓圖片」）。
  - 複製 → lightbox 內彈「已複製」；貼到外部確認圖片正確。
  - 儲存 → 系統存檔對話框預設檔名為「角色名_標籤.png」；存完 lightbox 內彈含完整路徑的提示；取消不提示。
  - 既有單擊縮放／滾輪／拖曳／關閉不受影響。

## 提交前檢查

按 CLAUDE.md（優先 `fvm`）：

1. `fvm dart format lib/ test/`
2. `fvm flutter analyze` → `No issues found!`
3. `fvm flutter test` → `All tests passed!`

## 檔案改動總表

| 檔案 | 改動類型 |
|---|---|
| `lib/widgets/dialogs/zoomable_image_overlay.dart` | 修改（選單 items／分派／copy／save／右鍵／`...` 鈕／ScaffoldMessenger 回饋／`suggestedFileName` 參數） |
| `lib/widgets/dialogs/gacha_item_detail_dialog.dart` | 修改（開 overlay 時帶 `suggestedFileName`） |
| `test/widgets/dialogs/zoomable_image_overlay_test.dart` | 修改（選單／右鍵／copy／save／檔名測試） |
