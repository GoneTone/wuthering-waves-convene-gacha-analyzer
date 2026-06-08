# Discord 風格圖片檢視器互動 — Design Spec

- **Date**: 2026-06-08
- **Branch**: feat/discord-style-image-viewer
- **Status**: Approved, ready for plan

## 背景與目標

`ZoomableImageOverlay`（`lib/widgets/dialogs/zoomable_image_overlay.dart`）目前的全螢幕 lightbox 互動是：**雙擊** fit↔2x、滑鼠滾輪以游標為中心連續縮放、拖曳平移、右上角單顆 X 關閉、點 letterbox 暗區／黑底／ESC 關閉。游標的 `zoomIn` 提示其實設在 `GachaItemDetailDialog` 的縮圖 tap target 上，overlay 內本身不依縮放狀態切換游標。

使用者希望把 overlay 的互動改成 **Discord 圖片檢視器的體驗**：

1. 改成**單擊**切換放大／縮小（取代雙擊）。
2. 滑鼠移到圖片上時，游標依目前縮放狀態顯示放大鏡＋（可放大）或放大鏡−（可縮小）。
3. 右上角除了關閉，再加一顆**依狀態切換的縮放鈕**。

本 spec 為這三點的實作方案設計。

## 範圍

**在範圍內**：

- 修改 `ZoomableImageOverlay` 的互動層：
  - 單擊圖片像素 → 切換 fit ↔ 2x（以點擊落點為焦點）。
  - 移除雙擊縮放（避免與單擊重複觸發）。
  - 圖片像素區游標依縮放狀態切換 `zoomIn` / `zoomOut`。
  - 右上角按鈕列由「單顆 X」改為「縮放切換鈕＋X」兩顆。
- 新增 2 個 ARB key（`actionZoomIn`／`actionZoomOut`）。
- 對應調整既有測試、補新測試。

**不在範圍內**：

- 滾輪縮放、拖曳平移、ESC／點背景／點暗區關閉 — 全部維持現狀。
- `GachaItemDetailDialog` 縮圖 tap target 上的 `SystemMouseCursors.zoomIn`（那是「點擊開啟」的提示，與本次無關）。
- grab 手型游標、縮放百分比顯示、多圖左右切換 — YAGNI，使用者未要求。
- 縮放層級維持 fit ↔ 2x（不改為 1:1 原始像素或多級循環）。

## 互動模型

| 動作 | 現況 | 改成 |
|---|---|---|
| 單擊圖片像素 | 無作用（吸收，避免誤關） | **切換 fit ↔ 2x**，以點擊落點為焦點 |
| 雙擊圖片 | fit ↔ 2x | **移除** |
| 滑鼠滾輪 | 游標為中心連續縮放（1x–5x） | 保留 |
| 拖曳 | 平移 | 保留 |
| 點 letterbox 暗區／黑底／ESC | 關閉 | 保留 |

**單擊邏輯**（沿用現有 `_zoomAt` 數學）：

- 目前在 fit（scale ≈ `_minScale`）→ 放大到 `_doubleTapScale`（2x），焦點 = 點擊落點。
- 否則（含滾輪放到任意倍率）→ 回 fit（強制 `Matrix4.identity()`，與現有 zoom-out clamp 路徑一致，避免殘留 translation）。

實作上把目前 image absorber 內層 `GestureDetector` 的 `onDoubleTapDown` 換成 **`onTapUp`**（`TapUpDetails.localPosition` 取得落點）。手勢競技場：靜止點擊 → `TapGestureRecognizer` 贏 → 觸發縮放；有位移 → `InteractiveViewer` 的 pan 贏 → 平移。兩者互不打架，且因為不再有 double-tap recognizer，tap 不會被 `kDoubleTapTimeout`（300ms）卡住。

外層（包住 `InteractiveViewer` 的 `GestureDetector`）維持單純 `onTap` → 關閉，落在 image 像素外的暗區點擊立即關閉。

> **關閉路徑變動提示**：改成單擊縮放後，點圖片像素本身不再關閉（改為縮放）。關閉改靠：點 letterbox 暗區／黑底、ESC、X 鈕。放大後圖片占畫面更大、暗區變小，但 ESC／X 永遠可用。此為 Discord 一致行為。

## 右上角按鈕列

把目前單顆 X（`Positioned(top: 16, right: 16)`）改為一個橫向 `Row`，由左到右兩顆半透明黑底圓鈕（沿用現有 X 的 `Material(color: black α0.4) + CircleBorder + IconButton(white)` 樣式）：

```
                                    [ ⤢ ]  [ ✕ ]
                                  縮放切換  關閉
```

- **縮放切換鈕**：單一按鈕，依目前 scale 切換 icon／tooltip／行為——
  - fit（scale ≈ `_minScale`）→ `Icons.zoom_in`、tooltip `actionZoomIn`，按下 → 放大到 2x（焦點 = **圖片／viewport 中心**）。
  - 已放大（scale > `_minScale`）→ `Icons.zoom_out`、tooltip `actionZoomOut`，按下 → 回 fit（`Matrix4.identity()`）。
- **關閉（✕）**：維持 `Icons.close`、tooltip `actionCloseImagePreview`、`_close('button')`。

縮放鈕的「以 viewport 中心為焦點」需要 viewport 尺寸。沿用既有 overlay 的 `LayoutBuilder`／可量測區域取得當前可用尺寸，焦點 = `Offset(w / 2, h / 2)`，再餵給 `_zoomAt`。

## 游標狀態（依縮放切換）

在 image 像素區（現有 `SizedBox`／內層 GestureDetector 的範圍）外包一層 `MouseRegion`，游標依目前 scale：

