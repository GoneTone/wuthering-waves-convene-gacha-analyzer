# Google Drive 雲端同步 — Design

**Date:** 2026-07-04
**Branch:** feat/cloud-sync
**Status:** Approved（三段設計皆經使用者確認）

## 1. Motivation & Goals

使用者的抽卡紀錄目前只存在本機（每帳號一個 JSON 檔），跨電腦搬遷得靠手動匯出／匯入。本功能讓使用者登入**自己的 Google 帳號**，把資料自動備份到自己的 Google 雲端硬碟，並在多台電腦間自動同步。

### 目標

- 設定頁新增「雲端同步」區塊：連結 Google 帳號、自動同步開關（登入後預設開啟）、「立即同步」手動按鈕、中斷連結。
- 同步檔格式**與手動匯出完全相同**（`AccountsBundle`，`schema_version: 2`），複用現有匯出／匯入／合併程式碼。
- 自動雙向同步：App 啟動、本機資料變動後自動跑「下載 → 合併 → 上傳」。
- 同步永不刪除資料；唯一例外是使用者刪帳號時勾選「同時從雲端移除」。

### 非目標

- 不支援 Google 以外的雲端服務。
- 不做選擇性同步（部分帳號）——一律同步全部帳號。
- 不做 etag 樂觀鎖／衝突版本管理——非破壞性合併＋last-writer-wins 已足夠（見 §3）。
- 不做定時輪詢同步（Timer）——只有啟動、資料變動、手動三類觸發。
- 不同步 UI 偏好（themeMode／locale 等），僅同步 `AccountsBundle` 既有內容（紀錄＋別名＋lastActiveUid）。

## 2. 雲端檔案佈局與權限

- **存放位置**：Google Drive 隱藏的 `appDataFolder`（`drive.appdata` scope），使用者在雲端硬碟介面看不到、也改不到，不會被誤刪誤改。
- **檔案**：單一檔案 `wuwa_convene_sync.json`，內容即 `exportAccounts` 產出的 `AccountsBundle` JSON——與手動匯出檔同格式，拿下來可直接餵給「匯入」功能。
- **OAuth scopes**：`https://www.googleapis.com/auth/drive.appdata`（最小權限）＋ `email`（僅用於設定頁顯示已連結帳號）。
- **OAuth 用戶端**：Google Cloud Console 的 Desktop app 類型 client；`client_id`／`client_secret` 直接寫在原始碼常數（Google 官方定義 installed app 的 secret 不視為機密），任何人 clone 即可建置出可用的同步功能。

## 3. 同步演算法

一輪同步 = **下載 → 合併 → 上傳**：

1. **下載**：從 appDataFolder 找 `wuwa_convene_sync.json` 下載；不存在視為空 bundle。
2. **合併**：走現有匯入路徑——`importAccounts` 解析（含 app id／schema 驗證）→ `BannerStorage.mergeWith`／`mergeBackupRecords` 非破壞性合併進本機 → 落盤。不寫任何新的合併邏輯。
3. **上傳**：以合併後的本機全帳號 `exportAccounts` 打包，上傳覆蓋雲端檔。

**合併細節**：

- 雲端 bundle 的 `last_active_uid` 在同步時**不套用**（手動匯入才會還原），避免靜默同步偷偷切換使用者目前作用中的帳號。
- 別名衝突：本機已有別名以本機為準，本機沒有才採用雲端的。

**併發語意**：多台電腦同時同步採 last-writer-wins。因合併只增不減，最壞情況是另一台的新紀錄晚一輪才收斂，不會遺失資料，故不需樂觀鎖。

**Schema 保護**：雲端檔 `schema_version` 比本機支援的新時（`UnsupportedSchemaVersionException`），該輪**整個跳過**——不合併、不上傳覆蓋——並提示使用者更新 app。避免舊版 app 用舊格式蓋掉新版資料。

**單飛鎖**：以 `synchronized` 套件確保同時只跑一輪；進行中再被觸發就記一個 pending 旗標，該輪結束後補跑一輪。

## 4. 觸發時機

| 入口 | 模式 | 行為 |
|------|------|------|
| 登入成功後 | manual | 立刻同步一次 |
| App 啟動時 | silent | 已登入且開關開啟才跑；失敗不打擾（仿 `AppReleaseNotifier.check` 的 silent 模式） |
| 本機資料變動後 | silent | 擷取到新紀錄、匯入完成、別名變更、帳號刪除 → debounce 5 秒後同步 |
| 設定頁「立即同步」 | manual | 手動觸發，失敗明確顯示錯誤 |

## 5. 登入／登出與 token 管理

### 登入（「連結 Google 帳號」）

1. `url_launcher` 開**系統瀏覽器**跑 Google 授權頁；`googleapis_auth`（`auth_io`）的 installed-app 流程自動在本機開臨時 localhost port 接收授權回跳，使用者按「允許」即完成。不用 `webview_windows`（Google 封鎖 embedded WebView OAuth，回 `403 disallowed_useragent`）。
2. 授權成功 → 存 token、取 email → 立刻觸發第一輪同步。
3. 等待授權期間設定頁顯示等待狀態＋「取消」（放棄授權、關閉 localhost 監聽）。

### Token 儲存

