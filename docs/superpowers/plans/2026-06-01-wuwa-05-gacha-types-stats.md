# 05 Gacha Types / Pity / Stats / Item Kind Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 把卡池定義、保底、統計、類型分類、五星一覽、Overview 分段與時間軸從原神（7 型別 + 頌願 odes + 2★ + HoYoWiki menu_id）改造為鳴潮（8 型別 cardPoolType、保底 80/50/10、resourceType 三類含道具、無 odes、無 2★、無唯一 id），並同步 ARB 結構（移除 odes/集錄 key、新增 8 卡池 nameKey 四語、新增 kindItem）。

**Architecture:** `gacha_types.dart` 改持 `int cardPoolType`（key getter 轉 String）、移除 `GachaCategory`；統計/類型/五星/Overview/時間軸全部移除 odes 與 2★、改吃 `GachaRecord` 新欄位（`resourceId`/`qualityLevel`/`resourceType`/`cardPoolType`）；類型分類改用 record 自帶 `resourceType` 直接映射 canonical kind（含道具），不再依賴 HoYoWiki index；時間軸 `pullsSinceLastRankedAcrossBanners` 因無唯一 id 改用清單索引定位 + 同秒穩定 tie-break。

**Tech Stack:** Flutter / Dart、flutter gen-l10n（4 ARB：app_zh / app_zh_Hans / app_en / app_ja）、flutter_test、Logger（package:logging）。

**前置依賴：** 本 plan 依賴 plan 03（`lib/models/gacha_record.dart` 重寫後的 `GachaRecord`：欄位 `resourceId(int)` / `qualityLevel(int)` / `resourceType(String)` / `cardPoolType(String)` / `name` / `count(int)` / `time(DateTime)`，已移除 `id`/`uid`/`gachaType`/`itemType`/`rankType`/`lang`）。本 plan 假設套件已由 plan 01 改名為 `wuthering_waves_convene_gacha_analyzer`，import 前綴一律 `package:wuthering_waves_convene_gacha_analyzer/`。

**注意（整體編譯短暫紅燈）：** 此遷移是一連串 plan。本 plan 觸及的型別（`GachaType.key`、移除 `GachaCategory`、`OverviewSections` 攤平單段化）在所有 plan 完成前，UI 層（`app_shell` / `overview_page` / `banner_page` / `share_card` 等，屬 plan 07）會有編譯錯誤。本 plan 的驗收以「**本 plan 觸及檔案 + 其單元測試**能編譯並通過」為準；`flutter analyze` 全庫綠燈延後到整體遷移收尾。每個 Task 的驗收指令會明確指出跑哪些測試檔。

> **本專案目錄非 git repo。** 每個 Task 末尾的 commit 步驟照寫；若執行者尚未 `git init`，略過該步驟即可。commit message 一律英文 conventional commits，**不 git push**。

---

## 依賴順序與跨 plan 介面契約

本 plan 的卡池統計、類型分類、五星一覽、Overview 分段全部只吃 `GachaRecord` 自帶欄位（`resourceId`／`qualityLevel`／`resourceType`／`cardPoolType`），**不查圖**，故本 plan 完全不碰圖片索引。圖片索引／判定（`item_image_index.dart`、`ItemImageEntry`、`hasItemImage(...)` 等）全歸 plan 06 交付，本 plan 不建立其骨架、也不定義任何 item_image 自由函式。

跨 plan 介面契約（本 plan 交付或用到的部分）：

- `lib/services/item_type_kind.dart`（本 plan 交付）：`const kItemKindItem = 'kind:item'`、`const kItemKindCharacter = 'kind:character'`、`const kItemKindWeapon = 'kind:weapon'`、`String itemTypeKeyOf(GachaRecord r)`（不再吃 index）。
- `lib/data/gacha_types.dart`（本 plan 交付）：`GachaType{ int cardPoolType; String get key => cardPoolType.toString(); String nameKey; List<PityRule> pities }`、`gachaTypes` = 8 筆 cardPoolType `[1,2,3,4,5,6,8,9]`（無 7），無 `GachaCategory`。
- `lib/models/gacha_record.dart`（plan 03 交付）：本 plan 所有測試與實作建構 `GachaRecord` 用其新欄位。

---

## Task 1：ARB 結構性變更（移除 odes/Chronicled、新增 8 卡池 nameKey 四語 + kindItem）、跑 gen-l10n

**Files:**
- Modify: `lib/l10n/app_zh.arb`（template；現況 `gachaTypeChronicled`/`gachaTypeStandard`/`gachaTypeOdesEvent`/`gachaTypeOdesStandard` 在第 41–45 行；`kindWeapon` 在第 110 行）
- Modify: `lib/l10n/app_zh_Hans.arb`（gachaType* 第 31–37 行；kind* 第 129–131 行）
- Modify: `lib/l10n/app_en.arb`（gachaType* 第 35–41 行；kind* 第 133–135 行）
- Modify: `lib/l10n/app_ja.arb`（gachaType* 第 35–41 行；kind* 第 133–135 行）
- Generated: `lib/l10n/generated/app_localizations*.dart`（gen-l10n 產生，勿手改）

> **執行順序（R16）：** 本 plan 的 8 卡池 nameKey ARB 與 `gacha_types.dart` 的 `resolveName`、`item_type_kind.dart` 的 `itemTypeKeyLabel` 都在本 plan 內，故**先把 ARB key 補齊 + 跑 gen-l10n（本 Task）**，後續 Task 2/3 即可直接引用生成 getter（`l.gachaTypeStandardCharacter`、`l.kindItem` 等），一次到位、不需任何臨時 `=> nameKey` fallback。
>
> 對齊術語表四語。本 Task 只動「8 卡池 nameKey + kindItem」這組結構性 key（本 plan 範圍）。`appName`／`navSectionGacha`／`progressOpenGameHint`／移除 `pityBeginnerEnded`／移除 `actionViewOnHoYoWiki` 等品牌與其他 UI 文案的 ARB 變更屬 plan 07（UI/i18n/品牌），不在此 Task。為避免 plan 間衝突，本 Task **僅替換 7 個舊 gachaType key → 8 個新 gachaType key，並在 kind 區塊新增 kindItem**，其餘 odes 相關 key（`navOdesEvent`/`navOdesStandard`/`navSectionOdes`/`emptyNoOdesRecords`/`pageOverviewOdesSection`）的移除留給 plan 07 處理（它們的移除會牽動 UI 層，集中在 UI/i18n plan 一次清掉較安全）。

### app_zh.arb（template，繁中）

- [ ] 替換 `lib/l10n/app_zh.arb` 第 39–45 行的 7 個 gachaType 行：

old：
```
  "gachaTypeCharacter": "角色活動祈願",
  "gachaTypeWeapon": "武器活動祈願",
  "gachaTypeChronicled": "集錄祈願",
  "gachaTypeStandard": "常駐祈願",
  "gachaTypeBeginner": "新手祈願",
  "gachaTypeOdesEvent": "活動頌願",
  "gachaTypeOdesStandard": "常駐頌願",
```
new：
```
  "gachaTypeCharacter": "角色活動喚取",
  "gachaTypeWeapon": "武器活動喚取",
  "gachaTypeStandardCharacter": "角色常駐喚取",
  "gachaTypeStandardWeapon": "武器常駐喚取",
  "gachaTypeBeginner": "新手喚取",
  "gachaTypeBeginnerChoice": "新手自選喚取",
  "gachaTypeNewVoyageCharacter": "角色新旅喚取",
  "gachaTypeNewVoyageWeapon": "武器新旅喚取",
```

- [ ] 在 `lib/l10n/app_zh.arb` 的 `"kindWeapon": "武器",`（第 110 行）後新增 `kindItem`：

old：
```
  "kindWeapon": "武器",
```
new：
```
  "kindWeapon": "武器",
  "kindItem": "道具",
```

### app_zh_Hans.arb（簡中）

- [ ] 替換 `lib/l10n/app_zh_Hans.arb` 第 31–37 行：

old：
```
  "gachaTypeCharacter": "角色活动祈愿",
  "gachaTypeWeapon": "武器活动祈愿",
  "gachaTypeChronicled": "集录祈愿",
  "gachaTypeStandard": "常驻祈愿",
  "gachaTypeBeginner": "新手祈愿",
  "gachaTypeOdesEvent": "活动颂愿",
  "gachaTypeOdesStandard": "常驻颂愿",
```
new：
```
  "gachaTypeCharacter": "角色活动唤取",
  "gachaTypeWeapon": "武器活动唤取",
  "gachaTypeStandardCharacter": "角色常驻唤取",
  "gachaTypeStandardWeapon": "武器常驻唤取",
  "gachaTypeBeginner": "新手唤取",
  "gachaTypeBeginnerChoice": "新手自选唤取",
  "gachaTypeNewVoyageCharacter": "角色新旅唤取",
  "gachaTypeNewVoyageWeapon": "武器新旅唤取",
```

- [ ] 在 `lib/l10n/app_zh_Hans.arb` 的 `"kindWeapon": "武器",`（第 131 行）後新增：

old：
```
  "kindWeapon": "武器",
```
new：
```
  "kindWeapon": "武器",
  "kindItem": "道具",
```

### app_en.arb（英文）

- [ ] 替換 `lib/l10n/app_en.arb` 第 35–41 行：

