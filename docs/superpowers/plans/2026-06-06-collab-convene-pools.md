# 新增 角色聯動／武器聯動喚取卡池 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `cardPoolType` 10（角色聯動喚取）與 11（武器聯動喚取）完整接進資料驅動的卡池註冊表，連同 i18n、側欄圖示／標籤、時間軸配色、測試與文件全部到位。

**Architecture:** 卡池為資料驅動——單一 `gachaTypes` 清單驅動擷取迭代、統計、側欄、分頁、配色，各環節以 `cardPoolType` 字串或 `nameKey` 透過 switch 對照表分派。本次為純加法：先把「依 `nameKey`／`'10'`／`'11'` 分派」的對照表（i18n、配色、圖示、側欄標籤）補好，最後才把註冊表長到 10 筆，讓註冊表一長大時所有環節已就緒；每個 commit 都保持編譯通過、測試全綠、App 畫面正確。

**Tech Stack:** Flutter（FVM 釘版）、Dart、`flutter gen-l10n`（ARB i18n）、`flutter_test`、Riverpod。所有指令一律用 `fvm`（找不到再退回 `flutter`／`dart`）。

**設計來源：** [`docs/superpowers/specs/2026-06-06-collab-convene-pools-design.md`](../specs/2026-06-06-collab-convene-pools-design.md)

---

## File Structure

依責任分組，各檔職責：

| 檔案 | 角色 | 本計畫改動 |
|---|---|---|
| `lib/l10n/{app_zh,app_zh_Hans,app_en,app_ja}.arb` | 四語系字串來源 | 各加 4 個 key（全名 + Short）；`gachaType*` 慣例不附 `@` metadata |
| `lib/widgets/banner_colors.dart` | 時間軸各卡池配色表 | 加 `collabCharacter`／`collabWeapon` 欄位、dark/light palette、`colorFor` 兩 case |
| `lib/widgets/gacha_type_icons.dart` | 卡池 outlined 圖示對照 | 加兩 case |
| `lib/pages/app_shell.dart` | 側欄 rail 標籤／選中圖示對照 | `_railLabel`、`_railIconActive` 各加兩 case |
| `lib/data/gacha_types.dart` | 卡池註冊表（單一事實來源） | 清單加兩筆 `GachaType`、`resolveName` 加兩 case、dartdoc 集合更新 |
| `docs/鳴潮相關資料.md`、`gacha_repository.dart`、`gacha_fetcher.dart` | 文件／註解 | 把殘留「8 種／8 個／`[1..9]`」說明同步為 10 |

**範圍外（不要動）：** `rust/src/mitm.rs`、`lib/services/gacha_credential.dart`、`lib/services/gacha_fetcher.dart` 與 `lib/state/gacha_repository.dart` 的擷取/迭代邏輯——它們以 `gachaTypes` 為來源並對 `cardPoolType` 參數化，註冊表長大後自動涵蓋 10／11，**只改其中的數字註解、不改邏輯**。

---

## Task 1: i18n — 新增聯動卡池四語系字串

**Files:**
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_zh_Hans.arb`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_ja.arb`

每個 ARB 在 **`gachaTypeNewVoyageWeapon`（全名）那行之後**插入兩個全名 key，並在 **`gachaTypeNewVoyageWeaponShort`（短名）那行之後**插入兩個短名 key。`gachaType*` 系列依既有慣例**不附 `@` description**。

- [ ] **Step 1: `app_zh.arb` 加 4 key**

在 `"gachaTypeNewVoyageWeapon": "武器新旅喚取",` 之後插入：
```json
  "gachaTypeCollabCharacter": "角色聯動喚取",
  "gachaTypeCollabWeapon": "武器聯動喚取",
```
在 `"gachaTypeNewVoyageWeaponShort": "武器新旅",` 之後插入：
```json
  "gachaTypeCollabCharacterShort": "角色聯動",
  "gachaTypeCollabWeaponShort": "武器聯動",
```

- [ ] **Step 2: `app_zh_Hans.arb` 加 4 key**

