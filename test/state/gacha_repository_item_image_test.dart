import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';

/// 不打網路的 fetcher：[characters]/[weapons] 內的 id 在 catalog 命中、回 icon；
/// [details] 內的 id 在 fetchItemDetail 回詳情。
class _FakeFetcher extends ItemImageFetcher {
  _FakeFetcher({
    this.characters = const {},
    this.weapons = const {},
    this.details = const {},
  });
  final Set<int> characters;
  final Set<int> weapons;
  final Set<int> details;

  @override
  Future<EncoreCatalog> fetchCatalog({
    required String lang,
    required Set<String> kinds,
    required http.Client client,
  }) async {
    return EncoreCatalog(
      iconByKindId: {
        kItemKindCharacter: {
          for (final id in characters) id: 'https://x/$id.png',
        },
        kItemKindWeapon: {for (final id in weapons) id: 'https://x/$id.png'},
      },
    );
  }

  @override
  Future<EncoreItemDetail?> fetchItemDetail({
    required int resourceId,
    required String kind,
    required String lang,
    required http.Client client,
  }) async {
    if (!details.contains(resourceId)) return null;
    return EncoreItemDetail(
      intro: 'intro-$lang-$resourceId',
      elementName: 'el',
      weaponTypeName: 'wt',
      skins: kind == kItemKindCharacter
          ? [
              (
                formationCard: 'https://x/${resourceId}_skin.png',
                name: 'skin-$resourceId',
                subDecName: 'sub-$resourceId',
                bgDescription: 'bg-$resourceId',
              ),
            ]
          : const [],
      iconHd: kind == kItemKindCharacter
          ? 'https://x/${resourceId}_hd.png'
          : '',
    );
  }
}