old：
```
  "gachaTypeCharacter": "Character Event Wish",
  "gachaTypeWeapon": "Weapon Event Wish",
  "gachaTypeChronicled": "Chronicled Wish",
  "gachaTypeStandard": "Standard Wish",
  "gachaTypeBeginner": "Novice Wishes",
  "gachaTypeOdesEvent": "Event Ode",
  "gachaTypeOdesStandard": "Standard Ode",
```
new：
```
  "gachaTypeCharacter": "Featured Resonator Convene",
  "gachaTypeWeapon": "Featured Weapon Convene",
  "gachaTypeStandardCharacter": "Standard Resonator Convene",
  "gachaTypeStandardWeapon": "Standard Weapon Convene",
  "gachaTypeBeginner": "Beginner Convene",
  "gachaTypeBeginnerChoice": "Beginner's Choice Convene",
  "gachaTypeNewVoyageCharacter": "New Voyage Resonator Convene",
  "gachaTypeNewVoyageWeapon": "New Voyage Weapon Convene",
```

- [ ] 在 `lib/l10n/app_en.arb` 的 `"kindWeapon": "Weapon",`（第 135 行）後新增：

old：
```
  "kindWeapon": "Weapon",
```
new：
```
  "kindWeapon": "Weapon",
  "kindItem": "Item",
```

### app_ja.arb（日文）

- [ ] 替換 `lib/l10n/app_ja.arb` 第 35–41 行：

old：
```
  "gachaTypeCharacter": "イベント祈願・キャラクター",
  "gachaTypeWeapon": "イベント祈願・武器",
  "gachaTypeChronicled": "集録祈願",
  "gachaTypeStandard": "通常祈願",
  "gachaTypeBeginner": "初心者向け祈願",
  "gachaTypeOdesEvent": "イベント星願",
  "gachaTypeOdesStandard": "通常星願",
```
new：
```
  "gachaTypeCharacter": "共鳴者集音（イベント）",
  "gachaTypeWeapon": "武器集音（イベント）",
  "gachaTypeStandardCharacter": "共鳴者集音（恒常）",
  "gachaTypeStandardWeapon": "武器集音（恒常）",
  "gachaTypeBeginner": "初心者集音",
  "gachaTypeBeginnerChoice": "初心者応援セレクト集音",
  "gachaTypeNewVoyageCharacter": "共鳴者集音（旅立ち）",
  "gachaTypeNewVoyageWeapon": "武器集音（旅立ち）",
```

- [ ] 在 `lib/l10n/app_ja.arb` 的 `"kindWeapon": "武器",`（第 135 行）後新增：

old：
```
  "kindWeapon": "武器",
```
new：
```
  "kindWeapon": "武器",
  "kindItem": "アイテム",
```

### 生成與驗證

- [ ] 跑 gen-l10n：`flutter gen-l10n`。預期：無錯誤輸出（warning 若提示 `gachaTypeChronicled` 等被移除的 key 在非 template locale 缺漏屬正常，因四檔已同步移除）。
- [ ] 確認生成檔含新 getter（供後續 Task 的 `resolveName`／`itemTypeKeyLabel` 直接引用，無需任何臨時 fallback）：`flutter analyze lib/l10n/generated`。預期：`No issues found!`（驗證 `l.kindItem`、`gachaTypeStandardCharacter` 等 getter 已生成）。
- [ ] commit：`feat(l10n): 8 wuwa convene name keys + kindItem across 4 ARBs, run gen-l10n`

---

## Task 2：重寫 `gacha_types.dart`（8 型別、int cardPoolType、key getter、保底 80/50/10、移除 GachaCategory）

**Files:**
- Modify: `lib/data/gacha_types.dart`（整檔重寫，現況 131 行）
- Test: `test/data/gacha_types_test.dart`（整檔重寫，現況 88 行）

- [ ] 重寫測試 `test/data/gacha_types_test.dart`（整檔取代）：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/data/gacha_types.dart';

void main() {
  group('gachaTypes registry', () {
    test('共 8 個 type，cardPoolType 為 [1,2,3,4,5,6,8,9]（無 7）', () {
      expect(gachaTypes.length, 8);
      expect(
        gachaTypes.map((t) => t.cardPoolType).toList(),
        [1, 2, 3, 4, 5, 6, 8, 9],
      );
    });

    test('key getter = cardPoolType.toString()', () {
      for (final t in gachaTypes) {
        expect(t.key, t.cardPoolType.toString());
      }
      expect(gachaTypes.firstWhere((t) => t.cardPoolType == 8).key, '8');
    });

    test('每個 type 都有 5★ 與 4★ 兩條 pity', () {
      for (final t in gachaTypes) {
        expect(t.pities, hasLength(2), reason: t.key);
        expect(t.primaryPity.rank, 5);
        expect(t.secondaryPity!.rank, 4);
      }
    });

    test('primaryPity 是 pities[0]、secondaryPity 是 pities[1]', () {
      for (final t in gachaTypes) {
        expect(t.primaryPity, same(t.pities.first));
        expect(t.secondaryPity, same(t.pities[1]));
      }
    });

    test('type 1/2/3/4/6/8/9 → 5★80 / 4★10', () {
      for (final cpt in [1, 2, 3, 4, 6, 8, 9]) {
        final t = gachaTypes.firstWhere((g) => g.cardPoolType == cpt);
        expect(t.primaryPity.threshold, 80, reason: 'type $cpt 5star');
        expect(t.secondaryPity!.threshold, 10, reason: 'type $cpt 4star');
      }
    });

    test('type 5（新手喚取）→ 5★50 / 4★10', () {
      final t = gachaTypes.firstWhere((g) => g.cardPoolType == 5);
      expect(t.primaryPity.threshold, 50);
      expect(t.secondaryPity!.threshold, 10);
    });

    test('nameKey 對齊 8 個鳴潮卡池 key', () {
      expect(gachaTypes.map((t) => t.nameKey).toList(), [
        'gachaTypeCharacter',
        'gachaTypeWeapon',
        'gachaTypeStandardCharacter',
        'gachaTypeStandardWeapon',
        'gachaTypeBeginner',
        'gachaTypeBeginnerChoice',
        'gachaTypeNewVoyageCharacter',
        'gachaTypeNewVoyageWeapon',
      ]);
    });
  });
}
```

- [ ] 跑驗證失敗：`flutter test test/data/gacha_types_test.dart`。預期：編譯失敗（`cardPoolType` / `key` getter 不存在、`gachaTypes.length` 為 7、`GachaCategory` 仍存在等）。

- [ ] 重寫 `lib/data/gacha_types.dart`（整檔取代）：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';

/// 保底規則：指定 rank 的抽數門檻。
class PityRule {
  /// 建立 [PityRule]。
  const PityRule({required this.rank, required this.threshold});

  /// 觸發保底的星級。
  final int rank;

  /// 觸發保底所需的抽數。
  final int threshold;
}

/// 卡池類型定義，含 API cardPoolType、名稱 i18n key 與保底規則。
class GachaType {
  /// 建立 [GachaType]。
  const GachaType({
    required this.cardPoolType,
    required this.nameKey,
    required this.pities,
  });

  /// 對應喚取記錄 API 的 `cardPoolType`（int，集合 [1,2,3,4,5,6,8,9]，無 7）。
  final int cardPoolType;

  /// 對外 key/route/map 用的字串（即 [cardPoolType] 的字串形式）。
  /// 轉換只發生於此 getter，禁止散落於各處硬轉（spec D4）。
  String get key => cardPoolType.toString();

  /// i18n key（透過 [resolveName] 取顯示字串）。
  final String nameKey;

  /// 由高 rank 到低 rank。[0] 為主保底（5★），[1] 為副保底（4★）。
  final List<PityRule> pities;

  /// 主保底（[pities] 第一條）。
  PityRule get primaryPity => pities.first;

  /// 副保底（若 [pities] 長度 > 1），否則 null。
  PityRule? get secondaryPity => pities.length > 1 ? pities[1] : null;

  /// 將 [nameKey] 對應到目前語言的顯示字串。
  String resolveName(AppLocalizations l) => switch (nameKey) {
    'gachaTypeCharacter' => l.gachaTypeCharacter,
    'gachaTypeWeapon' => l.gachaTypeWeapon,
    'gachaTypeStandardCharacter' => l.gachaTypeStandardCharacter,
    'gachaTypeStandardWeapon' => l.gachaTypeStandardWeapon,
    'gachaTypeBeginner' => l.gachaTypeBeginner,
    'gachaTypeBeginnerChoice' => l.gachaTypeBeginnerChoice,
    'gachaTypeNewVoyageCharacter' => l.gachaTypeNewVoyageCharacter,
    'gachaTypeNewVoyageWeapon' => l.gachaTypeNewVoyageWeapon,
    _ => nameKey,
  };
}

/// 五星保底 80 抽（角色／武器活動、常駐、新手自選、新旅）。
const _pityFive80 = PityRule(rank: 5, threshold: 80);

/// 五星保底 50 抽（新手喚取）。
const _pityFive50 = PityRule(rank: 5, threshold: 50);

/// 四星保底 10 抽（所有卡池統一）。
const _pityFour10 = PityRule(rank: 4, threshold: 10);

/// 全部支援的卡池類型定義，順序對應側欄顯示順序。
const gachaTypes = <GachaType>[
  GachaType(
    cardPoolType: 1,
    nameKey: 'gachaTypeCharacter',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 2,
    nameKey: 'gachaTypeWeapon',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 3,
    nameKey: 'gachaTypeStandardCharacter',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 4,
    nameKey: 'gachaTypeStandardWeapon',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 5,
    nameKey: 'gachaTypeBeginner',
    pities: [_pityFive50, _pityFour10],
  ),
  GachaType(
    cardPoolType: 6,
    nameKey: 'gachaTypeBeginnerChoice',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 8,
    nameKey: 'gachaTypeNewVoyageCharacter',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 9,
    nameKey: 'gachaTypeNewVoyageWeapon',
    pities: [_pityFive80, _pityFour10],
  ),
];
```

