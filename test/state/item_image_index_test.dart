import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';

void main() {
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('item_image_state_test_');
    container = ProviderContainer(
      overrides: [
        itemImageIndexStorageProvider.overrideWithValue(
          ItemImageIndexStorage(tempDir),
        ),
        itemImageCacheDirProvider.overrideWithValue(tempDir),
      ],
    );
    addTearDown(container.dispose);
    await container.read(itemImageIndexProvider.notifier).waitForLoad();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('初始為空 index', () {
    expect(container.read(itemImageIndexProvider).items, isEmpty);
  });

  test('bumpCacheRevision 換新 identity 但內容不變', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await notifier.mergeIcon(
      resourceId: 1211,
      iconUrl: 'https://x/card.png',
      noImage: false,
      permanentNoImage: false,
    );
    final before = container.read(itemImageIndexProvider);
    notifier.bumpCacheRevision();
    final after = container.read(itemImageIndexProvider);
    expect(identical(before, after), isFalse);
    expect(after.items, before.items);
  });

  test('並發 mergeIcon 全部寫入不丟失', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await Future.wait(
      List.generate(
        10,
        (i) => notifier.mergeIcon(
          resourceId: i,
          iconUrl: 'https://x/$i.png',
          noImage: false,
          permanentNoImage: false,
        ),
      ),
    );
    final state = container.read(itemImageIndexProvider);
    expect(state.items.length, 10);
    for (var i = 0; i < 10; i++) {
      expect(state.lookupImage(i)!.iconUrl, 'https://x/$i.png');
    }
  });

  test('mergeItemDetail 寫入 detailByLang，不動 icon', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await notifier.mergeIcon(
      resourceId: 1503,
      iconUrl: 'https://x/role.webp',
      noImage: false,
      permanentNoImage: false,
    );
    await notifier.mergeItemDetail(
      resourceId: 1503,
      lang: 'zh-Hant',
      detail: const ItemDetailL10n(
        intro: '簡介',
        elementName: '衍射',
        weaponTypeName: '音感儀',
        skins: [],
      ),
    );
    final e = container.read(itemImageIndexProvider).lookupImage(1503)!;
    expect(e.iconUrl, 'https://x/role.webp');
    expect(e.detailByLang['zh-Hant']!.intro, '簡介');
  });

  test('負取：mergeIcon noImage=true 寫入後 entry 標記負取', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await notifier.mergeIcon(
      resourceId: 21010024,
      iconUrl: null,
      noImage: true,
      permanentNoImage: false,
    );
    final e = container.read(itemImageIndexProvider).lookupImage(21010024)!;
    expect(e.noImage, isTrue);
    expect(e.permanentNoImage, isFalse);
    expect(e.hasIcon, isFalse);

    // 確認持久化：reload 後仍為負取
    final reloaded = await ItemImageIndexStorage(tempDir).load();
    final persisted = reloaded.lookupImage(21010024)!;
    expect(persisted.noImage, isTrue);
    expect(persisted.permanentNoImage, isFalse);
  });

  test('永久負取：mergeIcon permanentNoImage=true 寫入後標記永久負取', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await notifier.mergeIcon(
      resourceId: 21040084,
      iconUrl: null,
      noImage: true,
      permanentNoImage: true,
    );
    final e = container.read(itemImageIndexProvider).lookupImage(21040084)!;
    expect(e.permanentNoImage, isTrue);

    // 確認持久化
    final reloaded = await ItemImageIndexStorage(tempDir).load();
    expect(reloaded.lookupImage(21040084)!.permanentNoImage, isTrue);
  });

  test('由負取覆蓋為正取：第二次 mergeIcon 帶 iconUrl 後 hasIcon=true', () async {
    const rid = 21010024;
    final notifier = container.read(itemImageIndexProvider.notifier);

    // 第一次：負取
    await notifier.mergeIcon(
      resourceId: rid,
      iconUrl: null,
      noImage: true,
      permanentNoImage: false,
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(rid)!.noImage,
      isTrue,
    );

    // 第二次：官方後補圖，覆蓋為正取
    await notifier.mergeIcon(
      resourceId: rid,
      iconUrl: 'https://x/card.png',
      noImage: false,
      permanentNoImage: false,
    );
    final e = container.read(itemImageIndexProvider).lookupImage(rid)!;
    expect(e.noImage, isFalse);
    expect(e.hasIcon, isTrue);

    // 確認持久化
    final reloaded = await ItemImageIndexStorage(tempDir).load();
    final persisted = reloaded.lookupImage(rid)!;
    expect(persisted.noImage, isFalse);
    expect(persisted.hasIcon, isTrue);
  });

  test('mergeItemDetail 跨 lang 不互蓋', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await notifier.mergeItemDetail(
      resourceId: 1503,
      lang: 'zh-Hant',
      detail: const ItemDetailL10n(
        intro: 'A',
        elementName: '',
        weaponTypeName: '',
        skins: [],
      ),
    );
    await notifier.mergeItemDetail(
      resourceId: 1503,
      lang: 'en',
      detail: const ItemDetailL10n(
        intro: 'B',
        elementName: '',
        weaponTypeName: '',
        skins: [],
      ),
    );
    final e = container.read(itemImageIndexProvider).lookupImage(1503)!;
    expect(e.detailByLang['zh-Hant']!.intro, 'A');
    expect(e.detailByLang['en']!.intro, 'B');
  });

  test('mergeIcon 寫入 kind；mergeItemDetail 不覆蓋 kind', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await notifier.mergeIcon(
      resourceId: 1211,
      iconUrl: 'u',
      noImage: false,
      permanentNoImage: false,
      kind: 'kind:character',
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(1211)!.kind,
      'kind:character',
    );
    await notifier.mergeItemDetail(
      resourceId: 1211,
      lang: 'zh-Hant',
      detail: const ItemDetailL10n(
        intro: 'i',
        elementName: '',
        weaponTypeName: '',
        skins: [],
      ),
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(1211)!.kind,
      'kind:character',
    );
  });

  test('mergeIcon 不帶 kind 時保留既有 kind', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await notifier.mergeIcon(
      resourceId: 1211,
      iconUrl: 'u',
      noImage: false,
      permanentNoImage: false,
      kind: 'kind:character',
    );
    await notifier.mergeIcon(
      resourceId: 1211,
      iconUrl: 'u2',
      noImage: false,
      permanentNoImage: false,
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(1211)!.kind,
      'kind:character',
    );
  });

  group('resetAll', () {
    test('清空 index + 刪 cache 目錄 + state identity 換新', () async {
      final dir = await Directory.systemTemp.createTemp('item_image_reset_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final storage = ItemImageIndexStorage(dir);
      await storage.save(
        const ItemImageIndex(
          items: {
            1211: ItemImageEntry(
              iconUrl: 'https://x/card.png',
              noImage: false,
              permanentNoImage: false,
            ),
          },
        ),
      );
      await File('${dir.path}/1211_icon.png').writeAsBytes([1, 2, 3]);

      final c = ProviderContainer(
        overrides: [
          itemImageIndexStorageProvider.overrideWithValue(storage),
          itemImageCacheDirProvider.overrideWithValue(dir),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(itemImageIndexProvider.notifier);
      await n.waitForLoad();
      expect(c.read(itemImageIndexProvider).items, isNotEmpty);

      await n.resetAll();

      expect(c.read(itemImageIndexProvider).items, isEmpty);
      expect(File('${dir.path}/1211_icon.png').existsSync(), isFalse);
    });
  });

  group('pruneLanguages', () {
    test('移除不在 keepLangs 的語言詳情，保留當前語言與 icon/kind', () async {
      final notifier = container.read(itemImageIndexProvider.notifier);
      await notifier.mergeIcon(
        resourceId: 1503,
        iconUrl: 'https://x/role.webp',
        noImage: false,
        permanentNoImage: false,
        kind: 'kind:character',
      );
      await notifier.mergeItemDetail(
        resourceId: 1503,
        lang: 'zh-Hant',
        detail: const ItemDetailL10n(
          intro: 'A',
          elementName: '',
          weaponTypeName: '',
          skins: [],
        ),
      );
      await notifier.mergeItemDetail(
        resourceId: 1503,
        lang: 'en',
        detail: const ItemDetailL10n(
          intro: 'B',
          elementName: '',
          weaponTypeName: '',
          skins: [],
        ),
      );

      final pruned = await notifier.pruneLanguages({'zh-Hant'});

      final e = container.read(itemImageIndexProvider).lookupImage(1503)!;
      expect(pruned, 1);
      expect(e.detailByLang.keys.toSet(), {'zh-Hant'});
      expect(e.iconUrl, 'https://x/role.webp');
      expect(e.kind, 'kind:character');
    });

    test('空 keepLangs 直接回 0 且不動資料（防呆）', () async {
      final notifier = container.read(itemImageIndexProvider.notifier);
      await notifier.mergeItemDetail(
        resourceId: 1503,
        lang: 'en',
        detail: const ItemDetailL10n(
          intro: 'B',
          elementName: '',
          weaponTypeName: '',
          skins: [],
        ),
      );
      final pruned = await notifier.pruneLanguages(<String>{});
      expect(pruned, 0);
      expect(
        container
            .read(itemImageIndexProvider)
            .lookupImage(1503)!
            .detailByLang
            .keys,
        contains('en'),
      );
    });

    test('無殘留語言時回 0、state identity 不變（不重建）', () async {
      final notifier = container.read(itemImageIndexProvider.notifier);
      await notifier.mergeItemDetail(
        resourceId: 1503,
        lang: 'zh-Hant',
        detail: const ItemDetailL10n(
          intro: 'A',
          elementName: '',
          weaponTypeName: '',
          skins: [],
        ),
      );
      final before = container.read(itemImageIndexProvider);
      final pruned = await notifier.pruneLanguages({'zh-Hant'});
      expect(pruned, 0);
      expect(identical(container.read(itemImageIndexProvider), before), isTrue);
    });
  });
}
