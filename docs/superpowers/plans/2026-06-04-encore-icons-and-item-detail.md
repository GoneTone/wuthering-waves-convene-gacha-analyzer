# encore.moe Icons ＋ Item Detail Dialog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把所有物品 icon／圖片改由 encore.moe 取得（移除 guide-server 與武器猜檔名），並加回原神版風格的物品詳情顯示（簡介＋tag＋圖片切換＋外連），詳情於更新階段預抓、per-lang 存索引、dialog 開啟即時顯示。

**Architecture:** 格子 icon 改用 encore **列表端點**（`/api/{lang}/character|weapon|item`）查表（直接拿正確 icon URL）；dialog 詳情改用 encore **詳情端點**（`/api/{lang}/character|weapon/{id}`）於更新階段 per-(id,lang) 預抓，存入 `ItemImageEntry.detailByLang`；dialog 用**作用中帳號**語言查 `detailByLang` 即時顯示，僅立繪**圖片** lazy 下載。簡介以 `flutter_html` 渲染。

**Tech Stack:** Flutter／Dart、Riverpod（`NotifierProvider`）、`http` + `http/testing` MockClient、`flutter_html`、`url_launcher`（既有 `openExternalUrl`）。

**參考 spec：** `docs/superpowers/specs/2026-06-04-encore-icons-and-item-detail-design.md`

---

## 重要既有事實（實作前先讀）

- **fetcher 測試 MockClient** 以 `req.url.host` / `req.url.path` 路由（見 `test/services/item_image_fetcher_test.dart`）。
- **encore API**：`https://api-v2.encore.moe/api/{lang}/character`（list）、`/api/{lang}/character/{id}`（detail）；`weapon`、`item` 同構。圖片 URL 由回應直接給、照原樣用。
- **encore 外連路由（已用瀏覽器驗證，id-based ＋ `?lang=`）**：
  - 角色 `https://encore.moe/character/{resourceId}?lang={lang}`
  - 武器 `https://encore.moe/weapon/{resourceId}?lang={lang}`
- **kind 判定**：`itemTypeKeyOf(GachaRecord)`（`lib/services/item_type_kind.dart`）→ `kItemKindCharacter` / `kItemKindWeapon` / `kItemKindItem`。
- **list 端點 icon 欄位**：角色 `roleList[].RoleHeadIcon`、武器 `weapons[].Icon`、道具 `itemList[].Icon`。
- **detail 端點欄位**：角色 `Introduction.Content`／`ElementName`／`WeaponTypeName`／`Skins[0].PreviewRoleCard`；武器 `BgDescription`（含 HTML）／`WeaponTypeName`。
- **ARB 既有鍵**：`rarityStar`=`"{rank}★"`、`actionClose`=`關閉`、`galleryIllustrationLabel`=`立繪`、`galleryIconLabel`=`圖示`、`galleryLazyLoadFailed`、`actionRetry`。實譯 ARB 僅 `app_zh` / `app_zh_Hans` / `app_en` / `app_ja`。
- **每個 task 結尾品質檢查**（CLAUDE.md 強制）：`dart format lib/ test/` → `flutter analyze`（`No issues found!`）→ `flutter test`（`All tests passed!`）。任一失敗先修，不得 `--no-verify`。commit message 用英文 conventional commits。

---

## 檔案結構

| 檔案 | 責任 | 本案動作 |
|---|---|---|
| `lib/services/item_image_fetcher.dart` | encore HTTP 抓取（catalog / detail / download） | 改寫：移除 guide-server＋猜檔名；加 `encoreLang`／`EncoreCatalog`／`fetchCatalog`／`EncoreItemDetail`／`fetchItemDetail`／`encoreItemUrl` |
| `lib/services/item_image_index.dart` | 索引資料模型＋storage（persist） | 加 `ItemDetailL10n`、`ItemImageEntry.detailByLang`；storage v2；移除 `illustrationUrl` |
| `lib/state/item_image_index.dart` | 索引 Notifier（mutation＋persist） | `mergeItemImage`→`mergeIcon`；加 `mergeItemDetail` |
| `lib/state/gacha_repository.dart` | 喚取資料＋更新流程 | `_fetchItemImages` 改 catalog 查表＋詳情預抓；加 `activeLanguageCodeProvider` |
| `lib/widgets/dialogs/gacha_item_detail_dialog.dart` | 詳情 dialog | 加回簡介（`Html`）＋tag＋外連；詳情由 `detailByLang[activeLang]` 取 |
| `pubspec.yaml` | 依賴 | 加回 `flutter_html` |
| `lib/l10n/app_{zh,zh_Hans,en,ja}.arb` | i18n | 加 `actionViewOnEncore` |

---

## Task 1：`encoreLang` 白名單 helper

**Files:**
- Modify: `lib/services/item_image_fetcher.dart`
- Test: `test/services/item_image_fetcher_test.dart`

- [ ] **Step 1: 寫失敗測試**（加在 `void main() {` 內最前面新 group）

```dart
group('encoreLang', () {
  test('白名單語碼原樣回傳', () {
    expect(encoreLang('zh-Hant'), 'zh-Hant');
    expect(encoreLang('zh-Hans'), 'zh-Hans');
    expect(encoreLang('ja'), 'ja');
    expect(encoreLang('en'), 'en');
  });
  test('未知語碼 fallback en', () {
    expect(encoreLang('xx'), 'en');
    expect(encoreLang('zh-TW'), 'en'); // 非白名單寫法
  });
  test('空字串 fallback en', () {
    expect(encoreLang(''), 'en');
  });
});
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `flutter test test/services/item_image_fetcher_test.dart -n encoreLang`
Expected: FAIL（`encoreLang` 未定義）

- [ ] **Step 3: 實作**（加在 `lib/services/item_image_fetcher.dart` 頂部、`import` 之後）

```dart
/// encore API 支援的語系白名單（path 參數 `{lang}` 的合法值）。
const _encoreLangs = {
  'en', 'zh-Hans', 'zh-Hant', 'ja', 'ko',
  'de', 'es', 'fr', 'id', 'pt', 'ru', 'th', 'vi',
};

