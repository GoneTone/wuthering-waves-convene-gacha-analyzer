# 武器 icon 來源（encore.moe）+ 還原詳情頁籤切換器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 替 guide-server 撈不到的 8 碼武器補上 encore.moe icon（順序 fallback），並還原原版 chip 頁籤切換詳情 dialog（立繪 + Icon-last、單圖自動隱藏、修永久 spinner bug）。

**Architecture:** `item_image_fetcher.dart` 在 guide-server 回 null 後以 encore 武器 URL（由 `resourceId` 直接組）做輕量 ranged-GET 探測，2xx/206 才回該 URL；`gacha_repository.dart` 兩階段**完全不動**（`fetchItemImages` 仍是「是否有圖」唯一裁決者）。詳情 dialog 移植原版 chip 切換器骨架，剝除鳴潮無資料源的 gallery 多圖／HTML 描述／tags／wiki 連結，餵入現有兩張圖。

**Tech Stack:** Flutter / Dart、Riverpod、`http` + `http/testing.dart`（MockClient）、`flutter gen-l10n`（ARB）。

**Spec:** `docs/superpowers/specs/2026-06-03-weapon-icon-encore-and-detail-tabs-design.md`

---

## 檔案結構

| 檔案 | 責任 | 動作 |
|---|---|---|
| `.gitignore` | 忽略研究期產生的 `.playwright-mcp/` | Modify |
| `lib/services/item_image_fetcher.dart` | guide-server 角色 + encore 武器 fallback、URL builder | Modify |
| `test/services/item_image_fetcher_test.dart` | fetcher 測試（mock 改為依 host 路由 + encore 案例） | Rewrite |
| `lib/l10n/app_zh.arb`／`app_en.arb`／`app_ja.arb`／`app_zh_Hans.arb` | 新增 `galleryIllustrationLabel` | Modify ×4 |
| `lib/widgets/dialogs/gacha_item_detail_dialog.dart` | chip 頁籤切換詳情 dialog | Rewrite |
| `test/widgets/dialogs/gacha_item_detail_dialog_test.dart` | dialog 測試（新增 chip 行為案例） | Modify |
| `docs/鳴潮相關資料.md` | 更新「只有角色有圖」說明 | Modify |

> **不動**：`lib/state/gacha_repository.dart`（兩階段流程與 D7 worklist）、`lib/widgets/gacha_item_icon.dart`、`lib/services/item_image_index.dart`、`lib/state/item_image_index.dart`。

---

## Task 1：`.gitignore` 排除 `.playwright-mcp/`（Part C）

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1：在 `.gitignore` 末尾加入區段**

在檔案最後（`.fvm/` 之後）新增：

```gitignore

# Playwright MCP scratch output (research-time browser automation; not tracked)
/.playwright-mcp/
```

- [ ] **Step 2：驗證已忽略**

Run: `git status --porcelain`
Expected：輸出**不再**出現 `?? .playwright-mcp/`（且 `.gitignore` 顯示為已修改 `M`）。

- [ ] **Step 3：Commit**

```bash
git add .gitignore
git commit -m "chore: ignore .playwright-mcp scratch directory"
```

---

## Task 2：encore 武器 icon 來源（Part A）

**Files:**
- Modify: `lib/services/item_image_fetcher.dart`
- Rewrite: `test/services/item_image_fetcher_test.dart`

> **背景**：`fetchItemImages` 目前只打 guide-server，多個 `return null` 分支（data 空／role 缺／cardPictureUrl 空／非 2xx／code≠200／JSON 壞／例外）。本 task 把 guide-server 邏輯抽成私有方法，再於 null 時加 encore 武器 fallback。
> **mock 注意**：加 encore 呼叫後，原本「回 null」的測試其 MockClient 對**所有**請求回 200 JSON，會讓 encore 探測誤判成功。故測試 mock 必須**依 host 路由**：guide-server host 用 guide handler，`api-v2.encore.moe` 用可設定狀態（預設 404）。

- [ ] **Step 1：改寫整個 `test/services/item_image_fetcher_test.dart`（先寫測試）**

以下為完整檔案內容，覆寫原檔：

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';