在 `"gachaTypeNewVoyageWeapon": "武器新旅唤取",` 之後插入：
```json
  "gachaTypeCollabCharacter": "角色联动唤取",
  "gachaTypeCollabWeapon": "武器联动唤取",
```
在 `"gachaTypeNewVoyageWeaponShort": "武器新旅",` 之後插入：
```json
  "gachaTypeCollabCharacterShort": "角色联动",
  "gachaTypeCollabWeaponShort": "武器联动",
```

- [ ] **Step 3: `app_en.arb` 加 4 key**

在 `"gachaTypeNewVoyageWeapon": "New Voyage Weapon Convene",` 之後插入：
```json
  "gachaTypeCollabCharacter": "Collab Resonator Convene",
  "gachaTypeCollabWeapon": "Collab Weapon Convene",
```
在 `"gachaTypeNewVoyageWeaponShort": "New Voyage Weapon",` 之後插入：
```json
  "gachaTypeCollabCharacterShort": "Collab Resonator",
  "gachaTypeCollabWeaponShort": "Collab Weapon",
```

- [ ] **Step 4: `app_ja.arb` 加 4 key**

在 `"gachaTypeNewVoyageWeapon": "武器集音（旅立ち）",` 之後插入：
```json
  "gachaTypeCollabCharacter": "共鳴者集音（コラボ）",
  "gachaTypeCollabWeapon": "武器集音（コラボ）",
```
在 `"gachaTypeNewVoyageWeaponShort": "武器（旅立ち）",` 之後插入：
```json
  "gachaTypeCollabCharacterShort": "共鳴者（コラボ）",
  "gachaTypeCollabWeaponShort": "武器（コラボ）",
```

- [ ] **Step 5: 重產 l10n 並驗證 getter 存在**

Run: `fvm flutter gen-l10n`
Expected: 無錯誤輸出。

Run: `Select-String -Path lib/l10n/generated/app_localizations.dart -Pattern "gachaTypeCollabCharacter|gachaTypeCollabWeapon"`
Expected: 找到 4 個 getter 宣告（`gachaTypeCollabCharacter`、`gachaTypeCollabWeapon`、`gachaTypeCollabCharacterShort`、`gachaTypeCollabWeaponShort`）。

- [ ] **Step 6: 確認既有測試不受影響**

Run: `fvm flutter analyze`
Expected: `No issues found!`

Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 7: Commit**

```bash
git add lib/l10n/app_zh.arb lib/l10n/app_zh_Hans.arb lib/l10n/app_en.arb lib/l10n/app_ja.arb lib/l10n/generated/
git commit -m "feat(i18n): add collab convene pool names (type 10/11)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: 時間軸配色 — 聯動卡池兩色

**Files:**
- Modify: `lib/widgets/banner_colors.dart`
- Test: `test/widgets/banner_colors_test.dart`

`BannerColors` 僅由類別內 `_dark`／`_light` 兩個 const factory 建構，新增必填欄位只需同步這兩處。

- [ ] **Step 1: 更新測試以涵蓋 10 色（先紅）**

把 `test/widgets/banner_colors_test.dart` 的 `keys` 與 `hasLength` 改為 10：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/banner_colors.dart';

void main() {
  const keys = ['1', '2', '3', '4', '5', '6', '8', '9', '10', '11'];

  for (final b in [Brightness.dark, Brightness.light]) {
    test('colorFor 對 10 個 cardPoolType 皆有獨特色 ($b)', () {
      final c = BannerColors.of(b);
      final colors = keys.map(c.colorFor).toList();
      expect(colors.toSet(), hasLength(10), reason: '10 色不可重複');
      expect(c.colorFor('7'), c.fallback, reason: '無 7 池 → fallback');
      expect(c.colorFor('999'), c.fallback, reason: '未知 → fallback');
    });
  }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/banner_colors_test.dart`
Expected: FAIL — `colorFor('10')`／`colorFor('11')` 目前回 `fallback`，與其他色重複導致 `hasLength(10)` 不成立。

- [ ] **Step 3: 在 `banner_colors.dart` 加兩欄位、palette、case**

在 constructor 參數列（`required this.newVoyageWeapon,` 之後）加：
```dart
    required this.collabCharacter,
    required this.collabWeapon,
```

