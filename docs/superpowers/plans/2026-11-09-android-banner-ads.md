# Android 底部橫幅廣告 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Android 版在有內容的頁面底部顯示一則 AdMob 自適應橫幅，含歐盟／美國州的同意流程，廣告 ID 於建置時注入。

**Architecture:** 廣告 ID 比照雲端同步憑證以 `--dart-define-from-file=secrets/ads_defines.json` 注入（Dart 讀 banner 單元 ID，Gradle 從 `dart-defines` 屬性讀應用程式 ID 寫進 manifest placeholder），缺值或非 release 一律用官方測試 ID。同意與 SDK 初始化包在可替換的 `AdsPlatform` 後面，由 `AdsController`（Riverpod Notifier）管理狀態；外框 `AppShell` 依「目前頁面有沒有內容」決定是否插入 `BannerAdSlot`，並把底部狀態列與廣告一起移到 `Scaffold.bottomNavigationBar`，讓 SnackBar 自動浮在它們上方。

**Tech Stack:** Flutter 3.47.5（fvm）、Riverpod 3、go_router、`google_mobile_ads`（內含 UMP）、Kotlin DSL Gradle、GitHub Actions。

**Spec:** `docs/superpowers/specs/2026-11-09-android-banner-ads-design.md`

## Global Constraints

- 只在 Android 載入與顯示廣告；`isAndroidProvider` 為 false 時不得呼叫任何 `google_mobile_ads` API。
- 非 release 建置（`kReleaseMode == false`，以及 Gradle 的 debug／profile buildType）一律用官方測試 ID；release 且有注入值才用正式 ID。
- 官方測試應用程式 ID：`ca-app-pub-3940256099942544~3347511713`；Android 自適應橫幅測試單元 ID：`ca-app-pub-3940256099942544/9214589741`（實作時對照 https://developers.google.com/admob/android/test-ads 確認）。
- 注入鍵名：`ADMOB_APP_ID`、`ADMOB_BANNER_UNIT_ID`；本機檔 `secrets/ads_defines.json`（`/secrets/` 已在 `.gitignore`）。
- `RequestConfiguration(maxAdContentRating: MaxAdContentRating.t)`。
- 同意以 UMP `canRequestAds()` 為準；尚未表態時不請求廣告。
- 不放廣告：`LogAccessSetupPage`、所有對話框、沒有內容的頁面、手機排版開著鍵盤時。
- 版面：手機直向在底部狀態列上方並加分隔線；手機橫向在最底部（沒有狀態列）；非手機排版只佔內容欄寬度（不延伸到側欄下方），與狀態列之間至少 `AppSpacing.l` 間隔加分隔線。
- 廣告載入失敗、尚未取得同意時：完全收起，不留空白。
- log 一律 `Logger('ads')`，英文、帶錯誤碼；不記錄完整廣告單元 ID。
- 新 UI 字串改核心四語 ARB 並補齊其餘 27 語（使用者偏好 31 語一起翻）。
- commit 用英文 conventional commits；提交前 `fvm dart format lib/ test/`、`fvm flutter analyze`、`fvm flutter test` 全綠；不 push。

## Review Focus

1. **release 建置沒有注入 ID**（別人 fork 編譯、CI secrets 未設）→ 必須用測試 ID、不可閃退。測試：Task 1 的 `resolveBannerUnitId` 與 Gradle 驗證步驟。
2. **轉向或分割畫面讓寬度改變** → 橫幅要依新寬度重新載入，不可溢出。測試：Task 4 `reloads when the width changes`。
3. **沒網路／載入失敗** → 收起，不留 50dp 空白。測試：Task 4 `collapses when loading fails`。
4. **同意查詢失敗或使用者尚未表態** → 不請求廣告、不初始化廣告請求。測試：Task 2 `consent error leaves ads disabled`。
5. **停在卡池頁時切到沒有資料的帳號** → 廣告要立刻消失。測試：Task 3 矩陣＋Task 4 `hides the ad when the active account has no records`。

---

### Task 1: 廣告 ID 注入（Dart、Gradle、Manifest、CI）

