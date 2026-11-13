# 手機滑動流暢度優化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓綜合頁與卡池頁在 165Hz 手機上（開著無障礙服務）慣性滑動準時率 ≥ 95%，並讓卡池頁靜止時不再持續出幀。

**Architecture:** 綜合頁、卡池頁的外層從 `SingleChildScrollView` + `Column` 改成按需建構的清單（畫面外的區塊不建構、不繪製、不產生語意）。帶本地狀態的區塊用 `AutomaticKeepAliveClientMixin` 撐過捲出畫面。橫向五星時間軸改成橫向 `ListView.builder`。保底卡呼吸動畫只在快保底時跑。

**Tech Stack:** Flutter（FVM 3.47.5）、Riverpod 3、flutter_test。

**Spec:** `docs/superpowers/specs/2026-11-07-mobile-scroll-smoothness-design.md`

## Global Constraints

- 外觀、互動、桌面版行為不變：所有寬度斷點（`>= 1024` 三欄、`>= 800` 中寬、手機）的佈局逐字保留。
- 捲出畫面再捲回來不得遺失：紀錄表頁碼、搜尋框文字、篩選狀態、橫向時間軸捲動位置、垂直時間軸已載入筆數。
- 語意內容只改成按需產生，不刪除任何 `Semantics`／`Tooltip`。
- 不做：圖示解碼尺寸、`existsSync`、鎖刷新率、關語意樹、啟動流程、設定頁、貢獻者頁。
- 每次 commit 前：`fvm dart format lib/ test/` → `fvm flutter analyze`（`No issues found!`）→ `fvm flutter test`（`All tests passed!`）。
- Commit message 用英文 conventional commits，結尾附：
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WreXjqEmJ2GoJo17JNX6YF
  ```
- 新宣告（含 private）要有一行 `///` dartdoc；註解用繁中全形標點；不 push。

## Review Focus

1. **快保底狀態在頁面開著時改變**（例如重新抓取後距離跨過門檻）：呼吸動畫要跟著開始或停止，不能停在舊狀態。測試在 Task 1。
2. **系統開啟「移除動畫」時剛好是快保底**：計時器不得啟動，畫面不得持續出幀。測試在 Task 1。
3. **紀錄表在第 2 頁以後時捲出畫面再捲回**：頁碼保留。篩選改變導致筆數變化時，仍照舊重設回第 1 頁（既有行為）。測試在 Task 2。
4. **橫向時間軸只有「現在」欄、沒有任何五星**：版面與既有行為相同，不得拋出版面錯誤。既有測試 `empty + nowPulls != null → renders only the Now column` 要繼續通過（Task 3）。
5. **桌面寬度（≥ 1024）的綜合頁與卡池頁**：三欄並排與 `IntrinsicHeight` 等高照舊，在 `ListView`／sliver 子項裡不得拋出 intrinsic 或無界高度錯誤。測試在 Task 4。

---

### Task 1: 保底卡呼吸動畫只在快保底時跑

**Files:**
- Modify: `lib/widgets/cards/pity_card.dart`（`_PityCardState`、`_ProgressBar`）
- Test: `test/widgets/cards/pity_card_test.dart`

**Interfaces:**
- Produces: 無對外介面變更（`PityCard` 建構子不變）。

- [ ] **Step 1: 寫失敗測試**

在 `pity_card_test.dart` 新增，沿用檔內既有的 pump helper 與 `Pity` 建構方式：

```dart
testWidgets('normal phase does not keep scheduling frames', (tester) async {
  // pity：threshold 80、distance 50（遠離快保底門檻 20）
  await pumpPityCard(tester, pity: normalPity);
  await tester.pump();
  expect(tester.binding.hasScheduledFrame, isFalse);
});

testWidgets('close phase keeps the breath animation running', (tester) async {
  // pity：threshold 80、distance 10
  await pumpPityCard(tester, pity: closePity);
  await tester.pump();
  expect(tester.binding.hasScheduledFrame, isTrue);
});

testWidgets('entering and leaving close phase starts and stops the animation', (tester) async {
  await pumpPityCard(tester, pity: normalPity);
  await tester.pump();
  expect(tester.binding.hasScheduledFrame, isFalse);
  await pumpPityCard(tester, pity: closePity);   // 同一位置重建 → didUpdateWidget
  await tester.pump();
  expect(tester.binding.hasScheduledFrame, isTrue);
  await pumpPityCard(tester, pity: normalPity);
  await tester.pump();
  await tester.pump();
  expect(tester.binding.hasScheduledFrame, isFalse);
});

testWidgets('reduce motion keeps close phase still', (tester) async {
  await pumpPityCard(tester, pity: closePity, disableAnimations: true); // MediaQueryData(disableAnimations: true)
  await tester.pump();
  expect(tester.binding.hasScheduledFrame, isFalse);
});
```

