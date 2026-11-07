# 手機版 UI/UX 調整 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 依已確認的示意圖與設計文件，調整手機直向、手機橫向與電腦版的 13 項 UI/UX 問題，且不遺失任何資料或功能、不讓滑動流暢度退步。

**Architecture:** 在現有元件上以版面條件分支：手機直向、手機橫向、電腦版／寬度。共用判斷集中在 `lib/theme/layout.dart`。外殼負責底部列、側欄社群連結、橫向標題列收合；頁面負責數字卡、圓餅、紀錄列表；對話框類各自獨立成檔。

**Tech Stack:** Flutter（FVM 3.47.5）、Riverpod 3、go_router、flutter_test、gen-l10n（核心四份 ARB）。

**Spec:** `docs/superpowers/specs/2026-11-07-mobile-ui-ux-adjustments-design.md`（示意圖：https://claude.ai/artifact/TeMxuPicwtkHjezNCM7nsL ）

## Global Constraints

- 「手機直向／橫向」專屬規則（底部列、標題列收起、側欄社群連結、橫向卡片）只在 Android／iOS 生效，以 `phoneOrientationOf(context)` 判斷（Task 1 產出）。數字卡與圓餅沿用頁面既有的寬度分支。
- 電腦版外殼、電腦版紀錄表、電腦版圓餅（寬度 ≥ 800）不變。
- 「必須保留不變」清單（spec 同名章節）的每一項都不得消失。
- 新 UI 文字只改核心四份 ARB（`app_en.arb`、`app_zh.arb`、`app_zh_Hans.arb`、`app_ja.arb`），改完跑 `fvm flutter gen-l10n`。中、日文用全形標點，省略號用 ASCII `...`。
- 新對話框一律用 `AppDialog`。
- 新宣告（含 private）寫一行 `///` dartdoc；註解用繁中全形；log 訊息用英文。
- 不得讓 2026-11-07 的流暢度成果退步，包括按需建構（`ListView`／`CustomScrollView`／`SliverFiveStarOverview`）與 keep-alive。
- 每次 commit 前：`fvm dart format lib/ test/` → `fvm flutter analyze`（`No issues found!`）→ `fvm flutter test`（`All tests passed!`）。
- Commit 用英文 conventional commits，結尾附：
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WreXjqEmJ2GoJo17JNX6YF
  ```
  不 push。

## Review Focus

1. **手機橫向、標題列收起時旋轉成直向**：直向標題列必須立即可見（Task 2 測試）。
2. **手機橫向開著鍵盤（點搜尋框）**：不溢出，鍵盤收起後標題列與內容正常（Task 2 測試）。
3. **跳頁輸入非法值**：例如 `12a`、`0`、超過總頁數、貼上空白字元，「前往」不可按也不跳頁（Task 6 測試）。
4. **只有一張圖的物品**：水平拖曳不切換、不拋錯，頁點不顯示（Task 8 測試）。
5. **en／ja 加上 1.3 倍字級、寬 360**：兩欄數字卡、精簡圓餅、篩選排序列都不溢出（Task 3、4、5 測試）。

---

### Task 1: 手機排版判斷、最後更新元件、底部列與側欄社群連結

**Files:**
- Modify: `lib/theme/layout.dart`（新增判斷）
- Create: `lib/widgets/last_updated_label.dart`
- Modify: `lib/pages/app_shell.dart`（底部列、抽屜底部）
- Modify: `lib/pages/overview_page.dart`、`lib/pages/banner_page.dart`（橫向頁首與空資料）
- Test: `test/theme/layout_test.dart`（沒有就建立）、`test/pages/app_shell_test.dart`、`test/pages/phone_layout_pages_test.dart`

**Interfaces:**
- Produces:
  - `enum PhoneOrientation { portrait, landscape }`
  - `PhoneOrientation? phoneOrientationOf(BuildContext context)`：Android／iOS 且 `isCompactLayout` 時依 `width > height` 回傳；其他情況回傳 null。
  - `class LastUpdatedLabel extends ConsumerWidget { const LastUpdatedLabel({super.key, this.style}); final TextStyle? style; }`：有資料時顯示 `RelativeTimeText(footerLastUpdated)`，沒資料時顯示 `footerNotSynced`。外殼底部列與頁首共用，取代 `app_shell.dart` 底部列裡現有的同一段邏輯。

- [ ] **Step 1: 寫失敗測試**
  - `phoneOrientationOf`：Android 360×800 → portrait；Android 800×360 → landscape；Windows 500×300 → null；Android 1280×800（平板，非手機排版）→ null。
  - app_shell（以 `TargetPlatformVariant` 指定平台）：
    - Android 直向：底部列有「最後更新」，底部列內沒有 `TeamLinksBar`。
    - Android 橫向：找不到底部列。
    - 打開抽屜：抽屜內有 `TeamLinksBar`。
    - Windows 1280×800：底部列同時有最後更新與 `TeamLinksBar`，抽屜不存在。
  - 頁面（Android 800×360）：綜合頁與卡池頁頁首有 `LastUpdatedLabel`；沒有資料時畫面有 `footerNotSynced` 文字與 `EmptyState`。Android 360×800 時頁首沒有 `LastUpdatedLabel`。
  - 底部列需要可被測試找到：外層 `Container` 加 `key: const Key('shell-bottom-bar')`。
- [ ] **Step 2:** 執行 `fvm flutter test test/theme/layout_test.dart test/pages/app_shell_test.dart test/pages/phone_layout_pages_test.dart`。Expected：新測試 FAIL。
- [ ] **Step 3: 實作**
  - 判斷函式放進 `layout.dart`。
  - 底部列：`phoneOrientationOf == landscape` 時不建。手機直向時只放 `LastUpdatedLabel`，拿掉 `TeamLinksBar`。電腦版維持原樣，只把文字段換成 `LastUpdatedLabel`。開著鍵盤時收起的既有條件保留。
  - 抽屜：手機時在 `_Rail` 的底部按鈕下方加 `TeamLinksBar()`，非 compact 參數，顯示完整三個圖示和團隊名稱。抽屜太矮時跟著清單一起捲的既有規則照用。
  - 頁首：兩頁的標題 `Row` 在手機橫向時，於標題下方或右側加入 `LastUpdatedLabel`（`bodySmall` 弱色）。
  - 空資料：手機橫向時，回傳 `Column[Padding(LastUpdatedLabel), Expanded(EmptyState.noSync)]`。
- [ ] **Step 4:** 重跑 Step 2 的命令。Expected：PASS。
- [ ] **Step 5:** 品質檢查後 commit：`feat(shell): move phone footer links into the drawer and hide the footer in landscape`

---

### Task 2: 手機橫向標題列捲動收合

**Files:**
- Modify: `lib/pages/app_shell.dart`
- Test: `test/pages/app_shell_test.dart`

**Interfaces:**
- Consumes：Task 1 的 `phoneOrientationOf`。
- Produces：標題列外層 `key: const Key('shell-top-bar')`，供測試量高度。

- [ ] **Step 1: 寫失敗測試**（Android 800×360，頁面放一個 `ListView` 長內容）：
  - 往上拖（內容往下捲）300 → `pumpAndSettle` → `shell-top-bar` 高度 ≈ 0。
  - 再往下拖 50 → 高度恢復為 toolbar 高度。
  - 回到頂端 → 一定可見。
  - **Review Focus 1**：收起狀態下把 `tester.view.physicalSize` 改成 360×800 → 標題列可見。
  - **Review Focus 2**：橫向開鍵盤（`viewInsets.bottom = 200`）不拋例外；鍵盤收起後標題列可見。
  - Android 360×800 直向：往上拖 300 → 高度不變。
- [ ] **Step 2:** 執行 `fvm flutter test test/pages/app_shell_test.dart`。Expected：新測試 FAIL。
- [ ] **Step 3: 實作**
  - 以 `NotificationListener<UserScrollNotification>` 包住 body，只處理 `depth == 0` 且垂直的捲動：`reverse` 收起、`forward` 展開。
  - 另外監聽 `ScrollUpdateNotification`：`pixels <= 0` 時展開。
  - 收起只在 `phoneOrientationOf == landscape` 時生效；方向一變就強制展開。
  - 用 `AnimationController` 驅動 `PreferredSize` 高度。動畫細節由實作者決定（spec 允許）。
  - 狀態列區域避讓：AppBar 收起後，內容區需避開狀態列，`SafeArea(top:)` 改成跟著收起狀態。
- [ ] **Step 4:** 重跑 Step 2 的命令。Expected：PASS。
- [ ] **Step 5:** commit：`feat(shell): collapse the phone landscape top bar while scrolling down`

---

### Task 3: 數字卡兩欄並排與橫向三卡一列

**Files:**
- Modify: `lib/pages/overview_page.dart`（`_OverviewSection` 的 Stat row）
- Modify: `lib/pages/banner_page.dart`（Row 1 保底卡）
- Test: `test/pages/phone_layout_pages_test.dart`

- [ ] **Step 1: 寫失敗測試**
  - 綜合頁 Android 360×800：三張 `StatCard` 中，後兩張的 `dy` 相同、高度相同，且 `dx` 不同；第一張在上方。
  - 卡池頁 Android 360×800：兩張 `PityCard` 中第一張獨佔一列；第二張 `PityCard` 與 `StatCard` 同 `dy`、同高。
  - 卡池頁 Android 800×360：兩張 `PityCard` 與 `StatCard` 同 `dy`，且畫面上有兩個保底進度條。
  - **Review Focus 5**：en、ja 各以 `textScaler 1.3`、寬 360 跑綜合頁與卡池頁，不拋例外。
- [ ] **Step 2:** 執行 `fvm flutter test test/pages/phone_layout_pages_test.dart`。Expected：新測試 FAIL。
- [ ] **Step 3: 實作**
  - 兩頁的 `mid` 改成 `c.maxWidth < 1024`，讓窄寬也走現有的「第一張整列＋其餘並排 `IntrinsicHeight`」分支。
  - 卡池頁另外在 `phoneOrientationOf == landscape` 時走 `wide` 分支。
- [ ] **Step 4:** 重跑 Step 2 的命令。Expected：PASS。
- [ ] **Step 5:** commit：`feat(pages): pair secondary stat cards on phones`

---

### Task 4: 精簡圓餅卡

**Files:**
- Modify: `lib/widgets/cards/chart_card.dart`
- Modify: `lib/widgets/rarity_pie.dart`、`lib/widgets/item_type_pie.dart`
- Modify: `lib/pages/overview_page.dart`（Pie row）、`lib/pages/banner_page.dart`（Row 2 `Wrap`）
- Test: `test/widgets/cards/chart_card_test.dart`、`test/pages/phone_layout_pages_test.dart`

**Interfaces:**
- Produces：
  - `enum ChartCardLayout { standard, compact, compactTitleBeside }`
  - `ChartCard({..., ChartCardLayout layout = ChartCardLayout.standard})`
  - `RarityChartCard({required stats, ChartCardLayout layout = ChartCardLayout.standard})`，`ItemTypeChartCard` 同。

- [ ] **Step 1: 寫失敗測試**
  - `compact`：卡片高度 < 260（原為 380）；圖表區寬高為 112；圖例在圖表右側（圖例左緣 x > 圖表右緣 x）；圖例項目文字（件數、百分比）都找得到。
  - `compactTitleBeside`：標題在圖例欄內（標題 x ≈ 圖例 x）；並排兩張卡（3 列與 2 列圖例）時，兩張的標題 `dy` 相同、第一列圖例 `dy` 相同（靠上對齊）。
  - 頁面：Android 360×800 綜合頁兩張圓餅卡為 `compact`；Android 800×360 卡池頁為 `compactTitleBeside`；Windows 1280×800 為 `standard`（高度 380）。
  - **Review Focus 5**：en、ja 1.3 倍字級、寬 360 不溢出。
- [ ] **Step 2:** 執行 `fvm flutter test test/widgets/cards/chart_card_test.dart test/pages/phone_layout_pages_test.dart`。Expected：新測試 FAIL。
- [ ] **Step 3: 實作**
  - `ChartCard` 的 `compact` 版：標題，再接 `Row(crossAxisAlignment: start)[SizedBox(112×112, chart), gap m, Expanded(legend)]`，`height` 不固定。
  - `compactTitleBeside` 版：`Row(start)[SizedBox(96×96, chart), gap m, Expanded(Column[標題, s, legend])]`。
  - 頁面的選擇規則：寬度 < 800 用 `compact`；`phoneOrientationOf == landscape` 用 `compactTitleBeside`；其餘用 `standard`。
- [ ] **Step 4:** 重跑 Step 2 的命令。Expected：PASS。
- [ ] **Step 5:** commit：`feat(charts): compact pie cards with side legends on phones`

---

### Task 5: 紀錄列表：篩選排序同列、橫向卡片、換頁捲回標題

**Files:**
- Modify: `lib/widgets/data/sortable_table.dart`
  - `_SortButton` 改公開為 `RecordSortButton`。
  - 新增 `showSortButton`、`onPageChanged`，以及判斷函式。
- Modify: `lib/widgets/data/search_filter_bar.dart`（`trailing`）
- Modify: `lib/pages/banner_page.dart`
  - 改為 `ConsumerStatefulWidget`，持有標題 `GlobalKey`。
  - 傳入排序按鈕，處理換頁捲動。
- Test: `test/widgets/data/sortable_table_test.dart`、`test/widgets/data/search_filter_bar_test.dart`、`test/pages/phone_layout_pages_test.dart`

**Interfaces:**
- Produces：
  - `bool recordListUsesCards(BuildContext context, double width)`：`isCompactLayout(context) || width < 600`。
  - `SortableTable({..., bool showSortButton = true, ValueChanged<int>? onPageChanged})`
  - `class RecordSortButton`，建構子與原 `_SortButton` 相同。
  - `SearchFilterBar({..., Widget? trailing})`：放在下拉選單與「清除篩選」之後，同一個 `Wrap`。

- [ ] **Step 1: 寫失敗測試**
  - `recordListUsesCards`：Android 800×360 → true；Windows 寬 900 → false；Windows 寬 500 → true。
  - SearchFilterBar 寬 360：`trailing` 與稀有度下拉同 `dy`。**Review Focus 5**：en、ja 1.3 倍字級、寬 320 不溢出。
  - SortableTable：
    - 換頁時 `onPageChanged` 收到新頁碼。
    - 按「第一頁」且已在第一頁時，不呼叫 `onPageChanged`。
    - `showSortButton: false` 時找不到 `RecordSortButton`。
  - 卡池頁 Android 360×800：
    - 只有一個 `RecordSortButton`，且在 `SearchFilterBar` 內。
    - 捲到分頁器按下一頁後，「紀錄列表」標題的 `dy` 落在標題列下方 ±8 內。
  - 卡池頁 Android 800×360：紀錄以卡片呈現（找不到表格 `_Header` 的排序欄標題，找得到 `RecordSortButton`）。
- [ ] **Step 2:** 執行 `fvm flutter test test/widgets/data/ test/pages/phone_layout_pages_test.dart`。Expected：新測試 FAIL。
- [ ] **Step 3: 實作**
  - `SortableTable` 內部的卡片／表格判斷改用 `recordListUsesCards`。
  - 卡池頁用 `LayoutBuilder` 取得寬度，卡片模式下把 `RecordSortButton` 交給 `SearchFilterBar.trailing`，並傳 `showSortButton: false`。
  - `onPageChanged` 時 `Scrollable.ensureVisible(_recordsTitleKey.currentContext!, alignment: 0, duration: 250ms)`。
  - 保留 Task 2（流暢度計畫）加上的 `ValueKey('banner-search')` 與 `ValueKey('banner-table')`。
- [ ] **Step 4:** 重跑 Step 2 的命令。Expected：PASS。
- [ ] **Step 5:** commit：`feat(records): one-row filters, landscape cards and scroll back on page change`

---

### Task 6: 跳頁對話框

**Files:**
- Create: `lib/widgets/data/jump_to_page_dialog.dart`
- Modify: `lib/widgets/data/pager.dart`（下拉選單改成可點的頁碼按鈕）
- Modify: `lib/widgets/data/sortable_table.dart`（傳 `totalItems`）
- Modify: 核心四份 ARB
- Test: `test/widgets/data/jump_to_page_dialog_test.dart`、`test/widgets/data/pager_test.dart`

**Interfaces:**
- Produces：
  - `Future<int?> showJumpToPageDialog({required BuildContext context, required int currentPage, required int totalPages, int? totalItems})`：回傳 0-based 頁碼，取消時回傳 null。
  - `Pager({..., int? totalItems})`
  - ARB（zh 原文；en、ja、zh_Hans 對應翻譯）：
    - `pagerJumpTitle`「前往頁數」
    - `pagerJumpLabel`「頁碼（{min}–{max}）」
    - `pagerJumpCurrent`「目前在第 {page} 頁，共 {total} 筆」
    - `pagerJumpGo`「前往」
    - `pagerJumpInvalid`「請輸入 {min}–{max} 的頁碼」
    - 「取消」沿用 `actionCancel`。

- [ ] **Step 1: 寫失敗測試**
  - 輸入 `128` 按「前往」→ 回傳 127。
  - 按 Enter 等同前往。
  - **Review Focus 3**：`0`、`368`（共 367 頁）、`12a`、空白、`' '` 時「前往」disabled，並顯示 `pagerJumpInvalid`。
  - 取消 → null。
  - Pager：點頁碼按鈕開出對話框；`totalPages == 1` 時頁碼按鈕 disabled；找不到 `DropdownButton<int>`。
  - 既有的 `paginates with 20 per page (always shows dropdown)` 測試改為驗證頁碼按鈕。斷言語意不放寬：仍要驗 20 筆一頁與 3 頁。
- [ ] **Step 2:** 執行 `fvm flutter test test/widgets/data/`。Expected：新測試 FAIL。
- [ ] **Step 3: 實作**
  - `AppDialog(size: sm)`；輸入框用 `keyboardType: number`、`FilteringTextInputFormatter.digitsOnly`，`autofocus`。
  - Pager 中間改成 `OutlinedButton` 顯示「{page} / {total}」，點擊後 `await showJumpToPageDialog`，有值才 `onChanged`。
  - 跳頁成功時記 log：`Logger('ui.pager').info('jump page from=… to=… total=…')`。
- [ ] **Step 4:** 先執行 `fvm flutter gen-l10n`，再重跑 Step 2 的命令。Expected：PASS。
- [ ] **Step 5:** commit：`feat(pager): jump to a typed page instead of a long dropdown`

---

### Task 7: 空資料提示嵌入更新按鈕圖案

**Files:**
- Modify: `lib/widgets/empty_state.dart`（`noSync`、新增 `messageSpan`）
- Modify: 核心四份 ARB 的 `emptyNoSyncMessage`
- Test: `test/widgets/empty_state_test.dart`（沒有就建立）

**Interfaces:**
- ARB `emptyNoSyncMessage` 改為帶 `{icon}` 佔位符：
  - zh「點右上 {icon} 開始」
  - zh_Hans「点右上 {icon} 开始」
  - en「Tap {icon} in the top right to start」
  - ja「右上の {icon} から開始してください」
  - `@emptyNoSyncMessage` 補 placeholders 說明。
- `EmptyState({..., InlineSpan? messageSpan})`：有值時優先於 `message`。

- [ ] **Step 1: 寫失敗測試**
  - Android 360×800：`EmptyState.noSync` 的訊息 `Text.rich` 內含 `WidgetSpan`，其中有 `Icons.refresh` 的圓形底。
  - Windows 1280×800：`WidgetSpan` 內同時有 `Icons.refresh` 與 `actionUpdate` 文字。
  - 若翻譯字串沒有 `{icon}`（測試用替身字串），整段以純文字顯示、不拋錯。
  - 四個核心 locale 都能找到 `WidgetSpan`。
- [ ] **Step 2:** 先 `fvm flutter gen-l10n`，再執行 `fvm flutter test test/widgets/empty_state_test.dart`。Expected：新測試 FAIL。
- [ ] **Step 3: 實作**
  - `noSync` 以標記字元呼叫 `l.emptyNoSyncMessage(marker)`，再依標記切成前後兩段，中間放 `WidgetSpan`。找不到標記時退回純文字。
  - 手機排版用圓形底 `Icons.refresh`；電腦版用縮小的按鈕樣子（`Icons.refresh` 加 `actionUpdate`，主色底、圓角）。
- [ ] **Step 4:** 重跑 Step 2 的命令。Expected：PASS。
- [ ] **Step 5:** commit：`feat(empty-state): point the no-sync hint at the actual update button`

---

### Task 8: 詳情圖片左右滑動、頁點、箭頭點擊範圍

**Files:**
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`（`_buildCurrentImageArea` 外包水平拖曳、頁點）
- Modify: `lib/widgets/scroll/scroll_affordance.dart`（`ScrollArrowButton` 新參數）
- Modify: `lib/widgets/dialogs/gallery_chip_bar.dart`（傳新參數）
- Test: `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`（沿用既有檔）、`test/widgets/dialogs/gallery_chip_bar_test.dart`