/// 組一個 guide-server introduction/list 的成功回應。
http.Response _listOk({
  String? cardPictureUrl,
  String? illustrationPictureUrl,
  bool emptyData = false,
  bool nullRole = false,
}) {
  final role = nullRole
      ? null
      : {
          'cardPictureUrl': ?cardPictureUrl,
          'illustrationPictureUrl': ?illustrationPictureUrl,
        };
  final body = jsonEncode({
    'code': 200,
    'message': 'ok',
    'data': emptyData
        ? []
        : [
            {'role': role},
          ],
  });
  return http.Response.bytes(
    utf8.encode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

/// 依 host 路由的 MockClient：
/// - `api-v2.encore.moe` → 回 [encoreStatus]（預設 404），並把請求記入 [seenHosts]；
/// - 其餘（guide-server）→ 用 [guide] handler。
http.Client _routedClient({
  required http.Response Function(http.Request req) guide,
  int encoreStatus = 404,
  List<String>? seenHosts,
  void Function(http.Request req)? onEncore,
}) {
  return MockClient((req) async {
    seenHosts?.add(req.url.host);
    if (req.url.host == 'api-v2.encore.moe') {
      onEncore?.call(req);
      return http.Response('', encoreStatus);
    }
    return guide(req);
  });
}

void main() {
  group('encoreWeaponIconUrl', () {
    test('由 resourceId 直接組武器 icon URL', () {
      expect(
        encoreWeaponIconUrl(21010011),
        'https://api-v2.encore.moe/resource/Data/Game/Aki/UI/UIResources/'
        'Common/Image/IconWeapon/T_IconWeapon21010011_UI.webp',
      );
    });
  });

  group('ItemImageFetcher.fetchItemImages — guide-server（角色）', () {
    test('角色有圖 → 回 (iconUrl, illustrationUrl)，不打 encore', () async {
      final seen = <String>[];
      final mock = _routedClient(
        guide: (_) => _listOk(
          cardPictureUrl: 'https://x/card.png',
          illustrationPictureUrl: 'https://x/illust.png',
        ),
        seenHosts: seen,
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 1211,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNotNull);
      expect(out!.iconUrl, 'https://x/card.png');
      expect(out.illustrationUrl, 'https://x/illust.png');
      expect(seen.contains('api-v2.encore.moe'), isFalse);
    });

    test('帶 roleGbId query 與 X-Language header', () async {
      late http.BaseRequest captured;
      final mock = _routedClient(
        guide: (req) {
          captured = req;
          return _listOk(
            cardPictureUrl: 'https://x/card.png',
            illustrationPictureUrl: 'https://x/illust.png',
          );
        },
      );
      await ItemImageFetcher().fetchItemImages(
        resourceId: 1211,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(captured.url.host, 'guide-server.aki-game.net');
      expect(captured.url.path, '/introduction/list');
      expect(captured.url.queryParameters['roleGbId'], '1211');
      expect(captured.headers['X-Language'], 'zh-Hant');
    });

    test('有 card 但 illustration 缺 → illustrationUrl 為空字串、仍算有圖', () async {
      final mock = _routedClient(
        guide: (_) => _listOk(cardPictureUrl: 'https://x/card.png'),
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 1211,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNotNull);
      expect(out!.iconUrl, 'https://x/card.png');
      expect(out.illustrationUrl, '');
    });
  });

  group('ItemImageFetcher.fetchItemImages — encore 武器 fallback', () {
    test('guide-server data 空 + encore 200 → 回 encore URL、illustration 空', () async {
      final mock = _routedClient(
        guide: (_) => _listOk(emptyData: true),
        encoreStatus: 200,
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 21010024,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNotNull);
      expect(out!.iconUrl, encoreWeaponIconUrl(21010024));
      expect(out.illustrationUrl, '');
    });

    test('guide-server 206（partial）也視為有圖', () async {
      final mock = _routedClient(
        guide: (_) => _listOk(emptyData: true),
        encoreStatus: 206,
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 21010024,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNotNull);
      expect(out!.iconUrl, encoreWeaponIconUrl(21010024));
    });

    test('guide-server miss + encore 404 → null', () async {
      final mock = _routedClient(
        guide: (_) => _listOk(emptyData: true),
        encoreStatus: 404,
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 21010024,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNull);
    });

    test('encore 探測帶 Range 與 User-Agent header，URL 由 resourceId 組', () async {
      late http.Request encoreReq;
      final mock = _routedClient(
        guide: (_) => _listOk(emptyData: true),
        encoreStatus: 200,
        onEncore: (req) => encoreReq = req,
      );
      await ItemImageFetcher().fetchItemImages(
        resourceId: 21010024,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(encoreReq.method, 'GET');
      expect(encoreReq.url.toString(), encoreWeaponIconUrl(21010024));
      expect(encoreReq.headers['Range'], 'bytes=0-0');
      expect(encoreReq.headers['User-Agent'], isNotEmpty);
    });

    test('guide-server 非 2xx → 仍嘗試 encore（encore 200 → 有圖）', () async {
      final mock = _routedClient(
        guide: (_) => http.Response('', 500),
        encoreStatus: 200,
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 21010024,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNotNull);
      expect(out!.iconUrl, encoreWeaponIconUrl(21010024));
    });

    test('guide-server role null + encore 404 → null', () async {
      final mock = _routedClient(
        guide: (_) => _listOk(nullRole: true),
        encoreStatus: 404,
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 9999,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNull);
    });

    test('encore 探測丟例外 → null（不 throw）', () async {
      final mock = MockClient((req) async {
        if (req.url.host == 'api-v2.encore.moe') {
          throw const SocketException('refused');
        }
        return _listOk(emptyData: true);
      });
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 21010024,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNull);
    });

    test('guide-server 回非 JSON + encore 404 → null（不 throw）', () async {
      final mock = _routedClient(
        guide: (_) => http.Response('{not json', 200),
        encoreStatus: 404,
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 21010024,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNull);
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
}
```

- [ ] **Step 2：跑測試確認失敗**

Run: `flutter test test/services/item_image_fetcher_test.dart`
Expected：編譯失敗 `The function 'encoreWeaponIconUrl' isn't defined` / encore 案例 FAIL（尚未實作 fallback）。

- [ ] **Step 3：實作 fetcher 改動**

改寫 `lib/services/item_image_fetcher.dart`，覆寫整個檔案為：

```dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 由 [resourceId] 直接組 encore.moe 武器 icon URL（檔名內嵌 8 碼武器 id）。
String encoreWeaponIconUrl(int resourceId) =>
    'https://api-v2.encore.moe/resource/Data/Game/Aki/UI/UIResources/'
    'Common/Image/IconWeapon/T_IconWeapon${resourceId}_UI.webp';

/// 取物品圖片的 fetcher：角色走官方 guide-server，武器走 encore.moe fallback，
/// 外加通用圖檔下載。
class ItemImageFetcher {
  /// 建立 [ItemImageFetcher]，可調整下載並行度與逾時。
  ItemImageFetcher({
    this.downloadConcurrency = 8,
    this.timeout = const Duration(seconds: 10),
  });

  /// download 階段 worker-pool 同時 in-flight 上限。
  final int downloadConcurrency;

  /// 單次 HTTP 請求超時。
  final Duration timeout;

  /// Logger 實例（item_image.fetcher 命名空間）。
  static final _log = Logger('item_image.fetcher');

  /// 打第三方圖床（encore）時帶的禮貌 User-Agent。
  static const _userAgent = 'wuthering-waves-convene-gacha-analyzer';

  /// guide-server introduction/list API base URL。
  static final _listBase = Uri.parse(
    'https://guide-server.aki-game.net/introduction/list',
  );

  /// 以 [resourceId] 取物品圖：先官方 guide-server（角色），回 null 再走 encore
  /// 武器 fallback。回 `(iconUrl, illustrationUrl)` 或 `null`（兩來源皆無圖）。
  ///
  /// 不靠 `resourceType`／位數預判是否有圖（D7）：所有 guide-server miss 的 id 都
  /// 試 encore 武器 URL，角色若漏抓會在 encore 端 404 → 自然回 null（不誤判）。
  Future<({String iconUrl, String illustrationUrl})?> fetchItemImages({
    required int resourceId,
    required String languageCode,
    required http.Client client,
  }) async {
    final guide = await _fetchGuideServerImages(
      resourceId: resourceId,
      languageCode: languageCode,
      client: client,
    );
    if (guide != null) return guide;
    return _fetchEncoreWeaponImage(resourceId: resourceId, client: client);
  }

  /// 走 guide-server introduction/list 取角色圖（`data[0].role.cardPictureUrl`
  /// / `illustrationPictureUrl`）。任一防呆失敗一律回 `null`（不 throw）。
  Future<({String iconUrl, String illustrationUrl})?> _fetchGuideServerImages({
    required int resourceId,
    required String languageCode,
    required http.Client client,
  }) async {
    final url = _listBase.replace(queryParameters: {'roleGbId': '$resourceId'});
    try {
      final res = await client
          .get(url, headers: {'X-Language': languageCode})
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        _log.warning(
          'list non-2xx status=${res.statusCode} resourceId=$resourceId '
          'lang=$languageCode url=${sanitizeUrl(url.toString())}',
        );
        return null;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final code = body['code'];
      if (code is! int || code != 200) {
        _log.warning(
          'list code=$code resourceId=$resourceId lang=$languageCode '
          'msg=${body['message']}',
        );
        return null;
      }
      final data = body['data'];
      if (data is! List || data.isEmpty) {
        _log.fine('list empty data resourceId=$resourceId (no role image)');
        return null;
      }
      final first = data.first;
      if (first is! Map<String, dynamic>) return null;
      final role = first['role'];
      if (role is! Map<String, dynamic>) {
        _log.fine('list role missing resourceId=$resourceId (no role image)');
        return null;
      }
      final iconUrl = (role['cardPictureUrl'] as String?) ?? '';
      if (iconUrl.isEmpty) {
        _log.fine(
          'list cardPictureUrl empty resourceId=$resourceId (no role image)',
        );
        return null;
      }
      final illustrationUrl = (role['illustrationPictureUrl'] as String?) ?? '';
      _log.info(
        'list hit resourceId=$resourceId lang=$languageCode '
        'illustration=${illustrationUrl.isNotEmpty}',
      );
      return (iconUrl: iconUrl, illustrationUrl: illustrationUrl);
    } catch (e) {
      _log.warning(
        'list failed resourceId=$resourceId lang=$languageCode err=$e',
      );
      return null;
    }
  }

  /// 武器 fallback：以 [resourceId] 組 encore 武器 URL，做輕量 ranged-GET 探測。
  ///
  /// 帶 `Range: bytes=0-0` 只取首位元組確認存在（Cloudflare 回 206；若忽略 Range
  /// 則回 200 全檔，照樣只看 status）。回 `(iconUrl, '')`（武器無立繪）或 `null`。
  Future<({String iconUrl, String illustrationUrl})?> _fetchEncoreWeaponImage({
    required int resourceId,
    required http.Client client,
  }) async {
    final url = encoreWeaponIconUrl(resourceId);
    try {
      final res = await client
          .get(
            Uri.parse(url),
            headers: {'User-Agent': _userAgent, 'Range': 'bytes=0-0'},
          )
          .timeout(timeout);
      if (res.statusCode == 200 || res.statusCode == 206) {
        _log.info(
          'encore weapon hit resourceId=$resourceId status=${res.statusCode} '
          'url=${sanitizeUrl(url)}',
        );
        return (iconUrl: url, illustrationUrl: '');
      }
      _log.fine(
        'encore weapon miss resourceId=$resourceId status=${res.statusCode} '
        'url=${sanitizeUrl(url)}',
      );
      return null;
    } catch (e) {
      _log.warning(
        'encore weapon probe failed resourceId=$resourceId '
        'url=${sanitizeUrl(url)} err=$e',
      );
      return null;
    }
  }

  /// GET [url] 的圖檔 bytes；任何失敗（非 2xx / 例外）回 null，caller 不寫檔
  /// 並於下次更新重試。
  Future<Uint8List?> downloadImage(String url, http.Client client) async {
    try {
      final res = await client.get(Uri.parse(url)).timeout(timeout);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return res.bodyBytes;
      }
      _log.warning(
        'download non-2xx status=${res.statusCode} url=${sanitizeUrl(url)}',
      );
      return null;
    } catch (e) {
      _log.warning('download failed url=${sanitizeUrl(url)} err=$e');
      return null;
    }
  }
}
```

- [ ] **Step 4：跑測試確認通過**

Run: `flutter test test/services/item_image_fetcher_test.dart`
Expected：All tests passed!

- [ ] **Step 5：Commit**

```bash
git add lib/services/item_image_fetcher.dart test/services/item_image_fetcher_test.dart
git commit -m "feat(item-image): add encore.moe weapon icon fallback after guide-server"
```

---

## Task 3：新增 `galleryIllustrationLabel` l10n 字串（Part B 前置）

**Files:**
- Modify: `lib/l10n/app_zh.arb`（template，含 `@` 描述）、`app_en.arb`、`app_ja.arb`、`app_zh_Hans.arb`

> 在每個 ARB 既有的 `galleryIconLabel` 條目**正上方**插入 `galleryIllustrationLabel`。只有 template `app_zh.arb` 與其餘 ARB 都帶 `@` metadata（本專案慣例）。

- [ ] **Step 1：`lib/l10n/app_zh.arb`（template）**

找到：
```json
  "galleryIconLabel": "圖示",
```
在其**上方**插入：
```json
  "galleryIllustrationLabel": "立繪",
  "@galleryIllustrationLabel": {
    "description": "Item detail dialog: chip label for the character illustration (large art) page. Placed before the icon chip. Weapons have no illustration so this chip is absent for them."
  },
```

- [ ] **Step 2：`lib/l10n/app_en.arb`**

在 `"galleryIconLabel": "Icon",` 上方插入：
```json
  "galleryIllustrationLabel": "Illustration",
  "@galleryIllustrationLabel": {
    "description": "Item detail dialog: chip label for the character illustration (large art) page. Placed before the icon chip. Weapons have no illustration so this chip is absent for them."
  },
```

- [ ] **Step 3：`lib/l10n/app_ja.arb`**

在 `"galleryIconLabel": "アイコン",` 上方插入：
```json
  "galleryIllustrationLabel": "イラスト",
  "@galleryIllustrationLabel": {
    "description": "Item detail dialog: chip label for the character illustration (large art) page. Placed before the icon chip. Weapons have no illustration so this chip is absent for them."
  },
```

- [ ] **Step 4：`lib/l10n/app_zh_Hans.arb`**

在 `"galleryIconLabel": "图标",` 上方插入：
```json
  "galleryIllustrationLabel": "立绘",
  "@galleryIllustrationLabel": {
    "description": "Item detail dialog: chip label for the character illustration (large art) page. Placed before the icon chip. Weapons have no illustration so this chip is absent for them."
  },
```

- [ ] **Step 5：重新產生 l10n 並驗證**

Run: `flutter gen-l10n`
Run: `flutter analyze lib/l10n`
Expected：產生成功、`No issues found!`（`lib/l10n/generated/app_localizations.dart` 出現 `String get galleryIllustrationLabel`）。

- [ ] **Step 6：Commit**

```bash
git add lib/l10n/app_zh.arb lib/l10n/app_en.arb lib/l10n/app_ja.arb lib/l10n/app_zh_Hans.arb
git commit -m "feat(l10n): add galleryIllustrationLabel for item detail illustration chip"
```

---

## Task 4：還原詳情 chip 頁籤切換器（Part B）

**Files:**
- Rewrite: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`
- Modify: `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`（在既有 `GachaItemDetailDialog 渲染` group 末尾新增案例）

> **設計**：chip 順序「立繪（若 `illustrationUrl` 非空）→ Icon（永遠最後）」；`chipEntries.length > 1` 才繪 chip 列；Icon chip 永遠 ready（已快取）→ 天然修掉永久 spinner；content 大圖用 `key: ValueKey(file.path)` 以利測試辨識當前圖。

- [ ] **Step 1：在 dialog test 末尾新增 chip 行為案例（先寫測試）**

在 `test/widgets/dialogs/gacha_item_detail_dialog_test.dart` 的 `group('GachaItemDetailDialog 渲染', () {` 區塊內、現有 testWidgets 之後（`'actions 區無外部 Wiki 連結按鈕'` 案例之後、該 group `});` 之前）插入：

```dart
    testWidgets('武器（僅 icon、無立繪）→ 無 chip 列、無 spinner、放大顯示 icon', (
      tester,
    ) async {
      const iconUrl = 'https://cdn.example.com/w_icon.webp';
      late File iconFile;
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeItemImage(
              resourceId: 77,
              iconUrl: iconUrl,
              illustrationUrl: '',
              noImage: false,
              permanentNoImage: false,
            );
        iconFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 77,
          url: iconUrl,
        );
        await _touchFile(tempDir, iconFile.uri.pathSegments.last);
      });

      await pumpDialog(
        tester,
        _rec(resourceId: 77, name: 'WeaponX', resourceType: '武器'),
      );

      // 單一 chip → chip 列隱藏。
      expect(find.byType(ChoiceChip), findsNothing);
      // Icon chip 永遠 ready → 無永久 spinner。
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // content 大圖即 icon（以 ValueKey(file.path) 辨識）。
      expect(find.byKey(ValueKey(iconFile.path)), findsOneWidget);
    });

    testWidgets('角色（立繪+icon）→ 2 chips、icon 在最後（切到最後一個顯示 icon）', (
      tester,
    ) async {
      const iconUrl = 'https://cdn.example.com/c_icon.png';
      const illustUrl = 'https://cdn.example.com/c_illust.png';
      late File iconFile;
      late File illustFile;
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeItemImage(
              resourceId: 111,
              iconUrl: iconUrl,
              illustrationUrl: illustUrl,
              noImage: false,
              permanentNoImage: false,
            );
        iconFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: iconUrl,
        );
        await _touchFile(tempDir, iconFile.uri.pathSegments.last);
        illustFile = itemIllustrationCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: illustUrl,
        );
        await _touchFile(tempDir, illustFile.uri.pathSegments.last);
      });

      await pumpDialog(tester, _rec(resourceId: 111, name: 'Char'));

      // 2 chips。
      expect(find.byType(ChoiceChip), findsNWidgets(2));
      // 預設（index 0）顯示立繪。
      expect(find.byKey(ValueKey(illustFile.path)), findsOneWidget);

      // 切到最後一個 chip → 顯示 icon（證明 icon 排最後）。
      await tester.tap(find.byType(ChoiceChip).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(ValueKey(iconFile.path)), findsOneWidget);
    });
