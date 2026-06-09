# 統一 dialog／lightbox 複製・儲存訊息（對齊原神版）— Design Spec

- **Date**: 2026-06-09
- **Status**: Approved, ready for plan
- **參考**: 原神版 `lib/widgets/dialogs/dialog_toast.dart`（https://github.com/GoneTone/genshin-impact-wish-gacha-analyzer）

## 背景與目標

`GachaItemDetailDialog`（詳情 dialog）與 `ZoomableImageOverlay`（lightbox）都提供「複製圖片／儲存圖片」，完成後需顯示一則結果訊息。但鳴潮版目前是**兩套不一致**的訊息機制：

- **Dialog**（`lib/widgets/dialogs/gacha_item_detail_dialog.dart`）：自管 Stack toast。硬寫 `Colors.black.withValues(alpha: 0.85)`、白字、`borderRadius 8`、`IgnorePointer`、置底 `bottom: 32`、3 秒 `Timer`、**無淡入淡出**；為了讓 toast 疊在 dialog 上，還把整個 `AppDialog` 包進一層外層 `Stack`，並維護 `_toastMessage` / `_toastTimer` 兩個 state 欄位。
- **Lightbox**（`lib/widgets/dialogs/zoomable_image_overlay.dart`）：把 overlay 內容包一層 `ScaffoldMessenger` + 透明 `Scaffold`，用原生 `SnackBar`（透過 `_messengerKey`）。

原神版則統一成**單一共用元件** `lib/widgets/dialogs/dialog_toast.dart`，提供 `showDialogToast(context, message)`，dialog 與 lightbox 都呼叫它，視覺、動畫、停留時間、配色完全一致。

**目標**：把鳴潮版兩處的訊息顯示忠實對齊原神版——同一個共用 toast 元件、同樣的 Material SnackBar 風格配色（`inverseSurface`）、同樣的淡入淡出與停留時間。

## 配色決策

「和原神版一樣，包括配色」採**沿用原神做法**：toast 底色 `theme.colorScheme.inverseSurface`、文字 `theme.colorScheme.onInverseSurface`（Material SnackBar 風格、隨主題）。在鳴潮主題下會自動取鳴潮的 `inverseSurface` 色（與 app 自身協調），取代目前硬寫的黑底 `alpha 0.85`。

> 註：鳴潮主題以 `ColorScheme.fromSeed(seedColor: accentPrimary)` 建立，未覆寫 `inverseSurface` / `onInverseSurface`，故由種子色自動推導；這與原神版「用主題色」的做法一致。

## 範圍

**在範圍內**：

- 新增 `lib/widgets/dialogs/dialog_toast.dart`，忠實移植原神版的 `showDialogToast` + `_DialogToast`。
- Dialog：移除自管 Stack toast（含外層 `Stack` 包裹、`_toastMessage` / `_toastTimer`、`IgnorePointer` toast 區、`dispose` 內 timer cancel），`_showSnack` 改呼叫 `showDialogToast`。
- Lightbox：移除 `ScaffoldMessenger` + `Scaffold` 包裹與 `_messengerKey`，`_showSnack` 改呼叫 `showDialogToast`。
- 對應測試更新／新增。

**不在範圍內**：

- copy/save 業務邏輯、`...` 鈕、右鍵選單、`suggestedFileName`、選單項目——全部不動。
- 任何新 ARB 字串（沿用既有 `itemImageCopied` / `itemImageCopyFailed` / `itemImageSavedTo` / `itemImageSaveFailed`）。
- 其他用到 SnackBar/toast 的畫面（app 層級 Scaffold 自身的 SnackBar 不受影響）。

## 取捨過的做法

- **採用：移植原神版共用 `dialog_toast.dart`，兩處改接。** 這正是「和原神版一樣」的字面要求；單一元件消除目前兩套不一致，後續維護只需改一處。
- **不採用：各自原地改樣式。** 仍是兩份重複實作，配色／動畫日後易再漂移，違反「嚴禁重複造輪子」。
- **不採用：lightbox 維持 `ScaffoldMessenger`+`SnackBar`、只改 dialog。** 兩處仍不一致，且 lightbox 為了 SnackBar 而包的透明 `Scaffold` 是多餘耦合。

## 架構與元件

### 新元件 `lib/widgets/dialogs/dialog_toast.dart`

忠實移植原神版（一字不差地對齊）：

- 模組層 `OverlayEntry? _activeToast`：目前在畫面上的 toast；新 toast 出現前先 `remove` 舊的，避免堆疊。
- `void showDialogToast(BuildContext context, String message)`：
  - 若 `_activeToast` 仍 mounted 先移除、清為 null。
  - 取 `Overlay.of(context)`，建立 `OverlayEntry`（builder 回傳 `_DialogToast`），插入 overlay。`_DialogToast.onDismissed` 內移除該 entry 並在 `identical` 時清 `_activeToast`。
  - 插到 `Overlay.of(context)`（承載 dialog route 的 navigator overlay），故 toast 疊在 dialog／modal barrier **之上**而可見——這是取代 dialog 內 `ScaffoldMessenger` SnackBar（被 modal barrier 蓋住）的關鍵。
