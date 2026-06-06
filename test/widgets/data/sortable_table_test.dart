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
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/data/sortable_table.dart';
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
}
