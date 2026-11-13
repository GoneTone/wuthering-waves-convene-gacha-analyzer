# 子專案 7：Play 上架與更新 — 設計

- 狀態：草稿（2026-11-06）
- 路線圖：`docs/superpowers/specs/2026-11-05-android-support-roadmap-design.md`（子專案 7）
- 分支：`feat/android-support`

---

## 一、目的

讓只玩手機的玩家可以從 **Google Play** 安裝、更新這個 App（路線圖目標），並讓維護者每次發版時只需按一個「升級到正式版」。

**目標**

- 用正式的上傳金鑰簽章 AAB，打 tag 後由 CI 自動建置並上傳到 Play 的**內部測試軌道**。
- Android 版的「有新版」改用 Play 的應用程式內更新，玩家看到的對話框沿用現有樣式。
- 準備上架所需的文件：商店頁文字、隱私權政策、資料安全表單答案、給審查人員的說明。
- 補登記 Play 版的 SHA-1，讓雲端同步在 Play 下載的版本也能用（子專案 5 留下的待辦）。
- 全平台換上新的 App 圖示（見 4.7）。

**非目標**（使用者 2026-11-06 決定）

- GitHub Releases 提供 APK、兩種建置版本（只上 Play）。
- 改動 Windows 的發佈流程與版本號。
- 自動升級到正式版（升級一律在 Play Console 手動按）。
- 商店主視覺圖、宣傳圖的設計（由使用者提供）。
- 把 App 啟動器上顯示的名稱改成商店標題的寫法（只改 Play 商店頁的標題，見 4.6；**我的判斷**：啟動器空間小，長標題會被截斷）。

**反目標**

- 改壞 Windows 的發佈流程或 GitHub 更新檢查。
- 上傳金鑰、密碼、服務帳戶金鑰進入 repo 或 log。
- Play 上還沒有的版本，App 卻叫玩家去更新。
- 從 Play 下載的版本雲端同步登入失敗（`DEVELOPER_ERROR`）。

## 二、現況

- **更新檢查**（`lib/services/app_release_checker.dart`、`lib/state/app_release.dart`）：
  - App 啟動時（`app_shell.dart`）和設定頁按「檢查更新」時，查 GitHub Releases API，取比目前新的版本清單。
  - 有新版就跳出 `NewVersionDialog`，列出各版更新內容。按「下載」會開 GitHub 頁面；按「略過此版本」會把 tag 存進 settings 的 `skippedReleaseTag`。
- **Android 簽章**：`android/app/build.gradle.kts` 的 release 目前用 debug 金鑰簽（Flutter 範本的 TODO）。
- **版本號**：`pubspec.yaml` 為 `1.8.1+17`。Windows 發佈流程（`.github/workflows/release-windows.yml`）由 tag 解析版本，build number 用該流程的 `github.run_number`，並把 bump commit 推上 master。
- **CI**：`ci.yml`（format／analyze／test）、`release-windows.yml`（手動觸發，輸入 tag，建安裝檔、建 GitHub Release 草稿）。
- **權限**（Play 審查與資料安全相關）：
  - 一般權限：`INTERNET`、`ACCESS_NETWORK_STATE`、`POST_NOTIFICATIONS`、`FOREGROUND_SERVICE`（`shortService`）。
  - `READ_EXTERNAL_STORAGE`（`maxSdkVersion=29`）。
  - `WRITE_SECURE_SETTINGS`（由無線偵錯的 shell 授權，用來自動開關無線偵錯）。
  - `<queries>` 指定鳴潮國際服套件 `com.kurogame.wutheringwaves.global`。
- targetSdk 跟 Flutter 預設（36），符合 Play 目前要求。

## 三、做法（使用者已選）

### 3.1 發版流程：CI 自動上傳到內部測試軌道（使用者選 A）

| | 做法 | 取捨 |
|---|---|---|
| **A** | **打 tag 後 CI 建簽章 AAB，自動上傳到內部測試軌道；使用者在 Play Console 升級到正式版** | **和 Windows「CI 做到草稿、人按發佈」一致；上傳與版本代碼不會出錯；需一次性設定服務帳戶** |
| B | CI 只建 AAB 放在產出物，使用者手動上傳 | 不需服務帳戶；每次都要手動上傳、填版本說明 |

