# Android 原生廣告 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Android 版在卡池頁紀錄列表中間（小型）、卡池頁時間軸下方（中型）、綜合頁類型分布下方（中型）顯示 AdMob 原生廣告，底部橫幅不變；廣告沒顯示時版面和沒有廣告時完全一樣。

**Architecture:** `nativeAdProvider`（`FutureProvider.autoDispose.family`，key 含位置、頁面範圍、深淺色）負責載入與釋放，實際載入走可替換的 `nativeAdLoaderProvider`（測試換成假載入器）。頁面在**頁面層級**依條件 watch provider（條件第一次成立才開始載入、離開頁面自動釋放），拿到已載入的廣告才把 `NativeAdBlock` 放進版面；`SortableTable` 多一個「第 10 筆後插入」的選填參數。

**Tech Stack:** Flutter、Riverpod 3、`google_mobile_ads` 9.2.0（`NativeAd`＋`NativeTemplateStyle`）。

**Spec:** `docs/superpowers/specs/2026-11-10-android-native-ads-design.md`（已核准）

## Global Constraints

- 只在 Android 載入與顯示：`ref.watch(isAndroidProvider)`；Windows 與測試以外的平台一律不呼叫 SDK。
- 必須 `ref.watch(adsProvider.select((s) => s.canRequestAds))` 為 true 才載入（`AdsController` 先初始化 SDK 才把它設成 true，所以這同時保證 SDK 已初始化）。
- 有內容才載入：沿用 `pageHasAdContent(path:, gacha:)`（`lib/services/ads/ad_placement.dart`）。
- 原生廣告單元 ID：release 且注入 `ADMOB_NATIVE_UNIT_ID` 時用注入值，否則一律用官方測試 ID `ca-app-pub-3940256099942544/2247696110`。
- 模板：位置 1＝`TemplateType.small`；位置 3、4＝`TemplateType.medium`（手機橫向也是中型）。
- 樣式：`mainBackgroundColor` = `surfaceCard`；`cornerRadius` = `AppRadius.md`；按鈕 = 背景 `accentPrimary`、文字 `colorScheme.onPrimary`、bold、14；標題 = `textPrimary`、bold、14；副標 = `textSecondary`、normal、12；第三行 = `textMuted`、normal、12；外層 `borderSubtle` 邊框＋`AppRadius.md` 圓角。
- 寬度：可用寬度上限 400dp、水平置中；**可用寬度小於 320dp 不顯示**。
- 沒有已載入的廣告時，**不插入任何東西**（不切開列表、不多出間距）。
- 每個位置每次停留最多載入一次；翻頁、改篩選、切帳號不重新載入；深淺色切換、離開頁面（含切換卡池）才釋放；失敗不重試。
- log：`Logger('ads')`，英文，帶 `placement=`，例如 `native loaded placement=bannerList`、`native failed placement=overview code=3 message=...`、`native disposed placement=...`。
- 專案規則：所有宣告一行 `///` 繁中 dartdoc；`//` 只寫不明顯的原因；提交前 `fvm dart format lib/ test/`、`fvm flutter analyze`（No issues found!）、`fvm flutter test`（All tests passed!）；commit 用英文 conventional commits，結尾兩行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`、`Claude-Session: https://claude.ai/code/session_01WreXjoaH16qSiJYU59riA8`；不 push。
- 不新增 UI 字串（模板自帶「Ad」標籤），所以不動 ARB。

## Review Focus

- 載入途中就離開頁面（provider 已 dispose）→ 晚到的廣告必須立刻釋放，不能洩漏。（Task 1 測試）
- 深淺色切換時舊廣告仍掛在畫面上就被釋放 → 會出現紅色錯誤框；舊廣告要等新一幀、`AdWidget` 離開畫面後才釋放（比照 `BannerAdSlot`）。（Task 1、3 測試）
- 從一個卡池切到另一個卡池：key 的 `scope` 不同，必須各自載入，不能共用前一個卡池的廣告。（Task 3 測試）
- 當頁剛好 10 筆／11 筆的邊界：10 筆不插、11 筆插在第 10 筆之後。（Task 2 測試）
- 可用寬度 319dp／320dp 的邊界：319 不顯示、320 顯示。（Task 1 測試）

