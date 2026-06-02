import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/five_star_collection.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/five_star_overview.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/gacha_item_detail_dialog.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/gacha_item_icon.dart';

GachaRecord _r(int resourceId, String name, DateTime time) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: '1',
  name: name,
  count: 1,
  time: time,
);

Future<ProviderContainer> _container(WidgetTester tester) async {
  late Directory tempDir;
  await tester.runAsync(() async {
    tempDir = await Directory.systemTemp.createTemp('five_star_overview_test_');
  });
  addTearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });
  final container = ProviderContainer(
    overrides: [
      itemImageIndexStorageProvider.overrideWithValue(
        ItemImageIndexStorage(tempDir),
      ),
      itemImageCacheDirProvider.overrideWithValue(tempDir),
    ],
  );
  addTearDown(container.dispose);
  await tester.runAsync(
    () => container.read(itemImageIndexProvider.notifier).waitForLoad(),
  );
  return container;
}

Widget _wrap(ProviderContainer c, Widget child) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(
    theme: buildDarkTheme(),
    home: Scaffold(body: SizedBox(width: 800, child: child)),
  ),
);

void main() {
  testWidgets('空清單 → SizedBox.shrink，不顯示任何 chip', (tester) async {
    final c = await _container(tester);
    await tester.pumpWidget(_wrap(c, const FiveStarOverview(items: [])));
    await tester.pump();
    expect(find.byType(GachaItemTapTarget), findsNothing);
    expect(find.byType(GachaItemIcon), findsNothing); // 空清單不繪任何 chip
  });

  testWidgets('顯示每個物品的次數徽章', (tester) async {
    final c = await _container(tester);
    final items = buildFiveStarCollection([
      _r(10, 'A', DateTime(2025, 1, 1)),
      _r(10, 'A', DateTime(2025, 1, 2)),
      _r(20, 'B', DateTime(2025, 1, 3)),
    ]);
    await tester.pumpWidget(_wrap(c, FiveStarOverview(items: items)));
    await tester.pump();
    expect(find.text('2'), findsOneWidget); // A 抽到 2 次
    expect(find.text('1'), findsOneWidget); // B 抽到 1 次
  });

  testWidgets('interactive=false → 不掛 GachaItemTapTarget', (tester) async {
    final c = await _container(tester);
    final items = buildFiveStarCollection([_r(10, 'A', DateTime(2025, 1, 1))]);
    await tester.pumpWidget(
      _wrap(c, FiveStarOverview(items: items, interactive: false)),
    );
    await tester.pump();
    expect(find.byType(GachaItemTapTarget), findsNothing);
  });

  testWidgets('interactive=true → 掛 GachaItemTapTarget', (tester) async {
    final c = await _container(tester);
    final items = buildFiveStarCollection([_r(10, 'A', DateTime(2025, 1, 1))]);
    await tester.pumpWidget(_wrap(c, FiveStarOverview(items: items)));
    await tester.pump();
    expect(find.byType(GachaItemTapTarget), findsOneWidget);
  });
}
