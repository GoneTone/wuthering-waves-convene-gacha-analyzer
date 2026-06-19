# Timeline Luck-Color Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 時間軸節點與物品名稱改為依「抽數相對保底比例」呈現歐非色（綠/黃/紅），總覽頁以卡池色顯示卡池名稱保留辨識，並加上小圖例與 tooltip。（Task 1–7 為初版；Task 8–12 為同分支後續增強，把歐非色延伸到所有「抽數」呈現處、調整卡池調色盤避撞、分享圖加圖例、橫向時間軸加年/月區隔——供姐妹專案參考。）

**Architecture:** 新增純函式 `luckTierFor`／`luckColorFor`（`luck_palette.dart`）與在地化標籤＋圖例 widget（`luck_legend.dart`）；`gacha_types.dart` 新增集中查詢 helper `gachaTypeFor`／`pityThresholdFor`。兩個時間軸 widget 把節點/名稱顏色由卡池色換成歐非色；橫向圖例走 `ChartCard.legend`，直向用可選參數 `showLuckLegend`。後續把歐非色一致延伸到時間軸 meta 的「N 抽」與記錄列表「保底內」欄，並把卡池調色盤整體移出歐非色帶。

**Tech Stack:** Flutter／Dart、FVM 釘版、Riverpod、flutter gen-l10n（ARB i18n）。

## Global Constraints

- 回答與設計文件用繁體中文 (台灣)；CJK 全形標點，但**省略號一律用 ASCII `...`**。
- commit message／PR 標題用英文、conventional commits。
- 所有 Flutter／Dart 指令優先用 `fvm`（找不到才退回 `flutter`／`dart`）。
- 嚴禁重複造輪子：顏色重用既有 `GachaTokens.stateSuccess`／`stateWarning`／`stateDanger`，不新增 token；查詢集中到 `gachaTypeFor`／`pityThresholdFor`。
- 所有宣告（含 private）寫一行 `///` dartdoc（Flutter override 例外）。
- 純 UI 顏色呈現，不埋 log。
- 不改 `TimelineEntry` 資料模型；不新增設定選項。
- 提交前依序 `fvm dart format lib/ test/`、`fvm flutter analyze`（No issues found!）、`fvm flutter test`（All tests passed!）全綠；不要 `--no-verify`；不要主動 push。
- 分級門檻（具名常數，verbatim）：`ratio <= 0.5` 歐、`0.5 < ratio <= 0.8` 普通、`ratio > 0.8` 非；`ratio = pulls / pityThreshold`。
- 已在分支 `feat/timeline-luck-color`，spec 已 commit。

---

### Task 1: `gacha_types.dart` 集中查詢 helper

**Files:**
- Modify: `lib/data/gacha_types.dart`（檔案結尾、`gachaTypes` 常數之後新增 top-level 函式）
- Test: `test/data/gacha_types_test.dart`（既有檔，新增 group）

**Interfaces:**
- Produces:
  - `GachaType gachaTypeFor(String cardPoolType)` — 查 `gachaTypes`，查無回傳帶預設保底的 fallback。
  - `int pityThresholdFor(String cardPoolType, int rank)` — 回傳該池該 rank 的保底門檻；rank 無對應時回傳主保底門檻。

- [ ] **Step 1: 寫失敗測試**（在 `test/data/gacha_types_test.dart` 的 `void main() {` 內，既有 `group('gachaTypes registry', ...)` 之後新增）

```dart
  group('gachaTypeFor', () {
    test('已知 cardPoolType 回傳對應 GachaType', () {
      expect(gachaTypeFor('1').cardPoolType, 1);
      expect(gachaTypeFor('5').nameKey, 'gachaTypeBeginner');
    });

    test('未知 cardPoolType 回傳 fallback（5★80 / 4★10）', () {
      final t = gachaTypeFor('999');
      expect(t.cardPoolType, 999);
      expect(t.primaryPity.threshold, 80);
      expect(t.secondaryPity!.threshold, 10);
    });

    test('非數字 cardPoolType 的 fallback cardPoolType = 0', () {
      expect(gachaTypeFor('abc').cardPoolType, 0);
    });
  });

  group('pityThresholdFor', () {
    test('標準池 5★ → 80', () {
      expect(pityThresholdFor('1', 5), 80);
    });

    test('新手池 5★ → 50', () {
      expect(pityThresholdFor('5', 5), 50);
    });

    test('任一池 4★ → 10', () {
      expect(pityThresholdFor('1', 4), 10);
      expect(pityThresholdFor('5', 4), 10);
    });

    test('未知池 5★ → fallback 80', () {
      expect(pityThresholdFor('999', 5), 80);
    });

    test('rank 無對應 pity（3★）回傳主保底門檻', () {
      expect(pityThresholdFor('1', 3), 80);
      expect(pityThresholdFor('5', 3), 50);
    });
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/data/gacha_types_test.dart`
Expected: FAIL（`gachaTypeFor` / `pityThresholdFor` 未定義）

