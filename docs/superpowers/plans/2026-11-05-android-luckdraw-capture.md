# 喚取立繪擷取跨平台化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 `flutter_inappwebview` 的 `HeadlessInAppWebView` 取代 `webview_windows`＋隱藏宿主元件，讓 Android 與 Windows 共用同一套喚取立繪擷取。

**Architecture:** `LuckdrawCaptureService` 自行延遲建立並重用一個 headless webview（不再需要 UI 宿主）；擷取 JS 與分塊讀回流程原樣沿用。Windows 以 CDP 設 deviceScaleFactor 提升 canvas 解析度，Android 依裝置 dpr 調整 viewport。

**Tech Stack:** Flutter 3.47.5（FVM）、`flutter_inappwebview` 6.2.0-beta.3、Riverpod

**Spec:** `docs/superpowers/specs/2026-11-05-android-luckdraw-capture-design.md`

## Global Constraints

- `flutter_inappwebview` 版本釘死 `6.2.0-beta.3`（不用 `^`）；移除 `webview_windows`。
- `LuckdrawCaptureService.capture({resourceId, kind, lang, force})` 與 `cacheFileFor` 介面不變；`luckdrawCaptureServiceProvider` 建構方式不變。
- 延遲初始化：首次 `capture` 未命中快取時才建立 webview；建立失敗只試一次，之後一律回 null。
- 畫質：canvas 寬 ≥ 1422，目標約 1600 px。
- log 一律英文、Logger `gacha.luckdraw.capture`；新宣告都有 `///` dartdoc；註解中文全形。
- 每次 commit 前 `fvm dart format lib/ test/`、`fvm flutter analyze`、`fvm flutter test` 全綠；commit 帶 session 的 Co-Authored-By／Claude-Session 兩行。
- 測試機：`adb -d`（ASUS AI2501、Android 16）；Windows 為本機。

## Review Focus

1. **webview 建立失敗（測試環境無平台實作／Windows 缺 WebView2）**：`capture` 回 null、不拋例外、只嘗試一次 → Task 1 Step 1 測試。
2. **同時觸發多次擷取**（快速切換角色）：不可重複建立 webview、擷取序列化 → Task 1 沿用 `Lock`，Step 1 測試「並發兩次只建立一次」。
3. **擷取逾時或頁面無 canvas**：回 null、導回 `about:blank`、下次仍可擷取 → 實機 Task 2 Step 3。
4. **App 結束／provider dispose**：headless webview 要釋放 → Task 1 Step 3（provider `onDispose`）。
5. **舊 Windows 快取**：既有 1422 版快取照常顯示、不被覆寫 → Task 2 Step 4。

---

### Task 1: 以 headless webview 改寫擷取服務並移除宿主

**Files:**
- Modify: `pubspec.yaml`（移除 `webview_windows`、新增 `flutter_inappwebview: 6.2.0-beta.3`）
- Modify: `lib/services/luckdraw_capture_service.dart`
- Modify: `lib/state/luckdraw_capture.dart`（`ref.onDispose(service.dispose)`）
- Delete: `lib/widgets/luckdraw_capture_host.dart`
- Modify: `lib/main.dart`（移除 host import 與 `builder` 內的 `Stack`）
- Modify: `windows/CMakeLists.txt`、`scripts/build_installer/build_release.ps1`（移除只為 `webview_windows` 存在的 workaround，見 Step 5）
- Test: `test/services/luckdraw_capture_service_test.dart`

**Interfaces:**
- Produces:
  - `LuckdrawCaptureService({required Directory cacheDir, Duration timeout = const Duration(seconds: 30), Future<LuckdrawWebEngine?> Function()? engineFactory})`
  - `abstract interface class LuckdrawWebEngine { Future<void> loadUrl(String url); Future<dynamic> evaluate(String js); Future<void> dispose(); }`（擷取所需的最小 webview 操作，供測試注入假實作）
  - `Future<void> dispose()`（釋放 engine）
  - 預設 `engineFactory` 建立 `HeadlessInAppWebView` 包裝成 `LuckdrawWebEngine`。

- [ ] **Step 1: 改寫測試（先紅）**
  - 移除「host 未就緒」測試，改為：
    - `engineFactory 回 null → capture 回 null，且第二次呼叫不再呼叫 factory`（計數 factory 呼叫次數 == 1）。
    - `engineFactory 丟例外 → capture 回 null、不拋出`。
    - `並發兩次 capture（不同 rid）→ factory 只呼叫一次`：假 engine 的 `evaluate` 對 probe 回 `capReady:false` 直到逾時（`timeout` 設 1 秒），兩次都回 null 且 factory 計數 1。
    - `成功路徑`：假 engine 的 probe 回 `{'hasCanvas':true,'capReady':true,'capLen':N}`，`window.__cap.substr` 依序回 `data:image/png;base64,<小 PNG 的 base64>` 的分塊 → 回傳檔存在、內容等於該 PNG bytes，且最後一次 `loadUrl` 是 `about:blank`。
  - 保留 cache hit、force、cacheFileFor 測試（force 測試改用回 null 的 factory）。
  - 執行 `fvm flutter test test/services/luckdraw_capture_service_test.dart`，預期編譯失敗或測試失敗。