**Interfaces:**
- Produces：`ScrollArrowButton({..., bool largeHitArea = false})`：true 時不論平台都包 48dp 觸控區；false 時維持現行（僅手機排版放大）。

- [ ] **Step 1: 寫失敗測試**（沿用既有測試的多圖物品替身）
  - 在圖片區 `drag(Offset(-120, 0))` → 選中第 2 張；`drag(Offset(120, 0))` → 回到第 1 張。
  - 第 1 張往右拖不變；最後一張往左拖不變。
  - `drag(Offset(0, -120))` 不切換。
  - 拖曳距離 20、速度低 → 不切換。
  - 點圖片仍開啟放大層；⋮ 選單仍在。
  - 頁點數量 = 圖片數，第 1 個為選中樣式。**Review Focus 4**：只有一張圖時沒有頁點，拖曳不拋錯。
  - GalleryChipBar 在 Windows 1280×800：兩個箭頭的觸控區尺寸 ≥ 44×44。
- [ ] **Step 2:** 執行 `fvm flutter test test/widgets/dialogs/`。Expected：新測試 FAIL。
- [ ] **Step 3: 實作**
  - 圖片區外包 `GestureDetector(onHorizontalDragUpdate: 累加 dx, onHorizontalDragEnd: |dx| ≥ 48 或 |velocity| ≥ 300 時依方向改 _selectedIndex)`。
  - 放手後直接換圖，不做跟手輪播（使用者選定）。
  - 頁點 `_PageDots(count, index)`：放在圖片區底部，選中的寬 18、主色，其餘 6×6、`borderEmphasis` 色。
