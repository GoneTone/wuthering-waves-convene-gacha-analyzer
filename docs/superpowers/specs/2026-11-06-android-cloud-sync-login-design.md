# 子專案 5：Android 雲端同步登入 — 設計

- 狀態：草稿（2026-11-06），手機實驗已通過 go／no-go
- 路線圖：`docs/superpowers/specs/2026-11-05-android-support-roadmap-design.md`（子專案 5）
- 既有雲端同步設計：`docs/superpowers/specs/2026-07-04-google-drive-cloud-sync-design.md`
- 分支：`feat/android-support`

---

## 一、目的

讓只用手機的玩家也能把喚取紀錄同步到 Google 雲端硬碟，而且手機和 PC 版**讀寫同一份同步檔**。路線圖已決定「登入分流，Drive 同步本體共用」，Android 使用 Android 類型的 OAuth 用戶端。

**目標**

- Android 上能連結 Google 帳號、自動／手動同步、中斷連結，行為與 PC 版相同。
- 手機與 PC 連結同一個 Google 帳號時，看到的是同一份同步檔。
- 一台裝置中斷連結，不影響其他裝置的同步（使用者 2026-11-06 決定，見 5.3）。

**非目標**

- 沒有 Google Play 服務的裝置（App 只在 Play 上架）。這類裝置連結失敗時顯示既有的「授權失敗」即可。
- 改動同步檔格式、合併規則、觸發時機。

**反目標**

- 改壞 Windows 既有的登入流程與 UX（瀏覽器授權、完成頁、取消、把視窗帶回前景）。中斷連結不再撤銷授權是使用者決定的行為變更，不算改壞。
- 在手機上冒用桌面版 OAuth 憑證。
- 只在開發用金鑰簽的版本能登入、Play 下載的版本登入失敗。

## 二、現況

- `lib/services/cloud_sync/google_auth_service.dart`：`googleapis_auth` 的 `clientViaUserConsent`（瀏覽器＋localhost 回呼）取得 refresh token；`restore()` 用 refresh token 換 access token；`signOut()` 向 Google 撤銷並刪除 token；`revokeToken()` 另用於「取消後遲到的授權」與「缺 Drive 權限」兩處。
- `lib/services/cloud_sync/token_store.dart`：refresh token 存在 `flutter_secure_storage`。
- `lib/state/cloud_sync.dart`（`CloudSyncNotifier`）：`link`／`cancelLink`／`unlink`／`start`／`syncNow`，持有常駐的授權 client（`_client`）。
- `lib/services/cloud_sync/cloud_sync_config.dart`：`CLOUD_SYNC_CLIENT_ID`／`CLOUD_SYNC_CLIENT_SECRET` 由 `--dart-define-from-file=secrets/cloud_sync_defines.json` 注入；`isCloudSyncConfigured` 為 false 時整個功能停用。
- 同步本體（`cloud_sync_remote.dart`、`cloud_sync_service.dart`）只需要一個已授權的 `http.Client`，與平台無關。

## 三、做法比較（使用者選 A）

| | 做法 | 取捨 |
|---|---|---|
| **A** | **官方 `google_sign_in`，系統的 Google 帳號選擇視窗** | **Google 建議的 Android 做法；不必存任何密鑰或 refresh token；只有登入那段依平台分流** |
| B | `flutter_appauth`＋自訂 URI scheme 轉回 App | 可沿用 refresh token 那套；但 Google 新建的 Android 用戶端預設停用自訂 scheme，官方不鼓勵 |
| C | 手機沿用 PC 的瀏覽器＋localhost 流程 | 改最少；但等於在手機上用桌面版憑證，違反用戶端類型規範 |

## 四、手機實驗結果（2026-11-06，ROG Phone，拋棄式程式，不進 repo）

使用 `google_sign_in` 7.2.0（`google_sign_in_android` 7.2.18）。

1. **只走「授權」、不走「登入」就夠了。** `GoogleSignIn.instance.authorizationClient` 直接要求 `drive.appdata`＋`email`，不必呼叫 `authenticate()`。`initialize()` 不帶任何參數也能用，**不需要網頁應用程式用戶端，也不需要新的 define**。
   - 對照：走 `authenticate()` 時必須給「網頁應用程式」用戶端 ID 當 `serverClientId`；拿桌面用戶端 ID 去填會失敗：`[28444] Developer console is not set up correctly.`