在 `_dark` palette（`newVoyageWeapon: Color(0xFFD98AC4), // 紫粉` 之後）加：
```dart
    collabCharacter: Color(0xFFE5689E), // 洋紅
    collabWeapon: Color(0xFF6F6BE0), // 靛藍
```

在 `_light` palette（`newVoyageWeapon: Color(0xFFA53D8C),` 之後）加：
```dart
    collabCharacter: Color(0xFFC23E7E),
    collabWeapon: Color(0xFF4A46C2),
```

在欄位宣告區（`final Color newVoyageWeapon;` 之後、`fallback` 之前）加：
```dart
  /// 角色聯動喚取配色（cardPoolType 10）。
  final Color collabCharacter;

  /// 武器聯動喚取配色（cardPoolType 11）。
  final Color collabWeapon;
```

在 `colorFor` switch（`'9' => newVoyageWeapon,` 之後）加：
```dart
    '10' => collabCharacter,
    '11' => collabWeapon,
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/banner_colors_test.dart`
Expected: PASS（dark／light 兩個 test 皆綠）。

- [ ] **Step 5: 格式化並全域驗證**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`
Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/banner_colors.dart test/widgets/banner_colors_test.dart
git commit -m "feat(ui): add timeline colors for collab convene pools

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: 側欄圖示與標籤

**Files:**
- Modify: `lib/widgets/gacha_type_icons.dart`
- Modify: `lib/pages/app_shell.dart`

無直接單元測試（既有 icon 對照亦無測試）；以 `analyze` + 全測試套件作為驗證。這些 case 在 Task 4 註冊表長大前不會被命中，先就緒即可。

- [ ] **Step 1: `gacha_type_icons.dart` 加兩 outlined case**

在 `gachaTypeOutlinedIcon` 的 `'gachaTypeNewVoyageWeapon' => Icons.explore_outlined,` 之後加：
```dart
  'gachaTypeCollabCharacter' => Icons.diversity_3_outlined,
  'gachaTypeCollabWeapon' => Icons.handshake_outlined,
```

- [ ] **Step 2: `app_shell.dart` `_railLabel` 加兩 case**

在 `'gachaTypeNewVoyageWeapon' => l.gachaTypeNewVoyageWeaponShort,` 之後加：
```dart
  'gachaTypeCollabCharacter' => l.gachaTypeCollabCharacterShort,
  'gachaTypeCollabWeapon' => l.gachaTypeCollabWeaponShort,
```

- [ ] **Step 3: `app_shell.dart` `_railIconActive` 加兩 case**

在 `'gachaTypeNewVoyageWeapon' => Icons.explore,` 之後加：
```dart
  'gachaTypeCollabCharacter' => Icons.diversity_3,
  'gachaTypeCollabWeapon' => Icons.handshake,
```

- [ ] **Step 4: 格式化並驗證**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`
Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/gacha_type_icons.dart lib/pages/app_shell.dart
git commit -m "feat(ui): add sidebar icons and labels for collab convene pools

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: 註冊表新增 type 10／11（含耦合測試）

**Files:**
- Modify: `lib/data/gacha_types.dart`
- Test: `test/data/gacha_types_test.dart`
- Test: `test/services/overview_sections_test.dart`
- Test: `test/state/gacha_repository_update_test.dart`

把 `gachaTypes` 長到 10 筆。此改動會讓上述三個測試檔的池數斷言同時失效（`overview_sections.dart` 的 `types`、擷取迴圈 `hitTypes`），故三檔須與註冊表同一個 commit 才能保持全綠。先改測試（紅），再改註冊表（綠）。

- [ ] **Step 1: 更新 `gacha_types_test.dart`（先紅）**

