import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/importers/wuwa_tracker_importer.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/platform_import.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/platform_picker_dialog.dart';

// 用 file-level 變數捕捉 dialog 結果（同 accounts_picker_dialog_test.dart 模式）。
PlatformImporter? _result;
bool _completed = false;

Future<void> _open(WidgetTester tester) async {
  _result = null;
  _completed = false;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'Hant'),
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  _result = await showPlatformPickerDialog(context: ctx);
                  _completed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists WuWa Tracker and returns it on tap', (tester) async {
    await _open(tester);
    expect(find.text('WuWa Tracker'), findsOneWidget);

    await tester.tap(find.text('WuWa Tracker'));
    await tester.pumpAndSettle();

    expect(_completed, isTrue);
    expect(_result, isA<WuwaTrackerImporter>());
  });

  testWidgets('cancel returns null', (tester) async {
    await _open(tester);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(_completed, isTrue);
    expect(_result, isNull);
  });
}
