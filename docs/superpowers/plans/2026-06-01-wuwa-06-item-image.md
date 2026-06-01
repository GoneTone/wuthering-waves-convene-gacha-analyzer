# Item Image Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 把原神 HoYoWiki 圖片補抓整套（`hoyowiki_fetcher` / `hoyowiki_index` / state notifier / cache usage / orchestrator）重構為去 HoYoWiki 化的鳴潮物品圖片服務，改打官方攻略站 guide-server（`roleGbId=resourceId` + `X-Language`），單表索引、單階段抓取編排、負取重試。

**Architecture:** fetcher 退化為「對一個 resourceId 打一次 guide-server，回 `{iconUrl, illustrationUrl}` 或 null（無圖）」；index 縮為單表 `items: resourceId → ItemImageEntry{iconUrl, illustrationUrl, noImage, permanentNoImage}`；notifier 只剩 `mergeItemImage`；orchestrator 對所有 unique `resourceId` 單階段抓取（負取非永久者重試、正取跳過、回 null 寫負取或永久負取），由 `hasItemImage(GachaRecord)` 統一「是否有圖」判定（D7）。

**Tech Stack:** Dart / Flutter / Riverpod Notifier / `http` package（`MockClient` 測試）/ `synchronized` Lock / `concurrent_pool.runConcurrent` / `logging`。

**前置依賴：** 本 plan 依賴 plan 03（`GachaRecord{ int resourceId, qualityLevel, String name, resourceType, ... }`、`BannerStorage{ String playerId, languageCode, Map<String,List<GachaRecord>> banners }`）與 plan 04（orchestrator 重寫的 `_fetchAllBanners` 主流程、`forceRefetch*` / `import*` 呼叫點的既有結構）。**本 plan 自己擁有「圖片進度型別交換」**（R3）：在 `lib/state/update_progress.dart` 移除 `enum HoYoWikiPhase` 與 `class FetchingHoYoWiki`、新增 `class FetchingItemImages{ int doneCount; int totalCount; }`、把 `UpdateCompleted.hoYoWikiImagesDownloaded` 改名為 `itemImagesDownloaded`（plan 04 刻意保留舊型別讓其 `_fetchHoYoWiki` 編得過，型別替換在本 plan 一次到位）。本 plan 的純新增/重寫**服務檔（fetcher、index、notifier、cache_usage）可獨立 TDD**（不依賴 `GachaRecord`，只吃 `resourceId:int` / `languageCode:String`）；`hasItemImage(GachaRecord)`、orchestrator 改寫、UI 呼叫點調整則依賴 plan 03/04 的型別到位。

**命名與套件名注意：** 所有新檔 import 前綴一律用 `package:wuthering_waves_convene_gacha_analyzer/`（plan 01 已把套件改名）。所有識別子去 HoYoWiki（D10）；`roleGbId` / `data[0].role.cardPictureUrl` / `illustrationPictureUrl` / `X-Language` 是 guide-server 的回應/查詢欄位名，照 API 原樣使用，不算違反 D10。

**Logger 命名：** `item_image.fetcher` / `item_image.index` / `item_image.storage` / `item_image.notifier` / `item_image.usage` / `item_image.refetch`（對齊既有 `gacha.*` 樹的子樹概念，但去 HoYoWiki 名）。

**git 注意：** 本專案目錄非 git repo。每個 Task 末尾的 commit 步驟照寫；若執行者尚未 `git init`，commit 步驟略過、繼續下一個 Task。整個遷移期間整體 compile 可能短暫紅燈（型別替換跨多 plan），至全部 plan 完成才全綠；本 plan 的純新增服務檔單元測試可獨立綠。

**OPEN ITEM（R17，未完成、明列）：`permanentNoImage` 永久負取最佳化尚未啟用。** `ItemImageEntry.permanentNoImage` 的 schema（欄位、序列化、worklist 跳過邏輯）本 plan 已完整實作並測試，但**判定「何時可標永久負取」的條件待 §九 API 樣本確認**：目前尚無法從 guide-server 回應穩定區分「非角色（應永久負取、不再重試）」與「角色但圖暫未上架（應每次重試）」。在該樣本確認前，`_fetchItemImages` 對所有 null 回應一律寫 `permanentNoImage:false`（即每次更新都重試），永久負取分支**不**啟用。這是 explicit open-item，不視為已完成；待 §九 取得非角色回應形態樣本後再補「設 `permanentNoImage:true`」的判定，並補對應測試。

---

## Task 1: 新增 `item_image_fetcher.dart`（fetcher）

把 `hoyowiki_fetcher.dart` 重構為對單一 `resourceId` 打一次 guide-server 的 `fetchItemImages`，刪掉 search/entry/gallery/tags 整套，保留 `downloadImage`。純新增檔，可獨立 TDD。

**Files:**
- Create: `lib/services/item_image_fetcher.dart`
- Create (test): `test/services/item_image_fetcher_test.dart`
- Delete (Task 9 統一刪舊檔，本 Task 先不動 `lib/services/hoyowiki_fetcher.dart`)

### 步驟

