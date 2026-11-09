# Android 取得喚取記錄（子專案 2）— 設計 spec

- 狀態：已核准（2026-11-06）
- 日期：2026-11-06
- 上層文件：`2026-11-05-android-support-roadmap-design.md`（第二節「取得憑證」與第三節子專案 2）
- 相關前作：`2026-11-01-client-log-credential-fallback-design.md`（電腦版的 Client.log 監看）

---

## 一、目的

讓只用手機或平板、沒有電腦的玩家，在 Android 版按下「更新資料」後也能取得喚取記錄網址，接著沿用既有的抓資料流程。電腦版同時多一個「手動輸入喚取記錄」的入口，兩個平台共用。

Android 無法攔截網路（遊戲的 WebView 不信任使用者自行安裝的 CA），所以 Android 只能讀遊戲寫出的 `Client.log`。差別只在「用什麼身分讀」：root、無線偵錯自己連自己、Android 10 以下直接讀。

## 二、目標／非目標／反目標

**目標**

- Android 按「更新資料」後的體驗跟電腦版一致：先按更新，再去遊戲開「喚取記錄」，App 偵測到網址就自動開始抓。
- 讀取方式由 App 自動選擇，玩家不用懂 root 或 ADB。
- 無線偵錯配對只需做一次；之後每次更新都由 App 自己開啟無線偵錯並連線，玩家感覺不到。
- 兩個平台都能手動輸入：貼上網址（含整段錯誤訊息）或選擇 `Client.log` 檔案。
- 電腦版既有的攔截與 Client.log 監看行為完全不變。

**非目標**

- 讀系統記錄（logcat）。三種讀取身分都讀得到 `Client.log`，logcat 只有 root 和無線偵錯讀得到，不需要第二套來源。
- 國服、iOS、其他遊戲套件名稱。目前只支援國際服 `com.kurogame.wutheringwaves.global`（電腦版的網址比對也只認國際服網域）。
- 讓 App 在背景持續監看。玩家切去遊戲時 App 被系統暫停沒關係，切回來會補讀。
- 讓玩家手動選讀取方式的設定。

**反目標**

- 讀取鳴潮記錄檔以外的任何東西，或執行白名單以外的指令。
- 無線偵錯在用完後保持開啟（除非玩家原本就自己開著）。
- 第一次使用就卡在配對：配對流程對不熟開發人員選項的人也要走得完。
- 把帳號憑證寫進 log 或通知內容。

**用語**（使用者決定）：UI 文字一律稱「裝置」，不說「手機」，因為玩家也可能用平板。只有引用系統設定的實際名稱時例外（例如「關於手機」）。

## 三、做法

### 3.1 考慮過的做法

**配對時 App 在背景，要怎麼保持運作**（使用者已選 A）

| 做法 | 取捨 |
|---|---|
| **A. 配對期間開一個前景服務** | 跟 Shizuku 相同。服務負責找配對連接埠、顯示可輸入的通知、接收配對碼；真正配對由 Dart 的 `flutter_adb` 完成。代價是要寫 Kotlin，上架時要說明前景服務用途 |
| B. 不開服務，靠通知把 App 叫醒 | 程式碼少，但 Android 14 以後背景 App 約十秒就被凍結，能不能找到連接埠、收到輸入要看廠牌 |

**第一次配對怎麼輸入配對碼**（使用者已選通知列輸入）：系統的配對碼視窗一離開設定頁就會關閉，所以不採用「切回 App 輸入」或「教玩家開分割畫面」。

**Android 上的監看語意**（使用者要求跟電腦版一致）：只採用開始等待之後才寫進 log 的網址，不採用 log 裡舊的網址。

### 3.2 實機實驗結果（2026-11-06，ASUS AI2501、Android 16）

這些是設計依據，都已在實機上確認：

