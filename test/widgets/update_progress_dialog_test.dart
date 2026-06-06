import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/update_progress_dialog.dart';

/// [GachaRepository] 測試替身：覆寫 [build] 傳回固定 [GachaState]，
/// 不執行任何真實 bootstrap 或 I/O。
class _FakeGachaRepository extends GachaRepository {
  _FakeGachaRepository(this._progress);

  final UpdateProgress? _progress;

  @override
  GachaState build() => GachaState(progress: _progress, isBootstrapping: false);

  @override
  void cancelPreparing() {}

  @override
  Future<void> cancelCapture() async {}

  @override
  void clearProgress() {}
}

/// 以指定進度狀態 pump [UpdateProgressDialog]，並用 locale zh-Hant 顯示。
Future<void> _pumpDialog(
  WidgetTester tester, {
  required UpdateProgress progress,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        gachaRepositoryProvider.overrideWith(
          () => _FakeGachaRepository(progress),
        ),
      ],
      child: MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'Hant'),
        home: const Scaffold(body: Center(child: UpdateProgressDialog())),
      ),
    ),
  );
  // pump(duration) 代替 pumpAndSettle：LinearProgressIndicator 是無限動畫，
  // pumpAndSettle 會 timeout；固定幀推進足以讓 i18n 載入完成。
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('UpdateProgressDialog — FetchingBanner collab 卡池本地化', () {
    testWidgets('gachaTypeCollabCharacter 顯示本地化名稱，不顯示原始 key', (tester) async {
      await _pumpDialog(
        tester,
        progress: const FetchingBanner(
          displayName: 'gachaTypeCollabCharacter',
          poolIndex: 9,
          poolCount: 10,
          newRecordsSoFar: 0,
        ),
      );

      // progressFetchingBanner ARB = "正在抓取：{name}"，故用 textContaining
      expect(find.textContaining('角色聯動喚取'), findsOneWidget);
      expect(find.textContaining('gachaTypeCollabCharacter'), findsNothing);
    });

    testWidgets('gachaTypeCollabWeapon 顯示本地化名稱，不顯示原始 key', (tester) async {
      await _pumpDialog(
        tester,
        progress: const FetchingBanner(
          displayName: 'gachaTypeCollabWeapon',
          poolIndex: 10,
          poolCount: 10,
          newRecordsSoFar: 0,
        ),
      );

      expect(find.textContaining('武器聯動喚取'), findsOneWidget);
      expect(find.textContaining('gachaTypeCollabWeapon'), findsNothing);
    });
  });
}