- [ ] **Step 3: 實作**（`lib/data/gacha_types.dart` 結尾，`gachaTypes` 常數之後新增）

```dart
/// 依 [cardPoolType] 字串查 [GachaType]；查無時回傳帶預設保底（5★80／4★10）
/// 的 fallback（[cardPoolType] 非數字時其 `cardPoolType` 欄為 0）。
GachaType gachaTypeFor(String cardPoolType) => gachaTypes.firstWhere(
  (t) => t.key == cardPoolType,
  orElse: () => GachaType(
    cardPoolType: int.tryParse(cardPoolType) ?? 0,
    nameKey: cardPoolType,
    pities: const [
      PityRule(rank: 5, threshold: 80),
      PityRule(rank: 4, threshold: 10),
    ],
  ),
);

/// 查 [cardPoolType] 池中 [rank] 的保底門檻；該池無對應 [rank] 的規則時，
/// 回傳主保底門檻當保守值。
int pityThresholdFor(String cardPoolType, int rank) {
  final type = gachaTypeFor(cardPoolType);
  for (final p in type.pities) {
    if (p.rank == rank) return p.threshold;
  }
  return type.primaryPity.threshold;
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/data/gacha_types_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/data/gacha_types.dart test/data/gacha_types_test.dart
git commit -m "feat(gacha-types): add gachaTypeFor/pityThresholdFor lookup helpers"
```

---

### Task 2: `luck_palette.dart` 歐非分級純函式

**Files:**
- Create: `lib/widgets/luck_palette.dart`
- Test: `test/widgets/luck_palette_test.dart`

**Interfaces:**
- Produces:
  - `enum LuckTier { lucky, average, unlucky }`
  - `LuckTier luckTierFor(int pulls, int pityThreshold)`
  - `Color luckColorFor(LuckTier tier, GachaTokens t)`

- [ ] **Step 1: 寫失敗測試**（`test/widgets/luck_palette_test.dart`）

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/luck_palette.dart';