- **直接跳到「無線偵錯」頁**：送出 `android.service.quicksettings.action.QS_TILE_PREFERENCES` 給 `com.android.settings/.Settings$DevelopmentSettingsActivity`，並帶上 `Intent.EXTRA_COMPONENT_NAME = com.android.settings/.development.qstile.DevelopmentTiles$WirelessDebugging`，系統會直接開「無線偵錯」頁。這是快速設定磚長按的入口，不是公開保證的介面。
- **退路（Shizuku 的做法）**：開 `Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS`，帶 `":settings:fragment_args_key" = "toggle_adb_wireless"`，系統會捲到「無線偵錯」並標示出來。正式版在上面的 intent 也一併帶這個參數，系統不認得直接開頁時，至少會捲到正確位置。
- **前景服務用 `shortService`**（Android 14 起的短時間任務）：不需要額外權限，上限約 3 分鐘。配對碼通知用 `PendingIntent.getForegroundService` 接收回覆。App 在背景時，從找到配對連接埠到配對成功約 2 秒。
- **一鍵恢復**：首次連上後執行 `pm grant <套件> android.permission.WRITE_SECURE_SETTINGS`。之後 App 自己寫 `Settings.Global adb_wifi_enabled=1`，再用 NsdManager 找 `_adb-tls-connect._tcp` 的連接埠並連線，約 2.1 秒。**重開機後授權仍在**，一樣約 2.2 秒恢復。
- **NSD 會回傳已關閉的舊連接埠**：無線偵錯重新開啟後連接埠會換，但 NSD 結果裡舊的記錄還在，而且常排在前面。必須收集一小段時間內的所有結果，逐一嘗試連線，能連上的才算數。
- **緊接著開下一個 shell 串流會失敗**：前一個串流剛結束就立刻開下一個，`flutter_adb` 偶爾會回 `Stream open failed or refused by remote peer`；稍等再開就正常。正式版要讓指令排隊，失敗時延遲重試一次。
- **Client.log 約 10 MB**，所以每次只讀新增的部分。
- **飛航模式可以手動取得網址**：開飛航模式後進「喚取記錄」，頁面只顯示載入失敗，但長按可以全選複製出看不見的文字，內容是整段錯誤訊息，裡面含完整網址。所以貼上欄位要能從整段文字裡找出網址。

尚未驗證：其他廠牌的系統設定是否支援直接開頁、Android 10 以下直接讀檔、root（測試機沒有 root）。

## 四、整體流程

### 4.1 按下「更新資料」（Android）

沿用 `GachaRepository._runUpdate`：有可用的快取憑證就直接用，沒有才進入等待流程。等待流程在 Android 改走新的分支：

1. **決定讀取方式**（依序，第一個可用的就用）：
   1. **root**：系統上找得到 `su` 執行檔，而且 `su -c id` 回傳 `uid=0`。這一步會跳出 Magisk 等工具的授權詢問。找不到 `su` 執行檔時不呼叫，避免沒有 root 的裝置多等一次逾時。
   2. **Android 10 以下直接讀**：`Build.VERSION.SDK_INT <= 29`。沒有儲存權限時先請求。
   3. **無線偵錯**：Android 11 以上。
      - 沒有配對過：見下方「沒有自動讀取方式時」。
      - 沒有連 Wi‑Fi：同上，原因顯示「需要連上 Wi‑Fi」。
      - 已配對：寫 `adb_wifi_enabled=1` → NSD 收集連接埠 → 逐一連線。失敗時同上，原因顯示「連不上無線偵錯」，並提供「重新配對」。
   4. 都不可用（例如 Android 10 以下但拒絕了儲存權限）：同上，顯示對應原因。

   **沒有自動讀取方式時**（設計決定）：一樣進入等待畫面，但不顯示進度條，改顯示原因，並提供「手動輸入喚取記錄」與「設定讀取方式」（無線偵錯未配對時）兩個按鈕。這樣只能手動輸入的玩家，在第一次更新或網址失效需要重新取得時，都走同一個畫面，也不會每次都被帶去說明頁。說明頁只在玩家按「設定讀取方式」時開啟。

   **讀取方式要記下來**（設計決定）：上次成功使用的方式存在設定裡，設定頁據此顯示，下次更新也先試這個方式；失敗才重新依序判斷。這樣設定頁不用每次偵測 root（會跳授權詢問）。