> 此檔 import 的 `app_localizations.dart` 的新 getter（`gachaTypeStandardCharacter` 等）已由 Task 1（ARB + gen-l10n）生成，故本 Task 的 `resolveName` 直接寫完整 switch、一次到位（R16），不需任何臨時 `=> nameKey` fallback。其單元測試 `gacha_types_test.dart` **不觸及 `resolveName`**，純驗 registry 結構。

- [ ] 跑驗證通過：`flutter test test/data/gacha_types_test.dart`。預期：`All tests passed!`。
- [ ] 格式化：`dart format lib/data/gacha_types.dart test/data/gacha_types_test.dart`。
- [ ] commit：`feat(gacha-types): rewrite to 8 wuwa card pool types with int cardPoolType`

---

## Task 3：`item_type_kind.dart` 改用 `resourceType` 映射 canonical kind（含道具、移除 index 依賴）

**Files:**
- Modify: `lib/services/item_type_kind.dart`（整檔重寫，現況 32 行）
- Test: `test/services/item_type_kind_test.dart`（整檔重寫，現況 92 行）

- [ ] 重寫測試 `test/services/item_type_kind_test.dart`（整檔取代）：

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

/// 建立測試用 [GachaRecord]；只需指定 [resourceType]。
GachaRecord _r({required String resourceType}) => GachaRecord(
  resourceId: 1211,
  qualityLevel: 5,
  resourceType: resourceType,
  cardPoolType: '1',
  name: 'x',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, 3),
);

