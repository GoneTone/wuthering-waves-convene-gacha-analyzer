# 手動更新物品詳細資料 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在設定頁新增一顆非破壞性「更新物品資料」按鈕，重抓所有物品的 encore.moe 詳情以偵測新增 skins／頁籤，保留已下載的圖、新圖維持 lazy，並語意化完成訊息與清理殘留語言。

**Architecture:** 重用既有 `GachaRepository._fetchItemImages` 增量管線，加 `forceDetailRefetch`／`pruneStaleLangs` 兩個參數使其能強制重抓 detail；新增非破壞性入口 `refreshAllItemDetails()`（不 `resetAll()`），與既有破壞性 `forceRefetchAllItemImages()` 職責區隔。詳情頁既有 `watch(itemImageIndexProvider)`＋lazy backfill 已涵蓋「頁籤跟著更新＋開啟補缺圖」，**零改動**。

**Tech Stack:** Flutter、Riverpod 3.x（NotifierProvider）、flutter_test、l10n（ARB + gen-l10n）、FVM 釘版。

## Global Constraints

- 所有 Flutter／Dart 指令一律 `fvm flutter ...` / `fvm dart ...`（找不到 fvm 才退回 `flutter`／`dart`）。
- 每個 commit 前依序通過：`fvm dart format lib/ test/`（**勿對 `.`**，會動到 `rust_builder/`）→ `fvm flutter analyze`（須 `No issues found!`）→ `fvm flutter test`（須 `All tests passed!`）。任一失敗先修，不得 `--no-verify`。
- Commit message 用英文、conventional commits（`feat(...)`／`refactor(...)`／`i18n(...)`）；每個 commit 結尾附上專案標準 trailer（`Co-Authored-By: ...`／`Claude-Session: ...`）。
- **不要 git push。** 本計畫已在分支 `feat/manual-refresh-item-data` 上。
- i18n **只改 4 個核心 ARB**：`app_zh.arb`（template，繁中全形標點）、`app_en.arb`、`app_zh_Hans.arb`、`app_ja.arb`；其餘 27 個交給 Crowdin pipeline，不要碰。改完 ARB 必須跑 `fvm flutter gen-l10n` 重新產生 accessor（generated 為 gitignore）。
- 標點：繁中 ARB／註解／dartdoc 用全形 `，。？（）`；省略號一律 ASCII `...`（本專案明確例外）。
- 新功能在關鍵節點（I/O、外部 API、錯誤分支）埋 `Logger('gacha.itemimage.*').info/warning(...)`，帶足夠 context。
- 所有新宣告（method／class／field）寫一行 `///` dartdoc（Flutter override 例外）。
- Dialog 一律走既有 `showConfirmDialog`（內部已用 `AppDialog`），不要手寫 `AlertDialog`。
- `permanentNoImage` 在本專案從不為 true（死欄位）；force 路徑無條件重抓、不對它設例外。

---

### Task 1: `ItemImageIndexNotifier.pruneLanguages`

非破壞性清理 index 中殘留的舊語言詳情（資料語言轉換後遺留）。

**Files:**
- Modify: `lib/state/item_image_index.dart`（在 `resetAll` 之後、`_saveAndEmit` 之前新增 method）
- Test: `test/state/item_image_index_test.dart`（新增 `group('pruneLanguages', ...)`）

**Interfaces:**
- Produces: `Future<int> pruneLanguages(Set<String> keepLangs)` — 回傳 `detailByLang` 真的有縮減的相異物品數。

- [ ] **Step 1: 寫失敗測試**

在 `test/state/item_image_index_test.dart` 的 `main()` 內、最後一個 `}` 之前加入：

```dart
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
        container.read(itemImageIndexProvider).lookupImage(1503)!.detailByLang.keys,
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
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/state/item_image_index_test.dart`
Expected: FAIL（`pruneLanguages` 未定義 → 編譯錯誤）

- [ ] **Step 3: 實作 `pruneLanguages`**

在 `lib/state/item_image_index.dart` 的 `resetAll()`（約 line 164）之後加入：

```dart
  /// 移除所有 entry 中 lang 不在 [keepLangs] 的 detailByLang 條目（資料語言轉換後殘留清理）。
  ///
  /// 保留 iconUrl／noImage／permanentNoImage／kind／hasLuckdraw。空 [keepLangs] 直接回 0
  /// （防呆：空集合會清掉全部）。回傳 detailByLang 真的有縮減的相異物品數；無縮減回 0、
  /// 不重建 index（不觸發 UI churn）。
  Future<int> pruneLanguages(Set<String> keepLangs) async {
    if (keepLangs.isEmpty) return 0;
    return _lock.synchronized(() async {
      var prunedItems = 0;
      final newItems = <int, ItemImageEntry>{};
      state.items.forEach((id, entry) {
        final kept = <String, ItemDetailL10n>{
          for (final e in entry.detailByLang.entries)
            if (keepLangs.contains(e.key)) e.key: e.value,
        };
        if (kept.length != entry.detailByLang.length) {
          prunedItems++;
          newItems[id] = ItemImageEntry(
            iconUrl: entry.iconUrl,
            noImage: entry.noImage,
            permanentNoImage: entry.permanentNoImage,
            detailByLang: kept,
            hasLuckdraw: entry.hasLuckdraw,
            kind: entry.kind,
          );
        } else {
          newItems[id] = entry;
        }
      });
      if (prunedItems == 0) return 0;
      await _saveAndEmit(ItemImageIndex(items: newItems));
      _log.info('pruneLanguages: pruned $prunedItems items, keepLangs=$keepLangs');
      return prunedItems;
    });
  }
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/state/item_image_index_test.dart`
Expected: PASS（含新 group 三個 test）

