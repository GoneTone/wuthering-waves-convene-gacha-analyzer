# 喚取立繪擷取跨平台化（子專案 6）— 設計 spec

- 狀態：待核准
- 日期：2026-11-05
- 上層文件：`2026-11-05-android-support-roadmap-design.md`
- 前作：`2026-06-05-luckdraw-convene-art-design.md`（Windows 版的原始設計）

---

## 一、目的

讓 Android 版也能顯示角色的「喚取」立繪（encore 頁面上的 Spine 動畫，擷取成靜態 PNG 並快取）。依照「優先跨平台共用」的原則，Windows 和 Android 共用同一套擷取實作。

## 二、目標／非目標／反目標

**目標**

- Android 和 Windows 都能擷取喚取立繪，並沿用既有的快取、詳情對話框「喚取」頁籤、手動「重抓」流程，下游完全不用改。
- 兩個平台共用同一個 `LuckdrawCaptureService` 實作，不依平台分流。
- 擷取出來的畫質不低於現行 Windows 版（canvas 1422×1185）。

**非目標**

- 動態立繪（動態 WebP）。2026-06-09 已評估後放棄，這次不重提。
- 強制重抓既有快取。Windows 使用者已經快取的舊立繪維持原樣，想要更清晰的版本可以用既有的「重抓」或「清除立繪快取」。

**反目標**

- Windows 版的喚取立繪變得比現在模糊，或者擷取變慢到使用者感覺得出來。
- 從來不看喚取立繪的使用者，一開 App 就多跑一個常駐的 WebView 行程（現行的延遲初始化要保留）。

## 三、做法

### 3.1 考慮過的做法（使用者已選 A）

| 做法 | 取捨 |
|---|---|
| **A. 兩個平台都改用 `flutter_inappwebview` 6.2.0-beta.3 的 `HeadlessInAppWebView`** | 一套實作、不需要藏 UI 的技巧。Windows 可以用 CDP 調高像素比，拿到更清晰的圖。風險：這是 beta 版，穩定版 6.1.5 從 2024-10 就沒更新，而且在 AGP 9 上編不過 |
| B. Android 用官方的 `webview_flutter`，Windows 維持 `webview_windows` | Android 用的是官方套件；但要維護兩套實作，`webview_flutter` 沒有 headless 模式，而 `webview_windows` 本身也從 2024-02 就沒再更新 |

選 A 的理由：擷取邏輯原本就獨立包在 `LuckdrawCaptureService` 裡，萬一 `flutter_inappwebview` 停止維護，要換掉的範圍也只有這個服務；B 在 Windows 上靠的套件也一樣沒人維護。

### 3.2 實驗已驗證的事實（2026-11-05，角色 1508）

- `HeadlessInAppWebView` 在 Android（ASUS、Android 16）和 Windows 上 `requestAnimationFrame` 都不會停，沿用現行的 JS（輪詢 → 武裝 → 在 rAF 內 `toDataURL` → 用 `evaluateJavascript` 分塊讀回）就能擷取成功，透明背景也保留。
- 熱啟動耗時：Android 約 1.1 秒、Windows 約 1.4～1.7 秒；首次約 3～4 秒。
- **canvas 解析度＝頁面上 canvas 的 CSS 寬度 × 裝置像素比（dpr）。** CSS 寬度在 viewport 夠寬之後就不會再變。實測數據：

| 平台 | viewport（邏輯尺寸） | dpr | canvas |
|---|---|---|---|
| Windows | 2000～3200 寬 | 1 | 1246×1038（加寬也不會變大） |
| Windows | 1400×1180 | 2（CDP） | 1624×1354 |
| Windows | 1000×840 | 2（CDP） | 1176×980 |
| Android | 700×590 | 2.625（手機本身） | 1423×1187 |

