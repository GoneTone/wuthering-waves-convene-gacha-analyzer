# WuWa Tracker null resourceId 匯入修復 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓 WuWa Tracker 匯出檔中 `resourceId` 為 null 的紀錄不再使整檔匯入崩潰，改以三層 name→id 解析（同檔回填 → encore 清單 → name 穩定合成 id）保留全部資料，並加 name 清理防護避免跨來源重複。

**Architecture:** `parse()` 維持純同步函式，接收可選 `ItemNameResolver`（由 `settings_page` 預抓 encore 清單後注入）；缺 id 紀錄依序嘗試同檔 name→id 表、encore 解析器、決定性合成負 id。合成 id 工具放模型層 `gacha_record.dart`，`record_merge` 與 importer 皆只依賴模型。`mergeBackupRecords` 末端加去重防護，丟棄「已有真實 id 雙胞」的合成筆。

**Tech Stack:** Dart / Flutter、Riverpod（provider 讀取）、`package:http`（encore 清單）、`flutter_test`。指令一律優先 `fvm`，找不到再退回 `flutter`／`dart`。

---

## File Structure

- `lib/models/gacha_record.dart`（修改）：新增 `syntheticResourceIdForName` 與 `isSyntheticResourceId` 兩個純函式。
- `lib/services/item_image_fetcher.dart`（修改）：`EncoreCatalog` 新增 `idByName` 欄位與 `resolveByName`；`fetchCatalog`／`_fetchCatalogKind` 一併解析清單 `Name`。
- `lib/services/platform_import.dart`（修改）：新增 `ItemNameResolver` typedef，`parse` 介面加可選參數。
- `lib/services/importers/wuwa_tracker_importer.dart`（修改）：防護式讀取 + 三層解析 + 統計 log + 註解更新。
- `lib/services/record_merge.dart`（修改）：`mergeBackupRecords` 末端加 `_dropSupersededSynthetic`。
- `lib/pages/settings_page.dart`（修改）：匯入前預抓 encore 清單建解析器並注入 `parse()`。
- 測試：`test/models/gacha_record_test.dart`、`test/services/importers/wuwa_tracker_importer_test.dart`、`test/services/record_merge_test.dart`（皆延伸既有檔）。

---

## Task 1: 合成 id 工具（gacha_record.dart）

**Files:**
- Modify: `lib/models/gacha_record.dart`
- Test: `test/models/gacha_record_test.dart`

- [ ] **Step 1: 寫失敗測試**

在 `test/models/gacha_record_test.dart` 的 `main()` 內、既有 `group('parseGachaTime / formatGachaTime', ...)` 之後，新增一個 group：

```dart
  group('syntheticResourceIdForName / isSyntheticResourceId', () {
    test('同名決定性且為負', () {
      final a = syntheticResourceIdForName('Camellya');
      final b = syntheticResourceIdForName('Camellya');
      expect(a, b);
      expect(a, isNegative);
    });

    test('不同名得不同 id', () {
      expect(
        syntheticResourceIdForName('Camellya'),
        isNot(syntheticResourceIdForName('Jinhsi')),
      );
    });

    test('isSyntheticResourceId 區分合成（負）與真實（正）', () {
      expect(
        isSyntheticResourceId(syntheticResourceIdForName('Yinlin')),
        isTrue,
      );
      expect(isSyntheticResourceId(1211), isFalse);
      expect(isSyntheticResourceId(21010023), isFalse);
    });
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/models/gacha_record_test.dart`
Expected: 編譯失敗，`syntheticResourceIdForName`／`isSyntheticResourceId` 未定義。

- [ ] **Step 3: 實作**

在 `lib/models/gacha_record.dart` 頂端加 import（檔案目前無 import）：

```dart
import 'dart:convert';
```

在檔案末端（`GachaRecord` class 之後）加：

