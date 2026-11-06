# 手機版面（RWD 與觸控）實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 短邊 < 600dp 時切成手機排版（抽屜導覽、精簡標題列與狀態列、記錄卡片列、12dp 對話框），並讓看圖等元件適合觸控；寬螢幕行為完全不變。

**Architecture:** 新增一個集中判斷 `isCompactLayout(context)`（短邊 < 600），各元件在原地依它或依自身 `LayoutBuilder` 寬度切換排版；不另寫手機頁面、不新增依賴。觸控手勢（雙指縮放、觸控點兩下、長按選單、往下滑關閉）不看排版一律開啟，滑鼠路徑不變。

**Tech Stack:** Flutter（FVM 釘版）、Riverpod 3、go_router、flutter_test。

**Spec:** `docs/superpowers/specs/2026-11-06-mobile-layout-design.md`

## Global Constraints

- 手機排版判斷：`MediaQuery.sizeOf(context).shortestSide < 600`，不分平台；所有元件都呼叫 Task 1 的 `isCompactLayout`，不在別處重寫判斷。
- 內容排版依可用寬度；記錄區 `< 600` 用卡片列，其餘沿用各元件既有分界（800、1024、1180）。
- 48dp 觸控目標只在手機排版套用；寬螢幕維持現有尺寸與外觀（反目標：寬螢幕行為改變）。
- 內容、入口、欄位、排序與篩選規則和桌面版相同；排序一律走既有 `RecordFilterNotifier.cycleSort`（降冪 → 升冪 → 不排序）。
- 對話框一律 `AppDialog`；新宣告都寫一行 `///` dartdoc；log 訊息英文、沿用 `gacha.itemimage.zoom` 等既有 Logger 名稱。
- 新字串只加核心四 ARB（`app_en.arb`、`app_zh.arb`、`app_zh_Hans.arb`、`app_ja.arb`），`app_en.arb` 附 `@` 描述；中文全形標點，省略號用 ASCII `...`；改 ARB 後跑 `fvm flutter gen-l10n`。
- 不新增依賴；不動 `rust_builder/`；Windows 最小視窗維持 800×450。
- 測試尺寸：手機直向 360×800、手機橫向 800×360、桌面 1280×800（`tester.view.physicalSize` ＋ `devicePixelRatio = 1`，`addTearDown(tester.view.reset)`）；overflow 以 `tester.takeException()` 為 null 判定。
- 每個 commit 前：`fvm dart format lib/ test/`、`fvm flutter analyze`（`No issues found!`）、`fvm flutter test`（`All tests passed!`）。commit 訊息英文 conventional commits，結尾附專案規定的兩行 attribution。不要 push。

## Review Focus

1. **轉向時抽屜或對話框正開著**：不應丟例外，抽屜關閉或維持可用，頁面不錯位 → Task 3 測試 `rotating with the drawer open does not throw`。
2. **手機上開著鍵盤搜尋**（`viewInsets.bottom` ≈ 300）：篩選列與記錄列不 overflow → Task 9 測試 `banner page with keyboard open does not overflow`。
3. **英文、日文等較長字串在 360dp**：標題列、抽屜項目、排序按鈕不 overflow → Task 3、Task 5 測試加 `en` 語系變體。
4. **系統字級放大（textScaler 1.3）**：手機標題列與記錄卡片不 overflow → Task 3、Task 5 測試加 `textScaler: TextScaler.linear(1.3)` 變體。
5. **轉向導致卡片列 ↔ 表格切換**：目前頁碼與排序保留 → Task 5 測試 `switching between cards and table keeps the page`。

---

### Task 1: 手機排版判斷

**Files:**
- Create: `lib/theme/layout.dart`
- Test: `test/theme/layout_test.dart`

**Interfaces:**
- Produces: `const double kCompactShortestSide = 600;`、`bool isCompactLayout(BuildContext context)`。後續所有 Task 都用它。

- [ ] **Step 1: 寫失敗的測試** `test/theme/layout_test.dart`：用 `MediaQuery(data: MediaQueryData(size: ...))` 包一個 `Builder` 讀 `isCompactLayout`。

