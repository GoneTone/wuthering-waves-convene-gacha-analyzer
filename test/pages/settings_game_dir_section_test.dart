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
import 'package:wuthering_waves_convene_gacha_analyzer/services/game_dir_locator.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import '../helpers/no_game_dir.dart';

/// 空 [GachaCapture] 替身，避免測試啟動真實 MITM session。
class _NullCapture implements GachaCapture {
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(null), cancel: () async {});
}

/// 回傳固定結果、`normalize` 一律通過的 locator 替身；[location] 為 null 代表偵測不到。
class _FakeLocator extends GameDirLocator {
  /// 建立替身。
  _FakeLocator(this.location);

  /// `locate` 在沒有設定值時回傳的結果。
  final GameDirLocation? location;

  @override
  Future<GameDirLocation?> locate({String? settingDir}) async => location;

  @override
  Future<String?> normalize(String picked) async =>
      picked.contains('bad') ? null : picked;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = await Directory.systemTemp.createTemp('settings_game_dir_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// 啟動 SettingsPage；[locator] 預設為找不到遊戲資料夾。
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    GameDirLocator? locator,
    String? settingDir,
    Future<String?> Function()? pickDirectory,
    Size size = const Size(1000, 2000),
  }) async {
    if (settingDir != null) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'pref.gameDir': settingDir,
      });
    }
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = ProviderContainer(
        overrides: [
          gameDirLocatorProvider.overrideWithValue(
            locator ?? NoGameDirLocator(),
          ),
          gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
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
    });
    addTearDown(container.dispose);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: buildDarkTheme(),
          home: Scaffold(body: SettingsPage(pickGameDir: pickDirectory)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return container;
  }

  testWidgets('shows manual setting with path and clear button', (
    tester,
  ) async {
    final container = await pump(
      tester,
      settingDir: r'D:\Games\Wuthering Waves Game',
    );
    expect(
      find.text(r'Set manually: D:\Games\Wuthering Waves Game'),
      findsOneWidget,
    );
    final clear = find.byKey(const ValueKey('settings.gameDirClear'));
    await tester.ensureVisible(clear);
    await tester.tap(clear);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(container.read(settingsProvider).gameDir, isNull);
    expect(find.text('Game folder not found'), findsOneWidget);
  });

  testWidgets('shows auto-detected path when no setting', (tester) async {
    await pump(
      tester,
      locator: _FakeLocator(
        const GameDirLocation(r'C:\WW\Game', GameDirSource.registry),
      ),
    );
    expect(find.text(r'Auto-detected: C:\WW\Game'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings.gameDirClear')), findsNothing);
  });

  testWidgets('choose saves picked dir; invalid shows snack bar', (
    tester,
  ) async {
    String? next;
    final container = await pump(
      tester,
      locator: _FakeLocator(null),
      pickDirectory: () async => next,
    );
    final choose = find.byKey(const ValueKey('settings.gameDirChoose'));
    await tester.ensureVisible(choose);
    await tester.pump();

    next = r'D:\bad';
    await tester.tap(choose);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('No game log file'), findsOneWidget);
    expect(container.read(settingsProvider).gameDir, isNull);

    next = r'D:\good';
    await tester.tap(choose);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(container.read(settingsProvider).gameDir, r'D:\good');
    expect(find.text(r'Set manually: D:\good'), findsOneWidget);
  });

  testWidgets('long path does not overflow on narrow width', (tester) async {
    await pump(
      tester,
      settingDir: r'D:\' + 'VeryLongFolderName' * 12 + r'\Wuthering Waves Game',
      size: const Size(360, 2000),
    );
    // 設定頁其他區塊在窄寬度本來就會溢位，這裡只驗證本區塊的元件都落在視窗內。
    tester.takeException();
    for (final f in [
      find.textContaining('Set manually'),
      find.byKey(const ValueKey('settings.gameDirChoose')),
      find.byKey(const ValueKey('settings.gameDirClear')),
    ]) {
      expect(tester.getRect(f).right, lessThanOrEqualTo(360));
    }
  });
}