- [ ] **Step 5: 品質檢查 + commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/state/item_image_index.dart test/state/item_image_index_test.dart
git commit -m "feat(item-image): add non-destructive pruneLanguages to index notifier"
```

---

### Task 2: 參數化 `_fetchItemImages`（record 回傳 + forceDetailRefetch + pruneStaleLangs）

讓既有增量管線可被「強制重抓 detail」並回報重抓／清理統計。

**Files:**
- Modify: `lib/state/gacha_repository.dart`（`_fetchItemImages` 簽名、gate、內層 worker、prune 呼叫、所有 return 點；3 處呼叫端；`debugRunItemImagesOnly`）
- Test: `test/state/gacha_repository_item_image_test.dart`（新增 force／prune 測試）

**Interfaces:**
- Consumes: `ItemImageIndexNotifier.pruneLanguages`（Task 1）。
- Produces:
  - `Future<({int imagesDownloaded, int itemsRefreshed, int staleItemsPruned})> _fetchItemImages(http.Client client, {bool forceDetailRefetch = false, bool pruneStaleLangs = false})`
  - `Future<void> debugRunItemImagesOnly({bool forceDetailRefetch = false, bool pruneStaleLangs = false})`

- [ ] **Step 1: 改 `_fetchItemImages` 簽名與回傳型別**

在 `lib/state/gacha_repository.dart`，把 `_fetchItemImages` 簽名（約 line 1024）改為：

```dart
  Future<({int imagesDownloaded, int itemsRefreshed, int staleItemsPruned})>
  _fetchItemImages(
    http.Client client, {
    bool forceDetailRefetch = false,
    bool pruneStaleLangs = false,
  }) async {
    var downloaded = 0;
    var staleItemsPruned = 0;
    final refreshedIds = <int>{};
    ({int imagesDownloaded, int itemsRefreshed, int staleItemsPruned}) result() =>
        (
          imagesDownloaded: downloaded,
          itemsRefreshed: refreshedIds.length,
          staleItemsPruned: staleItemsPruned,
        );
```

（即：保留既有 `var downloaded = 0;`，在其後加 `staleItemsPruned`／`refreshedIds`／`result()` helper。）

- [ ] **Step 2: 所有 return 點改用 `result()`**

把 `_fetchItemImages` 內所有 `return downloaded;`（共 6 處：langsById 空、workIds 空、catalog loop abort、step4 loop abort、`toDownload` 空/abort、函式結尾）改為 `return result();`。

- [ ] **Step 3: 插入殘留語言清理（prune）**

在 `if (langsById.isEmpty) return result();`（約 line 1042）之後、`final idx0 = ref.read(itemImageIndexProvider);`（約 line 1047）之前插入：

```dart
    // 殘留語言清理：移除 index 中已不再被任何記錄使用的語言詳情（資料語言轉換後遺留）。
    // 必須在讀 idx0 快照前做，使後續階段看到清理後的 index。recordLangs 空時不清（防呆）。
    if (pruneStaleLangs) {
      final recordLangs = {for (final s in langsById.values) ...s};
      if (recordLangs.isNotEmpty) {
        staleItemsPruned = await indexNotifier.pruneLanguages(recordLangs);
      }
    }
```

- [ ] **Step 4: gate 支援 forceDetailRefetch**

在 `bool needsWork(int id) {`（約 line 1048）的第一行插入：

```dart
      // 強制重抓：所有物品都重新處理（catalog 重跑→負取/新物品重試解析；正取→重抓
      // detail 偵測新 skins）。permanentNoImage 在本專案從不為 true，故不另設例外。
      if (forceDetailRefetch) return true;
```

- [ ] **Step 5: 內層 worker 強制重抓 detail + 計數**

在 step 5 的 worker 內，把守衛條件（約 line 1172）

```dart
            if (!detailAlready || luckdrawUnevaluated) {
```

改為：

```dart
            if (forceDetailRefetch || !detailAlready || luckdrawUnevaluated) {
```

並在其內成功 merge 後（`if (detail != null) {` 區塊內、`await indexNotifier.mergeItemDetail(...)` 之後）加入計數：

```dart
                refreshedIds.add(id);
```

（放在 `mergeItemDetail` 呼叫之後、HD icon 判斷之前皆可；確保只在 `detail != null` 分支內。）

- [ ] **Step 6: 更新 3 處讀回傳值的呼叫端**

`_fetchItemImages` 回傳改 record 後，下列 3 處（約 line 506、599、698）原為

```dart
      itemImagesDownloaded = await _fetchItemImages(client);
```

改為（注意各處的 client 變數名：line 506 是 `client`，599／698 是 `cancellable.client`）：

```dart
      itemImagesDownloaded = (await _fetchItemImages(client)).imagesDownloaded;
```

line 599／698：

```dart
        itemImagesDownloaded = (await _fetchItemImages(cancellable.client)).imagesDownloaded;
```

（line 958 的 `unifyDataLanguage` 與 line 1278 的 `debugRunItemImagesOnly` 為「不讀回傳值」呼叫，下一步單獨處理；其餘無。）

- [ ] **Step 7: 擴充 `debugRunItemImagesOnly` 帶旗標**

把 `debugRunItemImagesOnly`（約 line 1274）改為：

```dart
  /// 測試用：略過 banner fetch 直接跑 item image 階段（用既有 state.byUid）。
  @visibleForTesting
  Future<void> debugRunItemImagesOnly({
    bool forceDetailRefetch = false,
    bool pruneStaleLangs = false,
  }) async {
    _cancelTriggered = false;
    final cancellable = ref.read(cancellableHttpClientFactoryProvider)();
    try {
      await _fetchItemImages(
        cancellable.client,
        forceDetailRefetch: forceDetailRefetch,
        pruneStaleLangs: pruneStaleLangs,
      );
    } finally {
      cancellable.client.close();
    }
  }
```

- [ ] **Step 8: 確認既有測試仍綠（重構無行為變更）**

Run: `fvm flutter test test/state/gacha_repository_item_image_test.dart test/state/gacha_repository_update_test.dart`
Expected: PASS（既有測試不受 record 重構影響）

- [ ] **Step 9: 寫 force／prune 行為測試**

在 `test/state/gacha_repository_item_image_test.dart` 的 `main()` 內、最後一個 `}` 之前加入：

```dart
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
    expect(await File('${tempDir.path}/1211_icon.png').readAsBytes(), [9, 9, 9]);
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
```

- [ ] **Step 10: 跑測試確認通過**

Run: `fvm flutter test test/state/gacha_repository_item_image_test.dart`
Expected: PASS（含 3 個新 test）

- [ ] **Step 11: 品質檢查 + commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/state/gacha_repository.dart test/state/gacha_repository_item_image_test.dart
git commit -m "feat(item-image): parameterize fetch pipeline for forced detail refetch and stale-lang prune"
```

---

### Task 3: `UpdateCompleted` 新欄位 + `refreshAllItemDetails()` 非破壞性入口

**Files:**
- Modify: `lib/state/update_progress.dart`（`UpdateCompleted` 加兩個欄位）
- Modify: `lib/state/gacha_repository.dart`（新 logger + `refreshAllItemDetails()`）
- Test: `test/state/gacha_repository_item_image_test.dart`（新增 entry 測試）

**Interfaces:**
- Consumes: `_fetchItemImages(..., forceDetailRefetch: true, pruneStaleLangs: true)`（Task 2）。
- Produces:
  - `UpdateCompleted({..., int? itemDetailsRefreshed, int staleItemsPruned = 0})`
  - `Future<void> refreshAllItemDetails()`

- [ ] **Step 1: `UpdateCompleted` 加欄位**

在 `lib/state/update_progress.dart` 的 `UpdateCompleted` 建構子（約 line 74）與欄位區改為：

```dart
  const UpdateCompleted({
    required this.totalNewRecords,
    required this.failedBanners,
    required this.updatedAt,
    required this.itemImagesDownloaded,
    this.importSummary,
    this.itemDetailsRefreshed,
    this.staleItemsPruned = 0,
  });
```

並在 `importSummary` 欄位（約 line 96）之後加入：

```dart
  /// 「更新物品資料」流程專屬：本次成功重抓詳情的相異物品數。非 null 即代表此完成
  /// 來自更新物品資料流程，UI 據此切換到物品資料摘要；其他入口為 null。
  final int? itemDetailsRefreshed;

  /// 「更新物品資料」流程本次清理殘留語言的物品數；其他入口為 0。
  final int staleItemsPruned;
```

- [ ] **Step 2: 確認既有測試仍綠（新欄位皆 optional）**

Run: `fvm flutter test test/widgets/update_progress_dialog_test.dart test/state/gacha_repository_update_test.dart`
Expected: PASS（既有 `UpdateCompleted` 呼叫端不傳新欄位，靠預設值）

- [ ] **Step 3: 新增 logger 欄位**

在 `lib/state/gacha_repository.dart` 的 `_refetchLog`（約 line 126）之後加入：

```dart
  /// 非破壞性「更新物品資料」流程 logger。
  static final _refreshDetailsLog = Logger('gacha.itemimage.refreshDetails');
```

- [ ] **Step 4: 寫 `refreshAllItemDetails` 失敗測試**

在 `test/state/gacha_repository_item_image_test.dart` 的 `main()` 內、最後一個 `}` 之前加入：

```dart
  test('refreshAllItemDetails 非破壞性重抓 + 完成訊息帶物品資料摘要', () async {
    // 預植：1211 角色 icon 已快取、詳情已抓但 skins 空。
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

    await repo.refreshAllItemDetails();

    final e = container.read(itemImageIndexProvider).lookupImage(1211)!;
    // 強制重抓 → 偵測新 skins。
    expect(e.detailByLang['zh-Hant']!.skins, isNotEmpty);
    // 非破壞性：icon 檔保留（未被 resetAll 清掉）。
    expect(File('${tempDir.path}/1211_icon.png').existsSync(), isTrue);
    // 完成訊息為物品資料摘要（itemDetailsRefreshed 非 null）。
    final prog = container.read(gachaRepositoryProvider).progress;
    expect(prog, isA<UpdateCompleted>());
    expect((prog as UpdateCompleted).itemDetailsRefreshed, 1);
  });
```

- [ ] **Step 5: 跑測試確認失敗**

Run: `fvm flutter test test/state/gacha_repository_item_image_test.dart --plain-name 'refreshAllItemDetails 非破壞性重抓'`
Expected: FAIL（`refreshAllItemDetails` 未定義）

- [ ] **Step 6: 實作 `refreshAllItemDetails`**

在 `lib/state/gacha_repository.dart` 的 `forceRefetchAllItemImages()`（約 line 626 結尾 `}`）之後加入：

```dart
  /// 非破壞性更新所有物品詳細資料：重抓 detail 偵測新增 skins／頁籤，保留已下載的圖、
  /// 新圖維持 lazy。與破壞性 [forceRefetchAllItemImages] 區隔——**不** `resetAll()`。
  ///
  /// 流程：互斥檢查 → emit `Preparing` → `_fetchItemImages(forceDetailRefetch: true,
  /// pruneStaleLangs: true)` → 依取消狀態 emit `UpdateCompleted`（帶 itemDetailsRefreshed／
  /// staleItemsPruned）或清 progress。
  Future<void> refreshAllItemDetails() async {
    if (state.progress != null) {
      _refreshDetailsLog.info('skip: another progress in-flight');
      return;
    }
    if (_isUpdating) return;
    _isUpdating = true;
    _cancelTriggered = false;

    final totalUids = state.byUid.length;
    _refreshDetailsLog.info('start, totalUids=$totalUids');

    final cancellable = ref.read(cancellableHttpClientFactoryProvider)();
    _activeCancellable = cancellable;
    state = state.copyWith(progress: const Preparing());

    try {
      var result = (imagesDownloaded: 0, itemsRefreshed: 0, staleItemsPruned: 0);
      try {
        result = await _fetchItemImages(
          cancellable.client,
          forceDetailRefetch: true,
          pruneStaleLangs: true,
        );
      } catch (e, st) {
        _refreshDetailsLog.warning('item detail stage threw (ignored)', e, st);
      }
      if (!ref.mounted) return;

      if (_cancelTriggered) {
        _refreshDetailsLog.warning('cancelled');
        state = state.copyWith(clearProgress: true);
        return;
      }

      _refreshDetailsLog.info(
        'done refreshed=${result.itemsRefreshed} '
        'images=${result.imagesDownloaded} pruned=${result.staleItemsPruned}',
      );
      state = state.copyWith(
        progress: UpdateCompleted(
          totalNewRecords: 0,
          failedBanners: const [],
          updatedAt: DateTime.now().toUtc(),
          itemImagesDownloaded: result.imagesDownloaded,
          itemDetailsRefreshed: result.itemsRefreshed,
          staleItemsPruned: result.staleItemsPruned,
        ),
      );
    } finally {
      _activeCancellable?.client.close();
      _activeCancellable = null;
      _cancelTriggered = false;
      _isUpdating = false;
    }
  }
```

- [ ] **Step 7: 跑測試確認通過**

Run: `fvm flutter test test/state/gacha_repository_item_image_test.dart`
Expected: PASS

- [ ] **Step 8: 品質檢查 + commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/state/update_progress.dart lib/state/gacha_repository.dart test/state/gacha_repository_item_image_test.dart
git commit -m "feat(item-image): add non-destructive refreshAllItemDetails entry"
```

---

### Task 4: i18n 字串（4 個核心 ARB + gen-l10n）

**Files:**
- Modify: `lib/l10n/app_zh.arb`（template，繁中全形）、`lib/l10n/app_en.arb`、`lib/l10n/app_zh_Hans.arb`、`lib/l10n/app_ja.arb`

**Interfaces:**
- Produces（gen-l10n accessor）：`settingsItemData`、`settingsRefreshItemDataDesc`、`settingsRefreshItemDataTitle`、`settingsRefreshItemDataEmpty`、`confirmRefreshItemDataTitle`、`confirmRefreshItemDataBody`、`confirmRefreshItemDataConfirm`、`progressDoneItemDataSummary(int)`、`progressDoneItemDataImagesSummary(int)`、`progressDoneItemDataPrunedSummary(int)`。

- [ ] **Step 1: app_zh.arb（template）新增 key**

在 `lib/l10n/app_zh.arb` 的 `confirmRefetchItemImagesConfirm` 區塊（約 line 360-363）之後加入（含 `@` 描述與 placeholder 定義）：

```json
  "settingsItemData": "物品資料",
  "@settingsItemData": {
    "description": "Settings page section title for item metadata controls (non-destructive update)."
  },
  "settingsRefreshItemDataDesc": "重新抓取所有物品的最新詳細資料（簡介、圖片清單等），保留已下載的圖片；新增的圖片會在你開啟該物品詳情時才下載。",
  "@settingsRefreshItemDataDesc": {
    "description": "Description under the item data section explaining the non-destructive metadata refresh."
  },
  "settingsRefreshItemDataTitle": "更新物品資料",
  "@settingsRefreshItemDataTitle": {
    "description": "Button label: non-destructively re-fetch item metadata, keeping downloaded images."
  },
  "settingsRefreshItemDataEmpty": "尚無喚取紀錄，無法更新物品資料",
  "@settingsRefreshItemDataEmpty": {
    "description": "Tooltip shown when the update item data button is disabled because there are no gacha records."
  },
  "confirmRefreshItemDataTitle": "更新物品資料？",
  "@confirmRefreshItemDataTitle": {
    "description": "Title of the confirm dialog for the non-destructive item data update."
  },
  "confirmRefreshItemDataBody": "將重新抓取所有物品的詳細資料，保留已下載的圖片，新增的圖片會在開啟詳情時才下載。確定要更新嗎？",
  "@confirmRefreshItemDataBody": {
    "description": "Body of the confirm dialog for the non-destructive item data update."
  },
  "confirmRefreshItemDataConfirm": "開始更新",
  "@confirmRefreshItemDataConfirm": {
    "description": "Confirm button label in the item data update dialog."
  },
  "progressDoneItemDataSummary": "已更新 {count} 個物品的資料",
  "@progressDoneItemDataSummary": {
    "description": "Completion summary main line for the update item data flow: number of items whose metadata was refreshed.",
    "placeholders": { "count": { "type": "int" } }
  },
  "progressDoneItemDataImagesSummary": "補下載 {count} 張物品圖片",
  "@progressDoneItemDataImagesSummary": {
    "description": "Completion line shown only when count > 0: item images back-filled during the update item data flow.",
    "placeholders": { "count": { "type": "int" } }
  },
  "progressDoneItemDataPrunedSummary": "已清理 {count} 個物品的殘留語言資料",
  "@progressDoneItemDataPrunedSummary": {
    "description": "Completion line shown only when count > 0: items whose stale-language metadata was pruned.",
    "placeholders": { "count": { "type": "int" } }
  },
```

- [ ] **Step 2: app_en.arb 新增對應翻譯（plural ICU 對齊既有慣例）**

在 `lib/l10n/app_en.arb` 對應位置加入（en 既有 `progressDoneImagesSummary` 用 plural，故 count 行一致用 plural；無 `@` 描述，翻譯檔慣例只放值）：

```json
  "settingsItemData": "Item data",
  "settingsRefreshItemDataDesc": "Re-fetch the latest details for all items (intro, image list, etc.), keeping already-downloaded images; newly added images download when you open that item's details.",
  "settingsRefreshItemDataTitle": "Update item data",
  "settingsRefreshItemDataEmpty": "No gacha records yet, nothing to update",
  "confirmRefreshItemDataTitle": "Update item data?",
  "confirmRefreshItemDataBody": "This re-fetches details for all items, keeping already-downloaded images; newly added images download when you open the details. Update now?",
  "confirmRefreshItemDataConfirm": "Start updating",
  "progressDoneItemDataSummary": "{count, plural, =1{Updated data for {count} item} other{Updated data for {count} items}}",
  "progressDoneItemDataImagesSummary": "{count, plural, =1{Downloaded {count} item image} other{Downloaded {count} item images}}",
  "progressDoneItemDataPrunedSummary": "{count, plural, =1{Cleaned up stale-language data for {count} item} other{Cleaned up stale-language data for {count} items}}",
```

- [ ] **Step 3: app_zh_Hans.arb 新增簡中翻譯**

```json
  "settingsItemData": "物品资料",
  "settingsRefreshItemDataDesc": "重新抓取所有物品的最新详细资料（简介、图片清单等），保留已下载的图片；新增的图片会在你打开该物品详情时才下载。",
  "settingsRefreshItemDataTitle": "更新物品资料",
  "settingsRefreshItemDataEmpty": "尚无唤取记录，无法更新物品资料",
  "confirmRefreshItemDataTitle": "更新物品资料？",
  "confirmRefreshItemDataBody": "将重新抓取所有物品的详细资料，保留已下载的图片，新增的图片会在打开详情时才下载。确定要更新吗？",
  "confirmRefreshItemDataConfirm": "开始更新",
  "progressDoneItemDataSummary": "已更新 {count} 个物品的资料",
  "progressDoneItemDataImagesSummary": "补下载 {count} 张物品图片",
  "progressDoneItemDataPrunedSummary": "已清理 {count} 个物品的残留语言资料",
```

- [ ] **Step 4: app_ja.arb 新增日文翻譯（術語對齊既有：集音記録／アイテム）**

```json
  "settingsItemData": "アイテムデータ",
  "settingsRefreshItemDataDesc": "すべてのアイテムの最新の詳細データ（紹介、画像リストなど）を再取得します。ダウンロード済みの画像は保持され、新しく追加された画像はそのアイテムの詳細を開いたときにダウンロードされます。",
  "settingsRefreshItemDataTitle": "アイテムデータを更新",
  "settingsRefreshItemDataEmpty": "集音記録がないため、アイテムデータを更新できません",
  "confirmRefreshItemDataTitle": "アイテムデータを更新しますか？",
  "confirmRefreshItemDataBody": "すべてのアイテムの詳細データを再取得します。ダウンロード済みの画像は保持され、新しく追加された画像は詳細を開いたときにダウンロードされます。更新しますか？",
  "confirmRefreshItemDataConfirm": "更新を開始",
  "progressDoneItemDataSummary": "{count} 件のアイテムのデータを更新しました",
  "progressDoneItemDataImagesSummary": "アイテム画像を {count} 件ダウンロード",
  "progressDoneItemDataPrunedSummary": "{count} 件のアイテムの残存言語データを整理しました",
```

- [ ] **Step 5: 重新產生 l10n accessor**

Run: `fvm flutter gen-l10n`
Expected: 無錯誤；`lib/l10n/generated/app_localizations*.dart` 更新（gitignore，不入版控）。

- [ ] **Step 6: 品質檢查 + commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/l10n/app_zh.arb lib/l10n/app_en.arb lib/l10n/app_zh_Hans.arb lib/l10n/app_ja.arb
git commit -m "i18n(settings): add item data update strings to core ARBs"
```

---

### Task 5: `UpdateProgressDialog` 完成訊息三路分支

完成訊息依 `itemDetailsRefreshed` 切換到物品資料摘要（補圖／清理行條件顯示）。

**Files:**
- Modify: `lib/widgets/update_progress_dialog.dart`（`_Body` 的 `UpdateCompleted` 分支）
- Test: `test/widgets/update_progress_dialog_test.dart`

**Interfaces:**
- Consumes: `UpdateCompleted.itemDetailsRefreshed` / `.staleItemsPruned`（Task 3）；i18n key（Task 4）。

- [ ] **Step 1: 寫失敗 widget 測試**

在 `test/widgets/update_progress_dialog_test.dart` 的 `main()` 內、最後一個 `}` 之前加入：

```dart
  group('UpdateProgressDialog — 物品資料完成摘要', () {
    testWidgets('itemDetailsRefreshed 非 null → 三行皆顯示，不顯示「新增筆數」', (tester) async {
      await _pumpDialog(
        tester,
        progress: UpdateCompleted(
          totalNewRecords: 0,
          failedBanners: const [],
          updatedAt: DateTime.utc(2026),
          itemImagesDownloaded: 3,
          itemDetailsRefreshed: 5,
          staleItemsPruned: 2,
        ),
      );
      expect(find.textContaining('已更新 5 個物品的資料'), findsOneWidget);
      expect(find.textContaining('補下載 3 張物品圖片'), findsOneWidget);
      expect(find.textContaining('已清理 2 個物品的殘留語言資料'), findsOneWidget);
      expect(find.textContaining('新增'), findsNothing);
    });

    testWidgets('補圖=0、清理=0 → 只顯示主行', (tester) async {
      await _pumpDialog(
        tester,
        progress: UpdateCompleted(
          totalNewRecords: 0,
          failedBanners: const [],
          updatedAt: DateTime.utc(2026),
          itemImagesDownloaded: 0,
          itemDetailsRefreshed: 4,
          staleItemsPruned: 0,
        ),
      );
      expect(find.textContaining('已更新 4 個物品的資料'), findsOneWidget);
      expect(find.textContaining('補下載'), findsNothing);
      expect(find.textContaining('殘留語言'), findsNothing);
    });
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/update_progress_dialog_test.dart`
Expected: FAIL（顯示的是既有「新增 0 筆紀錄」而非物品資料摘要）

- [ ] **Step 3: 改 `_Body` 的 UpdateCompleted 分支為三路**

在 `lib/widgets/update_progress_dialog.dart`，把 `UpdateCompleted(...)` 分支（約 line 219-261）整段替換為：

```dart
      UpdateCompleted(
        :final totalNewRecords,
        :final failedBanners,
        :final itemImagesDownloaded,
        :final importSummary,
        :final itemDetailsRefreshed,
        :final staleItemsPruned,
      ) =>
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (itemDetailsRefreshed != null) ...[
              Text(l.progressDoneItemDataSummary(itemDetailsRefreshed)),
              if (itemImagesDownloaded > 0) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(l.progressDoneItemDataImagesSummary(itemImagesDownloaded)),
              ],
              if (staleItemsPruned > 0) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(l.progressDoneItemDataPrunedSummary(staleItemsPruned)),
              ],
            ] else ...[
              if (importSummary != null)
                Text(
                  l.progressDoneImportSummary(
                    importSummary.successAccounts,
                    importSummary.addedRecords,
                    importSummary.duplicateRecords,
                  ),
                )
              else
                Text(l.progressDoneSummary(totalNewRecords)),
              const SizedBox(height: AppSpacing.xs),
              Text(l.progressDoneImagesSummary(itemImagesDownloaded)),
            ],
            if (failedBanners.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s),
              Text(
                l.progressPartialFailed(
                  failedBanners.map(resolveBannerName).join('、'),
                ),
                style: TextStyle(color: tokens.stateDanger),
              ),
            ],
            if (importSummary != null &&
                importSummary.failedUids.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s),
              Text(
                l.progressPartialImportFailed(
                  importSummary.failedUids.join(', '),
                ),
                style: TextStyle(color: tokens.stateDanger),
              ),
            ],
          ],
        ),
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/update_progress_dialog_test.dart`
Expected: PASS（含 2 個新 testWidgets）

- [ ] **Step 5: 品質檢查 + commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/widgets/update_progress_dialog.dart test/widgets/update_progress_dialog_test.dart
git commit -m "feat(update-dialog): semantic completion summary for item data refresh"
```