### 3.2 App 內更新體驗：彈性更新＋沿用現有對話框（使用者選 A）

| | 做法 | 取捨 |
|---|---|---|
| **A** | **Play 彈性更新；沿用 `NewVersionDialog`（更新內容、略過此版本）；「更新」在背景下載，下載完提示重新啟動** | **和 Windows 體驗一致** |
| B | Play 立即更新（全螢幕擋住 App） | 程式最少；沒有更新內容、不能略過，打擾 |
| C | 「下載」只開 Play 商店頁 | 不用整合 `in_app_update`；多跳出一次，App 不知道 Play 是否真的有新版 |

### 3.3 其他使用者決定

- 只上 Play，不提供 GitHub APK。
- 使用者已有 Google Play 開發者帳號。
- **商店標題用「工具名 for 遊戲名」**（例如「喚取卡池分析 for 鳴潮」、英文「Convene Analyzer for Wuthering Waves」）：Play 官方政策沒有規定遊戲名的位置，但「Official」或暗示官方關係的寫法明確禁止；這種格式在實務上比較不像官方產品。說明開頭加「非官方工具，與庫洛遊戲無關」。
- **新圖示（全平台）**：採用使用者以 Gemini 生成的圖（見 4.7）。**使用者已知並接受**：它以遊戲道具圖（金球與十字）為參考，造型與遊戲美術高度相似；庫洛《鳴潮衍生作品指引》把軟體排除在允許的衍生作品之外，Play 冒充政策也把「圖示與既有產品相似」列為違規。可能的後果是送審被退或上架後被權利人檢舉下架。
- **CI 的實際驗收放在 PR 合併之後**：GitHub 只能手動觸發預設分支上已存在的流程，而 Android 程式全部完成後才開 PR（使用者既有規則）。
- **另開一把這個 App 專用的上傳金鑰**（不沿用 `G:\_APK_Key` 裡的舊金鑰）：金鑰會放進公開 repo 的 GitHub Actions secrets，專用金鑰外洩只影響這個 App；有開 Play 應用程式簽署時，上傳金鑰可以向 Play 申請重設。

## 四、設計

### 4.1 版本代碼（只限 Android）

- Android 的 versionCode 由版本號換算，建置時以 `--build-number` 傳入，**不改 `pubspec.yaml`、不影響 Windows**。
  - Windows 執行檔版本資訊每段上限 65535，放不下換算後的數字，所以 Windows 維持 `github.run_number`。
- 公式：`MAJOR × 1,000,000 ＋ MINOR × 10,000 ＋ PATCH × 100 ＋ 尾碼`
  - 正式版尾碼為 `99`；預覽版 `-rc.N` 的尾碼為 `N`（1 ≤ N ≤ 98）。
  - 例：`1.8.1` → `1080199`；`1.9.0-rc.2` → `1090002`；`1.9.0` → `1090099`。
  - 預覽版的代碼一定小於同版號的正式版，版本號遞增時代碼必遞增。
  - 不符合 `vX.Y.Z` 或 `vX.Y.Z-rc.N` 的 tag，CI 直接失敗。
- 公式以一個 Dart 純函式實作（給 App 反推版本號用，見 4.3），CI 也用同一份規則。CI 換算方式由實作者決定，但要有測試或檢查確保兩邊一致。

### 4.2 上傳金鑰與簽章

- 使用者在自己電腦用 `keytool` 產生專用上傳金鑰（PKCS12，RSA 2048 以上，有效期 25 年以上），密碼由使用者在終端機輸入，**不經過對話**。計畫附指令。
- `android/app/build.gradle.kts` 的 release `signingConfig` 依下列順序取得金鑰：
  - 本機：讀 git-ignored 的 `android/key.properties`（storeFile、storePassword、keyAlias、keyPassword）。
  - CI：由 secrets 解碼出的同名檔案。
  - 兩者都沒有時，維持用 debug 金鑰（開發者 `flutter run --release` 照常能跑），但 **CI 的 Play 上傳流程必須檢查到正式金鑰才繼續**。
