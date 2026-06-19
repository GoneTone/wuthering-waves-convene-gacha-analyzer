# 時間軸節點以歐非程度上色

## 背景與動機

目前時間軸（`TimelineVertical`／`TimelineHorizontal`）的節點與物品名稱皆以
**卡池顏色**（`BannerColors.colorFor(gachaType)`）上色，因此單一卡池頁整條時間軸是
同一個顏色，無法從顏色看出每一次出貨「歐還是非」。

本功能參考 WuWa Tracker「以幾抽為依據」的概念，改成依**抽到該筆所花的抽數相對於
保底門檻的比例**，把節點分成綠（歐）／黃（普通）／紅（非）三階，讓使用者一眼看出
運氣分布。

## 目標

- 時間軸節點與物品名稱顏色改為反映「歐非程度」。
- 門檻依各卡池保底自動換算（80 池、新手 50 池、4★ 10 池皆正確）。
- 總覽頁（跨卡池）仍能分辨「哪個池子」——把卡池名稱文字改用卡池顏色顯示。
- 加入小圖例與 tooltip 提升辨識度。
- 不影響分享圖版面（節點/名稱顏色會反映歐非，但不畫圖例）。

## 非目標（YAGNI）

- 不新增「歐非」相關的設定選項或開關。
- 不新增主題 token（重用既有語意色）。
- 不修改 `TimelineEntry` 資料模型。
- 不為圖例標示抽數範圍（跨池門檻不同，標數字會誤導）。

## 分級邏輯（核心）

以 `ratio = pullsSincePrev / pityThreshold` 分三階：

| 比例區間            | 分級    | 顏色            |
|-----------------|-------|---------------|
| `ratio ≤ 0.5`   | 歐     | `stateSuccess`（綠） |
| `0.5 < ratio ≤ 0.8` | 普通    | `stateWarning`（金/琥珀） |
| `ratio > 0.8`   | 非     | `stateDanger`（紅）  |

換算後各池的抽數落點：

- **5★ 標準池（保底 80）**：綠 1–40 ／ 黃 41–64 ／ 紅 65–80。
- **新手池（保底 50）**：綠 1–25 ／ 黃 26–40 ／ 紅 41–50。
- **4★（保底 10）**：綠 1–5 ／ 黃 6–8 ／ 紅 9–10。
- **比例 > 1**（資料異常、超出硬保底）：歸入「非」（紅）。

### 門檻來源

- 用每筆 entry 的 `gachaType` 查該池保底規則。
- 稀有度優先取 `entry.sourceRecord?.qualityLevel`，缺值（歷史 callsite 未帶
  `sourceRecord`）才退回 widget 的 `targetRank`。如此不必改 `TimelineEntry` 模型。

### 顏色決策

直接重用 `GachaTokens` 既有語意色 `stateSuccess`／`stateWarning`／`stateDanger`，
**不新增 token**（符合「嚴禁重複造輪子」）。

> **取捨**：中階 `stateWarning` 在本主題是金/琥珀色（與 5★ 金 `fiveStar`、
> `accentPrimary` 同色系），並非純黃。這是刻意接受的取捨——綠／琥珀／紅的紅綠燈
> 語意對使用者仍直覺。

## 元件與檔案異動

### 新增：`lib/widgets/luck_palette.dart`

對齊既有 `lib/widgets/rank_palette.dart` 的風格，提供純函式：

```dart
/// 歐非分級：依抽數相對保底比例分三階。
enum LuckTier { lucky, average, unlucky }

/// 依「抽數 / 保底門檻」比例回傳分級。
/// 比例 <= 0.5 歐；<= 0.8 普通；其餘（含 > 1）非。
LuckTier luckTierFor(int pulls, int pityThreshold);

/// 將分級映射到既有語意色（綠/金/紅）。
Color luckColorFor(LuckTier tier, GachaTokens t);
```

- `0.5` / `0.8` 兩個門檻以具名常數定義，附 WHY 註解（綠 = 半保底內、紅 = 進入
  軟保底區）。
- `pityThreshold <= 0` 的防呆：視為「非」（避免除以零；正常資料不會發生）。
- palette 不 import l10n；分級名稱由 widget 端在地化。

### 新增：`lib/widgets/luck_legend.dart`

輕量橫向圖例 widget：3 個色點 + 在地化名稱（歐／普通／非），不含數字。

- 供兩個時間軸 widget 共用。
- 色點樣式對齊 `DistributionLegend`（10×10、圓角 2），但**不重用**
  `DistributionLegend`——後者強制帶 count 與百分比兩欄，不適合純色說明。
- 版面採可換行（`Wrap`）橫向排列，低視窗寬度不溢出。

### 修改：`lib/data/gacha_types.dart`

新增集中查詢 helper，消除散落各處的 `firstWhere`：

```dart
/// 依 cardPoolType 字串查 GachaType；查無時回傳帶預設保底的 fallback。
GachaType gachaTypeFor(String cardPoolType);

/// 查指定卡池、指定 rank 的保底門檻；查無時回傳預設（5★ 80、其餘 10）。
int pityThresholdFor(String cardPoolType, int rank);
```

- `gachaTypeFor` 的 fallback 沿用 `timeline_vertical.dart` 現有 `_bannerName` 內
  那組（未知 type → `PityRule(5,80)`＋`PityRule(4,10)`）。