---

### Task 6: 設定頁「物品資料」區 + `_ItemDataSection`

**Files:**
- Modify: `lib/pages/settings_page.dart`（`build` 插入 SectionCard + 新增 `_ItemDataSection`）
- Test: `test/pages/settings_item_data_section_test.dart`（新檔）

**Interfaces:**
- Consumes: `GachaRepository.refreshAllItemDetails`（Task 3）；i18n key（Task 4）；`showConfirmDialog`（既有）。

- [ ] **Step 1: 在 build 插入「物品資料」SectionCard**

在 `lib/pages/settings_page.dart` 的 `_DataManagement` SectionCard（約 line 108-112）與其後的 `const SizedBox(height: AppSpacing.xl),`（line 113）之間插入新 section，使其位於「資料管理」與「圖片快取」之間：

```dart
              SectionCard(
                title: l.settingsDataManagement,
                icon: Icons.folder_outlined,
                child: const _DataManagement(),
              ),
              const SizedBox(height: AppSpacing.xl),
              SectionCard(
                title: l.settingsItemData,
                icon: Icons.dataset_outlined,
                child: const _ItemDataSection(),
              ),
              const SizedBox(height: AppSpacing.xl),
              SectionCard(
                title: l.settingsImageCache,
                icon: Icons.image_outlined,
                child: const _ImageCacheSection(),
              ),
```