`pumpPityCard` 若檔內沒有同名 helper，就在檔內新增一個，包住既有的 MaterialApp／theme／l10n 設定，並多收 `disableAnimations` 參數。

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/cards/pity_card_test.dart`
Expected: `normal phase does not keep scheduling frames` 與 `reduce motion keeps close phase still` FAIL（目前計時器無條件在跑）。

- [ ] **Step 3: 實作**

- `_PityCardState` 新增 `void _syncBreath()`：當 `_phase(widget.pity) == _Phase.close && !MediaQuery.disableAnimationsOf(context)` 且尚未在跑時 `repeat(reverse: true)`；否則 `stop()` 並把 `value` 歸零。
- `initState` 不再呼叫 `repeat()`。改在 `didChangeDependencies`（涵蓋首次與 MediaQuery 變化）和 `didUpdateWidget` 呼叫 `_syncBreath()`。
- `_ProgressBar` 套用動畫的那一段（`AnimatedBuilder` + `Opacity`）外面包一層 `RepaintBoundary`，讓每幀只重畫進度條。

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/cards/pity_card_test.dart`
Expected: 全部 PASS。

- [ ] **Step 5: 品質檢查並 commit**

依 Global Constraints 跑 format／analyze／test，然後執行：

```bash
git add lib/widgets/cards/pity_card.dart test/widgets/cards/pity_card_test.dart
git commit  # fix(perf): run the pity breath animation only when close to pity
```

---

### Task 2: 帶本地狀態的區塊撐過捲出畫面

**Files:**
- Modify: `lib/widgets/data/sortable_table.dart`（`_SortableTableState`）
- Modify: `lib/widgets/data/search_filter_bar.dart`（`_SearchFilterBarState`）
- Modify: `lib/widgets/cards/timeline_vertical.dart`（`_TimelineVerticalState`）
- Test: `test/widgets/data/sortable_table_test.dart`、`test/widgets/cards/timeline_vertical_test.dart`

**Interfaces:**
- Produces: 這三個 State 混入 `AutomaticKeepAliveClientMixin`，`wantKeepAlive => true`，`build` 開頭呼叫 `super.build(context)`。放在非懶建構的父層（例如分享圖）時不受影響。Task 3、Task 4 依賴這點。

- [ ] **Step 1: 寫失敗測試**

`sortable_table_test.dart` 新增：

```dart
testWidgets('page survives being scrolled out of a lazy list', (tester) async {
  // ListView(children: [SortableTable(rows: 45 筆), SizedBox(height: 5000)])
  // 1. 翻到第 2 頁（沿用 'paginates with 20 per page' 的翻頁操作）
  // 2. tester.drag(find.byType(ListView), const Offset(0, -6000)); pumpAndSettle
  //    此時 expect(find.byType(SortableTable, skipOffstage: false), findsOneWidget) 仍在樹上
  // 3. 拖回頂端；expect 頁碼顯示 '2 / 3'
});
```

`timeline_vertical_test.dart` 新增：

```dart
testWidgets('loaded count survives being scrolled out of a lazy list', (tester) async {
  // ListView(children: [TimelineVertical(entries: 25 筆), SizedBox(height: 5000)])
  // 點「載入更多」一次 → 顯示 20 筆；拖到底再拖回；仍顯示 20 筆，載入更多按鈕顯示剩 5
});
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/data/sortable_table_test.dart test/widgets/cards/timeline_vertical_test.dart`
Expected: 新增的兩個測試 FAIL（頁碼回到 1／筆數回到 10）。

