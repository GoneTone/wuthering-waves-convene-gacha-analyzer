import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/settings_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';

/// 空 [GachaCapture] 替身，避免測試啟動真實 MITM session。
class _NullCapture implements GachaCapture {
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(null), cancel: () async {});
}

/// 建立並預熱 [ProviderContainer]（含所有 SettingsPage 所需 override）。
Future<ProviderContainer> _setupContainer({
  required GachaStorage storage,
  required Directory tempDir,
}) async {
  final container = ProviderContainer(
    overrides: [
      gachaStorageProvider.overrideWithValue(storage),
      gachaCaptureProvider.overrideWithValue(_NullCapture()),
      cancellableHttpClientFactoryProvider.overrideWithValue(
        () => CancellableHttpClient(
          client: MockClient((_) async => http.Response('{}', 200)),
          cancel: () {},
        ),
      ),
      itemImageIndexStorageProvider.overrideWithValue(
        ItemImageIndexStorage(tempDir),
      ),
      itemImageCacheDirProvider.overrideWithValue(tempDir),
      appVersionProvider.overrideWithValue('0.0.0-test'),
    ],
  );
  await container.read(settingsProvider.notifier).waitForLoad();
  await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
  return container;
}

/// 將 [SettingsPage] 包進 [MaterialApp] 與 [UncontrolledProviderScope]，
/// 套用測試所需的 i18n delegates 與英文語系。
Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    theme: buildDarkTheme(),
    home: const Scaffold(body: SettingsPage()),
  ),
);

void main() {
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = await Directory.systemTemp.createTemp('settings_data_lang_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  /// 建立 container 與 SettingsPage，回傳 container 供測試讀取 provider。
  Future<ProviderContainer> pumpSettingsPage(WidgetTester tester) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _setupContainer(
        storage: GachaStorage(tempDir),
        tempDir: tempDir,
      );
    });
    addTearDown(container.dispose);
    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return container;
  }

  testWidgets('shows data-language dropdown; unify disabled when unset', (
    tester,
  ) async {
    await pumpSettingsPage(tester);
    final l = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.text(l.settingsDataLanguage), findsOneWidget);

    final unify = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text(l.settingsDataLanguageUnify),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(unify.onPressed, isNull);
  });
}
