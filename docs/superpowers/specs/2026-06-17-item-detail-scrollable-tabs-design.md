# 物品詳情 Dialog 單行可捲動頁籤＋三角箭頭導航

## 背景

物品詳情 Dialog（`lib/widgets/dialogs/gacha_item_detail_dialog.dart`）的切換頁籤目前以 `Wrap` + `ChoiceChip` 排列（檔案內 759–774 行）。當頁籤過多（造型多、加上喚取與圖示）時，`Wrap` 會往下堆疊成多行，擠壓下方圖片區、版面變高且雜亂。

本案把頁籤改為**單行、超過可水平捲動**，左右各一個**可點擊的三角箭頭**導航，行為與 UX 完全對齊姐妹專案 [genshin-impact-wish-gacha-analyzer PR #119](https://github.com/GoneTone/genshin-impact-wish-gacha-analyzer/pull/119)。

## 目標

- **單行不換行**：頁籤過多時改為水平捲動（觸控／滑鼠拖曳／觸控板皆可），不再往下堆疊多行。
- **三角箭頭導航**：左右各一個三角箭頭，點擊等同切換到「上一個／下一個」頁籤並把它捲入可視範圍；只要超過一個頁籤就永遠顯示，停在第一個時左箭頭停用、最後一個時右箭頭停用（停用仍佔位，版面不跳動）。
- **三欄固定排版**：左箭頭、可捲動頁籤區、右箭頭各佔獨立欄位，箭頭不會遮住邊緣的頁籤；中間捲動區保留邊緣漸隱 fade 提示可捲方向（由實際捲動位置驅動，與箭頭停用狀態解耦）。

## 非目標

- 不改頁籤的內容、順序與既有「只有一個 chip 時整列隱藏」邏輯。
- 不改 timeline 的視覺與行為（僅做零行為變更的重構，抽共用元件）。
- 不調整圖片區、簡介、tag 等 dialog 其餘部分。

## 架構

與姐妹專案 PR #119 一對一對應，分三塊：

### 1. 新增共用元件 `lib/widgets/scroll/scroll_affordance.dart`

把目前內嵌在 `lib/widgets/cards/timeline_horizontal.dart` 的 `_ArrowButton`／`_EdgeFade` 抽出為共用元件，消除 timeline 與新頁籤列的重複：

- **`ScrollArrowButton`**：浮在捲動區邊緣的圓形箭頭按鈕。`onPressed` 為 `null` 時呈現**停用樣式**（icon 轉淡至 `textMuted` 0.4、游標為 `basic` 而非手形、`InkWell` 不可點），用於「已到頭／到底」；非 `null` 時為可點的啟用樣式（icon `textPrimary`、游標手形）。沿用既有圓鈕視覺（`surfaceCard` 0.85 底、`textMuted` 0.25 邊框、24×24、icon 16）。帶 `Semantics(button, enabled, label)` 與 `Tooltip`。
- **`ScrollEdgeFade`**：邊緣漸隱遮罩，漸層自 `GachaTokens.surfaceCard`（不透明）漸隱到透明，寬度由外層 `Positioned` 決定。
- **共用常數／enum**：`kScrollAffordanceDuration`（240ms）、`kScrollAffordanceCurve`（`Curves.easeOutCubic`）、`ScrollSide { left, right }`。

### 2. `lib/widgets/cards/timeline_horizontal.dart` 純重構（零行為變更）

改用共用元件，刪除內嵌的 `_ArrowButton`／`_EdgeFade`／私有常數（`_scrollDuration`／`_scrollCurve`／`_ScrollSide`／`_edgeFadeWidth` 視情況沿用或改引共用）。timeline 箭頭維持 `Icons.chevron_left`／`Icons.chevron_right`、維持「真捲動」語意，tooltip 沿用既有 `timelineScrollLeft`／`timelineScrollRight`。既有 timeline 測試須維持綠。

### 3. 新增 `lib/widgets/dialogs/gallery_chip_bar.dart`：`GalleryChipBar`

單行可水平捲動的頁籤列，三欄固定排版「左箭頭欄｜可捲動 ChoiceChip 列（含邊緣 fade）｜右箭頭欄」。

API：
- `labels: List<String>` —— 各頁籤顯示文字，順序即顯示順序。
- `selectedIndex: int` —— 當前選中索引（呼叫端保證 `0 <= selectedIndex < labels.length`）。
- `onSelected: ValueChanged<int>` —— 切換頁籤回呼。

關鍵設計：
- **箭頭**用 `Icons.arrow_left`／`Icons.arrow_right`（**實心三角**，對齊姐妹專案），由**選中索引是否在頭／尾**驅動停用：`selectedIndex > 0` 才啟用左箭頭、`selectedIndex < lastIndex` 才啟用右箭頭，點擊呼叫 `onSelected(selected ∓ 1)`。
- **fade** 由實際 scroll offset 驅動（`_updateAffordance` 監聽 `ScrollController`），與箭頭停用狀態**解耦**，兩者各自反映「索引位置」與「捲動位置」。
- **自動捲入**：每個頁籤掛 `GlobalKey`，選中變動時以 `Scrollable.ensureVisible(alignment: 0.5)` 把選中頁籤捲入中央；`labels.length` 變動時重建 keys 並把選中項捲回視野。
- **高度**：中間欄用 `Stack` + 非 `Positioned` 的 sizing child（`SingleChildScrollView`）撐高度——dialog 內無固定高度，不能像 timeline 全用 `Positioned.fill`，否則高度塌陷。
- **捲動裝置**：`ScrollConfiguration` 開啟 touch／mouse／trackpad／stylus 拖曳；`MouseRegion` 游標 `resizeLeftRight`。
- 是否顯示整條 bar（只有一個頁籤時隱藏）由呼叫端決定，元件本身不判斷。

### 4. `lib/widgets/dialogs/gacha_item_detail_dialog.dart`

以 `GalleryChipBar(labels: [for chip in chipEntries] chip.label, selectedIndex: clampedIndex, onSelected: (i) => setState(() => _selectedIndex = i))` 取代原本 759–774 行的 `Wrap` + `ChoiceChip` 迴圈。維持外層 `if (chipEntries.length > 1)` 的整列隱藏判斷。

### 5. i18n

新增兩個字串作為三角箭頭 tooltip，語意對應「切換頁籤」而非「捲動畫面」（刻意與 timeline 的 `timelineScroll*` 區分）：

- `galleryPrevTab`：上一個
- `galleryNextTab`：下一個

依本專案慣例只寫核心四 ARB（`app_zh`／`app_zh_Hans`／`app_en`／`app_ja`），其餘 ~27 個 locale 由 Crowdin 補。generated l10n 為 gitignore，須跑 `fvm flutter gen-l10n`。

## 測試

- 新增 `test/widgets/scroll/scroll_affordance_test.dart`：`ScrollArrowButton` 啟用／停用樣式（`onPressed` null 時停用、icon 轉淡）。
- 新增 `test/widgets/dialogs/gallery_chip_bar_test.dart`：頭／尾箭頭停用、點箭頭切到上／下頁、點 chip 切換、選中自動捲入。
- timeline 既有測試維持綠（純重構零行為變更）。
- 提交前品質檢查：`fvm dart format lib/ test/` → `fvm flutter analyze`（`No issues found!`）→ `fvm flutter test`（`All tests passed!`）。

## 風險與注意

- **dialog 高度塌陷**：頁籤列在 dialog 內無固定高度，必須用非 `Positioned` 的 sizing child 撐 `Stack` 高度（見架構 3），照搬 timeline 的全 `Positioned.fill` 會塌陷。
- **箭頭與 fade 解耦**：箭頭看「索引」、fade 看「scroll offset」，兩者語意不同不可合併判斷，否則會出現「右箭頭已停用但內容仍可捲」或反之的不一致。
- **timeline 重構回歸**：抽共用元件後務必確認 timeline 視覺與捲動行為不變（箭頭仍 chevron、停用前 timeline 無停用態——timeline 是「有得捲才顯示箭頭」，與頁籤列「永遠顯示、到頭尾停用」語意不同，重構只共用按鈕外觀不共用顯示邏輯）。