**Files:**
- Modify: `pubspec.yaml`（`fvm flutter pub add google_mobile_ads`，取與 Flutter 3.47.5 相容的最新穩定版）
- Create: `lib/services/ads/ad_config.dart`
- Modify: `android/app/build.gradle.kts`、`android/app/src/main/AndroidManifest.xml`
- Modify: `.github/workflows/release.yml`（Android job 的 defines 步驟）
- Modify: `README.md`、`README_EN.md`、`README_JA-JP.md`、`README_ZH-CN.md`（開發者設定段落，比照 cloud_sync_defines 說明）
- Test: `test/services/ads/ad_config_test.dart`

**Interfaces:**
- Produces: `const String kTestAdmobBannerUnitId`；`String resolveBannerUnitId({required bool release, required String injected})`；`String get admobBannerUnitId`（= `resolveBannerUnitId(release: kReleaseMode, injected: String.fromEnvironment('ADMOB_BANNER_UNIT_ID'))`）。

- [ ] **Step 1: 寫失敗測試** `ad_config_test.dart`：
  - `resolveBannerUnitId(release: true, injected: 'ca-app-pub-1/2')` == `'ca-app-pub-1/2'`
  - `resolveBannerUnitId(release: true, injected: '')` == `kTestAdmobBannerUnitId`
  - `resolveBannerUnitId(release: false, injected: 'ca-app-pub-1/2')` == `kTestAdmobBannerUnitId`
- [ ] **Step 2:** `fvm flutter test test/services/ads/ad_config_test.dart` → FAIL（未定義）。
- [ ] **Step 3:** 實作 `ad_config.dart`（dartdoc 說明為何不寫死：開源專案、無效流量風險）。
- [ ] **Step 4:** 測試 PASS。
- [ ] **Step 5: Gradle 與 Manifest**：`defaultConfig` 設 `manifestPlaceholders["admobAppId"] = "ca-app-pub-3940256099942544~3347511713"`；`release` buildType 解析 `project.findProperty("dart-defines")`（逗號分隔、每段 base64 的 `KEY=VALUE`），找到非空 `ADMOB_APP_ID` 時覆寫 placeholder。Manifest `<application>` 內加 `<meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" android:value="${admobAppId}"/>`。
- [ ] **Step 6: 驗證注入**（需要時暫建 `secrets/ads_defines.json`，值用假的 `ca-app-pub-0000000000000000~1111111111` 與 `ca-app-pub-0000000000000000/2222222222`，驗完刪掉或換成使用者給的正式值）：
  - `fvm flutter build apk --release --dart-define-from-file=secrets/cloud_sync_defines.json --dart-define-from-file=secrets/ads_defines.json` → 成功（同時確認可以給兩個 `--dart-define-from-file`）。
  - 用 `$ANDROID_HOME/build-tools/<版本>/aapt2 dump xmltree --file AndroidManifest.xml build/app/outputs/flutter-apk/app-release.apk` 查 `APPLICATION_ID` 值 = 假的 App ID。
  - 不帶 ads defines 再建一次 release → 值 = 測試 App ID。`fvm flutter build apk --debug` → 值 = 測試 App ID。
  - 若 `dart-defines` 屬性不含 from-file 的值，改讓 Gradle 直接讀 `../../secrets/ads_defines.json`（JsonSlurper），並在計畫筆記中記下原因。
- [ ] **Step 7: CI**：`release.yml` Android job 新增「Write ads defines from secrets」步驟，比照 cloud sync：`ADMOB_APP_ID`／`ADMOB_BANNER_UNIT_ID` 兩個 secrets 都有才寫 `secrets/ads_defines.json` 並把 `--dart-define-from-file=secrets/ads_defines.json` 加進 build 參數；缺少時 `::warning::` 並照常建置（只會有測試廣告）。跑 actionlint（使用者已允許）。
- [ ] **Step 8: README ×4** 開發者段落補 `secrets/ads_defines.json` 範例與「沒有時只顯示測試廣告」；本機 `private/play-store/README.md` 的 rc 建置指令加第二個 `--dart-define-from-file`（本機檔，不進版控）。
- [ ] **Step 9:** format／analyze／test 全綠後 commit：`feat(ads): inject AdMob IDs at build time with test-ID fallback`。

### Task 2: 同意流程與 SDK 初始化

**Files:**
- Create: `lib/services/ads/ads_platform.dart`、`lib/state/ads.dart`
- Modify: `lib/pages/app_shell.dart`（`initState` 在 Android 呼叫 `start()`）
- Test: `test/state/ads_test.dart`

