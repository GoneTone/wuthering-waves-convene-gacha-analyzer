# 物品詳情 Dialog 單行可捲動頁籤＋三角箭頭導航 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把物品詳情 Dialog 的切換頁籤從會換多行的 `Wrap` 改成單行可水平捲動、左右帶可點擊三角箭頭（頭尾停用）的頁籤列。

**Architecture:** 抽出共用捲動可及性元件 `scroll_affordance.dart`（箭頭按鈕＋邊緣 fade），timeline 改引用做零行為變更重構，新增 `GalleryChipBar` 三欄頁籤列（箭頭看選中索引、fade 看 scroll offset、選中自動捲入），dialog 以它取代 `Wrap`。完全對齊姐妹專案 PR #119。

**Tech Stack:** Flutter／Dart、Riverpod、flutter gen-l10n（ARB）、flutter_test widget test、FVM 釘版。

**Reference spec:** `docs/superpowers/specs/2026-06-17-item-detail-scrollable-tabs-design.md`

---

## File Structure

- **Create** `lib/widgets/scroll/scroll_affordance.dart` —— 共用 `ScrollArrowButton`（`onPressed` 可 null＝停用）／`ScrollEdgeFade`／常數／`ScrollSide`。
- **Create** `test/widgets/scroll/scroll_affordance_test.dart` —— 箭頭啟用／停用測試。
- **Modify** `lib/widgets/cards/timeline_horizontal.dart` —— 改引用共用元件，刪內嵌 `_ArrowButton`／`_EdgeFade`／`_ScrollSide`／`_scrollDuration`／`_scrollCurve`（純重構）。
- **Modify** `lib/l10n/app_zh.arb`、`app_zh_Hans.arb`、`app_en.arb`、`app_ja.arb` —— 新增 `galleryPrevTab`／`galleryNextTab`。
- **Create** `lib/widgets/dialogs/gallery_chip_bar.dart` —— `GalleryChipBar` 單行可捲動頁籤列。
- **Create** `test/widgets/dialogs/gallery_chip_bar_test.dart` —— 頭尾箭頭停用／點箭頭切頁／點 chip 切換測試。
- **Modify** `lib/widgets/dialogs/gacha_item_detail_dialog.dart` —— 以 `GalleryChipBar` 取代 `Wrap`（759–774 行）。

> **指令一律優先用 `fvm`**：`fvm flutter ...`／`fvm dart ...`；找不到 `fvm` 才退回 `flutter`／`dart`。
> 工作分支已為 `feat/item-detail-scrollable-tabs`（spec 已 commit 於此）。

---

## Task 1: 共用捲動可及性元件 `scroll_affordance.dart`

**Files:**
- Create: `lib/widgets/scroll/scroll_affordance.dart`
- Test: `test/widgets/scroll/scroll_affordance_test.dart`

- [ ] **Step 1: 寫失敗測試**

Create `test/widgets/scroll/scroll_affordance_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/scroll/scroll_affordance.dart';

Widget _wrap(Widget Function(GachaTokens tokens) build) => MaterialApp(
  theme: buildDarkTheme(),
  home: Scaffold(
    body: Builder(builder: (ctx) => Center(child: build(Theme.of(ctx).gacha))),
  ),
);

void main() {
  testWidgets('onPressed != null → tappable, fires callback', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        (tokens) => ScrollArrowButton(
          icon: Icons.arrow_left,
          tooltip: 'prev',
          tokens: tokens,
          onPressed: () => taps++,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.arrow_left));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('onPressed == null → renders icon but tap does nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        (tokens) => ScrollArrowButton(
          icon: Icons.arrow_left,
          tooltip: 'prev',
          tokens: tokens,
          onPressed: null,
        ),
      ),
    );
    expect(find.byIcon(Icons.arrow_left), findsOneWidget);
    final inkWell = tester.widget<InkWell>(
      find.ancestor(
        of: find.byIcon(Icons.arrow_left),
        matching: find.byType(InkWell),
      ),
    );
    expect(inkWell.onTap, isNull);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/scroll/scroll_affordance_test.dart`
Expected: 編譯失敗（`scroll_affordance.dart` 不存在 / `ScrollArrowButton` 未定義）。

- [ ] **Step 3: 實作共用元件**