```dart
for (final (size, want) in [
  (const Size(360, 800), true),   // 手機直向
  (const Size(800, 360), true),   // 手機橫向
  (const Size(800, 450), true),   // Windows 最小視窗（高度 < 600）
  (const Size(1280, 800), false), // 桌面
  (const Size(600, 1000), false), // 短邊剛好 600 不算手機
]) {
  testWidgets('isCompactLayout ${size.width}x${size.height}', (tester) async {
    late bool got;
    await tester.pumpWidget(MediaQuery(
      data: MediaQueryData(size: size),
      child: Builder(builder: (c) { got = isCompactLayout(c); return const SizedBox(); }),
    ));
    expect(got, want);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗** `fvm flutter test test/theme/layout_test.dart` → 編譯失敗（找不到 `isCompactLayout`）。
- [ ] **Step 3: 實作** `lib/theme/layout.dart`：`MediaQuery.sizeOf(context).shortestSide < kCompactShortestSide`。
- [ ] **Step 4: 跑測試確認通過**。
- [ ] **Step 5: Commit** `feat(layout): add a shared compact layout check`。

---

### Task 2: `AppDialog` 手機邊距

**Files:**
- Modify: `lib/widgets/dialogs/app_dialog.dart`
- Test: `test/widgets/dialogs/app_dialog_test.dart`

**Interfaces:**
- Consumes: `isCompactLayout`。
- Produces: 手機排版時 `AppDialog` 四周 12dp（`AlertDialog.insetPadding: EdgeInsets.all(12)`），寬 `min(size.maxWidth, mq.width - 24)`，高上限 `min(maxHeight ?? 720, mq.height - 24)`；寬螢幕維持 40／120 規則。Task 6 依賴此行為。

- [ ] **Step 1: 寫失敗的測試**（加到既有 `app_dialog_test.dart`）
  - `compact dialog leaves 12dp around it`：360×800 下 `AppDialogSize.md` 的 `find.byType(Dialog)` 寬度 `== 336`。
  - `compact dialog uses almost all the height`：800×360 下內容很高（`SizedBox(height: 2000)` 搭 `scrollable: true`）時 Dialog 高度 `== 336`。
  - `wide dialog is unchanged`：1280×800 下 `md` 寬度維持現有值（以現有測試的期望為準）。
  - `compact dialog wraps long action buttons`：360×800 下放三個長文字按鈕，`takeException()` 為 null。
- [ ] **Step 2: 確認失敗**（寬度目前是 360 − 80 = 280）。
- [ ] **Step 3: 實作**：依 `isCompactLayout` 選邊距常數（12 或既有 40／120），並把邊距傳給 `AlertDialog.insetPadding`。
- [ ] **Step 4: 確認通過**，並跑 `test/widgets/dialogs/` 全部。
- [ ] **Step 5: Commit** `feat(layout): give dialogs 12dp margins on phones`。

---

### Task 3: 外殼：抽屜導覽、標題列、狀態列

**Files:**
- Modify: `lib/pages/app_shell.dart`、`lib/widgets/team_links_bar.dart`、`lib/widgets/uid_indicator.dart`
- Test: Create `test/pages/app_shell_test.dart`；Modify `test/widgets/team_links_bar_test.dart`、`test/widgets/uid_indicator_test.dart`

**Interfaces:**
- Consumes: `isCompactLayout`。
- Produces:
  - `TeamLinksBar({super.key, this.compact = false})`：`compact` 時隱藏分隔線與團隊名稱，三個圖示按鈕觸控區 48×48。
  - `AccountTriggerLabel` 在受限寬度內可縮：別名改 `Flexible`（省略號），UID 與兩個圖示不縮；寬度仍不夠時 UID 也以省略號截斷，不 overflow。寬螢幕外觀不變（別名上限 160 照舊）。
  - `AppShell`：`isCompactLayout` 時 `Scaffold.drawer` 放 `_NavDrawer`，不顯示 `_Rail` 與 `VerticalDivider`；寬螢幕不變。

**實作要點**
- `_NavDrawer`：沿用 `_RailDestinationTile`（`extended: true`）、`_SectionLabel`（`extended: true`）、`_BottomRailButton`（`extended: true`）與同樣的 `_resolveRailSelection`、圖示、短名，項目高度至少 48dp。點項目：先 `Navigator.of(context).pop()` 關抽屜再 `context.go(...)`。
- 標題列（手機）：`Row(mainAxisSize: min, [app icon 40, SizedBox(s), Flexible(Text(l.appName, maxLines: 1, overflow: ellipsis))])`，不含版本號；actions 中帳號標示包 `ConstrainedBox(maxWidth: max(0, width - 56 - 64 - 56))`（扣掉 ☰、更新按鈕含外距、App 圖示），更新改 `IconButton.filled(icon: Icon(Icons.refresh), tooltip: l.actionUpdate, onPressed: 同一個 update)`。
- 狀態列（手機）：`TeamLinksBar(compact: true)`；最後更新文字已有省略號，保持單行。
- 頁面外距由 Task 9 處理，這裡不動。

- [ ] **Step 1: 寫失敗的測試** `test/pages/app_shell_test.dart`
  - 測試骨架：`GoRouter` 用 `ShellRoute(builder: (_, _, child) => AppShell(child: child))`，路由 `/`、`/banner/:type`、`/settings`、`/contributors` 都回 `Text('page:<path>')`。必要的 override：`appVersionProvider`（`'1.8.1'`）、`gachaRepositoryProvider`（fake：`isBootstrapping: false`、一個 `activeUid` 與 `BannerStorage`）、`appReleaseProvider`（fake notifier，`check` 不發請求）、`cloudSyncProvider`（fake notifier，`start` 不做事；可參考 `test/helpers/cloud_sync_fakes.dart`）。
  - `phone portrait uses a drawer instead of the rail`（360×800）：找得到 `MaterialLocalizations.openAppDrawerTooltip` 的按鈕；`find.text(l.navOverview)` 在打開前 `findsNothing`。
  - `drawer lists the same destinations and marks the current page`：打開抽屜後總覽、12 個卡池短名、貢獻者、設定都在；每個項目高度 `>= 48`。
  - `tapping a drawer item navigates and closes the drawer`：點 `l.gachaTypeWeaponShort` → `find.text('page:/banner/<weapon key>')` 存在、`Scaffold.of(...).isDrawerOpen == false`。
  - `phone landscape also uses the drawer`（800×360）。
  - `desktop keeps the rail`（1280×800）：沒有抽屜按鈕、`l.navOverview` 可見、版本號 `v1.8.1` 可見。
  - `phone title hides the version and never overflows`：360×800，alias 設成很長字串，`find.textContaining('v1.8.1')` `findsNothing`、`takeException()` 為 null、UID 文字仍 `findsOneWidget`。再跑 `en` 語系與 `textScaler 1.3` 變體（Review Focus 3、4）。
  - `phone update button is an icon with a tooltip`：找得到 `tooltip == l.actionUpdate` 的 `IconButton`，點下去會呼叫 fake repo 的 `update`。
  - `phone footer keeps last updated and icon links only`：`TeamLinksBar` 的 `compact == true`、`find.text(TeamInfo.name)` `findsNothing`；最後更新文字存在。
  - `rotating with the drawer open does not throw`（Review Focus 1）：360×800 打開抽屜 → 改成 800×360 → pump → `takeException()` 為 null。
- [ ] **Step 2: 補元件測試**：`team_links_bar_test.dart` 加 `compact hides the team name and uses 48dp targets`；`uid_indicator_test.dart` 加 `label shrinks the alias first when width is limited`（`SizedBox(width: 160)` 內，UID 全部可見、無例外）。
- [ ] **Step 3: 確認失敗**。
- [ ] **Step 4: 實作**（見上方要點）。
- [ ] **Step 5: 確認通過**，並跑 `test/widgets/` 與 `test/pages/` 全部。
- [ ] **Step 6: Commit** `feat(layout): navigate with a drawer and slim the app bar on phones`。

---

### Task 4: 篩選列手機排版

**Files:**
- Modify: `lib/widgets/data/search_filter_bar.dart`
- Test: `test/widgets/data/search_filter_bar_test.dart`

**Interfaces:**
- Produces: 可用寬度 `< 600` 時搜尋欄佔滿整行（其餘照舊在 `Wrap` 中換行）；寬螢幕維持 240 寬。

- [ ] **Step 1: 失敗測試** `search field spans the row on narrow widths`：父層寬 344 時 `TextField` 寬度 `== 344`；寬 900 時 `== 240`。
- [ ] **Step 2: 確認失敗**。
- [ ] **Step 3: 實作**：外層 `LayoutBuilder` 決定搜尋欄寬度。
- [ ] **Step 4: 確認通過**。
- [ ] **Step 5: Commit** `feat(layout): full-width record search on narrow screens`。

---

### Task 5: 記錄卡片列與排序選單

**Files:**
- Modify: `lib/widgets/data/sortable_table.dart`
- Modify: 核心四 ARB
- Test: `test/widgets/data/sortable_table_test.dart`

**Interfaces:**
- Consumes: 既有 `SortableTable({rows, sort, mainRank, onSortColumnTapped})`、`SortColumn`、`TableSort`、`SortDirection`、`GachaItemTapTarget`、`GachaItemIcon`、`luckColorFor`／`luckTierFor`／`pityThresholdFor`。
- Produces: `SortableTable` 內部以 `LayoutBuilder` 判斷：寬度 `< 600` 時畫 `_SortButton` ＋ `_RecordCard` 列表（同一個 `State`，`_page` 與分頁器共用），否則畫現有表格。公開 API 不變。
- 新 ARB key：`tableSortButton`（`"排序：{column}"`，placeholder `column` String）、`tableSortDefault`（`"排序：預設"`）、`tableSortSheetTitle`（`"排序方式"`）。en：`"Sort: {column}"`、`"Sort: default"`、`"Sort by"`；ja：`"並べ替え：{column}"`、`"並べ替え：既定"`、`"並べ替え"`；zh_Hans：`"排序：{column}"`、`"排序：默认"`、`"排序方式"`。

**實作要點**
- `_RecordCard`：整張卡包 `GachaItemTapTarget(record: ...)`，`minHeight: 48`；第一行 `GachaItemIcon(size: 36)`、名稱（省略號，5★／4★ 用表格同樣的 accent）、星級（`_Pill` 或 `l.rarityStar`）；第二行 `'${formatAbsoluteDateTime} (${relativeTime})' · '#${totalIndex}' · 保底 ${mainPityIndex}`（保底數字用表格同樣的 `pityLuck` 顏色）。條紋背景同表格。
- `_SortButton` 放在 `SortableTable` 內、卡片列上方（`SortableTable` 才持有排序狀態；畫面上緊接在篩選列下方，和草圖的位置相同）。文字為 `l.tableSortButton('<欄位名> ↓/↑')` 或 `l.tableSortDefault`；點擊 `showModalBottomSheet`，標題 `l.tableSortSheetTitle`，6 個 `ListTile`（欄位名沿用 `tableTime`、`tableName`、`tableKind`、`tableRarity`、`tableTotalIndex`、`tableMainPity`），目前排序那列 `trailing` 顯示方向箭頭＋勾；點某列 → `onSortColumnTapped(col)` 後關閉。

- [ ] **Step 1: 失敗測試**
  - `narrow width shows record cards instead of the table`：寬 360 時找不到表格標題列（`find.text(l.tableTotalIndex)` `findsNothing`），每筆名稱、`#<totalIndex>` 與保底數字都在；卡片高度 `>= 48`。
  - `wide width keeps the table`：寬 900 時 `l.tableTotalIndex` 標題存在。
  - `sort sheet calls cycleSort with the tapped column`：點 `_SortButton` → 底部選單出現 6 欄 → 點 `l.tableName` → callback 收到 `SortColumn.name`、選單關閉。
  - `sort button shows the current column and direction`：`sort: TableSort(column: SortColumn.time, direction: SortDirection.desc)` 時文字含 `l.tableTime` 與 `↓`；`sort: null` 時為 `l.tableSortDefault`。
  - `tapping a card opens item detail`：卡片的祖先有 `GachaItemTapTarget`。
  - `switching between cards and table keeps the page`（Review Focus 5）：45 筆資料，在 360 寬切到第 2 頁 → 改成 900 寬 → `Pager` 仍顯示第 2 頁。
  - `cards do not overflow with english and large text`（Review Focus 3、4）：`en` ＋ `textScaler 1.3`、360 寬，`takeException()` 為 null。