- 把 `gachaTypes.length` 期望 `8` → `10`。
- cardPoolType 清單尾端加 `10, 11`：
```dart
    test('共 10 個 type，cardPoolType 為 [1,2,3,4,5,6,8,9,10,11]（無 7）', () {
      expect(gachaTypes.length, 10);
      expect(gachaTypes.map((t) => t.cardPoolType).toList(), [
        1, 2, 3, 4, 5, 6, 8, 9, 10, 11,
      ]);
    });
```
- 「5★80／4★10」case 的迴圈清單加 `10, 11`：
```dart
    test('type 1/2/3/4/6/8/9/10/11 → 5★80 / 4★10', () {
      for (final cpt in [1, 2, 3, 4, 6, 8, 9, 10, 11]) {
```
- nameKey 清單尾端加兩個 key、描述 `8`→`10`：
```dart
    test('nameKey 對齊 10 個鳴潮卡池 key', () {
      expect(gachaTypes.map((t) => t.nameKey).toList(), [
        'gachaTypeCharacter',
        'gachaTypeWeapon',
        'gachaTypeStandardCharacter',
        'gachaTypeStandardWeapon',
        'gachaTypeBeginner',
        'gachaTypeBeginnerChoice',
        'gachaTypeNewVoyageCharacter',
        'gachaTypeNewVoyageWeapon',
        'gachaTypeCollabCharacter',
        'gachaTypeCollabWeapon',
      ]);
    });
```

- [ ] **Step 2: 更新 `overview_sections_test.dart`（先紅）**

`types` 期望清單尾端加 `10, 11`，描述 `8`→`10`：
```dart
  test('types 含全部 10 個卡池', () {
    final sections = buildOverviewSections(const <String, List<GachaRecord>>{});
    expect(sections.types.map((t) => t.cardPoolType).toList(), [
      1, 2, 3, 4, 5, 6, 8, 9, 10, 11,
    ]);
  });
```
同時把行 16 的測試名 `聚合全部 8 池於單段` → `聚合全部 10 池於單段`（純描述，無斷言改動）。

- [ ] **Step 3: 更新 `gacha_repository_update_test.dart`（先紅）**

逐處把池數對齊 10（共 6 個斷言 + 測試名／註解）：

| 位置 | 原 | 改 |
|---|---|---|
| test 名（happy path） | `'happy path: 8 pools fetched, ...'` | `'happy path: 10 pools fetched, ...'` |
| `expect(hitTypes, [1, 2, 3, 4, 5, 6, 8, 9])` | 8 元素 | `[1, 2, 3, 4, 5, 6, 8, 9, 10, 11]` |
| 註解 `// all 8 pools attempted ...` | 8 | `// all 10 pools attempted ...` |
| `expect(poolHits, 8)` | 8 | `expect(poolHits, 10)` |
| 註解 `round 2（hits 2-9）：完整 8 池` | 8/9 | `round 2（hits 2-11）：完整 10 池` |
| 註解 `1 次早退 + 8 次第二輪`（兩處） | 8 | `1 次早退 + 10 次第二輪` |
| `expect(hits, 9)`（三處：約 242／316／393 行） | 9 | `expect(hits, 11)` |
| 註解 `round 2 (hits 2-9)`／`完整 8 池`／`all 8 pools` | 8/9 | 對應改 10／11 |
| test 名 `'all 8 pools empty → ...'` | 8 | `'all 10 pools empty → ...'` |

說明：MockClient 以 `body['cardPoolType']` 取型別、未知型別一律回空 `_ok(const [])`，**對 10／11 自動回 `code:0` 空清單，不需改 mock**；故新池只讓 `hitTypes`／`poolHits`／`hits` 多 2，其餘斷言（`totalNewRecords`、`failedBanners`、capture 次數）不變。各 test 預存的 8-key `banners` fixture **不需**補 10／11（合併邏輯以 `existing[key] ?? []` 容忍缺鍵）。

> ⚠️ `expect(hits, 9)` 在檔內出現三次（happy/早退/重攔三條路徑的第二輪皆抓全部池），三處都要改成 `11`。`expect(poolHits, 8)` 只有一次。改完用 `Select-String -Path test/state/gacha_repository_update_test.dart -Pattern "hits, 9\b|poolHits, 8\b|, 8, 9\]|8 pools|完整 8 池"` 確認沒有殘留。

- [ ] **Step 4: 跑三檔確認失敗**

Run: `fvm flutter test test/data/gacha_types_test.dart test/services/overview_sections_test.dart test/state/gacha_repository_update_test.dart`
Expected: FAIL — 註冊表仍為 8 筆，新期望（length 10、types 含 10/11、hitTypes 含 10/11、poolHits 10、hits 11）尚未成立。