GachaRecord _rec(
  int resourceId,
  int q,
  String type, {
  String lang = 'zh-Hant',
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: q,
  resourceType: type,
  cardPoolType: '1',
  name: 'r$resourceId',
  count: 1,
  time: DateTime.utc(2026, 5, 21),
  languageCode: lang,
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('repo_item_image_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  ProviderContainer build({
    Set<int> characters = const {},
    Set<int> weapons = const {},
    Set<int> details = const {},
  }) {
    final mockClient = MockClient(
      (_) async => http.Response.bytes([1, 2, 3], 200),
    );
    return ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
        itemImageIndexStorageProvider.overrideWithValue(
          ItemImageIndexStorage(tempDir),
        ),
        itemImageCacheDirProvider.overrideWithValue(tempDir),
        itemImageFetcherProvider.overrideWithValue(
          _FakeFetcher(
            characters: characters,
            weapons: weapons,
            details: details,
          ),
        ),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(client: mockClient, cancel: () {}),
        ),
      ],
    );
  }

  test('角色寫正取 + 下載 icon；武器/道具寫負取', () async {
    final container = build(characters: {1211}, details: {1211});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();

    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [
            _rec(1211, 5, '角色'),
            _rec(21010024, 4, '武器'),
            _rec(21040084, 4, '道具'),
          ],
        },
      ),
    );

    await repo.debugRunItemImagesOnly();
    await container.read(itemImageIndexProvider.notifier).waitForLoad();
    final index = container.read(itemImageIndexProvider);

    expect(index.lookupImage(1211)!.hasIcon, isTrue);
    expect(index.lookupImage(21010024)!.noImage, isTrue);
    expect(index.lookupImage(21010024)!.permanentNoImage, isFalse);
    expect(index.lookupImage(21040084)!.noImage, isTrue);
    expect(File('${tempDir.path}/1211_icon.png').existsSync(), isTrue);
    expect(
      index.lookupImage(1211)!.detailByLang['zh-Hant']!.intro,
      'intro-zh-Hant-1211',
    );
    // 角色 icon 升級為詳情提供的 HD（256px）版，非列表的 150px。
    expect(index.lookupImage(1211)!.iconUrl, 'https://x/1211_hd.png');
  });

  test('正取者第二次跑不重抓；負取者每次重試', () async {
    // 預植：1211 正取、21010024 負取（非永久）。
    final storage = ItemImageIndexStorage(tempDir);
    await storage.save(
      const ItemImageIndex(
        items: {
          1211: ItemImageEntry(
            iconUrl: 'https://x/1211.png',
            noImage: false,
            permanentNoImage: false,
          ),
          21010024: ItemImageEntry(
            iconUrl: null,
            noImage: true,
            permanentNoImage: false,
          ),
        },
      ),
    );
    // 這次 21010024 在武器 catalog 命中（模擬官方後補圖）。
    final container = build(characters: {1211}, weapons: {21010024});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [_rec(1211, 5, '角色'), _rec(21010024, 4, '武器')],
        },
      ),
    );

    await repo.debugRunItemImagesOnly();
    final index = container.read(itemImageIndexProvider);
    // 負取者這次翻成正取。
    expect(index.lookupImage(21010024)!.hasIcon, isTrue);
  });

  test('進度分兩階段：取得物品資料 total=待查數、下載 total=有圖數', () async {
    // 1211 正取（角色），21010024 / 21040084 查無圖（負取）。
    final container = build(characters: {1211});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [
            _rec(1211, 5, '角色'),
            _rec(21010024, 4, '武器'),
            _rec(21040084, 4, '道具'),
          ],
        },
      ),
    );

    final seen = <(ItemImagePhase, int, int)>[];
    container.listen(gachaRepositoryProvider, (prev, next) {
      final p = next.progress;
      if (p is FetchingItemImages) {
        seen.add((p.phase, p.doneCount, p.totalCount));
      }
    });

    await repo.debugRunItemImagesOnly();

    final checking = seen.where((e) => e.$1 == ItemImagePhase.checking);
    final downloading = seen.where((e) => e.$1 == ItemImagePhase.downloading);
    expect(checking, isNotEmpty);
    expect(downloading, isNotEmpty);
    // 取得物品資料階段：待查 3 個物品。
    expect(checking.map((e) => e.$3).toSet(), {3});
    // 下載階段：只有 1 張真正要下載。
    expect(downloading.map((e) => e.$3).toSet(), {1});
  });

  test('全查無圖：只有取得物品資料階段，無下載階段', () async {
    final container = build(characters: <int>{}); // 全部查無圖
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [_rec(21010024, 4, '武器'), _rec(21040084, 4, '道具')],
        },
      ),
    );

    final phases = <ItemImagePhase>[];
    container.listen(gachaRepositoryProvider, (prev, next) {
      final p = next.progress;
      if (p is FetchingItemImages) phases.add(p.phase);
    });

    await repo.debugRunItemImagesOnly();

    expect(phases, contains(ItemImagePhase.checking));
    expect(phases, isNot(contains(ItemImagePhase.downloading)));
  });

  test('被拒的不相容舊版 v1 匯入不觸發補圖（R18）→ index 維持空', () async {
    final container = build(characters: {1211});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    await container.read(itemImageIndexProvider.notifier).waitForLoad();

    // 不相容的舊版 v1 全帳號匯出格式（uid/gacha_type，無鳴潮 playerId/cardPoolType），
    // 由 plan 03/04 的匯入解析拒絕；拒絕路徑不得進入 _fetchItemImages。
    final legacyBundle = jsonEncode({
      'schema': 'legacy-export-v1',
      'accounts': [
        {
          'uid': '700000001',
          'records': [
            {'gacha_type': '301', 'item_id': '10000002', 'rank_type': '5'},
          ],
        },
      ],
    });

    final result = await repo.importAccountsAndFetchItemImages(legacyBundle);

    expect(result.successAccounts, 0);
    expect(container.read(itemImageIndexProvider).items, isEmpty);
    expect(File('${tempDir.path}/1211_icon.png').existsSync(), isFalse);
  });

  test('詳情逐 (id, lang) 預抓：多語言帳號各存一份', () async {
    final container = build(characters: {1503}, details: {1503});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000001',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [_rec(1503, 5, '角色', lang: 'zh-Hant')],
        },
      ),
    );
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000002',
        languageCode: 'en',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [_rec(1503, 5, 'Character', lang: 'en')],
        },
      ),
    );
    await repo.debugRunItemImagesOnly();
    final e = container.read(itemImageIndexProvider).lookupImage(1503)!;
    expect(e.detailByLang.keys.toSet(), {'zh-Hant', 'en'});
  });

  test('kind 由 encore catalog 歸屬判定並寫入 index；不在清單者 kind 維持 null', () async {
    final container = build(characters: {1211}, weapons: {21010024});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [
            _rec(1211, 5, '角色'),
            _rec(21010024, 4, '武器'),
            _rec(21040084, 4, '道具'),
          ],
        },
      ),
    );
    await repo.debugRunItemImagesOnly();
    final idx = container.read(itemImageIndexProvider);
    expect(idx.lookupImage(1211)!.kind, kItemKindCharacter);
    expect(idx.lookupImage(21010024)!.kind, kItemKindWeapon);
    // 道具不在任何 catalog 清單 → 負取、kind 維持 null。
    expect(idx.lookupImage(21040084)!.noImage, isTrue);
    expect(idx.lookupImage(21040084)!.kind, isNull);
  });

  test('既有角色詳情已抓但 hasLuckdraw 未評估 → 重抓評估（legacy backfill）', () async {
    // 預植：角色 1211 icon 已快取、kind 已分類、該語言詳情已抓，但 hasLuckdraw 為 null。
    await File('${tempDir.path}/1211_icon.png').writeAsBytes([9, 9, 9]);
    await ItemImageIndexStorage(tempDir).save(
      const ItemImageIndex(
        items: {
          1211: ItemImageEntry(
            iconUrl: 'https://x/1211.png',
            noImage: false,
            permanentNoImage: false,
            kind: kItemKindCharacter,
            detailByLang: {
              'zh-Hant': ItemDetailL10n(
                intro: 'i',
                elementName: '',
                weaponTypeName: '',
                skins: [],
              ),
            },
          ),
        },
      ),
    );
    final container = build(characters: {1211}, details: {1211});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    await container.read(itemImageIndexProvider.notifier).waitForLoad();
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [_rec(1211, 5, '角色')],
        },
      ),
    );
    await repo.debugRunItemImagesOnly();
    final e = container.read(itemImageIndexProvider).lookupImage(1211)!;
    // hasLuckdraw 已由重抓詳情評估為定值（fake fetcher 回 false），不再是 null。
    expect(e.hasLuckdraw, isNotNull);
  });

  test('既有快取 icon 但 kind==null → 補 kind、不重下載', () async {
    await File('${tempDir.path}/1211_icon.png').writeAsBytes([9, 9, 9]);
    await ItemImageIndexStorage(tempDir).save(
      const ItemImageIndex(
        items: {
          1211: ItemImageEntry(
            iconUrl: 'https://x/1211.png',
            noImage: false,
            permanentNoImage: false,
          ),
        },
      ),
    );
    final container = build(characters: {1211});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    await container.read(itemImageIndexProvider.notifier).waitForLoad();
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [_rec(1211, 5, '角色')],
        },
      ),
    );
    await repo.debugRunItemImagesOnly();
    final e = container.read(itemImageIndexProvider).lookupImage(1211)!;
    expect(e.kind, kItemKindCharacter);
    // 未重下載：磁碟檔仍是預寫的 bytes（重下載會被 MockClient 覆成 [1,2,3]）。
    expect(await File('${tempDir.path}/1211_icon.png').readAsBytes(), [
      9,
      9,
      9,
    ]);
  });

  test('forceDetailRefetch：detail 已存在仍重抓，偵測新 skins；icon 不重下', () async {
    // 預植：1211 角色 icon 已快取、kind 已分類、zh-Hant 詳情已抓但 skins 為空、hasLuckdraw 已評估。
    await File('${tempDir.path}/1211_icon.png').writeAsBytes([9, 9, 9]);
    await ItemImageIndexStorage(tempDir).save(
      const ItemImageIndex(
        items: {
          1211: ItemImageEntry(
            iconUrl: 'https://x/1211.png',
            noImage: false,
            permanentNoImage: false,
            kind: kItemKindCharacter,
            hasLuckdraw: false,
            detailByLang: {
              'zh-Hant': ItemDetailL10n(
                intro: 'old',
                elementName: '',
                weaponTypeName: '',
                skins: [],
              ),
            },
          ),
        },
      ),
    );
    final container = build(characters: {1211}, details: {1211});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    await container.read(itemImageIndexProvider.notifier).waitForLoad();
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [_rec(1211, 5, '角色')],
        },
      ),
    );

    await repo.debugRunItemImagesOnly(forceDetailRefetch: true);

    final e = container.read(itemImageIndexProvider).lookupImage(1211)!;
    // detail 已存在仍重抓 → 偵測到 fake fetcher 回的新 skin。
    expect(e.detailByLang['zh-Hant']!.skins, isNotEmpty);
    // 非破壞：icon 檔未被重下載（仍是預寫 bytes；重下載會被 MockClient 覆成 [1,2,3]）。
    expect(await File('${tempDir.path}/1211_icon.png').readAsBytes(), [
      9,
      9,
      9,
    ]);
  });

  test('非 force 時 detail 已存在不重抓（守衛維持）', () async {
    await File('${tempDir.path}/1211_icon.png').writeAsBytes([9, 9, 9]);
    await ItemImageIndexStorage(tempDir).save(
      const ItemImageIndex(
        items: {
          1211: ItemImageEntry(
            iconUrl: 'https://x/1211.png',
            noImage: false,
            permanentNoImage: false,
            kind: kItemKindCharacter,
            hasLuckdraw: false,
            detailByLang: {
              'zh-Hant': ItemDetailL10n(
                intro: 'old',
                elementName: '',
                weaponTypeName: '',
                skins: [],
              ),
            },
          ),
        },
      ),
    );
    final container = build(characters: {1211}, details: {1211});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    await container.read(itemImageIndexProvider.notifier).waitForLoad();
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [_rec(1211, 5, '角色')],
        },
      ),
    );

    await repo.debugRunItemImagesOnly();

    // 未 force：skins 維持空（沒重抓）。
    final e = container.read(itemImageIndexProvider).lookupImage(1211)!;
    expect(e.detailByLang['zh-Hant']!.skins, isEmpty);
  });

  test('pruneStaleLangs：移除不在任何記錄的殘留語言', () async {
    // 預植：1503 同時有 zh-Hant 與 en 詳情，但記錄只剩 zh-Hant（en 為轉換後殘留）。
    await ItemImageIndexStorage(tempDir).save(
      const ItemImageIndex(
        items: {
          1503: ItemImageEntry(
            iconUrl: 'https://x/1503.png',
            noImage: false,
            permanentNoImage: false,
            kind: kItemKindCharacter,
            hasLuckdraw: false,
            detailByLang: {
              'zh-Hant': ItemDetailL10n(
                intro: 'A',
                elementName: '',
                weaponTypeName: '',
                skins: [],
              ),
              'en': ItemDetailL10n(
                intro: 'B',
                elementName: '',
                weaponTypeName: '',
                skins: [],
              ),
            },
          ),
        },
      ),
    );
    await File('${tempDir.path}/1503_icon.png').writeAsBytes([9, 9, 9]);
    final container = build(characters: {1503}, details: {1503});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    await container.read(itemImageIndexProvider.notifier).waitForLoad();
    repo.debugSeedAccount(
      BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026),
        banners: {
          '1': [_rec(1503, 5, '角色', lang: 'zh-Hant')],
        },
      ),
    );

    await repo.debugRunItemImagesOnly(
      forceDetailRefetch: true,
      pruneStaleLangs: true,
    );

    final e = container.read(itemImageIndexProvider).lookupImage(1503)!;
    // en 殘留被清，zh-Hant 保留。
    expect(e.detailByLang.containsKey('en'), isFalse);
    expect(e.detailByLang.containsKey('zh-Hant'), isTrue);
  });
}
