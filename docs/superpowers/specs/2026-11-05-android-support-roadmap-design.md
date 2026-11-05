# Android 版支援 — 總體路線圖與可行性結論

- 狀態：方向已核准（2026-11-05），各子專案另立設計文件
- 日期：2026-11-05
- 範圍：這份文件記錄「為什麼做、做成什麼樣子、怎麼拆」，以及實機實驗驗證過的事實。各子專案的細節寫在各自的設計文件。

---

## 一、目的與動機

服務**只玩手機、沒有 PC 的鳴潮玩家**。目前 App 只有 Windows 版，這群玩家完全無法使用。

**目標**

- Android 版要提供**跟 PC 版相同的全部功能**。PC 版的實作不能沿用時，另外找做法：優先選**能跨平台共用**的實作，其次才是依平台判斷走不同流程。
- 上架 **Google Play**。

**非目標**

- iOS（沒有讀取其他 App log 的途徑）。
- 國服（與 PC 版一致，只支援國際服）。

**反目標**

- 在背景偷偷讀取，或在使用者不知情的情況下取得權限。每一步都要讓玩家知道、由玩家觸發。
- 為了 Android 改壞 Windows 版既有的流程或 UX。

## 二、取得喚取紀錄的方式（實機驗證，2026-11-05）

測試機：ASUS AI2501、Android 16、國際服 `com.kurogame.wutheringwaves.global`。實驗程式只放在 session scratchpad，沒有進 repo。

### 2.1 攔截不可行

遊戲的 WebView 不信任使用者安裝的 CA，沒有 root 就不能做 MITM。PC 版的攔截做法在 Android 上整條不適用。

### 2.2 讀 log 可行，關鍵在「用什麼身分讀」

- 遊戲 log 在 `/sdcard/Android/data/com.kurogame.wutheringwaves.global/files/UE4Game/Client/Client/Saved/Logs/Client.log`，會輪替成 `Client-backup-*.log`。
- **XOR 混淆跟 PC 版完全相同**，`decodeClientLogBytes`、`findConveneUrls`、`GachaCredential.fromConveneUrl` 都可以直接沿用。
- 開喚取記錄後，喚取 URL 會出現在兩個地方：解碼後的 `Client.log`，以及系統 logcat（tag `KUROSDK`，`openWebView`／`krsdk.KRWebView loadUrl`）。URL 格式跟 PC 版一樣，只差在 `platform=Android`。
- 用這個 URL 組出的憑證，打既有的 `gmserver-api.aki-game2.net/gacha/record/query` 回傳 `code=0`（角色池 690 筆）。
- Android 11 起，一般 App 讀不到其他 App 的 `Android/data`，所以需要更高的權限，有兩條路：

**A. root（優先）**：執行 `su -c cat <路徑>`。不用配對、不用 Wi-Fi。測試機沒有 root，**這條路還沒在實機驗證**。

**B. 無線偵錯自我配對（沒有 root 時）**：
- `flutter_adb` 1.0.0（純 Dart、BSD-3-Clause）可以在 App 內用配對碼跟 `127.0.0.1` 配對，再連線取得 `uid=2000(shell)`（群組包含 `log`、`ext_data_rw`）。✅ 實機成功。
- 配對碼視窗一離開設定頁就會關閉，所以第一次配對需要分割畫面（或做類似 Shizuku 的通知回覆輸入）。
- Wi-Fi 一斷，無線偵錯就會被系統自動關掉；連回同一個 Wi-Fi 也不會恢復，而且連線埠會換。**金鑰會保留，不用重新配對。**
- **一鍵恢復**：第一次連上 shell 時執行 `pm grant <App> android.permission.WRITE_SECURE_SETTINGS` 授權給自己。之後 App 自己寫 `adb_wifi_enabled=1` 打開無線偵錯，再用 NsdManager 找到 `_adb-tls-connect._tcp` 的連線埠。✅ 斷過 Wi-Fi 後冷啟動，1.2 秒取得 shell。
- 完全沒有 Wi-Fi 時不可行：系統會立刻把設定關回去。
- 尚未驗證：重開機之後、手機熱點、其他廠牌的 ROM。

**決定**：App 會把 `WRITE_SECURE_SETTINGS` 授權給自己（使用者已同意這個取捨）。防護措施（細節在子專案 2）：私鑰用 `flutter_secure_storage` 加密保存；用完立刻斷線並關閉無線偵錯；只執行白名單內的固定指令；第一次配對前先顯示揭露說明頁，並提供解除配對的入口。

**C. 手動輸入網址（兩個平台共用的備援）**：讓使用者貼上喚取記錄網址，交給 `GachaCredential.fromConveneUrl` 解析。給沒有 root、沒有 Wi-Fi，或手機版本太舊不支援無線偵錯的人用。PC 版目前沒有這個入口，會在子專案 2 一起加上，兩個平台共用。

**D. Android 10 以下直接讀（推論，尚未驗證）**：Android 10 以下沒有 Android 11 的 `Android/data` 限制。取得儲存權限（Android 10 需要 `requestLegacyExternalStorage`）後，App 應該能直接讀 `Client.log`，不需要 root 也不需要 ADB。在子專案 2 驗證。

**minSdk**：沿用 Flutter 預設（24）。使用者決定不因為無線偵錯從 Android 11 才有，就排除舊版本。

**授權限制**：Ascent 是 AGPL 授權，本專案是 MIT，只能參考公開事實，不能抄它的程式碼。

### 2.3 Google Play 的風險（推論，沒有實際送審過）

- Play 上已經有同類的自我配對 ADB 工具 App 在架。
- Device and Network Abuse 政策禁止「未經授權存取其他 App」。我們的處理方式是：由使用者主動觸發、事前清楚揭露、只讀鳴潮的 log。
- `WRITE_SECURE_SETTINGS` 可能讓 Play 顯示的相容裝置數變少，審核時也可能被要求說明用途。
- 送審時要附上審核說明，教審核員怎麼開啟無線偵錯；Data safety 表單照實填寫。

## 三、子專案拆分與順序

一次做一個子專案，每個各自走一次「設計 → 計畫 → 實作」。

| # | 子專案 | 共用／分流 |
|---|---|---|
| 1 | Android 平台基礎（能建置、能啟動） | 依平台分流 |
| 6 | **喚取立繪實驗**（提前做，因為是唯一還不確定能不能做到的項目） | 評估 `flutter_inappwebview` 是否能讓 Windows 和 Android 共用 |
| 2 | 手機取得紀錄（root、無線偵錯、Android 10 以下直接讀；加上兩個平台共用的手動輸入網址） | 解碼、解析、抓資料共用，只有取得權限分流 |
| 3 | 手機版面（底部導覽、標題列溢出、表格、長按選單） | 共用，依螢幕寬度切換 |
| 4 | 檔案存取與分享（另存新檔、分享 log、剪貼簿） | 盡量換成跨平台套件 |
| 5 | 雲端同步登入（Android 用 Android 的 OAuth 用戶端） | 登入分流，Drive 同步本體共用 |
| 7 | Play 上架與更新（`in_app_update`、Play 版不檢查 GitHub、AAB、簽章、CI、上架文件） | 依平台分流 |

順序：**1 → 6 的實驗 → 2 → 3 → 4 → 5 → 7**。期間可以用 Play 的內部測試軌道，邊做邊發測試版。

## 四、身分

- Android applicationId：**`tw.reh.wuwa.gacha`**（使用者 2026-11-05 選定，上架後不能改）。之後如果出原神版，沿用同樣的規則：`tw.reh.genshin.gacha`。
