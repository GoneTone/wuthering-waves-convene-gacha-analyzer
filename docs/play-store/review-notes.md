# 審查說明

Play Console →「應用程式內容」→「應用程式存取權」，以及申請 `WRITE_SECURE_SETTINGS` 等敏感權限時的說明欄。審查人員看的是英文，所以以下以英文為主，中文為對照。

## 給審查人員的說明（貼到 Console）

```
This app is an unofficial, open-source tool that analyzes the player's own Wuthering Waves convene (gacha) history. No login to our service is needed; the developer runs no server.

HOW TO TEST WITHOUT A WUTHERING WAVES ACCOUNT
1. Open the app and tap "Update".
2. Choose "Enter manually instead" (or tap "Enter convene history manually" on the progress screen).
3. Tap "Choose Client.log file" and pick any text file, or paste any text. The app reports that no URL was found; this is the expected result without a game account.
To see the analysis screens with data, go to Settings → "Import from other platforms" and import the sample file linked below, or import a JSON backup.
Sample data: <填入範例檔網址>

WHY WRITE_SECURE_SETTINGS AND WIRELESS DEBUGGING
Android doesn't let one app read another app's files. To find the convene history URL, the app reads only Wuthering Waves' own log file through Android's built-in Wireless debugging, the same mechanism a player would use from a PC with adb:
• Every step is started by the player (tapping "Update"); the first time, the player pairs the device in system settings with a pairing code.
• The app connects to the device's own adb service, reads only the game's log file, then disconnects and turns wireless debugging off right away.
• WRITE_SECURE_SETTINGS is granted by the player once through that adb connection. It is used only to switch wireless debugging (adb_wifi_enabled) on before reading and off afterwards, so the player doesn't have to do it by hand each time.
• The player can remove the pairing and the permission at any time in Settings.
Alternatives offered in the app: root (if the player grants it), direct reading on Android 10 and below, and manual URL entry.
```

## 中文對照（自己確認用）

- 審查人員沒有鳴潮帳號時，可以走手動輸入，確認找不到網址時的訊息；要看分析畫面，用設定頁的匯入功能匯入範例檔。
- 範例檔：上架前從自己的帳號匯出一份，把 UID 改成假的，放在 repo 或 GitHub Release，把網址填進上面的 `<填入範例檔網址>`。
- `WRITE_SECURE_SETTINGS` 只用來開關無線偵錯；每一步都由玩家觸發；只讀鳴潮的記錄檔；可以隨時在設定頁解除。
