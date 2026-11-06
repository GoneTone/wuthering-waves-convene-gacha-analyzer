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

  testWidgets('paginates with 20 per page (always shows dropdown)', (
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
    final dropdown = tester.widget<DropdownButton<int>>(
      find.byType(DropdownButton<int>),
    );
    expect(dropdown.items, hasLength(3));
    expect(dropdown.value, 0);
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
    await tester.tap(find.text('時間'));
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
      expect(find.text('#45'), findsOneWidget);
      for (final card in tester.widgetList(find.byType(GachaItemTapTarget))) {
        expect(
          tester.getSize(find.byWidget(card)).height,
          greaterThanOrEqualTo(48),
        );
      }
      expect(tester.takeException(), isNull);
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

    testWidgets('cards do not overflow with english and large text', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpTable(tester, width: 360, locale: const Locale('en'));
      expect(tester.takeException(), isNull);
    });
  });
}
