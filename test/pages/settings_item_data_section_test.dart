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

BannerStorage _seeded() => BannerStorage(
  playerId: '1001',
  languageCode: 'zh-Hant',
  lastUpdated: DateTime.utc(2026, 5, 24),
  banners: {
    '1': [
      GachaRecord(
        resourceId: 1301,
        qualityLevel: 5,
        resourceType: '角色',
        cardPoolType: '1',
        name: 'r1301',
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
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('settings_item_data_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('無喚取紀錄：更新物品資料按鈕 disabled', (tester) async {
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

    final btn = find.widgetWithText(FilledButton, '更新物品資料');
    expect(btn, findsOneWidget);
    expect(tester.widget<FilledButton>(btn).onPressed, isNull);
  });

  testWidgets('有紀錄：按鈕 enabled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = GachaStorage(tempDir);
    late ProviderContainer container;
    await tester.runAsync(() async {
      await storage.save(_seeded());
      container = await _setupContainer(storage: storage, tempDir: tempDir);
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final btn = find.widgetWithText(FilledButton, '更新物品資料');
    expect(tester.widget<FilledButton>(btn).onPressed, isNotNull);
  });

  testWidgets('點按鈕 → 確認 dialog 出現 → 取消不啟動 progress', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = GachaStorage(tempDir);
    late ProviderContainer container;
    await tester.runAsync(() async {
      await storage.save(_seeded());
      container = await _setupContainer(storage: storage, tempDir: tempDir);
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final btn = find.widgetWithText(FilledButton, '更新物品資料');
    await tester.scrollUntilVisible(
      btn,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(btn);
    await tester.pumpAndSettle();

    // 確認 dialog 內容（確認鍵文字）。
    expect(find.text('開始更新'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.text('開始更新'), findsNothing);
    expect(container.read(gachaRepositoryProvider).progress, isNull);
  });
}
