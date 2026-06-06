import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/gacha_item_detail_dialog.dart';

GachaRecord _charRecord() => GachaRecord(
  resourceId: 1211,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: '',
  name: '測試角色',
  count: 1,
  time: DateTime(2026, 1, 1),
  languageCode: 'zh-Hant',
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('luckdraw_chip_test_');
    await itemIconCacheFile(
      baseDir: tempDir,
      resourceId: 1211,
      url: 'https://x/i.webp',
    ).writeAsBytes([0]);
    await itemLuckdrawCacheFile(
      baseDir: tempDir,
      resourceId: 1211,
    ).writeAsBytes([0]);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> pump(WidgetTester tester, ItemImageEntry entry) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          itemImageCacheDirProvider.overrideWithValue(tempDir),
          itemImageIndexProvider.overrideWith(
            () => _StubIndexNotifier(ItemImageIndex(items: {1211: entry})),
          ),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: GachaItemDetailDialog(record: _charRecord()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('hasLuckdraw=true：出現「喚取」chip', (tester) async {
    // kind 必須設為 kItemKindCharacter，itemTypeKeyOf 才回 character。
    await pump(
      tester,
      const ItemImageEntry(
        iconUrl: 'https://x/i.webp',
        noImage: false,
        permanentNoImage: false,
        hasLuckdraw: true,
        kind: kItemKindCharacter,
      ),
    );
    expect(find.text('喚取'), findsOneWidget);
  });

  testWidgets('hasLuckdraw=false：不出現「喚取」chip', (tester) async {
    await pump(
      tester,
      const ItemImageEntry(
        iconUrl: 'https://x/i.webp',
        noImage: false,
        permanentNoImage: false,
      ),
    );
    expect(find.text('喚取'), findsNothing);
  });
}

/// 測試用：直接持有固定 index 的 notifier stub（不碰 storage）。
class _StubIndexNotifier extends ItemImageIndexNotifier {
  /// 建立 [_StubIndexNotifier]。
  _StubIndexNotifier(this._value);

  final ItemImageIndex _value;

  @override
  ItemImageIndex build() => _value;
}