- [ ] **Step 4:** 重跑 Step 2 的命令。Expected：PASS。
- [ ] **Step 5:** commit：`feat(item-detail): swipe between images with page dots`

---

### Task 9: 詳情雙欄擴大到電腦版、左欄單一捲動與底部提示

**Files:**
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`
- Modify: `lib/widgets/dialogs/app_dialog.dart`（新增 `AppDialogSize.xl`，960）
- Modify: `lib/widgets/scroll/scroll_affordance.dart`（`ScrollSide.bottom`）
- Test: `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`、`test/widgets/dialogs/app_dialog_test.dart`

**Interfaces:**
- Produces：
  - `AppDialogSize.xl`（maxWidth 960）
  - `ScrollEdgeFade(side: ScrollSide.bottom)`：由下往上漸隱。

- [ ] **Step 1: 寫失敗測試**
  - 雙欄判斷：
    - Windows 1280×800 → 雙欄，左欄寬 320。
    - Windows 900×700 → 單欄。
    - Android 800×360 → 雙欄，左欄寬 240。
    - Android 360×800 → 單欄。
  - 雙欄時左欄只有一個 `Scrollable`。在簡介文字上往上拖 200 → 左欄 `ScrollPosition.pixels > 0`，且簡介文字跟著移動，涵蓋使用者以「千咲」回報的情境。測試用的長簡介要超過原本的 96dp。
  - 左欄內容超出時有 `ScrollEdgeFade(bottom)`；捲到底後消失。
  - 「在 encore.moe 查看」與「關閉」在捲動前後的 `dy` 不變。
  - 單欄（手機直向）時，簡介仍是原本的 96dp 上限加內層捲動，不退步。
- [ ] **Step 2:** 執行 `fvm flutter test test/widgets/dialogs/`。Expected：新測試 FAIL。
- [ ] **Step 3: 實作**
  - `twoColumn = phoneOrientationOf(context) == landscape || (!isCompactLayout(context) && size.width >= 1000)`。
  - 電腦版雙欄用 `AppDialogSize.xl`，左欄寬 320；手機橫向維持 lg、240。
  - 簡介與造型說明的建構函式加 `bool constrainHeight`，雙欄時傳 false，不包 `ConstrainedBox`／`SingleChildScrollView`。
  - 左欄 `SingleChildScrollView` 給 `ScrollController`，依 `maxScrollExtent > pixels` 決定是否疊 `ScrollEdgeFade(bottom)`。
- [ ] **Step 4:** 重跑 Step 2 的命令。Expected：PASS。
- [ ] **Step 5:** commit：`feat(item-detail): two-column layout on desktop with one scrolling info column`

---

### Task 10: 帳號管理收成一列與 ⋮ 選單

**Files:**
- Modify: `lib/widgets/cards/account_management.dart`（`_Row` 改版，移除常駐 `TextField`）
- Create: `lib/widgets/dialogs/edit_alias_dialog.dart`
- Modify: 核心四份 ARB（新增 `accountAliasNone`「未設定別名」、`accountActionEditAlias`「編輯別名」、`accountEditAliasTitle`「編輯別名」，其餘按鈕文字先 grep 既有 key 沿用）
- Test: `test/widgets/cards/account_management_test.dart`

**Interfaces:**
- Produces：`Future<String?> showEditAliasDialog({required BuildContext context, required String uid, required String initial})`：回傳去頭尾空白後的字串，空字串代表移除別名；取消時回傳 null。

- [ ] **Step 1: 寫失敗測試**
  - 每列沒有 `TextField`。
  - 無別名的列顯示 `accountAliasNone`；有別名的列顯示別名。
  - 使用中標籤只在 active 列。
  - ⋮ 選單：active 列只有「編輯別名」「移除帳號」；非 active 列多了「設為使用中」。
  - 「設為使用中」→ `activeUid` 改變。
  - 「編輯別名」→ 對話框預填 → 改成 `Main` 按儲存 → `uidAliases[uid] == 'Main'`；清空後儲存 → 別名移除；Enter 等同儲存；取消不變。
  - 「移除帳號」→ 出現既有的打字確認對話框。
  - 拖曳把手仍可重新排序（沿用既有排序測試）。
- [ ] **Step 2:** 執行 `fvm flutter test test/widgets/cards/account_management_test.dart`。Expected：新測試 FAIL。
- [ ] **Step 3: 實作**
  - 列：把手、`Expanded(Column[UID＋使用中標籤, 別名或 accountAliasNone（弱色）, 最後更新])`、`PopupMenuButton`。
  - 別名儲存沿用 `settingsNotifier.setUidAlias`。
  - 移除沿用 `_remove`。
  - 遮罩 UID 的設定（`maskUid`）照舊套用到 UID 文字。
- [ ] **Step 4:** 先 `fvm flutter gen-l10n`，再重跑 Step 2 的命令。Expected：PASS。
- [ ] **Step 5:** commit：`feat(accounts): compact account rows with an actions menu`

---

### Task 11: 實機驗收與記錄（主控執行，需要模擬器或手機）

**Files:**
- Modify: `docs/Android移植筆記.md`（`### 42.` 新條目，記錄版面條件與踩雷）