2. **開始監看**：記下 `Client.log` 目前的長度當起點，進入等待畫面。
3. **玩家切去遊戲開喚取記錄，再切回來**：每秒輪詢一次，App 切回前景時立刻補讀一次。讀不到（連線斷了）就重連；無線偵錯被系統關掉時重新開啟。
4. **拿到網址**：停止監看並斷線，接著走既有的抓資料流程。無線偵錯的關閉規則（設計決定）：開始這次更新時無線偵錯已經是開著的，就維持開啟；否則一律關掉。第一次配對時玩家照引導打開的無線偵錯，算是 App 這次開的，所以會關掉，符合說明頁「讀完立刻關閉」的承諾；但按「開始設定」時就已經開著的，維持開啟（2026-11-09 補）。
5. **全池失敗**（記錄網址失效）：沿用既有的「重新取得一次」流程，等待畫面顯示「請重新開啟喚取記錄」。

### 4.2 監看實作：共用電腦版的監看程式

`lib/state/client_log_watch.dart` 的 `PollingClientLogWatch` 目前直接用 `File` 讀。把「讀檔」抽成介面，三種實作共用同一套比對位置、處理輪替、解碼、找網址的邏輯：

```dart
/// 提供 Client.log 的長度與指定範圍的原始位元組。
abstract interface class ClientLogSource {
  /// 檔案目前長度；檔案不存在時回 0。
  Future<int> length();

  /// 讀取 [offset] 起最多 [length] 個位元組。
  Future<Uint8List> read(int offset, int length);
}
```

- `LocalFileLogSource`：包住現有的 `File` 讀法。電腦版和 Android 10 以下使用，行為不變。
- `ShellLogSource`：透過一個「執行 shell 指令並回傳 stdout 位元組」的函式讀檔，root（`su -c`）和無線偵錯（`flutter_adb` 的 `shell:` 串流）共用。指令只有兩種，路徑是常數，只插入整數：
  - 長度：`stat -c %s '<路徑>'`
  - 讀取：`tail -c +<offset+1> '<路徑>' | head -c <length>`

`PollingClientLogWatch.start` 改收 `ClientLogSource`，現有呼叫端改成傳 `LocalFileLogSource(path)`。單次讀取量設上限（例如 2 MB），超過就分多輪讀，避免第一次補讀時一次拉太多。

### 4.3 手動輸入（兩個平台共用）

- **貼上網址**：輸入框接受任何文字，用既有的 `findConveneUrls` 找出網址，由新到舊交給 `GachaCredential.fromConveneUrl`，第一個合法的就用。找不到時在輸入框下方提示，不關閉對話框。
- **選擇 Client.log 檔案**：用既有的 `file_selector` 選檔，讀出位元組後用 `decodeClientLogBytes` 解碼，再用同樣的方式找最新的合法網址。Android 11 以上的系統選檔器進不了其他 App 的 `Android/data`，這個按鈕主要給從電腦或其他工具複製出檔案的人。
- **送出後**：
  - 正在等待時（等待畫面上點進來的）：直接完成這次等待，跟 log 命中走同一條路。電腦版會照既有的「log 先到」流程停掉攔截並等它收尾。
  - 不在等待時（從說明頁或 Wi‑Fi 提示點進來的）：用這個憑證啟動一次更新。
- 手動輸入的憑證跟其他來源一樣存成快取憑證。

### 4.4 等待畫面

沿用 `update_progress_dialog.dart` 的 `WaitingForCapture` 畫面：

- Android 標題用「等待喚取記錄...」（電腦版維持「等待攔截...」）。
- Android 新增「開啟鳴潮」按鈕：用 `getLaunchIntentForPackage` 開遊戲；沒有安裝時不顯示。需要在 manifest 加 `<queries>` 宣告遊戲套件。
- 兩個平台都新增「手動輸入喚取記錄」連結。
- Android 不顯示「已經開啟喚取記錄，卻一直沒有反應？」：它的用途是選遊戲資料夾，Android 上的位置是固定的。

## 五、無線偵錯的第一次設定

### 5.1 說明頁

按「更新資料」但還沒配對時開啟（第一次使用時；之後也能從設定頁進入）。內容：

- 為什麼需要：Android 不允許 App 直接讀其他遊戲的檔案，本 App 透過系統內建的「無線偵錯」讀取鳴潮的記錄檔。
- 本 App 會做什麼：只讀鳴潮的記錄檔；讀完立刻中斷並關閉無線偵錯；授權自己開關無線偵錯，之後不用再設定；可以隨時在設定頁解除。
- 需要：Android 11 以上、連上 Wi‑Fi、通知權限。
- 按鈕：「開始設定」、「改用手動輸入」。

