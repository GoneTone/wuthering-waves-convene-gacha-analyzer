# 憶旅喚取卡池（type 12／13）實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「角色憶旅喚取（cardPoolType 12）」與「武器憶旅喚取（cardPoolType 13）」完整接進 App（擷取、統計、側欄、分頁、配色、四語系），並同步所有「10 種卡池」的文件敘述。

**Architecture:** 本專案卡池為資料驅動——單一 `gachaTypes` 清單驅動擷取迭代、統計、側欄、分頁、配色。本次為純加法擴充：i18n 先行（程式碼依賴新 getter），再註冊表＋測試、圖示、配色，最後文件同步。攔截／擷取／儲存流程對 `cardPoolType` 參數化，新增清單項目即自動涵蓋，不動任何邏輯。

**Tech Stack:** Flutter（FVM 釘版）、flutter_localizations（gen-l10n）、flutter_test。

**Spec:** `docs/superpowers/specs/2026-07-09-reverb-convene-pools-design.md`

## Global Constraints

- 所有 Flutter／Dart 指令優先透過 `fvm` 執行（`fvm flutter …`／`fvm dart …`）。
- 每次 `git commit` 前依序通過：`fvm dart format lib/ test/`（不可對 `.` 跑）→ `fvm flutter analyze`（`No issues found!`）→ `fvm flutter test`（`All tests passed!`）。
- Commit message 用英文、conventional commits，結尾附：
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_011Z6PZB8i2Gm2at7dqVwhRm
  ```
- 繁中文件／註解用全形標點；省略號一律 ASCII `...`。
- **不要 git push**。
- 工作分支：`feat/reverb-convene-pools`（已建立）。
- 譯名單一來源：`docs/術語表.md`（憶旅兩列已存在，勿改）。

---

### Task 1: i18n — 四語系 ARB 加 4 個 key ＋ gen-l10n

**Files:**
- Modify: `lib/l10n/app_zh.arb`（template）
- Modify: `lib/l10n/app_zh_Hans.arb`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_ja.arb`

**Interfaces:**
- Produces: `AppLocalizations` 新 getter `gachaTypeReverbCharacter`、`gachaTypeReverbWeapon`、`gachaTypeReverbCharacterShort`、`gachaTypeReverbWeaponShort`（後續 Task 2、3 依賴）。

**注意：** 既有 `gachaType*` key 皆無 `@` description（見 `app_zh.arb:34-53`），新 key 照樣不加。只改核心四 ARB，`lib/l10n/generated/` 為 gitignore 產物、其他 Crowdin locale 勿動。

- [ ] **Step 1: `app_zh.arb` 加全名兩 key**

在 `"gachaTypeCollabWeapon": "武器聯動喚取",` 之後插入：

```json
  "gachaTypeReverbCharacter": "角色憶旅喚取",
  "gachaTypeReverbWeapon": "武器憶旅喚取",
```

- [ ] **Step 2: `app_zh.arb` 加短名兩 key**

在 `"gachaTypeCollabWeaponShort": "武器聯動",` 之後插入：

```json
  "gachaTypeReverbCharacterShort": "角色憶旅",
  "gachaTypeReverbWeaponShort": "武器憶旅",
```

- [ ] **Step 3: `app_zh_Hans.arb` 同位置插入**

在 `"gachaTypeCollabWeapon": "武器联动唤取",` 之後：

```json
  "gachaTypeReverbCharacter": "角色忆旅唤取",
  "gachaTypeReverbWeapon": "武器忆旅唤取",
```

在 `"gachaTypeCollabWeaponShort": "武器联动",` 之後：

```json
  "gachaTypeReverbCharacterShort": "角色忆旅",
  "gachaTypeReverbWeaponShort": "武器忆旅",
```

- [ ] **Step 4: `app_en.arb` 同位置插入**

在 `"gachaTypeCollabWeapon": "Collab Weapon Convene",` 之後：

```json
  "gachaTypeReverbCharacter": "Reverb Resonator Convene",
  "gachaTypeReverbWeapon": "Reverb Weapon Convene",
```

在 `"gachaTypeCollabWeaponShort": "Collab Weapon",` 之後：

```json
  "gachaTypeReverbCharacterShort": "Reverb Resonator",
  "gachaTypeReverbWeaponShort": "Reverb Weapon",
```

- [ ] **Step 5: `app_ja.arb` 同位置插入**