```dart
/// 第三方匯入缺 `resourceId` 時，依物品名稱決定性產生的「合成」資源 id。
///
/// 一律為負（真實遊戲／encore id 皆正），確保不與真實 id 碰撞；同 name 必得同 id
/// （跨次匯入穩定）。**不可改用 Dart `String.hashCode`** —— 其每次程式執行 seed
/// 隨機，會破壞跨次匯入穩定性。採 FNV-1a 32-bit（over UTF-8）後映射到負數空間。
int syntheticResourceIdForName(String name) {
  var hash = 0x811c9dc5; // FNV-1a 32-bit offset basis
  for (final byte in utf8.encode(name)) {
    hash = (hash ^ byte) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff; // FNV prime
  }
  return -(hash & 0x7fffffff) - 1; // [-2^31, -1]，恆負、永不為 0
}

/// 判斷 [resourceId] 是否為 [syntheticResourceIdForName] 產生的合成 id（負值）。
bool isSyntheticResourceId(int resourceId) => resourceId < 0;
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/models/gacha_record_test.dart`
Expected: PASS（含既有 parseGachaTime 測試）。

- [ ] **Step 5: Commit**

```bash
git add lib/models/gacha_record.dart test/models/gacha_record_test.dart
git commit -m "feat(import): add deterministic synthetic resourceId helpers"
```

---

## Task 2: EncoreCatalog name→id 擴充（item_image_fetcher.dart）

**Files:**
- Modify: `lib/services/item_image_fetcher.dart`（`EncoreCatalog` class ~150-161、`fetchCatalog` ~223-241、`_fetchCatalogKind` ~244-280）
- Test: `test/services/item_image_fetcher_test.dart`（若不存在則建立）

- [ ] **Step 1: 寫失敗測試**

若 `test/services/item_image_fetcher_test.dart` 不存在則建立，內容如下；若已存在，僅把此 group 加入其 `main()`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

