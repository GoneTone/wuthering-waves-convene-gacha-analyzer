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
- 一致性：所有「抽數」呈現處都套同一套歐非色——時間軸節點/名稱、時間軸 meta 的
  「N 抽」、以及記錄列表的「保底內」欄（見「後續增強」）。
- 卡池調色盤整體避開歐非色帶（綠/琥珀/紅），避免「卡池色」與「歐非色」在同一視圖
  並存時混淆（見「後續增強」）。
- 分享圖同樣呈現歐非色，並把圖例釘在時間軸卡片底部（見「後續增強」）。
- 橫向時間軸加上年/月區隔（分隔線＋月份標籤），與垂直版一致（見「後續增強」）。

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
- 橫向時間軸的圖例改走既有 `ChartCard.legend` slot（banner_page 在包住時間軸的
  `ChartCard` 傳 `legend: const LuckLegend()`），**不**在 `TimelineHorizontal` 上新增
  參數——較 DRY，且避開「橫向本體是填滿高度 `Stack`」的版面問題。
- 橫向時間軸不再需要 `colors` 參數（節點/名稱改歐非色後卡池色未用），一併移除。

### 修改：`lib/widgets/cards/timeline_vertical.dart`（總覽頁／分享圖）

- `_EntryRow` 新增 `targetRank` 參數（由 `TimelineVertical.targetRank` 下傳）。
- 顏色計算同上，`luck` 用於**物品名稱文字**（`_nameRow`）與**節點**。
- meta 行（原 `date · bannerName · N抽`）改用 `Text.rich`：把**卡池名稱**字串用
  `colors.colorFor(entry.gachaType)` 上色，日期與「N 抽」維持 `textMuted`。
  保留「哪個池子」的辨識。
- 節點 `Tooltip` 訊息補上分級＋抽數。
- `TimelineVertical` 新增可選參數 `bool showLuckLegend = false`；為 `true` 時把圖例
  **釘在卡片底部**（在 `container()` 內：`fillHeight` 時內容區用 `Expanded` 占滿並
  自行裁切、圖例排其下，確保 entries 溢出被裁時圖例仍可見；非 `fillHeight` 時自然
  排在內容下方）。overview_page 與 share_card 皆傳 `true`。

### 修改：呼叫端

- `lib/pages/overview_page.dart`：`TimelineVertical(... showLuckLegend: true)`。
- `lib/pages/banner_page.dart`：包住時間軸的 `ChartCard` 傳 `legend: const LuckLegend()`；
  `TimelineHorizontal` 不再傳 `colors`。
- `lib/widgets/share/share_card.dart`：`TimelineVertical(... fillHeight: true,
  showLuckLegend: true)`——圖例釘在卡片底部，即使 entries 溢出被裁仍可見。

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
- 分享圖呈現歐非色，且時間軸卡片底部有圖例（即使 entries 溢出被裁仍可見）。

## 後續增強（同分支追加，供姐妹專案參考）

初版（上述 §核心～§驗收條件）落地後，於同一分支 `feat/timeline-luck-color` 追加了
以下增強。設計原則一致：**凡是「抽數」語意的數字一律套同一套歐非色**，並讓「卡池
識別色」與「歐非色」不互相干擾。

### A. 所有「抽數」一致上色

- **時間軸 meta 的「N 抽」**：兩個時間軸的 `日期 · [卡池名稱] · N 抽` 中，「N 抽」
  那段改用歐非色（`Text.rich` 內獨立 span）。日期維持 `textMuted`；垂直版的卡池
  名稱維持卡池色。
- **記錄列表「保底內」欄**（`lib/widgets/data/sortable_table.dart`）：該欄即
  `mainPityIndex`（距上次主稀有度的抽數），與時間軸抽數同義，故改用
  `luckColorFor(luckTierFor(row.mainPityIndex, pityThresholdFor(record.cardPoolType,
  mainRank)), tokens)`。「總抽數」（`totalIndex`，累積序號、非運氣指標）維持
  `textMuted`。`_Row` 為此新增 `mainRank` 欄位。

### B. 卡池調色盤避開歐非色帶（`lib/widgets/banner_colors.dart`）

- 動機：卡池 `1`（角色活動）dark `0xFF46B07A` 與歐非綠 `stateSuccess`、卡池 `2`
  （武器活動）`0xFFE6736B` 與歐非紅 `stateDanger` **完全同 hex**；卡池 `4` 橘
  ≈ 歐非琥珀。歐非色與卡池名稱在 meta 行並存會混淆。
- 做法：把 10 個卡池色整體重排到 **cyan → 洋紅** 弧段（青藍/天藍/矢車菊藍/紫羅蘭/
  灰藍/薰衣草紫/淺青/蘭紫/桃紅/靛藍），全部避開綠/琥珀/紅；dark 與 light 各一組
  （色相一致、light 加深）。**未新增任何 token**。
- 約束固化：`test/widgets/banner_colors_test.dart` 新增斷言「任一卡池色不得等於
  該主題的 `stateSuccess`／`stateWarning`／`stateDanger`」（dark + light 各一）。
- 註：此重排可行，是因為節點已改歐非色、卡池色不再上節點，原本「卡池色須避開
  稀有度 token」的約束放寬，可改以「避開歐非色」為主軸。

### C. 分享圖圖例改放時間軸卡片內、釘底部（`timeline_vertical.dart` + `share_card.dart`）

- 初版曾規劃分享圖不畫圖例；後改為**分享圖也要有圖例**，且要與 App 一致放在時間軸
  卡片內。
- 難點：分享圖右欄時間軸用 `fillHeight: true`，超出左欄等高的部分由 `ClipRect`
  裁掉；圖例若只排在內容最底會被裁掉。
- 解法：`TimelineVertical.container()` 在 `withLegend` 時，`fillHeight` 路徑改成
  `Column[Expanded(裁切內容), LuckLegend]`——內容區占滿剩餘高並自行裁切，圖例釘在
  邊框內底部、恆可見。非 `fillHeight`（App overview）則 `Column[內容, LuckLegend]`
  自然排列。`share_card_test.dart` 斷言「entries 溢出時圖例底部仍在卡片內」。

### D. 橫向時間軸年/月區隔（`timeline_horizontal.dart`）

- 與垂直版一致：每個月份分組（左→右＝新→舊，某月最新一筆為組首）在組首欄**上方
  標年/月**（重用 `timelineMonthLabel`），並在月份**交界畫垂直分隔線**（畫在組首欄
  左側 `Border`；最左欄＝最新月份起點不畫）。
- 節點對齊關鍵：每欄頂部保留固定高 `_monthBandHeight` 的標籤帶（組首填標籤、其餘
  留白且標籤靠上對齊），**底部以等高 spacer 對稱補回**。置中欄加等高上下 padding
  不改變其垂直中心，故節點 y 不位移、仍對齊背景軸線；「現在」欄不加帶、不受影響。

## 日誌

本功能為純 UI／顏色呈現，無 I/O、外部 API 或錯誤分支，依專案慣例不額外埋 log。