- [ ] **Step 3: 實作**

三個 State 加上 `AutomaticKeepAliveClientMixin`。`SearchFilterBar` 沒有對應測試：它的文字本來就會從 provider 還原，加上 keep-alive 是為了保住游標與防抖中的輸入，改動與另外兩個相同。

- [ ] **Step 4: 跑測試確認通過**

Run: 同 Step 2。Expected: 全部 PASS。

- [ ] **Step 5: 品質檢查並 commit**

```bash
git commit  # fix(perf): keep stateful sections alive when scrolled out of lazy lists
```

---

### Task 3: 橫向五星時間軸按需建構

**Files:**
- Modify: `lib/widgets/cards/timeline_horizontal.dart`（`_TimelineHorizontalState.build` 的捲動層）
- Test: `test/widgets/cards/timeline_horizontal_test.dart`

**Interfaces:**
- Consumes: Task 2 的 keep-alive 慣例。
- Produces: `TimelineHorizontal` 建構子不變。

- [ ] **Step 1: 寫失敗測試**

```dart
testWidgets('only builds the columns near the viewport', (tester) async {
  // 300 筆 entries（名稱 'E0'..'E299'），寬 400 的容器
  expect(find.text('E0'), findsOneWidget);
  expect(find.text('E299', skipOffstage: false), findsNothing);
});

testWidgets('scroll offset survives being scrolled out of a lazy list', (tester) async {
  // ListView(children: [SizedBox(height: 300, child: TimelineHorizontal(60 筆)), SizedBox(height: 5000)])
  // 點右箭頭兩次 → offset 180；外層拖到底再拖回；offset 仍為 180（讀 Scrollable 的 position.pixels）
});
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/cards/timeline_horizontal_test.dart`
Expected: 兩個新測試 FAIL。

- [ ] **Step 3: 實作**

- `_TimelineHorizontalState` 加上 `AutomaticKeepAliveClientMixin`。
- 把 `SingleChildScrollView(scrollDirection: horizontal, child: MouseRegion(child: Row(...)))` 換成 `MouseRegion(child: ListView.builder(controller: _controller, scrollDirection: Axis.horizontal, itemCount: entries.length + (nowPulls != null ? 1 : 0), itemExtent: _colWidth, itemBuilder: ...))`。
  - index 0 且 `nowPulls != null` 時是 `_NowColumn`，其餘依序對應 `_EntryColumn`。
  - `monthStart` 預先算好的陣列照用。
- 每個 item 外面包 `Center`。原本 `Row` 的 `crossAxisAlignment.center` 會給子欄寬鬆高度，包了 `Center` 才能保持一樣，月份分隔線的長度也不會變。
- `ScrollConfiguration` 的 dragDevices、背景軸線、左右漸層、箭頭、`_updateAffordance` 全部保留。
- `_NowColumn` 的寬度若不是 `_colWidth`，就不設 `itemExtent`，改由各欄自己決定寬度。
- 既有測試若依賴「所有欄都在樹上」，改用 `skipOffstage: false` 或先捲動。斷言的語意不能放寬。

- [ ] **Step 4: 跑測試確認通過**

Run: 同 Step 2。Expected: 全部 PASS，包括既有的 `empty + nowPulls != null → renders only the Now column` 與 `timeline scrolls with a finger drag`。

- [ ] **Step 5: 品質檢查並 commit**

```bash
git commit  # perf(timeline): build horizontal timeline columns lazily
```

---

### Task 4: 綜合頁與卡池頁改成按需建構的清單

**Files:**
- Modify: `lib/pages/overview_page.dart`（`OverviewPage.build` 有資料分支、`_OverviewSection`）
- Modify: `lib/pages/banner_page.dart`（`BannerPage.build` 有紀錄分支）
- Test: `test/pages/phone_layout_pages_test.dart`（新增案例；既有案例若因懶建構找不到畫面外 widget，改成先 `scrollUntilVisible`）

**Interfaces:**
- Consumes: Task 2、Task 3 的 keep-alive。

- [ ] **Step 1: 寫失敗測試**

在 `phone_layout_pages_test.dart` 沿用既有頁面 pump helper 與假資料，新增：