- Play 應用程式簽署：照 Play 預設，由 Play 產生並保管 App 簽署金鑰。

### 4.3 App 內更新（Android）

- 依 `isAndroidProvider` 分流：Windows 完全照舊（GitHub）；Android 改由 Play 判斷有沒有新版。
- **「有沒有新版」一律以 Play 為準**：
  - 用 `in_app_update`（實作時查最新穩定版，目前 5.0.0）的 `checkForUpdate()`。
  - 有可更新版本時，以 `availableVersionCode` 依 4.1 公式反推版本號。
  - 再用既有的 GitHub Releases 查詢，取「目前版本之後、到該版本為止」的各版更新內容給 `NewVersionDialog` 顯示。
- 對話框行為：
  - 「更新」：呼叫 `startFlexibleUpdate()`，背景下載。下載完成時顯示提示（SnackBar 或同等元件，含「重新啟動」動作），按下呼叫 `completeFlexibleUpdate()`。
  - 「略過此版本」：沿用 `skippedReleaseTag`，以反推的 `vX.Y.Z` 比對。
- **GitHub 查不到對應版本說明時**（網路錯誤、版本說明還沒發佈）：仍要提示有新版，只是不顯示更新內容（或顯示通用文字）。
- **不是從 Play 安裝的版本**（開發者 `flutter run`、本機 APK）：`checkForUpdate()` 會失敗。
  - 啟動時的自動檢查：安靜略過，只記 log。
  - 手動按「檢查更新」：顯示一般的「檢查更新失敗」並附原因。
- 「查看更新內容」（目前版本的說明）照舊讀 GitHub，只是讀取文字，不涉及下載程式。
- Android 顯示的更新內容**與 Windows 相同，不裁掉頁尾**（使用者 2026-11-07 決定）。改由調整頁尾本身讓它適用兩個平台，見 4.9。
- log：Logger 沿用現有的更新檢查命名，英文，記 Play 回報的可更新狀態、版本代碼、彈性更新各階段結果。

### 4.4 CI：Android 發佈流程

- 新增獨立的 `.github/workflows/release-android.yml`，**不改 `release-windows.yml`**。手動觸發，輸入 tag（與 Windows 相同格式）。
- 步驟：
  1. 驗證 tag，換算 versionCode。
  2. 從 secrets 還原上傳金鑰與 `key.properties`，以及 `secrets/cloud_sync_defines.json`（沿用 Windows 的 `CLOUD_SYNC_CLIENT_ID`／`CLOUD_SYNC_CLIENT_SECRET`）。
  3. `flutter build appbundle --release --build-name <semver> --build-number <versionCode> --dart-define-from-file=...`
  4. 用服務帳戶上傳到 **internal** 軌道。**不填 Play 的「新功能」**（使用者 2026-11-07 決定：主要版本說明是手寫的，不是 CI 產生的；由使用者在 Play Console 升級正式版時自行填寫）。
  5. AAB 另存為 workflow 產出物，方便除錯。
- **要建置哪個 commit**：
  - Windows 流程會把版本號 bump commit 推上 master，再以那個 commit 建 Release 草稿。
  - Android 流程從使用者指定的 ref（預設 master）建置，CI 不另做 bump commit；版本號全部透過建置參數傳入。
  - 使用順序：先跑 Windows 流程，再跑 Android 流程，兩邊會是同一個版本號。
  - **預覽版（`-rc.N`）只能留在內部測試軌道，不可升級到正式版**（使用者 2026-11-07 確認：rc 只給測試用。另一個原因是既有 GitHub 查詢會略過預覽版，升正式版後 App 內查不到它的更新內容）。寫進移植筆記與上架文件的發版步驟。
- 金鑰、密碼、服務帳戶 JSON 一律從 secrets 讀進 runner 的暫存檔；**不印到 log**；job 結束時刪除。
- 建置機需要 Rust toolchain（cargokit 會編 `rust/`）與 Android SDK／NDK；`android/cargokit_gradle9_shim.gradle` 等既有 shim 照用。

