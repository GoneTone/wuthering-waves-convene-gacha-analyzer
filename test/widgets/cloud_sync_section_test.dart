import 'dart:async';
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

  Widget wrap({GoogleAuthService? auth, VoidCallback? onForeground}) =>
      ProviderScope(
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
          windowForegroundProvider.overrideWithValue(() async {
            onForeground?.call();
          }),
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

  testWidgets('連結時傳入依 UI 語言在地化的授權完成頁', (tester) async {
    final auth = FakeAuthService(InMemoryTokenStore())
      ..signInThrowsScopeMissing = true;
    await tester.pumpWidget(wrap(auth: auth));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Link Google account'));
    await tester.pumpAndSettle();

    final page = auth.lastPostAuthPage;
    expect(page, isNotNull);
    expect(page, contains('Authorization complete'));
    expect(page, contains('You can close this tab and return to the app.'));
    expect(page, contains('lang="en"'));
  });

  testWidgets('授權等待結束 → 自動把視窗帶回前景', (tester) async {
    var foregroundCalls = 0;
    final auth = FakeAuthService(InMemoryTokenStore())
      ..signInThrowsScopeMissing = true;
    await tester.pumpWidget(
      wrap(auth: auth, onForeground: () => foregroundCalls++),
    );
    await tester.pumpAndSettle();
    expect(foregroundCalls, 0);

    await tester.tap(find.text('Link Google account'));
    await tester.pumpAndSettle();

    expect(foregroundCalls, 1);
  });

  testWidgets('已連結（授權失效）重連 → 顯示等待授權列與取消', (tester) async {
    SharedPreferences.setMockInitialValues({
      'pref.cloudAccountEmail': 'u@example.com',
    });
    final store = InMemoryTokenStore()..token = 'refresh-0';
    final auth = _GatedSignInAuthService(store)..restoreThrowsReauth = true;
    await tester.pumpWidget(wrap(auth: auth));
    await tester.pumpAndSettle();

    // restore 拋 invalid_grant → reauthRequired → 出現重連按鈕。
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();
    expect(find.text('Link Google account'), findsOneWidget);

    // 按重連 → 等待授權期間應顯示 spinner 提示與取消（M1）。
    await tester.tap(find.text('Link Google account'));
    await tester.pump();
    expect(
      find.textContaining('finish authorization in your browser'),
      findsOneWidget,
    );
    expect(find.text('Cancel'), findsOneWidget);

    // 收尾：取消等待並讓被閘住的 signIn 以例外收場（結果會被世代檢查拋棄）。
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    auth.gate.completeError(const CloudScopeMissingException());
    await tester.pumpAndSettle();
  });
}

/// signIn 卡在 [gate] 上的 fake，用來讓 widget 測試停留在等待授權狀態。
class _GatedSignInAuthService extends FakeAuthService {
  /// 建立 [_GatedSignInAuthService]。
  _GatedSignInAuthService(super.store);

  /// signIn 的完成閘門。
  final gate = Completer<CloudAuthSession>();

  @override
  Future<CloudAuthSession> signIn(
    void Function(String url) openUrl, {
    String? postAuthPage,
  }) {
    openUrl('https://accounts.google.com/consent');
    return gate.future;
  }
}