---

### Task 1: 原生廣告的載入、樣式與顯示元件

**Files:**
- Modify: `lib/services/ads/ad_config.dart`
- Create: `lib/widgets/ads/native_ad.dart`
- Test: `test/services/ads/ad_config_test.dart`（若已存在則新增 group）、`test/widgets/ads/native_ad_test.dart`

**Interfaces:**
- Produces:
  - `const String kTestAdmobNativeUnitId = 'ca-app-pub-3940256099942544/2247696110';`
  - `String resolveNativeUnitId({required bool release, required String injected})`、`String get admobNativeUnitId`（讀 `String.fromEnvironment('ADMOB_NATIVE_UNIT_ID')`，寫法比照 `admobBannerUnitId`）
  - `enum NativeAdPlacement { bannerList, bannerMid, overview }`，有 `TemplateType get template`（bannerList→small，其他→medium）
  - `typedef LoadedNative = ({Widget view, VoidCallback dispose});`
  - `typedef NativeAdLoader = Future<LoadedNative?> Function(NativeAdPlacement placement, Brightness brightness);`
  - `final nativeAdLoaderProvider = Provider<NativeAdLoader>(...)`：正式實作，以 `admobNativeUnitId`、`nativeTemplateStyleFor(...)` 建 `NativeAd` 並 `load()`；`onAdFailedToLoad` 時 dispose 並回 null；用 Completer 且只 complete 一次（比照 `bannerAdListener`）。
  - `typedef NativeAdKey = ({NativeAdPlacement placement, String scope, Brightness brightness});`
  - `final nativeAdProvider = FutureProvider.autoDispose.family<LoadedNative?, NativeAdKey>(...)`：呼叫 loader；await 之後若 `!ref.mounted` 就立刻 dispose 並回 null；`ref.onDispose` 時把已載入的廣告排到下一幀（`WidgetsBinding.instance.addPostFrameCallback`）再 dispose；平台例外記 severe 並回 null。
  - `NativeTemplateStyle nativeTemplateStyleFor(TemplateType type, Brightness brightness)`：色票取 `GachaTokens.dark`／`GachaTokens.light`，`onPrimary` 取 App 主題在該亮度的 `colorScheme.onPrimary`（看 `lib/theme/app_theme.dart` 怎麼建 scheme）。
  - `class NativeAdBlock extends StatelessWidget`：`const NativeAdBlock({super.key, required LoadedNative ad, required NativeAdPlacement placement})`；`LayoutBuilder`，`maxWidth < 320` 時回 `SizedBox.shrink()`；否則 `Center` → 寬 `min(maxWidth, 400)`、固定高度 `kNativeSmallHeight`／`kNativeMediumHeight` 的外框（`borderSubtle` 邊框、`AppRadius.md`、`Clip.antiAlias`）包住 `ad.view`。
  - `const double kNativeSmallHeight = 100; const double kNativeMediumHeight = 370;`（起始值，Task 6 在模擬器依實際模板內容調整，不留空白、不截斷）

- [ ] **Step 1: 寫失敗測試**
  - `resolveNativeUnitId`：`(release: true, injected: 'x')` → `'x'`；`(release: true, injected: '')`、`(release: false, injected: 'x')` → `kTestAdmobNativeUnitId`。
  - `NativeAdPlacement.bannerList.template == TemplateType.small`；`bannerMid`、`overview` 為 `medium`。
  - `nativeTemplateStyleFor(TemplateType.medium, Brightness.dark)`：`mainBackgroundColor == GachaTokens.dark.surfaceCard`、`cornerRadius == AppRadius.md`、`callToActionTextStyle!.backgroundColor == GachaTokens.dark.accentPrimary`、`primaryTextStyle!.textColor == GachaTokens.dark.textPrimary`、`secondaryTextStyle!.size == 12`；`Brightness.light` 時改用 `GachaTokens.light` 的值。
  - `NativeAdBlock`：父寬 319 → 找不到 `ad.view`；父寬 320 → 找得到，大小 320×`kNativeSmallHeight`（bannerList）；父寬 600 → 寬 400、置中，medium 高 `kNativeMediumHeight`。
  - `nativeAdProvider`（`ProviderContainer` override `nativeAdLoaderProvider` 為假載入器）：同一個 key 讀兩次只呼叫一次 loader；`container.dispose()`（或取消監聽讓 autoDispose）後，等一幀，假廣告的 dispose 被呼叫一次；假載入器用 Completer 卡住，在完成前取消監聽，再完成 → dispose 被立刻呼叫、結果不外洩；loader 回 null → 值為 null；loader 丟例外 → 值為 null。