- [ ] **Step 5: 在 `gacha_types.dart` 加兩筆 GachaType + resolveName case + dartdoc**

`gachaTypes` 清單尾端（`cardPoolType: 9` 那筆之後、`];` 之前）加：
```dart
  GachaType(
    cardPoolType: 10,
    nameKey: 'gachaTypeCollabCharacter',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 11,
    nameKey: 'gachaTypeCollabWeapon',
    pities: [_pityFive80, _pityFour10],
  ),
```

`resolveName` switch（`'gachaTypeNewVoyageWeapon' => l.gachaTypeNewVoyageWeapon,` 之後）加：
```dart
    'gachaTypeCollabCharacter' => l.gachaTypeCollabCharacter,
    'gachaTypeCollabWeapon' => l.gachaTypeCollabWeapon,
```

`cardPoolType` 欄位 dartdoc 更新集合：
```dart
  /// 對應喚取記錄 API 的 `cardPoolType`（int，集合 [1,2,3,4,5,6,8,9,10,11]，無 7）。
```

- [ ] **Step 6: 跑三檔確認通過**

Run: `fvm flutter test test/data/gacha_types_test.dart test/services/overview_sections_test.dart test/state/gacha_repository_update_test.dart`
Expected: PASS。

- [ ] **Step 7: 格式化並全域驗證**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`
Run: `fvm flutter test`
Expected: `All tests passed!`（含 `banner_top_rarity_bars_test`、`share_card_test` 等以 `gachaTypes.length` 自動適配的 widget 測試）。

- [ ] **Step 8: Commit**

```bash
git add lib/data/gacha_types.dart test/data/gacha_types_test.dart test/services/overview_sections_test.dart test/state/gacha_repository_update_test.dart
git commit -m "feat(gacha): register collab convene pools (cardPoolType 10/11)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: 文件與註解一致性同步

**Files:**
- Modify: `docs/鳴潮相關資料.md`
- Modify: `lib/state/gacha_repository.dart`
- Modify: `lib/services/gacha_fetcher.dart`
- Modify: `test/models/banner_storage_test.dart`
- Modify: `test/services/five_star_collection_test.dart`
- Modify: `test/widgets/cards/banner_top_rarity_bars_test.dart`
- Modify: `test/widgets/share/share_card_test.dart`

純文字／註解同步——把專案內殘留、與「10／11 兩聯動池」矛盾的「8 種／8 個／`[1..9]`」說明一次補齊。無功能改動，全程測試保持綠。

- [ ] **Step 1: `docs/鳴潮相關資料.md` 內文三處**

- §二（迭代固定集合）：`逐一迭代固定集合 \`[1, 2, 3, 4, 5, 6, 8, 9]\`` → `逐一迭代固定集合 \`[1, 2, 3, 4, 5, 6, 8, 9, 10, 11]\``。
- §三 開頭：`以下 8 種型別` → `以下 10 種型別`；`合法集合為 \`[1, 2, 3, 4, 5, 6, 8, 9]\`，沒有 7。` → `合法集合為 \`[1, 2, 3, 4, 5, 6, 8, 9, 10, 11]\`，沒有 7。`
- §七 對照表：`值 \`[1,2,3,4,5,6,8,9]\`` → `值 \`[1,2,3,4,5,6,8,9,10,11]\``。

（術語表與 §三 卡池表的 10／11 兩列已先行存在，不需再動。）

- [ ] **Step 2: in-code 註解三處**

- `lib/state/gacha_repository.dart`：`/// 8 個卡池全部 \`code==0\` ...` → `/// 10 個卡池全部 \`code==0\` ...`；`/// 依序拉取 8 個 cardPoolType 的整池全歷史，合併存檔。` → `... 10 個 ...`。
- `lib/services/gacha_fetcher.dart`：`/// 兩次 API 呼叫之間的最短間隔（夾在 8 個 cardPoolType 之間，避免被擋）。` → `... 10 個 ...`。

- [ ] **Step 3: 測試內描述字串／註解（cosmetic，不影響綠燈）**