```

- [ ] **Step 2：跑測試確認失敗**

Run: `flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart`
Expected：新案例 FAIL（武器案例現會出現永久 spinner → `CircularProgressIndicator` findsNothing 失敗；ValueKey 找不到等）。

- [ ] **Step 3：覆寫 `lib/widgets/dialogs/gacha_item_detail_dialog.dart`**

覆寫整個檔案為：

```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_cache_usage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/app_dialog.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/zoomable_image_overlay.dart';

/// module-level logger，供 dialog 與其 tap target 共用。
final _log = Logger('gacha.itemimage.detail');

/// 判斷 [record] 是否有可點開的詳情（icon 已成功下載 → 可開圖片切換器）。
///
/// 無 icon（負取／未抓）回 false，呼叫端據此不包 [GachaItemTapTarget]（passthrough）。
bool hasItemDetailContent(WidgetRef ref, GachaRecord record) {
  final index = ref.watch(itemImageIndexProvider);
  final entry = index.lookupImage(record.resourceId);
  if (entry == null) return false;
  final iconUrl = entry.iconUrl;
  if (iconUrl == null || iconUrl.isEmpty) return false;
  final cacheDir = ref.watch(itemImageCacheDirProvider);
  return itemIconCacheFile(
    baseDir: cacheDir,
    resourceId: record.resourceId,
    url: iconUrl,
  ).existsSync();
}

