# Google Play 上架文件

| 檔案 | 內容 |
|---|---|
| [listing.md](listing.md) | 商店頁文字（四種語言） |
| [privacy-policy.md](privacy-policy.md) | 隱私權政策（填進 Play 的網址用這個檔案在 GitHub 上的頁面） |
| [data-safety.md](data-safety.md) | 資料安全表單建議答案 |
| [review-notes.md](review-notes.md) | 給審查人員的說明、敏感權限說明 |
| `icon-512.png` | Play 商店圖示（由 `tool/generate_app_icons.dart` 產生） |

## 素材清單

- 512×512 圖示：`icon-512.png`。
- 1024×500 主視覺圖：由開發者提供。
- 手機截圖：用 adb 從實機擷取，四種語言各一組（Play 要求 2–8 張，比例 16:9 或 9:16）。

## 一次性設定

依序完成，有順序關係。

1. **產生上傳金鑰**（只做一次，檔案與密碼請自行備份，遺失只能向 Play 申請重設）：
   ```
   keytool -genkeypair -v -storetype PKCS12 -keystore upload.jks -alias upload -keyalg RSA -keysize 4096 -validity 10000
   ```
   密碼在終端機輸入，不要寫進任何檔案或對話中。密碼不要包含反斜線 `\`（`key.properties` 是 Java Properties 格式，`\` 會被當成跳脫字元），用英文字母、數字和 `\` 以外的符號即可。
2. **建立 `android/key.properties`**（已在 `.gitignore`，不會進 repo）：
   ```
   storeFile=<upload.jks 的絕對路徑，或相對於 android/ 的路徑>
   storePassword=<密碼>
   keyAlias=upload
   keyPassword=<密碼>
   ```
   密碼照原樣填，不需要加引號或跳脫（所以第 1 步的密碼不能含 `\`）。沒有這個檔案時，release 建置會改用 debug 金鑰，只能在本機測試，不能上傳。
3. **在 Play Console 建立 App**：套件名稱 `tw.reh.wuwa.gacha`，預設語言繁體中文（台灣），免費，類別「工具」。開啟「Play 應用程式簽署」。
4. **第一次手動上傳**（Play 規定新 App 的第一個版本必須手動上傳）：
   ```
   fvm dart run tool/android_version_code.dart v<版本>
   fvm flutter build appbundle --release --build-name <BUILD_NAME> --build-number <VERSION_CODE> --dart-define-from-file=secrets/cloud_sync_defines.json
   ```
   上傳 `build/app/outputs/bundle/release/app-release.aab` 到「內部測試」軌道。
5. **服務帳戶**：在 Google Cloud 建立服務帳戶並產生 JSON 金鑰；在 Play Console「使用者和權限」邀請該服務帳戶的 email，授予此 App 的「發布到測試軌道」權限。
6. **GitHub secrets**（Settings → Secrets and variables → Actions）：

   | 名稱 | 內容 |
   |---|---|
   | `ANDROID_UPLOAD_KEYSTORE_BASE64` | `upload.jks` 的 base64 |
   | `ANDROID_UPLOAD_STORE_PASSWORD` | keystore 密碼 |
   | `ANDROID_UPLOAD_KEY_ALIAS` | `upload` |
   | `ANDROID_UPLOAD_KEY_PASSWORD` | key 密碼 |
   | `PLAY_SERVICE_ACCOUNT_JSON` | 服務帳戶 JSON 全文 |

   `CLOUD_SYNC_CLIENT_ID`／`CLOUD_SYNC_CLIENT_SECRET` 已為 Windows 流程設定過，共用。
7. **登記 SHA-1**：Google Cloud 的 Android OAuth 用戶端一筆只能填一個 SHA-1，所以每把金鑰各建一筆（套件名稱都是 `tw.reh.wuwa.gacha`，同一個專案）：
   - Play 應用程式簽署金鑰：Play Console →「測試與發布」→「應用程式完整性」複製 SHA-1。**玩家從 Play 下載的版本用這把，最重要。**
   - 上傳金鑰：`keytool -list -v -keystore upload.jks` 取得 SHA-1。
   - debug 金鑰：已建立。
8. **填寫應用程式內容**：隱私權政策網址、資料安全（[data-safety.md](data-safety.md)）、應用程式存取權（[review-notes.md](review-notes.md)）、內容分級問卷、目標對象（不以兒童為對象）、廣告（無）。
9. **商店頁**：文字依 [listing.md](listing.md)，上傳圖示、主視覺圖、截圖。
10. **送審**。

## 每次發版

1. 跑 Windows 發佈流程（`release-windows.yml`），產生 tag、版本號 commit 與 GitHub Release 草稿。
2. 跑 Android 發佈流程（`release-android.yml`），輸入**同一個 tag**；AAB 會上傳到「內部測試」軌道。App 正式上架前，`release_status` 要選 `draft`（Play 不允許從未發佈過的 App 建立非草稿版本）。
3. 在 Play Console 把該版本升級到正式版，並手動填寫「新功能」（CI 不會自動填）。

**預覽版（`-rc.N`）只放內部測試，不要升級到正式版**：App 內的更新說明取自 GitHub，而 GitHub 查詢會略過預覽版；升到正式版後，玩家會看不到它的更新內容。

## 上架後

- 在 `.github/release-footer.md` 與 README ×4 加上 Google Play 下載徽章（使用 Google 官方提供的徽章圖片），點擊連到商店頁。