（即：在 `_DataManagement` SectionCard 後新增「SizedBox + 物品資料 SectionCard」，原本的圖片快取 SectionCard 與其前的 SizedBox 保持不動。）

- [ ] **Step 2: 新增 `_ItemDataSection` widget**

在 `lib/pages/settings_page.dart` 的 `_ImageCacheSection`（約 line 906）之前加入：

```dart
/// 設定頁「物品資料」區：非破壞性更新所有物品詳細資料（重抓 metadata，保留已下載圖）。
class _ItemDataSection extends ConsumerWidget {
  /// 建立 [_ItemDataSection]。
  const _ItemDataSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final tokens = theme.gacha;
    final hasData = ref.watch(
      gachaRepositoryProvider.select((s) => s.byUid.isNotEmpty),
    );
    final progress = ref.watch(
      gachaRepositoryProvider.select((s) => s.progress),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.settingsRefreshItemDataDesc,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: tokens.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.m),
        Tooltip(
          message: !hasData ? l.settingsRefreshItemDataEmpty : '',
          child: FilledButton.icon(
            onPressed: (!hasData || progress != null)
                ? null
                : () => _confirmAndRefresh(context, ref),
            icon: const Icon(Icons.update, size: 18),
            label: Text(l.settingsRefreshItemDataTitle),
          ),
        ),
      ],
    );
  }

  /// 顯示輕量確認 dialog（非 danger），確認後呼叫非破壞性 [GachaRepository.refreshAllItemDetails]。
  Future<void> _confirmAndRefresh(BuildContext ctx, WidgetRef ref) async {
    final l = AppLocalizations.of(ctx)!;
    final ok = await showConfirmDialog(
      context: ctx,
      title: l.confirmRefreshItemDataTitle,
      body: l.confirmRefreshItemDataBody,
      cancelLabel: l.actionCancel,
      confirmLabel: l.confirmRefreshItemDataConfirm,
      isDanger: false,
    );
    if (ok != true) return;
    // 後端流程獨立於 dialog lifecycle；UpdateProgressDialog 由 app_shell.dart 既有
    // ref.listen 自動彈出。
    unawaited(
      ref.read(gachaRepositoryProvider.notifier).refreshAllItemDetails(),
    );
  }
}
```