- scale ≈ fit（下一次單擊會放大）→ `SystemMouseCursors.zoomIn`。
- scale > fit（下一次單擊會縮小）→ `SystemMouseCursors.zoomOut`。

依使用者明確指定，只切換 zoomIn／zoomOut 兩種游標；放大後拖曳平移時游標仍為 zoomOut（不切 grab 手型）。

## 讓游標與縮放鈕跟著 scale 即時更新

`TransformationController` 本身是 `ValueNotifier<Matrix4>`。用單一 **`ValueListenableBuilder<Matrix4>(valueListenable: _ctrl)`** 同時驅動：

- `MouseRegion` 的 cursor 選擇。
- 縮放切換鈕的 icon／tooltip／onPressed 目標。

判斷 `isZoomed = scale > _minScale + ε`（沿用現有 `1e-6`/`0.05` 量級的容差），三處共用同一判斷，確保游標與按鈕狀態一致。

### 為什麼用 ValueListenableBuilder 而非自存 `double _scale`

`_ctrl` 已是唯一 scale 來源（滾輪／單擊／按鈕都寫它）。另存一份 `_scale` 用 `setState` 同步會多一份要對齊的狀態，容易在某條縮放路徑漏更新而與 `_ctrl` 不一致。直接監聽 `_ctrl` 讓 UI 永遠跟著真實矩陣走，無同步問題。

## i18n / a11y / logging

### i18n

新增 2 個 ARB key（沿用 `actionXxx` 命名，與 `actionCloseImagePreview` 同段）：

```json
"actionZoomIn": "放大",
"@actionZoomIn": {
  "description": "Tooltip and semantic label for the zoom-in button on the zoomable image overlay."
},
"actionZoomOut": "縮小",
"@actionZoomOut": {
  "description": "Tooltip and semantic label for the zoom-out button on the zoomable image overlay."
}
```

- 從 `app_zh.arb` 起手（per memory `feedback_i18n_starts_from_zh`）。
- 只加在已有實體翻譯的 ARB（per memory `feedback_i18n_skip_empty_arbs`），空殼留給 Crowdin pipeline。

### a11y

- 縮放切換鈕：`IconButton(tooltip: ...)`，tooltip 隨狀態為 `actionZoomIn`／`actionZoomOut`，同時擔任 semantic label。
- 關閉鈕：維持 `actionCloseImagePreview`。
- 圖片像素區游標已給 zoomIn／zoomOut 視覺提示。

### logging

維持現有 `gacha.itemimage.zoom` 樹的 `overlay open`／`overlay close reason=...`／`image errorBuilder`。不為單擊縮放／按鈕縮放／游標切換加 log（噪音大、無 debug 價值），與現有「不 log wheel／double-tap」一致。

## 測試計畫

修改 `test/widgets/dialogs/zoomable_image_overlay_test.dart`：

### 改寫

- **「double-tap toggle」群組 → 單擊 toggle**：
  - 從 fit 單擊（`tester.tapAt` 圖片區）→ scale 到 2x。
  - 從非 fit（先滾輪放到 >2x）單擊 → 回 1x，且 translation 歸零（identity）。
- **「tap-to-close structure」群組**：
  - 內層 image GestureDetector 改驗帶 `onTapUp`、不帶 `onDoubleTapDown`／`onDoubleTap`。
  - 外層 InteractiveViewer wrapper 維持帶 `onTap`、不帶 double-tap。

### 新增

- 游標：fit 時 image 區 `MouseRegion.cursor == SystemMouseCursors.zoomIn`；放大後（滾輪或單擊）== `SystemMouseCursors.zoomOut`。
- 縮放切換鈕：
  - fit 時以 `actionZoomIn` tooltip 找得到，按下 → scale ≈ 2.0。
  - 放大後以 `actionZoomOut` tooltip 找得到，按下 → scale ≈ 1.0、translation 歸零。
- 關閉鈕：維持以 `actionCloseImagePreview` tooltip 找得到並關閉。

### 不動

- 滾輪縮放群組、cursor-centered 數學、backdrop／ESC 關閉、InteractiveViewer wiring（`scaleEnabled=false`、`panEnabled=true`、min/max scale）。

### Manual checklist

- `flutter run --release` 進 app，開 5★ 角色 detail dialog → 點立繪 chip → 點主圖開 overlay。
- 驗證：
  - hover 圖片時游標在 fit 顯示放大鏡＋、放大後顯示放大鏡−。
  - 單擊圖片在 fit ↔ 2x 來回切換（落點為焦點）。
  - 右上縮放鈕 icon／tooltip 隨狀態切換，按下正確 fit↔2x。
  - 滾輪、拖曳平移仍正常；ESC／點黑底／點暗區／X 都能關閉。
  - GIF 圖在 overlay 下仍會動。

## 提交前檢查

按 CLAUDE.md（優先 `fvm`）：

1. `fvm dart format lib/ test/`
2. `fvm flutter analyze` → 必須 `No issues found!`
3. `fvm flutter test` → 必須 `All tests passed!`
4. 改 ARB 後 `fvm flutter gen-l10n`。

## 檔案改動總表

| 檔案 | 改動類型 |
|---|---|
| `lib/widgets/dialogs/zoomable_image_overlay.dart` | 修改（單擊 toggle、游標、右上按鈕列、ValueListenableBuilder 驅動） |
| `lib/l10n/app_zh.arb` 等已翻譯 ARB | 新增 `actionZoomIn`／`actionZoomOut` key |
| `test/widgets/dialogs/zoomable_image_overlay_test.dart` | 修改（雙擊→單擊、結構斷言、游標／按鈕新測試） |