void main() {
  group('EncoreCatalog.resolveByName', () {
    test('以名稱查回 (id, kind)，查無回 null', () {
      const catalog = EncoreCatalog(
        iconByKindId: {},
        idByName: {
          'Jinhsi': (id: 1304, kind: kItemKindCharacter),
          'Cosmic Ripples': (id: 21010024, kind: kItemKindWeapon),
        },
      );
      expect(catalog.resolveByName('Jinhsi'), (id: 1304, kind: kItemKindCharacter));
      expect(
        catalog.resolveByName('Cosmic Ripples'),
        (id: 21010024, kind: kItemKindWeapon),
      );
      expect(catalog.resolveByName('Unknown Name'), isNull);
    });
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/item_image_fetcher_test.dart`
Expected: 編譯失敗，`EncoreCatalog` 無 `idByName` 具名參數／`resolveByName` 方法。

- [ ] **Step 3: 實作 EncoreCatalog 擴充**

在 `lib/services/item_image_fetcher.dart` 把 `EncoreCatalog` class（約 151-161 行）整段替換為：

```dart
/// 單一 lang 的 encore 列表查表結果：icon（kind → id → URL）與 name→(id, kind)。
class EncoreCatalog {
  /// 建立 [EncoreCatalog]。
  const EncoreCatalog({required this.iconByKindId, this.idByName = const {}});

  /// kind（`kItemKind*`）→ `{resourceId → iconUrl}`。
  final Map<String, Map<int, String>> iconByKindId;

  /// 物品名稱 → (resourceId, kind)；跨 kind union，同名以首個命中為準。
  /// 供第三方匯入回填缺 id 紀錄（見 `wuwa_tracker_importer`）。
  final Map<String, ({int id, String kind})> idByName;

  /// 查 [kind] 的 [id] 對應 icon URL；查無回 null。
  String? iconFor({required String kind, required int id}) =>
      iconByKindId[kind]?[id];

  /// 以物品名稱查 (resourceId, kind)；查無回 null。
  ({int id, String kind})? resolveByName(String name) => idByName[name];
}
```

- [ ] **Step 4: 實作 fetchCatalog / _fetchCatalogKind 一併解析 Name**

把 `fetchCatalog`（約 223-241 行）整段替換為：

```dart
  /// 對 [kinds] 內每個 kind 打 encore 列表端點一次，組 [EncoreCatalog]
  /// （icon 與 name→(id, kind) 兩表）。
  ///
  /// 單一 kind 端點失敗（非 2xx／逾時／解析爛）→ 該 kind 回空（不 throw），
  /// 該 kind 物品交由呼叫端落負取／解析器無命中。
  Future<EncoreCatalog> fetchCatalog({
    required String lang,
    required Set<String> kinds,
    required http.Client client,
  }) async {
    final iconByKindId = <String, Map<int, String>>{};
    final idByName = <String, ({int id, String kind})>{};
    final encLang = encoreLang(lang);
    for (final kind in kinds) {
      final seg = _kindToSegment[kind];
      if (seg == null) continue;
      final parsed = await _fetchCatalogKind(
        lang: encLang,
        kind: kind,
        seg: seg,
        client: client,
      );
      iconByKindId[kind] = parsed.icons;
      parsed.names.forEach((name, id) {
        idByName.putIfAbsent(name, () => (id: id, kind: kind));
      });
    }
    return EncoreCatalog(iconByKindId: iconByKindId, idByName: idByName);
  }
```

把 `_fetchCatalogKind`（約 244-280 行）整段替換為：

```dart
  /// 抓單一 kind 的列表並解析 `{id → iconUrl}` 與 `{name → id}`；任何失敗回兩空 map。
  Future<({Map<int, String> icons, Map<String, int> names})> _fetchCatalogKind({
    required String lang,
    required String kind,
    required String seg,
    required http.Client client,
  }) async {
    const empty = (icons: <int, String>{}, names: <String, int>{});
    final url = Uri.parse('$_encoreApiBase/$lang/$seg');
    try {
      final res = await client.get(url).timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        _log.warning(
          'catalog kind=$seg non-2xx status=${res.statusCode} lang=$lang',
        );
        return empty;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final (listKey, iconKey) = switch (kind) {
        kItemKindCharacter => ('roleList', 'RoleHeadIcon'),
        kItemKindWeapon => ('weapons', 'Icon'),
        _ => ('itemList', 'Icon'),
      };
      final list = body[listKey];
      if (list is! List) return empty;
      final icons = <int, String>{};
      final names = <String, int>{};
      for (final e in list) {
        if (e is! Map<String, dynamic>) continue;
        final id = e['Id'];
        if (id is! int) continue;
        final icon = e[iconKey];
        if (icon is String && icon.isNotEmpty) icons[id] = icon;
        final name = e['Name'];
        if (name is String && name.isNotEmpty) names.putIfAbsent(name, () => id);
      }
      _log.info(
        'catalog kind=$seg lang=$lang icons=${icons.length} names=${names.length}',
      );
      return (icons: icons, names: names);
    } catch (e) {
      _log.warning('catalog kind=$seg failed lang=$lang err=$e');
      return empty;
    }
  }
```

- [ ] **Step 5: 跑測試確認通過**

Run: `fvm flutter test test/services/item_image_fetcher_test.dart`
Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add lib/services/item_image_fetcher.dart test/services/item_image_fetcher_test.dart
git commit -m "feat(import): expose encore catalog name->id lookup"
```

---

## Task 3: ItemNameResolver typedef（platform_import.dart）

**Files:**
- Modify: `lib/services/platform_import.dart`

> 此 task 僅改介面定義與簽名，importer 實作在 Task 4 同步更新；故 Task 3 與 Task 4 之間**先不跑 analyze**（過渡期 `WuwaTrackerImporter` 的 `@override` 簽名暫不符）。完成 Task 4 後一起驗證。

- [ ] **Step 1: 加 typedef 與介面簽名**

在 `lib/services/platform_import.dart`，於 `abstract interface class PlatformImporter` 之前加 typedef：

```dart
/// 以物品名稱解析回真實 resourceId 與 kind；查無回 null。
/// 供 importer 回填缺 id 的紀錄（如以 encore 清單建立）。
typedef ItemNameResolver = ({int id, String kind})? Function(String name);
```

把介面內 `parse` 宣告（約 26-29 行）替換為：

```dart
  /// 解析檔案內容為 [AccountsBundle]。
  ///
  /// 非此平台格式丟 `ForeignBundleException`；結構／型別不符丟 [FormatException]。
  /// [nameResolver]：缺 id 紀錄的名稱解析器（如 encore 清單），null＝不解析。
  AccountsBundle parse(String content, {ItemNameResolver? nameResolver});
```

- [ ] **Step 2: Commit（與 Task 4 連動，暫不驗證）**

```bash
git add lib/services/platform_import.dart
git commit -m "feat(import): add ItemNameResolver to PlatformImporter.parse"
```

---

## Task 4: 三層解析 + 防護式讀取（wuwa_tracker_importer.dart）

**Files:**
- Modify: `lib/services/importers/wuwa_tracker_importer.dart`（`parse` 方法 55-165 行）
- Test: `test/services/importers/wuwa_tracker_importer_test.dart`

- [ ] **Step 1: 寫失敗測試**

在 `test/services/importers/wuwa_tracker_importer_test.dart` 頂端 import 區加：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/five_star_collection.dart';
```

在 `main()` 內末端（既有 `same-timestamp` 測試之後）加三個測試：

```dart
  test('回填 null resourceId：同檔同名帶 id', () {
    const sample = '''
{
  "playerId": "700050216",
  "pulls": [
    {"cardPoolType": 1, "resourceId": 1211, "qualityLevel": 5, "name": "Denia", "time": "2026-05-21T02:39:03+00:00"},
    {"cardPoolType": 1, "resourceId": null, "qualityLevel": 5, "name": "Denia", "time": "2024-11-17T08:20:26Z"}
  ]
}
''';
    final pool = importer.parse(sample).accounts.single.data.banners['1']!;
    expect(pool, hasLength(2));
    expect(pool.every((r) => r.resourceId == 1211), isTrue);
    expect(pool.every((r) => r.resourceType == kItemKindCharacter), isTrue);
  });

  test('回填 null resourceId：注入 encore 解析器', () {
    const sample = '''
{
  "playerId": "700050216",
  "pulls": [
    {"cardPoolType": 1, "resourceId": null, "qualityLevel": 5, "name": "Jinhsi", "time": "2024-11-17T08:20:26Z"}
  ]
}
''';
    final bundle = importer.parse(
      sample,
      nameResolver: (name) =>
          name == 'Jinhsi' ? (id: 1304, kind: kItemKindCharacter) : null,
    );
    final rec = bundle.accounts.single.data.banners['1']!.single;
    expect(rec.resourceId, 1304);
    expect(rec.resourceType, kItemKindCharacter);
  });

  test('解不掉 → 合成穩定負 id，五星一覽依名分格', () {
    const sample = '''
{
  "playerId": "700050216",
  "pulls": [
    {"cardPoolType": 1, "resourceId": null, "qualityLevel": 5, "name": "Camellya", "time": "2024-11-17T08:20:26Z"},
    {"cardPoolType": 1, "resourceId": null, "qualityLevel": 5, "name": "Jinhsi", "time": "2024-11-16T08:20:26Z"}
  ]
}
''';
    final pool = importer.parse(sample).accounts.single.data.banners['1']!;
    final camellya = pool.firstWhere((r) => r.name == 'Camellya');
    final jinhsi = pool.firstWhere((r) => r.name == 'Jinhsi');
    expect(camellya.resourceId, isNegative);
    expect(camellya.resourceId, syntheticResourceIdForName('Camellya'));
    expect(jinhsi.resourceId, isNot(camellya.resourceId));
    expect(camellya.resourceType, '');
    expect(buildFiveStarCollection(pool), hasLength(2));
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/importers/wuwa_tracker_importer_test.dart`
Expected: 既有 8 測試仍編譯；新測試失敗（null 轉型崩潰／encore 參數未使用／合成 id 未實作）。

- [ ] **Step 3: 實作 parse 三層解析**

把 `wuwa_tracker_importer.dart` 的 `parse` 方法（55-165 行整個方法）替換為下方版本，並在 `WuwaTrackerImporter` class 內加 `_kindByIdLength` 私有方法：

```dart
  /// 解析 WuWa Tracker 的 wuwatracker-pulls JSON 匯出為 [AccountsBundle]。
  ///
  /// 缺 `resourceId` 的紀錄（早期版本）依序回填：同檔 name→id 表 → [nameResolver]
  /// （如 encore 清單）→ 決定性合成負 id（[syntheticResourceIdForName]），零資料遺失。
  @override
  AccountsBundle parse(String content, {ItemNameResolver? nameResolver}) {
    Object? raw;
    try {
      raw = jsonDecode(content);
    } catch (e) {
      _log.warning('wuwa_tracker import: invalid JSON ($e)');
      throw const FormatException('Invalid JSON');
    }
    if (raw is! Map<String, dynamic>) {
      _log.warning('wuwa_tracker import: top-level not an object');
      throw const ForeignBundleException();
    }
    final playerId = raw['playerId'];
    final pulls = raw['pulls'];
    if (playerId is! String || playerId.isEmpty || pulls is! List) {
      _log.warning(
        'wuwa_tracker import: missing playerId/pulls (foreign file)',
      );
      throw const ForeignBundleException();
    }

    try {
      // 第 1 層基礎：以同檔所有帶真實 id 的紀錄建 name→id 表（回填缺 id 用）。
      final inFileNameToId = <String, int>{};
      for (final entry in pulls) {
        if (entry is! Map<String, dynamic>) continue;
        final rid = entry['resourceId'];
        final name = entry['name'];
        if (rid is num && name is String) {
          inFileNameToId.putIfAbsent(name, () => rid.toInt());
        }
      }

      final banners = <String, List<GachaRecord>>{};
      var skipped = 0;
      var fromInFile = 0;
      var fromEncore = 0;
      var fromSynthetic = 0;
      for (final entry in pulls) {
        if (entry is! Map<String, dynamic>) {
          throw const FormatException('pulls[] entry must be an object');
        }
        final cardPoolType = (entry['cardPoolType'] as num).toInt().toString();
        if (!_knownPoolKeys.contains(cardPoolType)) {
          skipped++;
          continue;
        }
        final name = entry['name'] as String;

        // resourceId 解析：直接帶 → 同檔回填 → encore 解析器 → 合成負 id。
        // resourceType：有真實 id 時用位數推測（下游 encore 分類再校正）；encore
        // 命中用其 kind；合成 fallback 存空字串（顯示「未知」，不臆測類型）。
        final int resourceId;
        final String resourceType;
        final rawId = entry['resourceId'];
        if (rawId is num) {
          resourceId = rawId.toInt();
          resourceType = _kindByIdLength(resourceId);
        } else if (inFileNameToId.containsKey(name)) {
          resourceId = inFileNameToId[name]!;
          resourceType = _kindByIdLength(resourceId);
          fromInFile++;
        } else if (nameResolver?.call(name) case final r?) {
          resourceId = r.id;
          resourceType = r.kind;
          fromEncore++;
        } else {
          resourceId = syntheticResourceIdForName(name);
          resourceType = '';
          fromSynthetic++;
        }

        banners
            .putIfAbsent(cardPoolType, () => <GachaRecord>[])
            .add(
              GachaRecord(
                resourceId: resourceId,
                qualityLevel: (entry['qualityLevel'] as num).toInt(),
                resourceType: resourceType,
                cardPoolType: cardPoolType,
                name: name,
                count: 1,
                // WHY：WuWa Tracker 的 time 帶時區後綴（新紀錄 `+00:00`、舊紀錄
                // `Z`，皆 UTC instant），鳴潮全球統一 CST(+8)。toUtc() 規範化後 +8
                // → format 成牆鐘字串 → parse 回 local-kind DateTime，與官方擷取的
                // time 表示法完全一致；recordsEqual 依 DateTime==（含 isUtc）比對，
                // 唯同表示法才對齊。若未來變體改給 naive 字串，toUtc() 會改用裝置
                // 時區轉換，屆時需另行處理。
                time: parseGachaTime(
                  formatGachaTime(
                    DateTime.parse(
                      entry['time'] as String,
                    ).toUtc().add(kWuwaServerUtcOffset),
                  ),
                ),
                languageCode: 'en',
              ),
            );
      }

      // 每池由新到舊；同 time 以原陣列順序穩定 tiebreak（decorate-sort 保決定性）。
      for (final list in banners.values) {
        final indexed = list.indexed.toList();
        indexed.sort((a, b) {
          final byTime = b.$2.time.compareTo(a.$2.time);
          return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
        });
        list
          ..clear()
          ..addAll([for (final e in indexed) e.$2]);
      }

      final rawDate = raw['date'];
      final exportedAt =
          (rawDate is String ? DateTime.tryParse(rawDate)?.toUtc() : null) ??
          DateTime.now().toUtc();

      final total = banners.values.fold<int>(0, (a, b) => a + b.length);
      _log.info(
        'wuwa_tracker import parsed: player=${sanitizeUid(playerId)} '
        'pools=${banners.length} records=$total skipped=$skipped',
      );
      final nullResolved = fromInFile + fromEncore + fromSynthetic;
      if (nullResolved > 0) {
        _log.info(
          'wuwa_tracker null-resourceId resolution: inFile=$fromInFile '
          'encore=$fromEncore synthetic=$fromSynthetic (total null=$nullResolved)',
        );
      }

      final storage = BannerStorage(
        playerId: playerId,
        languageCode: 'en',
        lastUpdated: exportedAt,
        banners: banners,
      );
      return AccountsBundle(
        exportedAt: exportedAt,
        appVersion: '',
        lastActiveUid: playerId,
        accounts: [ExportedAccount(data: storage)],
      );
    } on FormatException {
      rethrow;
    } catch (e, st) {
      _log.warning('wuwa_tracker import: parse error', e, st);
      throw FormatException('Failed to parse WuWa Tracker file: $e');
    }
  }

  /// 依 resourceId 位數推測 canonical kind：≤4 碼角色、否則武器。第三方匯入缺
  /// `resourceType` 欄位時的暫定值，匯入後 encore 分類會以真實 id 校正（見 spec §3）。
  String _kindByIdLength(int resourceId) =>
      resourceId.toString().length <= 4 ? kItemKindCharacter : kItemKindWeapon;
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/services/importers/wuwa_tracker_importer_test.dart`
Expected: PASS（既有 8 + 新 3 = 11 測試全綠）。

- [ ] **Step 5: analyze 確認介面與實作對齊**

Run: `fvm flutter analyze`
Expected: `No issues found!`（Task 3 的簽名變更此時已被實作匹配）。

- [ ] **Step 6: Commit**

```bash
git add lib/services/importers/wuwa_tracker_importer.dart test/services/importers/wuwa_tracker_importer_test.dart
git commit -m "fix(import): resolve null resourceId in WuWa Tracker imports"
```

---

## Task 5: 跨來源去重防護（record_merge.dart）

**Files:**
- Modify: `lib/services/record_merge.dart`（`mergeBackupRecords` 105-112 行 + 末端加私有函式）
- Test: `test/services/record_merge_test.dart`

- [ ] **Step 1: 寫失敗測試**

在 `test/services/record_merge_test.dart` 的 `main()` 內末端加一個 group（沿用檔內既有 `r(...)` helper）：

```dart
  group('mergeBackupRecords 合成 id 去重防護', () {
    test('同 (time, quality, count, name) 有真實雙胞 → 丟合成、留真實', () {
      final synthetic = r(
        syntheticResourceIdForName('Camellya'),
        quality: 5,
        name: 'Camellya',
        sec: 3,
      );
      final real = r(1605, quality: 5, name: 'Camellya', sec: 3);
      final merged = mergeBackupRecords([synthetic], [real]);
      expect(merged, hasLength(1));
      expect(merged.single.resourceId, 1605);
    });

    test('合成筆無真實雙胞 → 原樣保留', () {
      final synthetic = r(
        syntheticResourceIdForName('Camellya'),
        quality: 5,
        name: 'Camellya',
        sec: 3,
      );
      final realOther = r(1304, quality: 5, name: 'Jinhsi', sec: 5);
      final merged = mergeBackupRecords([synthetic], [realOther]);
      expect(merged.where((x) => x.name == 'Camellya'), hasLength(1));
      expect(
        merged.where((x) => isSyntheticResourceId(x.resourceId)),
        hasLength(1),
      );
    });
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/record_merge_test.dart`
Expected: 第一個新測試失敗（合成與真實雙胞目前都會保留，`merged` 長度為 2）。

- [ ] **Step 3: 實作 heal 防護**

在 `lib/services/record_merge.dart`，把 `mergeBackupRecords`（105-112 行）末行替換：

```dart
List<GachaRecord> mergeBackupRecords(
  List<GachaRecord> local,
  List<GachaRecord> incoming,
) {
  if (local.isEmpty) return List<GachaRecord>.from(incoming);
  if (incoming.isEmpty) return List<GachaRecord>.from(local);
  return _dropSupersededSynthetic(
    _capMultiplicity(_alignedMerge(local, incoming), local, incoming),
  );
}
```

在檔案末端（`_capMultiplicity` 之後）加：

```dart
/// heal 鍵：對齊「合成↔真實」雙胞所需欄位。刻意含 [GachaRecord.name]（跨合成／
/// 真實配對需要，兩者 resourceId 本就不同）、排除 resourceId。僅供
/// [_dropSupersededSynthetic]，不污染通用 [recordsEqual]（後者排除 name 保跨語言對齊）。
String _healKey(GachaRecord r) =>
    '${r.time.microsecondsSinceEpoch}|${r.time.isUtc}|${r.qualityLevel}'
    '|${r.count}|${r.name}';

/// 去除「已有真實 id 雙胞」的合成 id 紀錄：同 [_healKey] 若同時存在真實 id 與合成
/// id 紀錄，丟棄合成那份（真實 id 取代）。根治「同檔先離線（合成）、後線上（encore
/// 真實 id）各匯一次」的重複。count 不漏 —— 合成與真實源自同份實體抽卡、同鍵數量相等。
List<GachaRecord> _dropSupersededSynthetic(List<GachaRecord> records) {
  final realKeys = <String>{
    for (final r in records)
      if (!isSyntheticResourceId(r.resourceId)) _healKey(r),
  };
  if (realKeys.isEmpty) return records;
  return [
    for (final r in records)
      if (!isSyntheticResourceId(r.resourceId) ||
          !realKeys.contains(_healKey(r)))
        r,
  ];
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/services/record_merge_test.dart`
Expected: PASS（既有測試 + 新 group 全綠）。

- [ ] **Step 5: Commit**

```bash
git add lib/services/record_merge.dart test/services/record_merge_test.dart
git commit -m "fix(import): drop synthetic records superseded by real twins on merge"
```

---

## Task 6: 匯入接線 encore 解析器（settings_page.dart）

**Files:**
- Modify: `lib/pages/settings_page.dart`（import 區、`_importFromPlatform` 約 662-709 行）

> 此 task 為 UI／網路接線，以 `analyze` + 手動驗證確認；無單元測試（避免引入 http mock infra，YAGNI）。

- [ ] **Step 1: 加 import**

在 `lib/pages/settings_page.dart` import 區加兩行（依字母序就近插入）：

```dart
import 'package:http/http.dart' as http;
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
```

- [ ] **Step 2: 加解析器建構 helper**

在 `_DataManagement` class 內（`_importFromPlatform` 方法之後）加：

```dart
  /// 為第三方匯入預抓 encore 清單（lang `en`，WuWa Tracker 名稱為英文），組
  /// name→(id, kind) 解析器供回填缺 id 紀錄；離線／失敗回 null（importer 落合成
  /// id）。best-effort，不阻斷匯入。
  Future<ItemNameResolver?> _buildEncoreNameResolver(WidgetRef ref) async {
    final fetcher = ref.read(itemImageFetcherProvider);
    final client = http.Client();
    try {
      final catalog = await fetcher.fetchCatalog(
        lang: 'en',
        kinds: const {kItemKindCharacter, kItemKindWeapon, kItemKindItem},
        client: client,
      );
      if (catalog.idByName.isEmpty) return null;
      return catalog.resolveByName;
    } catch (e, st) {
      Logger('wish.import.platform').warning(
        'platform import: encore name resolver fetch failed',
        e,
        st,
      );
      return null;
    } finally {
      client.close();
    }
  }
```

- [ ] **Step 3: 在 parse 前注入解析器**

在 `_importFromPlatform` 內，把讀檔成功後、`final AccountsBundle bundle;` 解析區塊（約 689-705 行）替換為：

```dart
    final nameResolver = await _buildEncoreNameResolver(ref);
    if (!ctx.mounted) return;

    final AccountsBundle bundle;
    try {
      bundle = platform.parse(text, nameResolver: nameResolver);
    } on ForeignBundleException {
      if (!ctx.mounted) return;
      _showSnack(
        ctx,
        l.settingsImportFailed(
          l.importReasonNotPlatformFile(platform.displayName(l)),
        ),
      );
      return;
    } on FormatException {
      if (!ctx.mounted) return;
      _showSnack(ctx, l.settingsImportFailed(l.importReasonInvalidFormat));
      return;
    }
```

- [ ] **Step 4: analyze**

Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/pages/settings_page.dart
git commit -m "feat(import): prefetch encore catalog to resolve WuWa Tracker ids"
```

---

## Task 7: 全量驗證 + 真實檔手動驗證

**Files:** 無（僅驗證）

- [ ] **Step 1: 格式化**

Run: `fvm dart format lib/ test/`
Expected: 僅本次改動檔被格式化（勿對 `.` 跑）。

- [ ] **Step 2: 靜態分析**

Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: 全測試**

Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 4: 手動驗證（真實檔）**

1. `fvm flutter run -d windows` 啟動 app。
2. 設定頁 → 從第三方平台匯入 → WuWa Tracker → 選
   `C:\Users\p2902\Downloads\測試用 700050216_2026-06-12_wuwatracker-pulls.json`。
3. 預期：匯入成功（不再是「格式無效」snackbar）。
4. 匯出 log，確認出現：
   `wuwa_tracker null-resourceId resolution: inFile=2131 encore=23 synthetic=0 (total null=2154)`
   （線上；若離線則 `encore=0 synthetic=23`）。
5. 五星一覽：確認 Camellya／Changli／Jinhsi／Shorekeeper／Yinlin／Zhezhi 等早期五星都在、各自一格（線上有 icon；離線為佔位圖）。

- [ ] **Step 5: 若有格式化改動則 commit**

```bash
git add -A
git commit -m "style: format import null-resourceId changes"
```

（若 Step 1 無改動則略過。）

---

## Self-Review 紀錄

- **Spec coverage**：第 0 層防護（Task 4）、第 1 層同檔回填（Task 4）、第 2 層 encore（Task 2+4+6）、第 3 層合成 id（Task 1+4）、name 清理防護（Task 5）、log 統計（Task 4）、Z 後綴註解修正（Task 4 time 區塊）、測試（Task 1/2/4/5）皆有對應 task。
- **型別一致**：`ItemNameResolver = ({int id, String kind})? Function(String)` 於 platform_import 定義，settings_page 回傳同型、importer `nameResolver?.call(name)` 消費同型；`EncoreCatalog.resolveByName` 簽名與 `ItemNameResolver` 相容（tear-off 注入）；`syntheticResourceIdForName`／`isSyntheticResourceId` 跨 Task 1/4/5 名稱一致。
- **無 placeholder**：所有 code step 皆完整程式碼與預期輸出。