- [ ] **Step 3: 寫 widget 測試（新檔）**

建立 `test/pages/settings_item_data_section_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/settings_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';

class _NullCapture implements GachaCapture {
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(null), cancel: () async {});
}

Future<ProviderContainer> _setupContainer({
  required GachaStorage storage,
  required Directory tempDir,
}) async {
  final container = ProviderContainer(
    overrides: [
      gachaStorageProvider.overrideWithValue(storage),
      gachaCaptureProvider.overrideWithValue(_NullCapture()),
      cancellableHttpClientFactoryProvider.overrideWithValue(
        () => CancellableHttpClient(
          client: MockClient((_) async => http.Response('{}', 200)),
          cancel: () {},
        ),
      ),
      itemImageIndexStorageProvider.overrideWithValue(
        ItemImageIndexStorage(tempDir),
      ),
      itemImageCacheDirProvider.overrideWithValue(tempDir),
      appVersionProvider.overrideWithValue('0.0.0-test'),
    ],
  );
  await container.read(settingsProvider.notifier).waitForLoad();
  await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
  return container;
}

Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh', 'Hant'),
    theme: buildDarkTheme(),
    home: const Scaffold(body: SettingsPage()),
  ),
);

BannerStorage _seeded() => BannerStorage(
  playerId: '1001',
  languageCode: 'zh-Hant',
  lastUpdated: DateTime.utc(2026, 5, 24),
  banners: {
    '1': [
      GachaRecord(
        resourceId: 1301,
        qualityLevel: 5,
        resourceType: '角色',
        cardPoolType: '1',
        name: 'r1301',
        count: 1,
        time: DateTime(2026, 5, 24),
      ),
    ],
    '2': [],
    '3': [],
    '4': [],
    '5': [],
    '6': [],
    '8': [],
    '9': [],
  },
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('settings_item_data_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('無喚取紀錄：更新物品資料按鈕 disabled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _setupContainer(
        storage: GachaStorage(tempDir),
        tempDir: tempDir,
      );
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final btn = find.widgetWithText(FilledButton, '更新物品資料');
    expect(btn, findsOneWidget);
    expect(tester.widget<FilledButton>(btn).onPressed, isNull);
  });

  testWidgets('有紀錄：按鈕 enabled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = GachaStorage(tempDir);
    late ProviderContainer container;
    await tester.runAsync(() async {
      await storage.save(_seeded());
      container = await _setupContainer(storage: storage, tempDir: tempDir);
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final btn = find.widgetWithText(FilledButton, '更新物品資料');
    expect(tester.widget<FilledButton>(btn).onPressed, isNotNull);
  });

  testWidgets('點按鈕 → 確認 dialog 出現 → 取消不啟動 progress', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = GachaStorage(tempDir);
    late ProviderContainer container;
    await tester.runAsync(() async {
      await storage.save(_seeded());
      container = await _setupContainer(storage: storage, tempDir: tempDir);
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final btn = find.widgetWithText(FilledButton, '更新物品資料');
    await tester.scrollUntilVisible(
      btn,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(btn);
    await tester.pumpAndSettle();

    // 確認 dialog 內容（確認鍵文字）。
    expect(find.text('開始更新'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.text('開始更新'), findsNothing);
    expect(container.read(gachaRepositoryProvider).progress, isNull);
  });
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/pages/settings_item_data_section_test.dart`
Expected: PASS（3 個 testWidgets）

