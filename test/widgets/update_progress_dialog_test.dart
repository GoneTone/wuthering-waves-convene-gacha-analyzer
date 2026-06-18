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
  group('UpdateProgressDialog — FetchingBanner 卡池本地化', () {
    testWidgets('gachaTypeCharacter（既有池）顯示本地化名稱，不顯示原始 key', (tester) async {
      await _pumpDialog(
        tester,
        progress: const FetchingBanner(
          displayName: 'gachaTypeCharacter',
          poolIndex: 1,
          poolCount: 10,
          newRecordsSoFar: 0,
        ),
      );

      // 驗證既有池重構後仍可正確本地化（ARB: "角色活動喚取"）
      expect(find.textContaining('角色活動喚取'), findsOneWidget);
      expect(find.textContaining('gachaTypeCharacter'), findsNothing);
    });

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

  group('UpdateProgressDialog — 物品資料完成摘要', () {
    testWidgets('itemDetailsRefreshed 非 null → 三行皆顯示，不顯示「新增筆數」', (
      tester,
    ) async {
      await _pumpDialog(
        tester,
        progress: UpdateCompleted(
          totalNewRecords: 0,
          failedBanners: const [],
          updatedAt: DateTime.utc(2026),
          itemImagesDownloaded: 3,
          itemDetailsRefreshed: 5,
          staleItemsPruned: 2,
        ),
      );
      expect(find.textContaining('已更新 5 個物品的資料'), findsOneWidget);
      expect(find.textContaining('補下載 3 張物品圖片'), findsOneWidget);
      expect(find.textContaining('已清理 2 個物品的殘留語言資料'), findsOneWidget);
      expect(find.textContaining('新增'), findsNothing);
    });

    testWidgets('補圖=0、清理=0 → 只顯示主行', (tester) async {
      await _pumpDialog(
        tester,
        progress: UpdateCompleted(
          totalNewRecords: 0,
          failedBanners: const [],
          updatedAt: DateTime.utc(2026),
          itemImagesDownloaded: 0,
          itemDetailsRefreshed: 4,
          staleItemsPruned: 0,
        ),
      );
      expect(find.textContaining('已更新 4 個物品的資料'), findsOneWidget);
      expect(find.textContaining('補下載'), findsNothing);
      expect(find.textContaining('殘留語言'), findsNothing);
    });
  });
}