```dart
testWidgets('overview builds bottom sections only when scrolled near', (tester) async {
  // 手機尺寸（沿用檔內設定），資料要多到底部的 TimelineVertical 在首屏之外
  expect(find.byType(TimelineVertical, skipOffstage: false), findsNothing);
  await tester.scrollUntilVisible(find.byType(TimelineVertical), 500);
  expect(find.byType(TimelineVertical), findsOneWidget);
});

testWidgets('banner page builds the record table only when scrolled near', (tester) async {
  expect(find.byType(SortableTable, skipOffstage: false), findsNothing);
  await tester.scrollUntilVisible(find.byType(SortableTable), 500);
  expect(find.byType(SortableTable), findsOneWidget);
});

testWidgets('overview and banner page lay out at desktop width', (tester) async {
  // 視窗 1280x800，分別 pump 兩頁；expect(tester.takeException(), isNull)，
  // 並確認三張 stat 卡在同一列（三者的 getTopLeft(...).dy 相同）
});
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/pages/phone_layout_pages_test.dart`
Expected: 前兩個新測試 FAIL（目前整頁一次建好）。

- [ ] **Step 3: 實作卡池頁**

把有紀錄分支的 `SingleChildScrollView(padding: P, child: Column(crossAxisAlignment: stretch, children: C))` 換成 `ListView(padding: P, children: C)`。`P` 與 `C` 逐字不變。

- [ ] **Step 4: 實作綜合頁**

- `_OverviewSection.build` 的兩個分支，都把 `Column(crossAxisAlignment: stretch, children: C)` 改成回傳 `SliverList.list(children: C)`，`C` 逐字不變。dartdoc 改成說明它回傳 sliver。
- `OverviewPage` 有資料分支改成：

```dart
CustomScrollView(
  slivers: [
    SliverPadding(
      padding: P, // 原本 SingleChildScrollView 的 padding
      sliver: SliverMainAxisGroup(
        slivers: [SliverToBoxAdapter(child: headerRow), _OverviewSection(...)],
      ),
    ),
  ],
)
```

這樣標題列和區塊內容都會變成清單裡的獨立項目，畫面外的五星一覽與時間軸不會被建構。

- [ ] **Step 5: 跑測試確認通過**

Run: `fvm flutter test test/pages/` 然後 `fvm flutter test`
Expected: 全部 PASS。

- [ ] **Step 6: 品質檢查並 commit**

```bash
git commit  # perf(pages): build overview and banner sections lazily
```

---

### Task 5: 實機驗收與記錄（主控執行，需要連著的手機）

**Files:**
- Create: `tool/measure_frame_pacing.sh`（把 scratchpad 的 `measure.sh` 原樣搬過來：靜止出幀率 + 放手後慣性滑動準時率；用法寫在檔頭）
- Modify: `docs/Android移植筆記.md`（新增章節「十一、滑動流暢度」與條目 `### 41.`）

- [ ] **Step 1:** 執行 `fvm flutter build apk --profile --target-platform android-arm64`，再 `adb install -r build/app/outputs/flutter-apk/app-profile.apk`。資料會保留。
- [ ] **Step 2:** 用 `tool/measure_frame_pacing.sh` 量全部 14 頁（側欄座標同 2026-11-07 的量測），外加冷啟動後的綜合頁。
  - Expected：所有可捲動頁的準時率 ≥ 95%。
  - Expected：有紀錄、但不在快保底的卡池頁，靜止時 idle = 0。
- [ ] **Step 3:** 若有頁面低於 95%，用 VM Service timeline 量 BeginFrame／SEMANTICS／PAINT，找出佔比最大的區塊，對該區塊套用同樣的按需建構或 keep-alive 做法。這算本計畫的延伸修正：先記一筆 Ruling，回到該區塊對應的 Task 補測試再修。
- [ ] **Step 4:** 把量測方法、前後對照表、根因（無障礙服務會觸發語意樹、整頁建構、無條件 `repeat()`）寫進 `docs/Android移植筆記.md` 的 `### 41.`。
- [ ] **Step 5:** 品質檢查並 commit：

```bash
git commit  # docs(android): record scroll smoothness measurements and fixes
```