這一頁同時是 Google Play 要求的「事前清楚揭露」。

### 5.2 配對引導頁

1. **確認開發人員選項**：讀 `Settings.Global.DEVELOPMENT_SETTINGS_ENABLED`。沒開時顯示教學：到系統設定的「關於」頁面（例如「關於手機」或「關於平板電腦」）連點版本號碼 7 次。開好了才顯示下一步。
2. **通知權限**：Android 13 以上請求 `POST_NOTIFICATIONS`。被拒絕時說明原因，並提供前往 App 通知設定的按鈕，不繼續。
3. **「前往無線偵錯」按鈕**：按下時才啟動配對服務並跳轉（第 3.2 節的兩段式 intent），讓約 3 分鐘的上限只用在真正配對那一段。
4. **等待配對**：頁面顯示「請在無線偵錯頁點『使用配對碼配對裝置』，再從頂端下拉，在本 App 的通知輸入配對碼」。
5. **配對成功**：服務通知改成「配對成功」，點了回到 App。App 接著連線、授權自己 `WRITE_SECURE_SETTINGS`，頁面顯示完成並自動返回。

**跟更新流程的關係**（設計決定）：從等待畫面按「設定讀取方式」時，先結束這次更新（跟按取消相同），再開說明頁。配對成功返回後自動重新呼叫一次 `update()`。網址失效重新取得的情況也一樣：第一池失敗時還沒有寫入任何資料（`abortOnFirstPoolFailure`），重新開始不會遺失進度。

### 5.3 配對服務（Kotlin）

- `shortService` 類型的前景服務，只在配對期間存在。
- 用 NsdManager 找 `_adb-tls-pairing._tcp`，只採用本機 IP 的結果（區網內可能有其他裝置也在配對）。
- 通知狀態：「正在尋找配對服務」→「已找到，請輸入配對碼」（附 RemoteInput 輸入框與「停止」按鈕）→「配對中...」→「配對成功」或「配對失敗，請重新輸入」。
- 收到配對碼後透過 MethodChannel 交給 Dart，由 `flutter_adb` 的 `AdbPairing.pair` 完成，再把結果傳回服務更新通知。配對碼不寫進 log。
- **Flutter engine 已被回收時**（設計決定）：前景服務讓行程存活，但 `MainActivity` 和它的 engine 在記憶體不足時仍可能被回收。這時通知改成「配對失敗，請回到 App 再試一次」，不另外為服務建立 engine。這種情況很少見，不值得讓 Kotlin 端複雜很多。
- **逾時**（設計決定）：服務自己計時 3 分鐘，所有 Android 版本行為一致。`shortService` 只在 Android 14 以上有作用，11 到 13 沒有系統上限，也不會呼叫 `onTimeout`；Android 14 以上另外覆寫 `onTimeout`，處理方式相同。時間到就停止服務，並把通知改成「配對逾時，點這裡重新開始」，點了回到配對引導頁。引導頁回到前景時，如果還沒配對成功、服務也不在了，就自動重新啟動服務。Shizuku 沒有處理這點，是我們額外補的。

### 5.4 金鑰與授權

- `flutter_adb` 的 RSA 金鑰用既有的 `flutter_secure_storage` 保存。
- 首次連上後授權自己 `WRITE_SECURE_SETTINGS`，之後一鍵恢復就不需要再操作系統設定。
- **授權失敗時**（使用者決定：教學＋手動開關模式）：部分廠牌的系統在開發人員選項裡有額外的安全性開關，沒開就不允許 `pm grant`，例如小米 HyperOS／MIUI 的「USB 偵錯（安全性設定）」、OPPO／realme ColorOS 的「停用權限監控」。其他廠牌也可能有類似限制，所以教學寫成通用說明，再舉這兩個例子。
  - 配對頁顯示教學，說明到開發人員選項找這類安全性開關，並提供「重試授權」。玩家不想開也可以「略過」，配對仍算完成。
  - 略過後的更新：無線偵錯關著、App 又沒有權限開啟時，顯示「請打開無線偵錯」對話框，附「前往無線偵錯」按鈕。App 回到前景時偵測到已開啟，就自動繼續連線。
  - 這個模式下 App 也沒有權限關閉無線偵錯，讀完只斷線，並在完成畫面提示玩家可自行關閉。
  - 每次連上 shell 時都檢查一次授權：玩家之後開了安全性選項，下次就自動補授權，回到一鍵模式。
  - 設定頁的配對狀態顯示「已配對（需手動開啟無線偵錯）」，並附「重試授權」。