/// 物品詳情 dialog：title 為 icon + 名稱；content 為 chip 切換器（立繪 / Icon）。
///
/// chip 順序固定「立繪（若有）→ Icon（永遠最後）」。只有一個 chip（如武器只有
/// icon）時自動隱藏 chip 列、直接放大顯示該圖。
class GachaItemDetailDialog extends ConsumerStatefulWidget {
  /// 建立 [GachaItemDetailDialog]。
  const GachaItemDetailDialog({super.key, required this.record});

  /// 要顯示的喚取 record。
  final GachaRecord record;

  @override
  ConsumerState<GachaItemDetailDialog> createState() =>
      _GachaItemDetailDialogState();
}

/// [GachaItemDetailDialog] 的 state：維護 chip 選中索引與各圖 lazy 下載狀態。
class _GachaItemDetailDialogState extends ConsumerState<GachaItemDetailDialog> {
  /// 當前選中 chip 的 index；超出範圍由 `clampedIndex` 收斂。
  int _selectedIndex = 0;

  /// 每張圖的下載／載入狀態，key 為該圖本地 cache 檔絕對路徑。
  final Map<String, _ImageLoadState> _loadStates = {};

  /// 已排程 precache 的本地圖檔路徑；避免每次 setState 重排。
  final Set<String> _precachedPaths = {};