void main() {
  group('itemTypeKeyOf（依 resourceType 映射 canonical kind）', () {
    test('zh-Hant 角色 → kind:character', () {
      expect(itemTypeKeyOf(_r(resourceType: '角色')), kItemKindCharacter);
    });

    test('zh-Hant 武器 → kind:weapon', () {
      expect(itemTypeKeyOf(_r(resourceType: '武器')), kItemKindWeapon);
    });

    test('zh-Hant 道具 → kind:item', () {
      expect(itemTypeKeyOf(_r(resourceType: '道具')), kItemKindItem);
    });

    test('zh-Hans 角色／武器／道具 → 對應 canonical kind', () {
      expect(itemTypeKeyOf(_r(resourceType: '角色')), kItemKindCharacter);
      expect(itemTypeKeyOf(_r(resourceType: '武器')), kItemKindWeapon);
      expect(itemTypeKeyOf(_r(resourceType: '道具')), kItemKindItem);
    });

    test('en Character／Weapon → 對應 canonical kind（跨語系合併）', () {
      expect(itemTypeKeyOf(_r(resourceType: 'Character')), kItemKindCharacter);
      expect(itemTypeKeyOf(_r(resourceType: 'Weapon')), kItemKindWeapon);
    });

    test('ja キャラクター／武器 → 對應 canonical kind', () {
      expect(itemTypeKeyOf(_r(resourceType: 'キャラクター')), kItemKindCharacter);
      expect(itemTypeKeyOf(_r(resourceType: '武器')), kItemKindWeapon);
    });

    test('未知字串 → fallback 原字串', () {
      expect(itemTypeKeyOf(_r(resourceType: 'Mystery')), 'Mystery');
    });

    test('空字串 → 回空字串', () {
      expect(itemTypeKeyOf(_r(resourceType: '')), '');
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

- [ ] 跑驗證失敗：`flutter test test/services/item_type_kind_test.dart`。預期：編譯失敗（`itemTypeKeyOf` 仍要求 `index` 參數、`kItemKindItem` 不存在、`l.kindItem` 不存在、`GachaRecord` 仍是舊欄位）。

- [ ] 重寫 `lib/services/item_type_kind.dart`（整檔取代）：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

/// 角色類型聚合鍵；以 `kind:` 前綴與遊戲原始 resourceType 字串（角色／Character…）
/// 區隔，永不碰撞。
const kItemKindCharacter = 'kind:character';

/// 武器類型聚合鍵；`kind:` 前綴的用意參見 [kItemKindCharacter]。
const kItemKindWeapon = 'kind:weapon';

/// 道具類型聚合鍵（鳴潮喚取的第三類；如保底墊的「塵雲旋臂」）。
const kItemKindItem = 'kind:item';

/// 各語系 `resourceType` 原始字串 → canonical kind 的對照表。
///
/// `resourceType` 由 API 回應提供、字串隨 `languageCode` 變化，故需涵蓋各語系
/// 文案（zh-Hant／zh-Hans／en／ja）。查無者由 [itemTypeKeyOf] fallback 原字串。
const _resourceTypeToKind = <String, String>{
  // 角色
  '角色': kItemKindCharacter,
  'Character': kItemKindCharacter,
  'キャラクター': kItemKindCharacter,
  // 武器
  '武器': kItemKindWeapon,
  'Weapon': kItemKindWeapon,
  // 道具
  '道具': kItemKindItem,
  'Item': kItemKindItem,
  'アイテム': kItemKindItem,
};

/// 解析單筆 [r] 的類型聚合鍵：依 API 給的 [GachaRecord.resourceType]（權威類型
/// 欄位）映射 canonical kind（角色／武器／道具），跨語系自然合併；查無時 fallback
/// 回原始 `resourceType` 字串（含空字串）。
///
/// 註：此處用 `resourceType` 是做「類型分類」，與「是否有圖」（spec D7，靠圖片
/// 索引抓取結果）是不同問題，兩者不可混用。
String itemTypeKeyOf(GachaRecord r) =>
    _resourceTypeToKind[r.resourceType] ?? r.resourceType;

/// 將 [key]（[itemTypeKeyOf] 產物）轉成顯示用在地化標籤：canonical 鍵套 [l]
/// 譯名、空字串顯示「未知」、其餘原始字串 fallback 原樣顯示。
String itemTypeKeyLabel(String key, AppLocalizations l) => switch (key) {
  kItemKindCharacter => l.kindCharacter,
  kItemKindWeapon => l.kindWeapon,
  kItemKindItem => l.kindItem,
  '' => l.kindUnknown,
  _ => key,
};
```

> 各語系 `resourceType` 的 en/ja 道具字串（`Item` / `アイテム`）為合理推定（spec §九 open item）。映射查無時 fallback 原字串，不會 crash；待實證後若官方字串不同，只需補對照表（單檔機械改）。
> `l.kindItem` getter 已由 Task 1（ARB + gen-l10n）生成，本 Task 直接引用即可，無需任何臨時 fallback。

- [ ] 跑驗證通過：`flutter test test/services/item_type_kind_test.dart`。預期：`All tests passed!`。
- [ ] 格式化：`dart format lib/services/item_type_kind.dart test/services/item_type_kind_test.dart`。
- [ ] commit：`feat(item-type-kind): map resourceType to canonical kind incl. item, drop index`

---

## Task 4：`gacha_stats.dart` 移除 2★ 與 HoYoWikiIndex 參數

**Files:**
- Modify: `lib/services/gacha_stats.dart`（整檔重寫，現況 106 行）
- Test: `test/services/gacha_stats_test.dart`（整檔重寫，現況 135 行）

- [ ] 重寫測試 `test/services/gacha_stats_test.dart`（整檔取代）：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_stats.dart';

GachaRecord _r({int rank = 5, String resourceType = '角色'}) => GachaRecord(
  resourceId: 1211,
  qualityLevel: rank,
  resourceType: resourceType,
  cardPoolType: '1',
  name: 'x',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, 3),
);

void main() {
  group('GachaStats', () {
    test('空 list 全 0', () {
      final s = computeGachaStats(const []);
      expect(s.total, 0);
      expect(s.fiveStarCount, 0);
      expect(s.byItemType, isEmpty);
      expect(s.fiveStarRate, 0.0);
    });

    test('混合 list 計數正確（只有 5/4/3，無 2★）', () {
      final records = [
        _r(rank: 5, resourceType: '角色'),
        _r(rank: 4, resourceType: '武器'),
        _r(rank: 4, resourceType: '角色'),
        _r(rank: 3, resourceType: '武器'),
        _r(rank: 3, resourceType: '武器'),
      ];
      final s = computeGachaStats(records);
      expect(s.total, 5);
      expect(s.fiveStarCount, 1);
      expect(s.fourStarCount, 2);
      expect(s.threeStarCount, 2);
      expect(s.fiveStarRate, closeTo(0.2, 1e-9));
    });

    test('byItemType 以 canonical kind 聚合（含道具）', () {
      final records = [
        _r(rank: 5, resourceType: '角色'),
        _r(rank: 4, resourceType: '角色'),
        _r(rank: 4, resourceType: '武器'),
        _r(rank: 4, resourceType: '道具'),
      ];
      final stats = computeGachaStats(records);
      expect(stats.byItemType, {
        'kind:character': 2,
        'kind:weapon': 1,
        'kind:item': 1,
      });
    });

    test('跨語系同類型以 canonical kind 合併，不分裂', () {
      final stats = computeGachaStats([
        _r(rank: 5, resourceType: '角色'),
        _r(rank: 5, resourceType: 'Character'),
        _r(rank: 5, resourceType: 'キャラクター'),
      ]);
      expect(stats.byItemType, {'kind:character': 3});
    });

    test('未知 resourceType fallback 原字串', () {
      final stats = computeGachaStats([_r(rank: 5, resourceType: 'Mystery')]);
      expect(stats.byItemType, {'Mystery': 1});
    });

    test('sortedItemTypes 依 count desc 排序', () {
      final records = <GachaRecord>[
        for (var i = 0; i < 5; i++) _r(resourceType: '武器'),
        for (var i = 0; i < 3; i++) _r(resourceType: '角色'),
        _r(resourceType: '道具'),
      ];
      final stats = computeGachaStats(records);
      expect(stats.sortedItemTypes().map((e) => e.key).toList(), [
        'kind:weapon',
        'kind:character',
        'kind:item',
      ]);
    });
  });
}
```

- [ ] 跑驗證失敗：`flutter test test/services/gacha_stats_test.dart`。預期：編譯失敗（`computeGachaStats` 仍要求 `index:` 參數、`GachaRecord` 舊欄位、`itemTypeKeyOf` 簽名已改）。

- [ ] 重寫 `lib/services/gacha_stats.dart`（整檔取代）：

```dart
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

/// 單一卡池的喚取統計摘要。
class GachaStats {
  /// 建立 [GachaStats]。
  const GachaStats({
    required this.total,
    required this.fiveStarCount,
    required this.fourStarCount,
    required this.threeStarCount,
    required this.byItemType,
  });

  /// 總抽數。
  final int total;

  /// 5★ 數量。
  final int fiveStarCount;

  /// 4★ 數量。
  final int fourStarCount;

  /// 3★ 數量。
  final int threeStarCount;

  /// 各物品類型的抽數，key = [itemTypeKeyOf] 產物（canonical 鍵如 `kind:character`／
  /// `kind:item`，或未知 resourceType 的 fallback 原始字串）。
  final Map<String, int> byItemType;

  /// 計算 [n] 在總抽數中的占比；總抽數為 0 時回傳 0.0。
  double _rate(int n) => total == 0 ? 0.0 : n / total;

  /// 5★ 出率。
  double get fiveStarRate => _rate(fiveStarCount);

  /// 4★ 出率。
  double get fourStarRate => _rate(fourStarCount);

  /// 3★ 出率。
  double get threeStarRate => _rate(threeStarCount);

  /// 依 count desc 排序的 entries（給 pie / legend 用）。
  List<MapEntry<String, int>> sortedItemTypes() {
    final list = byItemType.entries.toList();
    list.sort((a, b) => b.value.compareTo(a.value));
    return list;
  }
}

/// 喚取統計 logger。
final _log = Logger('gacha.stats');

/// 從 [records] 計算統計摘要；類型聚合改用 record 自帶的 `resourceType`
/// 直接映射（[itemTypeKeyOf]），消除跨語系分裂，不再依賴外部 index。
GachaStats computeGachaStats(List<GachaRecord> records) {
  var five = 0, four = 0, three = 0;
  var canonical = 0, fallback = 0;
  final byItemType = <String, int>{};
  for (final r in records) {
    switch (r.qualityLevel) {
      case 5:
        five++;
      case 4:
        four++;
      case 3:
        three++;
    }
    final key = itemTypeKeyOf(r);
    if (key == kItemKindCharacter ||
        key == kItemKindWeapon ||
        key == kItemKindItem) {
      canonical++;
    } else {
      fallback++;
    }
    byItemType[key] = (byItemType[key] ?? 0) + 1;
  }
  if (records.isNotEmpty) {
    _log.fine(
      'computeGachaStats: total=${records.length} '
      'canonicalKind=$canonical rawFallback=$fallback',
    );
  }
  return GachaStats(
    total: records.length,
    fiveStarCount: five,
    fourStarCount: four,
    threeStarCount: three,
    byItemType: byItemType,
  );
}
```

- [ ] 跑驗證通過：`flutter test test/services/gacha_stats_test.dart`。預期：`All tests passed!`。
- [ ] 格式化：`dart format lib/services/gacha_stats.dart test/services/gacha_stats_test.dart`。
- [ ] commit：`feat(gacha-stats): drop 2-star and HoYoWiki index, aggregate by resourceType kind`

---

## Task 5：`gacha_pity.dart` 改用 `qualityLevel`（確認道具計入保底）

**Files:**
- Modify: `lib/services/gacha_pity.dart`（現況 92 行；改 `r.rankType` → `r.qualityLevel`）
- Test: `test/services/gacha_pity_test.dart`（更新建構子、補道具計入測試）

> spec §D：`gacha_pity` 語意天然符合鳴潮，幾乎不改——僅把欄位名 `rankType` 改為 `qualityLevel`，並補一個「道具的 qualityLevel 計入保底」的測試。

- [ ] 先讀現有測試以保留既有 case 結構：`Read test/services/gacha_pity_test.dart`。

- [ ] 在 `test/services/gacha_pity_test.dart` 中，將所有 `GachaRecord` 建構改為新欄位（`resourceId`/`qualityLevel`/`resourceType`/`cardPoolType`/`name`/`count`/`time`），並把判斷星級的 `rankType:` 改為 `qualityLevel:`。新增以下測試（加入既有 `group('computePity', ...)` 內或檔末新 group）：

```dart
    test('resourceType=道具 的 qualityLevel 一樣計入保底命中', () {
      // desc by time：最新一筆是 4★ 道具，視為命中 rank 4。
      final records = [
        GachaRecord(
          resourceId: 21040084,
          qualityLevel: 4,
          resourceType: '道具',
          cardPoolType: '1',
          name: '塵雲旋臂',
          count: 1,
          time: DateTime(2026, 2, 7, 16, 19, 41),
        ),
        GachaRecord(
          resourceId: 21020023,
          qualityLevel: 3,
          resourceType: '武器',
          cardPoolType: '1',
          name: '源能迅刀·測貳',
          count: 1,
          time: DateTime(2026, 2, 7, 16, 19, 40),
        ),
      ];
      final p = computePity(records, threshold: 10, rank: 4);
      expect(p.hitCount, 1);
      expect(p.current, 0); // 最新一筆即命中 → 距上次命中 0 抽
    });
```

- [ ] 跑驗證失敗：`flutter test test/services/gacha_pity_test.dart`。預期：編譯失敗（`GachaRecord` 舊欄位 / `r.rankType`）。

- [ ] 修改 `lib/services/gacha_pity.dart` 第 56 行，把 `r.rankType == rank` 改為 `r.qualityLevel == rank`：

```dart
    if (r.qualityLevel == rank) {
```

- [ ] 跑驗證通過：`flutter test test/services/gacha_pity_test.dart`。預期：`All tests passed!`。
  - 註：`averageIntervalAcrossBanners` 的 `rankFor` 簽名仍為 `int Function(String gachaType)`，呼叫端傳入的是 `Map<String, List<GachaRecord>>` 的 key（即 `cardPoolType` 字串），語意不變、不需改。
- [ ] 格式化：`dart format lib/services/gacha_pity.dart test/services/gacha_pity_test.dart`。
- [ ] commit：`refactor(gacha-pity): use qualityLevel field, confirm item rarity counts toward pity`

---

## Task 6：`five_star_collection.dart` 移除 odes 排除、`_mergeKey` 改 resourceId

**Files:**
- Modify: `lib/services/five_star_collection.dart`（整檔重寫，現況 94 行）
- Test: `test/services/five_star_collection_test.dart`（整檔重寫，現況 195 行）

- [ ] 重寫測試 `test/services/five_star_collection_test.dart`（整檔取代）：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/five_star_collection.dart';

GachaRecord _r({
  required int resourceId,
  required int rank,
  required DateTime time,
  String cardPoolType = '1',
  String name = 'x',
  String resourceType = '角色',
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: rank,
  resourceType: resourceType,
  cardPoolType: cardPoolType,
  name: name,
  count: 1,
  time: time,
);

void main() {
  group('buildFiveStarCollection', () {
    test('empty records → empty list', () {
      expect(buildFiveStarCollection(const []), isEmpty);
    });

    test('只取 5★，排除 4★／3★', () {
      final records = [
        _r(resourceId: 1, rank: 5, name: 'A', time: DateTime(2025, 1, 1)),
        _r(resourceId: 2, rank: 4, name: 'B', time: DateTime(2025, 1, 2)),
        _r(resourceId: 3, rank: 3, name: 'C', time: DateTime(2025, 1, 3)),
      ];
      final result = buildFiveStarCollection(records);
      expect(result, hasLength(1));
      expect(result.single.representative.name, 'A');
      expect(result.single.count, 1);
    });

    test('同 resourceId 去重計數，代表 record 取最近一次', () {
      final records = [
        _r(resourceId: 1211, rank: 5, name: 'A', time: DateTime(2025, 1, 1)),
        _r(resourceId: 1211, rank: 5, name: 'A', time: DateTime(2025, 3, 1)),
        _r(resourceId: 1211, rank: 5, name: 'A', time: DateTime(2025, 2, 1)),
      ];
      final result = buildFiveStarCollection(records);
      expect(result, hasLength(1));
      expect(result.single.count, 3);
      expect(result.single.representative.time, DateTime(2025, 3, 1));
    });

    test('排序：次數降冪，同次數以最近時間降冪', () {
      final records = [
        _r(resourceId: 10, rank: 5, name: 'A', time: DateTime(2025, 1, 1)),
        _r(resourceId: 10, rank: 5, name: 'A', time: DateTime(2025, 1, 2)),
        _r(resourceId: 20, rank: 5, name: 'B', time: DateTime(2025, 5, 1)),
        _r(resourceId: 30, rank: 5, name: 'C', time: DateTime(2025, 4, 1)),
      ];
      final result = buildFiveStarCollection(records);
      expect(result.map((e) => e.representative.name).toList(), ['A', 'B', 'C']);
    });

    test('跨語系：同 resourceId 不同語系名稱合併為一', () {
      final records = [
        _r(
          resourceId: 1211,
          rank: 5,
          name: '達妮婭',
          time: DateTime(2025, 1, 1),
        ),
        _r(
          resourceId: 1211,
          rank: 5,
          name: 'Dania',
          time: DateTime(2025, 2, 1),
        ),
      ];
      final result = buildFiveStarCollection(records);
      expect(result, hasLength(1));
      expect(result.single.count, 2);
      expect(result.single.representative.name, 'Dania'); // 最近一筆
    });

    test('不同 resourceId 不誤併', () {
      final records = [
        _r(resourceId: 1, rank: 5, name: 'A', time: DateTime(2025, 1, 1)),
        _r(resourceId: 2, rank: 5, name: 'B', time: DateTime(2025, 2, 1)),
      ];
      expect(buildFiveStarCollection(records), hasLength(2));
    });

    test('不再排除任何卡池（所有 8 池的 5★ 都納入）', () {
      final records = [
        _r(
          resourceId: 1,
          rank: 5,
          name: '活動角色',
          cardPoolType: '1',
          time: DateTime(2025, 1, 1),
        ),
        _r(
          resourceId: 2,
          rank: 5,
          name: '新旅角色',
          cardPoolType: '8',
          time: DateTime(2025, 1, 2),
        ),
      ];
      expect(buildFiveStarCollection(records), hasLength(2));
    });
  });

  group('buildFiveStarCollectionAcrossBanners', () {
    test('同 resourceId 跨卡池合併、次數相加', () {
      final banners = {
        '1': [
          _r(resourceId: 1301, rank: 5, name: '某角', time: DateTime(2025, 1, 1)),
        ],
        '3': [
          _r(
            resourceId: 1301,
            rank: 5,
            name: '某角',
            cardPoolType: '3',
            time: DateTime(2025, 3, 1),
          ),
          _r(
            resourceId: 1301,
            rank: 5,
            name: '某角',
            cardPoolType: '3',
            time: DateTime(2025, 2, 1),
          ),
        ],
      };
      final result = buildFiveStarCollectionAcrossBanners(banners);
      expect(result, hasLength(1));
      expect(result.single.count, 3);
      expect(result.single.representative.time, DateTime(2025, 3, 1));
    });

    test('empty banners → empty list', () {
      expect(buildFiveStarCollectionAcrossBanners(const {}), isEmpty);
    });
  });
}
```

- [ ] 跑驗證失敗：`flutter test test/services/five_star_collection_test.dart`。預期：編譯失敗（`buildFiveStarCollection` 仍要求 `index:` 參數、`GachaRecord` 舊欄位、`HoYoWikiIndex` import 失效）。

- [ ] 重寫 `lib/services/five_star_collection.dart`（整檔取代）：

```dart
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

/// 五星一覽聚合的 logger。
final _log = Logger('gacha.fiveStar');

/// 五星一覽的單一條目：一個不重複的五星物品 + 其累計抽到次數。
@immutable
class FiveStarCollectionItem {
  /// 建立 [FiveStarCollectionItem]。
  const FiveStarCollectionItem({
    required this.representative,
    required this.count,
  });

  /// 該物品最近一次被抽到的紀錄；決定 icon 查找與 tooltip 顯示名稱。
  final GachaRecord representative;

  /// 該物品（同 resourceId）在來源中被抽到的總次數。
  final int count;
}

/// 內部累積桶：記住該合併鍵目前的代表 record（最近一次）與出現次數。
class _Bucket {
  /// 以首次遇到的 record 初始化，count 由呼叫端累加。
  _Bucket(this.representative) : count = 0;

  /// 目前該合併鍵最近一次的 record。
  GachaRecord representative;

  /// 出現次數。
  int count;
}

/// 計算合併鍵：以 [GachaRecord.resourceId] 為鍵（語言無關，跨語系自然合併）。
int _mergeKey(GachaRecord r) => r.resourceId;

/// 由單一 records 來源建構五星一覽：取所有 5★，依 resourceId 去重計數，
/// 依「次數降冪 → 最近抽到時間降冪」排序。鳴潮 8 池皆納入（無 odes 排除）。
List<FiveStarCollectionItem> buildFiveStarCollection(List<GachaRecord> records) {
  final buckets = <int, _Bucket>{};
  for (final r in records) {
    if (r.qualityLevel != 5) continue;
    final b = buckets.putIfAbsent(_mergeKey(r), () => _Bucket(r));
    b.count++;
    if (r.time.isAfter(b.representative.time)) {
      b.representative = r;
    }
  }
  final items = buckets.values
      .map(
        (b) => FiveStarCollectionItem(
          representative: b.representative,
          count: b.count,
        ),
      )
      .toList();
  items.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    if (byCount != 0) return byCount;
    return b.representative.time.compareTo(a.representative.time);
  });
  _log.info(
    'buildFiveStarCollection: ${items.length} unique five-star item(s)',
  );
  return items;
}

/// 跨卡池版：攤平所有卡池 records 後委派給 [buildFiveStarCollection]，
/// 同 resourceId 跨卡池累加。
List<FiveStarCollectionItem> buildFiveStarCollectionAcrossBanners(
  Map<String, List<GachaRecord>> banners,
) {
  final all = banners.values.expand((r) => r).toList(growable: false);
  return buildFiveStarCollection(all);
}
```

- [ ] 跑驗證通過：`flutter test test/services/five_star_collection_test.dart`。預期：`All tests passed!`。
- [ ] 格式化：`dart format lib/services/five_star_collection.dart test/services/five_star_collection_test.dart`。
- [ ] commit：`feat(five-star-collection): drop odes exclusion, merge by resourceId`

---

## Task 7：`overview_sections.dart` 刪 OdesSectionData、改單段、8 池套保底平均

**Files:**
- Modify: `lib/services/overview_sections.dart`（整檔重寫，現況 192 行）
- Test: `test/services/overview_sections_test.dart`（整檔重寫，現況 67 行）

> spec §D / P2：移除 `OdesSectionData`，並把 `OverviewSections` 設計成**扁平**（R8）——直接持有 `types`/`banners`/`stats`/`timeline`/`timelineRank`/`timelineNowPulls`/`fiveStarAvg`/`fourStarAvg` 欄位，**不再包 `GachaSectionData` wrapper、不再有 `.gacha` 中介層**。聚合全部 8 池（`activeBanners` key = cardPoolType 字串）。`fiveStarAvg`/`fourStarAvg` 對 8 池套用、`timelineRank=5`。plan 07 的 `share_card`／`overview_page` 直接用 `sec.stats`／`sec.banners`／`sec.timeline` 直取。

- [ ] 重寫測試 `test/services/overview_sections_test.dart`（整檔取代）：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/overview_sections.dart';

GachaRecord _r(String cpt, int rank, String name, DateTime t) => GachaRecord(
  resourceId: name.hashCode & 0xffff,
  qualityLevel: rank,
  resourceType: rank == 5 ? '角色' : '武器',
  cardPoolType: cpt,
  name: name,
  count: 1,
  time: t,
);

void main() {
  test('buildOverviewSections 聚合全部 8 池於單段、統計正確', () {
    final t = DateTime(2026, 5, 1, 10);
    final activeBanners = <String, List<GachaRecord>>{
      '1': [_r('1', 5, '達妮婭', t), _r('1', 3, '冷刃', t)],
      '8': [_r('8', 5, '新旅角色', t.add(const Duration(hours: 1)))],
    };

    final sections = buildOverviewSections(activeBanners);

    expect(sections.stats.total, 3);
    expect(sections.stats.fiveStarCount, 2);
    expect(sections.timeline.length, 2);
    expect(sections.timelineRank, 5);
  });

  test('buildOverviewSections 空輸入不拋例外、各欄位回傳零值', () {
    final sections = buildOverviewSections(const <String, List<GachaRecord>>{});

    expect(sections.stats.total, 0);
    expect(sections.fiveStarAvg, isNull);
    expect(sections.fourStarAvg, isNull);
    expect(sections.timeline, isEmpty);
    expect(sections.timelineNowPulls, 0);
  });

  test('types 含全部 8 個卡池', () {
    final sections = buildOverviewSections(const <String, List<GachaRecord>>{});
    expect(sections.types.map((t) => t.cardPoolType).toList(), [
      1,
      2,
      3,
      4,
      5,
      6,
      8,
      9,
    ]);
  });
}
```

- [ ] 跑驗證失敗：`flutter test test/services/overview_sections_test.dart`。預期：編譯失敗（`buildOverviewSections` 仍要求 `index:`、`OverviewSections` 仍是 `.gacha` 巢狀結構而非扁平欄位、`GachaCategory` 已移除）。

- [ ] 重寫 `lib/services/overview_sections.dart`（整檔取代）：

```dart
import 'package:flutter/foundation.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/data/gacha_types.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_pity.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_stats.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/timeline_entries.dart';

/// OverviewPage 與 ShareCard 共用的喚取彙整結果（鳴潮單段、無頌願）。
///
/// 扁平結構（R8）：直接持有全部 8 池的彙整欄位，無 `GachaSectionData` wrapper、
/// 無 `.gacha` 中介層。消費端（plan 07 的 `overview_page`／`share_card`）直接用
/// `sec.stats`／`sec.banners`／`sec.timeline` 直取。
@immutable
class OverviewSections {
  /// 建立 [OverviewSections]。
  const OverviewSections({
    required this.types,
    required this.banners,
    required this.stats,
    required this.timeline,
    required this.timelineRank,
    required this.timelineNowPulls,
    required this.fiveStarAvg,
    required this.fourStarAvg,
  });

  /// 包含的卡池類型清單（全部 8 池）。
  final List<GachaType> types;

  /// 各卡池的抽卡記錄，key 為 cardPoolType 字串。
  final Map<String, List<GachaRecord>> banners;

  /// 全部卡池合計統計。
  final GachaStats stats;

  /// 跨卡池合併的時間軸條目。
  final List<TimelineEntry> timeline;

  /// 時間軸目標星級（鳴潮所有卡池主保底皆 5★）。
  final int timelineRank;

  /// 距上次 timelineRank 出貨的累積抽數（供 TimelineVertical「現在」row 顯示）。
  final int timelineNowPulls;

  /// 5★ 平均間隔抽數；無出貨記錄時為 null。
  final double? fiveStarAvg;

  /// 4★ 平均間隔抽數；無出貨記錄時為 null。
  final double? fourStarAvg;
}

/// 從 [activeBanners]（key = cardPoolType 字串）建構 [OverviewSections]，供
/// OverviewPage 與 ShareCard 共用，避免兩處複製分組邏輯。
OverviewSections buildOverviewSections(
  Map<String, List<GachaRecord>> activeBanners,
) {
  final gachaList = gachaTypes.toList(growable: false);

  final gachaBanners = <String, List<GachaRecord>>{
    for (final t in gachaList)
      t.key: activeBanners[t.key] ?? const <GachaRecord>[],
  };
  final gachaAll = gachaBanners.values.expand((r) => r).toList(growable: false);

  final typesByKey = <String, GachaType>{for (final t in gachaList) t.key: t};
  final timelineRank = gachaList.first.primaryPity.rank;

  final timeline = buildTimelineEntriesAcrossBanners(
    gachaBanners,
    rankFor: (key) => typesByKey[key]!.primaryPity.rank,
  );
  final timelineNowPulls = pullsSinceLastRankedAcrossBanners(
    gachaBanners,
    rankFor: (key) => typesByKey[key]!.primaryPity.rank,
  );

  return OverviewSections(
    types: gachaList,
    banners: gachaBanners,
    stats: computeGachaStats(gachaAll),
    timeline: timeline,
    timelineRank: timelineRank,
    timelineNowPulls: timelineNowPulls,
    fiveStarAvg: averageIntervalAcrossBanners(gachaBanners, rankFor: (_) => 5),
    fourStarAvg: averageIntervalAcrossBanners(gachaBanners, rankFor: (_) => 4),
  );
}
```

- [ ] 跑驗證通過：`flutter test test/services/overview_sections_test.dart`。預期：`All tests passed!`。
- [ ] 格式化：`dart format lib/services/overview_sections.dart test/services/overview_sections_test.dart`。
- [ ] commit：`feat(overview-sections): single section over 8 pools, drop odes`

---

## Task 8：`timeline_entries.dart` 改用清單索引定位 + 同秒穩定 tie-break；`gacha_row.dart` 改 `qualityLevel` 與移除 index

**Files:**
- Modify: `lib/services/timeline_entries.dart`（現況 146 行；改 `r.rankType` → `r.qualityLevel`、`r.gachaType` → `r.cardPoolType`、`pullsSinceLastRankedAcrossBanners` 改清單索引）
- Modify: `lib/services/gacha_row.dart`（現況 66 行；移除 `HoYoWikiIndex` 參數、改 `qualityLevel`、`itemTypeKeyOf(r)`）
- Test: `test/services/timeline_entries_test.dart`（整檔重寫，現況 305 行）
- Test: `test/services/gacha_row_test.dart`（整檔重寫，現況 112 行）

> **核心修正（無唯一 id）：** `pullsSinceLastRankedAcrossBanners` 原靠 `r.id` 在同池內定位目標筆。鳴潮無唯一 id 且同十連同秒，改用**清單索引**（在該池記錄清單中的位置 index）定位該筆，計數其前面（desc 中排在前 = 抽得較晚）的筆數。`TimelineEntry.gachaType` 欄位語意改持 `cardPoolType` 字串（為降低跨 plan 改動面，欄位名沿用 `gachaType`，僅值改為 cardPoolType）。

- [ ] 重寫測試 `test/services/timeline_entries_test.dart`（整檔取代）：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/timeline_entries.dart';

GachaRecord _r({
  required String cpt,
  required int rank,
  required DateTime time,
  int resourceId = 1,
  String name = 'x',
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: rank,
  resourceType: '角色',
  cardPoolType: cpt,
  name: name,
  count: 1,
  time: time,
);

void main() {
  group('buildTimelineEntries', () {
    test('empty records → empty list', () {
      expect(buildTimelineEntries(const []), isEmpty);
    });

    test('records without 5★ → empty list', () {
      final records = [
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 1)),
        _r(cpt: '1', rank: 4, time: DateTime(2025, 1, 2)),
      ];
      expect(buildTimelineEntries(records.reversed.toList()), isEmpty);
    });

    test('computes pullsSincePrev counting from start', () {
      final asc = [
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 1)),
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 2)),
        _r(cpt: '1', rank: 5, name: 'A', time: DateTime(2025, 1, 3)),
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 4)),
        _r(cpt: '1', rank: 5, name: 'B', time: DateTime(2025, 1, 5)),
      ];
      final desc = asc.reversed.toList();
      final result = buildTimelineEntries(desc);
      expect(result, hasLength(2));
      expect(result[0].name, 'B');
      expect(result[0].pullsSincePrev, 2);
      expect(result[1].name, 'A');
      expect(result[1].pullsSincePrev, 3);
    });

    test('entry.gachaType 持 cardPoolType 字串', () {
      final records = [_r(cpt: '8', rank: 5, time: DateTime(2025, 1, 1))];
      final result = buildTimelineEntries(records);
      expect(result.single.gachaType, '8');
    });
  });

  group('buildTimelineEntriesAcrossBanners', () {
    test('merges multiple banners and sorts by time desc', () {
      final banners = {
        '1': [
          _r(cpt: '1', rank: 5, name: 'CharB', time: DateTime(2025, 3, 1)),
          _r(cpt: '1', rank: 5, name: 'CharA', time: DateTime(2025, 1, 1)),
        ],
        '2': [_r(cpt: '2', rank: 5, name: 'WepA', time: DateTime(2025, 2, 1))],
      };
      final result = buildTimelineEntriesAcrossBanners(
        banners,
        rankFor: (_) => 5,
      );
      expect(result.map((e) => e.name).toList(), ['CharB', 'WepA', 'CharA']);
    });

    test('per-pool pullsSincePrev preserved (not recomputed across pools)', () {
      final banners = {
        '1': [_r(cpt: '1', rank: 5, time: DateTime(2025, 2, 1))],
        '2': [_r(cpt: '2', rank: 5, time: DateTime(2025, 1, 1))],
      };
      final result = buildTimelineEntriesAcrossBanners(
        banners,
        rankFor: (_) => 5,
      );
      expect(result.every((e) => e.pullsSincePrev == 1), isTrue);
    });
  });

  group('pullsSinceLastRanked', () {
    test('no matching rank → returns total records count', () {
      final records = [
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 2)),
        _r(cpt: '1', rank: 4, time: DateTime(2025, 1, 1)),
      ];
      expect(pullsSinceLastRanked(records, rank: 5), 2);
    });

    test('counts records newer than latest matching rank', () {
      final records = [
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 3)),
        _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 2)),
        _r(cpt: '1', rank: 5, time: DateTime(2025, 1, 1)),
      ];
      expect(pullsSinceLastRanked(records, rank: 5), 2);
    });

    test('empty records → 0', () {
      expect(pullsSinceLastRanked(const [], rank: 5), 0);
    });
  });

  group('pullsSinceLastRankedAcrossBanners', () {
    test('counts across all pools after cross-pool latest 5★', () {
      final banners = {
        '1': [
          _r(cpt: '1', rank: 3, time: DateTime(2025, 3, 1)),
          _r(cpt: '1', rank: 5, time: DateTime(2025, 2, 1)),
          _r(cpt: '1', rank: 3, time: DateTime(2025, 1, 1)),
        ],
        '2': [_r(cpt: '2', rank: 5, time: DateTime(2025, 2, 15))],
      };
      expect(pullsSinceLastRankedAcrossBanners(banners, rankFor: (_) => 5), 1);
    });

    test('no matching rank anywhere → total cross-pool record count', () {
      final banners = {
        '1': [_r(cpt: '1', rank: 3, time: DateTime(2025, 1, 1))],
        '2': [
          _r(cpt: '2', rank: 4, time: DateTime(2025, 1, 1)),
          _r(cpt: '2', rank: 3, time: DateTime(2025, 1, 2)),
        ],
      };
      expect(pullsSinceLastRankedAcrossBanners(banners, rankFor: (_) => 5), 3);
    });

    test('empty banners → 0', () {
      expect(pullsSinceLastRankedAcrossBanners(const {}, rankFor: (_) => 5), 0);
    });

    test(
      'same-pool same-second: 用清單索引定位 5★，計其後（清單前段）抽數，無唯一 id 也正確',
      () {
        // 同一十連同秒：清單 desc 順序 r10..r1，5★ 是清單 index 5（第 6 筆）。
        // 其後（在清單前段、抽得較晚的）= index 0..4 共 5 筆。
        final sameSec = DateTime(2025, 4, 19, 14, 32, 0);
        final banners = {
          '1': [
            _r(cpt: '1', rank: 3, time: sameSec, resourceId: 31),
            _r(cpt: '1', rank: 3, time: sameSec, resourceId: 32),
            _r(cpt: '1', rank: 3, time: sameSec, resourceId: 33),
            _r(cpt: '1', rank: 4, time: sameSec, resourceId: 41),
            _r(cpt: '1', rank: 3, time: sameSec, resourceId: 34),
            _r(cpt: '1', rank: 5, time: sameSec, resourceId: 51, name: 'Five'),
            _r(cpt: '1', rank: 3, time: sameSec, resourceId: 35),
            _r(cpt: '1', rank: 3, time: sameSec, resourceId: 36),
            _r(cpt: '1', rank: 3, time: sameSec, resourceId: 37),
            _r(cpt: '1', rank: 3, time: sameSec, resourceId: 38),
          ],
        };
        expect(
          pullsSinceLastRankedAcrossBanners(banners, rankFor: (_) => 5),
          5,
        );
      },
    );

    test('跨池同秒穩定 tie-break：時間相同時取 cardPoolType 較大者為較新', () {
      // 兩池各一筆 5★ 同秒。tie-break：cardPoolType key 較大（'2' > '1'）視為較新。
      // 故定位到 '2' 池那筆；'2' 池其前 0 筆、'1' 池整段（time 不 isAfter）→ 0。
      final sameSec = DateTime(2025, 4, 19, 14, 32, 0);
      final banners = {
        '1': [_r(cpt: '1', rank: 5, time: sameSec, resourceId: 1)],
        '2': [_r(cpt: '2', rank: 5, time: sameSec, resourceId: 2)],
      };
      expect(pullsSinceLastRankedAcrossBanners(banners, rankFor: (_) => 5), 0);
    });
  });
}
```

- [ ] 跑驗證失敗：`flutter test test/services/timeline_entries_test.dart`。預期：編譯失敗（`GachaRecord` 舊欄位 / `r.id` 已不存在 / `r.rankType` / `r.gachaType`）。

- [ ] 修改 `lib/services/timeline_entries.dart`。第 44 行 `if (r.rankType == targetRank)` 改 `r.qualityLevel`；第 50 行 `gachaType: r.gachaType,` 改 `gachaType: r.cardPoolType,`：

```dart
  for (final r in asc) {
    pull++;
    if (r.qualityLevel == targetRank) {
      out.add(
        TimelineEntry(
          name: r.name,
          gachaType: r.cardPoolType,
          time: r.time,
          pullsSincePrev: pull,
          sourceRecord: r,
        ),
      );
      pull = 0;
    }
  }