- Windows 用 `callDevToolsProtocolMethod('Emulation.setDeviceMetricsOverride', {width, height, deviceScaleFactor, mobile: false})` 設定 dpr，設完要 reload 頁面才會套用。Android WebView 沒有 CDP，只能用手機本身的 dpr。

### 3.3 改動

1. **依賴**：移除 `webview_windows`，新增 `flutter_inappwebview: 6.2.0-beta.3`（釘死版本，不用 `^`）。
2. **`LuckdrawCaptureService`**：自己管理一個延遲建立、可重複使用的 `HeadlessInAppWebView`。第一次擷取時才 `run()`，之後重複使用；擷取完導回 `about:blank`（和現行一樣）。對外介面 `capture({resourceId, kind, lang, force})` 和 `cacheFileFor` 完全不變。原本給宿主元件用的 `registerInitializer`、`attachWebview`、`detachWebview` 都移除。
3. **移除 `LuckdrawCaptureHost`**（`lib/widgets/luckdraw_capture_host.dart`），以及 `main.dart` 裡 `MaterialApp.builder` 中為了它而存在的 `Stack`。headless 不需要掛在 UI 上。
4. **畫質**：兩個平台都固定使用 1400×1180 的 viewport，Windows 再用 CDP 設 `deviceScaleFactor: 2`。（2026-11-05 實作時實機校準後更正：canvas CSS 寬度會依 encore 版面斷點階梯式變化，原本「依 dpr 反推寬度」的做法不成立；1400 是最大的一階，Windows 約 1624、Android 約 1644～2877 px，都高於 1422 的底線。）
5. **環境不支援的時候**：Windows 缺少 WebView2 runtime，或 Android 的系統 WebView 無法使用時，`capture` 回傳 `null` 並記一筆 warning，「喚取」頁籤就不顯示。這和現行行為一致，只嘗試一次，不反覆重試。
6. **log**：沿用 `gacha.luckdraw.capture`，記錄平台、viewport、dpr、canvas 尺寸、耗時。

### 3.4 不需要改的部分

- 快取路徑和檔名（`itemLuckdrawCacheFile`）、詳情對話框、喚取頁籤、重抓按鈕、清除立繪快取。
- Windows 安裝檔附帶的 WebView2 Evergreen Bootstrapper 照舊保留，`flutter_inappwebview` 一樣需要 WebView2 runtime。

## 四、驗收條件

1. Android 實機：打開一個有喚取立繪的角色詳情，「喚取」頁籤會出現並顯示立繪，canvas 寬度 ≥ 1422。
2. Windows：同一個流程正常運作，畫質 ≥ 1422 寬；舊的快取照常顯示；按「重抓」可以拿到新的畫質。
3. 從來不開喚取立繪的情況下，啟動 App 不會建立 WebView 行程。
4. Windows 缺少 WebView2 runtime 時，詳情對話框正常，只是沒有「喚取」頁籤，不會崩潰（用模擬的方式驗證）。
5. `fvm dart format`、`fvm flutter analyze`、`fvm flutter test` 全部通過；Windows 和 Android 都能建置。

## 五、風險與留給實作的部分

- **beta 套件的維護風險**：已接受。要在 `docs/Android移植筆記.md` 記錄版本和替換方式。
- **Windows 建置需要 NuGet**：`flutter_inappwebview_windows` 會在建置時用 NuGet 下載 WebView2 SDK。開發機已經安裝；CI（`release-windows.yml`，`windows-latest`）的 runner 有沒有 NuGet，要在實作時確認。如果沒有，就在 workflow 加一個安裝步驟。
- **Windows 路徑長度**：`flutter_inappwebview_windows` 在很深的路徑會建置失敗（見移植筆記第 9 點）。專案目前的路徑沒問題，但 CI 的工作目錄要留意。
- **既有的單元測試**（`test/services/luckdraw_capture_service_test.dart`）要跟著新的介面調整；需要真的 WebView 才能測的部分，靠實機驗收。