- [ ] **Step 2: 跑測試確認失敗**：`fvm flutter test test/widgets/ads/native_ad_test.dart test/services/ads/ad_config_test.dart`，預期因符號不存在而失敗。
- [ ] **Step 3: 實作上面 Produces 列出的所有宣告。**
- [ ] **Step 4: 跑測試確認通過**（同上指令）。
- [ ] **Step 5: 提交** `feat(ads): load native ads with templates styled from the app theme`

### Task 2: 紀錄列表第 10 筆之後插入廣告

**Files:**
- Modify: `lib/widgets/data/sortable_table.dart`（卡片模式那段，約 118～147 行）
- Test: `test/widgets/data/sortable_table_test.dart`（新增 group）

**Interfaces:**
- Consumes: 無（只接一個 Widget）。
- Produces: `SortableTable` 新增選填參數 `final Widget? midListAd;`（dartdoc：卡片模式且當頁超過 10 筆時，插在第 10 筆之後）。

- [ ] **Step 1: 寫失敗測試**（`midListAd: const SizedBox(key: Key('mid-ad'), height: 50)`，手機寬度使卡片模式）：
  - 當頁 11 筆 → 找到 `mid-ad`，且它在第 10 筆卡片之下、第 11 筆之上（比較 `tester.getTopLeft`）；上下各有 `AppSpacing.m` 間距。
  - 當頁 10 筆 → 找不到 `mid-ad`，且卡片外框容器只有 1 個。
  - `midListAd: null`、當頁 20 筆 → 卡片外框容器只有 1 個（與改動前相同，不切開）。
  - 表格模式（寬 1200、非 compact）＋`midListAd` 非 null → 找不到 `mid-ad`。
  - 有 `midListAd` 時切到最後一頁且該頁 ≤10 筆 → 不顯示；切回第 1 頁 → 又顯示同一個 widget（不重建 key）。
- [ ] **Step 2: 跑測試確認失敗**：`fvm flutter test test/widgets/data/sortable_table_test.dart`。
- [ ] **Step 3: 實作**：卡片模式時，若 `midListAd != null && slice.length > 10`，把 slice 分成前 10 筆與其餘兩個外框容器，中間 `SizedBox(height: AppSpacing.m)`＋`midListAd`＋`SizedBox(height: AppSpacing.m)`；否則維持原本單一容器（第二塊的斑馬紋延續原本的奇偶）。
- [ ] **Step 4: 跑測試確認通過。**
- [ ] **Step 5: 提交** `feat(records): let the card list host a mid-list ad slot`

### Task 3: 卡池頁接上位置 1 與位置 3