- [ ] 建立失敗測試 `test/services/item_image_fetcher_test.dart`，貼上以下完整內容：

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
          if (cardPictureUrl != null) 'cardPictureUrl': cardPictureUrl,
          if (illustrationPictureUrl != null)
            'illustrationPictureUrl': illustrationPictureUrl,
        };
  final body = jsonEncode({
    'code': 0,
    'message': 'success',
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

void main() {
  group('ItemImageFetcher.fetchItemImages', () {
    test('角色有圖 → 回 (iconUrl, illustrationUrl)', () async {
      final mock = MockClient(
        (_) async => _listOk(
          cardPictureUrl: 'https://x/card.png',
          illustrationPictureUrl: 'https://x/illust.png',
        ),
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 1211,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNotNull);
      expect(out!.iconUrl, 'https://x/card.png');
      expect(out.illustrationUrl, 'https://x/illust.png');
    });

    test('帶 roleGbId query 與 X-Language header', () async {
      late http.BaseRequest captured;
      final mock = MockClient((req) async {
        captured = req;
        return _listOk(
          cardPictureUrl: 'https://x/card.png',
          illustrationPictureUrl: 'https://x/illust.png',
        );
      });
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

    test('data 為空 → null（非角色/無此物）', () async {
      final mock = MockClient((_) async => _listOk(emptyData: true));
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 21010024,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNull);
    });

    test('data[0].role 為 null → null', () async {
      final mock = MockClient((_) async => _listOk(nullRole: true));
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 9999,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNull);
    });

    test('role 缺 cardPictureUrl（圖未上架）→ null', () async {
      final mock = MockClient(
        (_) async => _listOk(illustrationPictureUrl: 'https://x/illust.png'),
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 1211,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNull);
    });

    test('cardPictureUrl 為空字串 → null', () async {
      final mock = MockClient(
        (_) async => _listOk(
          cardPictureUrl: '',
          illustrationPictureUrl: 'https://x/illust.png',
        ),
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 1211,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNull);
    });

    test('有 card 但 illustration 缺 → illustrationUrl 為空字串、仍算有圖', () async {
      final mock = MockClient(
        (_) async => _listOk(cardPictureUrl: 'https://x/card.png'),
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

    test('code != 0 → null（不 throw）', () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({'code': -1, 'message': 'fail', 'data': []}),
          200,
        ),
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 1211,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNull);
    });

    test('非 2xx → null（不 throw）', () async {
      final mock = MockClient((_) async => http.Response('', 500));
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 1211,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNull);
    });

    test('回應非合法 JSON → null（不 throw）', () async {
      final mock = MockClient((_) async => http.Response('{not json', 200));
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 1211,
        languageCode: 'zh-Hant',
        client: mock,
      );
      expect(out, isNull);
    });

    test('連線丟例外 → null（不 throw）', () async {
      final mock = MockClient(
        (_) async => throw const SocketException('refused'),
      );
      final out = await ItemImageFetcher().fetchItemImages(
        resourceId: 1211,
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

- [ ] 跑 `flutter test test/services/item_image_fetcher_test.dart`，預期失敗（`Error: Couldn't resolve the package 'wuthering_waves_convene_gacha_analyzer'` 或 `Target of URI doesn't exist: '.../item_image_fetcher.dart'`），確認測試先紅。
- [ ] 建立 `lib/services/item_image_fetcher.dart`，貼上以下完整內容：

```dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 與官方攻略站 guide-server 互動的 fetcher，只取角色圖片 + 通用圖檔下載。
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

  /// guide-server introduction/list API base URL。
  static final _listBase = Uri.parse(
    'https://guide-server.aki-game.net/introduction/list',
  );

  /// 以 [resourceId] 走攻略站 introduction/list 取角色圖。
  ///
  /// 必送 `X-Language: $languageCode` header（須與攔到的喚取記錄 body
  /// `languageCode` 一致）。回 `(iconUrl, illustrationUrl)`（取
  /// `data[0].role.cardPictureUrl` / `illustrationPictureUrl`），或 `null`
  /// 代表無此物的圖（非角色／data 空／role 缺欄位／圖尚未上架）。
  ///
  /// 防呆：data 可能空、role 可能 null 或缺欄位、回應可能非 JSON 或非 2xx；
  /// 任一情況一律回 `null`（不 throw），caller 寫負取標記、下次更新重試。
  Future<({String iconUrl, String illustrationUrl})?> fetchItemImages({
    required int resourceId,
    required String languageCode,
    required http.Client client,
  }) async {
    final url = _listBase.replace(
      queryParameters: {'roleGbId': '$resourceId'},
    );
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
      if (code is! int || code != 0) {
        _log.warning(
          'list code=$code resourceId=$resourceId lang=$languageCode '
          'msg=${body['message']}',
        );
        return null;
      }
      final data = body['data'];
      if (data is! List || data.isEmpty) {
        _log.fine('list empty data resourceId=$resourceId (no image)');
        return null;
      }
      final first = data.first;
      if (first is! Map<String, dynamic>) return null;
      final role = first['role'];
      if (role is! Map<String, dynamic>) {
        _log.fine('list role missing resourceId=$resourceId (no image)');
        return null;
      }
      final iconUrl = (role['cardPictureUrl'] as String?) ?? '';
      if (iconUrl.isEmpty) {
        _log.fine('list cardPictureUrl empty resourceId=$resourceId (no image)');
        return null;
      }
      final illustrationUrl =
          (role['illustrationPictureUrl'] as String?) ?? '';
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

- [ ] 跑 `dart format lib/services/item_image_fetcher.dart test/services/item_image_fetcher_test.dart`。
- [ ] 跑 `flutter test test/services/item_image_fetcher_test.dart`，預期全部通過（若整體 analyze 因其他 plan 未完成而紅燈，這支獨立測試仍應綠）。
- [ ] commit（若有 git）：`feat(item-image): add ItemImageFetcher for guide-server character images`

---

## Task 2: 新增 `item_image_index.dart`（單表索引 + storage + 檔名推導）

把 `hoyowiki_index.dart` 三表（search/entries/menuIds）縮成單表 `items: resourceId → ItemImageEntry`，全新 schema（無舊遷移），新增 illustration 檔名推導，刪 gallery 檔名。純新增檔，可獨立 TDD。

**Files:**
- Create: `lib/services/item_image_index.dart`
- Create (test): `test/services/item_image_index_test.dart`

### 步驟

- [ ] 建立失敗測試 `test/services/item_image_index_test.dart`，貼上以下完整內容：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';

void main() {
  group('ItemImageIndex.lookupImage', () {
    test('命中回 entry', () {
      const entry = ItemImageEntry(
        iconUrl: 'https://x/card.png',
        illustrationUrl: 'https://x/illust.png',
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
            illustrationUrl: null,
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
        illustrationUrl: '',
        noImage: false,
        permanentNoImage: false,
      );
      expect(e.hasIcon, isTrue);
    });

    test('負取 → false', () {
      const e = ItemImageEntry(
        iconUrl: null,
        illustrationUrl: null,
        noImage: true,
        permanentNoImage: false,
      );
      expect(e.hasIcon, isFalse);
    });

    test('iconUrl 為空字串 → false', () {
      const e = ItemImageEntry(
        iconUrl: '',
        illustrationUrl: '',
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
            illustrationUrl: 'https://x/illust.png',
            noImage: false,
            permanentNoImage: false,
          ),
        },
      );
      await storage.save(original);
      final loaded = await storage.load();
      final e = loaded.lookupImage(1211)!;
      expect(e.iconUrl, 'https://x/card.png');
      expect(e.illustrationUrl, 'https://x/illust.png');
      expect(e.noImage, isFalse);
      expect(e.permanentNoImage, isFalse);
    });

    test('save → load roundtrip（負取 + 永久負取）', () async {
      final original = ItemImageIndex(
        items: const {
          21010024: ItemImageEntry(
            iconUrl: null,
            illustrationUrl: null,
            noImage: true,
            permanentNoImage: false,
          ),
          21040084: ItemImageEntry(
            iconUrl: null,
            illustrationUrl: null,
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
              illustrationUrl: '',
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
              illustrationUrl: '',
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
              illustrationUrl: '',
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

  group('itemIllustrationCacheFile', () {
    final baseDir = Directory.systemTemp;

    test('組合為 <resourceId>_illustration.<ext>', () {
      final f = itemIllustrationCacheFile(
        baseDir: baseDir,
        resourceId: 1211,
        url: 'https://x/illust.jpg',
      );
      expect(f.path, endsWith('1211_illustration.jpg'));
    });
  });
}
```

- [ ] 跑 `flutter test test/services/item_image_index_test.dart`，預期失敗（`Target of URI doesn't exist`）。
- [ ] 建立 `lib/services/item_image_index.dart`，貼上以下完整內容：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 單一 resourceId 的圖片索引條目（正取 / 負取 / 永久負取）。
///
/// - 正取：[iconUrl] 非空、[noImage] = false → [hasIcon] 為 true。
/// - 負取（非永久）：[noImage] = true、[permanentNoImage] = false，每次更新重試。
/// - 永久負取：[permanentNoImage] = true（確認非角色），不再重試。
class ItemImageEntry {
  /// 建立 [ItemImageEntry]。
  const ItemImageEntry({
    required this.iconUrl,
    required this.illustrationUrl,
    required this.noImage,
    required this.permanentNoImage,
  });

  /// 角色 icon 小圖 CDN URL（`cardPictureUrl`）；負取時為 null。
  final String? iconUrl;

  /// 角色立繪大圖 CDN URL（`illustrationPictureUrl`）；無此圖時為空字串、負取時為 null。
  final String? illustrationUrl;

  /// 負取標記：本物經 API 確認無圖（非角色／圖未上架）。
  final bool noImage;

  /// 永久負取標記：確認非角色、不再重試（D11 最佳化）。
  ///
  /// OPEN ITEM（R17）：判定條件待 §九 API 樣本確認前一律寫 false（每次重試），
  /// 永久負取分支尚未啟用；schema 先就位，待樣本到位再補判定。
  final bool permanentNoImage;

  /// 是否有可顯示的成功 icon（D7：是否有圖的權威判定基礎）。
  bool get hasIcon => !noImage && iconUrl != null && iconUrl!.isNotEmpty;
}

/// 跨帳號共用的物品圖片 lookup index（單表）。
class ItemImageIndex {
  /// 建立 [ItemImageIndex]。
  const ItemImageIndex({required this.items});

  /// 建立空 index。
  const ItemImageIndex.empty() : items = const {};

  /// `resourceId` → [ItemImageEntry]（含正取 / 負取 / 永久負取）。
  final Map<int, ItemImageEntry> items;

  /// 以 [resourceId] 查 entry；查無回 null。
  ItemImageEntry? lookupImage(int resourceId) => items[resourceId];
}

/// 負責 `item_image_index.json` 的讀寫（atomic write，跨帳號共用）。
class ItemImageIndexStorage {
  /// 建立 [ItemImageIndexStorage]，需指定圖檔快取根目錄 [baseDir]。
  ItemImageIndexStorage(this.baseDir);

  /// Logger 實例。
  static final _log = Logger('item_image.storage');

  /// 資料根目錄。
  final Directory baseDir;

  /// index 檔路徑。
  File get _file => File('${baseDir.path}/item_image_index.json');

  /// 讀取 index；檔案不存在或解析失敗回空 index。
  Future<ItemImageIndex> load() async {
    final f = _file;
    if (!await f.exists()) return const ItemImageIndex.empty();
    try {
      final text = await f.readAsString();
      final json = jsonDecode(text) as Map<String, dynamic>;
      final itemsJson = (json['items'] as Map<String, dynamic>?) ?? const {};
      final items = <int, ItemImageEntry>{};
      itemsJson.forEach((k, v) {
        final id = int.tryParse(k);
        if (id == null || v is! Map<String, dynamic>) return;
        items[id] = ItemImageEntry(
          iconUrl: v['icon_url'] as String?,
          illustrationUrl: v['illustration_url'] as String?,
          noImage: (v['no_image'] as bool?) ?? false,
          permanentNoImage: (v['permanent_no_image'] as bool?) ?? false,
        );
      });
      return ItemImageIndex(items: items);
    } catch (e, st) {
      _log.warning('load failed, return empty index', e, st);
      return const ItemImageIndex.empty();
    }
  }

  /// 將 [index] 寫回磁碟（atomic rename）。
  Future<void> save(ItemImageIndex index) async {
    final json = {
      'version': 1,
      'items': index.items.map(
        (k, v) => MapEntry('$k', {
          'icon_url': v.iconUrl,
          'illustration_url': v.illustrationUrl,
          'no_image': v.noImage,
          'permanent_no_image': v.permanentNoImage,
        }),
      ),
    };
    await baseDir.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(json));
    await tmp.rename(_file.path);
    _log.fine('saved items=${index.items.length}');
  }

  /// 將 index 重設為空，用於「強制重抓所有物品圖片」操作。
  Future<void> clearAll() async {
    await save(const ItemImageIndex.empty());
    _log.info('clearAll: index reset to empty');
  }

  /// 刪除 [baseDir] 內所有圖檔並重建空目錄。
  /// 目錄不存在時直接建立；失敗（權限被鎖等）直接拋給呼叫方處理。
  Future<void> wipeCacheDirectory() async {
    if (await baseDir.exists()) {
      await baseDir.delete(recursive: true);
    }
    await baseDir.create(recursive: true);
    _log.info(
      'wipeCacheDirectory: cache cleared at ${sanitizeFsPath(baseDir.path)}',
    );
  }
}

/// 推導 icon 的 cache 路徑：`<resourceId>_icon.<ext>`。
File itemIconCacheFile({
  required Directory baseDir,
  required int resourceId,
  required String url,
}) {
  return File('${baseDir.path}/${resourceId}_icon.${_extFromUrl(url)}');
}

/// 推導 illustration 大圖的 cache 路徑：`<resourceId>_illustration.<ext>`。
File itemIllustrationCacheFile({
  required Directory baseDir,
  required int resourceId,
  required String url,
}) {
  return File(
    '${baseDir.path}/${resourceId}_illustration.${_extFromUrl(url)}',
  );
}

/// 從 [url] 推導副檔名（無則回 `png`）。
String _extFromUrl(String url) {
  if (url.isEmpty) return 'png';
  final qIdx = url.indexOf('?');
  final clean = qIdx >= 0 ? url.substring(0, qIdx) : url;
  final dotIdx = clean.lastIndexOf('.');
  final slashIdx = clean.lastIndexOf('/');
  if (dotIdx <= slashIdx || dotIdx == clean.length - 1) return 'png';
  final ext = clean.substring(dotIdx + 1).toLowerCase();
  const allowed = {'png', 'jpg', 'jpeg', 'webp', 'gif'};
  return allowed.contains(ext) ? ext : 'png';
}
```

- [ ] 跑 `dart format lib/services/item_image_index.dart test/services/item_image_index_test.dart`。
- [ ] 跑 `flutter test test/services/item_image_index_test.dart`，預期全部通過。
- [ ] commit（若有 git）：`feat(item-image): add ItemImageIndex single-table index + storage`

---

## Task 3: 新增 `state/item_image_index.dart`（providers + Notifier `mergeItemImage`）

把 `state/hoyowiki_index.dart` 重構：providers 改名、Notifier 只剩 `mergeItemImage`（含負取/永久負取）+ 沿用 `bumpCacheRevision`/`resetAll`/`waitForLoad`/`_lock`。純新增檔，可獨立 TDD。

**Files:**
- Create: `lib/state/item_image_index.dart`
- Create (test): `test/state/item_image_index_test.dart`

### 步驟

- [ ] 建立失敗測試 `test/state/item_image_index_test.dart`，貼上以下完整內容：

```dart
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

  test('mergeItemImage 正取：寫入並 persist', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await notifier.mergeItemImage(
      resourceId: 1211,
      iconUrl: 'https://x/card.png',
      illustrationUrl: 'https://x/illust.png',
      noImage: false,
      permanentNoImage: false,
    );
    final e = container.read(itemImageIndexProvider).lookupImage(1211)!;
    expect(e.iconUrl, 'https://x/card.png');
    expect(e.hasIcon, isTrue);
    final reloaded = await ItemImageIndexStorage(tempDir).load();
    expect(reloaded.lookupImage(1211)!.iconUrl, 'https://x/card.png');
  });

  test('mergeItemImage 負取：寫入 noImage', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await notifier.mergeItemImage(
      resourceId: 21010024,
      iconUrl: null,
      illustrationUrl: null,
      noImage: true,
      permanentNoImage: false,
    );
    final e = container.read(itemImageIndexProvider).lookupImage(21010024)!;
    expect(e.noImage, isTrue);
    expect(e.permanentNoImage, isFalse);
    expect(e.hasIcon, isFalse);
  });

  test('mergeItemImage 永久負取：寫入 permanentNoImage', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await notifier.mergeItemImage(
      resourceId: 21040084,
      iconUrl: null,
      illustrationUrl: null,
      noImage: true,
      permanentNoImage: true,
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(21040084)!
          .permanentNoImage,
      isTrue,
    );
  });

  test('mergeItemImage 由負取改正取（官方後補圖）→ 覆蓋成正取', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await notifier.mergeItemImage(
      resourceId: 1211,
      iconUrl: null,
      illustrationUrl: null,
      noImage: true,
      permanentNoImage: false,
    );
    await notifier.mergeItemImage(
      resourceId: 1211,
      iconUrl: 'https://x/card.png',
      illustrationUrl: '',
      noImage: false,
      permanentNoImage: false,
    );
    final e = container.read(itemImageIndexProvider).lookupImage(1211)!;
    expect(e.noImage, isFalse);
    expect(e.hasIcon, isTrue);
  });

  test('bumpCacheRevision 換新 identity 但內容不變', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await notifier.mergeItemImage(
      resourceId: 1211,
      iconUrl: 'https://x/card.png',
      illustrationUrl: '',
      noImage: false,
      permanentNoImage: false,
    );
    final before = container.read(itemImageIndexProvider);
    notifier.bumpCacheRevision();
    final after = container.read(itemImageIndexProvider);
    expect(identical(before, after), isFalse);
    expect(after.items, before.items);
  });

  test('並發 mergeItemImage 全部寫入不丟失', () async {
    final notifier = container.read(itemImageIndexProvider.notifier);
    await Future.wait(
      List.generate(
        10,
        (i) => notifier.mergeItemImage(
          resourceId: i,
          iconUrl: 'https://x/$i.png',
          illustrationUrl: '',
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
              illustrationUrl: '',
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
}
```

- [ ] 跑 `flutter test test/state/item_image_index_test.dart`，預期失敗（`Target of URI doesn't exist`）。
- [ ] 建立 `lib/state/item_image_index.dart`，貼上以下完整內容：

```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';

/// 物品圖片 index 儲存層，main.dart 用 `overrideWithValue` 注入。
final itemImageIndexStorageProvider = Provider<ItemImageIndexStorage>((ref) {
  throw UnimplementedError(
    'itemImageIndexStorageProvider must be overridden in main()',
  );
});

/// 物品圖檔快取目錄，main.dart 用 `overrideWithValue` 注入。
final itemImageCacheDirProvider = Provider<Directory>((ref) {
  throw UnimplementedError(
    'itemImageCacheDirProvider must be overridden in main()',
  );
});

/// 物品圖片 API fetcher；預設值即可，無需 override。
final itemImageFetcherProvider = Provider<ItemImageFetcher>(
  (ref) => ItemImageFetcher(),
);

/// 當前載入的 [ItemImageIndex]；透過 [ItemImageIndexNotifier] 變更。
final itemImageIndexProvider =
    NotifierProvider<ItemImageIndexNotifier, ItemImageIndex>(
      ItemImageIndexNotifier.new,
    );

/// 包裝 [ItemImageIndexStorage] 的 Riverpod Notifier；mutation 後同步 persist。
class ItemImageIndexNotifier extends Notifier<ItemImageIndex> {
  static final _log = Logger('item_image.notifier');

  Completer<void>? _loadCompleter;

  /// 保護 mergeItemImage 的 read-modify-write，避免並發 worker 互相覆蓋。
  final _lock = Lock();

  @override
  ItemImageIndex build() {
    _loadCompleter = Completer<void>();
    unawaited(_load());
    return const ItemImageIndex.empty();
  }

  /// 從 storage 載入並 emit 給 state。
  Future<void> _load() async {
    try {
      final storage = ref.read(itemImageIndexStorageProvider);
      final loaded = await storage.load();
      if (!ref.mounted) return;
      state = loaded;
    } catch (e, st) {
      _log.warning('load failed', e, st);
    } finally {
      _loadCompleter?.complete();
    }
  }

  /// 等待初始 load 結束。
  Future<void> waitForLoad() => _loadCompleter?.future ?? Future.value();

  /// 寫入單一 resourceId 的抓取結果並 persist。
  ///
  /// 正取：傳 `iconUrl` 非 null + `noImage:false`；負取：`noImage:true` + url 傳
  /// null；確認非角色的永久負取再帶 `permanentNoImage:true`。同 resourceId 重打
  /// 一律以新結果覆蓋（讓官方後補的角色圖在下次更新由負取翻成正取）。
  Future<void> mergeItemImage({
    required int resourceId,
    required String? iconUrl,
    required String? illustrationUrl,
    required bool noImage,
    required bool permanentNoImage,
  }) async {
    await _lock.synchronized(() async {
      final newItems = Map<int, ItemImageEntry>.from(state.items)
        ..[resourceId] = ItemImageEntry(
          iconUrl: iconUrl,
          illustrationUrl: illustrationUrl,
          noImage: noImage,
          permanentNoImage: permanentNoImage,
        );
      await _saveAndEmit(ItemImageIndex(items: newItems));
      _log.fine(
        'merge resourceId=$resourceId noImage=$noImage '
        'permanent=$permanentNoImage hasIcon=${iconUrl?.isNotEmpty == true}',
      );
    });
  }

  /// 在 cache 檔案下載完成後呼叫；state 內容不變但 identity 換新，
  /// 觸發 watch itemImageIndexProvider 的 widget 重新 build 以挑到新檔。
  void bumpCacheRevision() {
    state = ItemImageIndex(items: state.items);
  }

  /// 強制重抓圖片用：清空整個 index 與 cache 目錄。
  Future<void> resetAll() async {
    final storage = ref.read(itemImageIndexStorageProvider);
    await storage.clearAll();
    await storage.wipeCacheDirectory();
    if (!ref.mounted) return;
    state = const ItemImageIndex.empty();
    _log.info('resetAll: index+cache wiped');
  }

  /// 內部 helper：寫檔 + emit。
  Future<void> _saveAndEmit(ItemImageIndex next) async {
    final storage = ref.read(itemImageIndexStorageProvider);
    await storage.save(next);
    if (!ref.mounted) return;
    state = next;
  }
}
```

- [ ] 跑 `dart format lib/state/item_image_index.dart test/state/item_image_index_test.dart`。
- [ ] 跑 `flutter test test/state/item_image_index_test.dart`，預期全部通過。
- [ ] commit（若有 git）：`feat(item-image): add ItemImageIndexNotifier with mergeItemImage`

---

## Task 4: 新增 `state/item_image_cache_usage.dart`（去 gallery 的用量分項）

把 `state/hoyowiki_cache_usage.dart` 重構：移除 gallery 分項，只算 icon 與 illustration 兩項。純新增檔，可獨立 TDD。

**Files:**
- Create: `lib/state/item_image_cache_usage.dart`
- Create (test): `test/state/item_image_cache_usage_test.dart`

### 步驟

- [ ] 建立失敗測試 `test/state/item_image_cache_usage_test.dart`，貼上以下完整內容：

```dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_cache_usage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';

void main() {
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('item_image_usage_');
    container = ProviderContainer(
      overrides: [itemImageCacheDirProvider.overrideWithValue(tempDir)],
    );
    addTearDown(container.dispose);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> touch(String name, int size) async {
    final f = File('${tempDir.path}/$name');
    await f.writeAsBytes(List<int>.filled(size, 0));
  }

  test('空目錄 → 0 / 0', () async {
    final usage = await container.read(itemImageCacheUsageProvider.future);
    expect(usage.iconBytes, 0);
    expect(usage.illustrationBytes, 0);
    expect(usage.totalBytes, 0);
  });

  test('只 icon', () async {
    await touch('1211_icon.png', 1234);
    await touch('1601_icon.jpg', 4321);
    final usage = await container.read(itemImageCacheUsageProvider.future);
    expect(usage.iconBytes, 1234 + 4321);
    expect(usage.illustrationBytes, 0);
  });

  test('只 illustration', () async {
    await touch('1211_illustration.png', 5000);
    final usage = await container.read(itemImageCacheUsageProvider.future);
    expect(usage.iconBytes, 0);
    expect(usage.illustrationBytes, 5000);
  });

  test('混合 + 其他檔被忽略', () async {
    await touch('1211_icon.png', 100);
    await touch('1211_illustration.webp', 200);
    await touch('item_image_index.json', 999);
    await touch('readme.txt', 50);
    final usage = await container.read(itemImageCacheUsageProvider.future);
    expect(usage.iconBytes, 100);
    expect(usage.illustrationBytes, 200);
    expect(usage.totalBytes, 300);
  });

  test('cache 目錄不存在 → 0 / 0（不拋例外）', () async {
    await tempDir.delete(recursive: true);
    final usage = await container.read(itemImageCacheUsageProvider.future);
    expect(usage.iconBytes, 0);
    expect(usage.illustrationBytes, 0);
  });
}
```

- [ ] 跑 `flutter test test/state/item_image_cache_usage_test.dart`，預期失敗（`Target of URI doesn't exist`）。
- [ ] 建立 `lib/state/item_image_cache_usage.dart`，貼上以下完整內容：

```dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';

/// Logger 實例（item_image.usage 命名空間）。
final _log = Logger('item_image.usage');

/// 物品圖片快取用量分項。
@immutable
class ItemImageCacheUsage {
  /// 建立 [ItemImageCacheUsage]。
  const ItemImageCacheUsage({
    required this.iconBytes,
    required this.illustrationBytes,
  });

  /// 角色 icon 圖檔總大小（bytes）。
  final int iconBytes;

  /// 角色 illustration 大圖圖檔總大小（bytes）。
  final int illustrationBytes;

  /// icon + illustration 總和。
  int get totalBytes => iconBytes + illustrationBytes;
}

/// 掃描 [itemImageCacheDirProvider] 目錄，分項計算 icon 與 illustration 總大小。
///
/// `autoDispose` → 離開設定頁自動釋放，下次進設定頁重新計算。
/// 失敗（權限等）讓 `FutureProvider` 自然進 `AsyncError` 狀態。
final itemImageCacheUsageProvider =
    FutureProvider.autoDispose<ItemImageCacheUsage>((ref) async {
      final dir = ref.read(itemImageCacheDirProvider);
      if (!await dir.exists()) {
        _log.fine('cache dir not exist → zero');
        return const ItemImageCacheUsage(iconBytes: 0, illustrationBytes: 0);
      }
      var iconBytes = 0;
      var illustrationBytes = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final path = entity.path;
        final size = await entity.length();
        if (path.contains('_illustration.')) {
          illustrationBytes += size;
        } else if (path.contains('_icon.')) {
          iconBytes += size;
        }
      }
      _log.fine('scan done icon=$iconBytes illustration=$illustrationBytes');
      return ItemImageCacheUsage(
        iconBytes: iconBytes,
        illustrationBytes: illustrationBytes,
      );
    });
```

- [ ] 跑 `dart format lib/state/item_image_cache_usage.dart test/state/item_image_cache_usage_test.dart`。
- [ ] 跑 `flutter test test/state/item_image_cache_usage_test.dart`，預期全部通過。
- [ ] commit（若有 git）：`feat(item-image): add ItemImageCacheUsage provider (no gallery)`

---

## Task 5: 新增 `hasItemImage(GachaRecord)` 共用判定（D7）

新增「是否有圖」的權威判定函式：`imageIndex.lookupImage(r.resourceId)` 有成功 icon。依賴 plan 03 的 `GachaRecord.resourceId`。放在 `item_image_index.dart` 旁的薄 helper 檔，給 UI 與 orchestrator 共用。

**Files:**
- Create: `lib/services/item_image_lookup.dart`
- Create (test): `test/services/item_image_lookup_test.dart`

### 步驟

- [ ] 建立失敗測試 `test/services/item_image_lookup_test.dart`，貼上以下完整內容（`GachaRecord` 來自 plan 03 契約）：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_lookup.dart';

GachaRecord _rec(int resourceId) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: '1',
  name: 'X',
  count: 1,
  time: DateTime.utc(2026, 5, 21),
);

void main() {
  group('hasItemImage', () {
    test('索引有成功 icon → true', () {
      final index = ItemImageIndex(
        items: const {
          1211: ItemImageEntry(
            iconUrl: 'https://x/card.png',
            illustrationUrl: '',
            noImage: false,
            permanentNoImage: false,
          ),
        },
      );
      expect(hasItemImage(index, _rec(1211)), isTrue);
    });

    test('索引為負取 → false', () {
      const index = ItemImageIndex(
        items: {
          21010024: ItemImageEntry(
            iconUrl: null,
            illustrationUrl: null,
            noImage: true,
            permanentNoImage: false,
          ),
        },
      );
      expect(hasItemImage(index, _rec(21010024)), isFalse);
    });

    test('索引無此 resourceId（未抓）→ false', () {
      const index = ItemImageIndex.empty();
      expect(hasItemImage(index, _rec(1211)), isFalse);
    });
  });
}
```

- [ ] 跑 `flutter test test/services/item_image_lookup_test.dart`，預期失敗（`Target of URI doesn't exist`，或 `GachaRecord` 簽名不符——若 plan 03 尚未完成，本 Task 留待 plan 03 後再驗；本 plan 仍先建立檔案）。
- [ ] 建立 `lib/services/item_image_lookup.dart`，貼上以下完整內容：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';

/// 判定 [record] 是否有可顯示的角色 icon（D7 權威判定）。
///
/// 唯一依據：[index].lookupImage(resourceId) 有成功下載的 icon（非負取、非缺）。
/// 一律不靠 resourceId 位數或 resourceType 字串推定。所有 icon 消費點與「可否點開
/// 詳情」一律呼叫此函式；無圖（含負取/未抓）走 placeholder。
bool hasItemImage(ItemImageIndex index, GachaRecord record) {
  final entry = index.lookupImage(record.resourceId);
  return entry?.hasIcon ?? false;
}
```

- [ ] 跑 `dart format lib/services/item_image_lookup.dart test/services/item_image_lookup_test.dart`。
- [ ] 跑 `flutter test test/services/item_image_lookup_test.dart`，預期通過（前提 plan 03 的 `GachaRecord` 已到位；否則此測試與檔案留待 plan 03 完成後驗證）。
- [ ] commit（若有 git）：`feat(item-image): add hasItemImage authoritative image check`

---

## Task 6: 改 `main.dart` cache 目錄與 provider override（去 HoYoWiki）

把 `main.dart` 的 `hoyowiki_cache` 目錄改名為 `item_image_cache`、import 與 provider override 改用新服務／state 檔。依賴 Task 2/3 的新檔。

**Files:**
- Modify: `lib/main.dart`（import 區 20-21 行、cache 目錄 95-108 行）

### 步驟

- [ ] 在 `lib/main.dart` 把 HoYoWiki 兩個 import（第 20-21 行）替換：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
```

（其餘 import 前綴由 plan 01 機械改名統一處理；本步驟只動這兩行的檔名段。）

- [ ] 把 cache 目錄建立與 storage 構造（第 95-99 行）替換為：

```dart
      final itemImageCacheDir = Directory(
        '${supportDir.path}/item_image_cache',
      );
      if (!await itemImageCacheDir.exists()) {
        await itemImageCacheDir.create(recursive: true);
      }
      final itemImageIndexStorage = ItemImageIndexStorage(itemImageCacheDir);
```

- [ ] 把 ProviderScope overrides 內兩個 HoYoWiki override（第 105-108 行）替換為：

```dart
            itemImageIndexStorageProvider.overrideWithValue(
              itemImageIndexStorage,
            ),
            itemImageCacheDirProvider.overrideWithValue(itemImageCacheDir),
```

- [ ] 跑 `dart format lib/main.dart`。
- [ ] 註記：此時整體 `flutter analyze` 仍會因其他 plan 的引用尚在 `hoyowiki_*` 而紅燈（Task 9 統一刪舊檔後收斂）；本步驟不單獨跑全 analyze，留到 Task 9 之後一起驗。
- [ ] commit（若有 git）：`refactor(item-image): rename cache dir to item_image_cache in main`

---

## Task 7: 抓取編排單階段化（重寫 orchestrator 的補圖階段，D6/D7/D8/D11）

把 `gacha_repository.dart` 的 `_fetchHoYoWiki` 三階段（search→entry→download）重寫為單階段 `_fetchItemImages`：逐 BannerStorage、對所有 unique `resourceId`（未抓或負取非永久者）用該帳號 `languageCode` 打 `fetchItemImages`，正取寫 icon（與 illustration）、回 null 寫負取（可確認非角色則永久負取）。調整三個呼叫點。依賴 plan 03（`BannerStorage.playerId`/`languageCode`、`GachaRecord.resourceId`/`resourceType`）與 plan 04（orchestrator `_fetchAllBanners` 主流程的既有結構）。

> 所有權說明（R3/R4/R5）：本 plan 06 **完整擁有**圖片補抓相關的型別交換與改名，plan 04 刻意不碰、保留舊型別讓其 `_fetchHoYoWiki` 編得過：
> - **進度型別交換（R3）**：本 Task 在 `lib/state/update_progress.dart` 移除 `enum HoYoWikiPhase` 與 `class FetchingHoYoWiki`、新增單階段 `class FetchingItemImages{ int doneCount; int totalCount; }`、把 `UpdateCompleted.hoYoWikiImagesDownloaded` 改名為 `itemImagesDownloaded`。plan 07 消費 `FetchingItemImages`/`itemImagesDownloaded`（標題/文案列）。
> - **內部方法改名（R4）**：本 Task 把 `_fetchHoYoWiki` 改名 `_fetchItemImages` 並重寫，同時更新 `_fetchAllBanners` 內的呼叫點為 `_fetchItemImages(client)`。
> - **對外 public 方法改名（R5）**：本 Task 把 `forceRefetchAllHoYoWikiImages` 改名 `forceRefetchAllItemImages`、`importAccountsAndFetchHoYoWiki` 改名 `importAccountsAndFetchItemImages`；plan 07 的 settings 呼叫一律用 `forceRefetchAllItemImages`。

**Files:**
- Modify: `lib/state/update_progress.dart`
  - 移除 `enum HoYoWikiPhase`（第 104-114 行）與 `class FetchingHoYoWiki`（第 116-133 行）
  - 新增 `class FetchingItemImages{ int doneCount; int totalCount; }`
  - `UpdateCompleted.hoYoWikiImagesDownloaded`（第 74、87-89 行）改名 `itemImagesDownloaded`
- Modify: `lib/state/gacha_repository.dart`
  - import 區（第 16、20 行的 `hoyowiki_index` → `item_image_index`）
  - `_fetchHoYoWiki`（第 759-996 行）整段刪除改 `_fetchItemImages`
  - `_HoYoWikiDownloadItem`（第 1030-1040 行）刪除
  - 三個呼叫點：`_fetchAllBanners`（第 414-433 行）、`forceRefetchAllHoYoWikiImages`（第 477-538 行，含 `resetAll`/`_refetchLog`）改名 `forceRefetchAllItemImages`、`importAccountsAndFetchHoYoWiki`（第 550-600 行）改名 `importAccountsAndFetchItemImages`
  - `debugRunHoYoWikiOnly`（第 998-1008 行）→ `debugRunItemImagesOnly`
- Create (test): `test/state/gacha_repository_item_image_test.dart`

### 步驟

- [ ] 圖片進度型別交換（R3）：在 `lib/state/update_progress.dart` 刪除 `enum HoYoWikiPhase`（第 104-114 行）與 `class FetchingHoYoWiki`（第 116-133 行），於檔尾改貼以下單階段進度型別：

```dart
/// 主資料抓取完成後，正在補齊各物品的角色圖片（單階段，無 phase enum）。
class FetchingItemImages extends UpdateProgress {
  /// 建立 [FetchingItemImages]。
  const FetchingItemImages({required this.doneCount, required this.totalCount});

  /// 目前已完成的工作項數。
  final int doneCount;

  /// 本次需補圖的總工作項數。
  final int totalCount;
}
```

- [ ] 在 `lib/state/update_progress.dart` 把 `UpdateCompleted.hoYoWikiImagesDownloaded`（建構子第 74 行具名參數 + 第 87-89 行欄位宣告）改名為 `itemImagesDownloaded`，dartdoc 改為：

```dart
  /// 本次補抓物品角色圖片成功寫入磁碟的 icon 張數。既有圖檔已存在不重抓的不算；
  /// 只計入本次新下載成功的張數。
  final int itemImagesDownloaded;
```

- [ ] 跑 `dart format lib/state/update_progress.dart`（此時 plan 04 仍引用舊 `FetchingHoYoWiki`/`hoYoWikiImagesDownloaded` 的處會紅燈，由本 Task 後續呼叫點改名一併收斂；plan 07 的標題/文案列改名屬 plan 07）。

- [ ] 在 `lib/state/gacha_repository.dart` import 區把第 16、20 行替換為：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
```
```dart
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
```

- [ ] 刪除整個 `_fetchHoYoWiki` 方法（第 759-996 行的 dartdoc + 方法本體）與檔尾 `_HoYoWikiDownloadItem` class（第 1030-1040 行）。
- [ ] 在 `gacha_repository.dart` 的 `GachaRepository` class 內、`debugImportOnly` 之後新增 `_fetchItemImages` 方法，貼上以下完整內容（dartdoc + 實作）：

```dart
  /// 補齊所有帳號喚取記錄聯集物品的角色圖片（單階段，D6/D7/D8/D11）。
  ///
  /// 流程：
  ///   1. 逐 [BannerStorage] 收集 `(resourceId, languageCode)`：每帳號用自己的
  ///      `languageCode`；同 resourceId 跨帳號取首次出現的 languageCode。
  ///   2. worklist 篩選：未抓過（index 無此 key）或「負取且非永久」
  ///      （`noImage && !permanentNoImage`）才重抓；正取（已有 icon URL）跳過。
  ///   3. 對每個 worklist 項打 [ItemImageFetcher.fetchItemImages]：
  ///      回 urls → mergeItemImage 正取 + downloadImage 寫 icon（與 illustration）；
  ///      回 null → mergeItemImage 寫負取（暫不標永久；待 §九最佳化確認 API 可
  ///      區分「非角色」後再標 permanentNoImage）。
  ///   4. 每筆成功寫檔後 bumpCacheRevision 觸發 UI rebuild。
  ///
  /// 不預先用 resourceId/resourceType 篩角色（D7：由 API 結果決定）。每筆獨立
  /// try/catch，單筆失敗不終止整段。取消（`_cancelTriggered` 或 `!ref.mounted`）
  /// 早退。回傳本次成功寫入磁碟的 icon 張數。
  Future<int> _fetchItemImages(http.Client client) async {
    var downloaded = 0;
    final fetcher = ref.read(itemImageFetcherProvider);
    final indexNotifier = ref.read(itemImageIndexProvider.notifier);
    final cacheDir = ref.read(itemImageCacheDirProvider);
    await indexNotifier.waitForLoad();

    // (1) 逐帳號收集 (resourceId, languageCode)；同 id 取首見 languageCode。
    final langByResourceId = <int, String>{};
    for (final data in state.byUid.values) {
      final lang = data.languageCode;
      if (lang.isEmpty) continue;
      for (final list in data.banners.values) {
        for (final r in list) {
          langByResourceId.putIfAbsent(r.resourceId, () => lang);
        }
      }
    }

    // (2) worklist：未抓 or 負取非永久。
    final index = ref.read(itemImageIndexProvider);
    final worklist = <(int resourceId, String lang)>[];
    for (final entry in langByResourceId.entries) {
      final existing = index.lookupImage(entry.key);
      final needFetch =
          existing == null ||
          (existing.noImage && !existing.permanentNoImage);
      if (needFetch) worklist.add((entry.key, entry.value));
    }
    if (worklist.isEmpty) return downloaded;

    bool isAborted() => !ref.mounted || _cancelTriggered;

    var done = 0;
    await runConcurrent<(int, String)>(
      items: worklist,
      concurrency: fetcher.downloadConcurrency,
      shouldAbort: isAborted,
      worker: (item) async {
        final resourceId = item.$1;
        final lang = item.$2;
        try {
          final urls = await fetcher.fetchItemImages(
            resourceId: resourceId,
            languageCode: lang,
            client: client,
          );
          if (urls == null) {
            // 負取（非永久）：官方後補圖會在下次更新由負取翻成正取。
            await indexNotifier.mergeItemImage(
              resourceId: resourceId,
              iconUrl: null,
              illustrationUrl: null,
              noImage: true,
              permanentNoImage: false,
            );
          } else {
            await indexNotifier.mergeItemImage(
              resourceId: resourceId,
              iconUrl: urls.iconUrl,
              illustrationUrl: urls.illustrationUrl,
              noImage: false,
              permanentNoImage: false,
            );
            // icon 在列表常駐顯示 → 立即下載；illustration 大圖只在詳情用，
            // 走 lazy（由 detail dialog 打開時下載），此處不預下載。
            final iconBytes = await fetcher.downloadImage(urls.iconUrl, client);
            if (iconBytes != null) {
              final file = itemIconCacheFile(
                baseDir: cacheDir,
                resourceId: resourceId,
                url: urls.iconUrl,
              );
              await file.writeAsBytes(iconBytes, flush: true);
              indexNotifier.bumpCacheRevision();
              downloaded++;
            }
          }
        } catch (e) {
          _log.warning('item image fetch failed resourceId=$resourceId err=$e');
        }
        if (!ref.mounted) return;
        done++;
        state = state.copyWith(
          progress: FetchingItemImages(
            doneCount: done,
            totalCount: worklist.length,
          ),
        );
      },
    );
    return downloaded;
  }

  /// 測試用：略過 banner fetch 直接跑 item image 階段（用既有 state.byUid）。
  @visibleForTesting
  Future<void> debugRunItemImagesOnly() async {
    _cancelTriggered = false;
    final cancellable = ref.read(cancellableHttpClientFactoryProvider)();
    try {
      await _fetchItemImages(cancellable.client);
    } finally {
      cancellable.client.close();
    }
  }
```

> `FetchingItemImages`（單階段 `{ int doneCount; int totalCount; }`，取代 `FetchingHoYoWiki`/`HoYoWikiPhase`）與 `UpdateCompleted.itemImagesDownloaded` 由**本 Task 在 `update_progress.dart` 定義/改名**（見本 Task 第一步，R3）；此處的 `_fetchItemImages` 是它們的第一個消費者。plan 07 之後再消費於更新對話框的標題/文案列。

- [ ] 把三個呼叫點對 `_fetchHoYoWiki(...)` 的呼叫改名為 `_fetchItemImages(...)`（R4），並把對外公開方法 `forceRefetchAllHoYoWikiImages` 改名 `forceRefetchAllItemImages`、`importAccountsAndFetchHoYoWiki` 改名 `importAccountsAndFetchItemImages`（R5）。`forceRefetchAllItemImages` 內 `ref.read(hoyowikiIndexProvider.notifier).resetAll()` 改為 `ref.read(itemImageIndexProvider.notifier).resetAll()`。同時把 `_fetchAllBanners`/`forceRefetchAllItemImages`/`importAccountsAndFetchItemImages` 內傳給 `UpdateCompleted` 的 `hoYoWikiImagesDownloaded:` 具名參數改成本 Task（R3）改名後的 `itemImagesDownloaded:`，本地變數 `hoYoWikiImagesDownloaded`/`images` 改名 `itemImagesDownloaded`。`debugRunHoYoWikiOnly` 已被上一步替換為 `debugRunItemImagesOnly`，刪除舊的。

> 注意：`forceRefetchAllItemImages` / `importAccountsAndFetchItemImages` 為對外公開 API，由**本 plan 06 擁有並一次改名**（R5；plan 04 不碰此兩方法名）。plan 07 的 settings_page 呼叫點一律對齊 `forceRefetchAllItemImages`（見 Task 8）。

- [ ] 建立 `test/state/gacha_repository_item_image_test.dart`，貼上以下完整內容（用既有 state 注入 + mock fetcher，驗單階段補圖；依賴 plan 03 的 `BannerStorage`/`GachaRecord` 與 plan 04 的 `_fetchAllBanners` 主流程結構到位，`FetchingItemImages`/`itemImagesDownloaded` 由本 plan 自有）：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';

/// 不真的打網路的 fetcher：roleGbId 在 [characters] 內回圖，否則回 null。
class _FakeFetcher extends ItemImageFetcher {
  _FakeFetcher(this.characters);
  final Set<int> characters;

  @override
  Future<({String iconUrl, String illustrationUrl})?> fetchItemImages({
    required int resourceId,
    required String languageCode,
    required http.Client client,
  }) async {
    if (!characters.contains(resourceId)) return null;
    return (
      iconUrl: 'https://x/$resourceId.png',
      illustrationUrl: 'https://x/${resourceId}_i.png',
    );
  }
}

GachaRecord _rec(int resourceId, int q, String type) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: q,
  resourceType: type,
  cardPoolType: '1',
  name: 'r$resourceId',
  count: 1,
  time: DateTime.utc(2026, 5, 21),
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('repo_item_image_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  ProviderContainer build({required Set<int> characters}) {
    final mockClient = MockClient(
      (_) async => http.Response.bytes([1, 2, 3], 200),
    );
    return ProviderContainer(
      overrides: [
        itemImageIndexStorageProvider.overrideWithValue(
          ItemImageIndexStorage(tempDir),
        ),
        itemImageCacheDirProvider.overrideWithValue(tempDir),
        itemImageFetcherProvider.overrideWithValue(_FakeFetcher(characters)),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(client: mockClient, cancel: () {}),
        ),
      ],
    );
  }

  test('角色寫正取 + 下載 icon；武器/道具寫負取', () async {
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

    await repo.debugRunItemImagesOnly();
    await container.read(itemImageIndexProvider.notifier).waitForLoad();
    final index = container.read(itemImageIndexProvider);

    expect(index.lookupImage(1211)!.hasIcon, isTrue);
    expect(index.lookupImage(21010024)!.noImage, isTrue);
    expect(index.lookupImage(21010024)!.permanentNoImage, isFalse);
    expect(index.lookupImage(21040084)!.noImage, isTrue);
    expect(File('${tempDir.path}/1211_icon.png').existsSync(), isTrue);
  });

  test('正取者第二次跑不重抓；負取者每次重試', () async {
    // 預植：1211 正取、21010024 負取（非永久）。
    final storage = ItemImageIndexStorage(tempDir);
    await storage.save(
      const ItemImageIndex(
        items: {
          1211: ItemImageEntry(
            iconUrl: 'https://x/1211.png',
            illustrationUrl: '',
            noImage: false,
            permanentNoImage: false,
          ),
          21010024: ItemImageEntry(
            iconUrl: null,
            illustrationUrl: null,
            noImage: true,
            permanentNoImage: false,
          ),
        },
      ),
    );
    // 這次 21010024 變成角色（模擬官方後補圖）。
    final container = build(characters: {1211, 21010024});
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

  test('被拒的原神 v1 匯入不觸發補圖（R18）→ index 維持空', () async {
    final container = build(characters: {1211});
    addTearDown(container.dispose);
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();
    await container.read(itemImageIndexProvider.notifier).waitForLoad();

    // 舊原神 v1 全帳號匯出格式（uid/wish_type，無鳴潮 playerId/cardPoolType），
    // 由 plan 03/04 的匯入解析拒絕；拒絕路徑不得進入 _fetchItemImages。
    final legacyGenshinBundle = jsonEncode({
      'schema': 'genshin-wish-export-v1',
      'accounts': [
        {
          'uid': '700000001',
          'wishes': [
            {'wish_type': '301', 'item_id': '10000002', 'rank_type': '5'},
          ],
        },
      ],
    });

    final result = await repo.importAccountsAndFetchItemImages(
      legacyGenshinBundle,
    );

    expect(result.successAccounts, 0);
    expect(container.read(itemImageIndexProvider).items, isEmpty);
    expect(File('${tempDir.path}/1211_icon.png').existsSync(), isFalse);
  });
}
```

> R18 補圖防呆斷言：上述「被拒的原神 v1 匯入不觸發補圖」測試驗證 `importAccountsAndFetchItemImages` 在匯入解析失敗（plan 03/04 的拒絕分支）時，**不**呼叫 `_fetchItemImages`、index 維持空、無 icon 落地。若 plan 03/04 的匯入拒絕回傳型別/欄位與此處 `ImportResult.successAccounts` 不同，依其實際契約調整斷言欄位，但「拒絕 ⇒ index 仍空、無 icon 檔」這條不變式必須留。`CancellableHttpClient` 直接以 `CancellableHttpClient(client: mockClient, cancel: () {})` 構造，與 plan 04 測試一致（R14；不另造 `_StubCancellable`、不用 `implements dynamic`）。

- [ ] 新增測試用 helper `debugSeedAccount`（R15）：plan 03 **並未**定義此 helper，故由本 Task 在 `gacha_repository.dart` 的 `GachaRepository` class 內明確新增（緊接 `debugImportOnly` 之後），貼上以下內容：

```dart
  /// 測試用：直接塞一筆帳號到 state.byUid（不走 bootstrap/storage）。生產勿用。
  @visibleForTesting
  void debugSeedAccount(BannerStorage data) {
    final next = Map<String, BannerStorage>.from(state.byUid)
      ..[data.playerId] = data;
    state = state.copyWith(byUid: next, activeUid: data.playerId);
  }
```

> R15 註記：上面用的是本 plan 自有的 `debugSeedAccount`。若實作當下發現 plan 03 已有等價的 debug helper（如 `debugImportOnly`）可直接塞單帳號 state，則改用既有者、不重複新增，並在測試呼叫點換成該名稱；二擇一、不可「假設 plan 03 提供 `debugSeedAccount`」。

> R14 註記：`cancellableHttpClientFactoryProvider` 回傳型別為具體類別 `CancellableHttpClient{ http.Client client; void Function() cancel }`（見 `lib/services/cancellable_http_client.dart`）。本測試直接以 `CancellableHttpClient(client: mockClient, cancel: () {})` 構造注入，與 plan 04 測試完全一致；不另造 stub class、不用 `implements dynamic`。

- [ ] 跑 `dart format lib/state/gacha_repository.dart test/state/gacha_repository_item_image_test.dart`。
- [ ] 跑 `flutter test test/state/gacha_repository_item_image_test.dart`，預期通過（前提 plan 03/04 型別到位；若尚未，留待整合後驗）。
- [ ] commit（若有 git）：`feat(item-image): single-stage item image fetch orchestration`

---

## Task 8: 調整 UI 與 share 呼叫點（icon / preload / detail tap / settings / share helper）

把 icon 顯示、share preload、詳情可點判定、settings 用量區、share helper 全部從 `hoyowiki_*` 索引改吃 `item_image_*`：icon 用 `hasItemImage` 判定、`itemIconCacheFile(resourceId)` 取檔；preload key 改 `resourceId`(int)；detail 可點性改 `hasItemImage`（武器/道具不可點，P3）；settings 用量改 `itemImageCacheUsageProvider` 並移除 gallery 清除按鈕。依賴 plan 03（`GachaRecord.resourceId`）、Task 3/4/5。

> 跨 plan 邊界：icon widget、detail dialog、share_card 的視覺與 `_Placeholder` 上色、移除 odes 特例、移除 gallery/desc/tags/`flutter_html`/「在 HoYoWiki 開啟」外連等屬 plan 07（UI/i18n）主責。本 Task 只負責「服務層介面替換」：把 lookup/cache-file 呼叫換到 `item_image_*`、把可點判定換成 `hasItemImage`、把 preload key 換 `resourceId`。若與 plan 07 同檔衝突，以「本 Task 負責資料來源替換、plan 07 負責版面」分工，最終由後執行者收斂為單一實作（依 spec §F）。

**Files:**
- Modify: `lib/widgets/gacha_item_icon.dart`
- Modify: `lib/widgets/share/preloaded_hoyowiki_images.dart` → 改名 `lib/widgets/share/preloaded_item_images.dart`
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`（`hasHoYoWikiContent` → `hasItemImage` 路徑）
- Modify: `lib/widgets/share/share_image_helper.dart`（第 125-132 行）
- Modify: `lib/widgets/share/share_card.dart`（preload import 與 key）
- Modify: `lib/pages/settings_page.dart`（用量區 700/780/805-808、refetch 850）
- Modify: `lib/pages/overview_page.dart` / `lib/pages/banner_page.dart`（`hoyowikiIndexProvider` → `itemImageIndexProvider` 的傳遞點，視 plan 07 分工）
- Modify (ARB, R9): `lib/l10n/app_zh.arb`（+ `app_zh_Hans.arb`、`app_en.arb`、`app_ja.arb`）—— 本 plan 擁有圖片進度字串 `progressFetchingImages` 與設定頁圖片快取字串（如 `settingsRefetchImages`/`settingsImageCacheUsage`），改完跑 `flutter gen-l10n`

### 步驟

- [ ] `gacha_item_icon.dart`：把 import `hoyowiki_index`（service + state）改為 `item_image_index`（service + state）與新增 `item_image_lookup`；移除 `_odesGachaTypes` 與其 `SizedBox.shrink` 特例；把 `index.lookupId/lookupEntry/iconUrl` 取圖邏輯改為：

```dart
    final index = ref.watch(itemImageIndexProvider);
    final cacheDir = ref.watch(itemImageCacheDirProvider);
    final tokens = Theme.of(context).gacha;

    if (!hasItemImage(index, record)) {
      return _Placeholder(
        rankType: record.qualityLevel,
        size: size,
        tokens: tokens,
        circular: circular,
      );
    }

    final entry = index.lookupImage(record.resourceId)!;
    final iconUrl = entry.iconUrl!;
    final preloaded = PreloadedItemImages.maybeOf(context);
    final preloadedImage = preloaded?.images[record.resourceId];
    if (preloadedImage != null) {
      return SizedBox(
        width: size,
        height: size,
        child: _clipIcon(RawImage(image: preloadedImage, fit: BoxFit.cover)),
      );
    }
    final file = itemIconCacheFile(
      baseDir: cacheDir,
      resourceId: record.resourceId,
      url: iconUrl,
    );
    if (file.existsSync()) {
      return SizedBox(
        width: size,
        height: size,
        child: _clipIcon(Image.file(file, fit: BoxFit.cover)),
      );
    }
    return _Placeholder(
      rankType: record.qualityLevel,
      size: size,
      tokens: tokens,
      circular: circular,
    );
```

  （`_Placeholder.rankType` 參數名沿用、實參改 `record.qualityLevel`；參數重命名屬 plan 07 的 2★/rank 精簡，視分工。）

- [ ] 把 `lib/widgets/share/preloaded_hoyowiki_images.dart` 改名為 `lib/widgets/share/preloaded_item_images.dart`，class 改 `PreloadedItemImages`、map key 型別改 `int`（resourceId）、`preloadItemImages` 函式吃 `ItemImageIndex` 並用 `hasItemImage`/`itemIconCacheFile(resourceId)`；移除 odes `gachaType == '2000'/'1000'` 跳過。完整內容：

```dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_lookup.dart';

final _log = Logger('item_image.preload');

/// 提供分享圖 sync pipeline 用的預解碼 icon [ui.Image] map（key = resourceId）。
class PreloadedItemImages extends InheritedWidget {
  /// 建立 [PreloadedItemImages]。
  const PreloadedItemImages({
    super.key,
    required this.images,
    required super.child,
  });

  /// resourceId → 預解碼的 [ui.Image]（已 owned；render 結束需 dispose）。
  final Map<int, ui.Image> images;

  /// 從祖先 [PreloadedItemImages] 取得；不存在回 null。
  static PreloadedItemImages? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PreloadedItemImages>();

  @override
  bool updateShouldNotify(PreloadedItemImages oldWidget) =>
      !identical(images, oldWidget.images);
}

/// 預解碼 [records] 對應的角色 icon cache 檔成 [ui.Image] map。
///
/// 只預載有圖（[hasItemImage] 為 true）且 cache 檔在的角色 icon；其餘 record
/// 直接跳過（分享圖內走 placeholder）。illustration 大圖不進 preload（體積大）。
/// 回傳的 map 須由 caller 在 render 結束後呼叫 [disposePreloadedItemImages] 釋放。
Future<Map<int, ui.Image>> preloadItemImages({
  required ItemImageIndex index,
  required Directory cacheDir,
  required Iterable<GachaRecord> records,
}) async {
  final out = <int, ui.Image>{};
  for (final r in records) {
    if (out.containsKey(r.resourceId)) continue;
    if (!hasItemImage(index, r)) continue;
    final entry = index.lookupImage(r.resourceId)!;
    final file = itemIconCacheFile(
      baseDir: cacheDir,
      resourceId: r.resourceId,
      url: entry.iconUrl!,
    );
    if (!file.existsSync()) continue;
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      out[r.resourceId] = frame.image;
    } catch (e, st) {
      _log.warning('preload decode failed resourceId=${r.resourceId}', e, st);
    }
  }
  return out;
}

/// dispose 由 [preloadItemImages] 產出的所有 [ui.Image]。
void disposePreloadedItemImages(Map<int, ui.Image> images) {
  for (final img in images.values) {
    img.dispose();
  }
}
```

- [ ] `share_image_helper.dart`（第 125-132 行）：把 `hoyowikiIndex`/`hoyowikiCacheDirProvider`/`preloadHoYoWikiImages`/`PreloadedHoYoWikiImages` 改為 `itemImageIndexProvider`/`itemImageCacheDirProvider`/`preloadItemImages`/`PreloadedItemImages`，import 改 `preloaded_item_images.dart`。
- [ ] `share_card.dart`：把 `PreloadedHoYoWikiImages` 相關 import 與用法改 `PreloadedItemImages`（版面/2★/odes 段由 plan 07 處理）。
- [ ] `gacha_item_detail_dialog.dart`：把 `hasHoYoWikiContent` 改名 `hasItemImage` 並改用 `itemImageIndexProvider` + Task 5 的 `hasItemImage(index, record)`（武器/道具→ false→不可點，P3）；`GachaItemTapTarget.build` 內 `if (!hasHoYoWikiContent(ref, record))` 改 `if (!hasItemImage(ref.watch(itemImageIndexProvider), record))`。gallery/desc/tags/`flutter_html`/`actionViewOnHoYoWiki` 外連的移除與 illustration 大圖呈現由 plan 07 處理；本 Task 只替換索引來源與可點判定。
- [ ] `settings_page.dart`：第 700 行 `hoyowikiCacheUsageProvider` → `itemImageCacheUsageProvider`；第 727-733 行 `_UsageRows` 的 `gallery:` 一項移除（改只 total/icon/illustration，對應的圖片快取字串本 plan ARB step 自有，見下）；移除「清除詳情圖快取」按鈕與 `_clearGallery`/`deleteGalleryCacheFiles` 整段（item_image 服務無 gallery 概念，illustration 隨 wipe/refetch 一併清）；第 850 行 `forceRefetchAllHoYoWikiImages()` 改本 plan（R5）改名後的 `forceRefetchAllItemImages()`；第 693/808/813 行 `ref.invalidate(hoyowikiCacheUsageProvider)` → `itemImageCacheUsageProvider`。
- [ ] `overview_page.dart` / `banner_page.dart`：把傳給統計/preload 的 `ref.watch(hoyowikiIndexProvider)` 改 `ref.watch(itemImageIndexProvider)`（若 plan 06 後 stats 不再需要 index 參數則由 plan 06/07 移除該參數；本 Task 只替換 provider 名以保 compile）。
- [ ] ARB 圖片字串（R9，本 plan 擁有）：在 `lib/l10n/app_zh.arb`（+ `app_zh_Hans.arb`、`app_en.arb`、`app_ja.arb`）新增圖片進度字串 `progressFetchingImages`（更新對話框補圖階段標題/文案，供 plan 07 的 `FetchingItemImages` 標題列消費）與設定頁圖片快取字串（如 `settingsRefetchImages`／`settingsImageCacheUsage`，去 HoYoWiki 命名，供上一步的用量區與 refetch 按鈕使用）。各語言依 CLAUDE.md 標點慣例（CJK 全形）填字。改完跑 `flutter gen-l10n`，確認新 key 生成於 `AppLocalizations`。本 plan **只動圖片相關 key**，與 plan 04（抓取/錯誤鍵）、plan 05（卡池 nameKey/kindItem）、plan 07（appName/nav/odes 移除）所有權不重疊。
- [ ] 刪除 `lib/widgets/dialogs/gacha_item_detail_dialog.dart` 內 module-level `_log` 重複宣告若改名造成衝突（保留一個）。
- [ ] 跑 `dart format lib/`（依 CLAUDE.md，只對 lib/ 與 test/，不對 `.`）。
- [ ] commit（若有 git）：`refactor(item-image): switch UI/share call sites to item image index`

---

## Task 9: 刪除舊 HoYoWiki 檔與測試，全綠驗收

刪除所有 `hoyowiki_*` 來源檔與測試（已被 item_image_* 取代），跑全套驗收。前提：Task 1-8 完成、plan 01/03/04/07 的相依改名已完成（整體 compile 收斂）。

**Files:**
- Delete: `lib/services/hoyowiki_fetcher.dart`、`lib/services/hoyowiki_index.dart`、`lib/state/hoyowiki_index.dart`、`lib/state/hoyowiki_cache_usage.dart`、`lib/widgets/share/preloaded_hoyowiki_images.dart`（已於 Task 8 改名移除）
- Delete (test): `test/services/hoyowiki_fetcher_test.dart`、`test/services/hoyowiki_index_test.dart`、`test/state/hoyowiki_index_test.dart`、`test/state/hoyowiki_cache_usage_test.dart`

### 步驟

- [ ] 刪除舊來源檔（PowerShell）：

```powershell
Remove-Item -Force `
  lib/services/hoyowiki_fetcher.dart, `
  lib/services/hoyowiki_index.dart, `
  lib/state/hoyowiki_index.dart, `
  lib/state/hoyowiki_cache_usage.dart
```

- [ ] 刪除舊測試檔（PowerShell）：

```powershell
Remove-Item -Force `
  test/services/hoyowiki_fetcher_test.dart, `
  test/services/hoyowiki_index_test.dart, `
  test/state/hoyowiki_index_test.dart, `
  test/state/hoyowiki_cache_usage_test.dart
```

- [ ] 確認無殘留 HoYoWiki 識別子（應只剩 plan 01/07 處理的品牌字串或無）：用 Grep 搜尋 `hoyowiki|HoYoWiki|lookupId|lookupEntry|lookupMenuId|hasHoYoWikiContent` 於 `lib/` 與 `test/`，預期 0 筆（或僅剩其他 plan 負責的品牌字串）。逐一修掉本 plan 範圍內殘留的引用。
- [ ] 跑 `dart format lib/ test/`。
- [ ] 跑 `flutter analyze`，預期 `No issues found!`（若仍有其他 plan 未完成造成的紅燈，記錄為跨 plan 待收斂，不在本 plan 範圍的不修）。
- [ ] 跑 `flutter test`，預期 `All tests passed!`。
- [ ] commit（若有 git）：`refactor(item-image): remove legacy hoyowiki services and tests`

---

## 驗收清單（全 plan 完成後）

- [ ] `lib/services/item_image_fetcher.dart` / `item_image_index.dart` / `item_image_lookup.dart`、`lib/state/item_image_index.dart` / `item_image_cache_usage.dart` 存在且無 HoYoWiki 識別子。
- [ ] `main.dart` cache 目錄為 `item_image_cache`、override 用 item_image providers。
- [ ] `gacha_repository.dart` 補圖為單階段 `_fetchItemImages`，逐帳號 `(resourceId, languageCode)`、未抓/負取非永久者重試、正取跳過、回 null 寫負取。
- [ ] `hasItemImage(index, record)` 為所有 icon 消費點與「可否點開詳情」的唯一判定；無圖一律 `_Placeholder`，絕不 `SizedBox.shrink`。
- [ ] 匯入舊原神 bundle 被拒時不觸發補圖（拒絕分支由 plan 03/04 提供；本 plan 不在拒絕路徑呼叫 `_fetchItemImages`，並以 Task 7 的「被拒的原神 v1 匯入不觸發補圖（R18）」測試斷言 index 維持空、無 icon 落地）。
- [ ] `dart format lib/ test/` → `flutter analyze`（No issues found!）→ `flutter test`（All tests passed!）全綠。

---

備註與向其他 plan 的明確契約（供整合對齊）：

- 本 plan 對外提供：`lib/services/item_image_fetcher.dart` 的 `ItemImageFetcher.fetchItemImages({required int resourceId, required String languageCode, required http.Client client}) -> ({String iconUrl, String illustrationUrl})?`（null=無圖）與 `downloadImage`；`lib/services/item_image_index.dart` 的 `ItemImageEntry{ String? iconUrl, illustrationUrl; bool noImage, permanentNoImage; bool get hasIcon }`、`ItemImageIndex.lookupImage(int)`、`ItemImageIndexStorage`、`itemIconCacheFile`/`itemIllustrationCacheFile`；`lib/services/item_image_lookup.dart` 的 `bool hasItemImage(ItemImageIndex, GachaRecord)`；`lib/state/item_image_index.dart` 的 `itemImageIndexProvider`/`itemImageIndexStorageProvider`/`itemImageCacheDirProvider`/`itemImageFetcherProvider` 與 `ItemImageIndexNotifier.mergeItemImage(...)`/`bumpCacheRevision`/`resetAll`/`waitForLoad`；`lib/state/item_image_cache_usage.dart` 的 `itemImageCacheUsageProvider`/`ItemImageCacheUsage{ iconBytes, illustrationBytes, totalBytes }`。
- 本 plan 對外提供（R3，由本 plan 在 `update_progress.dart` 定義/改名）：單階段進度型別 `FetchingItemImages{ int doneCount; int totalCount }`（取代 `FetchingHoYoWiki`/`HoYoWikiPhase`）、`UpdateCompleted.itemImagesDownloaded`（取代 `hoYoWikiImagesDownloaded`）—— plan 07 消費於更新對話框標題/文案列。
- 本 plan 對外提供（R5，`gacha_repository.dart` public API）：`forceRefetchAllItemImages()`（取代 `forceRefetchAllHoYoWikiImages`）、`importAccountsAndFetchItemImages(...)`（取代 `importAccountsAndFetchHoYoWiki`）—— plan 07 的 settings 呼叫一律對齊 `forceRefetchAllItemImages`。
- 本 plan 擁有（R9）ARB 圖片字串：`progressFetchingImages` + 設定頁圖片快取字串（`settingsRefetchImages`/`settingsImageCacheUsage` 等，去 HoYoWiki）；與 plan 04/05/07 的 ARB key 不重疊。
- 本 plan 依賴 plan 03：`GachaRecord{ int resourceId; int qualityLevel; String resourceType; String name; ... }`、`BannerStorage{ String playerId; String languageCode; Map<String,List<GachaRecord>> banners }`（`debugSeedAccount` 測試 helper 由本 plan 自有，R15）。
- 本 plan 依賴 plan 04：orchestrator `_fetchAllBanners` 主流程的既有結構、import 拒舊 schema 分支（本 plan 不在拒絕路徑呼叫 `_fetchItemImages`，並以 R18 測試斷言之）。