# 鳴潮喚取卡池分析 Wuthering Waves Convene Gacha Analyzer

[繁體中文](README.md) | [简体中文](README_ZH-HANS.md) | English | [日本語](README_JA-JP.md)

[![Crowdin](https://badges.crowdin.net/wuthering-waves-convene-gacha-analyzer/localized.svg)](https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer)

A convene history analyzer for Windows and Android, with all data and numbers well-organized in a convenient manner.

On Windows, when you press *Update*, the utility starts a local interception helper (running only on your computer; it requires administrator privileges, so you'll see a one-time UAC prompt — click Yes) and automatically installs a locally generated root certificate. It then redirects Wuthering Waves' convene-record page request to the official convene history API to your local machine for parsing, so it can capture that one request. You therefore need to open the convene record page in the game *after* pressing *Update*, so the request can be captured. The captured request is parsed for the parameters needed to query your convene records, which are then used to call the official API. Interception only runs during the update and stops immediately once done, restoring your network state.

The Android version can't intercept network traffic, so it reads the log file that Wuthering Waves writes and finds the convene history URL there. Android doesn't let apps read other apps' files directly, so depending on the device it reads the file via root, direct file access (Android 10 or earlier), or the system's built-in *Wireless debugging*. When using Wireless debugging, it disconnects as soon as it's done reading, and if the app turned Wireless debugging on, it turns it back off.

The first time you press *Update*, the utility loads your full convene history, which may take a while. The data is then stored locally so you don't have to wait again on the next launch. To pull new records, just press *Update*: the utility remembers the previously obtained parameters and reuses them as long as they're still valid, so you don't have to obtain them again every time. If the captured parameters have expired, the utility will ask you to open the convene record page in the game again to get new ones.

Rest assured: this utility does not modify any game file, does not read or modify game memory, and does not affect how the game runs. On Windows it only intercepts and parses that single request to the official convene history API to obtain the query parameters, and all other traffic passes through untouched; on Android it only reads the game's log file. So there is no risk of being banned for using it. If you have been banned, it was likely for a different reason. Please do not blame us, thanks.

Posts:
- 巴哈姆特 (Bahamut): <https://forum.gamer.com.tw/C.php?bsn=74934&snA=17364>

## Multiple Language

Please help us translate this software.

<https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer>

## Download Software

The utility may trigger anti-virus software during installation and execution. This is because it generates and installs a local root certificate, and when you press *Update* it launches an interception helper with administrator privileges (bundling the [WinDivert](https://github.com/basil00/WinDivert) kernel driver) that redirects the convene-record page request to your local machine — behavior (installing a certificate, loading a kernel driver, redirecting traffic) that resembles malware and is especially prone to false positives. However, the utility only intercepts the official convene history API, the certificate stays on your computer, and the source code is open for inspection. If the utility doesn't function correctly, please try disabling any anti-virus software you have installed. We guarantee this utility is safe and virus-free.

<https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer/releases>

### Versions for Other Games

- Genshin Impact: <https://github.com/GoneTone/genshin-impact-wish-gacha-analyzer>
- More games may be supported in the future...

## How to Use

### Windows

1. Launch Wuthering Waves (don't open the convene record page yet).
2. Open this utility and press *Update*. The utility will start a local interception helper (a one-time UAC administrator prompt will appear — click Yes) and wait for the request.
3. Switch back to the game and open *Convene → Convene Records* to view the convene record page.
4. Once captured, the utility automatically stops the interception, restores your network state, and starts fetching your data. To update again later, just repeat step 2 — the captured URL will be reused if still valid.

### Android

1. The first time you press *Update*, the app walks you through setting up how it reads the game's log file. Rooted devices and devices on Android 10 or earlier read it directly; other devices use the system's built-in *Wireless debugging*: pair once by following the on-screen steps, and from then on the app turns Wireless debugging on and off by itself.
2. After pressing *Update*, switch to the game and open *Convene → Convene Records* to view the convene record page.
3. Once the app finds the URL in the game's log file, it starts fetching your data automatically.
4. If Wireless debugging isn't available (for example, when you're not on Wi‑Fi), you can enter the convene history URL manually instead.

## Features

- Runs on Windows and Android
- Gets the convene history URL automatically — no need to paste URLs by hand: on Windows it intercepts the convene-record page request to the official convene history API via a local interception helper and a self-signed root certificate; on Android it reads the game's log file (via root, direct file access, or Wireless debugging)
- Supports the Global server (CN server not supported yet)
- Covers all 12 convene types: Featured Resonator Convene, Featured Weapon Convene, Standard Resonator Convene, Standard Weapon Convene, Beginner Convene, Beginner's Choice Convene, New Voyage Resonator Convene, New Voyage Weapon Convene, Collab Resonator Convene, Collab Weapon Convene, Reverb Resonator Convene, Reverb Weapon Convene
- Multi-account (UID) management: custom aliases, drag-to-reorder, one-click switching
- Incremental updates merge new records without overwriting old ones, so entries that fall off the official history won't disappear
- Total pulls and 5★ / 4★ / 3★ counts with their share of the total
- Dual pity progress (5★ and 4★) showing remaining pulls until pity
- Average pulls per 5★ / 4★ hit (per-banner and overall)
- Per-banner 5★ timeline
- 5★ overview: every distinct 5★ you've pulled laid out in a row, each with a cumulative count badge and clickable for details — shown on each banner page, the overview page, and the share image
- Bar chart comparing each banner's highest-rarity counts
- Rarity distribution pie chart
- Item type distribution pie chart
- Convene history table: multi-column sort, keyword search (by name), rarity and item-type filters, pagination
- Auto-fetched item icons (from the encore.moe API): characters, weapons, and items all have icons, shown in the table, timelines, and the 5★ overview
- Click any item for details: characters show the introduction, element, weapon type, and switchable Outfit and Convene artwork (the Convene art is captured live from encore's rendered canvas on your machine and cached — no artwork is redistributed); weapons show their description and weapon type
- Generate a share image in one click (dark / light theme, full UID or first-3-digits mask), then copy it to the clipboard or save it as a PNG file; on Android you can also share it directly through the system share sheet
- Export / Import accounts as JSON
- Cloud sync: link your own Google account to automatically back up convene records to your Google Drive and keep multiple devices in sync; deleting an account can optionally remove it from the cloud data too
- Dark / Light theme toggle
- Multi-language ([help us translate](https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer))
- Optional UID masking in the UI (first 3 digits only) for added privacy
- Automatic update check on launch, with a manual trigger in Settings (the Android version updates through Google Play)
- All data stays on your machine by default — nothing is uploaded; cloud sync is opt-in and backs up only to your own Google Drive
- The Android version shows AdMob native ads (consent is requested first in regions that require it); the Windows version has no ads

## Supported Third-Party Import Platforms

Besides importing this utility's own backup files, you can also import convene history data exported from the following third-party platforms (Settings → *Import from other platforms*):

- [WuWa Tracker](https://wuwatracker.com/)
- More platforms may be supported in the future...

## Screenshot

### Windows

![Waiting for the Convene Records page](docs/images/en/windows/1.png)
![Overview page](docs/images/en/windows/2.png)
![Character Event Convene page](docs/images/en/windows/3.png)
![Weapon Event Convene page](docs/images/en/windows/4.png)
![Share image options](docs/images/en/windows/5.png)
![Share image](docs/images/en/windows/6.png)
![Item details](docs/images/en/windows/7.png)
![Settings page](docs/images/en/windows/8.png)

### Android phone

<p>
<img src="docs/images/play-store/screenshots/en/phone/1.png" alt="Overview page" width="24%">
<img src="docs/images/play-store/screenshots/en/phone/2.png" alt="Character Event Convene page" width="24%">
<img src="docs/images/play-store/screenshots/en/phone/3.png" alt="5★ timeline and 5★ overview" width="24%">
<img src="docs/images/play-store/screenshots/en/phone/4.png" alt="Weapon Event Convene page" width="24%">
<img src="docs/images/play-store/screenshots/en/phone/5.png" alt="Item details" width="24%">
<img src="docs/images/play-store/screenshots/en/phone/6.png" alt="Share image options" width="24%">
<img src="docs/images/play-store/screenshots/en/phone/7.png" alt="Waiting for the Convene Records page" width="24%">
<img src="docs/images/play-store/screenshots/en/phone/8.png" alt="Settings page" width="24%">
</p>

### Android tablet

<p>
<img src="docs/images/play-store/screenshots/en/tablet-10/1.png" alt="Overview page" width="49%">
<img src="docs/images/play-store/screenshots/en/tablet-10/2.png" alt="Character Event Convene page" width="49%">
<img src="docs/images/play-store/screenshots/en/tablet-10/3.png" alt="5★ timeline and 5★ overview" width="49%">
<img src="docs/images/play-store/screenshots/en/tablet-10/4.png" alt="Weapon Event Convene page" width="49%">
<img src="docs/images/play-store/screenshots/en/tablet-10/5.png" alt="Item details" width="49%">
<img src="docs/images/play-store/screenshots/en/tablet-10/6.png" alt="Share image options" width="49%">
<img src="docs/images/play-store/screenshots/en/tablet-10/7.png" alt="Waiting for the Convene Records page" width="49%">
<img src="docs/images/play-store/screenshots/en/tablet-10/8.png" alt="Settings page" width="49%">
</p>

## Development

### Prerequisites

- Build the Windows version on Windows; the Android version also needs [Android Studio](https://developer.android.com/studio) (Android SDK)
- [Flutter SDK](https://docs.flutter.dev/install) (latest stable)
- [Rust toolchain](https://rustup.rs/) (stable)
- Run `flutter doctor` and install anything it flags as missing

### Clone and install dependencies

```bash
git clone https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer.git
cd wuthering-waves-convene-gacha-analyzer
flutter pub get
```

Rust is compiled automatically by `rust_builder/`'s cargokit during `flutter run` / `flutter build`; no manual `cargo build` is needed (the Rust toolchain must be installed first).

### Run in development mode

```bash
flutter run -d windows        # Windows
flutter run -d <device id>    # Android device or emulator (find the ID with flutter devices)
```

### Cloud sync credentials (optional)

Cloud sync (Google Drive backup) requires Google OAuth credentials. Without them everything else works normally; the cloud sync section in Settings simply shows an "unconfigured" notice.

To enable it in your own build:

1. In the [Google Cloud Console](https://console.cloud.google.com/), create a project, enable the **Google Drive API**, configure the OAuth consent screen (scopes: `.../auth/drive.appdata` and `email`), and create a **Desktop app** OAuth client.
2. Create `secrets/cloud_sync_defines.json` at the project root (git-ignored):

   ```json
   {
     "CLOUD_SYNC_CLIENT_ID": "your client id",
     "CLOUD_SYNC_CLIENT_SECRET": "your client secret"
   }
   ```

3. Pass the file when running (JetBrains IDEs can use the bundled "main.dart (cloud sync + ads)" run configuration, which also passes `secrets/ads_defines.json` below, so both files must exist; `build_release.ps1` picks the file up automatically when packaging):

   ```bash
   flutter run -d windows --dart-define-from-file=secrets/cloud_sync_defines.json
   ```

4. Android reuses the same `secrets/cloud_sync_defines.json`, but you must also create an **Android** OAuth client in the **same** Google Cloud project: package name `tw.reh.wuwa.gacha`, and the SHA-1 of the key that signs the APK (for the debug key, run `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android`). This client's ID does not go into the defines file; Google matches the app by package name and signature. It must live in the same project as the desktop client, otherwise the phone and the PC see different sync files.

   ```bash
   flutter run -d <device id> --dart-define-from-file=secrets/cloud_sync_defines.json
   ```

### Ad IDs (optional, Android)

The AdMob IDs for the Android native ads are also injected at build time and never committed. To serve real ads in your own build, create `secrets/ads_defines.json` at the project root (git-ignored) and pass it together with the cloud sync file:

```json
{
  "ADMOB_APP_ID": "ca-app-pub-xxxxxxxxxxxxxxxx~yyyyyyyyyy",
  "ADMOB_NATIVE_UNIT_ID": "ca-app-pub-xxxxxxxxxxxxxxxx/wwwwwwwwww"
}
```

```bash
flutter run -d <device id> --dart-define-from-file=secrets/cloud_sync_defines.json --dart-define-from-file=secrets/ads_defines.json
```

Without this file, or in any non-release build, Google's official test ad IDs are used and only test ads are shown.

### Rust ↔ Dart bridge code generation

After changing Rust functions in `rust/src/api/`, regenerate the bridge code. Install the codegen tool on first use:

```bash
cargo install flutter_rust_bridge_codegen --version 2.12.0
```

Then run this whenever the API changes:

```bash
flutter_rust_bridge_codegen generate
```

Generated files live in `lib/src/rust/`.

### Build for release

Windows:

```bash
flutter build windows --release
```

Output: `build\windows\x64\runner\Release\`

Android:

```bash
flutter build apk --release        # APK for direct install
flutter build appbundle --release  # AAB for Google Play upload
```

Output: `build/app/outputs/flutter-apk/app-release.apk`, `build/app/outputs/bundle/release/app-release.aab`

To sign with your own key, fill in `storeFile`, `storePassword`, `keyAlias` and `keyPassword` in `android/key.properties` (git-ignored); without that file the build is signed with the debug key.

### Run tests

```bash
flutter test
cargo test --manifest-path rust/Cargo.toml
```
