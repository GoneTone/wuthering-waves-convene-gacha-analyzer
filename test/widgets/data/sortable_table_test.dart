import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_filter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_row.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/data/pager.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/data/sortable_table.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/gacha_item_detail_dialog.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/gacha_item_icon.dart';

GachaRecord _r({required int seq, required int rank, required String name}) =>
    GachaRecord(
      resourceId: seq,
      qualityLevel: rank,
      resourceType: '角色',
      cardPoolType: '1',
      name: name,
      count: 1,
      time: DateTime(2025, 1, seq),
    );

/// 為一組 records 建立 index：全部 resourceType='角色' → kind:character。
ItemImageIndex _idxFor(List<GachaRecord> records) => ItemImageIndex(
  items: {
    for (final r in records)
      r.resourceId: const ItemImageEntry(
        iconUrl: 'u',
        noImage: false,
        permanentNoImage: false,
        kind: kItemKindCharacter,
      ),
  },
);

/// 建立含 [UncontrolledProviderScope] 的測試包裝 widget。
Widget _wrap(
  Widget child, {
  Locale locale = const Locale('zh'),
  required ProviderContainer container,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildDarkTheme(),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(child: SizedBox(width: 1200, child: child)),
    ),
  ),
);

/// 建立測試用 [ProviderContainer]，override 需要 main() 注入的 provider。
ProviderContainer _makeContainer(Directory tempDir) => ProviderContainer(
  overrides: [
    itemImageIndexStorageProvider.overrideWithValue(
      ItemImageIndexStorage(tempDir),
    ),
    itemImageCacheDirProvider.overrideWithValue(tempDir),
  ],
);

/// 以指定寬度包住 [child]（測試卡片列與表格的切換）；[textScale] 模擬系統字級。
Widget _wrapWidth(
  Widget child, {
  required double width,
  required ProviderContainer container,
  Locale locale = const Locale('zh'),
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildDarkTheme(),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  ),
);

