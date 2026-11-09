# 隱私權政策 Privacy Policy

適用於「喚取卡池分析 for 鳴潮」（套件名稱 `tw.reh.wuwa.gacha`）的 Android 版與 Windows 版。

最後更新：2026-11-09

[繁體中文](#繁體中文) | [English](#english)

## 繁體中文

本 App 是玩家自製的非官方工具，與庫洛遊戲（Kuro Games）無關。開發者沒有架設任何伺服器，也不會收到你的任何資料。

### 存在你裝置上的資料

- 喚取紀錄、帳號 UID 與你設定的別名。
- 查詢喚取紀錄用的網址參數（從鳴潮的記錄檔或你手動輸入的網址取得）。
- App 設定與執行紀錄（log）。
- Android 版：你在 Google 廣告同意視窗的選擇。

以上資料存在你的裝置上，在 App 內刪除帳號會一併刪除該帳號的資料。

- **Android 版**：解除安裝 App 會刪除裝置上的資料。Android 的系統備份可能會把 App 資料（喚取紀錄、設定）備份到你自己的 Google 帳號，是否備份由你裝置上的備份設定決定；重新安裝或換新裝置時，系統可能會還原這份備份。加密保存的憑證（例如無線偵錯的配對金鑰）不會備份，還原後需要重新配對。
- **Windows 版**：資料存在 `%APPDATA%\tw.reh\wuthering_waves_convene_gacha_analyzer`。解除安裝時會詢問是否一併刪除，預設保留；保留的話可以之後自行刪除這個資料夾。解除安裝時一定會嘗試移除本機產生的根憑證（Windows 會跳出一次確認視窗，按「是」才會刪除）並刪除它的私密金鑰資料夾 `%APPDATA%\wuthering_waves_convene_gacha_analyzer\ca`，不受上述「是否刪除資料」的選擇影響。

### 會連線的對象

- **鳴潮官方伺服器**：用上述查詢參數取得你的喚取紀錄。這和你在遊戲內開啟「喚取紀錄」頁面時送出的請求相同。
- **encore.moe**：下載物品名稱、圖示與角色、武器資料。只傳送物品 ID 與語言，不包含你的帳號資料。
- **GitHub**：檢查有沒有新版本、取得更新說明。
- **Google Play**（只限 Android 版）：檢查有沒有新版本、下載更新。
- **Google AdMob**（只限 Android 版）：顯示頁面底部的橫幅廣告，見下方「廣告」。
- **Google 雲端硬碟**（只在你自己開啟雲端同步時）：把喚取紀錄寫入你自己的 Google 雲端硬碟中、只有本 App 能存取的隱藏資料夾（appDataFolder）。App 只會取得你的 Google 帳號 email 用來顯示「已連結哪個帳號」，以及存取這個資料夾的權限。你可以隨時在設定頁中斷連結，並到 Google 帳號的安全性設定移除授權。

### Android 版讀取記錄檔的方式

Android 不允許 App 直接讀取其他 App 的檔案。本 App 會在你按下「更新資料」時，透過系統內建的「無線偵錯」（或你授權的 root）讀取鳴潮的記錄檔，從中找出喚取紀錄網址。

- 只讀取鳴潮的記錄檔，讀完立刻中斷連線；無線偵錯若是本 App 打開的，會一併關閉（你原本就開著的會維持開啟）。
- `WRITE_SECURE_SETTINGS` 權限只用來開關無線偵錯，讓你不用每次手動設定。你可以隨時在設定頁解除。

### 廣告（只限 Android 版）

Android 版會在有內容的頁面底部顯示一則 Google AdMob 橫幅廣告。Windows 版沒有廣告。

- 依 Google 公布的說明，Google Mobile Ads SDK 會自動收集並傳送以下資料給 Google，用於廣告、分析與防止詐騙：裝置的 IP 位址（可能用來推估大致位置）、與廣告的互動（例如 App 啟動、點擊、影片觀看）、效能診斷資訊，以及 Android 廣告 ID、應用程式集 ID 等裝置識別碼。所有資料在傳輸時都經過 TLS 加密。
- 這些資料由 Google 收集與處理，開發者收不到個人資料。詳見 [Google 如何使用合作夥伴網站或應用程式的資訊](https://policies.google.com/technologies/partner-sites)。
- 歐洲經濟區、英國與瑞士的使用者，第一次開啟 App 時會看到 Google 的同意視窗，之後可以在設定頁的「廣告隱私權選項」變更選擇；美國部分州的使用者可以在設定頁的「廣告隱私權選項」選擇退出個人化廣告。拒絕個人化廣告時，仍會顯示非個人化廣告。
- 你可以在 Android 系統設定重設或刪除廣告 ID。
- 廣告內容分級上限為「青少年（T）」。

### Windows 版取得查詢參數的方式

按下「更新資料」後，App 會在你的電腦上啟動一個本機攔截程式（需要系統管理員權限，會跳出一次 UAC 確認），並安裝一張在本機產生的根憑證，只把鳴潮喚取記錄頁面對官方喚取歷史 API 的那一條請求導到本機解析，取得查詢參數。App 也會讀取鳴潮在你電腦上的記錄檔作為備援。

- 除了上述記錄檔之外不讀取其他遊戲檔案，不修改任何遊戲檔案，也不讀取遊戲記憶體；其餘網路流量原樣放行。
- 攔截只在更新期間進行，完成後立即停止並還原網路設定。

### 不會做的事

- 除了 Android 版的廣告（見上方「廣告」），沒有其他分析或追蹤工具；開發者不會販售你的資料。
- 執行紀錄（log）只有在你自己匯出或分享時才會離開裝置。

### 兒童

本 App 不以兒童為對象。

### 聯絡方式

https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer/issues

## English

This app is an unofficial fan-made tool and is not affiliated with Kuro Games. The developer runs no server and receives none of your data.

### Data stored on your device

- Convene history, account UIDs and the aliases you set.
- The URL parameters used to query your convene history (taken from the game's log file or a URL you enter).
- App settings and logs.
- Android: your choices in Google's ad consent form.

This data is stored on your device. Deleting an account in the app removes that account's data.

- **Android**: uninstalling the app removes the data on the device. Android's system backup may back up the app data (convene history, settings) to your own Google account, depending on your device's backup setting, and may restore it when you reinstall or set up a new device. Encrypted credentials (such as the wireless debugging pairing key) are not backed up; after a restore you need to pair again.
- **Windows**: the data is stored in `%APPDATA%\tw.reh\wuthering_waves_convene_gacha_analyzer`. The uninstaller asks whether to delete it and keeps it by default; you can delete that folder yourself later. Uninstalling always tries to remove the locally generated root certificate (Windows asks you to confirm once; it is deleted only if you choose Yes) and deletes its private key folder `%APPDATA%\wuthering_waves_convene_gacha_analyzer\ca`, whatever you choose about the data.

### Services the app connects to

- **Wuthering Waves official servers**: to fetch your convene history with the parameters above. This is the same request the game sends when you open the Convene History page.
- **encore.moe**: to download item names, icons, and character and weapon data. Only item IDs and the language are sent, never your account data.
- **GitHub**: to check for new versions and fetch release notes.
- **Google Play** (Android only): to check for and download updates.
- **Google AdMob** (Android only): to show the banner ad at the bottom of the screen; see "Ads" below.
- **Google Drive** (only if you turn on cloud sync yourself): the app writes your convene history to a hidden folder in your own Google Drive that only this app can access (appDataFolder). The app only gets your Google account email, to show which account is linked, and access to that folder. You can unlink at any time in Settings and remove the access in your Google Account security settings.

### How the Android version reads the game's log

Android doesn't let apps read other apps' files. When you tap "Update", the app reads the game's log file through Android's built-in Wireless debugging (or root, if you grant it) to find the convene history URL.

- It reads only the game's log file, then disconnects right away and turns wireless debugging off again if the app turned it on (if you already had it on, it stays on).
- The `WRITE_SECURE_SETTINGS` permission is used only to turn wireless debugging on and off, so you don't have to set it up each time. You can remove it at any time in Settings.

### Ads (Android only)

The Android version shows one Google AdMob banner ad at the bottom of pages that have content. The Windows version has no ads.

- According to Google's disclosure, the Google Mobile Ads SDK automatically collects and sends the following data to Google for advertising, analytics and fraud prevention: the device's IP address (which may be used to estimate its general location), interactions with ads (such as app launches, taps and video views), performance diagnostics, and device identifiers such as the Android advertising ID and app set ID. All of it is encrypted in transit with TLS.
- This data is collected and processed by Google; the developer does not receive personal data. See [How Google uses information from sites or apps that use our services](https://policies.google.com/technologies/partner-sites).
- Users in the European Economic Area, the UK and Switzerland see Google's consent form the first time they open the app, and can change their choice later under "Ad privacy options" in Settings. Users in some US states can opt out of personalized ads under "Ad privacy options" in Settings. If you decline personalized ads, non-personalized ads are still shown.
- You can reset or delete your advertising ID in Android's system settings.
- Ad content is limited to the "Teen (T)" rating.

### How the Windows version gets the query parameters

When you click "Update", the app starts a local interception helper on your computer (it needs administrator rights, so Windows shows a UAC prompt once) and installs a root certificate generated on your computer. Only the one request the game's Convene History page sends to the official convene history API is redirected to the app to read the query parameters. The app also reads the game's log file on your computer as a fallback.

- Apart from that log file it reads no game files, it never modifies game files or reads game memory, and all other network traffic passes through untouched.
- Interception runs only during an update; it stops and restores the network settings right after.

### What the app does not do

- Apart from the ads in the Android version (see "Ads" above), no analytics or tracking tools; the developer never sells your data.
- Logs leave your device only when you export or share them yourself.

### Children

This app is not directed at children.

### Contact

https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer/issues