**Interfaces:**
- Produces:
  - `class AdsPlatform`：`Future<void> requestConsentUpdate()`（失敗時丟 `AdsConsentException(code, message)`）、`Future<void> loadAndShowConsentFormIfRequired()`、`Future<bool> canRequestAds()`、`Future<bool> isPrivacyOptionsRequired()`、`Future<void> showPrivacyOptionsForm()`、`Future<void> initializeSdk()`（`MobileAds.instance.initialize()` 後 `updateRequestConfiguration(RequestConfiguration(maxAdContentRating: MaxAdContentRating.t))`）。
  - `final adsPlatformProvider = Provider<AdsPlatform>(...)`
  - `class AdsState { final bool canRequestAds; final bool privacyOptionsRequired; }`（預設皆 false）
  - `class AdsController extends Notifier<AdsState>`：`Future<void> start()`（只執行一次）、`Future<void> showPrivacyOptions()`（表單關閉後重讀兩個旗標）。
  - `final adsProvider = NotifierProvider<AdsController, AdsState>(AdsController.new)`

- [ ] **Step 1: 寫失敗測試**（以 `_FakeAdsPlatform extends AdsPlatform` 記錄呼叫）：
  - `start enables ads after consent`：fake `canRequestAds` 回 true → `state.canRequestAds` 為 true，且 `initializeSdk` 被呼叫一次。
  - `consent error leaves ads disabled`：`requestConsentUpdate` 丟例外、`canRequestAds` 回 false → `state.canRequestAds` 為 false，`initializeSdk` 未呼叫。
  - `consent error still uses previous consent`：`requestConsentUpdate` 丟例外但 `canRequestAds` 回 true（上次已同意）→ `canRequestAds` 為 true（UMP 官方建議的行為）。
  - `start runs once`：連呼叫兩次 `start()`，`requestConsentUpdate` 只呼叫一次。
  - `privacy options flag follows the platform`：`isPrivacyOptionsRequired` 回 true → `state.privacyOptionsRequired` 為 true；`showPrivacyOptions()` 後 fake 改回 false → 狀態更新。
- [ ] **Step 2:** 測試 FAIL。
- [ ] **Step 3:** 實作。`AdsPlatform` 只是 UMP／MobileAds 的薄包裝（callback 轉 `Future`）。`AdsController.start` 的順序：`requestConsentUpdate` →（成功時）`loadAndShowConsentFormIfRequired` → `canRequestAds` → 為 true 才 `initializeSdk` → 讀 `isPrivacyOptionsRequired`。每個分支 `Logger('ads')`：`consent update failed code=… message=…`、`consent form error code=…`、`ads enabled canRequestAds=… privacyOptionsRequired=…`。
- [ ] **Step 4:** 測試 PASS。
- [ ] **Step 5:** `AppShell.initState` 在 `ref.read(isAndroidProvider)` 為 true 時 `unawaited(ref.read(adsProvider.notifier).start())`；既有 shell 測試若是 Android 情境，override `adsPlatformProvider` 為 fake。
- [ ] **Step 6:** 全綠後 commit：`feat(ads): gather consent and initialize the ads SDK`。

### Task 3: 哪些頁面放廣告

**Files:**
- Create: `lib/services/ads/ad_placement.dart`
- Test: `test/services/ads/ad_placement_test.dart`

**Interfaces:**
- Consumes: `GachaState`（`isBootstrapping`、`activeData`、`activeData.banners`）。
- Produces: `bool pageHasAdContent({required String path, required GachaState gacha})`。

- [ ] **Step 1: 寫失敗測試**（矩陣，每列一個 `test`）：
  - `/settings`、`/contributors` → true（不論資料）。
  - `/`：bootstrapping → false；`activeData == null` → false；所有卡池都空 → false；任一卡池有紀錄 → true。
  - `/banner/<有紀錄的 key>` → true；`/banner/<空的 key>` → false；bootstrapping 或 `activeData == null` → false。
  - 未知路徑（例如 `/foo`）→ false。
- [ ] **Step 2:** FAIL。 **Step 3:** 實作。 **Step 4:** PASS。
- [ ] **Step 5:** commit：`feat(ads): decide which pages may show an ad`。

### Task 4: 橫幅元件與外框版面

**Files:**
- Create: `lib/widgets/ads/banner_ad_slot.dart`
- Modify: `lib/pages/app_shell.dart`
- Test: `test/widgets/ads/banner_ad_slot_test.dart`、`test/pages/app_shell_test.dart`（或新增 `test/pages/app_shell_ads_test.dart`）