void main() {
  group('luckTierFor — 80 池', () {
    test('40 抽（ratio 0.5）= 歐', () {
      expect(luckTierFor(40, 80), LuckTier.lucky);
    });
    test('41 抽 = 普通', () {
      expect(luckTierFor(41, 80), LuckTier.average);
    });
    test('64 抽（ratio 0.8）= 普通', () {
      expect(luckTierFor(64, 80), LuckTier.average);
    });
    test('65 抽 = 非', () {
      expect(luckTierFor(65, 80), LuckTier.unlucky);
    });
    test('80 抽 = 非', () {
      expect(luckTierFor(80, 80), LuckTier.unlucky);
    });
    test('81 抽（ratio > 1）= 非', () {
      expect(luckTierFor(81, 80), LuckTier.unlucky);
    });
  });

  group('luckTierFor — 50 池', () {
    test('25 抽 = 歐', () => expect(luckTierFor(25, 50), LuckTier.lucky));
    test('26 抽 = 普通', () => expect(luckTierFor(26, 50), LuckTier.average));
    test('40 抽 = 普通', () => expect(luckTierFor(40, 50), LuckTier.average));
    test('41 抽 = 非', () => expect(luckTierFor(41, 50), LuckTier.unlucky));
  });

  group('luckTierFor — 10 池', () {
    test('5 抽 = 歐', () => expect(luckTierFor(5, 10), LuckTier.lucky));
    test('6 抽 = 普通', () => expect(luckTierFor(6, 10), LuckTier.average));
    test('8 抽 = 普通', () => expect(luckTierFor(8, 10), LuckTier.average));
    test('9 抽 = 非', () => expect(luckTierFor(9, 10), LuckTier.unlucky));
  });

  test('pityThreshold <= 0 防呆 = 非', () {
    expect(luckTierFor(1, 0), LuckTier.unlucky);
  });

  group('luckColorFor 對應既有語意色', () {
    const t = GachaTokens.dark;
    test('歐 → stateSuccess', () {
      expect(luckColorFor(LuckTier.lucky, t), t.stateSuccess);
    });
    test('普通 → stateWarning', () {
      expect(luckColorFor(LuckTier.average, t), t.stateWarning);
    });
    test('非 → stateDanger', () {
      expect(luckColorFor(LuckTier.unlucky, t), t.stateDanger);
    });
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/luck_palette_test.dart`
Expected: FAIL（`luck_palette.dart` 不存在）

- [ ] **Step 3: 實作**（`lib/widgets/luck_palette.dart`）

```dart
import 'package:flutter/material.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';

/// 歐非分級：依「抽到該筆所花抽數 / 該池保底門檻」的比例分三階。
enum LuckTier {
  /// 歐：半個保底內出貨。
  lucky,

  /// 普通。
  average,

  /// 非：進入軟保底區（接近硬保底）。
  unlucky,
}

/// 歐（綠）上界比例：抽數在保底的一半以內視為歐。
const double _luckyMaxRatio = 0.5;

/// 普通（黃）上界比例：超過此比例即進入軟保底區，視為非。
const double _averageMaxRatio = 0.8;

/// 依 [pulls] 相對 [pityThreshold] 的比例回傳分級。
/// `ratio <= 0.5` 歐；`<= 0.8` 普通；其餘（含 ratio > 1）非。
/// [pityThreshold] <= 0 時防呆視為非（避免除以零；正常資料不會發生）。
LuckTier luckTierFor(int pulls, int pityThreshold) {
  if (pityThreshold <= 0) return LuckTier.unlucky;
  final ratio = pulls / pityThreshold;
  if (ratio <= _luckyMaxRatio) return LuckTier.lucky;
  if (ratio <= _averageMaxRatio) return LuckTier.average;
  return LuckTier.unlucky;
}

/// 將分級映射到既有語意色（綠 / 金 / 紅），不新增 token。
Color luckColorFor(LuckTier tier, GachaTokens t) => switch (tier) {
  LuckTier.lucky => t.stateSuccess,
  LuckTier.average => t.stateWarning,
  LuckTier.unlucky => t.stateDanger,
};
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/luck_palette_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/luck_palette.dart test/widgets/luck_palette_test.dart
git commit -m "feat(luck-palette): add luck-tier classification and color mapping"
```

---

### Task 3: l10n 分級名稱字串

**Files:**
- Modify: `lib/l10n/app_zh.arb`（zh-Hant 模板）
- Modify: `lib/l10n/app_zh_Hans.arb`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_ja.arb`

**Interfaces:**
- Produces（gen-l10n 後）：`AppLocalizations` 上的 getter `luckTierLucky`、`luckTierAverage`、`luckTierUnlucky`（皆 `String`，無 placeholder）。

- [ ] **Step 1: 在 `lib/l10n/app_zh.arb` 的 `"timelineSinceLast"` 區塊之後新增**（純字串，無 placeholder，毋需 `@` metadata）

```json
  "luckTierLucky": "歐",
  "luckTierAverage": "普通",
  "luckTierUnlucky": "非",
```

- [ ] **Step 2: 在 `lib/l10n/app_zh_Hans.arb` 相同位置新增**

```json
  "luckTierLucky": "欧",
  "luckTierAverage": "普通",
  "luckTierUnlucky": "非",
```

- [ ] **Step 3: 在 `lib/l10n/app_en.arb` 相同位置新增**

```json
  "luckTierLucky": "Lucky",
  "luckTierAverage": "Average",
  "luckTierUnlucky": "Unlucky",
```

- [ ] **Step 4: 在 `lib/l10n/app_ja.arb` 相同位置新增**

```json
  "luckTierLucky": "強運",
  "luckTierAverage": "普通",
  "luckTierUnlucky": "不運",
```

> 注意：每個檔案上一個 entry 結尾需有逗號、JSON 仍合法（新 entry 後若非最後一項要保留逗號）。

- [ ] **Step 5: 重新產生 l10n 並驗證**

Run: `fvm flutter gen-l10n && fvm flutter analyze`
Expected: gen-l10n 無錯、`analyze` 仍 `No issues found!`（generated 為 gitignore，不需 add）

- [ ] **Step 6: Commit**

```bash
git add lib/l10n/app_zh.arb lib/l10n/app_zh_Hans.arb lib/l10n/app_en.arb lib/l10n/app_ja.arb
git commit -m "feat(l10n): add luck tier labels (lucky/average/unlucky)"
```

---

### Task 4: `luck_legend.dart` 圖例 widget 與在地化標籤

**Files:**
- Create: `lib/widgets/luck_legend.dart`
- Test: `test/widgets/luck_legend_test.dart`

**Interfaces:**
- Consumes: `LuckTier`、`luckColorFor`（Task 2）；`luckTierLucky/Average/Unlucky`（Task 3）。
- Produces:
  - `String luckTierLabel(LuckTier tier, AppLocalizations l)` — 分級 → 在地化標籤（供 tooltip 與圖例共用）。
  - `class LuckLegend extends StatelessWidget`（const 建構子，無參數）。

- [ ] **Step 1: 寫失敗測試**（`test/widgets/luck_legend_test.dart`）

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/luck_legend.dart';

void main() {
  testWidgets('LuckLegend 顯示三個分級標籤', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: LuckLegend()),
      ),
    );
    final l = AppLocalizations.of(
      tester.element(find.byType(LuckLegend)),
    )!;
    expect(find.text(l.luckTierLucky), findsOneWidget);
    expect(find.text(l.luckTierAverage), findsOneWidget);
    expect(find.text(l.luckTierUnlucky), findsOneWidget);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/luck_legend_test.dart`
Expected: FAIL（`luck_legend.dart` 不存在）

- [ ] **Step 3: 實作**（`lib/widgets/luck_legend.dart`）

```dart
import 'package:flutter/material.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/luck_palette.dart';

/// 將歐非分級對應到目前語言的標籤（供 tooltip 與 [LuckLegend] 共用）。
String luckTierLabel(LuckTier tier, AppLocalizations l) => switch (tier) {
  LuckTier.lucky => l.luckTierLucky,
  LuckTier.average => l.luckTierAverage,
  LuckTier.unlucky => l.luckTierUnlucky,
};

/// 時間軸歐非色圖例：歐／普通／非 三個色點＋標籤，低視窗寬度可換行。
/// 刻意不標抽數——跨池保底門檻不同，標數字會誤導。
class LuckLegend extends StatelessWidget {
  /// 建立 [LuckLegend]。
  const LuckLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.gacha;
    final l = AppLocalizations.of(context)!;
    return Wrap(
      spacing: AppSpacing.l,
      runSpacing: AppSpacing.xs,
      children: [
        for (final tier in LuckTier.values)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: luckColorFor(tier, tokens),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                luckTierLabel(tier, l),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.textSecondary,
                ),
              ),
            ],
          ),
      ],
    );
  }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/luck_legend_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/luck_legend.dart test/widgets/luck_legend_test.dart