```

- [ ] 修改 `lib/services/timeline_entries.dart` 的 `pullsSinceLastRanked`（第 81–88 行），把 `r.rankType` 改為 `r.qualityLevel`：

```dart
int pullsSinceLastRanked(List<GachaRecord> records, {required int rank}) {
  var count = 0;
  for (final r in records) {
    if (r.qualityLevel == rank) return count;
    count++;
  }
  return count;
}
```

- [ ] 重寫 `lib/services/timeline_entries.dart` 的 `pullsSinceLastRankedAcrossBanners`（第 90–146 行整段取代），改用清單索引定位 + 同秒 cardPoolType tie-break：

```dart
/// 跨卡池：找跨卡池最新「該卡池主稀有度」記錄，計算其後跨全部卡池 record 總數。
/// 每個卡池用 [rankFor] 決定主稀有度。
///
/// 鳴潮記錄無唯一 id 且同十連同秒，故同池內以**清單索引**（該筆在記錄清單中的
/// 位置）定位該 5★，計其前段（desc 排序中排在前 = 抽得較晚）的 record 數。
/// 跨池同秒以 cardPoolType key 字串比較做穩定 tie-break（較大者視為較新），
/// 避免「同秒」造成定位不穩定。
/// 若所有卡池皆無對應稀有度，回傳全部卡池 record 數總和。
int pullsSinceLastRankedAcrossBanners(
  Map<String, List<GachaRecord>> banners, {
  required int Function(String gachaType) rankFor,
}) {
  // Phase 1：找跨卡池最新的目標稀有度——記錄其所在池 key、在該池清單中的索引、時間。
  String? latestPool;
  int? latestIndex;
  DateTime? latestTime;
  for (final entry in banners.entries) {
    final rank = rankFor(entry.key);
    final records = entry.value;
    for (var i = 0; i < records.length; i++) {
      if (records[i].qualityLevel == rank) {
        // records 已 desc，該池第一筆目標稀有度即該池最新一筆。
        final isNewer =
            latestTime == null ||
            records[i].time.isAfter(latestTime) ||
            (records[i].time.isAtSameMomentAs(latestTime) &&
                entry.key.compareTo(latestPool!) > 0);
        if (isNewer) {
          latestTime = records[i].time;
          latestPool = entry.key;
          latestIndex = i;
        }
        break;
      }
    }
  }
  // 沒有任何符合稀有度：回傳跨卡池 record 總數。
  if (latestTime == null) {
    var total = 0;
    for (final records in banners.values) {
      total += records.length;
    }
    return total;
  }
  // Phase 2：計數。
  // - 目標稀有度所在卡池：清單索引前的筆數（desc 中 = 抽得較晚）即 [latestIndex]。
  // - 其他卡池：用 isAfter 嚴格比較（同秒以 tie-break 已歸屬到 latestPool，不重複算）。
  var count = latestIndex!;
  for (final entry in banners.entries) {
    if (entry.key == latestPool) continue;
    for (final r in entry.value) {
      if (r.time.isAfter(latestTime)) {
        count++;
      } else {
        break; // desc records，可以提早結束。
      }
    }
  }
  return count;
}
```

- [ ] 跑驗證通過：`flutter test test/services/timeline_entries_test.dart`。預期：`All tests passed!`。

- [ ] 重寫測試 `test/services/gacha_row_test.dart`（整檔取代）：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_row.dart';

GachaRecord _r({
  required int rank,
  required DateTime time,
  String resourceType = '角色',
  int resourceId = 1211,
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: rank,
  resourceType: resourceType,
  cardPoolType: '1',
  name: 'x',
  count: 1,
  time: time,
);

void main() {
  group('buildRecordRows', () {
    test('空 list → const []', () {
      expect(buildRecordRows(const []), isEmpty);
    });

    test('totalIndex 從 1 累計，最舊=1、最新=N，輸出順序與輸入一致 (desc by time)', () {
      final records = [
        for (var d = 5; d >= 1; d--) _r(rank: 3, time: DateTime(2025, 1, d)),
      ];
      final rows = buildRecordRows(records);
      expect(rows.map((r) => r.totalIndex).toList(), [5, 4, 3, 2, 1]);
      expect(rows.map((r) => r.record.time.day).toList(), [5, 4, 3, 2, 1]);
    });

    test('全無 5★ → mainPityIndex == totalIndex', () {
      final records = [
        _r(rank: 4, time: DateTime(2025, 1, 3)),
        _r(rank: 3, time: DateTime(2025, 1, 2)),
        _r(rank: 4, time: DateTime(2025, 1, 1)),
      ];
      final rows = buildRecordRows(records);
      expect(rows.map((r) => r.mainPityIndex).toList(), [3, 2, 1]);
    });

    test('5★ 那一抽 = 抵達該 5★ 的累積值，下一抽從 1 重新累計', () {
      // asc：1(3★) 2(3★) 3(5★) 4(3★) 5(5★) → pity asc 1,2,3,1,2
      final records = [
        _r(rank: 5, time: DateTime(2025, 1, 5)),
        _r(rank: 3, time: DateTime(2025, 1, 4)),
        _r(rank: 5, time: DateTime(2025, 1, 3)),
        _r(rank: 3, time: DateTime(2025, 1, 2)),
        _r(rank: 3, time: DateTime(2025, 1, 1)),
      ];
      final rows = buildRecordRows(records);
      final byDay = {for (final r in rows) r.record.time.day: r};
      expect(byDay[1]!.mainPityIndex, 1);
      expect(byDay[2]!.mainPityIndex, 2);
      expect(byDay[3]!.mainPityIndex, 3);
      expect(byDay[4]!.mainPityIndex, 1);
      expect(byDay[5]!.mainPityIndex, 2);
    });

    test('首抽即 5★ → 該抽 pity = 1', () {
      final rows = buildRecordRows([_r(rank: 5, time: DateTime(2025, 1, 1))]);
      expect(rows.first.totalIndex, 1);
      expect(rows.first.mainPityIndex, 1);
    });

    test('itemTypeKey 依 resourceType 映射 canonical（含道具）', () {
      final records = [
        _r(rank: 5, resourceType: '角色', time: DateTime(2025, 1, 3)),
        _r(rank: 4, resourceType: '武器', time: DateTime(2025, 1, 2)),
        _r(rank: 4, resourceType: '道具', time: DateTime(2025, 1, 1)),
      ];
      final rows = buildRecordRows(records);
      expect(rows[0].itemTypeKey, 'kind:character');
      expect(rows[1].itemTypeKey, 'kind:weapon');
      expect(rows[2].itemTypeKey, 'kind:item');
    });
  });
}
```

