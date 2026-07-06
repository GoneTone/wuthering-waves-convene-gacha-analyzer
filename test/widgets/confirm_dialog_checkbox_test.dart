import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/confirm_dialog.dart';

void main() {
  /// 打開帶 checkbox 的打字確認 dialog；結果經 [onResult] 回呼捕捉。
  ///
  /// 不透過 `open()` 回傳的 `Future` 承接結果——`showConfirmTypeDialogWithCheckbox`
  /// 要等對話框關閉才會 resolve，若在此處 await 會卡住呼叫端後續與對話框的互動；
  /// 因此採用與既有 `confirm_dialog_test.dart` 相同的作法：以外層變數捕捉結果。
  Future<void> open(
    WidgetTester tester,
    void Function(ConfirmTypeResult?) onResult,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              onResult(
                await showConfirmTypeDialogWithCheckbox(
                  context: context,
                  title: '確認',
                  body: '刪除帳號 100000001？',
                  expectedText: '100000001',
                  cancelLabel: '取消',
                  confirmLabel: '刪除',
                  confirmIcon: Icons.delete_outline,
                  checkboxLabel: '同時從雲端移除',
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('打字正確＋勾選 → confirmed=true, checked=true', (tester) async {
    ConfirmTypeResult? result;
    await open(tester, (r) => result = r);

    await tester.enterText(find.byType(TextField), '100000001');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刪除'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.confirmed, isTrue);
    expect(result!.checkboxChecked, isTrue);
  });

  testWidgets('不勾選 → checked=false；取消 → confirmed=false', (tester) async {
    ConfirmTypeResult? result;
    await open(tester, (r) => result = r);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result!.confirmed, isFalse);
    expect(result!.checkboxChecked, isFalse);
  });
}