**Files:**
- Modify: `lib/pages/banner_page.dart`
- Test: `test/pages/banner_page_native_ads_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `nativeAdProvider`、`NativeAdKey`、`NativeAdPlacement`、`NativeAdBlock`、`nativeAdLoaderProvider`；Task 2 的 `SortableTable.midListAd`；`recordListUsesCards(context, width)`。

- [ ] **Step 1: 寫失敗測試**（override `isAndroidProvider` = true、`adsProvider` 為 `canRequestAds: true`、`nativeAdLoaderProvider` 為記錄 (placement, brightness) 的假載入器，回傳帶 key 的假 view；資料用既有測試 helper 建一個卡池 25 筆、含 5★）：
  - 手機直向進頁 → 假載入器被呼叫 `bannerList` 一次、`bannerMid` 一次（不必捲動）；捲到時間軸下方看得到 `bannerMid` 的 view，且它在時間軸卡之下、「5★ 一覽」標題之上。
  - 卡池沒有 5★ → `bannerMid` 照樣顯示，它和「紀錄列表」標題之間的距離 ≥ `AppSpacing.xl`。
  - 該卡池只有 8 筆 → 不呼叫 `bannerList`，仍呼叫 `bannerMid`。
  - 平板寬（表格模式）→ 不呼叫 `bannerList`。
  - `isAndroidProvider` = false，或 `canRequestAds` = false，或卡池沒有紀錄 → 兩個都不呼叫，頁面 widget 樹與沒有廣告時相同（找不到任何假 view、列表只有 1 個外框）。
  - 假載入器回 null（失敗）→ 不顯示、不插入間距。
  - 翻到第 2 頁 → 不再呼叫 loader；切換深色→淺色 → `bannerList`、`bannerMid` 以 `Brightness.light` 各再呼叫一次，舊的假廣告在下一幀被 dispose。
  - 從 A 卡池切到 B 卡池 → B 以新的 scope 各呼叫一次，A 的假廣告被 dispose。
  - 改篩選讓總筆數從 8 變 12 → 補呼叫 `bannerList` 一次；再改回 8 → 不 dispose（停留期間保留）、不顯示。
- [ ] **Step 2: 跑測試確認失敗。**
- [ ] **Step 3: 實作**：
  - 在 `build` 的頁面層級（`CustomScrollView` 之外，不放進按需建構的 sliver 子項）計算條件，條件成立才 `ref.watch(nativeAdProvider((placement: ..., scope: cardPoolType, brightness: Theme.of(context).brightness)))`。
  - 位置 3 條件：Android、`canRequestAds`、`records.isNotEmpty`。
  - 位置 1 條件：位置 3 的條件，加上卡片模式（用包住頁面的 `LayoutBuilder` 取內容寬度扣掉 `pagePadding` 後呼叫 `recordListUsesCards`）且篩選後的總筆數 `sorted.length > 10`。用 `_BannerPageState` 的一個 bool 欄位記住「這次停留已經要過位置 1」，之後就一直 watch，條件變回 false 也不放開（停留期間最多載入一次）。
  - 位置 3 插入點：時間軸那一列之後既有的 `SizedBox(height: AppSpacing.xl)` 後面，有廣告時加 `NativeAdBlock(placement: bannerMid)`＋`SizedBox(height: AppSpacing.xl)`；沒有廣告時什麼都不加。
  - 位置 1：有廣告時傳 `midListAd: NativeAdBlock(placement: bannerList, ...)` 給 `SortableTable`，否則傳 null。
- [ ] **Step 4: 跑測試確認通過。**
- [ ] **Step 5: 提交** `feat(ads): show native ads in the banner page list and below the timeline`

### Task 4: 綜合頁接上位置 4

**Files:**
- Modify: `lib/pages/overview_page.dart`（「各卡池主稀有度件數」前，約 337～339 行）
- Test: `test/pages/overview_page_native_ads_test.dart`

**Interfaces:**
- Consumes: Task 1 的 provider 與 `NativeAdBlock`。

- [ ] **Step 1: 寫失敗測試**（同 Task 3 的 override 方式）：
  - 有紀錄 → 進頁就呼叫 `overview` 一次；看得到 view，且在「類型分布」卡之下、「各卡池最高稀有度件數」卡之上，前後間距都是 `AppSpacing.m`。
  - 非 Android／`canRequestAds` false／沒有任何紀錄／啟動載入中 → 不呼叫、版面與沒有廣告時相同。
  - 失敗 → 不顯示、不多出間距。
  - 深淺色切換 → 以新亮度再呼叫一次，舊的在下一幀 dispose。
- [ ] **Step 2: 跑測試確認失敗。**
- [ ] **Step 3: 實作**：`OverviewPage.build` 頁面層級依條件 watch `nativeAdProvider((placement: NativeAdPlacement.overview, scope: 'overview', brightness: ...))`，條件用 `pageHasAdContent(path: '/', gacha: ...)`；有廣告時在那個 `SizedBox(height: AppSpacing.m)` 之後插入 `NativeAdBlock`＋`SizedBox(height: AppSpacing.m)`。
- [ ] **Step 4: 跑測試確認通過。**
- [ ] **Step 5: 提交** `feat(ads): show a native ad on the overview page`

### Task 5: 建置注入、CI 與文件

**Files:**
- Modify: `.github/workflows/release.yml`（「Write ads defines from secrets」步驟）
- Modify: `docs/privacy-policy.md`（中英文「廣告」一節、最後更新日期）
- Modify: `docs/Android移植筆記.md`（#50 新增「原生廣告」小節）
- Modify: README ×4（若有寫「只有一則橫幅」之類的廣告描述）
- Modify（本機、不進版控）：`private/play-store/listing.md`、`secrets/ads_defines.json`（使用者提供正式 ID 後才填）

- [ ] **Step 1: CI**：步驟多讀 `ADMOB_NATIVE_UNIT_ID: ${{ secrets.ADMOB_NATIVE_UNIT_ID }}`，`jq` 輸出加 `ADMOB_NATIVE_UNIT_ID`；三個都有才寫檔，否則沿用現有警告（訊息加上新名稱）。用 actionlint 檢查（`go run github.com/rhysd/actionlint/cmd/actionlint@latest .github/workflows/release.yml`），預期無輸出。
- [ ] **Step 2: 隱私權政策**：「Android 版會在有內容的頁面底部顯示一則 Google AdMob 橫幅廣告」改成也包含「部分頁面的內容之間會穿插原生廣告」（中英文），其餘資料收集描述不變；最後更新改成實作當天日期。
- [ ] **Step 3: 移植筆記 #50**：新增「原生廣告（2026-11-10）」，記：三個位置與模板、為什麼要在頁面層級載入（按需建構的 sliver 會晚建構）、一定要等 SDK 初始化（試作出現紅色錯誤框）、廣告未顯示時不佔位、深淺色切換要重新載入、翻頁不重新載入的原因、位置 3 沒有 5★ 時照放並保留 xl 間距、模板可改與不可改的樣式。
- [ ] **Step 4: README 與商店說明**：搜尋「橫幅」「banner ad」「バナー」「横幅」，有描述廣告形式的地方一併更新；`private/play-store/listing.md` 四語的「只有一則小型橫幅廣告」改寫為「頁面底部一則橫幅，以及部分頁面內容之間的原生廣告」。
- [ ] **Step 5: 中日文與英數字空格檢查**（`python -I -X utf8 <scratchpad>/l10n_fix/spacing_check.py docs/privacy-policy.md docs/Android移植筆記.md README*.md`），無輸出。
- [ ] **Step 6: 提交** `docs(ads): describe native ads in the privacy policy, notes and CI`

### Task 6: AdMob 後台、實機外觀調整與正式版驗證（主代理與使用者一起）

- [ ] **Step 1**：帶使用者在 AdMob 後台建立「原生進階」廣告單元，取得 ID；寫進本機 `secrets/ads_defines.json` 的 `ADMOB_NATIVE_UNIT_ID`，並用 `gh secret set ADMOB_NATIVE_UNIT_ID` 設定（不印出內容）。
- [ ] **Step 2**：除錯版在模擬器（繁中、深色與淺色）放入資料，三個位置逐一截圖：調整 `kNativeSmallHeight`／`kNativeMediumHeight` 讓模板下方不留空白、內容不被截斷；手機直向、橫向、平板寬度都看過；確認沒有同時出現兩張原生廣告。
- [ ] **Step 3**：照移植筆記 #35，用與 AAB 相同參數建正式版 APK，在模擬器啟動並捲到三個位置，`adb logcat -b crash` 為空。
- [ ] **Step 4**：`fvm dart format lib/ test/`、`fvm flutter analyze`、`fvm flutter test` 全綠後提交高度調整（若有）：`fix(ads): fit native ad heights to the template content`。
