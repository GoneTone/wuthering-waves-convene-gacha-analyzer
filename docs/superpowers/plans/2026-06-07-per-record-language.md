# Per-Record Language & Encore-Backed Kind Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move both the language code and the type classification of each convene record from account-level/string-table to per-item & language-invariant — re-capturing in a new in-game language no longer overwrites existing records, and kind is decided by encore catalog membership instead of a `resourceType` language table.

**Architecture:** (1) `GachaRecord` carries its own `languageCode`; merge aligns on language-invariant fields so old records survive a language switch. (2) `ItemImageEntry` persists an encore-derived `kind` (`resourceId → character/weapon/item`); `itemTypeKeyOf(r, index)` reads it (Genshin's index-backed pattern), falling back to the raw `resourceType` string when unclassified.

**Tech Stack:** Flutter, Dart, Riverpod (Notifier), `flutter_test`. Run all commands via `fvm` (fallback to bare `flutter`/`dart` if `fvm` is missing).

**Spec:** `docs/superpowers/specs/2026-06-07-per-record-language-design.md`

**Planning refinement vs spec D1:** `GachaRecord.languageCode` uses constructor default `''` (NOT `required`) to avoid a mechanical ripple across ~15 test files. `fromApiJson` still requires `languageCode` (production records always tagged); `fromStorageJson` backfills. Behaviour is identical to the spec; only constructor strictness differs.

**Task order (each task = one green-build commit):**
1. Per-record `languageCode` on `GachaRecord` (+ fetcher + storage migration)
2. Language-invariant record merge
3. Persisted encore-backed `kind` on `ItemImageEntry`
4. Rewrite `_fetchItemImages` (per-record lang collection + membership classification + kind backfill)
5. Index-backed `itemTypeKeyOf(r, index)` threaded through stats/rows/overview/share/pages/dialog
6. Detail dialog consumes per-record language; remove `activeLanguageCodeProvider`

---

## Task 1: Per-record `languageCode` on `GachaRecord`

**Files:**
- Modify: `lib/models/gacha_record.dart`
- Modify: `lib/models/banner_storage.dart:29-46` (`fromJson`)
- Modify: `lib/services/gacha_fetcher.dart:88-95` (`fromApiJson` call)
- Test: `test/models/gacha_record_test.dart`, `test/models/banner_storage_test.dart`

- [ ] **Step 1: Write failing tests for per-record language round-trip + backfill**

In `test/models/gacha_record_test.dart`, add (keep existing tests):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

void main() {
  test('toStorageJson/fromStorageJson round-trips languageCode', () {
    const rec = GachaRecord(
      resourceId: 1211,
      qualityLevel: 5,
      resourceType: '角色',
      cardPoolType: '1',
      name: '達妮婭',
      count: 1,
      time: _t,
      languageCode: 'zh-Hant',
    );
    final restored = GachaRecord.fromStorageJson(rec.toStorageJson());
    expect(restored.languageCode, 'zh-Hant');
  });

  test('fromStorageJson uses fallbackLanguageCode when language_code missing', () {
    final legacy = {
      'resource_id': 1211,
      'quality_level': 5,
      'resource_type': '角色',
      'card_pool_type': '1',
      'name': '達妮婭',
      'count': 1,
      'time': '2026-05-21 10:39:03',
    };
    final restored = GachaRecord.fromStorageJson(
      legacy,
      fallbackLanguageCode: 'en',
    );
    expect(restored.languageCode, 'en');
  });

  test('fromApiJson tags record with the given languageCode', () {
    final rec = GachaRecord.fromApiJson(
      {
        'resourceId': 1211,
        'qualityLevel': 5,
        'resourceType': '角色',
        'name': '達妮婭',
        'count': 1,
        'time': '2026-05-21 10:39:03',
      },
      cardPoolType: '1',
      languageCode: 'ja',
    );
    expect(rec.languageCode, 'ja');
  });
}

final DateTime _t = DateTime(2026, 5, 21, 10, 39, 3);
```

In `test/models/banner_storage_test.dart`, add:

```dart
test('fromJson backfills per-record languageCode from account-level value', () {
  final json = {
    'player_id': '701000000',
    'language_code': 'zh-Hant',
    'last_updated': '2026-05-21T00:00:00.000Z',
    'banners': {
      '1': [
        {
          'resource_id': 1211,
          'quality_level': 5,
          'resource_type': '角色',
          'card_pool_type': '1',
          'name': '達妮婭',
          'count': 1,
          'time': '2026-05-21 10:39:03',
        },
      ],
    },
  };
  final storage = BannerStorage.fromJson(json);
  expect(storage.banners['1']!.single.languageCode, 'zh-Hant');
});
```

- [ ] **Step 2: Run the new tests; verify they fail to compile**

Run: `fvm flutter test test/models/gacha_record_test.dart test/models/banner_storage_test.dart`
Expected: FAIL — `GachaRecord` has no `languageCode` parameter / `fromStorageJson` has no `fallbackLanguageCode`.

- [ ] **Step 3: Add `languageCode` to `GachaRecord`**

In `lib/models/gacha_record.dart`, update the class. Add the field + constructor param (default `''`), thread through all three JSON methods:

```dart
  /// 建立 [GachaRecord]。
  const GachaRecord({
    required this.resourceId,
    required this.qualityLevel,
    required this.resourceType,
    required this.cardPoolType,
    required this.name,
    required this.count,
    required this.time,
    this.languageCode = '',
  });
```

Add the field (place after `time`):

```dart
  /// 抽取時間（伺服器在地時間語意）。
  final DateTime time;

  /// 該筆紀錄的擷取語言碼（如 `zh-Hant`）。決定 `name`／`resourceType` 字串語言，
  /// 並供 encore 詳情查詢挑 `detailByLang`。舊存檔無此欄位時由
  /// [GachaRecord.fromStorageJson] 的 fallback 回填（見 `BannerStorage.fromJson`）。
  final String languageCode;
```

Update `fromApiJson` to require `languageCode`:

```dart
  factory GachaRecord.fromApiJson(
    Map<String, dynamic> json, {
    required String cardPoolType,
    required String languageCode,
  }) {
    return GachaRecord(
      resourceId: json['resourceId'] as int,
      qualityLevel: json['qualityLevel'] as int,
      resourceType: json['resourceType'] as String,
      cardPoolType: cardPoolType,
      name: json['name'] as String,
      count: json['count'] as int,
      time: parseGachaTime(json['time'] as String),
      languageCode: languageCode,
    );
  }
```

Update `fromStorageJson` to backfill:

```dart
  /// 從本地存檔的 JSON 還原。
  ///
  /// 舊鳴潮存檔每筆無 `language_code`，由 [fallbackLanguageCode]（呼叫端帶帳號級
  /// `BannerStorage.languageCode`）回填，達成透明遷移。
  factory GachaRecord.fromStorageJson(
    Map<String, dynamic> json, {
    String fallbackLanguageCode = '',
  }) {
    final lang = json['language_code'] as String?;
    return GachaRecord(
      resourceId: json['resource_id'] as int,
      qualityLevel: json['quality_level'] as int,
      resourceType: json['resource_type'] as String,
      cardPoolType: json['card_pool_type'] as String,
      name: json['name'] as String,
      count: json['count'] as int,
      time: parseGachaTime(json['time'] as String),
      languageCode: (lang == null || lang.isEmpty) ? fallbackLanguageCode : lang,
    );
  }
```

Update `toStorageJson` to write `language_code`:

```dart
  Map<String, dynamic> toStorageJson() => {
    'resource_id': resourceId,
    'quality_level': qualityLevel,
    'resource_type': resourceType,
    'card_pool_type': cardPoolType,
    'name': name,
    'count': count,
    'time': formatGachaTime(time),
    'language_code': languageCode,
  };
```

- [ ] **Step 4: Backfill in `BannerStorage.fromJson`**

In `lib/models/banner_storage.dart`, update `fromJson` so records receive the account-level language as fallback:

```dart
  factory BannerStorage.fromJson(Map<String, dynamic> json) {
    final bannersJson = json['banners'] as Map<String, dynamic>;
    final bannerLang = json['language_code'] as String;
    return BannerStorage(
      playerId: json['player_id'] as String,
      languageCode: bannerLang,
      lastUpdated: DateTime.parse(json['last_updated'] as String),
      banners: bannersJson.map(
        (k, v) => MapEntry(
          k,
          (v as List<dynamic>)
              .map(
                (e) => GachaRecord.fromStorageJson(
                  e as Map<String, dynamic>,
                  fallbackLanguageCode: bannerLang,
                ),
              )
              .toList(growable: false),
        ),
      ),
    );
  }
```

Also update the `languageCode` field dartdoc:

```dart
  /// 帳號級語言碼（如 `zh-Hant`）：最近一次擷取的語言；亦為載入舊存檔時對缺
  /// 逐筆 `language_code` 的紀錄回填的來源。逐筆顯示／分類一律以
  /// `GachaRecord.languageCode` 為準，本欄位不再作為顯示語言權威。
  final String languageCode;
```

- [ ] **Step 5: Pass capture language into `fromApiJson`**

In `lib/services/gacha_fetcher.dart`, the `fetchPool` body builds records — pass `cred.languageCode`:

```dart
    final records = data
        .map(
          (e) => GachaRecord.fromApiJson(
            e as Map<String, dynamic>,
            cardPoolType: cardPoolTypeKey,
            languageCode: cred.languageCode,
          ),
        )
        .toList(growable: false);
```

- [ ] **Step 6: Fix the `fromApiJson` test call site**

Run: `fvm flutter analyze`
Expected: error in `test/services/gacha_fetcher_test.dart` (and any other `fromApiJson` caller) — missing `languageCode`. Add `languageCode: 'zh-Hant'` to each `GachaRecord.fromApiJson(...)` call the analyzer flags.

- [ ] **Step 7: Verify green**

Run: `fvm dart format lib/ test/` then `fvm flutter analyze` then `fvm flutter test`
Expected: `No issues found!` and `All tests passed!`

- [ ] **Step 8: Commit**

```bash
git add lib/models/gacha_record.dart lib/models/banner_storage.dart lib/services/gacha_fetcher.dart test/models/gacha_record_test.dart test/models/banner_storage_test.dart test/services/gacha_fetcher_test.dart
git commit -m "feat(model): add per-record languageCode to GachaRecord

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Language-invariant record merge

**Files:**
- Modify: `lib/services/record_merge.dart:16-21` (`recordsEqual`)
- Test: `test/services/record_merge_test.dart`

- [ ] **Step 1: Update the existing `name` test + add a cross-language alignment test**

In `test/services/record_merge_test.dart`, first extend the helper `r(...)` with a `lang` knob (keep all existing params/defaults):

```dart
GachaRecord r(
  int resourceId, {
  int quality = 4,
  String type = '角色',
  String name = 'x',
  int count = 1,
  int sec = 0,
  String lang = 'zh-Hant',
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: quality,
  resourceType: type,
  cardPoolType: '1',
  name: name,
  count: count,
  time: DateTime(2026, 5, 21, 11, 0, sec),
  languageCode: lang,
);
```

Replace the `name 不同 → false` test with language-invariant semantics:

```dart
    test('name 不同（換語言）→ true（語言無關對齊指紋）', () {
      expect(recordsEqual(r(1, name: 'a'), r(1, name: 'b')), isTrue);
    });
```

Add a new test inside `group('mergeOrderedRecords 增量', ...)`:

```dart
    test('換語言重抓：existing 語言保留、只前插新筆（新語言）', () {
      // existing 為 zh-Hant 的三筆；fresh 為 en 的同序列 + 頂端一筆新抽。
      final existing = [
        r(30, name: '維里奈', sec: 30, lang: 'zh-Hant'),
        r(20, name: '安可', sec: 20, lang: 'zh-Hant'),
        r(10, name: '今汐', sec: 10, lang: 'zh-Hant'),
      ];
      final fresh = [
        r(40, name: 'Carlotta', sec: 40, lang: 'en'),
        r(30, name: 'Verina', sec: 30, lang: 'en'),
        r(20, name: 'Encore', sec: 20, lang: 'en'),
        r(10, name: 'Jinhsi', sec: 10, lang: 'en'),
      ];
      final merged = mergeOrderedRecords(fresh, existing);
      expect(merged.map((e) => e.resourceId), [40, 30, 20, 10]);
      // 頂端新筆採新語言；既有三筆原語言完全不變。
      expect(merged[0].languageCode, 'en');
      expect(merged[1].languageCode, 'zh-Hant');
      expect(merged[1].name, '維里奈');
      expect(merged[3].name, '今汐');
    });
```

- [ ] **Step 2: Run tests; verify the cross-language test fails (and the renamed name test)**

Run: `fvm flutter test test/services/record_merge_test.dart`
Expected: FAIL — `recordsEqual` currently compares `name`, so the en fresh does not align with zh-Hant existing → fresh replaces existing → `merged[1].languageCode` is `en`, not `zh-Hant`.

- [ ] **Step 3: Drop `name` from the alignment fingerprint**

In `lib/services/record_merge.dart`, update `recordsEqual` (and its dartdoc):

```dart
/// 判斷兩筆喚取紀錄在「同一抽」意義上是否對齊（**語言無關對齊指紋**）。
///
/// 比對 `(time, resourceId, qualityLevel, count)` 全等，**刻意排除 `name`／
/// `resourceType`／`languageCode`** —— 換遊戲語言重抓時這些在地化欄位會變，唯有
/// 排除它們，舊紀錄才能被辨識為同一抽而保留原語言。鳴潮無唯一 id 且同十連 time
/// 相同，故只用於序列對齊輔助、不可單獨當主鍵。
bool recordsEqual(GachaRecord a, GachaRecord b) =>
    a.time == b.time &&
    a.resourceId == b.resourceId &&
    a.qualityLevel == b.qualityLevel &&
    a.count == b.count;
```

- [ ] **Step 4: Run tests; verify pass**

Run: `fvm flutter test test/services/record_merge_test.dart`
Expected: PASS. (The existing `recordsEqual 五欄位全等` group still passes — equal-name records remain equal; only the now-removed `name 不同 → false` semantics changed, which Step 1 rewrote.)

- [ ] **Step 5: Commit**

```bash
git add lib/services/record_merge.dart test/services/record_merge_test.dart
git commit -m "fix(merge): align records on language-invariant fields

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Persisted encore-backed `kind` on `ItemImageEntry`

**Files:**
- Modify: `lib/services/item_image_index.dart` (`ItemImageEntry` field + load/save)
- Modify: `lib/state/item_image_index.dart` (`mergeIcon` kind param; preserve in `mergeItemDetail`)
- Test: `test/services/item_image_index_test.dart`, `test/state/item_image_index_test.dart`

- [ ] **Step 1: Write failing tests for `kind` round-trip + merge preservation**

In `test/services/item_image_index_test.dart`, add (use whatever temp-dir/storage helpers the file already defines; the assertion is what matters):

```dart
test('ItemImageEntry.kind round-trips through storage save/load', () async {
  final dir = await Directory.systemTemp.createTemp('iii_kind');
  addTearDown(() => dir.delete(recursive: true));
  final storage = ItemImageIndexStorage(dir);
  await storage.save(
    ItemImageIndex(
      items: {
        1211: const ItemImageEntry(
          iconUrl: 'https://x/icon.webp',
          noImage: false,
          permanentNoImage: false,
          kind: 'kind:character',
        ),
      },
    ),
  );
  final loaded = await storage.load();
  expect(loaded.lookupImage(1211)!.kind, 'kind:character');
});

test('ItemImageEntry.kind defaults to null when absent in JSON', () async {
  final dir = await Directory.systemTemp.createTemp('iii_kind_legacy');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/item_image_index.json');
  await file.writeAsString(
    '{"version":2,"items":{"1211":{"icon_url":"u","no_image":false,'
    '"permanent_no_image":false,"detail_by_lang":{}}}}',
  );
  final loaded = await ItemImageIndexStorage(dir).load();
  expect(loaded.lookupImage(1211)!.kind, isNull);
});
```

In `test/state/item_image_index_test.dart`, add (follow the file's existing `ProviderContainer`/override setup):

```dart
test('mergeIcon writes kind; mergeItemDetail preserves it', () async {
  // (Build the container + notifier the way other tests in this file do.)
  await notifier.mergeIcon(
    resourceId: 1211,
    iconUrl: 'u',
    kind: 'kind:character',
    noImage: false,
    permanentNoImage: false,
  );
  expect(container.read(itemImageIndexProvider).lookupImage(1211)!.kind,
      'kind:character');

  await notifier.mergeItemDetail(
    resourceId: 1211,
    lang: 'zh-Hant',
    detail: const ItemDetailL10n(
      intro: 'i', elementName: '', weaponTypeName: '', skins: [],
    ),
  );
  // detail merge must not wipe kind.
  expect(container.read(itemImageIndexProvider).lookupImage(1211)!.kind,
      'kind:character');
});

test('mergeIcon without kind preserves existing kind', () async {
  await notifier.mergeIcon(
    resourceId: 1211, iconUrl: 'u', kind: 'kind:character',
    noImage: false, permanentNoImage: false,
  );
  await notifier.mergeIcon(
    resourceId: 1211, iconUrl: 'u2',
    noImage: false, permanentNoImage: false,
  );
  expect(container.read(itemImageIndexProvider).lookupImage(1211)!.kind,
      'kind:character');
});
```

- [ ] **Step 2: Run; verify failure**

Run: `fvm flutter test test/services/item_image_index_test.dart test/state/item_image_index_test.dart`
Expected: FAIL — `ItemImageEntry` has no `kind`; `mergeIcon` has no `kind` param.

- [ ] **Step 3: Add `kind` to `ItemImageEntry`**

In `lib/services/item_image_index.dart`, add the constructor param + field:

```dart
  const ItemImageEntry({
    required this.iconUrl,
    required this.noImage,
    required this.permanentNoImage,
    this.detailByLang = const {},
    this.hasLuckdraw,
    this.kind,
  });
```

Add the field (after `detailByLang`):

```dart
  /// 該物品的語言無關類型聚合鍵（`kItemKindCharacter`／`kItemKindWeapon`／
  /// `kItemKindItem`），由 encore catalog 清單歸屬判定；尚未分類為 null。
  /// 供 [itemTypeKeyOf] 做語言無關分類，取代 resourceType 語言對應表。
  final String? kind;
```

In `load()`, read it:

```dart
        items[id] = ItemImageEntry(
          iconUrl: v['icon_url'] as String?,
          noImage: (v['no_image'] as bool?) ?? false,
          permanentNoImage: (v['permanent_no_image'] as bool?) ?? false,
          detailByLang: _detailByLangFromJson(v['detail_by_lang']),
          hasLuckdraw: v['has_luckdraw'] as bool?,
          kind: v['kind'] as String?,
        );
```

In `save()`, write it:

```dart
        (k, v) => MapEntry('$k', {
          'icon_url': v.iconUrl,
          'no_image': v.noImage,
          'permanent_no_image': v.permanentNoImage,
          'has_luckdraw': v.hasLuckdraw,
          'kind': v.kind,
          'detail_by_lang': v.detailByLang.map(
            (l, d) => MapEntry(l, d.toJson()),
          ),
        }),
```

- [ ] **Step 4: Add `kind` to `mergeIcon` and preserve in `mergeItemDetail`**

In `lib/state/item_image_index.dart`, update `mergeIcon`:

```dart
  Future<void> mergeIcon({
    required int resourceId,
    required String? iconUrl,
    required bool noImage,
    required bool permanentNoImage,
    String? kind,
  }) async {
    await _lock.synchronized(() async {
      final prev = state.items[resourceId];
      final newItems = Map<int, ItemImageEntry>.from(state.items)
        ..[resourceId] = ItemImageEntry(
          iconUrl: iconUrl,
          noImage: noImage,
          permanentNoImage: permanentNoImage,
          detailByLang: prev?.detailByLang ?? const {},
          hasLuckdraw: prev?.hasLuckdraw,
          kind: kind ?? prev?.kind,
        );
      await _saveAndEmit(ItemImageIndex(items: newItems));
      _log.fine(
        'mergeIcon resourceId=$resourceId noImage=$noImage '
        'hasIcon=${iconUrl?.isNotEmpty == true} kind=${kind ?? prev?.kind}',
      );
    });
  }
```

In `mergeItemDetail`, preserve `kind` in the rebuilt entry:

```dart
        ..[resourceId] = ItemImageEntry(
          iconUrl: prev?.iconUrl,
          noImage: prev?.noImage ?? false,
          permanentNoImage: prev?.permanentNoImage ?? false,
          detailByLang: mergedDetail,
          hasLuckdraw: hasLuckdraw || (prev?.hasLuckdraw ?? false),
          kind: prev?.kind,
        );
```

- [ ] **Step 5: Run tests; verify pass**

Run: `fvm flutter test test/services/item_image_index_test.dart test/state/item_image_index_test.dart`
Expected: PASS.

- [ ] **Step 6: Verify green + commit**

Run: `fvm dart format lib/ test/` then `fvm flutter analyze` then `fvm flutter test`
Expected: `No issues found!`, `All tests passed!`

```bash
git add lib/services/item_image_index.dart lib/state/item_image_index.dart test/services/item_image_index_test.dart test/state/item_image_index_test.dart
git commit -m "feat(item-image): persist encore-derived kind on ItemImageEntry

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Rewrite `_fetchItemImages` (per-record lang + membership classification)

**Files:**
- Modify: `lib/state/gacha_repository.dart:894-1114` (`_fetchItemImages` whole method + its dartdoc)
- Test: `test/state/gacha_repository_item_image_test.dart`

This task makes `_fetchItemImages` (a) collect languages per-record, (b) fetch all three catalog lists per language and classify each `resourceId` by membership, writing `kind`, (c) back-fill `kind` for already-cached icons, (d) prefetch detail per record language using the membership kind. It removes the `itemTypeKeyOf(r)` call at the old line 909.

- [ ] **Step 1a: Make the test helper `_rec` carry a per-record language**

The existing `_rec(int resourceId, int q, String type)` helper builds records with the default `languageCode == ''`. The rewritten `_fetchItemImages` collects languages **per record** and skips empty-language records (`if (lang.isEmpty) continue;`), so without this the seeded records would be skipped and every test in this file would fail. Add a `lang` param:

```dart
GachaRecord _rec(int resourceId, int q, String type, {String lang = 'zh-Hant'}) =>
    GachaRecord(
      resourceId: resourceId,
      qualityLevel: q,
      resourceType: type,
      cardPoolType: '1',
      name: 'r$resourceId',
      count: 1,
      time: DateTime.utc(2026, 5, 21),
      languageCode: lang,
    );
```

In the existing `'詳情逐 (id, lang) 預抓：多語言帳號各存一份'` test, change the two seeded records to carry their account's language explicitly: `_rec(1503, 5, '角色', lang: 'zh-Hant')` for the zh-Hant account and `_rec(1503, 5, 'Character', lang: 'en')` for the en account. (Previously this test relied on the account-level `languageCode`; now language is per-record.)

- [ ] **Step 1b: Write failing tests for membership classification + kind backfill**

In `test/state/gacha_repository_item_image_test.dart`, add (the harness `build({characters, weapons, details})`, `debugSeedAccount`, `debugRunItemImagesOnly`, and `tempDir` already exist):

```dart
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
  expect(await File('${tempDir.path}/1211_icon.png').readAsBytes(), [9, 9, 9]);
});
```

- [ ] **Step 2: Run; verify failure**

Run: `fvm flutter test test/state/gacha_repository_item_image_test.dart`
Expected: FAIL — current code classifies via `itemTypeKeyOf` (language table), does not write `kind`, and collects languages per-account not per-record.

- [ ] **Step 3: Replace the `_fetchItemImages` method body**

In `lib/state/gacha_repository.dart`, replace the entire `_fetchItemImages` method (keep the method signature `Future<int> _fetchItemImages(http.Client client)`), and update its leading dartdoc to describe the new flow. New body:

```dart
  Future<int> _fetchItemImages(http.Client client) async {
    var downloaded = 0;
    final fetcher = ref.read(itemImageFetcherProvider);
    final indexNotifier = ref.read(itemImageIndexProvider.notifier);
    final cacheDir = ref.read(itemImageCacheDirProvider);
    await indexNotifier.waitForLoad();

    // (1) 逐筆收集 id → 出現過的擷取語言集合（per-record lang）。
    final langsById = <int, Set<String>>{};
    for (final data in state.byUid.values) {
      for (final list in data.banners.values) {
        for (final r in list) {
          final lang = r.languageCode;
          if (lang.isEmpty) continue;
          langsById.putIfAbsent(r.resourceId, () => {}).add(lang);
        }
      }
    }
    if (langsById.isEmpty) return downloaded;

    // (2) gate：icon 未就緒、kind 未分類（含既有快取 icon 的升級回填）、或某 lang
    //     詳情未抓 → 需處理。全無 → early return（不打 catalog）。
    final idx0 = ref.read(itemImageIndexProvider);
    bool needsWork(int id) {
      final existing = idx0.lookupImage(id);
      if (needsItemImageFetch(
        existing: existing,
        cacheDir: cacheDir,
        resourceId: id,
      )) {
        return true;
      }
      if (existing?.kind == null) return true;
      if (existing!.kind != kItemKindItem) {
        for (final lang in langsById[id]!) {
          if (!existing.detailByLang.containsKey(lang)) return true;
        }
      }
      return false;
    }

    final workIds = langsById.keys.where(needsWork).toSet();
    if (workIds.isEmpty) return downloaded;

    bool isAborted() => !ref.mounted || _cancelTriggered;

    // (3) 抓 catalog：對每個出現過的語言抓三清單，union 成歸屬表（kind + icon）。
    //     icon／歸屬語言無關，union 容忍個別語系缺漏；首個命中語言為準。
    const allKinds = {kItemKindCharacter, kItemKindWeapon, kItemKindItem};
    final iconById = <int, String>{};
    final kindById = <int, String>{};
    final allLangs = {for (final id in workIds) ...langsById[id]!};
    for (final lang in allLangs) {
      if (isAborted()) return downloaded;
      final catalog = await fetcher.fetchCatalog(
        lang: lang,
        kinds: allKinds,
        client: client,
      );
      for (final kind in allKinds) {
        final m = catalog.iconByKindId[kind];
        if (m == null) continue;
        m.forEach((id, url) {
          if (url.isEmpty) return;
          iconById.putIfAbsent(id, () => url);
          kindById.putIfAbsent(id, () => kind);
        });
      }
    }

    // (4) 分類 + icon 正負取。
    final toDownload = <(int id, String iconUrl)>[];
    final positiveIds = <int>{};
    final hdIconById = <int, String>{};
    for (final id in workIds) {
      if (isAborted()) return downloaded;
      final existing = ref.read(itemImageIndexProvider).lookupImage(id);
      final iconNeeded = needsItemImageFetch(
        existing: existing,
        cacheDir: cacheDir,
        resourceId: id,
      );
      final catKind = kindById[id];
      final catIcon = iconById[id];
      if (catKind != null && catIcon != null) {
        positiveIds.add(id);
        if (iconNeeded) {
          await indexNotifier.mergeIcon(
            resourceId: id,
            iconUrl: catIcon,
            kind: catKind,
            noImage: false,
            permanentNoImage: false,
          );
          toDownload.add((id, catIcon));
        } else if (existing?.kind == null) {
          // 升級回填：icon 已快取但 kind 未分類 → 只補 kind、不重下載。
          await indexNotifier.mergeIcon(
            resourceId: id,
            iconUrl: existing!.iconUrl,
            kind: catKind,
            noImage: existing.noImage,
            permanentNoImage: existing.permanentNoImage,
          );
        }
      } else if (iconNeeded) {
        // 三清單皆無 → 負取（保留既有 kind=null；itemTypeKeyOf 退原始字串）。
        await indexNotifier.mergeIcon(
          resourceId: id,
          iconUrl: null,
          kind: null,
          noImage: true,
          permanentNoImage: false,
        );
      }
    }

    // (5) 取得物品資料階段：對「每個 (id, lang)」計 checking 進度（保留既有語意：
    //     total = 待查 id×lang 數，含負取／道具）。正取角色／武器且該 lang 詳情未抓
    //     （或 luckdraw 尚未評估）時抓詳情；其餘只計進度不抓。
    final checkWorklist = <(int id, String lang)>[
      for (final id in workIds)
        for (final lang in langsById[id]!) (id, lang),
    ];
    var checkedDone = 0;
    await runConcurrent<(int, String)>(
      items: checkWorklist,
      concurrency: fetcher.downloadConcurrency,
      shouldAbort: isAborted,
      worker: (item) async {
        final (id, lang) = item;
        final kind = kindById[id];
        try {
          if (kind != null &&
              kind != kItemKindItem &&
              positiveIds.contains(id)) {
            final existing = ref.read(itemImageIndexProvider).lookupImage(id);
            final detailAlready =
                existing?.detailByLang.containsKey(lang) ?? false;
            final luckdrawUnevaluated =
                kind == kItemKindCharacter && existing?.hasLuckdraw == null;
            if (!detailAlready || luckdrawUnevaluated) {
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
                    skins: [
                      for (final s in detail.skins)
                        ItemSkin(
                          formationCard: s.formationCard,
                          name: s.name,
                          subDecName: s.subDecName,
                          bgDescription: s.bgDescription,
                        ),
                    ],
                  ),
                  hasLuckdraw: detail.hasLuckdraw,
                );
                if (kind == kItemKindCharacter && detail.iconHd.isNotEmpty) {
                  hdIconById[id] = detail.iconHd;
                }
              }
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
            totalCount: checkWorklist.length,
          ),
        );
      },
    );

    // (6) 角色 icon 升級為詳情提供的 256px HD 版。序列、在並行 5 之後 → 無 race。
    for (var i = 0; i < toDownload.length; i++) {
      final hd = hdIconById[toDownload[i].$1];
      if (hd == null) continue;
      await indexNotifier.mergeIcon(
        resourceId: toDownload[i].$1,
        iconUrl: hd,
        kind: kItemKindCharacter,
        noImage: false,
        permanentNoImage: false,
      );
      toDownload[i] = (toDownload[i].$1, hd);
    }

    // (7) 下載階段：只下載 icon（立繪走 dialog lazy）。
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

Update the method's leading dartdoc (the long comment block above the method) to describe the new 7-step flow: per-record lang collection → work gate (icon/kind/detail) → fetch 3 catalog lists per lang & union membership → classify + icon positive/negative → per-lang detail prefetch (character/weapon) → HD icon upgrade → download. Note that `kind` now comes from catalog membership, not `itemTypeKeyOf`.

Remove the now-unused `itemTypeKeyOf` import if the analyzer flags it as unused (it likely remains used elsewhere in the file — only remove if analyze says unused).

- [ ] **Step 4: Run tests; verify pass**

Run: `fvm flutter test test/state/gacha_repository_item_image_test.dart`
Expected: PASS. The `checking` progress total stays `id × lang` examination count (the `checkWorklist` design preserves the existing two-phase semantics), so the existing progress tests (`進度分兩階段`, `全查無圖`) pass unchanged once `_rec` carries a language (Step 1a). The new classification/backfill tests pass.

- [ ] **Step 5: Verify green + commit**

Run: `fvm dart format lib/ test/` then `fvm flutter analyze` then `fvm flutter test`
Expected: `No issues found!`, `All tests passed!`

```bash
git add lib/state/gacha_repository.dart test/state/gacha_repository_item_image_test.dart
git commit -m "feat(item-image): classify kind by encore catalog membership, collect languages per-record

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Index-backed `itemTypeKeyOf(r, index)` threaded through consumers

**Files:**
- Modify: `lib/services/item_type_kind.dart` (remove table; new signature)
- Modify: `lib/services/gacha_row.dart:37-60` (`buildRecordRows` takes index)
- Modify: `lib/services/gacha_stats.dart:58-94` (`computeGachaStats` takes index)
- Modify: `lib/services/overview_sections.dart:54-88` (`buildOverviewSections` takes index)
- Modify: `lib/widgets/share/share_card.dart:99-196` (`ShareCard.banner`/`.overview` take index)
- Modify: `lib/pages/banner_page.dart:91,107,329` and `lib/pages/overview_page.dart:52,126`
- Test: `test/services/item_type_kind_test.dart` (rewrite), plus index-threading in `gacha_stats_test`/`gacha_row_test`/`overview_sections_test` and any analyzer-flagged callers.

- [ ] **Step 1: Rewrite `item_type_kind_test` for the index-backed signature**

Replace `test/services/item_type_kind_test.dart` with:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

GachaRecord _r({
  int resourceId = 1211,
  String resourceType = '角色',
  String lang = 'zh-Hant',
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: 5,
  resourceType: resourceType,
  cardPoolType: '1',
  name: 'x',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, 3),
  languageCode: lang,
);

ItemImageIndex _indexWith(Map<int, String> kinds) => ItemImageIndex(
  items: {
    for (final e in kinds.entries)
      e.key: ItemImageEntry(
        iconUrl: 'u',
        noImage: false,
        permanentNoImage: false,
        kind: e.value,
      ),
  },
);

void main() {
  group('itemTypeKeyOf（依 index 的 encore 歸屬 kind）', () {
    test('index 命中 → 回 canonical kind', () {
      final index = _indexWith({1211: kItemKindCharacter});
      expect(itemTypeKeyOf(_r(resourceId: 1211), index), kItemKindCharacter);
    });

    test('同一 id 不同擷取語言 → 同一 canonical kind（跨語言合併）', () {
      final index = _indexWith({1211: kItemKindCharacter});
      expect(
        itemTypeKeyOf(_r(resourceId: 1211, lang: 'zh-Hant'), index),
        itemTypeKeyOf(_r(resourceId: 1211, lang: 'en'), index),
      );
    });

    test('index 無此 id → fallback 原始 resourceType 字串', () {
      const empty = ItemImageIndex.empty();
      expect(itemTypeKeyOf(_r(resourceType: '캐릭터'), empty), '캐릭터');
    });

    test('index entry 有但 kind==null → fallback 原始字串', () {
      final index = ItemImageIndex(
        items: {
          1211: const ItemImageEntry(
            iconUrl: null,
            noImage: true,
            permanentNoImage: false,
          ),
        },
      );
      expect(itemTypeKeyOf(_r(resourceType: 'Mystery'), index), 'Mystery');
    });
  });

  group('itemTypeKeyLabel', () {
    test('canonical key 轉在地化標籤；fallback 原樣（en）', () async {
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      expect(itemTypeKeyLabel(kItemKindCharacter, l), 'Character');
      expect(itemTypeKeyLabel(kItemKindWeapon, l), 'Weapon');
      expect(itemTypeKeyLabel(kItemKindItem, l), l.kindItem);
      expect(itemTypeKeyLabel('', l), l.kindUnknown);
      expect(itemTypeKeyLabel('Mystery', l), 'Mystery');
    });
  });
}
```

- [ ] **Step 2: Run; verify failure**

Run: `fvm flutter test test/services/item_type_kind_test.dart`
Expected: FAIL — `itemTypeKeyOf` still takes a single arg / `_resourceTypeToKind` table still drives it.

- [ ] **Step 3: Replace `item_type_kind.dart` implementation**

In `lib/services/item_type_kind.dart`: remove the `_resourceTypeToKind` map and the `app_localizations`/`gacha_record` imports as needed, add the `item_image_index` import, and rewrite `itemTypeKeyOf`. Keep the three `kItemKind*` constants and `itemTypeKeyLabel` unchanged. New core:

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';

// ...keep kItemKindCharacter / kItemKindWeapon / kItemKindItem constants...

/// 解析單筆 [r] 的類型聚合鍵：以 [index] 的 encore 歸屬 kind（`resourceId → kind`）
/// 判定（角色／武器／道具），跨語系天然一致；index 無此 id 或尚未分類（kind==null）
/// 時 fallback 回原始 `resourceType` 字串（含空字串）。
///
/// 取代前身版本的 `resourceType` 語言對應表（只涵蓋 4 語系、不可靠）；改用語言無關
/// 的 encore 清單歸屬，等價於原神版 `itemTypeKeyOf(r, HoYoWikiIndex)`。
String itemTypeKeyOf(GachaRecord r, ItemImageIndex index) =>
    index.lookupImage(r.resourceId)?.kind ?? r.resourceType;

// ...keep itemTypeKeyLabel unchanged...
```

- [ ] **Step 4: Thread `index` into `buildRecordRows`**

In `lib/services/gacha_row.dart`, add an `index` param and pass it to `itemTypeKeyOf`:

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
// ...

List<RecordRow> buildRecordRows(
  List<GachaRecord> records,
  ItemImageIndex index, {
  int mainRank = 5,
}) {
  if (records.isEmpty) return const [];
  final asc = records.reversed.toList(growable: false);
  final out = <RecordRow>[];
  var total = 0;
  var pity = 0;
  for (final r in asc) {
    total++;
    pity++;
    out.add(
      RecordRow(
        record: r,
        totalIndex: total,
        mainPityIndex: pity,
        itemTypeKey: itemTypeKeyOf(r, index),
      ),
    );
    if (r.qualityLevel == mainRank) {
      pity = 0;
    }
  }
  return out.reversed.toList(growable: false);
}
```

- [ ] **Step 5: Thread `index` into `computeGachaStats`**

In `lib/services/gacha_stats.dart`, add `index` and pass to `itemTypeKeyOf`:

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
// ...
GachaStats computeGachaStats(List<GachaRecord> records, ItemImageIndex index) {
  // ...unchanged loop, except:
    final key = itemTypeKeyOf(r, index);
  // ...rest unchanged...
}
```

Update the function dartdoc to say kind comes from the index (encore membership), fallback raw string.

- [ ] **Step 6: Thread `index` into `buildOverviewSections`**

In `lib/services/overview_sections.dart`:

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
// ...
OverviewSections buildOverviewSections(
  Map<String, List<GachaRecord>> activeBanners,
  ItemImageIndex index,
) {
  // ...unchanged, except:
    stats: computeGachaStats(gachaAll, index),
  // ...
}
```

- [ ] **Step 7: Thread `index` into `ShareCard` factories**

In `lib/widgets/share/share_card.dart`, add `required ItemImageIndex index` to both `ShareCard.banner(...)` and `ShareCard.overview(...)` factory params, and pass it down:

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
// banner factory:
    final stats = computeGachaStats(records, index);
// overview factory:
    final s = buildOverviewSections(banners, index);
```

(Add `required ItemImageIndex index,` to each factory's named parameter list; do not store it as a field — it is only used during construction.)

- [ ] **Step 8: Update page call sites to supply the index**

In `lib/pages/banner_page.dart` (inside the `build` method, which has `ref`):

```dart
    final imageIndex = ref.watch(itemImageIndexProvider);
    final stats = computeGachaStats(records, imageIndex);
    // ...
    final allRows = buildRecordRows(records, imageIndex, mainRank: primary.rank);
```

And in `_generateBannerShare` (capture the index from `ref` — add to the `ShareCard.banner(...)` call):

```dart
      buildCard: (icon, options) => ShareCard.banner(
        l: l,
        appVersion: appVersion,
        appIcon: icon,
        options: options,
        uid: uid,
        updatedAt: updatedAt.toLocal(),
        title: type.resolveName(l),
        records: records,
        targetRank: type.primaryPity.rank,
        index: ref.read(itemImageIndexProvider),
      ),
```

Add the import `import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';` to `banner_page.dart` if not present.

In `lib/pages/overview_page.dart`:

```dart
    final imageIndex = ref.watch(itemImageIndexProvider);
    final sec = buildOverviewSections(activeData.banners, imageIndex);
```

And in `_generateOverviewShare`:

```dart
      buildCard: (icon, options) => ShareCard.overview(
        l: l,
        appVersion: appVersion,
        appIcon: icon,
        options: options,
        uid: activeData.playerId,
        updatedAt: activeData.lastUpdated.toLocal(),
        banners: activeData.banners,
        index: ref.read(itemImageIndexProvider),
      ),
```

Add the `state/item_image_index.dart` import to `overview_page.dart` if not present.

- [ ] **Step 9: Update service tests + analyzer-driven fixes for remaining callers**

Add a shared helper to `test/services/gacha_stats_test.dart` and `test/services/gacha_row_test.dart` (and `overview_sections_test.dart`) to build an index with kinds, then pass it:

```dart
ItemImageIndex _idx(Map<int, String> kinds) => ItemImageIndex(
  items: {
    for (final e in kinds.entries)
      e.key: ItemImageEntry(
        iconUrl: 'u', noImage: false, permanentNoImage: false, kind: e.value,
      ),
  },
);
```

Update each `computeGachaStats(records)` → `computeGachaStats(records, _idx({...}))` and `buildRecordRows(records, ...)` → `buildRecordRows(records, _idx({...}), ...)`, mapping each test's resourceIds to the kind the test previously expected from the language table (e.g. character id → `kItemKindCharacter`). For tests that previously relied on the raw-string fallback (unknown `resourceType`), pass `const ItemImageIndex.empty()` so the fallback still yields the raw string.

Then run `fvm flutter analyze` and fix every remaining flagged call site (e.g. `gacha_filter_test`, `item_type_pie_test`, `sortable_table_test`, `search_filter_bar_test`, and any widget tests building rows/stats) by supplying the index the same way.

- [ ] **Step 10: Verify green + commit**

Run: `fvm dart format lib/ test/` then `fvm flutter analyze` then `fvm flutter test`
Expected: `No issues found!`, `All tests passed!`

```bash
git add -A
git commit -m "refactor(classification): make itemTypeKeyOf index-backed (encore membership)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Detail dialog consumes per-record language; remove `activeLanguageCodeProvider`

**Files:**
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart` (lang source + `itemTypeKeyOf` calls)
- Modify: `lib/state/gacha_repository.dart:118-123` (remove `activeLanguageCodeProvider`)
- Test: `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`, `test/widgets/luckdraw_chip_test.dart`

- [ ] **Step 1: Update the dialog test to drive language from `record.languageCode`**

In `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`, remove the `activeLanguageCodeProvider.overrideWithValue(activeLang)` override and instead set the language on the `GachaRecord` passed to the dialog (`languageCode: 'zh-Hant'`). Keep the existing "detail for that lang shows / fallback to first when missing" cases, now driven by `record.languageCode`. Where the test builds the record, also ensure the `itemImageIndexProvider` override supplies an entry whose `kind` matches (so `itemTypeKeyOf` resolves character/weapon as the test expects).

- [ ] **Step 2: Run; verify failure**

Run: `fvm flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart`
Expected: FAIL — `activeLanguageCodeProvider` override removed but dialog still reads it; `itemTypeKeyOf(record)` arity error after Task 5.

- [ ] **Step 3: Switch the dialog to per-record language + index-backed kind**

In `lib/widgets/dialogs/gacha_item_detail_dialog.dart`:

In `build`, replace the active-language lookup with the record's own language, and read the index for kind:

```dart
    final index = ref.watch(itemImageIndexProvider);
    final cacheDir = ref.watch(itemImageCacheDirProvider);
    final entry = index.lookupImage(record.resourceId);

    // per-lang 詳情：優先取「該筆紀錄自己的擷取語言」；該 lang 未抓時 fallback
    // 第一筆已抓語言（總比空白好）。
    final lang = record.languageCode;
    final detail =
        (lang.isEmpty ? null : entry?.detailByLang[lang]) ??
        (entry?.detailByLang.isNotEmpty == true
            ? entry!.detailByLang.values.first
            : null);
```

Replace `final isCharacter = itemTypeKeyOf(record) == kItemKindCharacter;` with:

```dart
    final isCharacter = itemTypeKeyOf(record, index) == kItemKindCharacter;
```

In the "view on encore" action, replace `lang: activeLang ?? ''` with `lang: record.languageCode`, and `kind: itemTypeKeyOf(record)` with `kind: itemTypeKeyOf(record, index)`:

```dart
            openExternalUrl(
              Uri.parse(
                encoreItemUrl(
                  kind: itemTypeKeyOf(record, index),
                  resourceId: record.resourceId,
                  lang: record.languageCode,
                ),
              ),
            );
```

In `_captureLuckdraw` call sites (the `_retryEntry` luckdraw branch and the post-frame luckdraw scheduling), replace `ref.read(activeLanguageCodeProvider) ?? ''` with `widget.record.languageCode`. And in `_captureLuckdraw`'s `service.capture(... kind: itemTypeKeyOf(widget.record) ...)`, change to `kind: itemTypeKeyOf(widget.record, ref.read(itemImageIndexProvider))`.

- [ ] **Step 4: Remove `activeLanguageCodeProvider`**

In `lib/state/gacha_repository.dart`, delete the `activeLanguageCodeProvider` provider (lines ~118-123). Run `fvm flutter analyze`; fix any remaining references (there should be none in `lib/` after Step 3; remove the override in `test/widgets/luckdraw_chip_test.dart` and set `languageCode` on its record instead).

- [ ] **Step 5: Run tests; verify pass**

Run: `fvm flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart test/widgets/luckdraw_chip_test.dart`
Expected: PASS.

- [ ] **Step 6: Full verify + commit**

Run: `fvm dart format lib/ test/` then `fvm flutter analyze` then `fvm flutter test`
Expected: `No issues found!`, `All tests passed!`

```bash
git add -A
git commit -m "feat(dialog): drive item detail language and kind from the record

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

- [ ] Run the full quality gate one more time from a clean tree:

Run: `fvm dart format lib/ test/` then `fvm flutter analyze` then `fvm flutter test`
Expected: `No issues found!` and `All tests passed!`

- [ ] Confirm against the spec's acceptance criteria:
  1. Quality gate green.
  2. Switching in-game language and re-capturing keeps old records' name/type/language; only new pulls are in the new language (mixed-language list).
  3. The detail dialog shows each record's own captured-language encore detail.
  4. Classification no longer depends on the `resourceType` language table: any locale (incl. ko/fr/de) classifies characters/weapons canonically after a catalog fetch; stats don't split across languages.
  5. Existing saved data loads losslessly (records backfilled, kind filled after next catalog fetch).
