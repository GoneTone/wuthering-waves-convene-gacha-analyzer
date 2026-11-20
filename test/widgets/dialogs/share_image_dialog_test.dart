import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/share_image_options.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/share_image_dialog.dart';

/// 包一個按鈕開啟 dialog，把回傳寫進 [onResult]。
Widget _host(
  void Function(({ShareImageOptions options, ShareImageAction action})? r)
  onResult, {
  bool android = false,
  Locale locale = const Locale('zh'),
}) {
  return ProviderScope(
    overrides: [isAndroidProvider.overrideWithValue(android)],
    child: MaterialApp(
      theme: buildDarkTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                onResult(
                  await showShareImageDialog(
                    ctx,
                    initialBrightness: Brightness.dark,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('按「儲存圖片」→ action=save，預設深色 + 不顯示完整 UID', (t) async {
    ({ShareImageOptions options, ShareImageAction action})? result;
    await t.pumpWidget(_host((r) => result = r));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    await t.tap(find.text(l.actionSaveImage));
    await t.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.action, ShareImageAction.save);
    expect(result!.options.brightness, Brightness.dark);
    expect(result!.options.showFullUid, isFalse);
  });

  testWidgets('按「複製圖片」→ action=copy', (t) async {
    ({ShareImageOptions options, ShareImageAction action})? result;
    await t.pumpWidget(_host((r) => result = r));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    await t.tap(find.text(l.actionCopyImage));
    await t.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.action, ShareImageAction.copy);
  });

  testWidgets('取消回傳 null', (t) async {
    ({ShareImageOptions options, ShareImageAction action})? result = (
      options: const ShareImageOptions(),
      action: ShareImageAction.save,
    );
    await t.pumpWidget(_host((r) => result = r));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    await t.tap(find.text(l.actionCancel));
    await t.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('Android 才顯示「分享」鈕，按下 → action=share', (t) async {
    ({ShareImageOptions options, ShareImageAction action})? result;
    await t.pumpWidget(_host((r) => result = r, android: true));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    await t.tap(find.text(l.actionShare));
    await t.pumpAndSettle();

    expect(result!.action, ShareImageAction.share);
  });

  testWidgets('Windows 不顯示「分享」鈕', (t) async {
    await t.pumpWidget(_host((_) {}));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    expect(find.text(l.actionShare), findsNothing);
  });

  for (final size in const [Size(360, 800), Size(800, 360)]) {
    for (final locale in const [
      Locale('zh', 'Hant'),
      Locale('en'),
      Locale('fr'),
    ]) {
      testWidgets('Android share image buttons fit $size in $locale', (
        t,
      ) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(_host((_) {}, android: true, locale: locale));
        await t.tap(find.text('open'));
        await t.pumpAndSettle();

        final l = lookupAppLocalizations(locale);
        expect(t.takeException(), isNull);
        for (final label in [
          l.actionCancel,
          l.actionCopyImage,
          l.actionShare,
          l.actionSaveImage,
        ]) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
      });
    }
  }
}