Create `lib/widgets/scroll/scroll_affordance.dart`：

```dart
import 'package:flutter/material.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';

/// 點擊捲動箭頭的動畫時長（timeline 與頁籤列共用）。
const Duration kScrollAffordanceDuration = Duration(milliseconds: 240);

/// 點擊捲動箭頭的動畫曲線（timeline 與頁籤列共用）。
const Curve kScrollAffordanceCurve = Curves.easeOutCubic;

/// 捲動可及性元件的方向。
enum ScrollSide {
  /// 左側：fade 從左往右漸隱。
  left,

  /// 右側：fade 從右往左漸隱。
  right,
}

/// 邊緣漸隱遮罩，用於提示使用者該方向仍可捲動。
///
/// 漸層自 [GachaTokens.surfaceCard]（不透明）漸隱到透明，會自動跟隨卡片／
/// dialog 背景色。寬度由外層 [Positioned] 決定，此元件本身不設寬度。
class ScrollEdgeFade extends StatelessWidget {
  /// 建立 [ScrollEdgeFade]。
  const ScrollEdgeFade({super.key, required this.side});

  /// 漸隱方向。
  final ScrollSide side;

  @override
  Widget build(BuildContext context) {
    final cardColor = Theme.of(context).gacha.surfaceCard;
    final isLeft = side == ScrollSide.left;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: isLeft ? Alignment.centerLeft : Alignment.centerRight,
          end: isLeft ? Alignment.centerRight : Alignment.centerLeft,
          colors: [cardColor, cardColor.withValues(alpha: 0)],
        ),
      ),
    );
  }
}

/// 浮在捲動區邊緣的圓形箭頭按鈕。
///
/// [onPressed] 為 `null` 時呈現停用樣式（icon 轉淡、游標不變手形、無法點擊），
/// 用於「已在最前／最後」的情境；非 `null` 時為可點的啟用樣式。
class ScrollArrowButton extends StatelessWidget {
  /// 建立 [ScrollArrowButton]。
  const ScrollArrowButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.tokens,
    required this.onPressed,
  });

  /// 按鈕圖示（左箭頭或右箭頭）。
  final IconData icon;

  /// 無障礙 tooltip 文字。
  final String tooltip;

  /// 主題 token，用於按鈕背景色與 icon 顏色。
  final GachaTokens tokens;

  /// 點擊後的回呼；為 `null` 時按鈕停用。
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: Material(
            color: tokens.surfaceCard.withValues(alpha: 0.85),
            shape: CircleBorder(
              side: BorderSide(
                color: tokens.textMuted.withValues(alpha: 0.25),
                width: 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                width: 24,
                height: 24,
                child: Icon(
                  icon,
                  size: 16,
                  color: enabled
                      ? tokens.textPrimary
                      : tokens.textMuted.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/scroll/scroll_affordance_test.dart`
Expected: PASS（2 個測試全綠）。

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/scroll/scroll_affordance.dart test/widgets/scroll/scroll_affordance_test.dart
git commit -m "feat(scroll): add shared ScrollArrowButton and ScrollEdgeFade"
```

---

## Task 2: `timeline_horizontal.dart` 改引用共用元件（純重構）

**Files:**
- Modify: `lib/widgets/cards/timeline_horizontal.dart`

> 零行為變更：timeline 箭頭仍為 `chevron`、仍為「真捲動」、tooltip 仍用 `timelineScroll*`。只是把內嵌的按鈕／fade／常數換成共用元件。

- [ ] **Step 1: 加 import、刪重複常數與 enum**

在 import 區（既有最後一行 `widgets/gacha_item_icon.dart` 之後）加上：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/scroll/scroll_affordance.dart';
```

刪除這四段（`_colWidth`、`_edgeFadeWidth` 保留）：

```dart
/// 點擊箭頭捲動的動畫時長。
const Duration _scrollDuration = Duration(milliseconds: 240);

/// 點擊箭頭捲動的動畫曲線。
const Curve _scrollCurve = Curves.easeOutCubic;

/// 捲動可及性箭頭的方向。
enum _ScrollSide { left, right }
```

- [ ] **Step 2: `_scrollBy` 改用共用常數**

把 `_scrollBy` 內的 `animateTo` 參數改為共用常數：