在 `"gachaTypeCollabWeapon": "武器集音（コラボ）",` 之後：

```json
  "gachaTypeReverbCharacter": "共鳴者集音（追憶）",
  "gachaTypeReverbWeapon": "武器集音（追憶）",
```

在 `"gachaTypeCollabWeaponShort": "武器（コラボ）",` 之後：

```json
  "gachaTypeReverbCharacterShort": "共鳴者（追憶）",
  "gachaTypeReverbWeaponShort": "武器（追憶）",
```

- [ ] **Step 6: 重產 l10n 並驗證 getter 存在**

Run: `fvm flutter gen-l10n`
Expected: 無錯誤結束。

Run: `grep -c "gachaTypeReverbCharacterShort" lib/l10n/generated/app_localizations.dart`
Expected: 輸出 ≥ 1（四個新 getter 已產生；`generated/` 不入版控，僅驗證）。

- [ ] **Step 7: 品質檢查後 commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze   # No issues found!
fvm flutter test      # All tests passed!
git add lib/l10n/app_zh.arb lib/l10n/app_zh_Hans.arb lib/l10n/app_en.arb lib/l10n/app_ja.arb
git commit -m "feat(i18n): add reverb convene pool names (type 12/13)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011Z6PZB8i2Gm2at7dqVwhRm"
```

---

### Task 2: 註冊表 — `gachaTypes` 加 type 12／13（TDD）

**Files:**
- Test: `test/data/gacha_types_test.dart`
- Test: `test/services/overview_sections_test.dart`
- Test: `test/state/gacha_repository_update_test.dart`
- Test: `test/models/banner_storage_test.dart`
- Modify: `lib/data/gacha_types.dart`

**Interfaces:**
- Consumes: Task 1 的 `l.gachaTypeReverbCharacter`／`l.gachaTypeReverbWeapon`。
- Produces: `gachaTypes` 尾端兩筆 `GachaType`（`cardPoolType: 12`／`13`，`nameKey: 'gachaTypeReverbCharacter'`／`'gachaTypeReverbWeapon'`，皆 5★80／4★10）。擷取、統計、側欄、儲存迭代自動涵蓋。

- [ ] **Step 1: 更新 `test/data/gacha_types_test.dart` 期望**

四處修改：

1. 第一個 test（`test/data/gacha_types_test.dart:6`）描述與期望：

```dart
    test('共 12 個 type，cardPoolType 為 [1,2,3,4,5,6,8,9,10,11,12,13]（無 7）', () {
      expect(gachaTypes.length, 12);
      expect(gachaTypes.map((t) => t.cardPoolType).toList(), [
        1,
        2,
        3,
        4,
        5,
        6,
        8,
        9,
        10,
        11,
        12,
        13,
      ]);
    });