### 4.5 雲端同步 SHA-1（子專案 5 待辦）

- Google Cloud 的 Android OAuth 用戶端**一筆只能填一個 SHA-1**，所以每把金鑰各建一筆 Android 用戶端（套件名稱同為 `tw.reh.wuwa.gacha`，同一個專案）：
  - debug 金鑰：已建立。
  - **Play 應用程式簽署金鑰**：從 Play Console 的「應用程式完整性」頁複製 SHA-1。**玩家從 Play 下載的版本用這把簽章，這筆最重要**。
  - 上傳金鑰：只影響本機以上傳金鑰簽的 release 版測試，也一併登記。
- 驗收：從內部測試軌道安裝後，雲端同步能連結並同步。

### 4.6 上架文件

放在 `docs/play-store/`，商店頁先做四種語言（繁中、英文、日文、簡中，與 App 核心語言一致）：

- **商店頁文字**：App 名稱（30 字內）、簡短說明（80 字內）、完整說明（4000 字內），強調「本機分析、資料不上傳到開發者」以及支援的讀取方式（無線偵錯、root、Android 10 以下直接讀、手動貼網址）。
- **隱私權政策**：放在 repo，用 GitHub 上的頁面網址填進 Play。內容依實際行為寫：
  - 喚取紀錄存在本機。
  - App 會向遊戲官方伺服器查詢喚取紀錄、向 encore.moe 取物品資料。
  - 雲端同步只在玩家自己連結時，寫入玩家自己的 Google 雲端硬碟（appDataFolder）。
  - log 只在玩家自己匯出或分享時才會離開裝置。
  - 沒有廣告、沒有分析追蹤、開發者沒有伺服器。
- **資料安全表單答案**：逐題列出建議答案與理由，最後由使用者在 Console 確認填寫。
- **審查說明**：
  - 怎麼用無線偵錯讀取紀錄（步驟、為什麼需要 `WRITE_SECURE_SETTINGS`、只讀鳴潮的 log、每一步都由玩家觸發）。
  - 審查人員沒有鳴潮帳號時，怎麼用「手動貼網址」或展示資料測試。
- **需要的素材清單**：
  - 512×512 圖示（由 4.7 的新圖示主檔輸出，滿版正方形，不含圓角）。
  - 1024×500 主視覺圖：由使用者提供。
  - 手機截圖：從實機用 adb 擷取，四種語言各一組。
- **一次性設定步驟**：
  - 建立 App、開啟 Play 應用程式簽署、第一次手動上傳 AAB。
  - 建服務帳戶並在 Play Console 授權、設定 GitHub secrets。
  - 登記 SHA-1（4.5）。
  - 內容分級問卷、目標對象（不以兒童為對象）。

### 4.7 新 App 圖示（全平台）

- 來源：使用者提供的 Gemini 生成圖 `C:\Users\p2902\Downloads\Gemini_Generated_Image_aerz7aerz7aerz7a.jpg`（2048×2048 JPG）。圖中已畫好圓角方形，四個角是黑色。
- 處理：用背景色把四個角補滿，存成**滿版正方形 PNG**，取代 `tool/app_icon_source.png`，再執行既有的 `dart run tool/generate_app_icons.dart` 重產所有尺寸（App 內 UI、Windows `.ico`、Android mipmap）。不重新生成、不改造型。Android 與 Play 會自己套形狀遮罩，所以主檔不可帶圓角。
- **Android 自適應圖示**：新增 adaptive icon（背景層用圖中的深藍色，前景層是主體縮放到安全區內），避免新版啟動器把舊式圖示縮小放進白底圓形。做法由實作者決定（可擴充既有產生腳本）。
- 驗收：Windows 工作列、安裝檔、App 標題列；Android 啟動器（圓形、方圓形裁切）與 Play 商店頁都看到新圖示，主體沒有被裁掉。
- 舊的角色圖示一併移除。

### 4.8 文件