- [ ] **Step 5: 品質檢查 + commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/pages/settings_page.dart test/pages/settings_item_data_section_test.dart
git commit -m "feat(settings): add non-destructive update item data action"
```

---

## Self-Review

**1. Spec coverage:**
- 目標 1（設定頁按鈕）→ Task 6。
- 目標 2（重抓未解析 + 強制重抓已解析）→ Task 2（gate force + 內層 worker force）。
- 目標 3（不重抓已下載圖、icon 缺檔才補、skins lazy）→ Task 2（icon gate 不變、skins 不在管線下載）+ 詳情頁既有機制（零改動）。
- 目標 4（詳情頁頁籤跟著更新 + 開啟補缺圖）→ 既有 `watch + lazy backfill`，無對應 task（spec「關鍵發現」已載明零改動）。
- 目標 5（完成訊息語意化）→ Task 3（欄位）+ Task 5（三路分支）。
- 目標 6（殘留語言清理 + 統計）→ Task 1（pruneLanguages）+ Task 2（pruneStaleLangs 接線）+ Task 3（emit staleItemsPruned）+ Task 5（清理行）。
- i18n → Task 4。

**2. Placeholder scan:** 無 TBD／TODO；每個 code step 皆含完整程式碼與 import。

**3. Type consistency:**
- `_fetchItemImages` record 欄位 `{imagesDownloaded, itemsRefreshed, staleItemsPruned}` 在 Task 2 定義、Task 3 `refreshAllItemDetails` 消費（`result.imagesDownloaded/itemsRefreshed/staleItemsPruned`）一致。
- `UpdateCompleted.itemDetailsRefreshed`（`int?`）/`staleItemsPruned`（`int`）在 Task 3 定義、Task 5 dialog 解構消費一致。
- `pruneLanguages(Set<String>) → Future<int>` 在 Task 1 定義、Task 2 呼叫一致。
- i18n accessor 名稱（Task 4）與 Task 5／Task 6 引用一致：`progressDoneItemDataSummary`、`progressDoneItemDataImagesSummary`、`progressDoneItemDataPrunedSummary`、`settingsItemData`、`settingsRefreshItemData*`、`confirmRefreshItemData*`。

無未定義型別／方法。計畫完整。
