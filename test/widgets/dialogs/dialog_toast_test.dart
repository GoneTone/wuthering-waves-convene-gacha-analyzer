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