- `test/models/banner_storage_test.dart`：測試名 `toJson 落 ... 8 個 cardPoolType key` → `... 10 個 ...`；`banners` map 與期望 key set 各加 `'10': []`、`'11': []` 與 `'10'`、`'11'`（位置接在 `'9'` 之後）。
- `test/services/five_star_collection_test.dart`：測試名 `所有 8 池的 5★ 都納入` → `所有 10 池的 5★ 都納入`。
- `test/widgets/cards/banner_top_rarity_bars_test.dart`：註解 `鳴潮 8 池主稀有度皆 5★` → `鳴潮 10 池主稀有度皆 5★`。
- `test/widgets/share/share_card_test.dart`：註解 `綜合模式現為 8 池聚合單段` → `... 10 池聚合單段`。

- [ ] **Step 4: 格式化並全域驗證**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`
Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 5: 殘留掃描**

Run: `Select-String -Path lib,test,docs -Recurse -Pattern "8 個 cardPoolType|8 個卡池|\[1, ?2, ?3, ?4, ?5, ?6, ?8, ?9\]|以下 8 種"`
Expected: 僅 `docs/superpowers/`（歷史 spec／plan）內可能殘留，**`lib/`、`test/`、`docs/鳴潮相關資料.md`、`docs/術語表.md` 不應再有**與本次新增相矛盾的命中。

- [ ] **Step 6: Commit**

```bash
git add docs/鳴潮相關資料.md docs/術語表.md lib/state/gacha_repository.dart lib/services/gacha_fetcher.dart test/models/banner_storage_test.dart test/services/five_star_collection_test.dart test/widgets/cards/banner_top_rarity_bars_test.dart test/widgets/share/share_card_test.dart
git commit -m "docs: sync pool-count references to 10 convene pools

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> 註：`docs/術語表.md`、`docs/鳴潮相關資料.md` 的兩張表為使用者先前手動修改、尚未提交，於本 commit 一併納入。

---

## Self-Review

**Spec coverage（逐節對照）：**
- 註冊表加 type 10／11 + resolveName + dartdoc → Task 4 ✓
- i18n 四語系 4 key（含修正後 ja Short `共鳴者（コラボ）`／`武器（コラボ）`） → Task 1 ✓
- 圖示 `diversity_3`／`handshake`（outlined + filled） → Task 3 ✓
- 配色 洋紅 `#E5689E`/`#C23E7E` + 靛藍 `#6F6BE0`/`#4A46C2`（dark/light + colorFor） → Task 2 ✓
- 必改測試（gacha_types／overview_sections／gacha_repository_update） → Task 4 ✓
- cosmetic 測試（banner_colors → Task 2；banner_storage／five_star／widget 註解 → Task 5） ✓
- 文件內文 + in-code 註解一致性 → Task 5 ✓
- 範圍外（mitm/credential/fetcher 邏輯不動、無 50/50、聯動池恆顯示） → 已於 File Structure 與 Task 5 範圍說明標記 ✓

**Placeholder scan：** 無 TBD／TODO；每個 code step 皆附完整片段與 anchor。

**Type consistency：** 欄位名 `collabCharacter`／`collabWeapon`、i18n key `gachaTypeCollabCharacter[Short]`／`gachaTypeCollabWeapon[Short]`、nameKey 字串、`colorFor` 的 `'10'`／`'11'` 在各 Task 一致；`diversity_3`/`handshake` 的 outlined（Task 3 Step 1）與 filled（Task 3 Step 3）變體一致。

**順序正確性：** Task 1（getter）先於 Task 3（引用 `l.gachaTypeCollab*Short`）與 Task 4（引用 `l.gachaTypeCollab*`）；Task 2/3 的對照表先於 Task 4 註冊表長大，確保每個 commit 編譯綠、App 畫面正確、測試全綠。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-06-collab-convene-pools.md`. Two execution options:

**1. Subagent-Driven (recommended)** — 每個 Task 派新的 subagent、Task 間我來審查，迭代快。

**2. Inline Execution** — 在本 session 用 executing-plans 批次執行、設檢查點供審查。

Which approach?
