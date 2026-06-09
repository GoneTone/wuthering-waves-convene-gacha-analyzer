# 統一 dialog／lightbox 複製・儲存訊息（對齊原神版）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把詳情 dialog 與 lightbox 的「複製／儲存圖片」結果訊息，統一改用移植自原神版的共用 `showDialogToast`（Material SnackBar 風格、`inverseSurface` 配色、淡入淡出），取代目前兩套不一致的自管 Stack toast 與 ScaffoldMessenger SnackBar。

**Architecture:** 新增 `lib/widgets/dialogs/dialog_toast.dart`（忠實移植原神版 `showDialogToast` + `_DialogToast`，用 `OverlayEntry` 浮在 dialog／modal barrier 之上）。dialog 與 lightbox 的 `_showSnack` 都改呼叫 `showDialogToast`，並移除各自原有的 toast 基礎設施（dialog 的外層 `Stack`/`_toastMessage`/`_toastTimer`；lightbox 的 `ScaffoldMessenger`/`Scaffold`/`_messengerKey`）。唯一相對原神版的刻意（且不影響視覺的）新增：toast 根 `Material` 帶 `ValueKey('dialogToast')` 供測試定位。

**Tech Stack:** Flutter（`Overlay`/`OverlayEntry`/`AnimationController`/`FadeTransition`/`Timer`）、`flutter_test`、既有 `item_image_save.dart` 可注入 seam、FVM 釘住的 SDK。

**Spec:** `docs/superpowers/specs/2026-06-09-dialog-toast-unify-design.md`

---

## File Structure

| 檔案 | 責任 | 改動 |
|---|---|---|
| `lib/widgets/dialogs/dialog_toast.dart` | 共用 overlay toast | 新增 |
| `lib/widgets/dialogs/gacha_item_detail_dialog.dart` | 詳情 dialog | 修改：移除自管 Stack toast，`_showSnack` 改呼叫 `showDialogToast` |
| `lib/widgets/dialogs/zoomable_image_overlay.dart` | lightbox | 修改：移除 ScaffoldMessenger/SnackBar，`_showSnack` 改呼叫 `showDialogToast` |
| `test/widgets/dialogs/dialog_toast_test.dart` | toast 元件測試 | 新增 |
| `test/widgets/dialogs/gacha_item_detail_dialog_test.dart` | dialog 測試 | 修改：toast 斷言改 overlay 版 |
| `test/widgets/dialogs/zoomable_image_overlay_test.dart` | lightbox 測試 | 修改：去 SnackBar 依賴、cancel 斷言改 toast key |

**指令一律優先 `fvm`**（找不到再退回 `flutter`／`dart`）。

---

## Task 1: 新增共用 `dialog_toast.dart`（移植原神版）

**Files:**
- Create: `lib/widgets/dialogs/dialog_toast.dart`
- Test: `test/widgets/dialogs/dialog_toast_test.dart`

- [ ] **Step 1: 寫失敗測試**

建立 `test/widgets/dialogs/dialog_toast_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/dialog_toast.dart';

void main() {
  /// 建一個帶 Overlay（MaterialApp 內建 Navigator overlay）的測試 app，
  /// 按鈕點擊時用按鈕自身 context 呼叫 showDialogToast。
  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialogToast(ctx, 'hello'),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('showDialogToast 顯示訊息文字', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('go'));
    await tester.pump(); // 插入 OverlayEntry + 啟動淡入
    expect(find.text('hello'), findsOneWidget);
    // flush 停留計時器與淡出動畫，避免殘留。
    await tester.pump(const Duration(milliseconds: 2200));
    await tester.pumpAndSettle();
  });

  testWidgets('toast 底色為 colorScheme.inverseSurface', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('go'));
    await tester.pump();
    final material = tester.widget<Material>(
      find.byKey(const ValueKey('dialogToast')),
    );
    final scheme = Theme.of(
      tester.element(find.byKey(const ValueKey('dialogToast'))),
    ).colorScheme;
    expect(material.color, scheme.inverseSurface);
    await tester.pump(const Duration(milliseconds: 2200));
    await tester.pumpAndSettle();
  });

  testWidgets('停留後自動淡出消失', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.text('hello'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2200)); // 停留結束 → 觸發淡出
    await tester.pumpAndSettle(); // 跑完 200ms 淡出 + 移除 entry
    expect(find.text('hello'), findsNothing);
  });

  testWidgets('新 toast 取代舊 toast（同時只留一則）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  onPressed: () => showDialogToast(ctx, 'first'),
                  child: const Text('a'),
                ),
                ElevatedButton(
                  onPressed: () => showDialogToast(ctx, 'second'),
                  child: const Text('b'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('a'));
    await tester.pump();
    expect(find.text('first'), findsOneWidget);
    await tester.tap(find.text('b'));
    await tester.pump();
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2200));
    await tester.pumpAndSettle();
  });
}
```

