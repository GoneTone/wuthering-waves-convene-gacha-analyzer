import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';

void main() {
  group('ItemImageIndex.lookupImage', () {
    test('命中回 entry', () {
      const entry = ItemImageEntry(
        iconUrl: 'https://x/card.png',
        noImage: false,
        permanentNoImage: false,
      );
      final index = ItemImageIndex(items: const {1211: entry});
      expect(index.lookupImage(1211), entry);
    });

    test('未命中回 null', () {
      const index = ItemImageIndex.empty();
      expect(index.lookupImage(1211), isNull);
    });

    test('負取 entry 也能查到（noImage=true）', () {
      const index = ItemImageIndex(
        items: {
          21010024: ItemImageEntry(
            iconUrl: null,
            noImage: true,
            permanentNoImage: false,
          ),
        },
      );
      final e = index.lookupImage(21010024)!;
      expect(e.noImage, isTrue);
      expect(e.iconUrl, isNull);
    });
  });

  group('ItemImageEntry.hasIcon', () {
    test('正取（iconUrl 非空、非負取）→ true', () {
      const e = ItemImageEntry(
        iconUrl: 'https://x/card.png',
        noImage: false,
        permanentNoImage: false,
      );
      expect(e.hasIcon, isTrue);
    });

    test('負取 → false', () {
      const e = ItemImageEntry(
        iconUrl: null,
        noImage: true,
        permanentNoImage: false,
      );
      expect(e.hasIcon, isFalse);
    });

    test('iconUrl 為空字串 → false', () {
      const e = ItemImageEntry(
        iconUrl: '',
        noImage: false,
        permanentNoImage: false,
      );
      expect(e.hasIcon, isFalse);
    });
  });

  group('ItemImageIndexStorage', () {
    late Directory tempDir;
    late ItemImageIndexStorage storage;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('item_image_index_test_');
      storage = ItemImageIndexStorage(tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('load 缺檔回空 index', () async {
      final index = await storage.load();
      expect(index.items, isEmpty);
    });

    test('save → load roundtrip（正取）', () async {
      final original = ItemImageIndex(
        items: const {
          1211: ItemImageEntry(
            iconUrl: 'https://x/card.png',
            noImage: false,
            permanentNoImage: false,
          ),
        },
      );
      await storage.save(original);
      final loaded = await storage.load();
      final e = loaded.lookupImage(1211)!;
      expect(e.iconUrl, 'https://x/card.png');
      expect(e.noImage, isFalse);
      expect(e.permanentNoImage, isFalse);
    });

    test('save → load roundtrip（負取 + 永久負取）', () async {
      final original = ItemImageIndex(
        items: const {
          21010024: ItemImageEntry(
            iconUrl: null,
            noImage: true,
            permanentNoImage: false,
          ),
          21040084: ItemImageEntry(
            iconUrl: null,
            noImage: true,
            permanentNoImage: true,
          ),
        },
      );
      await storage.save(original);
      final loaded = await storage.load();
      expect(loaded.lookupImage(21010024)!.permanentNoImage, isFalse);
      expect(loaded.lookupImage(21040084)!.permanentNoImage, isTrue);
      expect(loaded.lookupImage(21010024)!.noImage, isTrue);
    });

    test('atomic write 不留 .tmp 殘檔', () async {
      await storage.save(const ItemImageIndex.empty());
      final tmp = File('${tempDir.path}/item_image_index.json.tmp');
      expect(await tmp.exists(), isFalse);
    });

    test('save 兩次 → 後者覆蓋', () async {
      await storage.save(
        const ItemImageIndex(
          items: {
            1: ItemImageEntry(
              iconUrl: 'a',
              noImage: false,
              permanentNoImage: false,
            ),
          },
        ),
      );
      await storage.save(
        const ItemImageIndex(
          items: {
            2: ItemImageEntry(
              iconUrl: 'b',
              noImage: false,
              permanentNoImage: false,
            ),
          },
        ),
      );
      final loaded = await storage.load();
      expect(loaded.lookupImage(1), isNull);
      expect(loaded.lookupImage(2)!.iconUrl, 'b');
    });

    test('解析失敗回空 index（不 throw）', () async {
      final f = File('${tempDir.path}/item_image_index.json');
      await f.writeAsString('{not json');
      final loaded = await storage.load();
      expect(loaded.items, isEmpty);
    });

    test('JSON key 為 resource_id 字串，可正確解析回 int', () async {
      final f = File('${tempDir.path}/item_image_index.json');
      await f.writeAsString(
        jsonEncode({
          'version': 1,
          'items': {
            '1211': {
              'icon_url': 'https://x/card.png',
              'illustration_url': 'https://x/illust.png',
              'no_image': false,
              'permanent_no_image': false,
            },
          },
        }),
      );
      final loaded = await storage.load();
      expect(loaded.lookupImage(1211)!.iconUrl, 'https://x/card.png');
    });

    test('clearAll → 空 index', () async {
      await storage.save(
        const ItemImageIndex(
          items: {
            1211: ItemImageEntry(
              iconUrl: 'a',
              noImage: false,
              permanentNoImage: false,
            ),
          },
        ),
      );
      await storage.clearAll();
      final loaded = await storage.load();
      expect(loaded.items, isEmpty);
    });

    test('wipeCacheDirectory 刪光圖檔並重建目錄', () async {
      await File('${tempDir.path}/1211_icon.png').writeAsBytes([1, 2, 3]);
      await File(
        '${tempDir.path}/1211_illustration.png',
      ).writeAsBytes([4, 5, 6]);
      await storage.wipeCacheDirectory();
      expect(await tempDir.exists(), isTrue);
      final remaining = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .toList();
      expect(remaining, isEmpty);
    });

    test('wipeCacheDirectory 目錄不存在時建空目錄', () async {
      final parent = await Directory.systemTemp.createTemp('item_image_wipe_');
      addTearDown(() async {
        if (await parent.exists()) await parent.delete(recursive: true);
      });
      final dir = Directory('${parent.path}/missing');
      expect(await dir.exists(), isFalse);
      final s = ItemImageIndexStorage(dir);
      await s.wipeCacheDirectory();
      expect(await dir.exists(), isTrue);
      expect(dir.listSync(), isEmpty);
    });

    test('deleteIllustrationCacheFiles 只刪立繪、保留 icon、回傳刪除數', () async {
      await File('${tempDir.path}/1211_icon.png').writeAsBytes([1, 2, 3]);
      await File(
        '${tempDir.path}/1211_illustration.png',
      ).writeAsBytes([4, 5, 6]);
      await File(
        '${tempDir.path}/21010024_illustration.jpg',
      ).writeAsBytes([7, 8, 9]);

      final removed = await storage.deleteIllustrationCacheFiles();

      expect(removed, 2);
      expect(
        File('${tempDir.path}/1211_illustration.png').existsSync(),
        isFalse,
      );
      expect(
        File('${tempDir.path}/21010024_illustration.jpg').existsSync(),
        isFalse,
      );
      expect(File('${tempDir.path}/1211_icon.png').existsSync(), isTrue);
    });

    test('deleteIllustrationCacheFiles 一併刪除 _luckdraw.png', () async {
      await itemIllustrationCacheFile(
        baseDir: tempDir,
        resourceId: 1,
        url: 'https://x/a.webp',
      ).writeAsBytes([0]);
      await itemLuckdrawCacheFile(
        baseDir: tempDir,
        resourceId: 1,
      ).writeAsBytes([0]);
      await itemIconCacheFile(
        baseDir: tempDir,
        resourceId: 1,
        url: 'https://x/i.webp',
      ).writeAsBytes([0]);

      final removed = await storage.deleteIllustrationCacheFiles();
      expect(removed, 2); // illustration + luckdraw，icon 保留
      expect(
        itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1).existsSync(),
        isFalse,
      );
      expect(
        itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 1,
          url: 'https://x/i.webp',
        ).existsSync(),
        isTrue,
      );
    });

    test('deleteIllustrationCacheFiles 目錄不存在回 0、不丟例外', () async {
      final parent = await Directory.systemTemp.createTemp('item_image_del_');
      addTearDown(() async {
        if (await parent.exists()) await parent.delete(recursive: true);
      });
      final dir = Directory('${parent.path}/missing');
      final s = ItemImageIndexStorage(dir);
      expect(await s.deleteIllustrationCacheFiles(), 0);
    });

    test('hasLuckdraw round-trip：save/load 保留；舊檔缺欄位預設 null（尚未評估）', () async {
      final original = ItemImageIndex(
        items: const {
          1211: ItemImageEntry(
            iconUrl: 'https://x/role_1211.webp',
            noImage: false,
            permanentNoImage: false,
            hasLuckdraw: true,
          ),
          2: ItemImageEntry(
            iconUrl: 'https://x/w.webp',
            noImage: false,
            permanentNoImage: false,
          ),
          3: ItemImageEntry(
            iconUrl: 'https://x/w3.webp',
            noImage: false,
            permanentNoImage: false,
            hasLuckdraw: false,
          ),
        },
      );
      await storage.save(original);
      final loaded = await storage.load();
      expect(loaded.lookupImage(1211)!.hasLuckdraw, isTrue);
      // 未顯式設 hasLuckdraw（即舊快取缺此欄位）→ 保留 null，表示尚未評估。
      expect(loaded.lookupImage(2)!.hasLuckdraw, isNull);
      // 顯式設為 false 的條目仍 round-trip 為 false（已評估）。
      expect(loaded.lookupImage(3)!.hasLuckdraw, isFalse);
    });

    test('v2 round trip：detailByLang 多語言序列化', () async {
      final original = ItemImageIndex(
        items: const {
          1503: ItemImageEntry(
            iconUrl: 'https://x/role_1503.webp',
            noImage: false,
            permanentNoImage: false,
            detailByLang: {
              'zh-Hant': ItemDetailL10n(
                intro: '簡介',
                elementName: '衍射',
                weaponTypeName: '音感儀',
                skins: [
                  ItemSkin(
                    formationCard: 'https://x/f_a.webp',
                    name: '新綠致意',
                    subDecName: '維里奈-初始服飾',
                    bgDescription: '造型故事',
                  ),
                ],
              ),
              'en': ItemDetailL10n(
                intro: 'Intro',
                elementName: 'Spectro',
                weaponTypeName: 'Rectifier',
                skins: [],
              ),
            },
          ),
        },
      );
      await storage.save(original);
      final loaded = await storage.load();
      final e = loaded.lookupImage(1503)!;
      expect(e.iconUrl, 'https://x/role_1503.webp');
      expect(e.detailByLang['zh-Hant']!.intro, '簡介');
      expect(e.detailByLang['zh-Hant']!.elementName, '衍射');
      expect(e.detailByLang['en']!.weaponTypeName, 'Rectifier');
      // 造型清單序列化往返。
      final skin = e.detailByLang['zh-Hant']!.skins.single;
      expect(skin.name, '新綠致意');
      expect(skin.subDecName, '維里奈-初始服飾');
      expect(skin.bgDescription, '造型故事');
      expect(skin.formationCard, 'https://x/f_a.webp');
      expect(e.detailByLang['en']!.skins, isEmpty);
    });

    test('v1（無 detail_by_lang）載入 → detailByLang 空、其餘欄位保留', () async {
      final f = File('${tempDir.path}/item_image_index.json');
      await f.writeAsString(
        jsonEncode({
          'version': 1,
          'items': {
            '1503': {
              'icon_url': 'https://x/role_1503.webp',
              'illustration_url': 'https://x/old_illust.webp',
              'no_image': false,
              'permanent_no_image': false,
            },
          },
        }),
      );
      final loaded = await storage.load();
      final e = loaded.lookupImage(1503)!;
      expect(e.iconUrl, 'https://x/role_1503.webp');
      expect(e.detailByLang, isEmpty);
    });
  });

  group('itemIconCacheFile', () {
    final baseDir = Directory.systemTemp;

    test('組合為 <resourceId>_icon.<ext>', () {
      final f = itemIconCacheFile(
        baseDir: baseDir,
        resourceId: 1211,
        url: 'https://x/card.png',
      );
      expect(f.path, endsWith('1211_icon.png'));
    });

    test('無副檔名時 fallback png', () {
      final f = itemIconCacheFile(
        baseDir: baseDir,
        resourceId: 1211,
        url: 'https://x/card',
      );
      expect(f.path, endsWith('1211_icon.png'));
    });

    test('帶 query string 不影響 ext 推導', () {
      final f = itemIconCacheFile(
        baseDir: baseDir,
        resourceId: 1211,
        url: 'https://x/card.webp?token=abc',
      );
      expect(f.path, endsWith('1211_icon.webp'));
    });
  });

  group('needsItemImageFetch', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('needs_fetch_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('index 無紀錄 → true', () {
      expect(
        needsItemImageFetch(existing: null, cacheDir: tempDir, resourceId: 1),
        isTrue,
      );
    });

    test('負取非永久 → true', () {
      const e = ItemImageEntry(
        iconUrl: null,
        noImage: true,
        permanentNoImage: false,
      );
      expect(
        needsItemImageFetch(existing: e, cacheDir: tempDir, resourceId: 1),
        isTrue,
      );
    });

    test('永久負取 → false', () {
      const e = ItemImageEntry(
        iconUrl: null,
        noImage: true,
        permanentNoImage: true,
      );
      expect(
        needsItemImageFetch(existing: e, cacheDir: tempDir, resourceId: 1),
        isFalse,
      );
    });

    test('正取且 cache 檔存在 → false', () async {
      const e = ItemImageEntry(
        iconUrl: 'https://x/card.webp',
        noImage: false,
        permanentNoImage: false,
      );
      await itemIconCacheFile(
        baseDir: tempDir,
        resourceId: 1,
        url: e.iconUrl!,
      ).writeAsBytes([1, 2, 3]);
      expect(
        needsItemImageFetch(existing: e, cacheDir: tempDir, resourceId: 1),
        isFalse,
      );
    });

    test('正取但 cache 檔遺失（手動刪快取）→ true', () {
      const e = ItemImageEntry(
        iconUrl: 'https://x/card.webp',
        noImage: false,
        permanentNoImage: false,
      );
      expect(
        needsItemImageFetch(existing: e, cacheDir: tempDir, resourceId: 1),
        isTrue,
      );
    });
  });

  group('writeImageFileAtomic', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('write_atomic_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('寫入完整 bytes 且不留 .tmp 殘檔', () async {
      final target = File('${tempDir.path}/1211_icon.webp');
      await writeImageFileAtomic(target, [1, 2, 3, 4]);
      expect(await target.readAsBytes(), [1, 2, 3, 4]);
      expect(await File('${target.path}.tmp').exists(), isFalse);
    });

    test('覆蓋既有檔（後者勝）', () async {
      final target = File('${tempDir.path}/1211_icon.webp');
      await writeImageFileAtomic(target, [1, 2, 3]);
      await writeImageFileAtomic(target, [9, 9]);
      expect(await target.readAsBytes(), [9, 9]);
    });

    test('父目錄不存在時自動建立（手動刪快取後仍可寫）', () async {
      final target = File('${tempDir.path}/gone/1211_icon.webp');
      await writeImageFileAtomic(target, [1, 2, 3]);
      expect(await target.readAsBytes(), [1, 2, 3]);
    });
  });

  group('itemIllustrationCacheFile', () {
    final baseDir = Directory.systemTemp;

    test('組合為 <resourceId>_illustration_<urlToken>.<ext>', () {
      final f = itemIllustrationCacheFile(
        baseDir: baseDir,
        resourceId: 1211,
        url: 'https://x/T_IconRole_Pile_a_UI.jpg',
      );
      expect(f.path, endsWith('1211_illustration_T_IconRole_Pile_a_UI.jpg'));
    });

    test('同角色不同造型 URL → 不同檔（不互相覆蓋）', () {
      final a = itemIllustrationCacheFile(
        baseDir: baseDir,
        resourceId: 1211,
        url: 'https://x/skin_a.webp',
      );
      final b = itemIllustrationCacheFile(
        baseDir: baseDir,
        resourceId: 1211,
        url: 'https://x/skin_b.webp',
      );
      expect(a.path, isNot(b.path));
      expect(a.path, contains('_illustration_')); // 快取用量／清除仍比對得到
    });
  });

  group('itemLuckdrawCacheFile', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('luckdraw_cache_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('itemLuckdrawCacheFile：<id>_luckdraw.png', () {
      final f = itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1211);
      expect(f.path, '${tempDir.path}/1211_luckdraw.png');
    });
  });
}