- [ ] 跑驗證失敗：`flutter test test/services/gacha_row_test.dart`。預期：編譯失敗（`buildRecordRows` 仍要求 `index:` 參數、`GachaRecord` 舊欄位）。

- [ ] 修改 `lib/services/gacha_row.dart`：移除 `hoyowiki_index` import、移除 `index` 參數、`r.rankType` → `r.qualityLevel`、`itemTypeKeyOf(r, index)` → `itemTypeKeyOf(r)`。整檔取代如下：

```dart
import 'package:flutter/foundation.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

/// 附帶計算後序號的喚取紀錄行（表格顯示用）。
@immutable
class RecordRow {
  /// 建立 [RecordRow]。
  const RecordRow({
    required this.record,
    required this.totalIndex,
    required this.mainPityIndex,
    required this.itemTypeKey,
  });

  /// 原始喚取紀錄。
  final GachaRecord record;

  /// 該抽在該卡池所有抽中的累積序號（asc）；最舊 = 1，最新 = N。
  final int totalIndex;

  /// 距上一個「主稀有度」紀錄後的第幾抽（含自己）。「主稀有度」由
  /// [buildRecordRows.mainRank] 決定（鳴潮所有卡池主稀有度皆 5★）。
  /// 該主稀有度那一抽 = 抵達該主稀有度的累積值；下一抽從 1 重新累計。
  /// 若該卡池從未出現符合主稀有度的紀錄，則持續累計，與 totalIndex 相同。
  final int mainPityIndex;

  /// 跨語言無關的類型聚合鍵（[itemTypeKeyOf] 產物：kind:character / kind:weapon
  /// ／kind:item／未知字串 fallback）。供表格類型欄顯示、排序、篩選共用。
  final String itemTypeKey;
}

/// records 必須以時間 desc 排序（與 gacha_repository 一致）。
/// 回傳順序與 records 相同（desc by time）。
/// [mainRank] 預設 5（鳴潮卡池主稀有度）。
List<RecordRow> buildRecordRows(List<GachaRecord> records, {int mainRank = 5}) {
  if (records.isEmpty) return const [];
  // 以 asc 順序累計再 reverse，保持輸出順序與輸入一致。
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
        itemTypeKey: itemTypeKeyOf(r),
      ),
    );
    if (r.qualityLevel == mainRank) {
      pity = 0;
    }
  }
  return out.reversed.toList(growable: false);
}
```