  /// 是否已有 precache 排程於下一 frame。
  bool _precacheScheduled = false;

  /// http client（dispose 時 close 中斷 in-flight 請求）。
  late final http.Client _client;

  @override
  void initState() {
    super.initState();
    _client = http.Client();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  /// 對立繪 [url] 做 lazy 下載；成功寫 cache 並 setState 為 ready，失敗為 failed。
  Future<void> _fetchAndCache({required String url, required File file}) async {
    final fetcher = ref.read(itemImageFetcherProvider);
    try {
      final bytes = await fetcher.downloadImage(url, _client);
      if (bytes == null) {
        if (!mounted) return;
        setState(() => _loadStates[file.path] = const _ImageFailed());
        _log.warning(
          'illustration download null rid=${widget.record.resourceId} '
          'url=${sanitizeUrl(url)}',
        );
        return;
      }
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      setState(() => _loadStates[file.path] = _ImageReady(file));
      ref.invalidate(itemImageCacheUsageProvider);
      _log.info(
        'illustration ok rid=${widget.record.resourceId} '
        'bytes=${bytes.length} path=${sanitizeFsPath(file.path)}',
      );
    } catch (e, st) {
      if (!mounted) return;
      setState(() => _loadStates[file.path] = const _ImageFailed());
      _log.warning(
        'illustration failed rid=${widget.record.resourceId} '
        'url=${sanitizeUrl(url)}',
        e,
        st,
      );
    }
  }

  /// 由 failed 重試：改回 loading 並再次下載。
  void _retry({required String url, required File file}) {
    setState(() => _loadStates[file.path] = const _ImageLoading());
    unawaited(_fetchAndCache(url: url, file: file));
  }

  /// 只 precache ready 的圖檔。
  void _precacheImages(BuildContext context, List<_ImageChipEntry> entries) {
    for (final e in entries) {
      final st = _loadStates[e.file.path];
      if (st is! _ImageReady) continue;
      if (_precachedPaths.add(e.file.path)) {
        precacheImage(FileImage(e.file), context);
      }
    }
  }

  /// 依當前 chip 狀態顯示內容（ready→可縮放圖／loading→spinner／failed→重試）。
  Widget _buildCurrentImageArea(BuildContext context, _ImageChipEntry current) {
    final theme = Theme.of(context);
    final tokens = theme.gacha;
    final l = AppLocalizations.of(context)!;
    final state = _loadStates[current.file.path] ?? const _ImageLoading();
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: switch (state) {
        _ImageReady(:final file) => MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _log.info('open zoom path=${sanitizeFsPath(file.path)}');
              showZoomableImageOverlay(context, imageFile: file);
            },
            child: Image.file(
              file,
              key: ValueKey(file.path),
              fit: BoxFit.contain,
              alignment: Alignment.center,
              gaplessPlayback: true,
              errorBuilder: (_, e, st) => const SizedBox.shrink(),
            ),
          ),
        ),
        _ImageLoading() => Center(
          child: SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: tokens.textSecondary,
            ),
          ),
        ),
        _ImageFailed() => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                size: 48,
                color: tokens.textMuted,
              ),
              const SizedBox(height: AppSpacing.s),
              Text(
                l.galleryLazyLoadFailed,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.s),
              TextButton.icon(
                onPressed: () => _retry(url: current.url, file: current.file),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l.actionRetry),
              ),
            ],
          ),
        ),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final tokens = theme.gacha;
    final record = widget.record;

    final index = ref.watch(itemImageIndexProvider);
    final cacheDir = ref.watch(itemImageCacheDirProvider);
    final entry = index.lookupImage(record.resourceId);

    // icon cache 檔（已於更新階段下載 → 永遠 ready）。
    File? iconFile;
    final iconUrl = entry?.iconUrl;
    if (iconUrl != null && iconUrl.isNotEmpty) {
      final f = itemIconCacheFile(
        baseDir: cacheDir,
        resourceId: record.resourceId,
        url: iconUrl,
      );
      if (f.existsSync()) iconFile = f;
    }

    // chip 順序：立繪（若有）→ Icon（永遠最後）。
    final chipEntries = <_ImageChipEntry>[];
    final illustrationUrl = entry?.illustrationUrl;
    if (illustrationUrl != null && illustrationUrl.isNotEmpty) {
      final f = itemIllustrationCacheFile(
        baseDir: cacheDir,
        resourceId: record.resourceId,
        url: illustrationUrl,
      );
      chipEntries.add(
        _ImageChipEntry(
          label: l.galleryIllustrationLabel,
          url: illustrationUrl,
          file: f,
          kind: _ChipKind.illustration,
        ),
      );
    }
    if (iconFile != null) {
      chipEntries.add(
        _ImageChipEntry(
          label: l.galleryIconLabel,
          url: iconUrl ?? '',
          file: iconFile,
          kind: _ChipKind.icon,
        ),
      );
    }

    // 同步 _loadStates：icon 永遠 ready；立繪本地有檔→ready，否則 loading + 背景下載。
    for (final ce in chipEntries) {
      if (_loadStates.containsKey(ce.file.path)) continue;
      switch (ce.kind) {
        case _ChipKind.icon:
          _loadStates[ce.file.path] = _ImageReady(ce.file);
        case _ChipKind.illustration:
          if (ce.file.existsSync()) {
            _loadStates[ce.file.path] = _ImageReady(ce.file);
          } else {
            _loadStates[ce.file.path] = const _ImageLoading();
            final theUrl = ce.url;
            final theFile = ce.file;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              unawaited(_fetchAndCache(url: theUrl, file: theFile));
            });
          }
      }
    }

    final clampedIndex = chipEntries.isEmpty
        ? -1
        : _selectedIndex.clamp(0, chipEntries.length - 1);
    final current = clampedIndex >= 0 ? chipEntries[clampedIndex] : null;

    if (chipEntries.isNotEmpty && !_precacheScheduled) {
      _precacheScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _precacheScheduled = false;
        if (!mounted) return;
        _precacheImages(context, chipEntries);
      });
    }

    final nameColor = switch (record.qualityLevel) {
      5 => tokens.fiveStar,
      4 => tokens.fourStar,
      _ => tokens.textPrimary,
    };

    return AppDialog(
      size: AppDialogSize.md,
      maxHeight: 880,
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (iconFile != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Image.file(
                iconFile,
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, e, st) => const SizedBox.shrink(),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text(
              record.name,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: nameColor,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: current != null ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chipEntries.length > 1) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < chipEntries.length; i++)
                  ChoiceChip(
                    label: Text(chipEntries[i].label),
                    selected: i == clampedIndex,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _selectedIndex = i),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (current != null)
            Expanded(child: _buildCurrentImageArea(context, current)),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionClose),
        ),
      ],
    );
  }
}

