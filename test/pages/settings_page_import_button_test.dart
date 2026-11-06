import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:wuthering_waves_convene_gacha_analyzer/services/file_access.dart';
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

/// 啟動測試用 [ProviderContainer]，覆寫 SettingsPage 所需依賴並完成 bootstrap。
Future<ProviderContainer> _setupContainer({
  required GachaStorage storage,
  required Directory tempDir,
}) async {
  final container = ProviderContainer(
    overrides: [
      noGameDirOverride,
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

/// 最近一次選檔對話框收到的標題。
String? openTitle;

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('settings_import_btn_');
  });

  tearDown(() async {
    resetFileAccessSeams();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('progress 為 null：匯入按鈕 enabled（無紀錄也可按）', (tester) async {
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

    final btn = find.widgetWithText(OutlinedButton, '匯入資料');
    expect(btn, findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(btn).onPressed,
      isNotNull,
      reason: '匯入按鈕在 progress 為 null 時應 enabled（含無紀錄）',
    );
  });

  testWidgets('progress 非 null：匯入按鈕 disabled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _setupContainer(
        storage: GachaStorage(tempDir),
        tempDir: tempDir,
      );
    });
    addTearDown(container.dispose);

    // 用 debug API 將 progress 設為 Preparing
    container
        .read(gachaRepositoryProvider.notifier)
        .debugSetProgress(const Preparing());

    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final btn = find.widgetWithText(OutlinedButton, '匯入資料');
    expect(btn, findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(btn).onPressed,
      isNull,
      reason: 'progress 非 null 時匯入按鈕應 disabled',
    );
  });

  testWidgets('progress 為 null：其他平台匯入按鈕 enabled', (tester) async {
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

    final btn = find.widgetWithText(OutlinedButton, '從其他平台匯入');
    expect(btn, findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(btn).onPressed,
      isNotNull,
      reason: '其他平台匯入按鈕在 progress 為 null 時應 enabled',
    );
  });

  testWidgets('progress 非 null：其他平台匯入按鈕 disabled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _setupContainer(
        storage: GachaStorage(tempDir),
        tempDir: tempDir,
      );
    });
    addTearDown(container.dispose);

    container
        .read(gachaRepositoryProvider.notifier)
        .debugSetProgress(const Preparing());

    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final btn = find.widgetWithText(OutlinedButton, '從其他平台匯入');
    expect(btn, findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(btn).onPressed,
      isNull,
      reason: 'progress 非 null 時其他平台匯入按鈕應 disabled',
    );
  });

  /// 以 [bytes]（null 代表取消）當選檔內容，點擊 [buttonText] 並等流程跑完；
  /// [pickPlatform] 為 true 時再點平台選擇視窗的第一個平台。
  Future<void> tapImportWith(
    WidgetTester tester,
    Uint8List? bytes,
    String buttonText, {
    bool pickPlatform = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _setupContainer(
        storage: GachaStorage(tempDir),
        tempDir: tempDir,
      );
    });
    addTearDown(container.dispose);
    fileOpenDialog = (_, title) async {
      openTitle = title;
      return bytes;
    };

    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    final btn = find.widgetWithText(OutlinedButton, buttonText);
    await tester.ensureVisible(btn);
    await tester.tap(btn);
    await tester.pumpAndSettle();
    if (pickPlatform) {
      await tester.tap(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(ListTile),
            )
            .first,
      );
      await tester.pumpAndSettle();
    }
  }

  testWidgets('import dialog gets the localized open title', (tester) async {
    await tapImportWith(tester, Uint8List.fromList([0xff]), '匯入資料');
    expect(openTitle, '開啟');
  });

  testWidgets(
    'importing a backup with invalid UTF-8 shows the unreadable message',
    (tester) async {
      await tapImportWith(
        tester,
        Uint8List.fromList([0xff, 0xfe, 0xfd]),
        '匯入資料',
      );

      expect(find.textContaining('無法讀取'), findsOneWidget);
    },
  );

  testWidgets(
    'importing reads Chinese aliases correctly through pickTextFile',
    (tester) async {
      final json = jsonEncode({
        'schema_version': 2,
        'app': 'wuthering_waves_convene_gacha_analyzer',
        'exported_at': '2026-05-12T08:30:00.000Z',
        'app_version': '1.0.0',
        'last_active_uid': null,
        'accounts': [
          {
            'player_id': '100000001',
            'alias': '我的帳號',
            'language_code': 'zh-Hant',
            'last_updated': '2026-05-12T08:30:00.000Z',
            'banners': {'1': []},
          },
        ],
      });
      await tapImportWith(
        tester,
        Uint8List.fromList(utf8.encode(json)),
        '匯入資料',
      );

      expect(find.textContaining('我的帳號'), findsOneWidget);
    },
  );

  testWidgets('platform import of invalid UTF-8 shows the unreadable message', (
    tester,
  ) async {
    await tapImportWith(
      tester,
      Uint8List.fromList([0xff, 0xfe, 0xfd]),
      '從其他平台匯入',
      pickPlatform: true,
    );

    expect(find.textContaining('無法讀取'), findsOneWidget);
  });

  testWidgets('cancelling the platform import file picker shows nothing', (
    tester,
  ) async {
    await tapImportWith(tester, null, '從其他平台匯入', pickPlatform: true);

    expect(openTitle, '開啟');
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(Dialog), findsNothing);
  });
}