- [ ] 跑驗證通過：`flutter test test/services/gacha_row_test.dart`。預期：`All tests passed!`。
- [ ] 格式化：`dart format lib/services/timeline_entries.dart lib/services/gacha_row.dart test/services/timeline_entries_test.dart test/services/gacha_row_test.dart`。
- [ ] commit：`feat(timeline): list-index locate + same-second tie-break; gacha_row use qualityLevel`

---

## 收尾驗收（本 plan 範圍）

> 全庫 `flutter analyze` 綠燈須待整體遷移收尾（UI 層屬 plan 07）。本 plan 收尾只驗本 plan 觸及的測試檔全綠。

- [ ] 格式化本 plan 觸及檔：`dart format lib/data/gacha_types.dart lib/services/gacha_pity.dart lib/services/gacha_stats.dart lib/services/item_type_kind.dart lib/services/five_star_collection.dart lib/services/overview_sections.dart lib/services/timeline_entries.dart lib/services/gacha_row.dart test/data/gacha_types_test.dart test/services/gacha_pity_test.dart test/services/gacha_stats_test.dart test/services/item_type_kind_test.dart test/services/five_star_collection_test.dart test/services/overview_sections_test.dart test/services/timeline_entries_test.dart test/services/gacha_row_test.dart`。
- [ ] 跑本 plan 全部測試檔：