- [ ] **Step 2: 跑測試，確認失敗（紅燈）**

Run: `fvm flutter test test/widgets/dialogs/dialog_toast_test.dart`
Expected: FAIL——`dialog_toast.dart` 尚不存在（import 解析失敗 / `showDialogToast` 未定義）。

- [ ] **Step 3: 建立 `lib/widgets/dialogs/dialog_toast.dart`**

完整內容（移植原神版，新增 `ValueKey('dialogToast')` 供測試定位）：

```dart
import 'dart:async';

import 'package:flutter/material.dart';

/// 目前在畫面上的 toast entry；新 toast 出現前先移除舊的，避免堆疊重疊。
OverlayEntry? _activeToast;

/// 在最上層 [Overlay] 顯示一則短暫提示（toast），會疊在 dialog／modal barrier
/// **之上**。
///
/// 用來取代 dialog 內的 `ScaffoldMessenger` SnackBar — 後者由 app 層級 Scaffold
/// 繪製，會被 dialog 的 modal barrier 蓋住。toast 改插到 `Overlay.of(context)`
/// （承載 dialog route 的 navigator overlay），新 entry 疊在 dialog route 之上，
/// 因此可見。樣式對齊 Material SnackBar（inverseSurface 底色）。
void showDialogToast(BuildContext context, String message) {
  if (_activeToast?.mounted ?? false) {
    _activeToast!.remove();
  }
  _activeToast = null;

  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _DialogToast(
      message: message,
      onDismissed: () {
        if (entry.mounted) entry.remove();
        if (identical(_activeToast, entry)) _activeToast = null;
      },
    ),
  );
  _activeToast = entry;
  overlay.insert(entry);
}

/// [showDialogToast] 用的內部 widget：淡入 → 停留 → 淡出，結束後呼叫 [onDismissed]。
class _DialogToast extends StatefulWidget {
  /// 建立 [_DialogToast]。
  const _DialogToast({required this.message, required this.onDismissed});

  /// 要顯示的提示文字。
  final String message;

  /// 淡出結束後的回呼；呼叫端據此移除 [OverlayEntry]。
  final VoidCallback onDismissed;

  @override
  State<_DialogToast> createState() => _DialogToastState();
}

/// [_DialogToast] 的 state：管理淡入淡出動畫與停留計時。
class _DialogToastState extends State<_DialogToast>
    with SingleTickerProviderStateMixin {
  /// 淡入淡出動畫控制器（forward = 淡入、reverse = 淡出）。
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  /// 停留計時器；時間到觸發淡出。
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
    _holdTimer = Timer(const Duration(milliseconds: 2200), _dismiss);
  }

  /// 淡出後通知呼叫端移除 entry；重複呼叫安全。
  Future<void> _dismiss() async {
    _holdTimer?.cancel();
    if (!mounted) return;
    await _ctrl.reverse();
    if (!mounted) return;
    widget.onDismissed();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FadeTransition(
              opacity: _ctrl,
              child: Material(
                key: const ValueKey('dialogToast'),
                color: theme.colorScheme.inverseSurface,
                borderRadius: BorderRadius.circular(8),
                elevation: 6,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Text(
                      widget.message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onInverseSurface,
                      ),
                    ),
                  ),
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

- [ ] **Step 4: 跑測試，確認通過（綠燈）**

Run: `fvm flutter test test/widgets/dialogs/dialog_toast_test.dart`
Expected: PASS——4 個測試全綠。

- [ ] **Step 5: 格式化 + analyze**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/dialogs/dialog_toast.dart test/widgets/dialogs/dialog_toast_test.dart
git commit -m "feat(dialog-toast): add shared overlay toast matching Genshin style"
```

---

## Task 2: 詳情 dialog 改用 `showDialogToast`

