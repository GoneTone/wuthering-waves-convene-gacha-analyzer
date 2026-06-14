import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

/// 組 encore 列表回應（roleList / weapons / itemList）。
///
/// [withNames] 為 true 時，各條目補入 `"Name"` 欄位以覆蓋 name→id 解析路徑；
/// 同時改用帶 Name 的測試 ID（1304 / 21010024），避免與既有 icon 測試用 ID 衝突。
http.Response _catalogList(String kindSeg, {bool withNames = false}) {
  final body = switch (kindSeg) {
    'character' when withNames => {
      'roleList': [
        {
          'Id': 1304,
          'RoleHeadIcon': 'https://x/role_1304.webp',
          'Name': 'Jinhsi',
        },
        {
          'Id': 1503,
          'RoleHeadIcon': 'https://x/role_1503.webp',
          'Name': 'Verina',
        },
      ],
    },
    'character' => {
      'roleList': [
        {'Id': 1503, 'RoleHeadIcon': 'https://x/role_1503.webp'},
        {'Id': 1402, 'RoleHeadIcon': 'https://x/role_1402.webp'},
      ],
    },
    'weapon' when withNames => {
      'weapons': [
        {
          'Id': 21010024,
          'Icon': 'https://x/wpn_21010024.webp',
          'Name': 'Cosmic Ripples',
        },
      ],
    },
    'weapon' => {
      'weapons': [
        {'Id': 21010074, 'Icon': 'https://x/wpn_21010074.webp'},
      ],
    },
    'item' => {
      'itemList': [
        {'Id': 3, 'Icon': 'https://x/item_3.webp'},
      ],
    },
    _ => <String, dynamic>{},
  };
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

/// 依 path 段 `/api/{lang}/{kindSeg}` 路由的 catalog MockClient。
///
/// [withNames] 傳入 `_catalogList` 以決定是否帶 `"Name"` 欄位。
http.Client _catalogClient({
  Set<String> failKinds = const {},
  List<String>? seenKinds,
  bool withNames = false,
}) {
  return MockClient((req) async {
    final seg = req.url.pathSegments; // [api, {lang}, {kindSeg}]
    final kindSeg = seg.length >= 3 ? seg[2] : '';
    seenKinds?.add(kindSeg);
    if (failKinds.contains(kindSeg)) return http.Response('', 503);
    return _catalogList(kindSeg, withNames: withNames);
  });
}

void main() {
  group('encoreLang', () {
    test('白名單語碼原樣回傳', () {
      expect(encoreLang('zh-Hant'), 'zh-Hant');
      expect(encoreLang('zh-Hans'), 'zh-Hans');
      expect(encoreLang('ja'), 'ja');
      expect(encoreLang('en'), 'en');
      expect(encoreLang('ko'), 'ko');
      expect(encoreLang('fr'), 'fr');
    });
    test('未知語碼 fallback en', () {
      expect(encoreLang('xx'), 'en');
      expect(encoreLang('zh-TW'), 'en'); // 非白名單寫法
    });
    test('空字串 fallback en', () {
      expect(encoreLang(''), 'en');
    });
  });

  group('ItemImageFetcher.downloadImage', () {
    test('200 OK → 回 bytes', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final mock = MockClient((_) async => http.Response.bytes(bytes, 200));
      final out = await ItemImageFetcher().downloadImage(
        'https://x/icon.png',
        mock,
      );
      expect(out, bytes);
    });

    test('404 → null', () async {
      final mock = MockClient((_) async => http.Response('', 404));
      final out = await ItemImageFetcher().downloadImage(
        'https://x/icon.png',
        mock,
      );
      expect(out, isNull);
    });

    test('throw → null', () async {
      final mock = MockClient(
        (_) async => throw const SocketException('refused'),
      );
      final out = await ItemImageFetcher().downloadImage(
        'https://x/icon.png',
        mock,
      );
      expect(out, isNull);
    });
  });

  group('ItemImageFetcher.fetchItemDetail', () {
    http.Client detailClient(Map<String, dynamic> body, {int status = 200}) =>
        MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(jsonEncode(body)),
            status,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        );

    test('角色：解析 intro/element/weaponType/skins/iconHd', () async {
      final d = await ItemImageFetcher().fetchItemDetail(
        resourceId: 1503,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
        client: detailClient({
          'Introduction': {'Content': '簡介文字'},
          'ElementName': '衍射',
          'WeaponTypeName': '音感儀',
          'Skins': [
            {
              'Name': '新綠致意',
              'SubDecName': '維里奈-初始服飾',
              'BgDescription': '造型故事',
              'FormationRoleCard': 'https://x/formation_1503_a.webp',
              'RoleHeadIconLarge': 'https://x/head256_1503.webp',
            },
            {
              'Name': '夏日',
              'SubDecName': '維里奈-特別訂製',
              'BgDescription': '故事2',
              'FormationRoleCard': 'https://x/formation_1503_b.webp',
            },
          ],
        }),
      );
      expect(d, isNotNull);
      expect(d!.intro, '簡介文字');
      expect(d.elementName, '衍射');
      expect(d.weaponTypeName, '音感儀');
      expect(d.skins.length, 2);
      expect(d.skins.first.name, '新綠致意');
      expect(d.skins.first.subDecName, '維里奈-初始服飾');
      expect(d.skins.first.bgDescription, '造型故事');
      expect(d.skins.first.formationCard, 'https://x/formation_1503_a.webp');
      expect(d.skins[1].formationCard, 'https://x/formation_1503_b.webp');
      // iconHd 取自 Skins[0].RoleHeadIconLarge。
      expect(d.iconHd, 'https://x/head256_1503.webp');
    });

    test('武器：解析 BgDescription（含 HTML 原樣）/weaponType，element/skins 空', () async {
      final d = await ItemImageFetcher().fetchItemDetail(
        resourceId: 21010074,
        kind: kItemKindWeapon,
        lang: 'zh-Hant',
        client: detailClient({
          'BgDescription': '此刃<br>為禮儀<te>用器</te>',
          'WeaponTypeName': '長刃',
        }),
      );
      expect(d, isNotNull);
      expect(d!.intro, '此刃<br>為禮儀<te>用器</te>');
      expect(d.weaponTypeName, '長刃');
      expect(d.elementName, '');
      expect(d.skins, isEmpty); // 武器無造型
      expect(d.iconHd, ''); // 武器不取 HD icon，沿用列表 icon
    });

    test('道具 kind 不打 API → 回 null', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('', 200);
      });
      final d = await ItemImageFetcher().fetchItemDetail(
        resourceId: 3,
        kind: kItemKindItem,
        lang: 'zh-Hant',
        client: client,
      );
      expect(d, isNull);
      expect(called, isFalse);
    });

    test('404 → null（不 throw）', () async {
      final d = await ItemImageFetcher().fetchItemDetail(
        resourceId: 1503,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
        client: detailClient(const {}, status: 404),
      );
      expect(d, isNull);
    });

    test('非 JSON → null（不 throw）', () async {
      final d = await ItemImageFetcher().fetchItemDetail(
        resourceId: 1503,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
        client: MockClient((_) async => http.Response('{not json', 200)),
      );
      expect(d, isNull);
    });

    test('角色：解析 Luckdraw 欄位 → hasLuckdraw', () async {
      final withLk = await ItemImageFetcher().fetchItemDetail(
        resourceId: 1211,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
        client: detailClient({
          'Introduction': {'Content': 'x'},
          'Skins': const [],
          'Luckdraw': {
            'LuckdrawSpineAtlas': '/Game/.../c.atlas',
            'LuckdrawSpineSkeletonData': '/Game/.../c.skel',
          },
        }),
      );
      expect(withLk!.hasLuckdraw, isTrue);

      final noLk = await ItemImageFetcher().fetchItemDetail(
        resourceId: 1212,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
        client: detailClient({
          'Introduction': {'Content': 'x'},
          'Skins': const [],
        }),
      );
      expect(noLk!.hasLuckdraw, isFalse);

      final emptyLk = await ItemImageFetcher().fetchItemDetail(
        resourceId: 1213,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
        client: detailClient({
          'Introduction': {'Content': 'x'},
          'Skins': const [],
          'Luckdraw': {'LuckdrawSpineSkeletonData': ''},
        }),
      );
      expect(emptyLk!.hasLuckdraw, isFalse);
    });

    test('武器：hasLuckdraw 恆 false', () async {
      final d = await ItemImageFetcher().fetchItemDetail(
        resourceId: 21010011,
        kind: kItemKindWeapon,
        lang: 'zh-Hant',
        client: detailClient({'BgDescription': 'w'}),
      );
      expect(d!.hasLuckdraw, isFalse);
    });

    test('角色：Luckdraw 與角色錯位（秧秧→尤諾）→ hasLuckdraw false', () async {
      final d = await ItemImageFetcher().fetchItemDetail(
        resourceId: 1402,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
        client: detailClient({
          'Id': 1402,
          'Introduction': {'Content': 'x'},
          'Skins': const [],
          // Luckdraw spine 指向尤諾（younuo），其餘欄位皆為秧秧（yangyang）。
          'Luckdraw': {
            'LuckdrawSpineSkeletonData':
                '/Game/Aki/UI/UIResources/UiLuckdraw/Spine/Character/'
                'C_YouNuo_01/c_younuo_1.skel',
          },
          'FormationRoleCard': 'https://x/T_IconRole_Pile_yangyang_UI.webp',
          'RolePortrait': 'https://x/T_ActivityRoleYangyang.webp',
          'UiScenePerformanceABP':
              '/Game/Aki/Character/Role/FemaleM/Yangyang/'
              'R2T1YangyangMd10011/ABP_Performance_Yangyang_PC',
        }),
      );
      expect(d!.hasLuckdraw, isFalse);
    });

    test('角色缺欄位 → 對應欄空字串、不 throw', () async {
      final d = await ItemImageFetcher().fetchItemDetail(
        resourceId: 1503,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
        client: detailClient({'ElementName': '衍射'}),
      );
      expect(d, isNotNull);
      expect(d!.intro, '');
      expect(d.elementName, '衍射');
      expect(d.skins, isEmpty); // 無 Skins → 空
      expect(d.iconHd, ''); // 無 Skins → iconHd 空
    });
  });

  group('luckdrawBelongsToCharacter', () {
    String luck(String code) =>
        '/Game/Aki/UI/UIResources/UiLuckdraw/Spine/Character/'
        'C_${code}_01/c_${code.toLowerCase()}_1.skel';
    String form(String code) => 'https://x/T_IconRole_Pile_${code}_UI.webp';
    String portrait(String code) => 'https://x/T_ActivityRole$code.webp';
    String perf(String code) =>
        '/Game/Aki/Character/Role/FemaleM/$code/R2T1${code}Md10011/'
        'ABP_Performance_${code}_PC';

    Map<String, dynamic> body({
      required String luckPath,
      String? formCard,
      String? rolePortrait,
      String? performance,
      int id = 1,
    }) => {
      'Id': id,
      'Luckdraw': {'LuckdrawSpineSkeletonData': luckPath},
      'FormationRoleCard': ?formCard,
      'RolePortrait': ?rolePortrait,
      'UiScenePerformanceABP': ?performance,
    };

    test('全部基準一致 → true', () {
      expect(
        luckdrawBelongsToCharacter(
          body(
            luckPath: luck('DaNiYa'),
            formCard: form('daniya'),
            rolePortrait: portrait('Daniya'),
            performance: perf('Daniya'),
          ),
        ),
        isTrue,
      );
    });

    test('Luckdraw 對不上全部基準（younuo vs yangyang）→ false', () {
      expect(
        luckdrawBelongsToCharacter(
          body(
            luckPath: luck('YouNuo'),
            formCard: form('yangyang'),
            rolePortrait: portrait('Yangyang'),
            performance: perf('Yangyang'),
          ),
        ),
        isFalse,
      );
    });

    test('英文別名：拼音基準不符但代號系基準相符（lucy/luxi）→ true（不誤殺）', () {
      expect(
        luckdrawBelongsToCharacter(
          body(
            luckPath: luck('Lucy'),
            formCard: form('luxi'),
            rolePortrait: portrait('Luxi'),
            performance: perf('Lucy'), // 內部代號系對上
          ),
        ),
        isTrue,
      );
    });

    test('拼音/代號分裂：代號系基準不符但拼音基準相符（kelaita/kamola）→ true', () {
      expect(
        luckdrawBelongsToCharacter(
          body(
            luckPath: luck('KeLaiTa'),
            formCard: form('kelaita'), // 拼音系對上
            performance: perf('Kamola'),
          ),
        ),
        isTrue,
      );
    });

    test('純數字尾碼容忍（jiyan vs jiyan1）→ true', () {
      // perf('Jiyan1') 產生帶數字尾碼的代號 jiyan1，須能被 _performanceCode 解析
      // （含數字）並經數字尾碼容忍對上 luck=jiyan，而非落入無基準保底。
      expect(
        luckdrawBelongsToCharacter(
          body(luckPath: luck('JiYan'), performance: perf('Jiyan1')),
        ),
        isTrue,
      );
    });

    test('performance ABP 為唯一基準時仍判錯位（younuo vs yangyang）→ false', () {
      expect(
        luckdrawBelongsToCharacter(
          body(luckPath: luck('YouNuo'), performance: perf('Yangyang')),
        ),
        isFalse,
      );
    });

    test('字母延伸不視為同角色（ling vs lingyang）→ false（不誤放）', () {
      expect(
        luckdrawBelongsToCharacter(
          body(luckPath: luck('Ling'), formCard: form('lingyang')),
        ),
        isFalse,
      );
    });

    test('保守：無任何基準可比 → true', () {
      expect(
        luckdrawBelongsToCharacter(body(luckPath: luck('DaNiYa'))),
        isTrue,
      );
    });

    test('保守：Luckdraw 路徑無法解析代號 → true', () {
      expect(
        luckdrawBelongsToCharacter(
          body(luckPath: '/Game/.../no_code.skel', formCard: form('yangyang')),
        ),
        isTrue,
      );
    });

    test('保守：無 Luckdraw 物件 → true', () {
      expect(luckdrawBelongsToCharacter({'Id': 1}), isTrue);
    });
  });

  group('encoreItemUrl', () {
    test('角色 id-based ＋ lang query', () {
      expect(
        encoreItemUrl(
          kind: kItemKindCharacter,
          resourceId: 1503,
          lang: 'zh-Hant',
        ),
        'https://encore.moe/character/1503?lang=zh-Hant',
      );
    });
    test('武器 → /weapon', () {
      expect(
        encoreItemUrl(kind: kItemKindWeapon, resourceId: 21010074, lang: 'en'),
        'https://encore.moe/weapon/21010074?lang=en',
      );
    });
    test('道具 → /item', () {
      expect(
        encoreItemUrl(kind: kItemKindItem, resourceId: 99, lang: 'ja'),
        'https://encore.moe/item/99?lang=ja',
      );
    });
    test('未知 lang fallback en', () {
      expect(
        encoreItemUrl(kind: kItemKindCharacter, resourceId: 1, lang: 'xx'),
        'https://encore.moe/character/1?lang=en',
      );
    });
  });

  group('EncoreCatalog.resolveByName', () {
    test('以名稱查回 (id, kind)，查無回 null', () {
      const catalog = EncoreCatalog(
        iconByKindId: {},
        idByName: {
          'Jinhsi': (id: 1304, kind: kItemKindCharacter),
          'Cosmic Ripples': (id: 21010024, kind: kItemKindWeapon),
        },
      );
      expect(catalog.resolveByName('Jinhsi'), (
        id: 1304,
        kind: kItemKindCharacter,
      ));
      expect(catalog.resolveByName('Cosmic Ripples'), (
        id: 21010024,
        kind: kItemKindWeapon,
      ));
      expect(catalog.resolveByName('Unknown Name'), isNull);
    });
  });

  group('ItemImageFetcher.fetchCatalog', () {
    test('解析 character/weapon/item 的 icon URL，iconFor 命中', () async {
      final cat = await ItemImageFetcher().fetchCatalog(
        lang: 'zh-Hant',
        kinds: {kItemKindCharacter, kItemKindWeapon, kItemKindItem},
        client: _catalogClient(),
      );
      expect(
        cat.iconFor(kind: kItemKindCharacter, id: 1503),
        'https://x/role_1503.webp',
      );
      expect(
        cat.iconFor(kind: kItemKindWeapon, id: 21010074),
        'https://x/wpn_21010074.webp',
      );
      expect(cat.iconFor(kind: kItemKindItem, id: 3), 'https://x/item_3.webp');
    });

    test('只打 kinds 內出現的端點', () async {
      final seen = <String>[];
      await ItemImageFetcher().fetchCatalog(
        lang: 'zh-Hant',
        kinds: {kItemKindCharacter},
        client: _catalogClient(seenKinds: seen),
      );
      expect(seen, ['character']);
    });

    test('某 kind 非 2xx → 該 kind 空、其餘正常', () async {
      final cat = await ItemImageFetcher().fetchCatalog(
        lang: 'zh-Hant',
        kinds: {kItemKindCharacter, kItemKindWeapon},
        client: _catalogClient(failKinds: {'weapon'}),
      );
      expect(cat.iconFor(kind: kItemKindCharacter, id: 1503), isNotNull);
      expect(cat.iconFor(kind: kItemKindWeapon, id: 21010074), isNull);
    });

    test('iconFor 查無回 null', () async {
      final cat = await ItemImageFetcher().fetchCatalog(
        lang: 'zh-Hant',
        kinds: {kItemKindCharacter},
        client: _catalogClient(),
      );
      expect(cat.iconFor(kind: kItemKindCharacter, id: 9999), isNull);
      expect(cat.iconFor(kind: kItemKindWeapon, id: 1503), isNull);
    });

    test('帶 encoreLang（未知碼以 en 打）', () async {
      final seenLangs = <String>[];
      final client = MockClient((req) async {
        seenLangs.add(req.url.pathSegments[1]);
        return _catalogList('character');
      });
      await ItemImageFetcher().fetchCatalog(
        lang: 'xx',
        kinds: {kItemKindCharacter},
        client: client,
      );
      expect(seenLangs, ['en']);
    });

    test(
      'Name 欄位填入 idByName，resolveByName 可查回 (id, kind)，未知名稱回 null',
      () async {
        final cat = await ItemImageFetcher().fetchCatalog(
          lang: 'en',
          kinds: {kItemKindCharacter, kItemKindWeapon},
          client: _catalogClient(withNames: true),
        );
        expect(cat.resolveByName('Jinhsi'), (
          id: 1304,
          kind: kItemKindCharacter,
        ));
        expect(cat.resolveByName('Cosmic Ripples'), (
          id: 21010024,
          kind: kItemKindWeapon,
        ));
        expect(cat.resolveByName('Unknown Name'), isNull);
      },
    );
  });
}
