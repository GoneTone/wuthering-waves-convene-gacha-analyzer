import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/confirm_dialog.dart';

void main() {
  testWidgets('delete button disabled until input matches', (tester) async {
    bool confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  confirmed =
                      await showConfirmTypeDialog(
                        context: ctx,
                        title: 'Confirm',
                        body: 'Type X to confirm',
                        expectedText: 'X',
                        cancelLabel: 'Cancel',
                        confirmLabel: 'Delete',
                        confirmIcon: Icons.delete_outline,
                      ) ??
                      false;
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final deleteBtn = find.widgetWithText(FilledButton, 'Delete');
    expect(tester.widget<FilledButton>(deleteBtn).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'X');
    await tester.pump();
    expect(tester.widget<FilledButton>(deleteBtn).onPressed, isNotNull);

    await tester.tap(deleteBtn);
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('action buttons render with icons', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showConfirmTypeDialog(
                  context: ctx,
                  title: 'Confirm',
                  body: 'Type X',
                  expectedText: 'X',
                  cancelLabel: 'Cancel',
                  confirmLabel: 'Delete',
                  confirmIcon: Icons.delete_outline,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('confirmIcon controls the confirm button icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showConfirmTypeDialog(
                  context: ctx,
                  title: 'Confirm',
                  body: 'Type X',
                  expectedText: 'X',
                  cancelLabel: 'Cancel',
                  confirmLabel: 'Import',
                  confirmIcon: Icons.check,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('showConfirmDialog: confirm enabled immediately, returns true', (
    tester,
  ) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  confirmed = await showConfirmDialog(
                    context: ctx,
                    title: 'Merge',
                    body: 'About to merge',
                    cancelLabel: 'Cancel',
                    confirmLabel: 'Import',
                    confirmIcon: Icons.check,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // 無 TextField；確認鍵一開始就 enabled
    expect(find.byType(TextField), findsNothing);
    final confirmBtn = find.widgetWithText(FilledButton, 'Import');
    expect(tester.widget<FilledButton>(confirmBtn).onPressed, isNotNull);

    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('showConfirmDialog: cancel returns false', (tester) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  confirmed = await showConfirmDialog(
                    context: ctx,
                    title: 'Merge',
                    body: 'About to merge',
                    cancelLabel: 'Cancel',
                    confirmLabel: 'Import',
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(confirmed, isFalse);
  });

  testWidgets('showConfirmDialog: isDanger uses danger color for confirm', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showConfirmDialog(
                  context: ctx,
                  title: 'Clear',
                  body: 'About to clear',
                  cancelLabel: 'Cancel',
                  confirmLabel: 'Delete',
                  confirmIcon: Icons.delete_outline,
                  isDanger: true,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final btn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Delete'),
    );
    expect(
      btn.style?.backgroundColor?.resolve(<WidgetState>{}),
      buildDarkTheme().gacha.stateDanger,
    );
  });
}