git commit -m "feat(luck-legend): add luck color legend widget + tier label helper"
```

---

### Task 5: 橫向時間軸改歐非色 + banner_page 圖例

**Files:**
- Modify: `lib/widgets/cards/timeline_horizontal.dart`
- Modify: `lib/pages/banner_page.dart:262-273`（`ChartCard` + `TimelineHorizontal` 呼叫）
- Test: `test/widgets/cards/timeline_horizontal_test.dart`

**Interfaces:**
- Consumes: `pityThresholdFor`（T1）、`luckTierFor`／`luckColorFor`（T2）、`luckTierLabel`／`LuckLegend`（T4）。
- Produces: `TimelineHorizontal` 移除 `colors` 必填參數；節點/名稱改歐非色；節點 tooltip 含分級＋抽數。`_EntryColumn` 改持有 `targetRank`、不再持有 `colors`。

> **為何同一任務改 widget＋page＋test：** 移除 `colors` 參數會破壞 `banner_page` 與測試的編譯，必須同批改才能維持每個任務結束時可編譯／測試。

- [ ] **Step 1: 改寫橫向 widget**（`lib/widgets/cards/timeline_horizontal.dart`）

在檔頭 import 區加入：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/data/gacha_types.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/luck_legend.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/luck_palette.dart';
```

（`banner_colors.dart` import 與 `colors` 欄位若移除後不再使用則一併刪除；`bannerDistributionEntries` 仍保留其自身 `colors` 參數，不動。）

`TimelineHorizontal` 建構子與欄位：移除 `required this.colors` 與 `final BannerColors colors;`（連同其 dartdoc）。

build() 內 `for (final entry in widget.entries)` 的 `_EntryColumn` 呼叫改為：

```dart
                    for (final entry in widget.entries)
                      _EntryColumn(
                        entry: entry,
                        targetRank: widget.targetRank,
                        tokens: tokens,
                      ),
```

`_EntryColumn` 改寫：移除 `colors` 欄位與其 dartdoc，新增 `targetRank`：

```dart
/// 時間軸中單一高稀有度紀錄的直欄（名稱 / 節點 / 日期+抽數）。
class _EntryColumn extends StatelessWidget {
  const _EntryColumn({
    required this.entry,
    required this.targetRank,
    required this.tokens,
  });

  /// 該欄對應的時間軸條目。
  final TimelineEntry entry;

  /// 該卡池萃取的稀有度（5 或 4），用於查保底門檻。
  final int targetRank;

  /// 主題 token。
  final GachaTokens tokens;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final rank = entry.sourceRecord?.qualityLevel ?? targetRank;
    final pity = pityThresholdFor(entry.gachaType, rank);
    final tier = luckTierFor(entry.pullsSincePrev, pity);
    final luck = luckColorFor(tier, tokens);
    return Tooltip(
      message:
          '${entry.name} · ${luckTierLabel(tier, l)} · '
          '${l.timelineSinceLast(entry.pullsSincePrev)}',
      preferBelow: false,
      waitDuration: const Duration(milliseconds: 100),
      child: SizedBox(
        width: _colWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (entry.sourceRecord != null)
              GachaItemTapTarget(
                record: entry.sourceRecord!,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    GachaItemIcon(record: entry.sourceRecord!, size: 32),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: luck,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              )
            else
              Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: luck,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            const SizedBox(height: AppSpacing.xs),
            TimelineNode(color: luck, tokens: tokens),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${formatShortMonthDay(entry.time)} · ${l.timelineSinceLast(entry.pullsSincePrev)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: tokens.textMuted,
                fontSize: 10,
                fontFeatures: kTabularFigures,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: 改 banner_page 呼叫端**（`lib/pages/banner_page.dart:262-273`）

移除 `colors:` 參數，並在 `ChartCard` 加 `legend`：

```dart
                    child: ChartCard(
                      title: l.timelineTopRarityTitle(
                        l.rarityStar(primary.rank),
                        _countAtRank(stats, primary.rank),
                      ),
                      icon: Icons.timeline,
                      legend: const LuckLegend(),
                      chart: TimelineHorizontal(
                        entries: buildTimelineEntries(
                          records,
                          targetRank: primary.rank,
                        ),
                        targetRank: primary.rank,
                        nowPulls: pullsSinceLastRanked(
                          records,
                          rank: primary.rank,
                        ),
                      ),
                    ),