```dart
    _controller.animateTo(
      target,
      duration: kScrollAffordanceDuration,
      curve: kScrollAffordanceCurve,
    );
```

- [ ] **Step 3: build 內改用共用元件**

把左 fade／左箭頭：

```dart
            child: const IgnorePointer(
              child: _EdgeFade(side: _ScrollSide.left),
            ),
```
改為
```dart
            child: const IgnorePointer(
              child: ScrollEdgeFade(side: ScrollSide.left),
            ),
```

```dart
              child: _ArrowButton(
                icon: Icons.chevron_left,
                tooltip: l.timelineScrollLeft,
                tokens: tokens,
                onPressed: () => _scrollBy(-_colWidth),
              ),
```
改為（類別名換成共用）
```dart
              child: ScrollArrowButton(
                icon: Icons.chevron_left,
                tooltip: l.timelineScrollLeft,
                tokens: tokens,
                onPressed: () => _scrollBy(-_colWidth),
              ),
```

右側同理：`_EdgeFade(side: _ScrollSide.right)` → `ScrollEdgeFade(side: ScrollSide.right)`；`_ArrowButton(icon: Icons.chevron_right, ...)` → `ScrollArrowButton(icon: Icons.chevron_right, ...)`（其餘參數不變）。

- [ ] **Step 4: 刪除內嵌的 `_EdgeFade` 與 `_ArrowButton` 類別**

刪除檔尾這兩個類別（`_EdgeFade` 與 `_ArrowButton` 的完整 class 宣告，含其 dartdoc）。`_EntryColumn`／`_NowColumn`／`_colWidth`／`_edgeFadeWidth` 保留不動。

- [ ] **Step 5: 跑分析＋既有 timeline 測試確認零回歸**

Run: `fvm flutter analyze`
Expected: `No issues found!`

Run: `fvm flutter test test/widgets/cards/`
Expected: timeline 相關測試全綠（PASS）。

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/cards/timeline_horizontal.dart
git commit -m "refactor(timeline): use shared scroll affordance widgets"
```

---

## Task 3: i18n —— 新增 `galleryPrevTab` / `galleryNextTab`

**Files:**
- Modify: `lib/l10n/app_zh.arb`、`app_zh_Hans.arb`、`app_en.arb`、`app_ja.arb`

> 只改核心四 ARB，其餘 locale 由 Crowdin 補。每個 ARB 在 `galleryIconLabel` 的 `@`-block 之後、`galleryLazyLoadFailed` 之前插入。

- [ ] **Step 1: `app_zh.arb` 插入**

在 `"@galleryIconLabel": { ... },` 之後插入：

```json
  "galleryPrevTab": "上一個",
  "@galleryPrevTab": {
    "description": "Item detail dialog gallery: tooltip for the left triangle arrow that selects the PREVIOUS tab/chip. Not a viewport scroll - it switches the selected gallery page."
  },
  "galleryNextTab": "下一個",
  "@galleryNextTab": {
    "description": "Item detail dialog gallery: tooltip for the right triangle arrow that selects the NEXT tab/chip."
  },
```

- [ ] **Step 2: `app_zh_Hans.arb` 插入**

同位置插入（值為簡中）：

```json
  "galleryPrevTab": "上一个",
  "@galleryPrevTab": {
    "description": "Item detail dialog gallery: tooltip for the left triangle arrow that selects the PREVIOUS tab/chip. Not a viewport scroll - it switches the selected gallery page."
  },
  "galleryNextTab": "下一个",
  "@galleryNextTab": {
    "description": "Item detail dialog gallery: tooltip for the right triangle arrow that selects the NEXT tab/chip."
  },
```

- [ ] **Step 3: `app_en.arb` 插入**

同位置插入：

```json
  "galleryPrevTab": "Previous",
  "@galleryPrevTab": {
    "description": "Item detail dialog gallery: tooltip for the left triangle arrow that selects the PREVIOUS tab/chip. Not a viewport scroll - it switches the selected gallery page."
  },
  "galleryNextTab": "Next",
  "@galleryNextTab": {
    "description": "Item detail dialog gallery: tooltip for the right triangle arrow that selects the NEXT tab/chip."
  },