- 設定頁「解除配對」：能連上時先用 shell 執行 `pm revoke <套件> android.permission.WRITE_SECURE_SETTINGS`，再刪除金鑰；連不上時只刪金鑰，並提示可以到系統的「無線偵錯 → 已配對的裝置」移除。

### 5.5 指令白名單

透過 shell（無線偵錯或 `su`）只會執行以下指令，全部寫成常數或只插入整數：

- `id`（確認身分）
- `stat -c %s '<Client.log 路徑>'`
- `tail -c +<n> '<Client.log 路徑>' | head -c <n>`
- `pm grant <本 App 套件> android.permission.WRITE_SECURE_SETTINGS`
- `pm revoke <本 App 套件> android.permission.WRITE_SECURE_SETTINGS`

`Client.log` 路徑：`/sdcard/Android/data/com.kurogame.wutheringwaves.global/files/UE4Game/Client/Client/Saved/Logs/Client.log`。

## 六、設定頁

Android 新增「讀取遊戲記錄」區塊（電腦版不顯示）：

- 讀取方式：root、直接讀取、無線偵錯，或「尚未設定」。
- 無線偵錯時顯示配對狀態，並提供「解除配對」（要確認）。
- 尚未設定時提供「設定」，開啟第五節的說明頁。

電腦版既有的「遊戲資料夾」區塊不變；Android 不顯示這個區塊。

## 七、原生程式（Kotlin）與權限

`MainActivity` 新增一個 MethodChannel（名稱例如 `tw.reh.wuwa.gacha/log_access`），提供：

- 讀寫 `adb_wifi_enabled`、讀 `development_settings_enabled`、取得 `SDK_INT`、目前是否連著 Wi‑Fi。
- NSD 收集 `_adb-tls-connect._tcp`：在約 2 秒內收集所有解析結果，只留本機 IP，回傳連接埠清單。
- 開「無線偵錯」頁（兩段式 intent）、開 App 通知設定、開遊戲。
- 啟動／停止配對服務；轉送配對碼與配對結果。
- 請求通知權限。

`AndroidManifest.xml` 新增：

- `WRITE_SECURE_SETTINGS`（`tools:ignore="ProtectedPermissions"`，由 shell 授權，不會出現在安裝時的權限請求）
- `POST_NOTIFICATIONS`、`FOREGROUND_SERVICE`
- `READ_EXTERNAL_STORAGE`（`android:maxSdkVersion="29"`），`<application android:requestLegacyExternalStorage="true">`
- 配對服務：`android:foregroundServiceType="shortService"`、`exported="false"`
- `<queries><package android:name="com.kurogame.wutheringwaves.global"/></queries>`

新增 Dart 依賴只有 `flutter_adb` 1.0.0（純 Dart、BSD-3-Clause）。版本、Wi‑Fi、權限都走自己的 MethodChannel，不另外引入 `device_info_plus`、`permission_handler` 等套件，因為這些資訊 Kotlin 端本來就要寫。

## 八、錯誤與邊界情況

| 情況 | 處理 |
|---|---|
| 沒有 Wi‑Fi（無線偵錯） | 不進等待，對話框說明並提供「手動輸入」 |
| 已配對但連不上（金鑰被系統移除、換了裝置） | 更新失敗並說明，提供「重新配對」與「手動輸入」 |
| 等待中切到背景、回來後連線已斷 | 自動重連；無線偵錯被關掉就重新開啟。重連失敗時在等待畫面提示，不中斷等待 |
| NSD 回傳多個連接埠 | 逐一嘗試，能連上的才算 |
| shell 串流開啟失敗 | 指令排隊執行；失敗時延遲約 300 ms 重試一次 |
| `Client.log` 不存在（還沒開過遊戲） | 長度視為 0，持續等待 |
| `Client.log` 輪替（遊戲重開） | 沿用既有邏輯：長度變小就從 0 讀 |
| root 授權被拒 | 改試下一種讀取方式 |
| 配對服務逾時 | 見 5.3 |
| 授權 `WRITE_SECURE_SETTINGS` 失敗（部分廠牌的安全性限制） | 見 5.4，改走手動開關模式 |
| 玩家在等待畫面按取消 | 停止監看；本次開啟的無線偵錯要關掉 |
| 其他廠牌不支援直接開「無線偵錯」頁 | 由兩段式 intent 的捲動參數接手；都失敗時退回只開「開發人員選項」 |