2. **Android 用戶端的 ID 不必放進程式。** Google Play 服務以套件名稱＋簽章指紋找到專案裡對應的 Android 用戶端。tokeninfo 查到通行證的 `azp` 是 `960146187350-03asj3...`：專案編號與桌面用戶端相同，用戶端不同，就是使用者建立的 Android 用戶端。
3. **手機讀到 PC 上傳的同一份同步檔**：`wuwa_convene_sync.json`，大小與修改時間一致，3 個帳號，schema 2。證實同一個專案共用 appDataFolder。
4. **App 完全關掉再開，靜默授權（`authorizationForScopes`）直接拿到通行證**，不必重新連結。
5. **授權是整個 Cloud 專案共用一份。** 第一次在手機授權時，連授權畫面都沒跳，直接沿用 PC 給過的授權。手機向 Google 撤銷後，**PC 也變成「需要重新連結」**。所以任何一台裝置撤銷，所有裝置都失效；現有 Windows 版的「中斷連結」也是如此。
6. **Play 服務會快取已失效的通行證。** 撤銷後重新授權，系統把舊的、已撤銷的通行證交回來，API 回 401。必須用 `clearAuthorizationToken` 清掉快取再要一次。
7. **「只忘記本機」可以換帳號、不影響 PC。** 清快取（`clearAuthorizationToken`）＋`signOut()`，不撤銷。之後靜默授權拿不到通行證；再授權時會跳出帳號選擇；PC 同步維持正常。

## 五、設計

### 5.1 憑證與啟用條件

- 不新增 define、不建網頁應用程式用戶端。
- `isCloudSyncConfigured` 在 Android 上，沿用 `CLOUD_SYNC_CLIENT_ID` 不為空作為「這個建置屬於有設定雲端專案的正式建置」的開關（**我的判斷**：程式用不到這個 ID，但這樣「沒帶 `secrets` 建置就停用同步」在兩個平台一致，fork 者不會撞上無法理解的設定錯誤）。Windows 維持 `CLIENT_ID`＋`CLIENT_SECRET`。
- Android 的 CI 建置注入留給子專案 7。

### 5.2 登入分流

- 把「連結／還原／中斷連結」抽成平台無關的介面，`CloudSyncNotifier` 只依賴介面。Windows 實作以現在的 `GoogleAuthService` 為基礎，Android 新增以 `google_sign_in` 授權 API 實作的版本，依 `isAndroidProvider` 選擇。
- **Android 連結**：`authorizeScopes(cloudSyncScopes)`（跳帳號選擇與授權）→ 用通行證呼叫 userinfo 取 email（沿用既有 `_fetchEmail` 的做法）→ 存 email、立即同步一輪（與 Windows 相同）。
- **Android 還原**：不讀 `TokenStore`，改用 `authorizationForScopes` 靜默取通行證，再以 userinfo 確認 email。以下情況一律丟 `CloudReauthRequiredException`，沿用既有「需要重新連結」流程：
  - 回 null（需要使用者操作）。
  - email 與 settings 存的不同（手機有多個帳號時，避免默默同步到別的帳號；**我的判斷**）。
- **通行證過期與快取**：Android 通行證約 1 小時過期，App 無法自己續期，`_client` 不可沿用到過期後（每輪重新取，或包一個會重新靜默索取的 client，由實作者決定）。API 回 401 時，先 `clearAuthorizationToken` 再靜默重取**一次**；仍失敗才走 `reauthRequired`。驗收條件：App 開著超過 1 小時，資料變動觸發的同步仍成功。
- **缺少 Drive 權限**：依賴既有路徑（同步時遇到 insufficient scope → `reauthRequired`＋`scopeMissing`）。
- **使用者取消**：系統視窗取消（`GoogleSignInExceptionCode.canceled`）回到閒置、不顯示「授權失敗」。log 要記 exception code（設定錯誤也可能被回報成 canceled）。

### 5.3 中斷連結：只忘記本機（使用者 2026-11-06 決定，兩個平台）

依實驗第 5 點，撤銷會讓所有裝置失效，所以**兩個平台的中斷連結都不再向 Google 撤銷**：

- Windows：只刪本機 refresh token、清 settings。
- Android：`clearAuthorizationToken`（目前通行證）＋`signOut()`、清 settings。
- 想徹底取消授權的玩家，可到 Google 帳戶設定移除。是否在中斷連結的確認文字提一句，由實作者依現有對話框決定。