**Interfaces:**
- Consumes: `admobBannerUnitId`（Task 1）、`adsProvider`（Task 2）、`pageHasAdContent`（Task 3）。
- Produces:
  - `typedef BannerLoader = Future<Widget?> Function(int width)`：載入成功回傳可顯示的 widget（實際為固定尺寸的 `AdWidget`），失敗回傳 null。
  - `class BannerAdSlot extends StatefulWidget`：`const BannerAdSlot({super.key, required this.load})`；以 `LayoutBuilder` 取寬度，寬度（取整數）變了就重新呼叫 `load`，舊廣告 dispose；`load` 回 null 或尚未完成時畫 `SizedBox.shrink()`。
  - `final bannerLoaderProvider = Provider<BannerLoader>(...)`：正式實作用 `AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width)` 取尺寸、`BannerAd(adUnitId: admobBannerUnitId, ...)` 載入；成功記 `banner loaded width=… height=…`，失敗記 `banner failed code=… message=…`。

- [ ] **Step 1: 寫 `BannerAdSlot` 失敗測試**：
  - `collapses when loading fails`：`load` 回 null → slot 高度 0。
  - `shows the loaded banner`：`load` 回 `SizedBox(key: Key('fake-banner'), height: 50)` → 找到它、slot 高度 50。
  - `reloads when the width changes`：改 `tester.view.physicalSize` 寬度後，`load` 以新寬度再被呼叫一次。
- [ ] **Step 2:** FAIL。 **Step 3:** 實作 `banner_ad_slot.dart`。 **Step 4:** PASS。
- [ ] **Step 5: 寫外框失敗測試**（override `isAndroidProvider`、`adsProvider` 狀態、`bannerLoaderProvider` 回固定的 `fake-banner`，資料用既有 helper 灌入）：
  - `phone portrait puts the ad above the status bar`（412×915）：`fake-banner` 底邊 ≤ `shell-bottom-bar` 頂邊，兩者之間有 `Divider`。
  - `phone landscape puts the ad at the bottom`（915×412）：找到 `fake-banner`，且底邊貼齊內容區底部（沒有狀態列）。
  - `tablet keeps the ad in the content column`（1280×800、Android）：`fake-banner` 左邊 ≥ 側欄右邊；與 `shell-bottom-bar` 頂邊距離 ≥ `AppSpacing.l`。
  - `hides the ad on empty pages`：卡池頁無紀錄 → 找不到 `fake-banner`。
  - `hides the ad when the active account has no records`：在有資料的卡池頁切到空帳號 → `fake-banner` 消失。
  - `hides the ad when ads are not allowed`：`canRequestAds` false → 找不到。
  - `never shows ads off Android`：`isAndroidProvider` false → 找不到，且 `bannerLoaderProvider` 未被呼叫。
  - `hides the ad while the keyboard is open`（手機排版、`viewInsets.bottom > 0`）→ 找不到。
  - `snack bars float above the ad`：顯示一則 SnackBar → SnackBar 底邊 ≤ `fake-banner` 頂邊。
  - 三種尺寸都 `expect(tester.takeException(), isNull)`（無溢出）。
- [ ] **Step 6:** FAIL。
- [ ] **Step 7: 實作外框**：把現有 `shell-bottom-bar`（含其顯示條件與 SafeArea）連同廣告移到 `Scaffold.bottomNavigationBar` 的 `Column(mainAxisSize: MainAxisSize.min)`，順序為「廣告列 → 狀態列」。廣告列只有在 Android、`adsProvider.canRequestAds`、`pageHasAdContent(...)`、且非（手機排版且鍵盤開著）時才放；非手機排版時用 `Padding` 左側讓出側欄寬度並在底下留 `AppSpacing.l`；上方一條 `Divider(height: 1)`。手機橫向沒有狀態列，廣告列自己處理底部 `SafeArea`。
- [ ] **Step 8:** 新測試與既有 shell、手機版面測試（`test/pages/app_shell_test.dart`、`test/pages/phone_layout_pages_test.dart`）全部 PASS。
- [ ] **Step 9:** commit：`feat(ads): show an adaptive banner at the bottom of content pages`。

### Task 5: 設定頁「廣告隱私權選項」

**Files:**
- Modify: `lib/pages/settings_page.dart`（`_PrivacySection`）
- Modify: `lib/l10n/app_*.arb`（31 語）
- Test: `test/pages/settings_page_test.dart`（或既有設定頁測試檔）