- **refresh token（敏感）**：存 `flutter_secure_storage`（Windows 底層 DPAPI，綁定 Windows 使用者），不進 shared_preferences。
- **非敏感狀態**：連結 email、自動同步開關、上次同步時間（`lastSyncedAt`）、待雲端移除清單 → `AppSettings`／`SettingsStorage`（`pref.cloudSync*` key）＋ `SettingsNotifier` setter。
- access token 由 `googleapis_auth` 自動續期 client 管理，不自寫刷新邏輯。
- refresh token 失效（使用者於 Google 端撤銷授權 → `invalid_grant`）：停止自動同步、狀態標「需要重新連結」，不無限重試。

### 登出（「中斷連結」）

- 向 Google 打 revoke（盡力而為，失敗不阻擋登出）→ 刪本機 refresh token → 清 settings 相關欄位（email、開關、上次同步時間）。
- **待雲端移除清單保留不清**：使用者刪帳號的意圖在重新連結後仍應補刪。
- 本機抽卡資料不動；**雲端檔保留**（重連或他機仍可同步回來）。

## 6. 刪帳號的雲端整合

- 現有刪除帳號確認對話框加勾選「同時從雲端同步資料移除此帳號」——僅已連結時顯示，預設不勾。
- 勾選後該 UID 加入 settings 的**待雲端移除清單**，並觸發一輪同步。
- 同步時先把清單內 UID 從**下載的雲端 bundle 剔除**（防止剛刪的帳號被合併「復活」），上傳成功後才自清單移除該 UID。
- 離線也安全：清單留存，下次同步成功時補刪。

## 7. UI（設定頁「雲端同步」區塊）

落點：「資料管理」區塊正下方，`SectionCard`＋`Icons.cloud_sync_outlined`。

- **未連結**：一段說明（「登入 Google 帳號後，抽卡紀錄會自動備份並在多台電腦間同步」）＋「連結 Google 帳號」按鈕；按下後轉為等待授權狀態（spinner＋提示＋取消）。
- **已連結**：
  - 已連結帳號 email（直接顯示，不做遮蔽）。
  - 「自動同步」開關（登入後預設開啟）。
  - 上次同步時間與狀態：成功顯示相對時間；失敗顯示簡短原因；「需要重新連結」顯示警告提示＋重連按鈕。
  - 「立即同步」按鈕（同步中 spinner＋停用）。
  - 「中斷連結」按鈕（`AppDialog` 確認框，說明本機與雲端資料皆保留）。
- 所有新字串進核心四 ARB；全形標點、省略號用 ASCII `...`。

## 8. 錯誤處理

| 情境 | 行為 |
|------|------|
| silent 同步失敗（啟動／資料變動觸發） | 不彈窗；更新設定頁狀態列＋log，下次觸發再試 |
| manual 同步失敗 | 明確顯示錯誤，區分：網路問題／授權失效／雲端 schema 過新 |
| 授權失效（invalid_grant） | 停止自動同步、標「需要重新連結」 |
| 雲端 schema 過新 | 跳過整輪（不上傳），提示更新 app |

## 9. Logging

新增 `cloudsync.*` logger 樹：

- `cloudsync.auth`：登入／登出／token 刷新／revoke 結果——**絕不記 token 內容**。
- `cloudsync.sync`：每輪的觸發來源、下載檔案大小、合併結果（added／duplicate）、上傳結果、耗時、失敗原因。
- UID 過 `sanitizeUid`、URL 過 `sanitizeUrl`。

## 10. 程式碼落點

| 檔案 | 職責 |
|------|------|
| `lib/services/cloud_sync/google_auth_service.dart` | OAuth 授權流程、token 存取（包 `flutter_secure_storage`）、revoke |
| `lib/services/cloud_sync/drive_sync_client.dart` | appDataFolder 檔案查找／下載／上傳（包 `googleapis` Drive v3） |
| `lib/services/cloud_sync/cloud_sync_service.dart` | 「下載→合併→上傳」編排、待移除清單剔除、schema 保護 |
| `lib/state/cloud_sync.dart` | `CloudSyncNotifier`（NotifierProvider）：連結狀態、同步狀態、debounce、四個觸發入口 |
| `lib/pages/settings_page.dart` | 新增 `_CloudSyncSection` widget |
| `lib/services/settings_storage.dart`／`lib/state/settings.dart` | `AppSettings` 加 `cloudSync*` 欄位與 setter |
| `lib/widgets/cards/account_management.dart` | 刪帳號對話框加「同時從雲端移除」勾選 |

**新依賴**：`googleapis`（僅 import drive v3）、`googleapis_auth`、`flutter_secure_storage`。

## 11. 測試策略

- `google_auth_service`／`drive_sync_client` 抽介面；`cloud_sync_service` 對 mock 介面寫單元測試：
  - 雲端無檔首輪 → 直接上傳本機資料。
  - 雙向合併：雲端多的補進本機、本機多的上傳。
  - 雲端 schema 過新 → 跳過且**不上傳**。
  - 待移除清單：下載剔除、上傳成功後清除、失敗保留。
  - `invalid_grant` → 標記需重連、停止自動同步。
- 既有合併邏輯（`record_merge`）已有測試，不重測。
- 設定頁 `_CloudSyncSection` 未連結／已連結兩態 widget test。
- 驗收：`fvm flutter analyze` 無 issue、`fvm flutter test` 全綠；實機手動驗證一次真實 Google 授權＋同步（OAuth 無法自動化）。