```

- [ ] **Step 4: `app_ja.arb` 插入**

同位置插入：

```json
  "galleryPrevTab": "前へ",
  "@galleryPrevTab": {
    "description": "Item detail dialog gallery: tooltip for the left triangle arrow that selects the PREVIOUS tab/chip. Not a viewport scroll - it switches the selected gallery page."
  },
  "galleryNextTab": "次へ",
  "@galleryNextTab": {
    "description": "Item detail dialog gallery: tooltip for the right triangle arrow that selects the NEXT tab/chip."
  },
```

- [ ] **Step 5: 重新產生 l10n 並確認 getter 存在**

Run: `fvm flutter gen-l10n`
Expected: 無錯誤；產生的 `app_localizations.dart` 含 `galleryPrevTab`／`galleryNextTab` getter。

Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/l10n/app_zh.arb lib/l10n/app_zh_Hans.arb lib/l10n/app_en.arb lib/l10n/app_ja.arb
git commit -m "i18n: add galleryPrevTab/galleryNextTab tab-nav arrow tooltips"
```

---

## Task 4: `GalleryChipBar` 單行可捲動頁籤列

**Files:**
- Create: `lib/widgets/dialogs/gallery_chip_bar.dart`
- Test: `test/widgets/dialogs/gallery_chip_bar_test.dart`

- [ ] **Step 1: 寫失敗測試**

Create `test/widgets/dialogs/gallery_chip_bar_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/gallery_chip_bar.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/scroll/scroll_affordance.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Center(child: SizedBox(width: 400, child: child)),
  ),
);

ScrollArrowButton _btn(WidgetTester tester, IconData icon) =>
    tester.widget<ScrollArrowButton>(
      find.ancestor(
        of: find.byIcon(icon),
        matching: find.byType(ScrollArrowButton),
      ),
    );

void main() {
  testWidgets('selectedIndex=0 → left arrow disabled, right enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        GalleryChipBar(
          labels: const ['A', 'B', 'C'],
          selectedIndex: 0,
          onSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_btn(tester, Icons.arrow_left).onPressed, isNull);
    expect(_btn(tester, Icons.arrow_right).onPressed, isNotNull);
  });

  testWidgets('selectedIndex=last → right arrow disabled, left enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        GalleryChipBar(
          labels: const ['A', 'B', 'C'],
          selectedIndex: 2,
          onSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_btn(tester, Icons.arrow_right).onPressed, isNull);
    expect(_btn(tester, Icons.arrow_left).onPressed, isNotNull);
  });

  testWidgets('selectedIndex=middle → both arrows enabled', (tester) async {
    await tester.pumpWidget(
      _wrap(
        GalleryChipBar(
          labels: const ['A', 'B', 'C'],
          selectedIndex: 1,
          onSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_btn(tester, Icons.arrow_left).onPressed, isNotNull);
    expect(_btn(tester, Icons.arrow_right).onPressed, isNotNull);
  });

  testWidgets('tap right arrow → onSelected(selectedIndex + 1)', (
    tester,
  ) async {
    int? picked;
    await tester.pumpWidget(
      _wrap(
        GalleryChipBar(
          labels: const ['A', 'B', 'C'],
          selectedIndex: 0,
          onSelected: (i) => picked = i,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_right));
    await tester.pump();
    expect(picked, 1);
  });

  testWidgets('tap left arrow → onSelected(selectedIndex - 1)', (tester) async {
    int? picked;
    await tester.pumpWidget(
      _wrap(
        GalleryChipBar(
          labels: const ['A', 'B', 'C'],
          selectedIndex: 2,
          onSelected: (i) => picked = i,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_left));
    await tester.pump();
    expect(picked, 1);
  });

  testWidgets('tap a chip → onSelected(that index)', (tester) async {
    int? picked;
    await tester.pumpWidget(
      _wrap(
        GalleryChipBar(
          labels: const ['A', 'B', 'C'],
          selectedIndex: 0,
          onSelected: (i) => picked = i,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('C'));
    await tester.pump();
    expect(picked, 2);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/dialogs/gallery_chip_bar_test.dart`
Expected: 編譯失敗（`gallery_chip_bar.dart` 不存在 / `GalleryChipBar` 未定義）。

- [ ] **Step 3: 實作 `GalleryChipBar`**

Create `lib/widgets/dialogs/gallery_chip_bar.dart`：

