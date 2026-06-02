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
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_cache_usage.dart';
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
  container.read(gachaRepositoryProvider);
  // itemImageCacheUsageProvider 在 container 內預熱，讓 widget 訂閱時已有快取值。
  await container.read(itemImageCacheUsageProvider.future);
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return container;
}

/// 將 [SettingsPage] 包進 [MaterialApp] 與 [UncontrolledProviderScope]，
/// 套用測試所需的 i18n delegates 與主題。
Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh', 'Hant'),
    theme: buildDarkTheme(),
    home: const Scaffold(body: SettingsPage()),
  ),
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('settings_img_cache_test_');
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  /// 建立指定大小的假檔案於 [tempDir]。
  Future<void> touch(String name, int size) async {
    await File('${tempDir.path}/$name').writeAsBytes(List<int>.filled(size, 0));
  }

  testWidgets('用量顯示三行（總計 / 小圖示 / 詳情圖）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    late ProviderContainer container;

    // 全部 I/O 放 runAsync 跳出 FakeAsync，包含 pumpWidget 與等待 provider。
    await tester.runAsync(() async {
      // 100 KB icon 檔（檔名含 '_icon.' 才計入 iconBytes）
      await touch('1001_icon.png', 1024 * 100);
      // 2 MB illustration 檔（檔名含 '_illustration.' 才計入 illustrationBytes）
      await touch('1001_illustration.png', 1024 * 1024 * 2);
      container = await _setupContainer(
        storage: GachaStorage(tempDir),
        tempDir: tempDir,
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_wrap(container));
      // 等 widget 訂閱後 provider 完成（已在 setupContainer 預熱，應立即 resolve）。
      await container.read(itemImageCacheUsageProvider.future);
      await tester.pump();
    });

    // 捲動到圖片快取 section 使用量文字才在視窗內。
    await tester.scrollUntilVisible(
      find.text('100.0 KB'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    // 小圖示：100 KB
    expect(find.text('100.0 KB'), findsOneWidget);
    // 詳情圖：2 MB
    expect(find.text('2.0 MB'), findsOneWidget);
    // 總計：100 KB + 2048 KB = 2148 KB → 2.1 MB（四捨五入 1 位小數）
    expect(find.text('2.1 MB'), findsOneWidget);
  });

  testWidgets('無資料時強制重抓按鈕 disabled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    late ProviderContainer container;

    await tester.runAsync(() async {
      container = await _setupContainer(
        storage: GachaStorage(tempDir),
        tempDir: tempDir,
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_wrap(container));
      await container.read(itemImageCacheUsageProvider.future);
      await tester.pump();
    });

    final refetchBtn = find.widgetWithText(FilledButton, '強制重抓物品圖片');
    expect(refetchBtn, findsOneWidget);
    expect(
      tester.widget<FilledButton>(refetchBtn).onPressed,
      isNull,
      reason: '無喚取紀錄時強制重抓按鈕應 disabled',
    );
  });
}