/// chip 類別 — icon 永遠 ready（已快取），illustration 走 lazy。
enum _ChipKind {
  /// entry.illustrationUrl（立繪大圖，lazy 下載）。
  illustration,

  /// entry.iconUrl（已預下載，永遠 ready，永遠排最後）。
  icon,
}

/// 內部：單一 chip 條目。
class _ImageChipEntry {
  /// 建立 [_ImageChipEntry]。
  const _ImageChipEntry({
    required this.label,
    required this.url,
    required this.file,
    required this.kind,
  });

  /// chip 顯示文字。
  final String label;

  /// 該 chip 對應的遠端 URL。
  final String url;

  /// 該 chip 對應的本地 cache 檔（立繪可能尚未存在）。
  final File file;

  /// chip 類別。
  final _ChipKind kind;
}

/// 顯示 [GachaItemDetailDialog]。
Future<void> showGachaItemDetailDialog(
  BuildContext context,
  GachaRecord record,
) {
  _log.info(
    'open rid=${record.resourceId} name=${record.name} '
    'quality=${record.qualityLevel}',
  );
  return showDialog<void>(
    context: context,
    builder: (_) => GachaItemDetailDialog(record: record),
  );
}

/// 把任意 [child] 包成可點區塊；[hasItemDetailContent] 為 false 時 passthrough。
class GachaItemTapTarget extends ConsumerWidget {
  /// 建立 [GachaItemTapTarget]。
  const GachaItemTapTarget({
    super.key,
    required this.record,
    required this.child,
  });