- [ ] **Step 2: 實作服務**
  - probe 回傳改為 `JSON.stringify(...)` 字串，Dart 端 `jsonDecode`（`flutter_inappwebview` 對物件回傳在兩平台的型別不一致，字串最穩）；同時多回 `cw`、`ch`、`dpr`、`vw` 供 log。
  - 預設 engine：`HeadlessInAppWebView(initialSize: <依平台>, initialSettings: InAppWebViewSettings(javaScriptEnabled: true, transparentBackground: true))`，`run()` 後等 `onWebViewCreated`；Windows 上 `callDevToolsProtocolMethod('Emulation.setDeviceMetricsOverride', {width, height, deviceScaleFactor: 2.0, mobile: false})`。viewport：Windows 1400×1180；Android 寬 `(1600 / dpr / 0.775).clamp(600, 1400)`、高 = 寬 × 0.843（0.775 為實測 canvas CSS 寬／viewport 寬，於 Task 2 校準；dpr 取 `PlatformDispatcher.instance.views.first.devicePixelRatio`）。
  - 成功 log：`capture ok rid=… bytes=… ms=… canvas=<cw>x<ch> dpr=… vw=… url=<sanitized>`。
  - 移除 `registerInitializer`／`attachWebview`／`detachWebview`／`isReady`；新增 `dispose()`。

- [ ] **Step 3: provider 釋放與移除宿主**
  - `luckdrawCaptureServiceProvider` 加 `ref.onDispose(service.dispose)`。
  - 刪 `lib/widgets/luckdraw_capture_host.dart`；`main.dart` 的 `builder` 移除（不再需要 `Stack`），刪對應 import。

- [ ] **Step 4: 測試轉綠**：`fvm flutter test test/services/luckdraw_capture_service_test.dart` 全過。

- [ ] **Step 5: Windows 建置 workaround 清理**
  - `build_release.ps1` 的 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`（CL 注入）是為 `webview_windows` 存在：`flutter_inappwebview_windows` 不使用 `<experimental/coroutine>`（已 grep 確認），移除該段。
  - `windows/CMakeLists.txt` 的 `CMP0175` 設定：先移除，跑 `fvm flutter build windows`；若出現 CMP0175 警告（`flutter_inappwebview_windows` 也有 `add_custom_command`），則保留並把註解改成指向新外掛。
  - Expected：`fvm flutter build windows` 成功；`fvm flutter build apk --debug` 成功。

- [ ] **Step 6: 全套檢查並 commit**
```bash
git add pubspec.yaml pubspec.lock lib/ test/ windows/ scripts/
git commit -m "feat(luckdraw): capture convene art with a headless webview on Android and Windows"
```

---

### Task 2: 實機校準與驗收

- [ ] **Step 1: Android 實機**：`flutter clean` 後建置安裝，打開角色 1508（或任一有喚取的角色）詳情 → 「喚取」頁籤出現且顯示立繪；從 log（`run-as ... cat files/logs/*.log`）讀 `canvas=` 寬度，須 ≥ 1422、目標 ~1600。不符時調整 Task 1 的 Android viewport 係數並重測，再 commit。
- [ ] **Step 2: Windows 實機**：`fvm flutter run -d windows`，同一流程；`canvas=` ≥ 1422。對既有已快取角色按「重抓」→ 新檔畫質提升。
- [ ] **Step 3: 失敗路徑**：Android 開飛航模式後對未快取角色開詳情 → 無「喚取」頁籤、不崩潰；恢復網路後再開另一角色可正常擷取（webview 未被弄壞）。
- [ ] **Step 4: 舊快取**：Windows 上原本已有喚取快取的角色，開詳情直接顯示（不重抓）。
- [ ] **Step 5: 延遲初始化**：Windows 啟動 App、不開任何角色詳情，工作管理員中不出現 `msedgewebview2.exe` 子行程（屬本 App）。
- [ ] **Step 6: CI 的 NuGet**：查 `.github/workflows/release-windows.yml` 的 runner 是否有 `nuget`；若無，加安裝步驟（例如 `nuget/setup-nuget`）。
- [ ] **Step 7: 文件**：`docs/Android移植筆記.md` 喚取段落補上正式實作的參數（viewport、dpr 策略）、版本釘死與替換方式。
- [ ] **Step 8: 全套檢查並 commit**（若有修正）。