- [ ] **Step 1:** 建 x64 profile 版，裝到 Medium Phone 模擬器（資料已在模擬器上）；手機有接時也裝 arm64 版。
- [ ] **Step 2:** 直向、橫向各截圖：綜合頁、卡池頁（上半、紀錄列表、跳頁）、側欄、空資料（另開一個沒資料的帳號狀態或清空測試資料前先備份）、詳情（直向、橫向）、設定的帳號管理。逐張與示意圖比對，並確認「必須保留不變」清單逐項都在。
- [ ] **Step 3:** 用 `tool/measure_frame_pacing.sh` 量綜合頁與卡池頁，慣性滑動準時率要 ≥ 95%。只有實機數字算數；沒接手機時記錄為「未在實機驗證」。
- [ ] **Step 4:** Windows 建 profile 版開起來看：底部列、紀錄表、詳情雙欄、帳號管理、跳頁對話框。測完把視窗大小調回原狀再關閉。
- [ ] **Step 5:** 寫 `### 42.` 後品質檢查並 commit。條目開頭要附示意圖連結 https://claude.ai/artifact/TeMxuPicwtkHjezNCM7nsL 與設計文件路徑，供原神版移植時參考；內容標明哪些規則通用、哪些只限本專案：`docs(android): record phone layout rules for the UI/UX pass`