**Files:**
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`
- Test: `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`

- [ ] **Step 1: 更新既有 toast 測試（先紅）**

在 `test/widgets/dialogs/gacha_item_detail_dialog_test.dart` 找到（約 line 1268-1272）：

```dart
      await tester.tap(find.text('複製圖片'));
      await tester.pump();
      // toast 置於 dialog 之上的 Stack，存在於 dialog 子樹內、不被蓋住。
      expect(find.byKey(const ValueKey('itemDetailToast')), findsOneWidget);
      expect(find.text('已複製圖片到剪貼簿'), findsOneWidget);
      // flush toast 自動消失計時器，避免測試結束時殘留 pending timer。
      await tester.pump(const Duration(seconds: 3));
```

替換為（toast 改為 overlay 版，用共用 key；flush 改對齊新停留＋淡出時間）：

```dart
      await tester.tap(find.text('複製圖片'));
      await tester.pump(); // 啟動 overlay toast 淡入
      // toast 為 overlay entry，疊在 dialog／modal barrier 之上、不被蓋住。
      expect(find.byKey(const ValueKey('dialogToast')), findsOneWidget);
      expect(find.text('已複製圖片到剪貼簿'), findsOneWidget);
      // flush 停留計時器與淡出動畫，避免測試結束時殘留 pending timer。
      await tester.pump(const Duration(milliseconds: 2200));
      await tester.pumpAndSettle();
```

並在該測試檔頂部 import 區確認（若無則加）：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/dialog_toast.dart';
```

> 註：`ValueKey('dialogToast')` 來自 Task 1 的 toast 元件；不需 import 即可用（`ValueKey` 為 framework 型別）。上面那行 import 僅在測試需直接引用 `showDialogToast` 時才必要——本步驟未直接用到，故**可不加**；若 analyze 報未使用 import 請移除。

- [ ] **Step 2: 跑測試，確認失敗（紅燈）**

Run: `fvm flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart --plain-name "在 dialog 之上彈出 toast"`
Expected: FAIL——目前仍是自管 toast（`ValueKey('itemDetailToast')`），找不到 `ValueKey('dialogToast')`。

- [ ] **Step 3: 加 import**

在 `lib/widgets/dialogs/gacha_item_detail_dialog.dart` 的 package import 區（既有 `widgets/dialogs/app_dialog.dart` 那行附近）加：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/dialog_toast.dart';
```

- [ ] **Step 4: 移除自管 toast 欄位與 dispose 清理**

找到欄位宣告（約 line 80-87）：

```dart
  /// 目前顯示的 toast 訊息；null 為不顯示。copy/save 結果在 dialog 之上回報。
  /// 不走 ScaffoldMessenger/SnackBar：那需要 Scaffold 包整個 dialog route，會擋掉
  /// barrierDismissible 的點外關閉；改用置於 dialog 之上的 Stack toast。
  String? _toastMessage;

  /// toast 自動消失計時器；[dispose] 內 cancel。
  Timer? _toastTimer;

```

整段刪除（連同空行）。

找到 `dispose`（約 line 95-99）：

```dart
  @override
  void dispose() {
    _toastTimer?.cancel();
    _client.close();
    super.dispose();
  }
```

替換為：

```dart
  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
```

- [ ] **Step 5: `_showSnack` 改呼叫 `showDialogToast`**

找到（約 line 372-381）：

```dart
  /// 在 dialog 之上顯示一則 toast（自管、置於 Stack 最上層），不被 dialog 蓋住，
  /// 也不像 Scaffold 包裹那樣擋掉 barrierDismissible 的點外關閉。
  void _showSnack(String message) {
    _toastTimer?.cancel();
    setState(() => _toastMessage = message);
    _toastTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _toastMessage = null);
    });
  }
```

替換為：

```dart
  /// 以共用 [showDialogToast] 在 dialog 之上顯示一則 toast（overlay entry，
  /// 不被 dialog 的 modal barrier 蓋住）。
  void _showSnack(String message) {
    showDialogToast(context, message);
  }