```

在 `banner_page.dart` 檔頭 import 區加入（若尚無）：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/luck_legend.dart';
```

（若 `BannerColors` 在 banner_page 其他處仍有用則保留其 import；僅此處不再傳 colors。）

- [ ] **Step 3: 更新橫向測試**（`test/widgets/cards/timeline_horizontal_test.dart`）

3a. 移除每一處 `TimelineHorizontal(...)` 呼叫中的 `colors: colors,` 引數（共多處；`_wrap` 的 builder 簽名 `(ctx, colors)` 維持不變，`colors` 區域變數未用不影響 analyze）。範例（第 64-79 行的 `renders one column per entry`）改為：

```dart
        (ctx, colors) => TimelineHorizontal(
          entries: [
            _e('夜蘭', '301', 87, DateTime(2025, 4, 1)),
            _e('流浪者', '301', 74, DateTime(2025, 3, 1)),
          ],
          targetRank: 5,
        ),
```

3b. 在 `void main() {` 內新增歐非色斷言（gachaType `'1'` = 80 池）：

```dart
  testWidgets('歐非色：40 抽名稱為 stateSuccess、70 抽為 stateDanger', (tester) async {
    await tester.pumpWidget(
      _wrap(
        (ctx, colors) => TimelineHorizontal(
          entries: [
            _e('歐神', '1', 40, DateTime(2025, 4, 1)),
            _e('非酋', '1', 70, DateTime(2025, 3, 1)),
          ],
          targetRank: 5,
        ),
      ),
    );
    Color nameColor(String name) =>
        tester.widget<Text>(find.text(name)).style!.color!;
    const t = GachaTokens.dark;
    expect(nameColor('歐神'), t.stateSuccess);
    expect(nameColor('非酋'), t.stateDanger);
  });

  testWidgets('節點 tooltip 含分級與抽數', (tester) async {
    await tester.pumpWidget(
      _wrap(
        (ctx, colors) => TimelineHorizontal(
          entries: [_e('歐神', '1', 40, DateTime(2025, 4, 1))],
          targetRank: 5,
        ),
      ),
    );
    final l = AppLocalizations.of(
      tester.element(find.byType(TimelineHorizontal)),
    )!;
    final expected = '歐神 · ${l.luckTierLucky} · ${l.timelineSinceLast(40)}';
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == expected,
      ),
      findsOneWidget,
    );
  });
```

3c. 在測試檔頭 import 區加入（若尚無）：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
```

- [ ] **Step 4: 跑相關測試確認通過**

Run: `fvm flutter test test/widgets/cards/timeline_horizontal_test.dart`
Expected: PASS（含新斷言）

- [ ] **Step 5: format + analyze**

Run: `fvm dart format lib/ test/ && fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/cards/timeline_horizontal.dart lib/pages/banner_page.dart test/widgets/cards/timeline_horizontal_test.dart
git commit -m "feat(timeline): color horizontal timeline by luck + add legend on banner page"
```

---

### Task 6: 直向時間軸改歐非色 + 卡池名稱上色 + 可選圖例

**Files:**
- Modify: `lib/widgets/cards/timeline_vertical.dart`
- Test: `test/widgets/cards/timeline_vertical_test.dart`

**Interfaces:**
- Consumes: `pityThresholdFor`（T1）、`luckTierFor`／`luckColorFor`（T2）、`luckTierLabel`／`LuckLegend`（T4）。
- Produces: `TimelineVertical` 新增可選 `bool showLuckLegend = false`；節點/名稱改歐非色；meta 行卡池名稱以卡池色顯示；節點 tooltip 含分級＋抽數；`_bannerName` 改用 `gachaTypeFor`。`_EntryRow` 新增 `targetRank` 欄位。

- [ ] **Step 1: 改寫直向 widget**（`lib/widgets/cards/timeline_vertical.dart`）

1a. 檔頭 import 區加入：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/luck_legend.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/luck_palette.dart';
```

1b. `TimelineVertical` 建構子新增可選參數與欄位（放在 `isAcrossBanners` 之後）：

```dart
    this.showLuckLegend = false,
```

```dart
  /// true 時於卡片內容底部顯示 [LuckLegend]（App 頁面用）；分享圖維持 false。
  final bool showLuckLegend;
```

1c. build() 內 `_EntryRow` 呼叫加 `targetRank`：

```dart
                  for (var i = 0; i < visibleEntries.length; i++)
                    _EntryRow(
                      entry: visibleEntries[i],
                      showMonthTag: monthFlag[i],
                      colors: colors,
                      tokens: tokens,
                      targetRank: targetRank,
                    ),
```

1d. 在「載入更多」按鈕的 `if (remaining > 0) ...` 區塊**之後**（仍在外層 `Column` 的 `children` 內、`],` 收尾前）新增圖例：

