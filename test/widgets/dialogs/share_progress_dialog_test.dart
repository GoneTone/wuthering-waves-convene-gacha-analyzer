import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/share_progress_dialog.dart';

void main() {
  testWidgets('顯示生成中文字與 LinearProgressIndicator', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const Scaffold(body: ShareProgressDialog()),
      ),
    );
    await t.pump();

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    expect(find.text(l.shareImageGenerating), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('PopScope 不允許使用者關閉（canPop=false）', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const Scaffold(body: ShareProgressDialog()),
      ),
    );
    await t.pump();

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    final popScopes = t.widgetList<PopScope>(
      find.ancestor(
        of: find.text(l.shareImageGenerating),
        matching: find.byType(PopScope),
      ),
    );
    expect(popScopes.any((p) => p.canPop == false), isTrue);
  });
}