## 九、Log

依 CLAUDE.md 用英文，Logger 命名沿用既有樹：

- `capture.android`：讀取方式的決定、每一步的成敗與耗時、Wi‑Fi 狀態。
- `capture.adb`：無線偵錯開關、NSD 結果數量、連線嘗試（連接埠可記，金鑰不記）、串流重試。
- `capture.pairing`：配對服務狀態、逾時、配對結果（不記配對碼）。
- 監看沿用 `gacha.clientLog`；網址一律經 `sanitizeCredential`／`sanitizeUrl`。

## 十、測試

**單元測試（`fvm flutter test`）**

- `PollingClientLogWatch` 改用假的 `ClientLogSource`：起點、增量、輪替、讀取上限分輪、讀取錯誤不中斷（既有測試改成透過 `LocalFileLogSource` 繼續跑）。
- `ShellLogSource`：產生的指令字串正確，路徑和整數以外不會插入其他內容。
- 讀取方式選擇：root → 直接讀 → 無線偵錯的優先順序、各種不可用情況。
- 連接埠逐一嘗試：第一個失敗、第二個成功。
- 手動輸入：從整段錯誤訊息找出網址（測資用飛航模式實際複製到的文字，帳號資料換成假值；網址前後是空白、`&` 未跳脫，既有的 `findConveneUrls` 不用改）、多個網址取最新的合法一個、找不到時的錯誤；Client.log 檔案解碼後找網址。
- `GachaRepository`：Android 等待分支、沒有自動讀取方式時的等待畫面、手動輸入完成等待、手動輸入啟動新的更新、取消時依規則關閉無線偵錯、全池失敗後重新等待、手動開關模式（等玩家打開無線偵錯後自動繼續）。
- 等待畫面：Android 與電腦版顯示的元素差異。

**實機驗證（ASUS Android 16）**

- 全新安裝：說明頁 → 配對引導 → 配對 → 自動繼續更新並成功抓到資料。
- 關閉無線偵錯、重開機、換 Wi‑Fi 後各更新一次。
- 等待中切去遊戲再切回來。
- 配對服務逾時後重新開始。
- 手動輸入：貼上飛航模式複製的整段文字；選 Client.log 檔案。
- 解除配對後再按更新，會出現「設定讀取方式」。
- 手動開關模式：用 `pm revoke` 收回授權來模擬授權失敗，確認提示與自動繼續。

**模擬器驗證**

- Android 10 與 Android 9：放一個假的 `Client.log` 到遊戲路徑，確認直接讀取可行。
- Android 12 或 13：配對服務（沒有 `shortService` 系統上限）的配對與 3 分鐘自行逾時。
- root：用有 root 的模擬器確認 `su` 路徑。

**電腦版回歸**

- 攔截、Client.log 監看、手動輸入（貼上與選檔）。

## 十一、文件

- 更新 `docs/Android移植筆記.md`：直接開「無線偵錯」頁的 intent、`shortService` 與逾時、NSD 舊連接埠、串流開啟競態、飛航模式取得網址、重開機後授權仍在。
- Google Play 上架說明與 Data safety 的內容留給子專案 7，這裡只記下需要說明的項目：`WRITE_SECURE_SETTINGS` 的用途、前景服務（`shortService`）的用途、給審核員的無線偵錯操作說明。

## 十二、留給實作者決定

- MethodChannel 的方法名稱與 Kotlin 類別拆分。
- 說明頁與引導頁用獨立頁面還是 `AppDialog`（依 RWD 與現有頁面風格判斷）。
- 單次讀取上限的確切數值、NSD 收集時間的確切數值。
- ARB 字串的 key 名稱（四份核心 ARB 都要補）。