- [ ] **Step 2: 確認失敗**。
- [ ] **Step 3: 實作**；改 ARB 後 `fvm flutter gen-l10n`。
- [ ] **Step 4: 確認通過**。
- [ ] **Step 5: Commit** `feat(layout): show records as cards with a sort sheet on phones`。

---

### Task 6: 物品詳情對話框（橫向兩欄、長按選單）

**Files:**
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`
- Test: `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`

**Interfaces:**
- Consumes: `isCompactLayout`、Task 2 的 `AppDialog` 邊距。
- Produces: 手機橫向（`isCompactLayout && width > height`）時對話框內容改兩欄：左欄 = 圖示＋名稱、簡介（可捲動）、標籤、兩個動作按鈕；右欄 = `GalleryChipBar` ＋ 圖片區（＋造型說明）。直向與寬螢幕維持現有結構。圖片區既有的右鍵選單（`onSecondaryTapDown`）同時接 `onLongPressStart`（同一個選單、log 寫 `source=longpress`）。

- [ ] **Step 1: 失敗測試**（沿用該檔既有的 pump 與 fixture）
  - `phone landscape puts details and image side by side`：800×360 下名稱文字的右緣 `<` 圖片區（或 `GalleryChipBar`）的左緣，兩者頂端差距 `< 100`；`takeException()` 為 null。
  - `phone portrait stacks details above the image`：360×800 下名稱底端 `<` 圖片區頂端；無例外。
  - `long press on the image opens the image menu`：長按圖片 → 出現 `l.actionSaveImage`。
- [ ] **Step 2: 確認失敗**。
- [ ] **Step 3: 實作**：兩欄時不使用 `AppDialog.title`，改把兩欄都放進 `content`（仍是 `AppDialog`）；actions 移到左欄底部、`AppDialog.actions` 傳空。
- [ ] **Step 4: 確認通過**。
- [ ] **Step 5: Commit** `feat(layout): lay out item details in two columns on landscape phones`。

---

### Task 7: 看圖元件觸控

**Files:**
- Modify: `lib/widgets/dialogs/zoomable_image_overlay.dart`
- Test: `test/widgets/dialogs/zoomable_image_overlay_test.dart`

**Interfaces:**
- Consumes: `isCompactLayout`。
- Produces（行為）：
  - `InteractiveViewer.scaleEnabled: true`（雙指縮放，範圍沿用 `_minScale`..`_maxScale`）。
  - `_onTapZoom` 依 `TapUpDetails.kind` 分流：`PointerDeviceKind.mouse`（及非觸控）維持立即縮放；`touch` 單擊不動作，兩次觸控點擊間隔 `<= kDoubleTapTimeout` 且距離 `<= kDoubleTapSlop` 時切換縮放（焦點為第二次點擊位置）。不加 `DoubleTapGestureRecognizer`（會延遲滑鼠單擊）。
  - 圖片 `GestureDetector` 加 `onLongPressStart` → `_showImageContextMenu(details.globalPosition)`，log `menu open source=longpress`。
  - 往下滑關閉：在外層 `Listener` 用原始指標事件判斷（不進手勢競技場）：單指、未放大、`dy > 120` 且 `|dy| > 2 * |dx|` 於放開時 → `_close('swipe-down')`；放大時不關閉。
  - 圖片外距：`isCompactLayout` 時 8，否則 48。
  - viewport 尺寸改變（轉向）時 `_ctrl.value = Matrix4.identity()`（在 `LayoutBuilder` 比對上次 constraints，post-frame 重設）。
  - `_close` 的 reason 註解補上 `swipe-down`。

- [ ] **Step 1: 失敗測試**
  - `pinch zooms in`：兩個觸控手勢從中心向外各移 100dp → `_ctrl` 的 scale `> 1`（以 `InteractiveViewer.transformationController.value.getMaxScaleOnAxis()` 讀）。
  - `single touch tap does nothing`：`tester.tapAt(center, kind: PointerDeviceKind.touch)` → scale `== 1`、overlay 仍開著。
  - `double touch tap toggles zoom`：兩次觸控點擊間隔 100ms → scale `== 2`；再兩次 → `== 1`。
  - `mouse click zooms immediately`：`kind: mouse` 點一下後只 `pump()`（不等 300ms）→ scale `== 2`。
  - `long press opens the image menu`：出現 `l.actionCopyImage`、`l.actionSaveImage`。
  - `swipe down closes when not zoomed`：觸控往下拖 200dp → overlay 消失。
  - `swipe down pans when zoomed`：先放大再往下拖 → overlay 仍在。
  - `rotating resets the zoom`：放大後把 view 從 360×800 改成 800×360 → pump → scale `== 1`。
  - `phone padding is 8`：360×800 下圖片區（`InteractiveViewer`）與畫面邊緣距離 `== 8`。
- [ ] **Step 2: 確認失敗**。
- [ ] **Step 3: 實作**。
- [ ] **Step 4: 確認通過**，並跑既有該檔測試（滾輪、右鍵、ESC、縮放鈕）全部仍綠。
- [ ] **Step 5: Commit** `feat(layout): make the image viewer touch friendly`。

---

### Task 8: 觸控小元件：水平捲動、說明、拖曳把手

**Files:**
- Modify（依測試結果需要時）：`lib/widgets/cards/timeline_horizontal.dart`、`lib/widgets/dialogs/gallery_chip_bar.dart`、`lib/widgets/cards/five_star_overview.dart`、`lib/widgets/cards/account_management.dart`、`lib/widgets/data/sortable_table.dart`（表頭保底說明）
- Test: 對應的 `test/widgets/cards/*_test.dart`、`test/widgets/dialogs/gallery_chip_bar_test.dart`

**Interfaces:**
- Consumes: `isCompactLayout`。
- Produces：手機排版時以下成立；寬螢幕不變。

- [ ] **Step 1: 失敗（或確認已通過的）測試**，每項在 360×800 下：
  - `timeline scrolls with a finger drag`：觸控往左拖 → 捲動位置增加。
  - `gallery chips scroll with a finger drag`：同上。
  - `five-star item tooltip appears on long press`：長按 5★ 項目 → tooltip 文字出現（若該項點一下沒有其他動作，改成點一下就出現，測試相應調整）。
  - `account drag handle is at least 48dp on phones`：把手的 hit 區 `>= 48×48`。
  - 每個測試同時斷言 `takeException()` 為 null。
- [ ] **Step 2: 跑測試**；已通過的項目在 ledger 記下「現況已符合」，不改程式。
- [ ] **Step 3: 只修失敗的項目**（觸控區用 `ConstrainedBox(minWidth/minHeight: 48)` 或 `Tooltip(triggerMode: ...)`，僅在 `isCompactLayout` 時）。
- [ ] **Step 4: 確認通過**。
- [ ] **Step 5: Commit** `feat(layout): touch targets and hints for small widgets on phones`。

---

### Task 9: 頁面巡檢：總覽、卡池、設定、貢獻者、讀取設定

**Files:**
- Modify：`lib/pages/overview_page.dart`、`lib/pages/banner_page.dart`（手機排版外距改 `AppSpacing.m`），以及巡檢中 overflow 的頁面（`settings_page.dart`、`contributors_page.dart`、`log_access_setup_page.dart`、各 `widgets/cards/*`），橫排放不下改 `Wrap`。
- Test: Create `test/pages/phone_layout_pages_test.dart`

**Interfaces:**
- Consumes: `isCompactLayout`、Task 3–5 的成果。

- [ ] **Step 1: 失敗測試** `test/pages/phone_layout_pages_test.dart`：fake `GachaRepository`（`isBootstrapping: false`、一個帳號的 `BannerStorage`，角色池含 5★、4★、3★ 各數筆）＋設定頁既有測試需要的 override（參考 `test/pages/settings_page_log_access_test.dart` 的 `pump`），在 360×800 與 800×360 兩種尺寸各 pump：
  - `overview page fits a phone`、`banner page fits a phone`、`settings page fits a phone`（Android：`isAndroidProvider` true）、`contributors page fits a phone`、`log access setup page fits a phone`：捲動到底（`tester.drag` 直到 `ScrollPosition.atEdge`）全程 `takeException()` 為 null。
  - `banner page with keyboard open does not overflow`（Review Focus 2）：360×800、`MediaQueryData.viewInsets.bottom = 300`。
  - `banner page padding is 12 on phones`：頁面第一個卡片左緣 `== 12`；1280×800 時 `== 16`。
- [ ] **Step 2: 確認失敗**（至少外距那條）。
- [ ] **Step 3: 實作**：外距；逐一修掉測試抓到的 overflow。
- [ ] **Step 4: 確認通過**，並跑完整 `fvm flutter test`。
- [ ] **Step 5: Commit** `feat(layout): fit every page on phone screens`。

---

### Task 10: 實機、Windows 驗證與筆記

**Files:**
- Modify: `docs/Android移植筆記.md`（新增「七、手機版面（子專案 3）」：判斷規則、各元件做法、實測發現）

- [ ] **Step 1: 實機**（ASUS ROG Phone 1080×2400，`fvm flutter build apk --debug` 後 `adb install -r`）：直向、橫向逐頁檢查總覽、12 個卡池（含空池）、記錄卡片列與排序選單、物品詳情（直向、橫向兩欄）、看圖（雙指縮放、點兩下、長按、往下滑、轉向）、設定、貢獻者、讀取設定頁、更新進度對話框；抽屜開著時轉向；鍵盤開著時搜尋。發現的問題回到對應 Task 以 TDD 修正。
- [ ] **Step 2: Windows**：視窗高度縮到 600 以下 → 抽屜、精簡標題列；拉回後恢復 rail；滑鼠單擊看圖仍立即縮放。
- [ ] **Step 3: 寫筆記**，commit `docs(android): record the phone layout rules and device findings`。
