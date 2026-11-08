import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/wait_until.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/settings_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/file_access.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/log_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import '../helpers/no_game_dir.dart';

/// 空 [GachaCapture] 替身。
class _NullCapture implements GachaCapture {
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(null), cancel: () async {});
}

/// 不碰檔案系統的 [LogService] 替身，只回傳固定的日誌內容。
class _FakeLogService implements LogService {
  /// 非 null 時 [buildExportBundle] 改丟這個例外。
  Object? bundleError;

  @override
  Future<String> buildExportBundle({
    required String appVersion,
    required String osDescription,
    required String localeTag,
    required String themeMode,
  }) async {
    if (bundleError != null) throw bundleError!;
    return 'fake log bundle';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 一次 saveBytes 呼叫的記錄。
typedef _Saved = ({Uint8List bytes, String name, String ext, String mime});

/// 一次 shareBytes 呼叫的記錄。
typedef _Shared = ({Uint8List bytes, String name, String mime});

void main() {
  Directory? tempDir;
  late List<_Saved> saves;
  late List<_Shared> shares;
  String? saveResult;
  Object? shareError;
  late _FakeLogService logService;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    saves = [];
    shares = [];
    saveResult = '/document/primary:Download/out.json';
    shareError = null;
    logService = _FakeLogService();
    fileSaveDialog = (bytes, name, ext, mime, title) async {
      saves.add((bytes: bytes, name: name, ext: ext, mime: mime));
      return saveResult;
    };
    fileSharer = (bytes, name, mime) async {
      if (shareError != null) throw shareError!;
      shares.add((bytes: bytes, name: name, mime: mime));
    };
  });

  tearDown(() async {
    resetFileAccessSeams();
    if (tempDir != null && await tempDir!.exists()) {
      await tempDir!.delete(recursive: true);
    }
  });