連帶的 Windows 變更（**我的判斷**：同一個理由，撤銷都會波及其他裝置）：
- 「取消後遲到的授權」改成只丟棄、不撤銷。
- 「授權缺 Drive 權限」改成只丟棄並報 `scopeMissing`、不撤銷。
- `revokeToken()` 因此不再有呼叫者，刪除。

### 5.4 介面（手機）

- 設定頁雲端同步區塊沿用既有元件。
- 等待授權的文字在 Android 不能說「已開啟瀏覽器」：新增 Android 用字串（例如「請在 Google 視窗完成授權...」）。Android 等待時要不要保留「取消」由實作者決定（系統視窗會蓋住 App）。
- 「把視窗帶回前景」與授權完成頁（`postAuthPage`）只用在 Windows；Android 不呼叫 `windowManager`。
- `cloudSyncIntro` 的「在多台電腦間同步」改成不限裝置的寫法（**我的判斷**：只是用詞，會改到 Windows 的文字）。只改四份核心 ARB。

### 5.5 log

Logger 沿用 `cloudsync.auth`／`cloudsync.sync`，英文：連結開始／成功／取消（含 exception code）／失敗、靜默還原成功／需要互動／email 不符／失敗、401 清快取重試、中斷連結結果。絕不記通行證內容，email 不寫進 log。

### 5.6 Google Cloud Console（使用者已完成）

- Android 用戶端已建在桌面用戶端同一個專案：套件名稱 `tw.reh.wuwa.gacha`，SHA-1 `F8:09:DC:34:0C:1C:D5:92:C5:0A:44:8E:0B:DB:1C:96:8D:30:08:1B`（debug 金鑰）。
- **子專案 7 待辦**：上傳金鑰與 Play 應用程式簽署金鑰的 SHA-1 都要補登記，否則 Play 版會出現設定錯誤。

## 六、驗收

**自動測試**（`fvm flutter analyze` 無問題、`fvm flutter test` 全過）

- Windows 既有雲端同步測試驗證的行為保留：refresh token 寫入、遲到授權不寫入、完成頁、取消。測試可以為了新介面做機械式調整。原本斷言「有撤銷」的地方，依 5.3 改為斷言「沒有撤銷」；其餘斷言不可刪減。
- Android 實作（以假的授權層測試）：
  - 連結成功存 email 並同步一輪；使用者取消回到閒置且不顯示錯誤。
  - 靜默還原回 null → `reauthRequired`；email 不符 → `reauthRequired`。
  - 401 → 清快取並重取一次；重取成功則同步成功。
  - 中斷連結會清快取、登出、清 settings，且不撤銷。
  - 通行證過期後，下一輪同步會重新取得。
- `isCloudSyncConfigured` 在兩個平台各自依 5.1 判斷。
- 設定頁在 Android 顯示 Android 版等待文字，且不呼叫把視窗帶回前景。

**實機（ROG Phone）**

- 正式 App 連結 → 帳號選擇 → 授權 → 顯示 email。
- 手機合併 PC 的紀錄；手機新增的資料 PC 同步後也看得到。
- 殺掉 App 重開，不必重新連結就能同步。
- 中斷連結後 PC 照常同步；再連結時跳帳號選擇。
- 開著超過 1 小時後同步仍成功。

**Windows 實機**：連結、同步正常；中斷連結後，手機照常同步。

## 七、留給實作者決定

- 登入介面的命名與檔案位置、Android 通行證過期的處理方式（5.2）。
- Android 等待授權時要不要保留取消按鈕（5.4）、中斷連結確認文字要不要提到 Google 帳戶設定（5.3）。

## 八、文件

- `docs/Android移植筆記.md` 新增「九、雲端同步登入（子專案 5）」，記錄第四節的實驗結果，以及三把金鑰的 SHA-1 待辦。
- README ×4 的「自行建置啟用雲端同步」段落：說明 Android 沿用同一個 `secrets/cloud_sync_defines.json`，並要在同一個專案建立 Android 用戶端（套件名稱＋SHA-1），附 Android 的 `flutter run` 範例。
- 子專案 7 的待辦：上傳金鑰與 Play 簽署金鑰的 SHA-1 補登記。