```dart
          if (widget.showLuckLegend && entries.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.m),
              child: LuckLegend(),
            ),
```

1e. `_EntryRow`：新增 `targetRank` 欄位、把 `_nameRow` getter 改為吃顏色的方法、build 計算歐非色、meta 行改 `Text.rich` 為卡池名稱上色、節點 tooltip 改帶分級。完整改寫如下。

建構子與欄位（新增 `targetRank`）：

```dart
  const _EntryRow({
    required this.entry,
    required this.showMonthTag,
    required this.colors,
    required this.tokens,
    required this.targetRank,
  });
```

```dart
  /// 主要顯示稀有度，用於查該筆保底門檻。
  final int targetRank;
```

`_nameRow` getter 改為方法（吃名稱顏色）：

```dart
  /// 名稱行：可選 icon + 粗體名稱文字的 [Row]，名稱以 [nameColor] 上色。
  Widget _nameRow(Color nameColor) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      if (entry.sourceRecord != null) ...[
        GachaItemIcon(record: entry.sourceRecord!, size: 32),
        const SizedBox(width: 6),
      ],
      Flexible(
        child: Text(
          entry.name,
          style: TextStyle(
            color: nameColor,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
```

`_bannerName` 改用 `gachaTypeFor`（移除原本內嵌的 firstWhere-with-fallback）：

```dart
  /// 依 [cardPoolType] 查在地化卡池名稱；查無時回傳 fallback type 的解析名。
  String _bannerName(String cardPoolType, AppLocalizations l) =>
      gachaTypeFor(cardPoolType).resolveName(l);
```

build() 改寫（計算歐非色、tooltip 訊息、`_nameRow(luck)`、meta `Text.rich`）：

```dart
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final rank = entry.sourceRecord?.qualityLevel ?? targetRank;
    final pity = pityThresholdFor(entry.gachaType, rank);
    final tier = luckTierFor(entry.pullsSincePrev, pity);
    final luck = luckColorFor(tier, tokens);
    final bannerColor = colors.colorFor(entry.gachaType);
    final nodeTooltip =
        '${entry.name} · ${luckTierLabel(tier, l)} · '
        '${l.timelineSinceLast(entry.pullsSincePrev)}';
    final year = entry.time.year.toString();
    final month = entry.time.month.toString().padLeft(2, '0');

    return Padding(
      padding: EdgeInsets.only(
        top: showMonthTag ? AppSpacing.m : 0,
        bottom: AppSpacing.m,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _monthColumnWidth,
            child: showMonthTag
                ? Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.s, top: 4),
                    child: Text(
                      l.timelineMonthLabel(year, month),
                      maxLines: 1,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: tokens.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                        fontFeatures: kTabularFigures,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Tooltip(
            message: nodeTooltip,
            preferBelow: false,
            waitDuration: const Duration(milliseconds: 100),
            child: SizedBox(
              width: _haloSize,
              child: Center(
                child: TimelineNode(color: luck, tokens: tokens),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.m),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: entry.name,
                    preferBelow: false,
                    waitDuration: const Duration(milliseconds: 100),
                    child: entry.sourceRecord != null
                        ? GachaItemTapTarget(
                            record: entry.sourceRecord!,
                            child: _nameRow(luck),
                          )
                        : _nameRow(luck),
                  ),
                  const SizedBox(height: 2),
                  Tooltip(
                    message: entry.name,
                    preferBelow: false,
                    waitDuration: const Duration(milliseconds: 100),
                    child: Text.rich(
                      TextSpan(
                        style: TextStyle(
                          color: tokens.textMuted,
                          fontSize: 12,
                          fontFeatures: kTabularFigures,
                        ),
                        children: [
                          TextSpan(
                            text: '${formatShortMonthDay(entry.time)} · ',
                          ),
                          TextSpan(
                            text: _bannerName(entry.gachaType, l),
                            style: TextStyle(color: bannerColor),
                          ),
                          TextSpan(
                            text:
                                ' · ${l.timelineSinceLast(entry.pullsSincePrev)}',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
```

> 注意：`_EntryRow` 既有的 `_bannerName` fallback（內嵌 `GachaType(...PityRule...)`）移除後，`data/gacha_types.dart` 的 import 已存在（`PityRule`／`GachaType`／`gachaTypeFor` 同檔），不需改 import。

- [ ] **Step 2: 更新直向測試**（`test/widgets/cards/timeline_vertical_test.dart`）

2a. 既有測試呼叫 `TimelineVertical(...)` 不需改（新參數有預設值，向下相容）。

2b. 新增歐非色 + 卡池名稱色 + 圖例斷言（先讀檔確認既有 `_wrap`/`_e` helper 命名，沿用之；下例假設與橫向測試同型）：

