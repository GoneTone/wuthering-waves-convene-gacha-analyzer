import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/share_image_options.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/share_image_dialog.dart';

/// 包一個按鈕開啟 dialog，把回傳寫進 [onResult]。
Widget _host(
  void Function(({ShareImageOptions options, ShareImageAction action})? r)
  onResult,
) {
  return MaterialApp(
    theme: buildDarkTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
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
}
