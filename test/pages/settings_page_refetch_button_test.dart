import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/settings_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';

class _NullCapture implements GachaCapture {
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(null), cancel: () async {});
}

/// 建立並預熱 [ProviderContainer]（含所有 SettingsPage 所需 override）。
///
/// 必須在 [WidgetTester.runAsync] 裡呼叫，以跳出 FakeAsync 讓 File I/O 正常完成。
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
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return container;
}

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
    tempDir = await Directory.systemTemp.createTemp('settings_refetch_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('無喚取紀錄：按鈕 disabled', (tester) async {
    SharedPreferences.setMockInitialValues({});
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

    final btn = find.widgetWithText(FilledButton, '強制重抓物品圖片');
    expect(btn, findsOneWidget);
    expect(
      tester.widget<FilledButton>(btn).onPressed,
      isNull,
      reason: '無紀錄應 disabled',
    );
  });

  testWidgets('有紀錄、progress 為 null：按鈕 enabled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = GachaStorage(tempDir);
    late ProviderContainer container;
    await tester.runAsync(() async {
      await storage.save(
        BannerStorage(
          playerId: '1001',
          languageCode: 'en',
          lastUpdated: DateTime.utc(2026, 5, 24),
          banners: {
            '1': [
              GachaRecord(
                resourceId: 1301,
                qualityLevel: 5,
                resourceType: 'Character',
                cardPoolType: '1',
                name: 'Hu Tao',
                count: 1,
                time: DateTime(2026, 5, 24),
              ),
            ],
            '2': [],
            '3': [],
            '4': [],
            '5': [],
            '6': [],
            '8': [],
            '9': [],
          },
        ),
      );
      container = await _setupContainer(storage: storage, tempDir: tempDir);
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final btn = find.widgetWithText(FilledButton, '強制重抓物品圖片');
    expect(tester.widget<FilledButton>(btn).onPressed, isNotNull);
  });

  testWidgets('點按鈕 → 確認 dialog 出現 → 取消不呼叫 repository', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = GachaStorage(tempDir);
    late ProviderContainer container;
    await tester.runAsync(() async {
      await storage.save(
        BannerStorage(
          playerId: '1001',
          languageCode: 'en',
          lastUpdated: DateTime.utc(2026, 5, 24),
          banners: {
            '1': [
              GachaRecord(
                resourceId: 1301,
                qualityLevel: 5,
                resourceType: 'Character',
                cardPoolType: '1',
                name: 'Hu Tao',
                count: 1,
                time: DateTime(2026, 5, 24),
              ),
            ],
            '2': [],
            '3': [],
            '4': [],
            '5': [],
            '6': [],
            '8': [],
            '9': [],
          },
        ),
      );
      container = await _setupContainer(storage: storage, tempDir: tempDir);
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 按鈕已移至 _ImageCacheSection，需先捲動使其進入視窗再點擊。
    final refetchBtn = find.widgetWithText(FilledButton, '強制重抓物品圖片');
    await tester.scrollUntilVisible(
      refetchBtn,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(refetchBtn);
    await tester.pumpAndSettle();

    // 確認 dialog 內容存在
    expect(find.text('開始重抓'), findsOneWidget);

    // 點取消
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    // Dialog 關閉
    expect(find.text('開始重抓'), findsNothing);

    // 取消路徑不會 emit Preparing，state.progress 仍為 null
    expect(
      container.read(gachaRepositoryProvider).progress,
      isNull,
      reason: '取消後不應啟動 progress',
    );
  });
}
