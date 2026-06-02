import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';

void main() {
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('luckdraw_merge_test_');
    container = ProviderContainer(
      overrides: [
        itemImageIndexStorageProvider.overrideWithValue(
          ItemImageIndexStorage(tempDir),
        ),
      ],
    );
    await container.read(itemImageIndexProvider.notifier).waitForLoad();
  });

  tearDown(() async {
    container.dispose();
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('mergeItemDetail 寫入 hasLuckdraw；mergeIcon 之後仍保留', () async {
    final n = container.read(itemImageIndexProvider.notifier);
    await n.mergeItemDetail(
      resourceId: 1211,
      lang: 'zh-Hant',
      detail: const ItemDetailL10n(
        intro: 'x',
        elementName: '',
        weaponTypeName: '',
        skins: [],
      ),
      hasLuckdraw: true,
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(1211)!.hasLuckdraw,
      isTrue,
    );

    await n.mergeIcon(
      resourceId: 1211,
      iconUrl: 'https://x/i.webp',
      noImage: false,
      permanentNoImage: false,
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(1211)!.hasLuckdraw,
      isTrue,
    );
  });

  test('mergeIcon 不把未評估 (null) 寫成 false', () async {
    final n = container.read(itemImageIndexProvider.notifier);
    await n.mergeIcon(
      resourceId: 7,
      iconUrl: 'https://x/i.webp',
      noImage: false,
      permanentNoImage: false,
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(7)!.hasLuckdraw,
      isNull,
    );
  });

  test('mergeItemDetail(false) 把未評估寫成已評估 false', () async {
    final n = container.read(itemImageIndexProvider.notifier);
    await n.mergeItemDetail(
      resourceId: 8,
      lang: 'zh-Hant',
      detail: const ItemDetailL10n(
        intro: '',
        elementName: '',
        weaponTypeName: '',
        skins: [],
      ),
      hasLuckdraw: false,
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(8)!.hasLuckdraw,
      isFalse,
    );
  });

  test('hasLuckdraw once-true-stays-true：先 true 後 false 仍 true', () async {
    final n = container.read(itemImageIndexProvider.notifier);
    await n.mergeItemDetail(
      resourceId: 9,
      lang: 'en',
      detail: const ItemDetailL10n(
        intro: '',
        elementName: '',
        weaponTypeName: '',
        skins: [],
      ),
      hasLuckdraw: true,
    );
    await n.mergeItemDetail(
      resourceId: 9,
      lang: 'zh-Hant',
      detail: const ItemDetailL10n(
        intro: '',
        elementName: '',
        weaponTypeName: '',
        skins: [],
      ),
      hasLuckdraw: false,
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(9)!.hasLuckdraw,
      isTrue,
    );
  });
}