```

- [ ] **Step 6: build 移除外層 Stack 與 toast 區塊**

找到 `build` 結尾（約 line 676-678 起）：

```dart
    return Stack(
      children: [
        Positioned.fill(
          child: AppDialog(
```

替換為（直接回傳 `AppDialog`，移除為 toast 而存在的外層 `Stack` 與 `Positioned.fill`）：

```dart
    return AppDialog(
```

接著找到 `AppDialog(...)` 的收尾與其後的 toast 區塊（約 line 824-853）：

```dart
          ),
        ),
        if (_toastMessage != null)
          Positioned(
            left: 24,
            right: 24,
            bottom: 32,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Material(
                  key: const ValueKey('itemDetailToast'),
                  color: Colors.black.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Text(
                      _toastMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
```

替換為（只留 `AppDialog` 的收尾，移除 toast 區塊與 `Stack` 的 `],);`）：

```dart
          ),
    );
  }
}
```

> 注意：上面第一段（`return Stack(... Positioned.fill(child: AppDialog(`）把 `AppDialog(` 的開頭從 `Stack > Positioned.fill` 內提到頂層；第二段把 `AppDialog` 後面整個 toast 區與 `Stack` 收尾刪掉。實作後 `AppDialog(...)` 內層縮排會多兩級，跑 `fvm dart format` 會自動修正，重點是括號層級為 `return AppDialog(...);`。

- [ ] **Step 7: 跑測試，確認通過（綠燈）**

Run: `fvm flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart`
Expected: PASS——toast 測試與其餘 dialog 測試全綠。

若 `dart:async` 在本檔已無其他使用（`unawaited` 仍在 `_onImageMenuSelected` 使用 → 應仍需要），analyze 會提示；依 analyze 結果保留或移除 `import 'dart:async';`。

- [ ] **Step 8: 格式化 + analyze**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 9: Commit**

```bash
git add lib/widgets/dialogs/gacha_item_detail_dialog.dart test/widgets/dialogs/gacha_item_detail_dialog_test.dart
git commit -m "refactor(item-detail): use shared dialog toast for copy/save feedback"
```

---

## Task 3: lightbox 改用 `showDialogToast`

**Files:**
- Modify: `lib/widgets/dialogs/zoomable_image_overlay.dart`
- Test: `test/widgets/dialogs/zoomable_image_overlay_test.dart`

- [ ] **Step 1: 更新 cancel 測試（去 SnackBar 依賴，先紅）**

在 `test/widgets/dialogs/zoomable_image_overlay_test.dart` 找到（約 line 557-564）：

```dart
    testWidgets('save cancelled shows no snackbar', (tester) async {
      itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
      itemImageSaveLocationPicker = (name) async => null;
      await openOverlay(tester);
      final l = loc(tester);
      await pickMenu(tester, l.actionSaveImage);
      expect(find.byType(SnackBar), findsNothing);
    });
```

替換為（取消時不應出現 toast；改驗證共用 toast key 不存在）：

```dart
    testWidgets('save cancelled shows no toast', (tester) async {
      itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
      itemImageSaveLocationPicker = (name) async => null;
      await openOverlay(tester);
      final l = loc(tester);
      await pickMenu(tester, l.actionSaveImage);
      expect(find.byKey(const ValueKey('dialogToast')), findsNothing);
    });
```

> `copy ...`／`save ...` 兩個成功測試（line 518-555）已用 `find.text(l.itemImageCopied)`／`find.text(l.itemImageSavedTo(tmp))` 斷言，overlay toast 會在子樹放入該文字，**不需改**。

- [ ] **Step 2: 跑測試，確認狀態**

Run: `fvm flutter test test/widgets/dialogs/zoomable_image_overlay_test.dart --plain-name "save cancelled shows no toast"`
Expected: 改名後此測試會跑；目前 lightbox 仍用 SnackBar、取消時本就不彈，故 `ValueKey('dialogToast')` findsNothing → 可能已 PASS。重點 red→green 在於 Step 1 的兩個成功測試於改完實作後仍綠、且不再依賴 SnackBar。先記錄此步輸出即可。

- [ ] **Step 3: 加 import、移除 `_messengerKey`**

在 `lib/widgets/dialogs/zoomable_image_overlay.dart` 的 package import 區（既有 `services/log_sanitize.dart` 那行附近）加：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/dialog_toast.dart';
```

找到欄位（約 line 78-81）：

```dart
  /// lightbox 自帶的 ScaffoldMessenger key；copy/save 的 SnackBar 透過它顯示在
  /// 全螢幕 overlay 內部，而非被覆蓋的 app Scaffold。
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

```

整段刪除（連同空行）。

- [ ] **Step 4: `_showSnack` 改呼叫 `showDialogToast`**

找到（約 line 289-294）：

```dart
  /// 在 lightbox 內部彈 SnackBar（用自帶 [_messengerKey]，不被全螢幕 overlay 蓋住）。
  void _showSnack(String message) {
    _messengerKey.currentState
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
```

替換為：

```dart
  /// 以共用 [showDialogToast] 在 lightbox 之上彈 toast（overlay entry，疊在
  /// 全螢幕 overlay 之上、不被蓋住）。
  void _showSnack(String message) {
    showDialogToast(context, message);
  }
```

- [ ] **Step 5: build 移除 ScaffoldMessenger/Scaffold 包裹**

找到 `build` 開頭（約 line 296-304）：

```dart
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
```

替換為（直接回傳 `Stack`）：

```dart
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Stack(
      children: [
```

找到 `build` 的收尾（約 line 437-441）：

```dart
          ],
        ),
      ),
    );
  }
}
```

替換為（只留 `Stack` 的收尾）：

```dart
      ],
    );
  }
}
```

> 注意：移除兩層包裹後，原 `Stack` 內 children 會多兩級縮排，`fvm dart format` 會自動修正；重點是括號層級回到 `return Stack(children: [...]);`。

- [ ] **Step 6: 跑測試，確認通過（綠燈）**

Run: `fvm flutter test test/widgets/dialogs/zoomable_image_overlay_test.dart`
Expected: PASS——copy/save 成功測試（toast 文字）、cancel（無 toast）、其餘結構／互動測試全綠。

- [ ] **Step 7: 格式化 + analyze**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`（若 `dart:async` 仍被 `unawaited` 使用則保留；`flutter/material.dart` 仍需要）。

- [ ] **Step 8: Commit**

```bash
git add lib/widgets/dialogs/zoomable_image_overlay.dart test/widgets/dialogs/zoomable_image_overlay_test.dart
git commit -m "refactor(image-overlay): use shared dialog toast for copy/save feedback"
```

---

## Task 4: 全套驗證與手動檢查

**Files:** 無新增改動，僅驗證。

- [ ] **Step 1: 全套品質檢查**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`
Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 2: 手動驗證（release）**

Run: `fvm flutter run --release`

進 app → 開 5★ 角色 detail dialog，逐項確認：

- dialog 內（右上 `...` 或右鍵）複製／儲存 → 底部彈 toast：**淡入 → 停留約 2.2s → 淡出**，底色為主題 `inverseSurface`（非純黑），疊在 dialog 之上。
- 點主圖開 lightbox，於 lightbox 內複製／儲存 → 出現**同樣**的 toast（同色、同動畫、同位置、`maxWidth 480` 置中）。
- 兩處 toast 視覺一致；連續操作只看到最新一則（舊的立即被取代）。
- dialog 點外圍仍能關閉；lightbox 既有單擊縮放／游標／滾輪／拖曳／ESC／背景關閉皆不受影響。

- [ ] **Step 3: （可選）若手動發現問題**

回對應 Task 修正後重跑 Step 1。全綠且手動通過即完成。不要 `git push`。

---

## Self-Review Notes

- **Spec coverage**：新增共用 `dialog_toast.dart`（Task 1）、dialog 改接並移除自管 toast（Task 2）、lightbox 改接並移除 ScaffoldMessenger/SnackBar（Task 3）、`inverseSurface` 配色（Task 1 Step 3 + 測試）、不新增 ARB（全用既有 key）、測試更新／新增（Task 1/2/3）、手動驗證（Task 4）——皆有對應任務。
- **型別／命名一致**：`showDialogToast(BuildContext, String)` 在三處呼叫端簽名一致；toast 測試定位 key 統一為 `ValueKey('dialogToast')`（元件、dialog 測試、lightbox cancel 測試一致）；移除的舊符號（`_toastMessage`／`_toastTimer`／`itemDetailToast`／`_messengerKey`）在各自檔案內已無殘留引用。
- **無 placeholder**：所有 code step 皆附完整 old→new 程式碼；新檔 `dialog_toast.dart` 給出整份內容。
- **唯一刻意偏離原神版**：toast 根 `Material` 加 `ValueKey('dialogToast')`（不影響視覺，僅供測試定位），已於 Architecture 與 Task 1 標註。