```dart
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/scroll/scroll_affordance.dart';

/// 左／右箭頭欄的寬度（含內距，足以容納 24px 圓鈕）。
const double _arrowSlotWidth = 32;

/// 中間捲動區邊緣漸隱遮罩的寬度。
const double _chipFadeWidth = 24;

/// 箭頭欄與中間頁籤捲動區之間的水平間距，讓箭頭與標籤拉開一點呼吸空間。
const double _arrowGap = 6;

/// 單行可水平捲動的頁籤列：左箭頭、可捲動 ChoiceChip 列（含邊緣 fade）、右箭頭。
///
/// 三欄固定排版，箭頭獨立欄位不會遮住邊緣頁籤。箭頭由「選中索引是否在頭／尾」
/// 驅動（在第一個時左箭頭停用、最後一個時右箭頭停用），點箭頭等同切換到上／下
/// 一個頁籤並把它捲入可視範圍；中間 fade 則由實際 scroll offset 驅動，兩者解耦。
///
/// 呼叫端需保證 `0 <= selectedIndex < labels.length`；是否顯示整條 bar
/// （例如只有一個頁籤時隱藏）由呼叫端決定，此元件不自行判斷。
class GalleryChipBar extends StatefulWidget {
  /// 建立 [GalleryChipBar]。
  const GalleryChipBar({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
  });

  /// 各頁籤的顯示文字，順序即顯示順序。
  final List<String> labels;

  /// 當前選中的頁籤索引。
  final int selectedIndex;

  /// 切換頁籤時的回呼，參數為新選中的索引。
  final ValueChanged<int> onSelected;

  @override
  State<GalleryChipBar> createState() => _GalleryChipBarState();
}

/// [GalleryChipBar] 的 state：管理橫向捲動控制器、fade 可見性與選中自動捲入。
class _GalleryChipBarState extends State<GalleryChipBar> {
  /// 中間頁籤列的捲動控制器。
  late final ScrollController _controller;

  /// 每個頁籤的 key，供 [Scrollable.ensureVisible] 把選中頁籤捲入可視範圍。
  late List<GlobalKey> _keys;

  /// true 時顯示左側漸隱遮罩。
  bool _hasLeft = false;

  /// true 時顯示右側漸隱遮罩。
  bool _hasRight = false;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController()..addListener(_updateAffordance);
    _keys = _buildKeys(widget.labels.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateAffordance();
      _ensureSelectedVisible();
    });
  }

  @override
  void didUpdateWidget(covariant GalleryChipBar old) {
    super.didUpdateWidget(old);
    if (old.labels.length != widget.labels.length) {
      // 頁籤數量變動會重建 _keys，選中頁籤可能因此跑出視野；除了更新 fade，
      // 也一併把選中頁籤捲回可視範圍，避免停在被裁切的位置。
      _keys = _buildKeys(widget.labels.length);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateAffordance();
        _ensureSelectedVisible();
      });
    }
    if (old.selectedIndex != widget.selectedIndex) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureSelectedVisible(),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 產生 [n] 個全新的 [GlobalKey]，對應 [GalleryChipBar.labels] 各項。
  List<GlobalKey> _buildKeys(int n) => List.generate(n, (_) => GlobalKey());

  /// 依捲動位置更新 [_hasLeft] / [_hasRight]，控制兩側 fade 的顯示。
  void _updateAffordance() {
    if (!mounted || !_controller.hasClients) return;
    final pos = _controller.position;
    final hasLeft = _controller.offset > 1;
    final hasRight = _controller.offset < pos.maxScrollExtent - 1;
    if (hasLeft != _hasLeft || hasRight != _hasRight) {
      setState(() {
        _hasLeft = hasLeft;
        _hasRight = hasRight;
      });
    }
  }

  /// 把當前選中的頁籤以動畫捲入可視範圍中央。
  void _ensureSelectedVisible() {
    if (!mounted) return;
    final index = widget.selectedIndex;
    if (index < 0 || index >= _keys.length) return;
    final ctx = _keys[index].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: kScrollAffordanceDuration,
      curve: kScrollAffordanceCurve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).gacha;
    final l = AppLocalizations.of(context)!;
    final selected = widget.selectedIndex;
    final lastIndex = widget.labels.length - 1;

    return Row(
      children: [
        SizedBox(
          width: _arrowSlotWidth,
          child: Center(
            child: ScrollArrowButton(
              icon: Icons.arrow_left,
              tooltip: l.galleryPrevTab,
              tokens: tokens,
              onPressed: selected > 0
                  ? () => widget.onSelected(selected - 1)
                  : null,
            ),
          ),
        ),
        const SizedBox(width: _arrowGap),
        Expanded(
          child: Stack(
            children: [
              // 非 Positioned 的 sizing child：決定 Stack 高度（dialog 內無固定
              // 高度，不能像 timeline 那樣全用 Positioned.fill，否則高度塌陷）。
              ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: const {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.stylus,
                  },
                ),
                child: SingleChildScrollView(
                  controller: _controller,
                  scrollDirection: Axis.horizontal,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < widget.labels.length; i++)
                          Padding(
                            key: _keys[i],
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(widget.labels[i]),
                              selected: i == selected,
                              showCheckmark: false,
                              onSelected: (_) => widget.onSelected(i),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_hasLeft)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: _chipFadeWidth,
                  child: const IgnorePointer(
                    child: ScrollEdgeFade(side: ScrollSide.left),
                  ),
                ),
              if (_hasRight)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: _chipFadeWidth,
                  child: const IgnorePointer(
                    child: ScrollEdgeFade(side: ScrollSide.right),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: _arrowGap),
        SizedBox(
          width: _arrowSlotWidth,
          child: Center(
            child: ScrollArrowButton(
              icon: Icons.arrow_right,
              tooltip: l.galleryNextTab,
              tokens: tokens,
              onPressed: selected < lastIndex
                  ? () => widget.onSelected(selected + 1)
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/dialogs/gallery_chip_bar_test.dart`
Expected: PASS（6 個測試全綠）。

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/dialogs/gallery_chip_bar.dart test/widgets/dialogs/gallery_chip_bar_test.dart
git commit -m "feat(item-detail): add GalleryChipBar single-line scrollable tab bar"
```

---

## Task 5: 接入 `gacha_item_detail_dialog.dart`

**Files:**
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`