- `_DialogToast`（`StatefulWidget`，`SingleTickerProviderStateMixin`）：
  - `AnimationController(duration: 200ms)`；`initState` 內 `forward()`（淡入）並起 `Timer(2200ms, _dismiss)`。
  - `_dismiss()`：cancel timer → `await _ctrl.reverse()`（淡出）→ `onDismissed()`；含 `mounted` 防護、重複呼叫安全。
  - `dispose()`：cancel timer + dispose controller。
  - `build`：`Positioned(left:0,right:0,bottom:0)` → `SafeArea` → `Padding(all:24)` → `Align(bottomCenter)` → `FadeTransition(opacity: _ctrl)` → `Material(color: colorScheme.inverseSurface, borderRadius:8, elevation:6)` → `ConstrainedBox(maxWidth:480)` → `Padding(h:16,v:12)` → `Text(message, bodyMedium.copyWith(color: onInverseSurface))`。

### Dialog 改動（`gacha_item_detail_dialog.dart`）

- 移除欄位 `_toastMessage`、`_toastTimer`；`dispose` 移除 `_toastTimer?.cancel()`（`_client.close()` 保留）。
- `_showSnack(String message)` 改為：`showDialogToast(context, message)`（沿用既有方法名與 `_copyImage` / `_saveImage` 呼叫點，不動 caller）。
- `build` 回傳值從 `Stack([Positioned.fill(AppDialog...), if(_toastMessage!=null) Positioned(...toast...)])` 改回**直接回傳 `AppDialog(...)`**（移除為 toast 而存在的外層 `Stack` 與 toast 區塊）。
- import：加 `dialog_toast.dart`；若 `dart:async` 僅 `Timer` 在用且改後無其他用途則移除（`unawaited` 仍在用 → 多半保留，依 analyze 結果為準）。

### Lightbox 改動（`zoomable_image_overlay.dart`）

- 移除欄位 `_messengerKey`。
- `_showSnack(String message)` 改為：`showDialogToast(context, message)`。
- `build` 移除 `ScaffoldMessenger(key:..., child: Scaffold(backgroundColor: transparent, body: Stack(...)))` 包裹，回到原本直接回傳 `Stack(children: [...])`（backdrop / 圖片區 / 右上按鈕列三段不動）。
- import：加 `dialog_toast.dart`。

## i18n / logging

- **不新增 ARB key**：沿用 `itemImageCopied`、`itemImageCopyFailed`、`itemImageSavedTo`、`itemImageSaveFailed`。
- logging 維持現狀（copy/save 既有 log 不動）。

## 測試計畫

### 新增 `test/widgets/dialogs/dialog_toast_test.dart`

- 在含 `Overlay` 的 `MaterialApp` 中呼叫 `showDialogToast(context, 'hello')` → pump 淡入後 `find.text('hello') findsOneWidget`。
- 底色：找到 toast 的 `Material`，斷言 `color == theme.colorScheme.inverseSurface`。
- 自動消失：`pump(2200ms 後再 + 200ms 淡出)` → `find.text('hello') findsNothing`。
- 單一 toast：連續呼叫兩次（不同訊息）→ 只剩最新一則（舊的被移除）。

### 改 `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`

- 既有針對自管 toast（`ValueKey('itemDetailToast')` 或黑底 `Material`）的斷言，改為驗證 copy/save 後 **overlay toast 文字**出現（`find.text(l.itemImageCopied)` 等）。
- 既有 copy/save 行為（writer 被呼叫、suggestedName）斷言維持不變。

### 改 `test/widgets/dialogs/zoomable_image_overlay_test.dart`

- 既有對 `SnackBar` / `ScaffoldMessenger` 的 copy/save 結果斷言，改為驗證 overlay toast 文字出現（`find.text(...)`）。
- 「取消不提示」：picker 回 null → 無 toast 文字出現。
- 既有 22 個結構／互動測試（縮放、游標、關閉、wheel）：移除 `Scaffold`/`ScaffoldMessenger` 包裹後，這些以 type／icon／tooltip 尋找的測試不受影響（須複跑確認）。

### Manual checklist

`fvm flutter run --release` →

- 詳情 dialog 內複製／儲存 → 底部彈出 toast：**淡入 → 停留約 2.2s → 淡出**，底色為主題 `inverseSurface`（非純黑），疊在 dialog 之上。
- lightbox 內複製／儲存 → 同樣的 toast（同色、同動畫、同位置）。
- 兩處 toast 視覺一致；連續操作只看到最新一則。
- dialog 點背景關閉、lightbox 既有縮放／滾輪／拖曳／ESC／關閉皆不受影響。

## 提交前檢查

按 CLAUDE.md（優先 `fvm`）：

1. `fvm dart format lib/ test/`
2. `fvm flutter analyze` → `No issues found!`
3. `fvm flutter test` → `All tests passed!`

## 檔案改動總表

| 檔案 | 改動類型 |
|---|---|
| `lib/widgets/dialogs/dialog_toast.dart` | 新增（移植原神版 `showDialogToast` + `_DialogToast`） |
| `lib/widgets/dialogs/gacha_item_detail_dialog.dart` | 修改（移除自管 Stack toast，改用 `showDialogToast`） |
| `lib/widgets/dialogs/zoomable_image_overlay.dart` | 修改（移除 `ScaffoldMessenger`/`SnackBar`，改用 `showDialogToast`） |
| `test/widgets/dialogs/dialog_toast_test.dart` | 新增 |
| `test/widgets/dialogs/gacha_item_detail_dialog_test.dart` | 修改（toast 斷言） |
| `test/widgets/dialogs/zoomable_image_overlay_test.dart` | 修改（toast 斷言、去 SnackBar 依賴） |