  Future<AppLocalizations> pump(
    WidgetTester tester, {
    required bool android,
  }) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      final dir = tempDir = await Directory.systemTemp.createTemp(
        'settings_export_',
      );
      final storage = GachaStorage(dir);
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
          },
        ),
      );
      container = ProviderContainer(
        overrides: [
          noGameDirOverride,
          isAndroidProvider.overrideWithValue(android),
          logServiceProvider.overrideWithValue(logService),
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWithValue(_NullCapture()),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(
              client: MockClient((_) async => http.Response('{}', 200)),
              cancel: () {},
            ),
          ),
          itemImageIndexStorageProvider.overrideWithValue(
            ItemImageIndexStorage(dir),
          ),
          itemImageCacheDirProvider.overrideWithValue(dir),
          appVersionProvider.overrideWithValue('0.0.0-test'),
        ],
      );
      await container.read(settingsProvider.notifier).waitForLoad();
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    });
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'Hant'),
          theme: buildDarkTheme(),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return AppLocalizations.of(tester.element(find.byType(SettingsPage)))!;
  }

  /// 打開備份匯出的帳號挑選視窗。
  Future<void> openBackupPicker(WidgetTester tester, AppLocalizations l) async {
    await tester.tap(find.text(l.settingsExportData));
    await tester.pumpAndSettle();
  }

  final android = TargetPlatformVariant.only(TargetPlatform.android);
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets('accounts picker shows share and save on Android export', (
    tester,
  ) async {
    final l = await pump(tester, android: true);
    await openBackupPicker(tester, l);
    expect(find.widgetWithText(OutlinedButton, l.actionShare), findsOneWidget);
    expect(find.widgetWithText(FilledButton, l.actionSave), findsOneWidget);
    expect(find.text(l.confirmExport), findsNothing);
  }, variant: android);

  testWidgets('accounts picker keeps only confirmExport on Windows', (
    tester,
  ) async {
    final l = await pump(tester, android: false);
    await openBackupPicker(tester, l);
    expect(find.widgetWithText(FilledButton, l.confirmExport), findsOneWidget);
    expect(find.text(l.actionShare), findsNothing);
    expect(find.text(l.actionSave), findsNothing);
  }, variant: windows);

  testWidgets(
    'exporting a backup on Android saves through saveBytes and shows the file name',
    (tester) async {
      final l = await pump(tester, android: true);
      await openBackupPicker(tester, l);
      await tester.tap(find.widgetWithText(FilledButton, l.actionSave));
      await pumpUntil(tester, () => saves.isNotEmpty);
      expect(saves, hasLength(1));
      expect(saves.single.name, matches(r'^wuwa_convene_backup_.+\.json$'));
      expect(saves.single.ext, 'json');
      expect(saves.single.mime, 'application/json');
      expect(utf8.decode(saves.single.bytes), contains('1001'));
      expect(find.textContaining('out.json'), findsOneWidget);
      expect(find.text(l.actionOpenFolder), findsNothing);
    },
    variant: android,
  );

  testWidgets(
    'sharing a backup sends wuwa_convene_backup_<stamp>.json as application/json',
    (tester) async {
      final l = await pump(tester, android: true);
      await openBackupPicker(tester, l);
      await tester.tap(find.widgetWithText(OutlinedButton, l.actionShare));
      await pumpUntil(tester, () => shares.isNotEmpty);
      expect(saves, isEmpty);
      expect(shares, hasLength(1));
      expect(shares.single.name, matches(r'^wuwa_convene_backup_.+\.json$'));
      expect(shares.single.mime, 'application/json');
      expect(find.text(l.shareFailed), findsNothing);
    },
    variant: android,
  );

  testWidgets('a failed backup share shows shareFailed', (tester) async {
    shareError = Exception('boom');
    final l = await pump(tester, android: true);
    await openBackupPicker(tester, l);
    await tester.tap(find.widgetWithText(OutlinedButton, l.actionShare));
    await pumpUntil(
      tester,
      () => find.text(l.shareFailed).evaluate().isNotEmpty,
    );
    expect(find.text(l.shareFailed), findsOneWidget);
  }, variant: android);

  testWidgets('Windows backup export success still offers open folder', (
    tester,
  ) async {
    saveResult = r'C:\tmp\wuwa_backup.json';
    final l = await pump(tester, android: false);
    await openBackupPicker(tester, l);
    await tester.tap(find.widgetWithText(FilledButton, l.confirmExport));
    await pumpUntil(tester, () => saves.isNotEmpty);
    expect(saves.single.mime, 'application/json');
    expect(find.text(l.actionOpenFolder), findsOneWidget);
    expect(find.textContaining(r'C:\tmp\wuwa_backup.json'), findsOneWidget);
  }, variant: windows);

  testWidgets('Android logs section shows share instead of open folder', (
    tester,
  ) async {
    final l = await pump(tester, android: true);
    expect(find.text(l.settingsLogsShare), findsOneWidget);
    expect(find.text(l.settingsLogsOpenFolder), findsNothing);
    expect(find.text(l.settingsLogsExport), findsOneWidget);
  }, variant: android);

  testWidgets('Windows logs section keeps open folder without share', (
    tester,
  ) async {
    final l = await pump(tester, android: false);
    expect(find.text(l.settingsLogsOpenFolder), findsOneWidget);
    expect(find.text(l.settingsLogsShare), findsNothing);
  }, variant: windows);

  testWidgets('sharing logs sends wwcga_logs_<stamp>.log as text/plain', (
    tester,
  ) async {
    final l = await pump(tester, android: true);
    await tester.tap(find.text(l.settingsLogsShare));
    await tester.pumpAndSettle();
    expect(shares, hasLength(1));
    expect(shares.single.name, matches(r'^wwcga_logs_.+\.log$'));
    expect(shares.single.mime, 'text/plain');
    expect(utf8.decode(shares.single.bytes), 'fake log bundle');
  }, variant: android);

  testWidgets('exporting logs saves them as text/plain', (tester) async {
    saveResult = '/document/primary:Download/logs.log';
    final l = await pump(tester, android: true);
    await tester.tap(find.text(l.settingsLogsExport));
    await tester.pumpAndSettle();
    expect(saves.single.name, matches(r'^wwcga_logs_.+\.log$'));
    expect(saves.single.ext, 'log');
    expect(saves.single.mime, 'text/plain');
    expect(find.textContaining('logs.log'), findsOneWidget);
  }, variant: android);

  testWidgets('cancelling the backup save shows no dialog', (tester) async {
    saveResult = null;
    final l = await pump(tester, android: false);
    await openBackupPicker(tester, l);
    await tester.tap(find.widgetWithText(FilledButton, l.confirmExport));
    await pumpUntil(tester, () => saves.isNotEmpty);
    expect(saves, hasLength(1));
    expect(find.byType(Dialog), findsNothing);
  }, variant: windows);

  testWidgets('a failing backup save shows the write failed dialog', (
    tester,
  ) async {
    fileSaveDialog = (_, _, _, _, _) async => throw StateError('boom');
    final l = await pump(tester, android: false);
    await openBackupPicker(tester, l);
    await tester.tap(find.widgetWithText(FilledButton, l.confirmExport));
    await pumpUntil(
      tester,
      () => find
          .text(l.settingsExportFailed(l.exportReasonWriteFailed))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.text(l.settingsExportFailed(l.exportReasonWriteFailed)),
      findsOneWidget,
    );
  }, variant: windows);

  testWidgets('a failing logs save shows the logs export failed dialog', (
    tester,
  ) async {
    final error = StateError('boom');
    fileSaveDialog = (_, _, _, _, _) async => throw error;
    final l = await pump(tester, android: true);
    await tester.tap(find.text(l.settingsLogsExport));
    await tester.pumpAndSettle();
    expect(
      find.text(l.settingsLogsExportFailed(error.toString())),
      findsOneWidget,
    );
  }, variant: android);

  testWidgets('a failing log bundle shows the logs export failed dialog', (
    tester,
  ) async {
    final error = StateError('no logs');
    logService.bundleError = error;
    final l = await pump(tester, android: true);
    await tester.tap(find.text(l.settingsLogsExport));
    await tester.pumpAndSettle();
    expect(saves, isEmpty);
    expect(
      find.text(l.settingsLogsExportFailed(error.toString())),
      findsOneWidget,
    );
  }, variant: android);

  testWidgets('a failing log bundle shows shareFailed when sharing', (
    tester,
  ) async {
    logService.bundleError = StateError('no logs');
    final l = await pump(tester, android: true);
    await tester.tap(find.text(l.settingsLogsShare));
    await tester.pumpAndSettle();
    expect(shares, isEmpty);
    expect(find.text(l.shareFailed), findsOneWidget);
  }, variant: android);

  group('export logs carry the saved location', () {
    late List<String> messages;

    setUp(() {
      messages = [];
      final sub = Logger.root.onRecord
          .where((r) => r.loggerName == 'accounts.io')
          .listen((r) => messages.add(r.message));
      addTearDown(sub.cancel);
    });

    testWidgets('Windows backup log includes the sanitized path', (
      tester,
    ) async {
      saveResult = r'C:\tmp\wuwa_backup.json';
      final l = await pump(tester, android: false);
      await openBackupPicker(tester, l);
      await tester.tap(find.widgetWithText(FilledButton, l.confirmExport));
      await pumpUntil(tester, () => saves.isNotEmpty);
      expect(
        messages,
        contains(contains('path=${sanitizeFsPath(saveResult!)}')),
      );
    }, variant: windows);

    testWidgets('Windows logs export log includes the sanitized path', (
      tester,
    ) async {
      saveResult = r'C:\tmp\app.log';
      final l = await pump(tester, android: false);
      await tester.tap(find.text(l.settingsLogsExport));
      await tester.pumpAndSettle();
      expect(
        messages,
        contains(contains('path=${sanitizeFsPath(saveResult!)}')),
      );
    }, variant: windows);

    testWidgets('Android logs export log includes the display name', (
      tester,
    ) async {
      saveResult = '/document/primary:Download/out.log';
      final l = await pump(tester, android: true);
      await tester.tap(find.text(l.settingsLogsExport));
      await tester.pumpAndSettle();
      expect(messages, contains(contains('name=out.log')));
    }, variant: android);
  });
}