- [ ] **Step 1: 加 import**

在既有 import 區（`widgets/dialogs/dialog_toast.dart` 一帶）加上：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/gallery_chip_bar.dart';
```

- [ ] **Step 2: 以 `GalleryChipBar` 取代 `Wrap`**

把 `content:` 的 `Column` 內這段（原 759–773 行的 `Wrap` 與其後的 `SizedBox`）：

```dart
          if (chipEntries.length > 1) ...[
            Wrap(
              spacing: AppSpacing.s,
              runSpacing: AppSpacing.s,
              children: [
                for (var i = 0; i < chipEntries.length; i++)
                  ChoiceChip(
                    label: Text(chipEntries[i].label),
                    selected: i == clampedIndex,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _selectedIndex = i),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.m),
          ],
```

替換為：

```dart
          if (chipEntries.length > 1) ...[
            GalleryChipBar(
              labels: [for (final e in chipEntries) e.label],
              selectedIndex: clampedIndex,
              onSelected: (i) => setState(() => _selectedIndex = i),
            ),
            const SizedBox(height: AppSpacing.m),
          ],
```

- [ ] **Step 3: 全套品質檢查**

Run: `fvm dart format lib/ test/`
Expected: 格式化完成（無錯誤）。

Run: `fvm flutter analyze`
Expected: `No issues found!`

Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 4: Commit**

```bash
git add lib/widgets/dialogs/gacha_item_detail_dialog.dart
git commit -m "feat(item-detail): use GalleryChipBar for the gallery tab switcher"
```

---

## 完成後驗收

- [ ] `fvm flutter analyze` → `No issues found!`
- [ ] `fvm flutter test` → `All tests passed!`
- [ ] 手動驗（建議）：開一個造型多的角色詳情 Dialog，確認頁籤單行、超過可左右拖曳捲動、三角箭頭可點切頁、停在第一／最後個時對應箭頭停用且版面不跳動、選中頁籤自動捲入視野；timeline 視覺與捲動行為無變化。
- [ ] **不主動 push**（依專案規則，由使用者決定何時 push／開 PR）。