```

2. 80/10 迴圈（`test/data/gacha_types_test.dart:44-45`）：

```dart
    test('type 1/2/3/4/6/8/9/10/11/12/13 → 5★80 / 4★10', () {
      for (final cpt in [1, 2, 3, 4, 6, 8, 9, 10, 11, 12, 13]) {
```

3. nameKey test（`test/data/gacha_types_test.dart:58`）描述改「12 個」、清單尾端加：

```dart
        'gachaTypeReverbCharacter',
        'gachaTypeReverbWeapon',
```

- [ ] **Step 2: 更新其餘三個測試檔期望**

1. `test/services/overview_sections_test.dart:65-82`：描述「types 含全部 12 個卡池」，期望清單 `11,` 之後加 `12,`、`13,`。
2. `test/state/gacha_repository_update_test.dart:77`：描述改 `'happy path: 12 pools fetched, stored, UpdateCompleted'`；`:102` 期望改 `expect(hitTypes, [1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13]);`（MockClient 對非 1 型別一律回 `_ok(const [])`＝`code: 0`，12／13 自動涵蓋，無需改 mock）。
3. `test/models/banner_storage_test.dart:26-59`：描述改「12 個 cardPoolType key」；banners map `'11': [],` 之後加 `'12': [], '13': [],`（各自成行）；期望 key set `'11',` 之後加 `'12', '13',`。

- [ ] **Step 3: 跑測試驗證失敗**

Run: `fvm flutter test test/data/gacha_types_test.dart test/services/overview_sections_test.dart test/state/gacha_repository_update_test.dart test/models/banner_storage_test.dart`
Expected: FAIL——`gacha_types_test`（length 10≠12）、`overview_sections_test`、`gacha_repository_update_test` 紅；`banner_storage_test` 綠（純測試資料，不依賴註冊表）。

- [ ] **Step 4: 實作 `lib/data/gacha_types.dart`**

1. `resolveName` switch（`lib/data/gacha_types.dart:53-54` 的 collab 兩 case 之後）加：

```dart
    'gachaTypeReverbCharacter' => l.gachaTypeReverbCharacter,
    'gachaTypeReverbWeapon' => l.gachaTypeReverbWeapon,
```

2. `gachaTypes` 清單尾端（type 11 之後）加：

```dart
  GachaType(
    cardPoolType: 12,
    nameKey: 'gachaTypeReverbCharacter',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 13,
    nameKey: 'gachaTypeReverbWeapon',
    pities: [_pityFive80, _pityFour10],
  ),
```

3. `cardPoolType` 欄位 dartdoc（`lib/data/gacha_types.dart:24`）改為：

```dart
  /// 對應喚取記錄 API 的 `cardPoolType`（int，集合 [1,2,3,4,5,6,8,9,10,11,12,13]，無 7）。
```

- [ ] **Step 5: 跑測試驗證通過**

Run: `fvm flutter test test/data/gacha_types_test.dart test/services/overview_sections_test.dart test/state/gacha_repository_update_test.dart test/models/banner_storage_test.dart`
Expected: PASS

- [ ] **Step 6: 品質檢查後 commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze   # No issues found!
fvm flutter test      # All tests passed!（banner_top_rarity_bars_test 以 gachaTypes.length 斷言，會自動適配）
git add lib/data/gacha_types.dart test/data/gacha_types_test.dart test/services/overview_sections_test.dart test/state/gacha_repository_update_test.dart test/models/banner_storage_test.dart
git commit -m "feat(gacha): register reverb convene pools (cardPoolType 12/13)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011Z6PZB8i2Gm2at7dqVwhRm"
```

---

### Task 3: 側欄圖示與短標籤

**Files:**
- Modify: `lib/widgets/gacha_type_icons.dart`
- Modify: `lib/pages/app_shell.dart`

**Interfaces:**
- Consumes: Task 1 的 `l.gachaTypeReverbCharacterShort`／`l.gachaTypeReverbWeaponShort`；Task 2 的 nameKey 字串。
- Produces: 無（switch 對照表為終端消費者）。

**注意：** 此區無既有單元測試（unknown key 有 casino fallback，不會紅），驗證靠 analyze 與 Task 6 的手動 smoke。

- [ ] **Step 1: `gacha_type_icons.dart` 加 outlined 兩 case**

在 `'gachaTypeCollabWeapon' => Icons.handshake_outlined,`（`lib/widgets/gacha_type_icons.dart:17`）之後加：

```dart
  'gachaTypeReverbCharacter' => Icons.auto_stories_outlined,
  'gachaTypeReverbWeapon' => Icons.history_edu_outlined,
```

- [ ] **Step 2: `app_shell.dart` 加 filled 圖示與短標籤**

`_railIconActive`（`lib/pages/app_shell.dart:535` 的 `'gachaTypeCollabWeapon' => Icons.handshake,` 之後）加：

```dart
  'gachaTypeReverbCharacter' => Icons.auto_stories,
  'gachaTypeReverbWeapon' => Icons.history_edu,
```

`_railLabel`（`lib/pages/app_shell.dart:517` 的 `'gachaTypeCollabWeapon' => l.gachaTypeCollabWeaponShort,` 之後）加：

```dart
  'gachaTypeReverbCharacter' => l.gachaTypeReverbCharacterShort,
  'gachaTypeReverbWeapon' => l.gachaTypeReverbWeaponShort,
```

- [ ] **Step 3: 品質檢查後 commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze   # No issues found!
fvm flutter test      # All tests passed!
git add lib/widgets/gacha_type_icons.dart lib/pages/app_shell.dart
git commit -m "feat(ui): add sidebar icons and labels for reverb convene pools

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011Z6PZB8i2Gm2at7dqVwhRm"
```

---

### Task 4: 時間軸配色（TDD）

**Files:**
- Test: `test/widgets/banner_colors_test.dart`
- Modify: `lib/widgets/banner_colors.dart`

**Interfaces:**
- Produces: `BannerColors` 新欄位 `reverbCharacter`／`reverbWeapon`；`colorFor('12')`／`colorFor('13')` 回傳對應色。

- [ ] **Step 1: 更新 `banner_colors_test.dart` 期望**

`test/widgets/banner_colors_test.dart:7-13` 改為：

```dart
  const keys = ['1', '2', '3', '4', '5', '6', '8', '9', '10', '11', '12', '13'];

  for (final b in [Brightness.dark, Brightness.light]) {
    test('colorFor 對 12 個 cardPoolType 皆有獨特色 ($b)', () {
      final c = BannerColors.of(b);
      final colors = keys.map(c.colorFor).toList();
      expect(colors.toSet(), hasLength(12), reason: '12 色不可重複');
```

（第二個 test 迭代 `keys`，自動涵蓋，無需改。）

- [ ] **Step 2: 跑測試驗證失敗**

Run: `fvm flutter test test/widgets/banner_colors_test.dart`
Expected: FAIL——`'12'`／`'13'` 皆回 fallback，`toSet()` 長度 11 ≠ 12。

- [ ] **Step 3: 實作 `banner_colors.dart`**

1. constructor（`collabWeapon` 之後、`fallback` 之前）加兩個必填參數：

```dart
    required this.reverbCharacter,
    required this.reverbWeapon,
```

2. `_dark` palette（`collabWeapon: Color(0xFF8266E0), // 靛藍` 之後）加：

```dart
    reverbCharacter: Color(0xFFE66EC6), // 洋紅
    reverbWeapon: Color(0xFFA08BC0), // 灰紫
```

3. `_light` palette（`collabWeapon: Color(0xFF5547C0), // 靛藍` 之後）加：

```dart
    reverbCharacter: Color(0xFFB93A96), // 洋紅
    reverbWeapon: Color(0xFF71589A), // 灰紫
```

4. 欄位宣告（`collabWeapon` 欄位之後）加：

```dart
  /// 角色憶旅喚取配色（cardPoolType 12）。
  final Color reverbCharacter;

  /// 武器憶旅喚取配色（cardPoolType 13）。
  final Color reverbWeapon;
```

5. `colorFor` switch（`'11' => collabWeapon,` 之後）加：

```dart
    '12' => reverbCharacter,
    '13' => reverbWeapon,
```

- [ ] **Step 4: 跑測試驗證通過**

Run: `fvm flutter test test/widgets/banner_colors_test.dart`
Expected: PASS（獨特性與歐非三色迴避皆由測試把關）。

- [ ] **Step 5: 品質檢查後 commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze   # No issues found!
fvm flutter test      # All tests passed!
git add lib/widgets/banner_colors.dart test/widgets/banner_colors_test.dart
git commit -m "feat(ui): add timeline colors for reverb convene pools

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011Z6PZB8i2Gm2at7dqVwhRm"
```

---

### Task 5: 文件與註解同步（10 → 12）

**Files:**
- Modify: `docs/鳴潮相關資料.md`
- Modify: `lib/state/gacha_repository.dart`（僅註解）
- Modify: `lib/services/gacha_fetcher.dart`（僅註解）
- Modify: `README.md`、`README_ZH-HANS.md`、`README_EN.md`、`README_JA-JP.md`

**Interfaces:** 無程式介面，純文字同步。

- [ ] **Step 1: `docs/鳴潮相關資料.md` 三處集合＋型別表**

1. §二（line 71）：`**逐一迭代固定集合 \`[1, 2, 3, 4, 5, 6, 8, 9, 10, 11]\`**` → `**逐一迭代固定集合 \`[1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13]\`**`。
2. §三（line 178）：`以下 10 種型別` → `以下 12 種型別`；`合法集合為 \`[1, 2, 3, 4, 5, 6, 8, 9, 10, 11]\`，沒有 7` → `合法集合為 \`[1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13]\`，沒有 7`。
3. §三表格（line 193 `| 11 | 武器聯動喚取 | 80 | 10 |` 之後）加兩列：

```markdown
| 12           | 角色憶旅喚取        | 80    | 10    |
| 13           | 武器憶旅喚取        | 80    | 10    |
```

4. §七（line 265）：`值 \`[1,2,3,4,5,6,8,9,10,11]\`` → `值 \`[1,2,3,4,5,6,8,9,10,11,12,13]\``。

- [ ] **Step 2: in-code 註解三處**

1. `lib/state/gacha_repository.dart:32`：`/// 10 個卡池全部 \`code==0\`` → `/// 12 個卡池全部 \`code==0\``。
2. `lib/state/gacha_repository.dart:387`：`/// 依序拉取 10 個 cardPoolType` → `/// 依序拉取 12 個 cardPoolType`。
3. `lib/services/gacha_fetcher.dart:42`：`（夾在 10 個 cardPoolType 之間，避免被擋）` → `（夾在 12 個 cardPoolType 之間，避免被擋）`。

- [ ] **Step 3: README ×4 的卡池清單行（各檔 line 46）**

1. `README.md`：

```markdown
- 涵蓋 12 種卡池：角色活動喚取、武器活動喚取、角色常駐喚取、武器常駐喚取、新手喚取、新手自選喚取、角色新旅喚取、武器新旅喚取、角色聯動喚取、武器聯動喚取、角色憶旅喚取、武器憶旅喚取
```

2. `README_ZH-HANS.md`：

```markdown
- 涵盖 12 种卡池：角色活动唤取、武器活动唤取、角色常驻唤取、武器常驻唤取、新手唤取、新手自选唤取、角色新旅唤取、武器新旅唤取、角色联动唤取、武器联动唤取、角色忆旅唤取、武器忆旅唤取
```

3. `README_EN.md`：

```markdown
- Covers all 12 convene types: Featured Resonator Convene, Featured Weapon Convene, Standard Resonator Convene, Standard Weapon Convene, Beginner Convene, Beginner's Choice Convene, New Voyage Resonator Convene, New Voyage Weapon Convene, Collab Resonator Convene, Collab Weapon Convene, Reverb Resonator Convene, Reverb Weapon Convene
```

4. `README_JA-JP.md`：

```markdown
- 12 種類の集音を網羅：共鳴者集音（イベント）、武器集音（イベント）、共鳴者集音（恒常）、武器集音（恒常）、初心者集音、初心者応援セレクト集音、共鳴者集音（旅立ち）、武器集音（旅立ち）、共鳴者集音（コラボ）、武器集音（コラボ）、共鳴者集音（追憶）、武器集音（追憶）
```

- [ ] **Step 4: 殘留掃描**

Run: `grep -rn "10 個卡池\|10 種卡池\|10 种卡池\|10 種類の集音\|10 convene types\|,10,11\]\|, 10, 11\]" lib/ test/ docs/ README*.md --include="*.dart" --include="*.md" | grep -v superpowers`
Expected: 無輸出（specs／plans 歷史文件除外，故排除 `superpowers` 目錄）。

- [ ] **Step 5: 品質檢查後 commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze   # No issues found!
fvm flutter test      # All tests passed!
git add docs/鳴潮相關資料.md lib/state/gacha_repository.dart lib/services/gacha_fetcher.dart README.md README_ZH-HANS.md README_EN.md README_JA-JP.md
git commit -m "docs: sync convene pool count to 12 across docs and READMEs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011Z6PZB8i2Gm2at7dqVwhRm"
```

---

### Task 6: 端到端驗證（手動 smoke）

**Files:** 無修改；驗證 spec 驗收條件 4。

- [ ] **Step 1: 全套 gate 最終確認**

Run: `fvm dart format lib/ test/ && fvm flutter analyze && fvm flutter test`
Expected: format 無變動、`No issues found!`、`All tests passed!`。

- [ ] **Step 2: 啟動 App 目視確認**

Run: `fvm flutter run -d windows`（不帶 cloud sync define，同步停用屬預期）
確認：

1. 側欄「武器聯動」之後出現「角色憶旅／武器憶旅」，未選中為 `auto_stories_outlined`／`history_edu_outlined`，選中變 filled。
2. 點入分頁，標題顯示「角色憶旅喚取」／「武器憶旅喚取」（無資料為預期，顯示空狀態即可）。
3. 設定頁切換語言（简中／EN／日文）抽查側欄短名與分頁標題譯名。
4. 深淺色模式下綜合頁時間軸圖例：洋紅（12）／灰紫（13）與既有 10 色、稀有度金／紫／藍目視可區分（新池無資料時，圖例可能不出現，屆時以側欄與分頁配色小點為準）。

- [ ] **Step 3: 回報結果**

向使用者回報 smoke 結果（含任何目視不符處），不自行 push；後續走 superpowers:finishing-a-development-branch 決定合併方式。
