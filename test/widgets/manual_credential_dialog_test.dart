import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/manual_credential_dialog.dart';
import '../helpers/client_log_fixtures.dart';
import '../helpers/no_game_dir.dart';

/// 只記錄手動輸入的 repository 替身。
class _RecordingRepository extends GachaRepository {
  /// 收到的手動憑證。
  final submitted = <GachaCredential>[];

  @override
  GachaState build() => const GachaState(isBootstrapping: false);

  @override
  Future<void> submitManualCredential(GachaCredential cred) async {
    submitted.add(cred);
  }
}

/// 完整的國際服喚取記錄網址。
String _url(String id) =>
    'https://aki-gm-resources-oversea.aki-game.net/aki/gacha/index.html#/record'
    '?svr_id=s&player_id=1&lang=en&gacha_id=1&resources_id=r&record_id=$id';

void main() {
  late _RecordingRepository repo;

  /// 開啟對話框；[android] 決定說明內容，[pick] 取代系統選檔。
  Future<AppLocalizations> open(
    WidgetTester tester, {
    bool android = false,
    Future<Uint8List?> Function()? pick,
  }) async {
    repo = _RecordingRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noGameDirOverride,
          isAndroidProvider.overrideWithValue(android),
          gachaRepositoryProvider.overrideWith(() => repo),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () =>
                    showManualCredentialDialog(ctx, pickClientLog: pick),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(TextField)))!;
  }

  testWidgets('help text starts at the same edge as its title', (tester) async {
    final l = await open(tester);
    await tester.tap(find.text(l.manualCredentialHowTo));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byType(SelectableText)).dx,
      moreOrLessEquals(
        tester.getTopLeft(find.text(l.manualCredentialHowTo)).dx,
        epsilon: 1,
      ),
    );
  });

  testWidgets('field does not let the keyboard rewrite the url', (
    tester,
  ) async {
    // 實機輸入法的自動校正會把 `&lang=` 改成 `&Lang=`，網址就失效了。
    await open(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.keyboardType, TextInputType.url);
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
  });

  testWidgets('text without url shows error and keeps dialog open', (
    tester,
  ) async {
    final l = await open(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.text(l.manualCredentialSubmit));
    await tester.pumpAndSettle();
    expect(find.text(l.manualCredentialNotFound), findsOneWidget);
    expect(find.text(l.manualCredentialTitle), findsOneWidget);
    expect(repo.submitted, isEmpty);
  });

  testWidgets('pasted error page text submits and closes', (tester) async {
    final l = await open(tester);
    await tester.enterText(
      find.byType(TextField),
      '網頁無法使用\n無法載入位於 ${_url('rec1')} 的網頁',
    );
    await tester.tap(find.text(l.manualCredentialSubmit));
    await tester.pumpAndSettle();
    expect(repo.submitted.single.recordId, 'rec1');
    expect(find.text(l.manualCredentialTitle), findsNothing);
  });

  testWidgets('chosen Client.log is decoded and submitted', (tester) async {
    final l = await open(
      tester,
      pick: () async => encodeClientLog('noise ${_url('log1')}\n'),
    );
    await tester.tap(find.text(l.manualCredentialPickLog));
    await tester.pumpAndSettle();
    expect(repo.submitted.single.recordId, 'log1');
  });

  testWidgets('Client.log without url shows the log error', (tester) async {
    final l = await open(tester, pick: () async => encodeClientLog('x\n'));
    await tester.tap(find.text(l.manualCredentialPickLog));
    await tester.pumpAndSettle();
    expect(find.text(l.manualCredentialNotFoundInLog), findsOneWidget);
    expect(repo.submitted, isEmpty);
  });

  testWidgets('help shows airplane mode on android', (tester) async {
    final l = await open(tester, android: true);
    await tester.tap(find.text(l.manualCredentialHowTo));
    await tester.pumpAndSettle();
    expect(find.text(l.manualCredentialHelpAndroid), findsOneWidget);
    expect(find.text(l.manualCredentialHelpWindows), findsNothing);
  });

  testWidgets('help shows Client.log path on windows', (tester) async {
    final l = await open(tester);
    await tester.tap(find.text(l.manualCredentialHowTo));
    await tester.pumpAndSettle();
    expect(find.text(l.manualCredentialHelpWindows), findsOneWidget);
  });
}
