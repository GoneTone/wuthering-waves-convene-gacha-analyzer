import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_auth_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/cloud_sync.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/cloud_sync_section.dart';

import '../helpers/cloud_sync_fakes.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cloud_section_test_');
    SharedPreferences.setMockInitialValues({});
    debugCloudSyncConfiguredOverride = true;
  });

  tearDown(() async {
    debugCloudSyncConfiguredOverride = null;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget wrap({GoogleAuthService? auth}) => ProviderScope(
    overrides: [
      appVersionProvider.overrideWithValue('1.5.0'),
      gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
      gachaCaptureProvider.overrideWithValue(FakeCapture()),
      cancellableHttpClientFactoryProvider.overrideWithValue(
        () => CancellableHttpClient(
          client: MockClient((_) async => http.Response('', 500)),
          cancel: () {},
        ),
      ),
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      if (auth != null) googleAuthServiceProvider.overrideWithValue(auth),
      cloudSyncRemoteFactoryProvider.overrideWithValue((_) => FakeRemote()),
      cloudSyncUrlOpenerProvider.overrideWithValue((_) {}),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: buildDarkTheme(),
      home: const Scaffold(
        body: SingleChildScrollView(child: CloudSyncSection()),
      ),
    ),
  );

  testWidgets('未連結：顯示說明與連結按鈕', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Link Google account'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
  });

  testWidgets('已連結：顯示 email、開關、立即同步與中斷連結', (tester) async {
    SharedPreferences.setMockInitialValues({
      'pref.cloudAccountEmail': 'u@example.com',
    });
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.textContaining('u@example.com'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.text('Unlink'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('連結時漏勾 Drive 權限 → 顯示 scope 缺失指引訊息', (tester) async {
    final auth = FakeAuthService(InMemoryTokenStore())
      ..signInThrowsScopeMissing = true;
    await tester.pumpWidget(wrap(auth: auth));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Link Google account'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('did not include Google Drive access'),
      findsOneWidget,
    );
  });
}