  /// 對應 record。
  final GachaRecord record;

  /// 子 widget。
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!hasItemDetailContent(ref, record)) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showGachaItemDetailDialog(context, record),
        child: child,
      ),
    );
  }
}

/// 圖片的下載／載入狀態。
sealed class _ImageLoadState {
  /// 建立 [_ImageLoadState]。
  const _ImageLoadState();
}

/// 下載中。
class _ImageLoading extends _ImageLoadState {
  /// 建立 [_ImageLoading]。
  const _ImageLoading();
}

/// 本地已有 cache 檔，可直接 `Image.file` 顯示。
class _ImageReady extends _ImageLoadState {
  /// 建立 [_ImageReady]。
  const _ImageReady(this.file);

  /// 對應的本地 cache 檔。
  final File file;
}

/// 下載失敗。
class _ImageFailed extends _ImageLoadState {
  /// 建立 [_ImageFailed]。
  const _ImageFailed();
}
```

- [ ] **Step 4：跑整支 dialog 測試確認通過（新舊案例都綠）**

Run: `flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart`
Expected：All tests passed!（含既有 `hasItemDetailContent`／渲染／TapTarget／illustration 可縮放，及新增 2 案例）

- [ ] **Step 5：Commit**

```bash
git add lib/widgets/dialogs/gacha_item_detail_dialog.dart test/widgets/dialogs/gacha_item_detail_dialog_test.dart
git commit -m "feat(item-detail): restore chip-based image switcher (illustration + icon-last)"
```

---

## Task 5：更新 `docs/鳴潮相關資料.md` 圖片來源說明（Part A 收尾）

**Files:**
- Modify: `docs/鳴潮相關資料.md`（約 line 233 與對照表 line 252）

> 現有兩處宣稱「武器/道具一律無圖、不需抓取」已不再成立（武器走 encore）。更新為現況。

- [ ] **Step 1：更新 line 233 的「重要」區塊**

將：
```markdown
> **重要（只有角色有圖）**：官方僅攻略站提供圖片，且**只涵蓋角色**。因此 `resourceType` 為「武器」「道具」者（8 碼 `resourceId`）**一律沒有圖片來源**，不需嘗試抓取。UI 需自行處理「無圖」情境（顯示 placeholder／僅文字／依稀有度底色等），表格、時間軸、分享圖等所有用到 icon 的地方都要能容忍道具無圖。
```
改為：
```markdown
> **重要（角色官方、武器 encore fallback）**：官方攻略站只涵蓋**角色**圖。**武器**（8 碼 `resourceId`）改走 **encore.moe** fallback：`https://api-v2.encore.moe/resource/Data/Game/Aki/UI/UIResources/Common/Image/IconWeapon/T_IconWeapon{resourceId}_UI.webp`（檔名內嵌 resourceId，由紀錄直接組，`fetchItemImages` 在 guide-server 回 null 後輕量探測）。仍**不靠 `resourceType`／位數預判是否有圖**（D7），由實際抓取結果決定。**「道具」型**（8 碼非武器）encore 武器端點無此類 → 仍無圖。UI 一律能容忍無圖（placeholder／依稀有度底色），表格、時間軸、分享圖等皆然。素材版權屬 Kuro Games，僅執行期抓取＋本機快取、不 bundle 進 release。詳見 `memory/wuwa-icon-sources.md`。
```

- [ ] **Step 2：更新對照表 line 252 的「圖片/補充資料」列**

將該列鳴潮欄：
```
官方攻略站，**僅角色有圖**（武器/道具無圖）；資料用 API 回應本身
```
改為：
```
官方攻略站（角色）＋ encore.moe（武器 fallback）；道具仍無圖；資料用 API 回應本身
```

- [ ] **Step 3：Commit**

```bash
git add docs/鳴潮相關資料.md
git commit -m "docs: note encore.moe weapon icon fallback in data reference"
```

---

## Task 6：全專案品質檢查與手動驗收

**Files:** 無（驗證 + 收尾）

- [ ] **Step 1：格式化**

Run: `dart format lib/ test/`
Expected：無待修改（若有改動，`git add` 後一起 commit）。

- [ ] **Step 2：靜態分析**

Run: `flutter analyze`
Expected：`No issues found!`

- [ ] **Step 3：全測試**

Run: `flutter test`
Expected：`All tests passed!`

- [ ] **Step 4（若 Step 1 有格式改動才需要）：Commit 格式修正**

```bash
git add -A
git commit -m "style: dart format after weapon icon and detail tabs"
```

- [ ] **Step 5：手動驗收（本機實跑，需網路）**

先 curl 確認 encore 在本機可達且 ranged-GET 行為符合預期：

```bash
curl -s -o NUL -w "%{http_code}\n" -H "Range: bytes=0-0" -H "User-Agent: wuthering-waves-convene-gacha-analyzer" "https://api-v2.encore.moe/resource/Data/Game/Aki/UI/UIResources/Common/Image/IconWeapon/T_IconWeapon21010011_UI.webp"
```
Expected：`200` 或 `206`。若回 `405`／其他非 2xx，回 Task 2 將探測改為 `client.head(...)` 或調整 Range 行為後重驗。

再跑 app（Windows）：

```bash
flutter run -d windows
```
驗收項目：
1. 既有帳號更新後，**武器**在表格／時間軸／五星一覽出現 icon（非 placeholder）。
2. 點**武器** → 詳情可開、**無 chip 列**、放大顯示 icon、可再點開縮放。
3. 點**角色** → 詳情有 **2 個 chip**（立繪、Icon），可切換，**Icon 在最後**，立繪可縮放。
4. encore 不可達／某武器 404 → 顯示 placeholder，app 不崩、其他功能正常。

---

## 完成後

實作完成、全綠且手動驗收通過後，使用 `superpowers:finishing-a-development-branch` 決定合併 / PR / 收尾（分支 `feat/weapon-icon-and-detail-tabs`）。**不主動 git push。**

---

## Self-Review（plan 對 spec 覆蓋檢查）

- **Part A 武器來源** → Task 2（fetcher + 測試）、Task 5（docs）。✓
- **順序 fallback / 不靠 resourceType 預判（D7）** → Task 2 `fetchItemImages` 先 guide 後 encore、dartdoc 載明。✓
- **存在性探測（ranged GET，避開 HEAD 405 風險）** → Task 2 `_fetchEncoreWeaponImage`（Range: bytes=0-0，接受 200/206）；Task 6 Step 5 curl 驗證 + HEAD 後備指引。✓
- **repository 兩階段不動** → 計畫未列任何 `gacha_repository.dart` 改動。✓
- **Part B chip 切換器（立繪+icon-last、單圖自動隱藏、修 spinner）** → Task 4（dialog + 測試）。✓
- **l10n galleryIllustrationLabel（四語系）** → Task 3。✓
- **可點性 = icon 已快取（武器可點）** → Task 4 `hasItemDetailContent` 不變 + 新增武器/角色案例。✓
- **不還原描述/tags/wiki、不重引 flutter_html** → Task 4 覆寫檔不含 `flutter_html`／Html／wiki 連結。✓
- **Part C gitignore** → Task 1。✓
- **驗收條件（format/analyze/test 全綠 + 本機實跑）** → Task 6。✓
- **授權警語（僅執行期抓取、不 bundle）** → Task 5 docs 註明 + 連結 memory。✓

Placeholder / 型別一致性：URL builder `encoreWeaponIconUrl(int)` 於 Task 2 定義並於測試引用；dialog 私有型別 `_ImageLoadState`/`_ImageReady`/`_ImageLoading`/`_ImageFailed`/`_ImageChipEntry`/`_ChipKind` 全在 Task 4 同檔定義並使用，命名一致；測試引用的 `itemIconCacheFile`/`itemIllustrationCacheFile`/`mergeItemImage`/provider 皆為既有 API。無 TODO/TBD。