**Interfaces:**
- Consumes: `adsProvider`（`privacyOptionsRequired`、`showPrivacyOptions()`）。
- Produces: ARB key `settingsAdPrivacyOptions`（按鈕文字，繁中「廣告隱私權選項」）與 `settingsAdPrivacyOptionsHint`（一句說明，繁中「變更是否同意顯示個人化廣告。」）。

- [ ] **Step 1: 寫失敗測試**：
  - `ad privacy options appear only when required`：Android＋`privacyOptionsRequired` true → 找到按鈕；false 或非 Android → 找不到。
  - `tapping ad privacy options opens the form`：點按鈕 → fake controller 的 `showPrivacyOptions` 被呼叫一次。
- [ ] **Step 2:** FAIL。
- [ ] **Step 3:** 實作：在 `_PrivacySection` 末端加 `OutlinedButton`（沿用該區塊既有按鈕樣式）與說明文字。核心四語 ARB 加字串與 `@` 說明，其餘 27 語沿用各語系「隱私權」「個人化廣告」的既有用詞翻譯，`fvm flutter gen-l10n` 無 untranslated 警告。
- [ ] **Step 4:** PASS，全綠後 commit：`feat(ads): add the ad privacy options entry to settings`。

### Task 6: 文件與政策內容

**Files:**
- Modify: `docs/privacy-policy.md`（中英）
- Modify: `private/play-store/data-safety.md`、`private/play-store/listing.md`（本機，不進版控）
- Modify: `docs/Android移植筆記.md`（新增一節）

- [ ] **Step 1:** 讀 Google 官方「Google Mobile Ads SDK 資料揭露」頁（https://developers.google.com/admob/android/privacy/play-data-disclosure），記下 SDK 收集的資料類型、用途、是否分享。
- [ ] **Step 2:** `docs/privacy-policy.md` 中英各新增「廣告」段落：Android 版使用 Google AdMob 顯示橫幅廣告；依 Step 1 列出收集的資料；歐盟／英國與美國部分州可在設定頁「廣告隱私權選項」變更同意；Windows 版沒有廣告。刪除或改寫原本「沒有廣告」的句子。
- [ ] **Step 3:** `data-safety.md` 依 Step 1 補廣告收集的資料列（用途「廣告或行銷」、是否分享），總覽題同步；`listing.md` 四語刪掉「沒有廣告」，改成「Android 版底部有一則小型橫幅廣告」的對應句。
- [ ] **Step 4:** 移植筆記新增「廣告」一節：為什麼只做底部橫幅、ID 注入與測試 ID 退路、SnackBar 為何移到 `bottomNavigationBar`、Play Console 待辦（廣告聲明改「含廣告」、資料安全、`AD_ID` 用途、商店頁開發人員網站填 `https://reh.tw`、AdMob 後台封鎖博弈類別與兩種隱私訊息）；並註明 AdMob 新 App 要等 Play 商店頁公開、在 AdMob 連結商店頁並通過審查後才會正常投放，**內部測試版看不到正式廣告是正常的**（開發版用測試廣告不受影響），正式上架後要回 AdMob 連結商店頁。
- [ ] **Step 5:** commit（只含 repo 內檔案）：`docs(ads): update the privacy policy and porting notes for ads`。

### Task 7: 模擬器實機驗證

- [ ] **Step 1:** `fvm flutter build apk --debug` 並以 `adb -s emulator-5554 install -r --user 0` 安裝；匯入有資料的備份或在模擬器上更新資料。
- [ ] **Step 2:** 直向、橫向各截圖：綜合、卡池、設定、貢獻者頁底部出現「Test Ad」橫幅；空卡池頁沒有；`logcat` 有 `banner loaded`。
- [ ] **Step 3:** 關掉模擬器網路重開 App → 底部沒有空白；`logcat` 有 `banner failed`。
- [ ] **Step 4:** 在本機暫時加 `ConsentDebugSettings(debugGeography: DebugGeography.debugGeographyEea, testIdentifiers: [...])`（**不提交**）確認同意視窗出現、設定頁出現「廣告隱私權選項」且能開啟表單；驗完還原。
- [ ] **Step 5:** 把截圖給使用者確認版面；結果寫進移植筆記並 commit：`docs(ads): record emulator verification`。