- `docs/Android移植筆記.md` 新增「十、Play 上架（子專案 7）」：版本代碼公式與 Windows 不同的原因、簽章設定、CI secrets 一覽、SHA-1 一筆一個用戶端、實際上架時遇到的問題。
- README ×4 補一段 Android 的取得方式（Play 連結，上架後才填）。

### 4.9 Release 頁尾（`.github/release-footer.md`，使用者 2026-11-07 決定）

- 現在：防毒軟體說明沒寫平台，Android 玩家看到會困惑。
- 本子專案：說明改成只針對 Windows，例如「Windows 版在安裝或執行時有可能會被防毒軟體阻擋…」，英文「The Windows version may be blocked by antivirus programs…」。其餘內容不動。
- **上架後**（不屬於本子專案的程式交付，列入第五節的使用者步驟與移植筆記）：在頁尾加上 Google Play 下載徽章圖片（使用 Google 官方提供的徽章），點擊連到 Play 商店頁。

## 五、需要使用者操作的事（計畫要標出順序）

1. 產生上傳金鑰，並建立本機 `android/key.properties`。
2. 在 Play Console 建立 App（套件名稱 `tw.reh.wuwa.gacha`），開啟 Play 應用程式簽署。
3. **第一次手動上傳** AAB 到內部測試軌道（Play 對新 App 的規定）。這個 AAB 由本機建置。
4. 建 Google Cloud 服務帳戶，在 Play Console「使用者和權限」授權給它，把 JSON 金鑰和上傳金鑰設成 GitHub secrets。
5. 在 Google Cloud 為 Play 簽署金鑰、上傳金鑰各建一筆 Android 用戶端。
6. 填商店頁、隱私權政策網址、資料安全、內容分級、目標對象，上傳主視覺圖。
7. 送審，之後每次發版只需要「跑 Windows 流程 → 跑 Android 流程 → 在 Play Console 填『新功能』並升級到正式版」。
8. 上架後：在 `.github/release-footer.md` 與 README ×4 加上 Google Play 下載徽章並連到商店頁（4.9、4.8）。

## 六、驗收

**自動測試**（`fvm flutter analyze` 無問題、`fvm flutter test` 全過）

- 版本代碼公式：正式版、預覽版、反推、不合法 tag。
- Android 更新分流：
  - Play 有新版 → 顯示對話框，更新內容來自 GitHub。
  - Play 沒有新版但 GitHub 有 → 不提示。
  - GitHub 查不到 → 仍提示有新版，不帶更新內容。
  - 略過此版本 → 不再提示同版本。
  - 非 Play 安裝：自動檢查安靜略過，手動檢查顯示失敗。
  - 彈性更新下載完成 → 顯示重新啟動提示。
- Windows 的更新檢查行為與測試不變。

**實機**

- 內部測試軌道安裝的版本：
  - 能開啟，讀取紀錄的各種方式照常可用。
  - 雲端同步能連結並同步（驗證 4.5）。
- 彈性更新：**用 Play 的「內部應用程式分享」測試**（Google 官方建議的應用程式內更新測試方式，可上傳任意版本代碼，不會用掉正式的版本號）。
  - 從分享連結安裝舊版，再分享一個版本代碼較大的版本。
  - 舊版 App 啟動時跳出對話框。
  - 按更新後背景下載，完成後重新啟動，變成新版本。
- CI（**PR 合併之後**）：Android 發佈流程跑一次，AAB 出現在內部測試軌道，版本代碼正確，log 裡沒有任何秘密。

## 七、Play 審查風險（沿用路線圖 2.3，推論，未實際送審）

- `WRITE_SECURE_SETTINGS` 與自我配對 ADB 可能被要求說明用途，審查說明要寫清楚。
- 若被拒，回到使用者決定：調整說明再送，或改動功能。

## 八、留給實作者決定

- 上傳到 Play 用哪個 GitHub Action（例如 `r0adkll/upload-google-play`）或 fastlane。
- CI 換算 versionCode 的方式（PowerShell／bash／呼叫 Dart），但必須與 Dart 公式一致並有檢查。
- 彈性更新下載完成提示的元件與文字（沿用現有 UI 慣例；新增字串只改四份核心 ARB）。
- `docs/play-store/` 內的檔案切分。