```dart
  testWidgets('歐非色：節點名稱依抽數變色（40→success、70→danger）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        (ctx, colors) => TimelineVertical(
          entries: [
            _e('歐神', '1', 40, DateTime(2025, 4, 1)),
            _e('非酋', '1', 70, DateTime(2025, 3, 1)),
          ],
          colors: colors,
          targetRank: 5,
        ),
      ),
    );
    Color nameColor(String name) =>
        tester.widget<Text>(find.text(name)).style!.color!;
    const t = GachaTokens.dark;
    expect(nameColor('歐神'), t.stateSuccess);
    expect(nameColor('非酋'), t.stateDanger);
  });

  testWidgets('showLuckLegend=true 顯示圖例、預設不顯示', (tester) async {
    Widget build({required bool legend}) => _wrap(
      (ctx, colors) => TimelineVertical(
        entries: [_e('歐神', '1', 40, DateTime(2025, 4, 1))],
        colors: colors,
        targetRank: 5,
        showLuckLegend: legend,
      ),
    );
    await tester.pumpWidget(build(legend: false));
    expect(find.byType(LuckLegend), findsNothing);
    await tester.pumpWidget(build(legend: true));
    expect(find.byType(LuckLegend), findsOneWidget);
  });
```

2c. 測試檔頭補 import（若尚無）：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/luck_legend.dart';
```

> 若既有直向測試的 `_e` helper 未帶 `sourceRecord`（與橫向測試相同型），上述 `_e('歐神', '1', 40, ...)` 直接可用；`gachaType '1'` 對應 80 池。先 Read 該測試檔頭確認 helper 簽名再貼。

- [ ] **Step 3: 跑相關測試確認通過**

Run: `fvm flutter test test/widgets/cards/timeline_vertical_test.dart`
Expected: PASS（含新斷言）

- [ ] **Step 4: format + analyze**

Run: `fvm dart format lib/ test/ && fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/cards/timeline_vertical.dart test/widgets/cards/timeline_vertical_test.dart
git commit -m "feat(timeline): color vertical timeline by luck, tint banner name, optional legend"
```

---

### Task 7: overview_page 開啟直向圖例

**Files:**
- Modify: `lib/pages/overview_page.dart:345-351`

**Interfaces:**
- Consumes: `TimelineVertical.showLuckLegend`（T6）。

- [ ] **Step 1: 改 overview 呼叫端**（`lib/pages/overview_page.dart:345-351`）

```dart
        TimelineVertical(
          entries: timeline,
          colors: bannerColors,
          targetRank: timelineRank,
          nowPulls: timelineNowPulls,
          isAcrossBanners: true,
          showLuckLegend: true,
        ),