```
flutter test test/data/gacha_types_test.dart test/services/gacha_pity_test.dart test/services/gacha_stats_test.dart test/services/item_type_kind_test.dart test/services/five_star_collection_test.dart test/services/overview_sections_test.dart test/services/timeline_entries_test.dart test/services/gacha_row_test.dart
```

預期：`All tests passed!`。

- [ ] 確認本 plan 範圍內檔案的靜態分析（限定目錄，避開 plan 07 尚未改的 UI 紅燈）：`flutter analyze lib/data/gacha_types.dart lib/services/gacha_pity.dart lib/services/gacha_stats.dart lib/services/item_type_kind.dart lib/services/five_star_collection.dart lib/services/overview_sections.dart lib/services/timeline_entries.dart lib/services/gacha_row.dart`。預期：`No issues found!`（這些檔自身不應有 analyze 錯誤；若報的是來自其他 plan 尚未改的依賴檔，記錄為已知遷移中紅燈、不在本 plan 修）。

---

## 完成定義（DoD）

- [ ] `gacha_types.dart`：8 筆 `GachaType`、`cardPoolType` int `[1,2,3,4,5,6,8,9]`、`key` getter 回字串、保底 type5=`[5★50,4★10]` 其餘=`[5★80,4★10]`、無 `GachaCategory`、`resolveName` 對齊 8 個新 nameKey。
- [ ] `item_type_kind.dart`：`itemTypeKeyOf(r)` 依 `resourceType` 映射 `kind:character`/`kind:weapon`/`kind:item`、四語對照、未知 fallback 原字串、不再吃 index；`kItemKindItem` 已導出。
- [ ] `gacha_stats.dart`：無 `twoStarCount`/`twoStarRate`/`case 2`、無 `HoYoWikiIndex` 參數、`byItemType` 以 canonical kind 聚合。
- [ ] `gacha_pity.dart`：用 `qualityLevel` 計數，道具的 qualityLevel 計入保底（有測試佐證）。
- [ ] `five_star_collection.dart`：無 odes 排除、`_mergeKey` 用 `resourceId`、簽名移除 `index`。
- [ ] `overview_sections.dart`：無 `OdesSectionData`、無 `GachaSectionData` wrapper、`OverviewSections` 為扁平欄位（`types`/`banners`/`stats`/`timeline`/`timelineRank`/`timelineNowPulls`/`fiveStarAvg`/`fourStarAvg`，無 `.gacha` 中介層）、聚合 8 池、`fiveStarAvg`/`fourStarAvg`/`timelineRank=5`。
- [ ] `timeline_entries.dart`：`pullsSinceLastRankedAcrossBanners` 用清單索引定位（不用 `r.id`）+ 同秒 cardPoolType tie-break；`gacha_row.dart` 用 `qualityLevel`、`itemTypeKeyOf(r)`、移除 index。
- [ ] ARB 四檔：8 個新 gachaType nameKey + `kindItem` 已加、舊 `gachaTypeChronicled`/`gachaTypeStandard`/`gachaTypeOdesEvent`/`gachaTypeOdesStandard` 已移除，`flutter gen-l10n` 通過。
- [ ] 本 plan 不碰圖片索引：未建立 `item_image_index.dart` 骨架、未定義 `mergeItemImage`／`hasItemImageInIndex` 等自由函式（圖片索引／判定全歸 plan 06）。
- [ ] 本 plan 全部測試檔 `All tests passed!`。

---

以上為 plan 文件完整內容。供執行者參考的關鍵事實（已實際 Read/Grep 對照現況）：

- `lib/data/gacha_types.dart`（131 行）現持 `String gachaType` + `GachaCategory` enum + 7 筆，`resolveName` switch 在第 53–62 行；本 plan 改為 `int cardPoolType` + `key` getter + 8 筆、移除 `GachaCategory`。
- `lib/services/gacha_pity.dart` 唯一需改的是第 56 行 `r.rankType` → `r.qualityLevel`；`averageIntervalAcrossBanners` 的 `rankFor(String)` 簽名語意不變（傳入的是 banners map 的 cardPoolType key）。
- `lib/services/gacha_stats.dart`（106 行）需刪 `twoStarCount`/`twoStarRate`、`case 2`、`HoYoWikiIndex` 參數（第 4、67–69、74–83 行）。
- `lib/services/item_type_kind.dart`（32 行）現靠 `index.lookupMenuId`（2/4）；改為 `resourceType` 四語對照表 + `kItemKindItem`。
- `lib/services/five_star_collection.dart`（94 行）現有 `_odesGachaTypes` 排除（第 14–17、60 行）與 `_mergeKey` 用 `index.lookupId`（第 48–49 行）；改為無排除 + `resourceId` 鍵。
- `lib/services/overview_sections.dart`（192 行）現有 `OdesSectionData` 與 `gacha/odes` 雙段（第 50–101、180–189 行）；改為扁平單段 8 池（移除 `GachaSectionData` wrapper 與 `.gacha` 中介層，欄位直掛 `OverviewSections`）。
- `lib/services/timeline_entries.dart`（146 行）的 `pullsSinceLastRankedAcrossBanners`（第 95–146 行）現靠 `r.id` 定位（第 110、131 行）；無唯一 id，改用清單索引 + cardPoolType tie-break。
- ARB 對照位置（已確認行號）：app_zh 第 39–45/110；app_zh_Hans 第 31–37/129–131；app_en 第 35–41/133–135；app_ja 第 35–41/133–135。`l10n.yaml` template = `app_zh.arb`、output = `lib/l10n/generated/app_localizations.dart`。
- 既有 `*_test.dart` 全部用舊 `GachaRecord`（`id`/`uid`/`gachaType`/`itemType`/`rankType`/`lang`）+ `HoYoWikiIndex`，本 plan 各 Task 已給出整檔重寫版。