void main() {
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sortable_table_test_');
    container = _makeContainer(tempDir);
  });

  tearDown(() async {
    container.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('ja locale → rank cell uses ★N order (pill + plain)', (
    tester,
  ) async {
    final records = [
      _r(seq: 5, rank: 5, name: 'A'), // accent != null → _Pill
      _r(seq: 4, rank: 4, name: 'B'), // accent != null → _Pill
      _r(seq: 3, rank: 3, name: 'C'), // accent == null → 純 Text 分支
    ];
    final rows = buildRecordRows(records, _idxFor(records));
    await tester.pumpWidget(
      _wrap(
        SortableTable(
          rows: rows,
          sort: null,
          mainRank: 5,
          onSortColumnTapped: (_) {},
        ),
        locale: const Locale('ja'),
        container: container,
      ),
    );
    expect(find.text('★5'), findsOneWidget);
    expect(find.text('★4'), findsOneWidget);
    expect(find.text('★3'), findsOneWidget);
    expect(find.text('5★'), findsNothing);
    expect(find.text('4★'), findsNothing);
    expect(find.text('3★'), findsNothing);
  });

  testWidgets('renders rows, rarity pills, totalIndex/pity columns', (
    tester,
  ) async {
    final records = [
      _r(seq: 5, rank: 5, name: 'A'),
      _r(seq: 4, rank: 4, name: 'B'),
      _r(seq: 3, rank: 3, name: 'C'),
    ];
    final rows = buildRecordRows(records, _idxFor(records));
    await tester.pumpWidget(
      _wrap(
        SortableTable(
          rows: rows,
          sort: null,
          mainRank: 5,
          onSortColumnTapped: (_) {},
        ),
        container: container,
      ),
    );
    expect(find.text('A'), findsOneWidget);
    expect(find.text('5★'), findsOneWidget);
    expect(find.text('4★'), findsOneWidget);
    // totalIndex 顯示（rows desc by time → id 5 是最新 → totalIndex=3）
    expect(find.text('3'), findsWidgets); // totalIndex of A
    expect(find.text('1'), findsWidgets); // totalIndex of C
  });

  testWidgets('保底內抽數以歐非色顯示、總抽數維持 muted', (tester) async {
    // A(5★) total=3/pity=3、B(4★) total=2/pity=2、C(3★) total=1/pity=1。
    final records = [
      _r(seq: 3, rank: 5, name: 'A'),
      _r(seq: 2, rank: 4, name: 'B'),
      _r(seq: 1, rank: 3, name: 'C'),
    ];
    final rows = buildRecordRows(records, _idxFor(records));
    await tester.pumpWidget(
      _wrap(
        SortableTable(
          rows: rows,
          sort: null,
          mainRank: 5,
          onSortColumnTapped: (_) {},
        ),
        container: container,
      ),
    );
    const t = GachaTokens.dark;
    // '1' 出現兩次（C 列）：總抽數欄 muted、保底內欄歐非綠（pity 1/80 → 歐）。
    final colors = tester
        .widgetList<Text>(find.text('1'))
        .map((w) => w.style?.color)
        .toList();
    expect(colors, contains(t.stateSuccess), reason: '保底內抽數應為歐非色');
    expect(colors, contains(t.textMuted), reason: '總抽數應維持 muted');
  });

  testWidgets('paginates with 20 per page (page button shows 1 / 3)', (
    tester,
  ) async {
    final records = List.generate(
      45,
      (i) => _r(seq: i + 1, rank: 4, name: 'r$i'),
    );
    final rows = buildRecordRows(records, _idxFor(records));
    await tester.pumpWidget(
      _wrap(
        SortableTable(
          rows: rows,
          sort: null,
          mainRank: 5,
          onSortColumnTapped: (_) {},
        ),
        container: container,
      ),
    );
    expect(find.byType(DropdownButton<int>), findsNothing);
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.text('r19'), findsOneWidget);
    expect(find.text('r20'), findsNothing);
  });

  testWidgets('jumping via the dialog fires onPageChanged', (tester) async {
    final records = List.generate(
      45,
      (i) => _r(seq: i + 1, rank: 4, name: 'r$i'),
    );
    final rows = buildRecordRows(records, _idxFor(records));
    final pages = <int>[];
    await tester.pumpWidget(
      _wrap(
        SortableTable(
          rows: rows,
          sort: null,
          mainRank: 5,
          onSortColumnTapped: (_) {},
          onPageChanged: pages.add,
        ),
        container: container,
      ),
    );
    await tester.ensureVisible(find.text('1 / 3'));
    await tester.tap(find.text('1 / 3'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '3');
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(pages, [2]);
    expect(find.text('3 / 3'), findsOneWidget);
  });

  testWidgets('page survives being scrolled out of a lazy list', (
    tester,
  ) async {
    final records = List.generate(
      45,
      (i) => _r(seq: i + 1, rank: 4, name: 'r$i'),
    );
    final rows = buildRecordRows(records, _idxFor(records));
    const listKey = Key('outer');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildDarkTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ListView(
              key: listKey,
              children: [
                SortableTable(
                  rows: rows,
                  sort: null,
                  mainRank: 5,
                  onSortColumnTapped: (_) {},
                ),
                const SizedBox(height: 5000),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.byIcon(Icons.chevron_right).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pumpAndSettle();
    expect(tester.widget<Pager>(find.byType(Pager)).page, 1);

    await tester.drag(find.byKey(listKey), const Offset(0, -6000));
    await tester.pumpAndSettle();
    expect(find.byType(Pager), findsNothing);
    await tester.drag(find.byKey(listKey), const Offset(0, 6000));
    await tester.pumpAndSettle();

    expect(tester.widget<Pager>(find.byType(Pager)).page, 1);
  });

  testWidgets('表頭點擊呼叫 onSortColumnTapped(對應欄)', (tester) async {
    final records = [_r(seq: 1, rank: 5, name: 'A')];
    final rows = buildRecordRows(records, _idxFor(records));
    SortColumn? tapped;
    await tester.pumpWidget(
      _wrap(
        SortableTable(
          rows: rows,
          sort: null,
          mainRank: 5,
          onSortColumnTapped: (c) => tapped = c,
        ),
        container: container,
      ),
    );
    await tester.tap(find.text('喚取時間'));
    expect(tapped, SortColumn.time);

    await tester.tap(find.text('名稱'));
    expect(tapped, SortColumn.name);

    await tester.tap(find.text('總抽數'));
    expect(tapped, SortColumn.totalIndex);

    await tester.tap(find.text('保底內'));
    expect(tapped, SortColumn.mainPity);
  });

  testWidgets('當前排序欄顯示 arrow_downward；其他欄維持 unfold_more', (tester) async {
    final records = [_r(seq: 1, rank: 5, name: 'A')];
    final rows = buildRecordRows(records, _idxFor(records));
    await tester.pumpWidget(
      _wrap(
        SortableTable(
          rows: rows,
          sort: const TableSort(
            column: SortColumn.rarity,
            direction: SortDirection.desc,
          ),
          mainRank: 5,
          onSortColumnTapped: (_) {},
        ),
        container: container,
      ),
    );
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    // 其餘 5 個欄位都顯示 unfold_more
    expect(find.byIcon(Icons.unfold_more), findsNWidgets(5));
  });

  testWidgets('類型欄顯示 itemTypeKeyLabel 結果（canonical kind 標籤）', (tester) async {
    // _r 產的 record.resourceType = '角色' → itemTypeKeyOf 映射 kind:character；
    // itemTypeKeyLabel('kind:character', l) 回傳本地化 '角色'。
    final records = [_r(seq: 1, rank: 5, name: 'A')];
    final rows = buildRecordRows(records, _idxFor(records));
    await tester.pumpWidget(
      _wrap(
        SortableTable(
          rows: rows,
          sort: null,
          mainRank: 5,
          onSortColumnTapped: (_) {},
        ),
        container: container,
      ),
    );
    // 類型欄應顯示 itemTypeKeyLabel(row.itemTypeKey='角色', l) = '角色'
    expect(find.text('角色'), findsOneWidget);
  });

  testWidgets('每列名稱欄前顯示 GachaItemIcon', (tester) async {
    final records = [
      _r(seq: 5, rank: 5, name: 'A'),
      _r(seq: 4, rank: 4, name: 'B'),
      _r(seq: 3, rank: 3, name: 'C'),
    ];
    final rows = buildRecordRows(records, _idxFor(records));
    await tester.pumpWidget(
      _wrap(
        SortableTable(
          rows: rows,
          sort: null,
          mainRank: 5,
          onSortColumnTapped: (_) {},
        ),
        container: container,
      ),
    );

    // 三筆 record → 三個 GachaItemIcon
    expect(find.byType(GachaItemIcon), findsNWidgets(3));
  });

  group('narrow layout', () {
    /// 45 筆紀錄（第 5、20 筆為 5★）。
    List<RecordRow> rows45() {
      final records = [
        for (var i = 45; i >= 1; i--)
          _r(seq: i, rank: i == 5 || i == 20 ? 5 : 3, name: 'N$i'),
      ];
      return buildRecordRows(records, _idxFor(records));
    }

    Future<AppLocalizations> pumpTable(
      WidgetTester tester, {
      required double width,
      TableSort? sort,
      ValueChanged<SortColumn>? onTap,
      Locale locale = const Locale('zh'),
      List<RecordRow>? rows,
    }) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrapWidth(
          SortableTable(
            rows: rows ?? rows45(),
            sort: sort,
            mainRank: 5,
            onSortColumnTapped: onTap ?? (_) {},
          ),
          width: width,
          container: container,
          locale: locale,
        ),
      );
      await tester.pumpAndSettle();
      return AppLocalizations.of(tester.element(find.byType(SortableTable)))!;
    }

    testWidgets('narrow width shows record cards instead of the table', (
      tester,
    ) async {
      final l = await pumpTable(tester, width: 360);
      expect(find.text(l.tableTotalIndex), findsNothing);
      expect(find.text('N45'), findsOneWidget);
      expect(find.textContaining('#45', findRichText: true), findsOneWidget);
      for (final card in tester.widgetList(find.byType(GachaItemTapTarget))) {
        expect(
          tester.getSize(find.byWidget(card)).height,
          greaterThanOrEqualTo(48),
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('record cards show the item type like the table', (
      tester,
    ) async {
      // 排序選單可以依類型排序，卡片上就要看得到類型（和桌面表格一致）。
      final l = await pumpTable(tester, width: 360);
      final card = find.ancestor(
        of: find.text('N45'),
        matching: find.byType(GachaItemTapTarget),
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text(itemTypeKeyLabel(kItemKindCharacter, l)),
        ),
        findsOneWidget,
      );
    });

    testWidgets('long press on a card explains the pity count', (tester) async {
      // 桌面表頭有保底說明，卡片沒有表頭，要在卡片上看得到。
      final l = await pumpTable(tester, width: 360);
      await tester.longPress(find.textContaining('#45', findRichText: true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text(l.tableMainPityTooltip(l.rarityStar(5))),
        findsOneWidget,
      );
    });

    testWidgets('wide width keeps the table', (tester) async {
      final l = await pumpTable(tester, width: 900);
      expect(find.text(l.tableTotalIndex), findsOneWidget);
    });

    testWidgets('sort sheet calls cycleSort with the tapped column', (
      tester,
    ) async {
      SortColumn? tapped;
      final l = await pumpTable(tester, width: 360, onTap: (c) => tapped = c);
      await tester.tap(find.text(l.tableSortDefault));
      await tester.pumpAndSettle();
      expect(find.text(l.tableSortSheetTitle), findsOneWidget);
      for (final label in [
        l.tableTime,
        l.tableName,
        l.tableKind,
        l.tableRarity,
        l.tableTotalIndex,
        l.tableMainPity,
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text(l.tableName));
      await tester.pumpAndSettle();
      expect(tapped, SortColumn.name);
      expect(find.text(l.tableSortSheetTitle), findsNothing);
    });

    testWidgets('sort sheet opens above the whole app, not the page', (
      tester,
    ) async {
      // 頁面在外殼的內層導覽器裡；開在內層會被外殼的底部狀態列蓋住。
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final inner = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Navigator(
                key: inner,
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: SingleChildScrollView(
                      child: SortableTable(
                        rows: rows45(),
                        sort: null,
                        mainRank: 5,
                        onSortColumnTapped: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(
        tester.element(find.byType(SortableTable)),
      )!;
      await tester.tap(find.text(l.tableSortDefault));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(inner),
          matching: find.byType(BottomSheet),
        ),
        findsNothing,
      );
    });

    testWidgets('sort button shows the current column and direction', (
      tester,
    ) async {
      final l = await pumpTable(
        tester,
        width: 360,
        sort: const TableSort(
          column: SortColumn.time,
          direction: SortDirection.desc,
        ),
      );
      expect(find.text(l.tableSortButton('${l.tableTime} ↓')), findsOneWidget);
    });

    testWidgets('tapping a card opens item detail', (tester) async {
      await pumpTable(tester, width: 360);
      expect(
        find.ancestor(
          of: find.text('N45'),
          matching: find.byType(GachaItemTapTarget),
        ),
        findsOneWidget,
      );
    });

    testWidgets('switching between cards and table keeps the page', (
      tester,
    ) async {
      final rows = rows45();
      await pumpTable(tester, width: 360, rows: rows);
      await tester.tap(find.byIcon(Icons.chevron_right).first);
      await tester.pumpAndSettle();
      expect(tester.widget<Pager>(find.byType(Pager)).page, 1);
      await tester.pumpWidget(
        _wrapWidth(
          SortableTable(
            rows: rows,
            sort: null,
            mainRank: 5,
            onSortColumnTapped: (_) {},
          ),
          width: 900,
          container: container,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Pager>(find.byType(Pager)).page, 1);
    });

    testWidgets('cards do not overflow with japanese and large text', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpTable(tester, width: 360, locale: const Locale('ja'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('cards do not overflow with english and large text', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpTable(tester, width: 360, locale: const Locale('en'));
      expect(tester.takeException(), isNull);
    });
  });

  group('record list cards and page change', () {
    /// 回傳 [recordListUsesCards] 在目前視窗與 [width] 下的結果。
    Future<bool> usesCards(WidgetTester tester, Size view, double width) async {
      tester.view.physicalSize = view;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late bool result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              result = recordListUsesCards(context, width);
              return const SizedBox();
            },
          ),
        ),
      );
      return result;
    }

    testWidgets('phone landscape uses cards even when wide', (tester) async {
      expect(await usesCards(tester, const Size(800, 360), 776), isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('desktop wide window keeps the table', (tester) async {
      expect(await usesCards(tester, const Size(1200, 800), 900), isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('desktop narrow width uses cards', (tester) async {
      expect(await usesCards(tester, const Size(1200, 800), 500), isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    /// 45 筆紀錄分 3 頁的表格；[onPageChanged] 收換頁通知。
    Future<void> pumpPaged(
      WidgetTester tester, {
      ValueChanged<int>? onPageChanged,
      bool showSortButton = true,
    }) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final records = [
        for (var i = 45; i >= 1; i--) _r(seq: i, rank: 3, name: 'N$i'),
      ];
      await tester.pumpWidget(
        _wrapWidth(
          SortableTable(
            rows: buildRecordRows(records, _idxFor(records)),
            sort: null,
            mainRank: 5,
            onSortColumnTapped: (_) {},
            showSortButton: showSortButton,
            onPageChanged: onPageChanged,
          ),
          width: 360,
          container: container,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('onPageChanged receives the new page', (tester) async {
      final pages = <int>[];
      await pumpPaged(tester, onPageChanged: pages.add);
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.last_page));
      await tester.pumpAndSettle();
      expect(pages, [1, 2]);
    });

    testWidgets('onPageChanged is silent when the page stays the same', (
      tester,
    ) async {
      final pages = <int>[];
      await pumpPaged(tester, onPageChanged: pages.add);
      await tester.tap(find.byIcon(Icons.first_page), warnIfMissed: false);
      await tester.ensureVisible(find.text('1 / 3'));
      await tester.tap(find.text('1 / 3'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(pages, isEmpty);
    });

    testWidgets('showSortButton false hides the sort button', (tester) async {
      await pumpPaged(tester, showSortButton: false);
      expect(find.byType(RecordSortButton), findsNothing);
    });

    testWidgets('showSortButton defaults to showing it in card mode', (
      tester,
    ) async {
      await pumpPaged(tester);
      expect(find.byType(RecordSortButton), findsOneWidget);
    });
  });

  group('mid-list ad slot', () {
    const adKey = Key('mid-ad');

    /// 卡片外框容器（圓角邊框的 Container）。
    final cardFrames = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).border != null &&
          (w.decoration! as BoxDecoration).borderRadius ==
              BorderRadius.circular(AppRadius.md),
    );

    /// 以 [count] 筆紀錄（名稱 R0..）建立表格；[width] 決定卡片或表格模式。
    Future<void> pumpAd(
      WidgetTester tester, {
      required int count,
      Widget? ad = const SizedBox(key: adKey, height: 50),
      double width = 360,
    }) async {
      tester.view.physicalSize = const Size(1200, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final records = [
        for (var i = count; i >= 1; i--) _r(seq: i, rank: 3, name: 'R$i'),
      ];
      await tester.pumpWidget(
        _wrapWidth(
          SortableTable(
            rows: buildRecordRows(records, _idxFor(records)),
            sort: null,
            mainRank: 5,
            onSortColumnTapped: (_) {},
            midListAd: ad,
          ),
          width: width,
          container: container,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('11 rows: ad is a row between row 10 and 11 in one frame', (
      tester,
    ) async {
      await pumpAd(tester, count: 11);
      final ad = find.byKey(adKey);
      expect(ad, findsOneWidget);
      // 不切開列表：整份列表仍是同一個外框，廣告上下各一條分隔線、留 m 內距。
      expect(cardFrames, findsOneWidget);
      final dividers = find.byType(Divider);
      expect(dividers, findsNWidgets(2));
      expect(
        tester.getTopLeft(ad).dy - tester.getBottomLeft(dividers.first).dy,
        AppSpacing.m,
      );
      expect(
        tester.getTopLeft(dividers.last).dy - tester.getBottomLeft(ad).dy,
        AppSpacing.m,
      );
      // 第 10 筆（R2）在廣告之上、第 11 筆（R1）在廣告之下。
      expect(
        tester.getBottomLeft(find.text('R2')).dy,
        lessThan(tester.getTopLeft(ad).dy),
      );
      expect(
        tester.getTopLeft(find.text('R1')).dy,
        greaterThan(tester.getBottomLeft(ad).dy),
      );
    });

    testWidgets('10 rows: no ad, single frame', (tester) async {
      await pumpAd(tester, count: 10);
      expect(find.byKey(adKey), findsNothing);
      expect(cardFrames, findsOneWidget);
    });

    testWidgets('null ad with 20 rows keeps a single frame', (tester) async {
      await pumpAd(tester, count: 20, ad: null);
      expect(cardFrames, findsOneWidget);
    });

    testWidgets('table mode ignores the ad', (tester) async {
      await pumpAd(tester, count: 15, width: 1200);
      expect(find.byKey(adKey), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('hidden on a short last page, back on page 1', (tester) async {
      await pumpAd(tester, count: 25);
      expect(find.byKey(adKey), findsOneWidget);
      await tester.tap(find.byIcon(Icons.last_page));
      await tester.pumpAndSettle();
      expect(find.byKey(adKey), findsNothing);
      await tester.tap(find.byIcon(Icons.first_page));
      await tester.pumpAndSettle();
      expect(find.byKey(adKey), findsOneWidget);
    });
  });
}