- 順手把 `timeline_vertical.dart` 的 `_bannerName` 改用 `gachaTypeFor`，移除重複的
  firstWhere-with-fallback。

### 修改：`lib/widgets/cards/timeline_horizontal.dart`（單卡池頁）

- `_EntryColumn` 新增 `targetRank` 參數（由 `TimelineHorizontal.targetRank` 下傳）。
- 顏色計算：
  ```dart
  final rank = entry.sourceRecord?.qualityLevel ?? targetRank;
  final pity = pityThresholdFor(entry.gachaType, rank);
  final luck = luckColorFor(luckTierFor(entry.pullsSincePrev, pity), tokens);
  ```
  以 `luck` 取代原 `accent`，用於**物品名稱文字**與**節點**。
- 節點 `Tooltip` 訊息補上分級＋抽數（見「tooltip 文案」）。
- `TimelineHorizontal` 新增可選參數 `bool showLuckLegend = false`；為 `true` 時在
  時間軸下方加上 `LuckLegend`。banner_page 傳 `true`。
  - 橫向時間軸本體是填滿高度的 `Stack`，圖例需置於 widget 外層的 `Column`
    （時間軸在上、圖例在下），不要疊進 `Stack`。

### 修改：`lib/widgets/cards/timeline_vertical.dart`（總覽頁／分享圖）

- `_EntryRow` 新增 `targetRank` 參數（由 `TimelineVertical.targetRank` 下傳）。
- 顏色計算同上，`luck` 用於**物品名稱文字**（`_nameRow`）與**節點**。
- meta 行（原 `date · bannerName · N抽`）改用 `Text.rich`：把**卡池名稱**字串用
  `colors.colorFor(entry.gachaType)` 上色，日期與「N 抽」維持 `textMuted`。
  保留「哪個池子」的辨識。
- 節點 `Tooltip` 訊息補上分級＋抽數。
- `TimelineVertical` 新增可選參數 `bool showLuckLegend = false`；為 `true` 時在卡片
  內容底部（`footerNote` 之前/「載入更多」附近）加上 `LuckLegend`。overview_page
  傳 `true`；**share_card.dart 不傳（維持 false）**，分享圖版面零回歸。

### 修改：呼叫端

- `lib/pages/overview_page.dart`：`TimelineVertical(... showLuckLegend: true)`。
- `lib/pages/banner_page.dart`：`TimelineHorizontal(... showLuckLegend: true)`。
- `lib/widgets/share/share_card.dart`：不變（不傳 `showLuckLegend`，預設 false）。

## tooltip 文案

節點 tooltip 由「只有物品名稱」改為組裝既有片段：

```
{物品名稱} · {分級名稱} · {timelineSinceLast(pulls)}
```

例：`深淵的呼喚 · 歐 · 40 抽`。分級名稱取自下方新增的 l10n key，抽數重用既有
`timelineSinceLast`，不另外新增 tooltip 專用 key。

## i18n

於 4 個核心 ARB（`lib/l10n/app_zh.arb`（zh-Hant 模板）、`lib/l10n/app_zh_Hans.arb`、
`lib/l10n/app_en.arb`、`lib/l10n/app_ja.arb`）新增 3 個 key：

| key                | zh-Hant | 說明        |
|--------------------|---------|-----------|
| `luckTierLucky`    | 歐       | 綠階分級名稱    |
| `luckTierAverage`  | 普通      | 黃階分級名稱    |
| `luckTierUnlucky`  | 非       | 紅階分級名稱    |

- 三個 key 同時用於 `LuckLegend` 的標籤與節點 tooltip 的分級名稱。
- generated l10n 為 gitignore，改完核心 ARB 後跑 `fvm flutter gen-l10n`。
- 其餘 Crowdin locale 不在本次改動範圍。

## 測試

- `test/`（對應 `luck_palette.dart`）：`luckTierFor` 邊界單元測試
  - 80 池：40→歐、41→普通、64→普通、65→非、80→非、81→非。
  - 50 池：25→歐、26→普通、40→普通、41→非、50→非。
  - 10 池：5→歐、6→普通、8→普通、9→非、10→非。
  - 防呆：`pityThreshold = 0` → 非。
- `pityThresholdFor`／`gachaTypeFor` 查詢測試：已知池（1→80、5→50、任一池 4★→10）
  與未知池 fallback。
- 既有時間軸 widget 測試若斷言節點顏色 = 卡池色，需同步更新為歐非色預期。

## 驗收條件

- `fvm dart format lib/ test/`、`fvm flutter analyze`（No issues found!）、
  `fvm flutter test`（All tests passed!）全綠。
- 單卡池頁時間軸節點/名稱顏色隨抽數呈綠/黃/紅，下方有圖例。
- 總覽頁時間軸節點/名稱呈歐非色，meta 行卡池名稱以卡池色顯示，下方有圖例。
- 節點 tooltip 顯示「名稱 · 分級 · N 抽」。
- 分享圖版面與改動前一致（顏色反映歐非、無圖例）。

## 日誌

本功能為純 UI／顏色呈現，無 I/O、外部 API 或錯誤分支，依專案慣例不額外埋 log。