/// 將擷取到的 [languageCode] 映射為 encore `{lang}` 路徑參數：命中白名單原樣
/// 回傳、否則 fallback `'en'`（並記 warning）。**一律帶物品擷取語言、不看 app UI 語言。**
String encoreLang(String languageCode) {
  if (_encoreLangs.contains(languageCode)) return languageCode;
  Logger('item_image.fetcher').warning(
    'encoreLang unknown code=$languageCode → en',
  );
  return 'en';
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `flutter test test/services/item_image_fetcher_test.dart -n encoreLang`
Expected: PASS

- [ ] **Step 5: 品質檢查＋commit**

```bash
dart format lib/ test/
flutter analyze
git add lib/services/item_image_fetcher.dart test/services/item_image_fetcher_test.dart
git commit -m "feat(item-image): add encoreLang whitelist mapping helper"
```

---

## Task 2：`EncoreCatalog` ＋ `fetchCatalog`（列表查 icon）

**Files:**
- Modify: `lib/services/item_image_fetcher.dart`
- Test: `test/services/item_image_fetcher_test.dart`

- [ ] **Step 1: 寫失敗測試**（新 group；先在檔案頂端 import kind 常數）

於 `test/services/item_image_fetcher_test.dart` 的 import 區加：
```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
```

新增 helper 與 group：
```dart
/// 組 encore 列表回應（roleList / weapons / itemList）。
http.Response _catalogList(String kindSeg) {
  final body = switch (kindSeg) {
    'character' => {
      'roleList': [
        {'Id': 1503, 'RoleHeadIcon': 'https://x/role_1503.webp'},
        {'Id': 1402, 'RoleHeadIcon': 'https://x/role_1402.webp'},
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
http.Client _catalogClient({
  Set<String> failKinds = const {},
  List<String>? seenKinds,
}) {
  return MockClient((req) async {
    final seg = req.url.pathSegments; // [api, {lang}, {kindSeg}]
    final kindSeg = seg.length >= 3 ? seg[2] : '';
    seenKinds?.add(kindSeg);
    if (failKinds.contains(kindSeg)) return http.Response('', 503);
    return _catalogList(kindSeg);
  });
}

group('ItemImageFetcher.fetchCatalog', () {
  test('解析 character/weapon/item 的 icon URL，iconFor 命中', () async {
    final cat = await ItemImageFetcher().fetchCatalog(
      lang: 'zh-Hant',
      kinds: {kItemKindCharacter, kItemKindWeapon, kItemKindItem},
      client: _catalogClient(),
    );
    expect(cat.iconFor(kind: kItemKindCharacter, id: 1503),
        'https://x/role_1503.webp');
    expect(cat.iconFor(kind: kItemKindWeapon, id: 21010074),
        'https://x/wpn_21010074.webp');
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
      lang: 'xx', kinds: {kItemKindCharacter}, client: client,
    );
    expect(seenLangs, ['en']);
  });
});
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `flutter test test/services/item_image_fetcher_test.dart -n fetchCatalog`
Expected: FAIL（`fetchCatalog`／`EncoreCatalog` 未定義）

- [ ] **Step 3: 實作**（`lib/services/item_image_fetcher.dart`）

於 import 區加：
```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
```

於檔案頂部加常數＋class：
```dart
/// encore API base（list／detail 共用）。
const _encoreApiBase = 'https://api-v2.encore.moe/api';

/// kind → encore 端點路徑段。
const _kindToSegment = {
  kItemKindCharacter: 'character',
  kItemKindWeapon: 'weapon',
  kItemKindItem: 'item',
};

/// 單一 lang 的 encore 列表查表結果：kind → (resourceId → icon URL)。
class EncoreCatalog {
  /// 建立 [EncoreCatalog]。
  const EncoreCatalog({required this.iconByKindId});

  /// kind（`kItemKind*`）→ `{resourceId → iconUrl}`。
  final Map<String, Map<int, String>> iconByKindId;

  /// 查 [kind] 的 [id] 對應 icon URL；查無回 null。
  String? iconFor({required String kind, required int id}) =>
      iconByKindId[kind]?[id];
}
```

在 `ItemImageFetcher` class 內（`downloadImage` 前）加：
```dart
/// 對 [kinds] 內每個 kind 打 encore 列表端點一次，組 [EncoreCatalog]。
///
/// 單一 kind 端點失敗（非 2xx／逾時／解析爛）→ 該 kind 回空 map（不 throw），
/// 該 kind 物品交由呼叫端落負取。
Future<EncoreCatalog> fetchCatalog({
  required String lang,
  required Set<String> kinds,
  required http.Client client,
}) async {
  final out = <String, Map<int, String>>{};
  final encLang = encoreLang(lang);
  for (final kind in kinds) {
    final seg = _kindToSegment[kind];
    if (seg == null) continue;
    out[kind] = await _fetchCatalogKind(
      lang: encLang,
      kind: kind,
      seg: seg,
      client: client,
    );
  }
  return EncoreCatalog(iconByKindId: out);
}

/// 抓單一 kind 的列表並解析 `{id → iconUrl}`；任何失敗回空 map。
Future<Map<int, String>> _fetchCatalogKind({
  required String lang,
  required String kind,
  required String seg,
  required http.Client client,
}) async {
  final url = Uri.parse('$_encoreApiBase/$lang/$seg');
  try {
    final res = await client.get(url).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _log.warning(
        'catalog kind=$seg non-2xx status=${res.statusCode} lang=$lang',
      );
      return const {};
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final (listKey, iconKey) = switch (kind) {
      kItemKindCharacter => ('roleList', 'RoleHeadIcon'),
      kItemKindWeapon => ('weapons', 'Icon'),
      _ => ('itemList', 'Icon'),
    };
    final list = body[listKey];
    if (list is! List) return const {};
    final map = <int, String>{};
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      final id = e['Id'];
      final icon = e[iconKey];
      if (id is int && icon is String && icon.isNotEmpty) map[id] = icon;
    }
    _log.info('catalog kind=$seg lang=$lang n=${map.length}');
    return map;
  } catch (e) {
    _log.warning('catalog kind=$seg failed lang=$lang err=$e');
    return const {};
  }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `flutter test test/services/item_image_fetcher_test.dart -n fetchCatalog`
Expected: PASS

- [ ] **Step 5: 品質檢查＋commit**

```bash
dart format lib/ test/
flutter analyze
git add lib/services/item_image_fetcher.dart test/services/item_image_fetcher_test.dart
git commit -m "feat(item-image): add EncoreCatalog + fetchCatalog list lookup"
```

---

## Task 3：`EncoreItemDetail` ＋ `fetchItemDetail`（詳情解析）

**Files:**
- Modify: `lib/services/item_image_fetcher.dart`
- Test: `test/services/item_image_fetcher_test.dart`

- [ ] **Step 1: 寫失敗測試**（新 group）

```dart
group('ItemImageFetcher.fetchItemDetail', () {
  http.Client detailClient(Map<String, dynamic> body, {int status = 200}) =>
      MockClient((_) async => http.Response.bytes(
            utf8.encode(jsonEncode(body)), status,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));

  test('角色：解析 intro/element/weaponType/illustration', () async {
    final d = await ItemImageFetcher().fetchItemDetail(
      resourceId: 1503, kind: kItemKindCharacter, lang: 'zh-Hant',
      client: detailClient({
        'Introduction': {'Content': '簡介文字'},
        'ElementName': '衍射',
        'WeaponTypeName': '音感儀',
        'Skins': [
          {'PreviewRoleCard': 'https://x/illust_1503.webp'},
        ],
      }),
    );
    expect(d, isNotNull);
    expect(d!.intro, '簡介文字');
    expect(d.elementName, '衍射');
    expect(d.weaponTypeName, '音感儀');
    expect(d.illustrationUrl, 'https://x/illust_1503.webp');
  });

  test('武器：解析 BgDescription（含 HTML 原樣）/weaponType，element/illustration 空', () async {
    final d = await ItemImageFetcher().fetchItemDetail(
      resourceId: 21010074, kind: kItemKindWeapon, lang: 'zh-Hant',
      client: detailClient({
        'BgDescription': '此刃<br>為禮儀<te>用器</te>',
        'WeaponTypeName': '長刃',
      }),
    );
    expect(d, isNotNull);
    expect(d!.intro, '此刃<br>為禮儀<te>用器</te>');
    expect(d.weaponTypeName, '長刃');
    expect(d.elementName, '');
    expect(d.illustrationUrl, '');
  });

  test('道具 kind 不打 API → 回 null', () async {
    var called = false;
    final client = MockClient((_) async {
      called = true;
      return http.Response('', 200);
    });
    final d = await ItemImageFetcher().fetchItemDetail(
      resourceId: 3, kind: kItemKindItem, lang: 'zh-Hant', client: client,
    );
    expect(d, isNull);
    expect(called, isFalse);
  });

  test('404 → null（不 throw）', () async {
    final d = await ItemImageFetcher().fetchItemDetail(
      resourceId: 1503, kind: kItemKindCharacter, lang: 'zh-Hant',
      client: detailClient(const {}, status: 404),
    );
    expect(d, isNull);
  });

  test('非 JSON → null（不 throw）', () async {
    final d = await ItemImageFetcher().fetchItemDetail(
      resourceId: 1503, kind: kItemKindCharacter, lang: 'zh-Hant',
      client: MockClient((_) async => http.Response('{not json', 200)),
    );
    expect(d, isNull);
  });

  test('角色缺欄位 → 對應欄空字串、不 throw', () async {
    final d = await ItemImageFetcher().fetchItemDetail(
      resourceId: 1503, kind: kItemKindCharacter, lang: 'zh-Hant',
      client: detailClient({'ElementName': '衍射'}),
    );
    expect(d, isNotNull);
    expect(d!.intro, '');
    expect(d.elementName, '衍射');
    expect(d.illustrationUrl, '');
  });
});
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `flutter test test/services/item_image_fetcher_test.dart -n fetchItemDetail`
Expected: FAIL（未定義）

- [ ] **Step 3: 實作**（`lib/services/item_image_fetcher.dart`）

於檔案頂部（`EncoreCatalog` 後）加：
```dart
/// dialog 用的單一 lang 詳情（只取原神版版面所需欄位）。
class EncoreItemDetail {
  /// 建立 [EncoreItemDetail]。
  const EncoreItemDetail({
    required this.intro,
    required this.elementName,
    required this.weaponTypeName,
    required this.illustrationUrl,
  });

  /// 簡介：角色 `Introduction.Content`／武器 `BgDescription`（可能含 HTML）。
  final String intro;

  /// 元素名：角色 `ElementName`；武器／道具為空。
  final String elementName;

  /// 武器類型名：角色／武器 `WeaponTypeName`；道具為空。
  final String weaponTypeName;

  /// 立繪 URL：角色 `Skins[0].PreviewRoleCard`；武器／道具為空。
  final String illustrationUrl;
}
```

在 `ItemImageFetcher` class 內加：
```dart
/// 抓 [resourceId] 的 encore 詳情（角色／武器）解析 [EncoreItemDetail]。
///
/// `kItemKindItem` 不打 API（道具 id 與 `/item` 體系不符）直接回 null；HTTP 非
/// 2xx／逾時／解析爛一律回 null（不 throw），呼叫端據此不寫 `detailByLang`。
Future<EncoreItemDetail?> fetchItemDetail({
  required int resourceId,
  required String kind,
  required String lang,
  required http.Client client,
}) async {
  final seg = _kindToSegment[kind];
  if (seg == null || kind == kItemKindItem) return null;
  final encLang = encoreLang(lang);
  final url = Uri.parse('$_encoreApiBase/$encLang/$seg/$resourceId');
  try {
    final res = await client.get(url).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _log.warning(
        'detail kind=$seg id=$resourceId non-2xx status=${res.statusCode} '
        'lang=$encLang',
      );
      return null;
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final String intro;
    final String illustration;
    if (kind == kItemKindCharacter) {
      final intoObj = body['Introduction'];
      intro = (intoObj is Map<String, dynamic>)
          ? (intoObj['Content'] as String? ?? '')
          : '';
      final skins = body['Skins'];
      illustration = (skins is List && skins.isNotEmpty &&
              skins.first is Map<String, dynamic>)
          ? ((skins.first as Map<String, dynamic>)['PreviewRoleCard']
                  as String? ??
              '')
          : '';
    } else {
      intro = body['BgDescription'] as String? ?? '';
      illustration = '';
    }
    final detail = EncoreItemDetail(
      intro: intro,
      elementName: body['ElementName'] as String? ?? '',
      weaponTypeName: body['WeaponTypeName'] as String? ?? '',
      illustrationUrl: illustration,
    );
    _log.info(
      'detail hit kind=$seg id=$resourceId lang=$encLang '
      'intro=${intro.isNotEmpty} illustration=${illustration.isNotEmpty}',
    );
    return detail;
  } catch (e) {
    _log.warning('detail kind=$seg id=$resourceId failed lang=$encLang err=$e');
    return null;
  }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `flutter test test/services/item_image_fetcher_test.dart -n fetchItemDetail`
Expected: PASS

- [ ] **Step 5: 品質檢查＋commit**

```bash
dart format lib/ test/
flutter analyze
git add lib/services/item_image_fetcher.dart test/services/item_image_fetcher_test.dart
git commit -m "feat(item-image): add EncoreItemDetail + fetchItemDetail parser"
```

---

## Task 4：索引資料模型 — `ItemDetailL10n` ＋ `detailByLang` ＋ storage v2 ＋ `mergeItemDetail`（純加法）

> 本 task 只做加法（不刪 `illustrationUrl`），保持既有 constructor／測試可編譯。`illustrationUrl` 改為**選填**（預設 null），讓後續新程式可省略它，最終於 Task 8 移除。

**Files:**
- Modify: `lib/services/item_image_index.dart`
- Modify: `lib/state/item_image_index.dart`
- Test: `test/services/item_image_index_test.dart`、`test/state/item_image_index_test.dart`

- [ ] **Step 1: 寫失敗測試（services）** — 加在 `test/services/item_image_index_test.dart` 的 `ItemImageIndexStorage` group 內

```dart
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
            illustrationUrl: 'https://x/illust.webp',
          ),
          'en': ItemDetailL10n(
            intro: 'Intro',
            elementName: 'Spectro',
            weaponTypeName: 'Rectifier',
            illustrationUrl: 'https://x/illust.webp',
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
});

test('v1（無 detail_by_lang）載入 → detailByLang 空、其餘欄位保留', () async {
  final f = File('${tempDir.path}/item_image_index.json');
  await f.writeAsString(jsonEncode({
    'version': 1,
    'items': {
      '1503': {
        'icon_url': 'https://x/role_1503.webp',
        'illustration_url': 'https://x/old_illust.webp',
        'no_image': false,
        'permanent_no_image': false,
      },
    },
  }));
  final loaded = await storage.load();
  final e = loaded.lookupImage(1503)!;
  expect(e.iconUrl, 'https://x/role_1503.webp');
  expect(e.detailByLang, isEmpty);
});
```

- [ ] **Step 2: 寫失敗測試（state notifier）** — 加在 `test/state/item_image_index_test.dart`

```dart
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
      intro: '簡介', elementName: '衍射',
      weaponTypeName: '音感儀', illustrationUrl: 'https://x/i.webp',
    ),
  );
  final e = container.read(itemImageIndexProvider).lookupImage(1503)!;
  expect(e.iconUrl, 'https://x/role.webp');
  expect(e.detailByLang['zh-Hant']!.intro, '簡介');
});

test('mergeItemDetail 跨 lang 不互蓋', () async {
  final notifier = container.read(itemImageIndexProvider.notifier);
  await notifier.mergeItemDetail(
    resourceId: 1503, lang: 'zh-Hant',
    detail: const ItemDetailL10n(
      intro: 'A', elementName: '', weaponTypeName: '', illustrationUrl: ''),
  );
  await notifier.mergeItemDetail(
    resourceId: 1503, lang: 'en',
    detail: const ItemDetailL10n(
      intro: 'B', elementName: '', weaponTypeName: '', illustrationUrl: ''),
  );
  final e = container.read(itemImageIndexProvider).lookupImage(1503)!;
  expect(e.detailByLang['zh-Hant']!.intro, 'A');
  expect(e.detailByLang['en']!.intro, 'B');
});
```

> 註：上述測試呼叫 `mergeIcon`（本 task 新增的別名/新方法）。本 task **新增** `mergeIcon`（內部沿用既有 `mergeItemImage` 邏輯），暫不移除 `mergeItemImage`（Task 8 才移除舊名）。

- [ ] **Step 3: 跑測試確認失敗**

Run: `flutter test test/services/item_image_index_test.dart test/state/item_image_index_test.dart`
Expected: FAIL（`ItemDetailL10n`／`detailByLang`／`mergeIcon`／`mergeItemDetail` 未定義）

- [ ] **Step 4: 實作 `lib/services/item_image_index.dart`**

新增 class（`ItemImageEntry` 前）：
```dart
/// 單一 lang 的 dialog 詳情（持久化於 index）。
class ItemDetailL10n {
  /// 建立 [ItemDetailL10n]。
  const ItemDetailL10n({
    required this.intro,
    required this.elementName,
    required this.weaponTypeName,
    required this.illustrationUrl,
  });

  /// 簡介（角色 Introduction／武器 BgDescription，可能含 HTML）。
  final String intro;

  /// 元素名（角色；武器／道具空）。
  final String elementName;

  /// 武器類型名（角色／武器；道具空）。
  final String weaponTypeName;

  /// 立繪 URL（角色；武器／道具空）。
  final String illustrationUrl;

  /// 由 storage JSON 還原。
  factory ItemDetailL10n.fromJson(Map<String, dynamic> j) => ItemDetailL10n(
    intro: j['intro'] as String? ?? '',
    elementName: j['element_name'] as String? ?? '',
    weaponTypeName: j['weapon_type_name'] as String? ?? '',
    illustrationUrl: j['illustration_url'] as String? ?? '',
  );

  /// 寫入 storage JSON。
  Map<String, dynamic> toJson() => {
    'intro': intro,
    'element_name': elementName,
    'weapon_type_name': weaponTypeName,
    'illustration_url': illustrationUrl,
  };
}
```

`ItemImageEntry` 改：加 `detailByLang`、`illustrationUrl` 改選填：
```dart
class ItemImageEntry {
  /// 建立 [ItemImageEntry]。
  const ItemImageEntry({
    required this.iconUrl,
    this.illustrationUrl, // Task 8 將移除；本 task 起改選填
    required this.noImage,
    required this.permanentNoImage,
    this.detailByLang = const {},
  });

  /// 角色 icon 小圖 CDN URL；負取時為 null。
  final String? iconUrl;

  /// （已棄用，Task 8 移除）舊版立繪 URL，立繪改存 [detailByLang]。
  final String? illustrationUrl;

  /// 負取標記。
  final bool noImage;

  /// 永久負取標記。
  final bool permanentNoImage;

  /// 各語言 dialog 詳情；key 為擷取 languageCode。某 lang 不在 map = 尚未抓。
  final Map<String, ItemDetailL10n> detailByLang;

  /// 是否有可顯示的成功 icon。
  bool get hasIcon => !noImage && iconUrl != null && iconUrl!.isNotEmpty;
}
```

`ItemImageIndexStorage.load` 解析加 `detail_by_lang`：
```dart
items[id] = ItemImageEntry(
  iconUrl: v['icon_url'] as String?,
  illustrationUrl: v['illustration_url'] as String?,
  noImage: (v['no_image'] as bool?) ?? false,
  permanentNoImage: (v['permanent_no_image'] as bool?) ?? false,
  detailByLang: _detailByLangFromJson(v['detail_by_lang']),
);
```

在檔案底部（`_extFromUrl` 旁）加 helper：
```dart
/// 從 storage JSON 還原 `detail_by_lang`；缺/型別不符回空 map。
Map<String, ItemDetailL10n> _detailByLangFromJson(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, ItemDetailL10n>{};
  raw.forEach((k, v) {
    if (k is String && v is Map<String, dynamic>) {
      out[k] = ItemDetailL10n.fromJson(v);
    }
  });
  return out;
}
```

`ItemImageIndexStorage.save` bump version、寫 `detail_by_lang`：
```dart
final json = {
  'version': 2,
  'items': index.items.map(
    (k, v) => MapEntry('$k', {
      'icon_url': v.iconUrl,
      'illustration_url': v.illustrationUrl,
      'no_image': v.noImage,
      'permanent_no_image': v.permanentNoImage,
      'detail_by_lang': v.detailByLang.map((l, d) => MapEntry(l, d.toJson())),
    }),
  ),
};
```

- [ ] **Step 5: 實作 `lib/state/item_image_index.dart`**

新增 `mergeIcon`（與既有 `mergeItemImage` 並存；保留既有 `detailByLang`）：
```dart
/// 寫入單一 resourceId 的 icon 抓取結果並 persist（保留既有 detailByLang）。
Future<void> mergeIcon({
  required int resourceId,
  required String? iconUrl,
  required bool noImage,
  required bool permanentNoImage,
}) async {
  await _lock.synchronized(() async {
    final prev = state.items[resourceId];
    final newItems = Map<int, ItemImageEntry>.from(state.items)
      ..[resourceId] = ItemImageEntry(
        iconUrl: iconUrl,
        noImage: noImage,
        permanentNoImage: permanentNoImage,
        detailByLang: prev?.detailByLang ?? const {},
      );
    await _saveAndEmit(ItemImageIndex(items: newItems));
    _log.fine(
      'mergeIcon resourceId=$resourceId noImage=$noImage '
      'hasIcon=${iconUrl?.isNotEmpty == true}',
    );
  });
}

/// 寫入單一 (resourceId, lang) 的 dialog 詳情並 persist（保留既有 icon）。
Future<void> mergeItemDetail({
  required int resourceId,
  required String lang,
  required ItemDetailL10n detail,
}) async {
  await _lock.synchronized(() async {
    final prev = state.items[resourceId];
    final mergedDetail = <String, ItemDetailL10n>{
      if (prev != null) ...prev.detailByLang,
      lang: detail,
    };
    final newItems = Map<int, ItemImageEntry>.from(state.items)
      ..[resourceId] = ItemImageEntry(
        iconUrl: prev?.iconUrl,
        noImage: prev?.noImage ?? false,
        permanentNoImage: prev?.permanentNoImage ?? false,
        detailByLang: mergedDetail,
      );
    await _saveAndEmit(ItemImageIndex(items: newItems));
    _log.fine(
      'merge detail id=$resourceId lang=$lang intro=${detail.intro.isNotEmpty}',
    );
  });
}
```

- [ ] **Step 6: 跑測試確認通過**

Run: `flutter test test/services/item_image_index_test.dart test/state/item_image_index_test.dart`
Expected: PASS（既有測試＋新測試皆綠；既有 `mergeItemImage` 測試仍在、未動）

- [ ] **Step 7: 品質檢查＋commit**

```bash
dart format lib/ test/
flutter analyze
git add lib/services/item_image_index.dart lib/state/item_image_index.dart test/services/item_image_index_test.dart test/state/item_image_index_test.dart
git commit -m "feat(item-image): add per-lang ItemDetailL10n to index (storage v2)"
```

---

## Task 5：Repository `_fetchItemImages` 改 catalog 查表 ＋ 詳情預抓

**Files:**
- Modify: `lib/state/gacha_repository.dart`（`_fetchItemImages`，約 860-986 行）
- Test: `test/state/gacha_repository_item_image_test.dart`

- [ ] **Step 1: 改寫測試 fake fetcher＋既有案例**

把 `test/state/gacha_repository_item_image_test.dart` 的 `_FakeFetcher` 改為 override 新 API：
```dart
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
    return EncoreCatalog(iconByKindId: {
      kItemKindCharacter: {for (final id in characters) id: 'https://x/$id.png'},
      kItemKindWeapon: {for (final id in weapons) id: 'https://x/$id.png'},
    });
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
      illustrationUrl: 'https://x/${resourceId}_i.png',
    );
  }
}
```

import 區補：
```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
```

把建構 fake 的呼叫從 `_FakeFetcher(characters)` 改為具名（各既有測試）：
- 「角色寫正取…」：`_FakeFetcher(characters: {1211}, details: {1211})`，斷言加 `expect(index.lookupImage(1211)!.detailByLang['zh-Hant']!.intro, 'intro-zh-Hant-1211');`
- 「正取者第二次跑不重抓…」：原案已把 21010024 seed 為 `_rec(21010024, 4, '武器')`，故 fake 改 `_FakeFetcher(characters: {1211}, weapons: {21010024})`（武器要放 `weapons` 才會在 weapon catalog 命中）。斷言 `index.lookupImage(21010024)!.hasIcon` 不變。
- 進度兩階段、全查無圖、R18：fake 用 `_FakeFetcher(characters: {...})`／`<int>{}` 對應。

新增一條 per-lang 預抓測試：
```dart
test('詳情逐 (id, lang) 預抓：多語言帳號各存一份', () async {
  final container = build2(characters: {1503}, details: {1503});
  addTearDown(container.dispose);
  final repo = container.read(gachaRepositoryProvider.notifier);
  await repo.waitForBootstrap();
  repo.debugSeedAccount(BannerStorage(
    playerId: '701000001', languageCode: 'zh-Hant',
    lastUpdated: DateTime.utc(2026),
    banners: {'1': [_rec(1503, 5, '角色')]},
  ));
  repo.debugSeedAccount(BannerStorage(
    playerId: '701000002', languageCode: 'en',
    lastUpdated: DateTime.utc(2026),
    banners: {'1': [_rec(1503, 5, 'Character')]},
  ));
  await repo.debugRunItemImagesOnly();
  final e = container.read(itemImageIndexProvider).lookupImage(1503)!;
  expect(e.detailByLang.keys.toSet(), {'zh-Hant', 'en'});
});
```

> `build2` ＝ 既有 `build` 改為接受 `{characters, weapons, details}` 並 `_FakeFetcher(characters: characters, weapons: weapons, details: details)`。把既有 `build({required Set<int> characters})` 簽名改為 `build({Set<int> characters = const {}, Set<int> weapons = const {}, Set<int> details = const {}})`，並把 `_FakeFetcher(characters)` 換成具名建構；測試內 `build(...)` 呼叫沿用即可（上面新測試用同一 `build`，不需另立 `build2` —— 直接用 `build`）。

- [ ] **Step 2: 跑測試確認失敗**

Run: `flutter test test/state/gacha_repository_item_image_test.dart`
Expected: FAIL（`_fetchItemImages` 仍呼叫舊 `fetchItemImages`；catalog/detail 未被使用、`detailByLang` 為空）

- [ ] **Step 3: 改寫 `_fetchItemImages`**（`lib/state/gacha_repository.dart`）

於 import 區確認有 `item_type_kind.dart`（若無則加）：
```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
```

把 `_fetchItemImages` 整個 method body 換成：
```dart
Future<int> _fetchItemImages(http.Client client) async {
  var downloaded = 0;
  final fetcher = ref.read(itemImageFetcherProvider);
  final indexNotifier = ref.read(itemImageIndexProvider.notifier);
  final cacheDir = ref.read(itemImageCacheDirProvider);
  await indexNotifier.waitForLoad();

  // (1) 收集 (id → (kind, langs))；同 id 跨帳號彙整所有出現過的 lang。
  final kindById = <int, String>{};
  final langsById = <int, Set<String>>{};
  for (final data in state.byUid.values) {
    final lang = data.languageCode;
    if (lang.isEmpty) continue;
    for (final list in data.banners.values) {
      for (final r in list) {
        kindById[r.resourceId] = itemTypeKeyOf(r);
        langsById.putIfAbsent(r.resourceId, () => {}).add(lang);
      }
    }
  }

  // (2) worklist：(id, kind, lang) —— icon 未就緒，或該 lang 詳情未抓。
  final index = ref.read(itemImageIndexProvider);
  final worklist = <(int id, String kind, String lang)>[];
  for (final entry in langsById.entries) {
    final id = entry.key;
    final kind = kindById[id]!;
    final existing = index.lookupImage(id);
    final iconNeeded = needsItemImageFetch(
      existing: existing,
      cacheDir: cacheDir,
      resourceId: id,
    );
    for (final lang in entry.value) {
      final detailMissing = kind != kItemKindItem &&
          !(existing?.detailByLang.containsKey(lang) ?? false);
      if (iconNeeded || detailMissing) worklist.add((id, kind, lang));
    }
  }
  if (worklist.isEmpty) return downloaded;

  bool isAborted() => !ref.mounted || _cancelTriggered;

  // (3a) 逐 distinct lang 序列抓 catalog（icon 來源；同 lang 一次，無 race）。
  final toDownload = <(int id, String iconUrl)>[];
  final catalogByLang = <String, EncoreCatalog>{};
  for (final lang in worklist.map((w) => w.$3).toSet()) {
    if (isAborted()) return downloaded;
    catalogByLang[lang] = await fetcher.fetchCatalog(
      lang: lang,
      kinds: worklist.where((w) => w.$3 == lang).map((w) => w.$2).toSet(),
      client: client,
    );
  }

  // (3b) 序列解析每個 id 的 icon（catalog 純查表、無 HTTP）；收集正取 id。
  // icon 為 lang-agnostic，任一出現過的 lang 的 catalog 皆可查。
  final positiveIds = <int>{};
  for (final id in langsById.keys) {
    final kind = kindById[id]!;
    final existing = index.lookupImage(id);
    if (!needsItemImageFetch(
      existing: existing,
      cacheDir: cacheDir,
      resourceId: id,
    )) {
      if (existing?.hasIcon ?? false) positiveIds.add(id);
      continue;
    }
    final lang = langsById[id]!.first;
    final iconUrl = catalogByLang[lang]?.iconFor(kind: kind, id: id);
    if (iconUrl != null) {
      await indexNotifier.mergeIcon(
        resourceId: id,
        iconUrl: iconUrl,
        noImage: false,
        permanentNoImage: false,
      );
      toDownload.add((id, iconUrl));
      positiveIds.add(id);
    } else {
      await indexNotifier.mergeIcon(
        resourceId: id,
        iconUrl: null,
        noImage: true,
        permanentNoImage: false,
      );
    }
  }

  // (3c) 並行：逐 (id, lang) 預抓詳情（icon 正取、非道具、該 lang 未抓）。
  // checking 進度對所有 worklist triple 計數（全負取情境也會 emit checking）。
  var checkedDone = 0;
  await runConcurrent<(int, String, String)>(
    items: worklist,
    concurrency: fetcher.downloadConcurrency,
    shouldAbort: isAborted,
    worker: (item) async {
      final (id, kind, lang) = item;
      try {
        final detailAlready = ref
                .read(itemImageIndexProvider)
                .lookupImage(id)
                ?.detailByLang
                .containsKey(lang) ??
            false;
        if (positiveIds.contains(id) &&
            kind != kItemKindItem &&
            !detailAlready) {
          final detail = await fetcher.fetchItemDetail(
            resourceId: id,
            kind: kind,
            lang: lang,
            client: client,
          );
          if (detail != null) {
            await indexNotifier.mergeItemDetail(
              resourceId: id,
              lang: lang,
              detail: ItemDetailL10n(
                intro: detail.intro,
                elementName: detail.elementName,
                weaponTypeName: detail.weaponTypeName,
                illustrationUrl: detail.illustrationUrl,
              ),
            );
          }
        }
      } catch (e) {
        _log.warning('item detail fetch failed id=$id lang=$lang err=$e');
      }
      if (!ref.mounted) return;
      checkedDone++;
      state = state.copyWith(
        progress: FetchingItemImages(
          phase: ItemImagePhase.checking,
          doneCount: checkedDone,
          totalCount: worklist.length,
        ),
      );
    },
  );

  // (4) 下載階段：只下載 icon（立繪走 dialog lazy）。
  if (toDownload.isEmpty || isAborted()) return downloaded;
  var downloadedDone = 0;
  await runConcurrent<(int, String)>(
    items: toDownload,
    concurrency: fetcher.downloadConcurrency,
    shouldAbort: isAborted,
    worker: (item) async {
      final (id, iconUrl) = item;
      try {
        final iconBytes = await fetcher.downloadImage(iconUrl, client);
        if (iconBytes != null) {
          final file = itemIconCacheFile(
            baseDir: cacheDir,
            resourceId: id,
            url: iconUrl,
          );
          await writeImageFileAtomic(file, iconBytes);
          indexNotifier.bumpCacheRevision();
          downloaded++;
        }
      } catch (e) {
        _log.warning('item icon download failed id=$id err=$e');
      }
      if (!ref.mounted) return;
      downloadedDone++;
      state = state.copyWith(
        progress: FetchingItemImages(
          phase: ItemImagePhase.downloading,
          doneCount: downloadedDone,
          totalCount: toDownload.length,
        ),
      );
    },
  );
  return downloaded;
}
```

於 import 區確認有 `ItemDetailL10n`（來自 `services/item_image_index.dart`，既有 import）。

> **註（結構）**：catalog 在 (3a) 序列抓、icon 在 (3b) 序列查表決定，故 `toDownload`／`positiveIds`／`mergeIcon` 都無並行 race；只有 (3c) 詳情抓取並行（彼此 (id,lang) 互異、`mergeItemDetail` 有 `_lock`）。`langsById`／`kindById`／`worklist` 為 (1)(2) 既算好的不可變集合。

- [ ] **Step 4: 跑測試確認通過**

Run: `flutter test test/state/gacha_repository_item_image_test.dart`
Expected: PASS

- [ ] **Step 5: 品質檢查＋commit**

```bash
dart format lib/ test/
flutter analyze
git add lib/state/gacha_repository.dart test/state/gacha_repository_item_image_test.dart
git commit -m "feat(item-image): repository fetches via encore catalog + prefetch detail"
```

---

## Task 6：pubspec `flutter_html` ＋ ARB `actionViewOnEncore` ＋ `encoreItemUrl`

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/l10n/app_zh.arb`、`app_zh_Hans.arb`、`app_en.arb`、`app_ja.arb`
- Modify: `lib/services/item_image_fetcher.dart`（`encoreItemUrl`）
- Test: `test/services/item_image_fetcher_test.dart`

- [ ] **Step 1: 加 flutter_html 依賴**

```bash
flutter pub add flutter_html
```
若解析失敗（SDK 相容性），改在 `pubspec.yaml` 的 `dependencies:` 手動加 `flutter_html: ^3.0.0`（遷移前 baseline 版本）後 `flutter pub get`。必要時依 context7 查當前相容版：
```bash
npx ctx7@latest library "flutter_html" "current version compatible with Flutter 3.x"
```

- [ ] **Step 2: 加 ARB key**（先查 `l10n.yaml` 的 `template-arb-file`，模板檔須最先加）

於 `lib/l10n/app_zh.arb`（與其他 3 個實譯 ARB）的適當位置加：
```json
"actionViewOnEncore": "在 encore.moe 查看",
"@actionViewOnEncore": {
  "description": "Item detail dialog actions: external link button to open the item's encore.moe page. 'encore.moe' is a brand name, do not translate."
},
```
各語系建議譯：`app_en` → `"View on encore.moe"`；`app_ja` → `"encore.moe で見る"`；`app_zh_Hans` → `"在 encore.moe 查看"`。

跑 `flutter pub get`（觸發 `gen-l10n`）後確認 `l.actionViewOnEncore` 可用：
```bash
flutter pub get
flutter analyze
```

- [ ] **Step 3: 寫 `encoreItemUrl` 失敗測試**

```dart
group('encoreItemUrl', () {
  test('角色 id-based ＋ lang query', () {
    expect(
      encoreItemUrl(kind: kItemKindCharacter, resourceId: 1503, lang: 'zh-Hant'),
      'https://encore.moe/character/1503?lang=zh-Hant',
    );
  });
  test('武器 → /weapon', () {
    expect(
      encoreItemUrl(kind: kItemKindWeapon, resourceId: 21010074, lang: 'en'),
      'https://encore.moe/weapon/21010074?lang=en',
    );
  });
  test('未知 lang fallback en', () {
    expect(
      encoreItemUrl(kind: kItemKindCharacter, resourceId: 1, lang: 'xx'),
      'https://encore.moe/character/1?lang=en',
    );
  });
});
```

- [ ] **Step 4: 跑測試確認失敗**

Run: `flutter test test/services/item_image_fetcher_test.dart -n encoreItemUrl`
Expected: FAIL（未定義）

- [ ] **Step 5: 實作 `encoreItemUrl`**（`lib/services/item_image_fetcher.dart`，`encoreLang` 旁）

```dart
/// 組該物品的 encore.moe 前台頁 URL（id-based ＋ `?lang=`，已驗證可用）。
/// 角色 `/character/{id}`、武器 `/weapon/{id}`、道具 `/item/{id}`（道具一般不可點）。
String encoreItemUrl({
  required String kind,
  required int resourceId,
  required String lang,
}) {
  final seg = switch (kind) {
    kItemKindWeapon => 'weapon',
    kItemKindItem => 'item',
    _ => 'character',
  };
  return 'https://encore.moe/$seg/$resourceId?lang=${encoreLang(lang)}';
}
```

- [ ] **Step 6: 跑測試確認通過＋全測試**

Run: `flutter test test/services/item_image_fetcher_test.dart -n encoreItemUrl`
Expected: PASS

- [ ] **Step 7: 品質檢查＋commit**

```bash
dart format lib/ test/
flutter analyze
flutter test
git add pubspec.yaml pubspec.lock lib/l10n/ lib/services/item_image_fetcher.dart test/services/item_image_fetcher_test.dart
git commit -m "feat(item-image): add flutter_html dep, encore link key + encoreItemUrl"
```

---

## Task 7：Dialog 加回簡介 ＋ tag ＋ 外連（讀 `detailByLang[activeLang]`）

**Files:**
- Modify: `lib/state/gacha_repository.dart`（加 `activeLanguageCodeProvider`）
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`
- Test: `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`

- [ ] **Step 1: 加 `activeLanguageCodeProvider`**（`lib/state/gacha_repository.dart`，`gachaRepositoryProvider` 之後）

```dart
/// 作用中帳號的擷取語言（無帳號時 null）；dialog 用來查 per-lang 詳情。
final activeLanguageCodeProvider = Provider<String?>(
  (ref) =>
      ref.watch(gachaRepositoryProvider.select((s) => s.activeData?.languageCode)),
);
```

- [ ] **Step 2: 改寫 widget 測試**（`test/widgets/dialogs/gacha_item_detail_dialog_test.dart`）

以 fake index（含 `detailByLang`）＋ `activeLanguageCodeProvider` override 驗證新版。核心案例（沿用既有測試骨架的 `ProviderScope.overrides`、temp dir、預製假圖檔；參考既有檔內 helper）：

```dart
testWidgets('角色：簡介(Html)＋tag(★/元素/武器類型)＋立繪/頭像 chip', (tester) async {
  // 預置 index：1503 正取 icon ＋ zh-Hant 詳情；temp dir 放好 icon 檔。
  // override activeLanguageCodeProvider = 'zh-Hant'。
  // pump GachaItemDetailDialog(record: _rec(1503,5,'角色'))。
  await tester.pumpAndSettle();
  expect(find.byType(Html), findsWidgets);            // 簡介
  expect(find.widgetWithText(Chip, '5★'), findsOneWidget); // l.rarityStar(5)
  expect(find.widgetWithText(Chip, '衍射'), findsOneWidget);
  expect(find.widgetWithText(Chip, '音感儀'), findsOneWidget);
  expect(find.text('立繪'), findsOneWidget);          // chip label
  expect(find.text('圖示'), findsOneWidget);          // icon chip label
});

testWidgets('武器：只有 Icon chip（隱藏 chip 列）＋tag 無元素', (tester) async {
  // 1503 換成武器：detailByLang 給 weaponTypeName='長刃'、elementName=''、illustrationUrl=''
  // chip 只有 icon → 不顯示 ChoiceChip 列。
  await tester.pumpAndSettle();
  expect(find.widgetWithText(Chip, '長刃'), findsOneWidget);
  expect(find.byType(ChoiceChip), findsNothing);
});

testWidgets('active lang 無詳情、他 lang 有 → 退 firstOrNull 顯示', (tester) async {
  // detailByLang 只有 'en'，activeLanguageCodeProvider='zh-Hant' → 顯示 en 詳情。
  await tester.pumpAndSettle();
  expect(find.byType(Html), findsWidgets);
});

testWidgets('外連按鈕：點擊呼叫 openExternalUrl 且 URL 為 encore item URL', (tester) async {
  // 以可注入的方式驗證（見既有 dialog 測試對外連的做法；
  // 若無 DI seam，斷言 actions 區存在 l.actionViewOnEncore 標籤的 TextButton 即可）。
  expect(find.text('在 encore.moe 查看'), findsOneWidget);
});

testWidgets('詳情全無（icon-only）→ 只剩 icon＋名稱＋關閉，不 crash', (tester) async {
  // detailByLang 空。
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(find.text('在 encore.moe 查看'), findsOneWidget);
});
```

> 既有 import 補：`import 'package:flutter_html/flutter_html.dart';`、`import '.../state/gacha_repository.dart';`、`item_type_kind.dart`。tearDown 沿用既有 `imageCache.clear()` + `clearLiveImages()`。

- [ ] **Step 3: 跑測試確認失敗**

Run: `flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart`
Expected: FAIL（dialog 尚無簡介/tag/外連、未讀 detailByLang）

- [ ] **Step 4: 改寫 dialog `build`**（`lib/widgets/dialogs/gacha_item_detail_dialog.dart`）

import 區加：
```dart
import 'package:flutter_html/flutter_html.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
```

在 `build` 內取 active lang 與詳情（於 `final entry = index.lookupImage(...)` 之後）：
```dart
final activeLang = ref.watch(activeLanguageCodeProvider);
final detail = (activeLang == null ? null : entry?.detailByLang[activeLang]) ??
    (entry?.detailByLang.isNotEmpty == true
        ? entry!.detailByLang.values.first
        : null);
final intro = detail?.intro ?? '';
final elementName = detail?.elementName ?? '';
final weaponTypeName = detail?.weaponTypeName ?? '';
final illustrationUrl = detail?.illustrationUrl ?? '';
```

把現行「取 `entry?.illustrationUrl`」改為上面的 `illustrationUrl`（立繪 chip 來源）。

title 區的 `Expanded(child: Text(record.name, ...))` 換成 `Expanded(child: Column(...))`，名稱下加簡介＋tag：
```dart
Expanded(
  child: Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        record.name,
        style: theme.textTheme.headlineSmall
            ?.copyWith(color: nameColor, fontWeight: FontWeight.bold),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      if (intro.trim().isNotEmpty) ...[
        const SizedBox(height: AppSpacing.s),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 120),
          child: SingleChildScrollView(
            child: Html(
              data: intro,
              style: {
                'body': Style(
                  fontSize: FontSize(theme.textTheme.bodyMedium?.fontSize ?? 14),
                  color: tokens.textSecondary,
                  margin: Margins.zero,
                  padding: HtmlPaddings.zero,
                ),
                'p': Style(margin: Margins.zero),
              },
            ),
          ),
        ),
      ],
      if (_tagsFor(l, record, elementName, weaponTypeName).isNotEmpty) ...[
        const SizedBox(height: AppSpacing.s),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in _tagsFor(l, record, elementName, weaponTypeName))
              Chip(
                label: Text(t),
                backgroundColor: tokens.textPrimary.withValues(alpha: 0.15),
                side: BorderSide.none,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(AppRadius.sm)),
                ),
                labelStyle: theme.textTheme.bodySmall
                    ?.copyWith(color: tokens.textPrimary, fontWeight: FontWeight.w500),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        ),
      ],
    ],
  ),
),
```

`actions` 區在 `關閉` 前加外連按鈕：
```dart
actions: [
  TextButton.icon(
    icon: const Icon(Icons.open_in_new, size: 18),
    label: Text(l.actionViewOnEncore),
    onPressed: () {
      _log.info('open encore kind=${itemTypeKeyOf(record)} id=${record.resourceId}');
      openExternalUrl(Uri.parse(encoreItemUrl(
        kind: itemTypeKeyOf(record),
        resourceId: record.resourceId,
        lang: activeLang ?? '',
      )));
    },
  ),
  FilledButton(
    onPressed: () => Navigator.of(context).pop(),
    child: Text(l.actionClose),
  ),
],
```

於檔案底部加 tag 組裝 helper：
```dart
/// 組詳情 tag：★（app UI 語系）＋元素＋武器類型（encore 在地化，空者略過）。
List<String> _tagsFor(
  AppLocalizations l,
  GachaRecord record,
  String elementName,
  String weaponTypeName,
) => [
  l.rarityStar(record.qualityLevel),
  if (elementName.isNotEmpty) elementName,
  if (weaponTypeName.isNotEmpty) weaponTypeName,
];
```

於 import 區加 `openExternalUrl`（`app_link.dart` 已 import？若無則加）：
```dart
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/app_link.dart';
```

> 立繪 chip 邏輯：把 `final illustrationUrl = entry?.illustrationUrl;` 改成上面算好的 `illustrationUrl`（來自 detail）。其餘 chip／圖片狀態機不動。

- [ ] **Step 5: 跑測試確認通過**

Run: `flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart`
Expected: PASS

- [ ] **Step 6: 品質檢查＋commit**

```bash
dart format lib/ test/
flutter analyze
git add lib/state/gacha_repository.dart lib/widgets/dialogs/gacha_item_detail_dialog.dart test/widgets/dialogs/gacha_item_detail_dialog_test.dart
git commit -m "feat(item-detail): restore intro + tags + encore link from prefetched detail"
```

---

## Task 8：清理 — 移除 guide-server／猜檔名／`illustrationUrl`、`mergeItemImage`→`mergeIcon`

> 至此所有消費端都已改用新 API；本 task 移除舊路徑並收束 `illustrationUrl`。

**Files:**
- Modify: `lib/services/item_image_fetcher.dart`
- Modify: `lib/services/item_image_index.dart`
- Modify: `lib/state/item_image_index.dart`
- Modify: `test/services/item_image_fetcher_test.dart`、`test/services/item_image_index_test.dart`、`test/state/item_image_index_test.dart`、`test/state/gacha_repository_item_image_test.dart`、`test/widgets/gacha_item_icon_test.dart`、`test/services/item_image_lookup_test.dart`、`test/widgets/dialogs/gacha_item_detail_dialog_test.dart`

- [ ] **Step 1: 移除 fetcher 舊碼**（`lib/services/item_image_fetcher.dart`）

刪除：`encoreWeaponIconUrl`、`encoreWeaponIconUrlUnderscored`、`encoreWeaponIconUrls`、`fetchItemImages`、`_fetchGuideServerImages`、`_fetchEncoreWeaponImage`、`_listBase`、`_userAgent`、`_encoreIconWeaponBase` 及其 dartdoc。保留 `downloadImage`、`encoreLang`、`encoreItemUrl`、`EncoreCatalog`、`fetchCatalog`、`EncoreItemDetail`、`fetchItemDetail`、`_log`、`timeout`、`downloadConcurrency`。

- [ ] **Step 2: 移除 fetcher 舊測試**（`test/services/item_image_fetcher_test.dart`）

刪除 group：`encoreWeaponIconUrl`、`ItemImageFetcher.fetchItemImages — guide-server（角色）`、`ItemImageFetcher.fetchItemImages — encore 武器 fallback`，以及檔頭 `_listOk` / `_routedClient` helper（已無人用）。保留 `encoreLang`／`fetchCatalog`／`fetchItemDetail`／`encoreItemUrl`／`downloadImage` groups 與其 helper。

- [ ] **Step 3: 移除 `illustrationUrl` 欄位**（`lib/services/item_image_index.dart`）

`ItemImageEntry` 移除 `illustrationUrl` 欄位與 constructor 參數；`ItemImageIndexStorage.save` 移除 `'illustration_url': v.illustrationUrl`；`load` 移除 `illustrationUrl: v['illustration_url'] as String?`（其餘欄位與 `detail_by_lang` 不動，version 維持 2）。`deleteIllustrationCacheFiles`／`itemIllustrationCacheFile`（檔名 helper，dialog 立繪快取仍用）**保留**。

- [ ] **Step 4: 移除 `mergeItemImage`、保留 `mergeIcon`**（`lib/state/item_image_index.dart`）

刪除舊 `mergeItemImage` method（已由 `mergeIcon` 取代）。

- [ ] **Step 5: 更新所有殘留 `ItemImageEntry(illustrationUrl: ...)` 與 `mergeItemImage(...)`**

逐檔移除 `illustrationUrl:` 具名參數、把 `mergeItemImage(` 改 `mergeIcon(`（並移除其 `illustrationUrl:` 參數）：
- `test/services/item_image_index_test.dart`：所有 `ItemImageEntry(... illustrationUrl: ... )` 移除該參數（含 lookup/hasIcon/storage/needsItemImageFetch/resetAll 各 group）。
- `test/state/item_image_index_test.dart`：`mergeItemImage(...)` → `mergeIcon(...)`（移除 `illustrationUrl:`）；`ItemImageEntry(...)` 移除 `illustrationUrl:`。
- `test/state/gacha_repository_item_image_test.dart`：預植 `ItemImageEntry(...)` 移除 `illustrationUrl:`。
- `test/widgets/gacha_item_icon_test.dart`：`ItemImageEntry(...)` 移除 `illustrationUrl:`。
- `test/services/item_image_lookup_test.dart`：`ItemImageEntry(...)` 移除 `illustrationUrl:`。
- `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`：若預植 entry 用到 `illustrationUrl:` 一併移除（立繪改放 `detailByLang[...].illustrationUrl`）。

（用 `git grep -n "illustration_url\|illustrationUrl\|mergeItemImage" lib/ test/` 逐一確認，殘留只應落在 `itemIllustrationCacheFile`／`deleteIllustrationCacheFiles`／`detail_by_lang` 的 `illustration_url` JSON key／`ItemDetailL10n.illustrationUrl`。）

- [ ] **Step 6: 跑全測試確認通過**

Run: `flutter analyze && flutter test`
Expected: `No issues found!` ＋ `All tests passed!`

- [ ] **Step 7: 品質檢查＋commit**

```bash
dart format lib/ test/
flutter analyze
git add lib/ test/
git commit -m "refactor(item-image): drop guide-server, weapon filename guess, illustrationUrl"
```

---

## Task 9：全套驗證 ＋ 手動冒煙

**Files:** 無（驗證）

- [ ] **Step 1: 全套品質檢查**

```bash
dart format lib/ test/
flutter analyze
flutter test
```
Expected: `No issues found!` ＋ `All tests passed!`

- [ ] **Step 2: 殘留掃描**

```bash
git grep -nE "guide-server|guide_server|encoreWeaponIcon|fetchItemImages|mergeItemImage" lib/ test/
```
Expected: 無命中（全部移除）。

- [ ] **Step 3: 手動冒煙（本機）**

跑 app（`flutter run -d windows`），對一個既有帳號按更新，確認：
- 角色／武器格子 icon 正常顯示（含 3.0 後武器，不再缺圖）。
- 點角色 → dialog 顯示簡介＋tag（★/元素/武器類型）＋立繪/頭像切換＋「在 encore.moe 查看」可開瀏覽器到正確頁。
- 點武器 → dialog 顯示簡介（HTML 正常）＋★/武器類型 tag＋僅 icon。
- 切換到不同語言的帳號，dialog 文案語言跟著該帳號（非 app UI 語言）。

- [ ] **Step 4（如有 format 變動才需要）: commit**

```bash
git add -A
git commit -m "style: dart format after encore item-image migration"
```

---

## Self-Review（plan↔spec 對照）

- **spec §2 格子 icon catalog** → Task 2/5 ✓
- **spec §2/§6-2 詳情預抓 per-lang** → Task 3/5 ✓
- **spec §3 簡介 flutter_html／tag／圖片切換／外連** → Task 6/7 ✓
- **spec §5 lang 對應（encoreLang、active lang）** → Task 1/7 ✓
- **spec §6-3 資料模型（ItemDetailL10n／detailByLang／storage v2／mergeIcon/mergeItemDetail）** → Task 4/8 ✓
- **spec §7-4 ★ 用 `l.rarityStar`、刻意語系組合** → Task 7（`_tagsFor`）✓
- **spec §7-5 外連 `encoreItemUrl`（id-based 已驗證）** → Task 6 ✓
- **spec §9 i18n `actionViewOnEncore`、重用既有 chip/rarity 鍵** → Task 6/7 ✓
- **spec §11 測試矩陣** → 各 task TDD step ✓
- **spec §12 影響檔案／flutter_html** → Task 6/8 對齊 ✓
- **型別一致**：`mergeIcon`／`mergeItemDetail`／`EncoreCatalog.iconFor`／`fetchCatalog`／`fetchItemDetail`／`encoreItemUrl`／`ItemDetailL10n` 在 Task 之間命名一致 ✓
- **無 placeholder**：各 step 皆附實際 code／指令／預期輸出。Task 7 widget 測試骨架引用既有測試 helper（同檔已有 ProviderScope/temp dir 樣式），非 TODO。

---

## 執行交接

完成後選擇執行方式：

1. **Subagent-Driven（建議）** — 每個 task 派新 subagent、task 間 review、快速迭代。
2. **Inline Execution** — 在本 session 用 executing-plans 批次執行、checkpoint review。