```

- [ ] **Step 2: 確認 share_card 未受影響**

讀 `lib/widgets/share/share_card.dart:394` 附近的 `TimelineVertical(...)`，確認**沒有**傳 `showLuckLegend`（維持預設 false，分享圖不顯示圖例）。不需修改。（註：此決策於後續 **Task 10** 改為「分享圖也顯示圖例、釘在卡片底部」，share_card 改傳 `showLuckLegend: true`。）

- [ ] **Step 3: 全量驗證**

Run: `fvm dart format lib/ test/ && fvm flutter analyze && fvm flutter test`
Expected: `No issues found!` 與 `All tests passed!`

- [ ] **Step 4: Commit**

```bash
git add lib/pages/overview_page.dart
git commit -m "feat(overview): show luck legend under the timeline"
```

---

## 後續增強任務（同分支已實作，供姐妹專案參考）

Task 1–7 落地後，於同分支追加下列增強。皆已完成並全綠提交，以下記錄**檔案、做法與
關鍵決策**（非逐步 TDD），方便姐妹專案直接照搬。原則：所有「抽數」語意數字一律套
同一套歐非色，並讓卡池識別色不與歐非色衝突。

### Task 8: 時間軸 meta 的「N 抽」上歐非色 — 已實作（commit `602c58f`）

**Files:** `lib/widgets/cards/timeline_horizontal.dart`、`lib/widgets/cards/timeline_vertical.dart`；測試同兩檔的 `_test.dart`。

- 橫向：底部 `日期 · N 抽` 改 `Text.rich`，「N 抽」span 套 `luck` 色，日期維持 `textMuted`。
- 垂直：meta `Text.rich` 把第三段 ` · N 抽` 拆成 muted 的 ` · ` 分隔 + 套 `luck` 的「N 抽」span（卡池名稱段仍卡池色）。
- 測試：以遞迴尋找 `Text.rich` 內 span 的 helper（注意區域函式勿命名為 `find`，會遮蔽 `flutter_test` 的 `find`），斷言 40 抽→`stateSuccess`、70 抽→`stateDanger`。

### Task 9: 卡池調色盤避開歐非色帶 — 已實作（commit `acca4b6`）

**Files:** `lib/widgets/banner_colors.dart`、`test/widgets/banner_colors_test.dart`。

- 問題：卡池 `1`＝`stateSuccess`、`2`＝`stateDanger` 完全同 hex，`4` 橘≈琥珀。
- 做法：10 個卡池色（dark + light）整體重排到 cyan→洋紅 弧段，全部避開綠/琥珀/紅；**不新增 token**。
- 測試：新增「任一卡池色 ≠ 該主題 `stateSuccess`／`stateWarning`／`stateDanger`」斷言（dark + light）。

### Task 10: 分享圖圖例（時間軸卡片內、釘底部） — 已實作（commit `a44b128`，取代早期 footer 版 `94c3ea9`）

**Files:** `lib/widgets/cards/timeline_vertical.dart`（`container()`）、`lib/widgets/share/share_card.dart`、`test/widgets/share/share_card_test.dart`。

- `TimelineVertical.container()` 加參數 `bool withLegend`；`fillHeight` 時改 `Column[Expanded(裁切內容), LuckLegend]`（圖例釘邊框內底部、不被裁），非 `fillHeight` 時 `Column[內容, LuckLegend]`。原本散在 build 內的圖例改由 `container()` 統一渲染。
- `share_card._timeline()` 傳 `showLuckLegend: true`（移除早期「等高列下方 footer」版的 `Center(LuckLegend())` 與其 import）。
- 測試：斷言「12 筆跨月 entries 溢出被裁時，`LuckLegend` 底部仍 ≤ 卡片底部」。

### Task 11: 記錄列表「保底內」欄上歐非色 — 已實作（commit `365100e`）

**Files:** `lib/widgets/data/sortable_table.dart`、`test/widgets/data/sortable_table_test.dart`。

- `_Row` 新增 `mainRank` 欄位；「保底內」（`mainPityIndex`）數字改用
  `luckColorFor(luckTierFor(row.mainPityIndex, pityThresholdFor(record.cardPoolType, mainRank)), tokens)`。
- 「總抽數」（`totalIndex`，累積序號）維持 `textMuted`。
- 測試：A(5★)/B(4★)/C(3★) 下，值 `1`（C 的 totalIndex muted + mainPityIndex 綠）的 `Text` 顏色集合同時含 `stateSuccess` 與 `textMuted`。

### Task 12: 橫向時間軸年/月區隔 — 已實作（commits `bf5d5fe`、間距微調 `75a2dc8`）

**Files:** `lib/widgets/cards/timeline_horizontal.dart`、`test/widgets/cards/timeline_horizontal_test.dart`。

- build 計算 `monthStart`（每欄是否為其月份分組首欄，左→右＝新→舊），傳 `isMonthStart` 與 `showMonthDivider = monthStart[i] && i > 0` 給 `_EntryColumn`。
- `_EntryColumn`：頂部固定高 `_monthBandHeight` 標籤帶（組首填 `timelineMonthLabel`、靠上對齊；其餘留白）＋**底部等高 spacer 對稱補回**（置中欄加等高上下 padding 不移動中心→節點仍對齊軸線）；組首欄左側 `Border` 當分隔線；「現在」欄不加帶。
- 測試：兩個月份分組各出現一個 `timelineMonthLabel` 標籤。
- 注意：`_monthBandHeight` 同時決定標籤帶與底部 spacer，調間距時兩者一起變、對齊不破。

---

## 驗收條件（對照 spec）

- [ ] `fvm dart format lib/ test/`、`fvm flutter analyze`（No issues found!）、`fvm flutter test`（All tests passed!）全綠。
- [ ] 單卡池頁：時間軸節點/名稱依抽數呈綠/黃/紅，卡片下方有歐非圖例（`ChartCard.legend`）。
- [ ] 總覽頁：節點/名稱呈歐非色；meta 行卡池名稱以卡池色顯示；卡片底部有圖例。
- [ ] 節點／物品 hover tooltip 只顯示物品名稱（初版曾含分級/抽數，後改回只顯示名稱）。
- [ ] 時間軸 meta 的「N 抽」與記錄列表「保底內」欄皆呈歐非色（Task 8/11）。
- [ ] 卡池調色盤無任一色等於歐非三色（Task 9）。
- [ ] 分享圖：節點/名稱/抽數呈歐非色，時間軸卡片底部有圖例且 entries 溢出被裁時仍可見（Task 10）。
- [ ] 橫向時間軸有年/月分隔線＋標籤，節點仍對齊軸線（Task 12）。

## Self-Review 摘要

- **Spec 覆蓋**：分級邏輯→T2；門檻來源→T1＋T5/T6 的 `rank = sourceRecord?.qualityLevel ?? targetRank`；顏色重用→T2；新檔 luck_palette/luck_legend→T2/T4；helper→T1；橫向→T5；直向＋卡池名稱色→T6；圖例（橫向 ChartCard.legend、直向參數）→T5/T6/T7；tooltip→T5/T6；i18n→T3；測試→各任務 TDD。後續增強（抽數/列表一致上色、卡池避撞、分享圖圖例、橫向年月區隔）→T8–T12（已實作）。
- **型別一致**：`luckTierFor(int,int)→LuckTier`、`luckColorFor(LuckTier,GachaTokens)→Color`、`luckTierLabel(LuckTier,AppLocalizations)→String`、`pityThresholdFor(String,int)→int`、`gachaTypeFor(String)→GachaType` 全程一致。
- **無 placeholder**：每個 code step 均附完整程式碼與預期輸出。
