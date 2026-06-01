# Rename & De-Genshin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 把整個 fork 的識別名與品牌字串從「原神祈願（Genshin Impact Wish）」全面去原神化、改名為「鳴潮喚取（Wuthering Waves Convene）」，涵蓋 Dart 套件名／import 前綴、Rust crate、自簽根 CA subject、Windows 原生品牌資源、GitHub/Crowdin 座標、README ×3（整檔改寫為最終鳴潮版）與 Inno Setup 安裝檔（與原神版並存不覆蓋）。**ARB 字串改動不在本 plan 範圍——所有 ARB key（含 `appName` 四語）一律歸 plan07（UI/i18n）。**

**Architecture:** 純命名／品牌遷移，不碰任何業務邏輯。改名點分三類 lockstep 群組：(1) Dart 套件名 `genshin_impact_wish_gacha_analyzer` → `wuthering_waves_convene_gacha_analyzer`（pubspec `name` + 全庫 import 前綴，純機械字串替換，編譯為唯一驗證）；(2) Rust crate `genshin_capture_core` → `gacha_capture_core`，須與 `windows/CMakeLists.txt`、`flutter_rust_bridge.yaml`、`lib/src/rust/frb_generated.dart` 的 `ExternalLibraryLoaderConfig.stem` 同步，否則 FRB 載 DLL 失敗；(3) 自簽 CA subject CN/Org 去原神化＝產生全新 root CA，正好讓鳴潮版與原神版各自獨立安裝、互不干擾。

**Tech Stack:** Flutter (Dart 3.11)、flutter_rust_bridge 2.12、Rust crate `gacha_capture_core`（rcgen/x509-parser 自簽 CA）、CMake + cargokit、Inno Setup 6。（ARB／gen-l10n 不在本 plan 範圍，所有 ARB key 改動歸 plan07。）

---

## 前置事實（已實際 Read/Grep 驗證，2026-06-01）

- 本目錄**非 git repo**（無 `.git`）。下文每個 Task 末尾仍照寫 commit 步驟；執行者若選擇不 `git init`，則略過 commit 步驟、其餘照做。
- **此遷移是一連串 plan**：型別替換期間整體 compile 可能短暫紅燈，至全部 plan 完成才全綠。本 plan（純命名／品牌）改完後，`flutter analyze` 仍可能因**其他 plan 尚未完成**而報錯；本 plan 的驗證標準是「**改名引入的錯誤數為 0**」——即改名前後 `flutter analyze` 的錯誤集合差異只剩其他 plan 的既有缺口，**不得新增因 import 前綴／crate 名不一致造成的錯誤**。最終全綠 build 收尾為 plan07（UI/i18n）的最後一個 Task。
- **import 前綴實測數字**：`package:genshin_impact_wish_gacha_analyzer/` 在 `lib/`+`test/` 共 **180 檔 / 754 處**（`grep -rln` / `grep -rho` 實測）。spec 文中「1721 處／240 檔」與實測不符，**以本 plan 實測為準**；無論幾處，做法都是純字串替換 + 編譯驗證。
- **bare name `genshin_impact_wish_gacha_analyzer`** 另出現於非 Dart 檔：`windows/CMakeLists.txt`、`windows/runner/Runner.rc`、`pubspec.yaml`、`installer.iss`（路徑常數）、`ca.rs`（appdata 目錄名）。
- **`genshin_capture_core`** 出現於：`rust/Cargo.toml:2`、`rust/Cargo.lock:820`、`windows/CMakeLists.txt:61,64,97`、`lib/src/rust/frb_generated.dart:72`、`AGENTS.md:13`。
- **CA subject**：`rust/src/ca.rs:12-13` 的 `EXPECTED_CN`/`EXPECTED_ORG`，及 appdata 目錄字串 `ca.rs:20`、測試 `ca.rs:217`。
- **`appName` ARB**：四語 zh/zh_Hans/en/ja 各一行；無 `@appName` metadata block。window title 來自 `main.dart:173` 讀 `appName`。
- **`actionViewOnHoYoWiki`** 在 `lib/widgets/dialogs/gacha_item_detail_dialog.dart:511` 被引用——**key 與引用移除、ARB 值改動皆歸 plan07（UI/i18n）**；本 plan 完全不碰 ARB，也不動 dialog 程式碼。

---

## 改名對照總表（全 plan 一律用這些確切名稱）

| 項目 | 舊 | 新 |
|----|----|----|
| Dart 套件名 / import 前綴 | `genshin_impact_wish_gacha_analyzer` | `wuthering_waves_convene_gacha_analyzer` |
| Rust crate / DLL stem | `genshin_capture_core` | `gacha_capture_core` |
| CA CommonName | `Genshin Impact Wish Gacha Analyzer Root CA` | `Wuthering Waves Convene Gacha Analyzer Root CA` |
| CA Organization | `GoneTone` | `GoneTone`（保留，個人識別非原神名詞） |
| CA appdata 目錄 | `genshin_impact_wish_gacha_analyzer\ca` | `wuthering_waves_convene_gacha_analyzer\ca` |
| 視窗標題（main.cpp splash） | `原神祈願卡池分析` | `鳴潮喚取卡池分析` |
| GitHub repo | `GoneTone/genshin-impact-wish-gacha-analyzer` | `GoneTone/wuthering-waves-convene-gacha-analyzer` |
| Crowdin slug | `genshin-impact-wish-gacha-analyzer` | `wuthering-waves-convene-gacha-analyzer` |
| appName zh（※ ARB 由 plan07 負責，本表僅供跨 plan 參照） | `原神祈願卡池分析` | `鳴潮喚取卡池分析` |
| appName zh_Hans（※ plan07） | `原神祈愿卡池分析` | `鸣潮唤取卡池分析` |
| appName en（※ plan07） | `Genshin Impact Wish Gacha Analyzer` | `Wuthering Waves Convene Gacha Analyzer` |
| appName ja（※ plan07，釘死值） | `原神祈願分析ツール` | `鳴潮 集音分析ツール` |
| installer AppId GUID | `{50C50DF7-CB14-4D51-9618-0E5116DDA065}` | `{27F3CD23-7E15-4570-8EBB-79D2801C9C85}`（釘死字面值） |
| installer userdata 路徑 | `tw.reh\genshin_impact_wish_gacha_analyzer` | `tw.reh\wuthering_waves_convene_gacha_analyzer` |

---

## Task 0：建立基準（記錄改名前 analyze 缺口）

**Files:**
- Read-only：建立改名前 `flutter analyze` 的錯誤基準快照，供後續 Task 比對「改名是否新增錯誤」。

- [ ] 跑 `flutter pub get` 確保依賴就緒（指令：`flutter pub get`；預期：`Got dependencies!` 或 `Resolving dependencies...` 成功結束）。
- [ ] 跑基準 analyze 並把輸出存到暫存檔：`flutter analyze > analyze_baseline.txt 2>&1`（**此檔不 commit，僅供本地比對**；若已全綠會輸出 `No issues found!`）。
- [ ] 記下 baseline 錯誤數：執行 `Select-String -Path analyze_baseline.txt -Pattern "error " | Measure-Object | Select-Object -ExpandProperty Count`，記住這個數字 `N0`。後續每個 Task 改名後重跑 analyze，**錯誤數必須 ≤ N0**（不得因改名新增錯誤；其他 plan 的既有缺口允許存在）。
- [ ] （無 git 則略）若選擇版本控管，先 `git init` 並 `git add -A && git commit -m "chore: snapshot before wuwa rename migration"`，commit message 結尾加：
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

---

## Task 1：Dart 套件改名 + 全庫 import 前綴機械替換

**Files:**
- Modify: `pubspec.yaml`（行 1 `name:`、行 2 `description:`）
- Modify（機械替換，180 檔）：`lib/**/*.dart` + `test/**/*.dart` 中所有 `package:genshin_impact_wish_gacha_analyzer/` → `package:wuthering_waves_convene_gacha_analyzer/`（754 處）
- 不碰：`rust_builder/`（vendored）、`lib/src/rust/frb_generated.dart` 的 `stem`（屬 Task 3）、其他字面值

**步驟：**

- [ ] 先精確統計待替換範圍，確認與基準一致：`(Get-ChildItem -Recurse -Include *.dart lib,test | Select-String -SimpleMatch "package:genshin_impact_wish_gacha_analyzer/" | Measure-Object).Count`（預期：754）。
- [ ] 改 `pubspec.yaml` 行 1，把
  ```yaml
  name: genshin_impact_wish_gacha_analyzer
  ```
  改為
  ```yaml
  name: wuthering_waves_convene_gacha_analyzer
  ```
- [ ] 改 `pubspec.yaml` 行 2 `description`，把
  ```yaml
  description: "原神祈願卡池分析 Genshin Impact Wish Gacha Analyzer | A utility for analyzing gacha history, where all data and numbers are well-organized in a convenient manner!"
  ```
  改為
  ```yaml
  description: "鳴潮喚取卡池分析 Wuthering Waves Convene Gacha Analyzer | A utility for analyzing gacha history, where all data and numbers are well-organized in a convenient manner!"
  ```
- [ ] 對 `lib/` 與 `test/` 全部 `.dart` 檔做**只替換 import 前綴字串**的機械替換（用 PowerShell，逐檔讀寫、只替換固定子字串，避免誤傷其他字面值）：
  ```powershell
  Get-ChildItem -Recurse -Include *.dart -Path lib,test | ForEach-Object {
      $p = $_.FullName
      $c = Get-Content -Raw -LiteralPath $p
      if ($c -like '*package:genshin_impact_wish_gacha_analyzer/*') {
          $n = $c.Replace('package:genshin_impact_wish_gacha_analyzer/', 'package:wuthering_waves_convene_gacha_analyzer/')
          [System.IO.File]::WriteAllText($p, $n)
      }
  }
  ```
- [ ] 驗證舊前綴已歸零：`(Get-ChildItem -Recurse -Include *.dart lib,test | Select-String -SimpleMatch "package:genshin_impact_wish_gacha_analyzer/" | Measure-Object).Count`（預期：0）。
- [ ] 驗證新前綴出現 754 處：`(Get-ChildItem -Recurse -Include *.dart lib,test | Select-String -SimpleMatch "package:wuthering_waves_convene_gacha_analyzer/" | Measure-Object).Count`（預期：754）。
- [ ] 重抓依賴讓 pub 認得新 package name：`flutter pub get`（預期：`Got dependencies!`）。
- [ ] 跑 analyze 確認**未因改名新增錯誤**：`flutter analyze`。比對：錯誤數應 ≤ Task 0 的 `N0`，且輸出中**不得**出現任何 `Target of URI doesn't exist: 'package:genshin_impact_wish_gacha_analyzer/...'` 或 `Target of URI doesn't exist: 'package:wuthering_waves_convene_gacha_analyzer/...'`（前者代表漏替換、後者代表 pub get 沒生效）。若出現 URI 錯誤，回到替換步驟修到歸零。
- [ ] （驗收前置三檢查）`dart format lib/ test/`（預期：格式化完成、無錯）。
- [ ] commit（無 git 則略）：
  ```
  refactor(pkg): rename Dart package to wuthering_waves_convene_gacha_analyzer

  Mechanical replacement of the package name in pubspec and all
  `package:` import prefixes across lib/ and test/ (754 occurrences in
  180 files). Pure rename, no logic change. Compilation is the only
  verification gate.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

---

## Task 2：Rust crate 改名 `genshin_capture_core` → `gacha_capture_core`（Cargo + CMake）

**Files:**
- Modify: `rust/Cargo.toml`（行 2 `name`）
- Modify: `rust/Cargo.lock`（行 820 `name`，避免 lockfile 與 manifest 不一致）
- Modify: `windows/CMakeLists.txt`（行 61 註解、64 `CARGOKIT_RUST_PROJECT`、97 註解；行 65-66、98-99 透過變數自動帶入無需手改）
- Modify: `AGENTS.md`（行 13 提及 `crate genshin_capture_core`）
- **Task 3 才改** `lib/src/rust/frb_generated.dart` 的 `stem`——但本 Task 末尾需與其 lockstep 一起編譯驗證，故 Task 2、Task 3 合併在同一輪 build 驗證（見 Task 3）。

**步驟：**

- [ ] 改 `rust/Cargo.toml` 行 2，把
  ```toml
  name = "genshin_capture_core"
  ```
  改為
  ```toml
  name = "gacha_capture_core"
  ```
- [ ] 改 `rust/Cargo.lock` 行 820，把
  ```toml
  name = "genshin_capture_core"
  ```
  改為
  ```toml
  name = "gacha_capture_core"
  ```
  （改完下次 `cargo` 會自動修正其他衍生欄位；手改 name 行避免首次 build 前 lockfile 不一致報 warning。）
- [ ] 改 `windows/CMakeLists.txt` 行 60-66 區段，把
  ```cmake
  # === Rust (flutter_rust_bridge) ===
  # Build genshin_capture_core.dll via cargokit and install it next to the exe.
  # lib_name must match the Cargo.toml package name so the dll stem matches what
  # the FRB Dart loader expects (ExternalLibraryLoaderConfig.stem = 'genshin_capture_core').
  set(CARGOKIT_RUST_PROJECT "genshin_capture_core")
  ```
  改為
  ```cmake
  # === Rust (flutter_rust_bridge) ===
  # Build gacha_capture_core.dll via cargokit and install it next to the exe.
  # lib_name must match the Cargo.toml package name so the dll stem matches what
  # the FRB Dart loader expects (ExternalLibraryLoaderConfig.stem = 'gacha_capture_core').
  set(CARGOKIT_RUST_PROJECT "gacha_capture_core")
  ```
- [ ] 改 `windows/CMakeLists.txt` 行 97 註解，把
  ```cmake
  # Install the Rust dynamic library (genshin_capture_core.dll) built by cargokit.
  ```
  改為
  ```cmake
  # Install the Rust dynamic library (gacha_capture_core.dll) built by cargokit.
  ```
- [ ] 改 `AGENTS.md` 行 13，把句中
  ```
  要改 Rust 邏輯改 `rust/`（crate `genshin_capture_core`）
  ```
  改為
  ```
  要改 Rust 邏輯改 `rust/`（crate `gacha_capture_core`）
  ```
  （同步更新 `CLAUDE.md` 若有同句；本 plan 範圍以 AGENTS.md 為準，CLAUDE.md 由執行者視一致性附帶更新。）
- [ ] 驗證 crate 名已全數替換（除 frb_generated.dart 留待 Task 3）：`Select-String -Path rust\Cargo.toml,rust\Cargo.lock,windows\CMakeLists.txt,AGENTS.md -SimpleMatch "genshin_capture_core"`（預期：無輸出）。
- [ ] 跑 Rust 單元測試確認 crate 改名不破壞編譯：`cargo test --manifest-path rust/Cargo.toml`（預期：`test result: ok`；CA 相關測試此時仍用舊 CN，會在 Task 4 改）。
- [ ] commit（無 git 則略；**與 Task 3 共用一個 build 驗證**，但 commit 可分開）：
  ```
  refactor(rust): rename crate genshin_capture_core to gacha_capture_core

  Update Cargo.toml/Cargo.lock package name, CMake CARGOKIT_RUST_PROJECT
  and related comments, and the AGENTS.md crate reference. The FRB DLL
  loader stem is updated in the next commit so build verification covers
  both lockstep ends together.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

---

## Task 3：FRB DLL loader stem lockstep + 完整 build 驗證

**Files:**
- Modify: `lib/src/rust/frb_generated.dart`（行 72 `stem: 'genshin_capture_core'`）

> **為何不手改而是重跑 codegen？** `frb_generated.dart` 是 flutter_rust_bridge 自動產生檔。但本 plan 不改 Rust API 簽名（那歸 plan02 的 Rust 攔截改動），純改 crate 名；FRB 的 `stem` 取自 `flutter_rust_bridge.yaml` 推導的 crate 名。最穩妥是重跑 `flutter_rust_bridge_codegen generate`。若該 CLI 不可用，可**精準手改該行**（stem 字串純命名、不影響其他生成內容），改完仍以 `flutter build windows` 為最終 lockstep 驗證。
>
> **frb codegen 跨 plan 執行順序：** 整個 frb codegen 鏈分兩段——**plan01（本 plan，crate 改名 + codegen）先執行**，**plan02（`CapturedRequest.body` 欄位新增 + codegen）後執行**。因此 plan02 的 codegen 才是**最終一次**，需同時反映本 plan 改名後的 crate stem（`gacha_capture_core`）與 plan02 新增的 body 欄位。本 plan 的 codegen 只負責 stem 同步，不引入任何 API 簽名變更。

**步驟：**

- [ ] 優先：重跑 FRB codegen 讓 stem 自動同步：`flutter_rust_bridge_codegen generate`（預期：成功、`frb_generated.dart` 內 stem 更新為 `gacha_capture_core`）。
- [ ] 若 codegen CLI 不可用，改用精準手改 `lib/src/rust/frb_generated.dart` 行 72，把
  ```dart
        stem: 'genshin_capture_core',
  ```
  改為
  ```dart
        stem: 'gacha_capture_core',
  ```
- [ ] 驗證 stem 已替換、全庫再無 `genshin_capture_core`：`Select-String -Path lib\src\rust\frb_generated.dart -SimpleMatch "genshin_capture_core"`（預期：無輸出），以及 `(Get-ChildItem -Recurse -File rust,windows,lib,AGENTS.md -Exclude *.lock | Select-String -SimpleMatch "genshin_capture_core" | Measure-Object).Count`（預期：0；Cargo.lock 已於 Task 2 改完）。
- [ ] **lockstep 端到端驗證**——實際建置 Windows，確認 cargokit 產出的 DLL stem 與 FRB loader 一致（名稱不一致會在啟動載 DLL 時失敗，build 階段即可抓 cargokit/CMake 不一致）：`flutter build windows --release`（預期：build 成功，產出 `build\windows\x64\runner\Release\gacha_capture_core.dll`）。
- [ ] 確認 DLL 檔名正確：`Test-Path build\windows\x64\runner\Release\gacha_capture_core.dll`（預期：`True`）；並確認舊名不再產出：`Test-Path build\windows\x64\runner\Release\genshin_capture_core.dll`（預期：`False`）。
- [ ] commit（無 git 則略）：
  ```
  refactor(rust): sync FRB DLL loader stem to gacha_capture_core

  Lockstep with the crate rename: update ExternalLibraryLoaderConfig.stem
  so the FRB loader resolves the renamed DLL. Verified by a full
  `flutter build windows --release` producing gacha_capture_core.dll.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

---

## Task 4：自簽 root CA 去原神化（產生新 root CA）

**Files:**
- Modify: `rust/src/ca.rs`（行 12 `EXPECTED_CN`、行 13 `EXPECTED_ORG` 註解保留 Org 不變、行 20 appdata 目錄、行 217-219 測試的 appdata 目錄路徑字串）
- Test: `rust/src/ca.rs` 內既有 `#[cfg(test)] mod tests`（`generated_ca_has_product_identity`、`regenerates_when_identity_is_stale`、`round_trip_generate_and_reload`）

> **為何改 CN ＝ 產生新 root CA：** `subject_identity` 比對 `EXPECTED_CN`/`EXPECTED_ORG`，現存舊憑證 CN 不符即被視為 stale → 自動從 Windows 根存放區移除舊憑證、刪 appdata 檔、重生新 CA。這正好讓鳴潮版安裝**全新獨立的 root CA**，與原神版互不干擾（符合「不覆蓋並存」需求）。Org 維持 `GoneTone`（個人識別、非原神名詞，無需改）。

**步驟（TDD：先讓既有測試以新值失敗，再改實作）：**

- [ ] 先改測試讓它表達新規格——`rust/src/ca.rs` 的 `regenerates_when_identity_is_stale` 測試行 217-219 把 appdata 子目錄字串
  ```rust
          let ca_path_dir = dir
              .path()
              .join("genshin_impact_wish_gacha_analyzer")
              .join("ca");
  ```
  改為
  ```rust
          let ca_path_dir = dir
              .path()
              .join("wuthering_waves_convene_gacha_analyzer")
              .join("ca");
  ```
- [ ] 跑測試確認**現在 fail**（測試已用新目錄名、但 `ca_dir()` 實作仍寫舊目錄，故 stale-regen 測試找不到預置檔而行為改變）：`cargo test --manifest-path rust/Cargo.toml ca::`（預期：`generated_ca_has_product_identity` 仍以舊 CN 通過、但我們接著要改 CN，先記錄這是過渡狀態）。
- [ ] 改 `rust/src/ca.rs` 行 12-13 常數，把
  ```rust
  pub const EXPECTED_CN: &str = "Genshin Impact Wish Gacha Analyzer Root CA";
  pub const EXPECTED_ORG: &str = "GoneTone";
  ```
  改為
  ```rust
  pub const EXPECTED_CN: &str = "Wuthering Waves Convene Gacha Analyzer Root CA";
  pub const EXPECTED_ORG: &str = "GoneTone";
  ```
  （`EXPECTED_ORG` 值不變，僅 CN 去原神化；保留兩行讓 diff 清楚。）
- [ ] 改 `rust/src/ca.rs` 行 15-24 的 `ca_dir()`，把 appdata 子目錄與 doc 字串
  ```rust
  /// Returns `%APPDATA%\genshin_impact_wish_gacha_analyzer\ca\`, creating it if missing.
  pub fn ca_dir() -> Result<PathBuf> {
      let appdata = std::env::var("APPDATA").context("APPDATA environment variable not set")?;
      let dir = PathBuf::from(appdata)
          .join("genshin_impact_wish_gacha_analyzer")
          .join("ca");
  ```
  改為
  ```rust
  /// Returns `%APPDATA%\wuthering_waves_convene_gacha_analyzer\ca\`, creating it if missing.
  pub fn ca_dir() -> Result<PathBuf> {
      let appdata = std::env::var("APPDATA").context("APPDATA environment variable not set")?;
      let dir = PathBuf::from(appdata)
          .join("wuthering_waves_convene_gacha_analyzer")
          .join("ca");
  ```
- [ ] 確認再無原神字眼殘留於 ca.rs：`Select-String -Path rust\src\ca.rs -Pattern "Genshin|genshin_impact"`（預期：無輸出；測試中的 `"GIWA PoC Root CA"` 是刻意用來模擬「舊版殘留 DN」的 stale 樣本，**保留不改**——它代表任何「非 EXPECTED 的舊憑證」都會被重生取代，正是我們要測的 de-genshin 行為）。
- [ ] 跑 CA 測試全綠：`cargo test --manifest-path rust/Cargo.toml ca::`（預期：`test result: ok. 3 passed`；`generated_ca_has_product_identity` 現在斷言新 CN、`regenerates_when_identity_is_stale` 用新 appdata 目錄 + 把 `"GIWA PoC Root CA"` 樣本重生為新 CN）。
- [ ] 跑全 Rust 測試確認無回歸：`cargo test --manifest-path rust/Cargo.toml`（預期：`test result: ok`）。
- [ ] commit（無 git 則略）：
  ```
  refactor(ca): de-genshin root CA subject and appdata path

  Change EXPECTED_CN to the Wuthering Waves brand and move the CA appdata
  directory to wuthering_waves_convene_gacha_analyzer. The CN change makes
  any previously installed Genshin-version root CA be treated as stale and
  regenerated, so the two products install independent root CAs that do not
  interfere. Tests updated to the new identity and path.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

---

## Task 5：Windows 原生品牌資源（splash 標題、Runner.rc、CMake project/BINARY_NAME）

**Files:**
- Modify: `windows/runner/main.cpp`（行 30 splash 視窗標題）
- Modify: `windows/runner/Runner.rc`（行 93、95、97、98 的 FileDescription/InternalName/OriginalFilename/ProductName）
- Modify: `windows/CMakeLists.txt`（行 3 `project()`、行 7 `BINARY_NAME`）

> **lockstep 注意：** `BINARY_NAME` 決定 on-disk exe 檔名 `<name>.exe`，installer 的 `MyAppExeName`（Task 7）與此**必須一致**。Runner.rc 的 `OriginalFilename` 也應對齊新 exe 名。Rust crate stem（Task 2/3）與 exe 名是**兩個獨立識別**，不要混淆——crate＝DLL stem、BINARY_NAME＝exe 名。

**步驟：**

- [ ] 改 `windows/runner/main.cpp` 行 30，把
  ```cpp
    if (!window.Create(L"原神祈願卡池分析", origin, size)) {
  ```
  改為
  ```cpp
    if (!window.Create(L"鳴潮喚取卡池分析", origin, size)) {
  ```
  （此為**初始 splash 標題**；App 啟動後 `main.dart:173` 會用 `appName` 覆寫，但 splash 仍須去原神化。）
- [ ] 改 `windows/CMakeLists.txt` 行 3，把
  ```cmake
  project(genshin_impact_wish_gacha_analyzer LANGUAGES CXX)
  ```
  改為
  ```cmake
  project(wuthering_waves_convene_gacha_analyzer LANGUAGES CXX)
  ```
- [ ] 改 `windows/CMakeLists.txt` 行 7，把
  ```cmake
  set(BINARY_NAME "genshin_impact_wish_gacha_analyzer")
  ```
  改為
  ```cmake
  set(BINARY_NAME "wuthering_waves_convene_gacha_analyzer")
  ```
- [ ] 改 `windows/runner/Runner.rc` 行 93、95、97、98 的四個品牌字串，把
  ```rc
              VALUE "FileDescription", "genshin_impact_wish_gacha_analyzer" "\0"
  ```
  改為
  ```rc
              VALUE "FileDescription", "wuthering_waves_convene_gacha_analyzer" "\0"
  ```
  把
  ```rc
              VALUE "InternalName", "genshin_impact_wish_gacha_analyzer" "\0"
  ```
  改為
  ```rc
              VALUE "InternalName", "wuthering_waves_convene_gacha_analyzer" "\0"
  ```
  把
  ```rc
              VALUE "OriginalFilename", "genshin_impact_wish_gacha_analyzer.exe" "\0"
  ```
  改為
  ```rc
              VALUE "OriginalFilename", "wuthering_waves_convene_gacha_analyzer.exe" "\0"
  ```
  把
  ```rc
              VALUE "ProductName", "genshin_impact_wish_gacha_analyzer" "\0"
  ```
  改為
  ```rc
              VALUE "ProductName", "wuthering_waves_convene_gacha_analyzer" "\0"
  ```
  （`CompanyName "tw.reh"`、`LegalCopyright ... GoneTone` 保留——非原神名詞。）
- [ ] 確認 windows 原生檔再無舊識別名：`Select-String -Path windows\runner\main.cpp,windows\runner\Runner.rc,windows\CMakeLists.txt -Pattern "原神祈願|genshin_impact_wish_gacha_analyzer"`（預期：無輸出）。
- [ ] **build 驗證**——exe 改名 + 原生資源編進去：`flutter build windows --release`（預期：build 成功，產出 `build\windows\x64\runner\Release\wuthering_waves_convene_gacha_analyzer.exe`）。
- [ ] 確認新 exe 名產出、舊 exe 名消失：`Test-Path build\windows\x64\runner\Release\wuthering_waves_convene_gacha_analyzer.exe`（預期：`True`）、`Test-Path build\windows\x64\runner\Release\genshin_impact_wish_gacha_analyzer.exe`（預期：`False`）。
- [ ] commit（無 git 則略）：
  ```
  refactor(windows): rebrand native splash title, version resource and exe name

  Update the Win32 splash window title to the Wuthering Waves brand, the
  Runner.rc version strings, and CMake project()/BINARY_NAME so the on-disk
  executable is wuthering_waves_convene_gacha_analyzer.exe. Verified by a
  full windows release build.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

---

## Task 6：（已移除）ARB 字串改動移交 plan07

> **本 plan 完全不碰 ARB。** 依校正決策表，所有 ARB key 改動（含 `appName` 四語品牌字串、`navSectionGacha`「祈願→喚取」標籤、`progressOpenGameHint`、HoYoWiki UI 字串移除等）一律歸 **plan07（UI/i18n）** 負責並由其執行 `flutter gen-l10n`。本 plan 既不改 ARB 值、也不跑 gen-l10n，以免與 plan07 的 key 所有權重疊。Windows 原生 splash 標題（非 ARB）仍由本 plan Task 5 去原神化；App 啟動後 `main.dart:173` 讀取的 `appName` ARB 由 plan07 改值。
>
> 本 Task 不含任何步驟，保留編號占位以維持後續 Task 編號穩定。

---

## Task 7：Inno Setup 安裝檔去原神化（釘死全新 AppId、新路徑、與原神版並存不覆蓋）

**Files:**
- Modify: `scripts/build_installer/installer.iss`（行 3 註解、8 註解、10 `MyAppId`、11 `MyAppName`、12 `MyAppExeName`、31 `DefaultDirName`、43 `OutputBaseFilename`、103 `DisplayNameNeedle`、234 `UserDataDir`）
- Modify: `scripts/build_installer/build_release.ps1`（行 3 註解、135 `$Output` 檔名）

> **為何換全新 AppId：** 這是**不同產品**，沿用舊 `AppId` 會被 Windows 當成原神版的升級而覆蓋安裝。必須用全新 AppId + 完全不同的 `DefaultDirName`/`OutputBaseFilename`/`UserDataDir`，確保兩版可同機並存、各自獨立資料夾。`MyAppExeName` 必須與 Task 5 的 `BINARY_NAME` 一致。`UserDataDir` 須與 `main.dart` 的 `getApplicationSupportDirectory`（隨 package 改名衍生為 `tw.reh\wuthering_waves_convene_gacha_analyzer`）一致，卸載清資料才指向正確路徑。
>
> **AppId 釘死字面值：** 本產品的 `MyAppId` 為**固定字面值** `{27F3CD23-7E15-4570-8EBB-79D2801C9C85}`——**不要**用 `[guid]::NewGuid()` 動態產生（每次 build 都重生會破壞自身升級路徑）。直接寫死此 GUID 即可（保持 `{...}` 大括號格式，注意 iss 中 `AppId={{#MyAppId}` 的雙大括號跳脫）。它與原神版的 `{50C50DF7-...}` 不同，故兩版互不視為對方的升級。

**步驟：**

- [ ] 改 `installer.iss` 行 3 檔頭註解，把
  ```pascal
  ; Genshin Impact Wish Gacha Analyzer — Inno Setup 安裝檔
  ```
  改為
  ```pascal
  ; Wuthering Waves Convene Gacha Analyzer — Inno Setup 安裝檔
  ```
- [ ] 改 `installer.iss` 行 8 註解（語意調整：本產品專屬的固定 GUID，與原神版不同），把
  ```pascal
  ; AppId 為固定 GUID，任何情況下不得變更（會破壞升級路徑）。
  ```
  改為
  ```pascal
  ; AppId 為本產品專屬的固定 GUID，任何情況下不得變更（會破壞升級路徑）；與原神版不同 GUID 以避免被當成升級而覆蓋安裝。
  ```
- [ ] 改 `installer.iss` 行 10-12 三行品牌常數，把
  ```pascal
  #define MyAppId       "{50C50DF7-CB14-4D51-9618-0E5116DDA065}"
  #define MyAppName     "Genshin Impact Wish Gacha Analyzer"
  #define MyAppExeName  "genshin_impact_wish_gacha_analyzer.exe"
  ```
  改為（`MyAppId` 為釘死字面值，直接照抄、勿動態產生）
  ```pascal
  #define MyAppId       "{27F3CD23-7E15-4570-8EBB-79D2801C9C85}"
  #define MyAppName     "Wuthering Waves Convene Gacha Analyzer"
  #define MyAppExeName  "wuthering_waves_convene_gacha_analyzer.exe"
  ```
  （`MyAppPublisher`/`MyAppURL` 行 13-14 暫保留——非原神識別名、屬發行者品牌，若要改另議；本 Task 聚焦防覆蓋的識別欄位。）
- [ ] 改 `installer.iss` 行 31 `DefaultDirName`，把
  ```pascal
  DefaultDirName={commonpf}\Genshin_Impact_Wish_Gacha_Analyzer
  ```
  改為
  ```pascal
  DefaultDirName={commonpf}\Wuthering_Waves_Convene_Gacha_Analyzer
  ```
- [ ] 改 `installer.iss` 行 43 `OutputBaseFilename`，把
  ```pascal
  OutputBaseFilename=Genshin_Impact_Wish_Gacha_Analyzer-Setup-{#MyAppVersion}
  ```
  改為
  ```pascal
  OutputBaseFilename=Wuthering_Waves_Convene_Gacha_Analyzer-Setup-{#MyAppVersion}
  ```
- [ ] 改 `installer.iss` 行 103 `DisplayNameNeedle`（舊版偵測比對字串——改成鳴潮品牌，避免誤判原神版為「自己的舊版」而連帶卸載），把
  ```pascal
    DisplayNameNeedle = 'Genshin Impact Wish Gacha Analyzer';
  ```
  改為
  ```pascal
    DisplayNameNeedle = 'Wuthering Waves Convene Gacha Analyzer';
  ```
- [ ] 改 `installer.iss` 行 234 `UserDataDir`（卸載清資料路徑——須對齊 package 改名後的 appdata 衍生目錄），把
  ```pascal
    UserDataDir := ExpandConstant('{userappdata}\tw.reh\genshin_impact_wish_gacha_analyzer');
  ```
  改為
  ```pascal
    UserDataDir := ExpandConstant('{userappdata}\tw.reh\wuthering_waves_convene_gacha_analyzer');
  ```
- [ ] 改 `build_release.ps1` 行 3 註解，把
  ```powershell
  # Genshin Impact Wish Gacha Analyzer — Windows 一鍵打包腳本
  ```
  改為
  ```powershell
  # Wuthering Waves Convene Gacha Analyzer — Windows 一鍵打包腳本
  ```
- [ ] 改 `build_release.ps1` 行 135 `$Output`（須與 iss 的 `OutputBaseFilename` 一致），把
  ```powershell
  $Output = Join-Path $InstallerDir "Genshin_Impact_Wish_Gacha_Analyzer-Setup-$Version.exe"
  ```
  改為
  ```powershell
  $Output = Join-Path $InstallerDir "Wuthering_Waves_Convene_Gacha_Analyzer-Setup-$Version.exe"
  ```
- [ ] 確認 installer/build 腳本再無原神識別名：`Select-String -Path scripts\build_installer\installer.iss,scripts\build_installer\build_release.ps1 -Pattern "Genshin|genshin_impact|50C50DF7"`（預期：無輸出；若 `MyAppPublisher`「原神資訊站」保留則人工確認那是發行者品牌、屬另議範圍）。
- [ ] 確認釘死的 `MyAppId` 已寫入：`Select-String -Path scripts\build_installer\installer.iss -SimpleMatch "27F3CD23-7E15-4570-8EBB-79D2801C9C85"`（預期：命中一行 `#define MyAppId`）。
- [ ] 確認 `MyAppExeName` 與 Task 5 `BINARY_NAME` 一致：兩者皆為 `wuthering_waves_convene_gacha_analyzer`（人工核對）。
- [ ] （可選，需 Inno Setup 6 + Rust toolchain）端到端打包驗證：`.\scripts\build_installer\build_release.ps1`（預期：產出 `build\installer\Wuthering_Waves_Convene_Gacha_Analyzer-Setup-<version>.exe`）。若環境無 ISCC/cargo，跳過此步、僅靠靜態核對。
- [ ] commit（無 git 則略）：
  ```
  build(installer): rebrand installer with a dedicated AppId for side-by-side install

  Pin MyAppId to the product's fixed GUID {27F3CD23-7E15-4570-8EBB-79D2801C9C85}
  (distinct from the Genshin version's GUID, not dynamically generated) and rename
  MyAppName/MyAppExeName/DefaultDirName/OutputBaseFilename/UserDataDir/
  DisplayNameNeedle to the Wuthering Waves brand so the new product installs to its
  own paths and does not overwrite the Genshin version. UserDataDir aligns with the
  renamed appdata directory. build_release.ps1 output name updated to match.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

---

## Task 8：GitHub/Crowdin 座標與品牌文件（app_repo、contributors、README ×3、.github、AGENTS）

**Files:**
- Modify: `lib/data/app_repo.dart`（行 11 `repo`；`owner` 保留 `GoneTone`）
- Modify: `lib/data/contributors.dart`（行 42 `githubContributorsUrl`、行 46 `translationCrowdinUrl`、行 50 `licenseUrl`；testers 行 26 的 hoyolab 個人連結保留——是貢獻者自己的頁面）
- Modify: `.github/release-footer.md`（行 6 Crowdin URL）
- Rewrite（整檔，由本 plan 完全擁有）：`README.md`、`README_EN.md`、`README_ZH-HANS.md`（標題、repo/Crowdin slug、卡池說明、稀有度、圖片來源敘述一律改為最終鳴潮版：8 卡池、無頌願、guide-server 角色圖／武器道具無圖、3/4/5★ 無 2★）
- 不改：`.github/FUNDING.yml`（無原神識別名、只有 reh.tw/paypal 個人贊助連結）、`.github/dependabot.yml`（無品牌）

> **range 註：** `lib/data/app_repo.dart` 的 `githubUrl`/`apiBase` 由 `owner`/`repo` 字串插值組出（行 14、17），改 `repo` 一行即全專案套用——這正是該檔 dartdoc（行 1-2）設計意圖。**更新檢查 API 指向新 repo**：spec §G 提到「不改更新檢查 404」是指**保留 owner/repo 指到一個真實存在的 release 來源**；改 repo slug 後須確保 GitHub 上有對應 repo（否則更新檢查 404）——這屬發布前置，本 Task 只改字串、實際 repo 建立由維護者處理，**在 plan 標注此依賴**。

**步驟：**

- [ ] 改 `lib/data/app_repo.dart` 行 11，把
  ```dart
    static const String repo = 'genshin-impact-wish-gacha-analyzer';
  ```
  改為
  ```dart
    static const String repo = 'wuthering-waves-convene-gacha-analyzer';
  ```
  （`owner = 'GoneTone'` 保留；`githubUrl`/`apiBase` 自動跟著變。）
- [ ] 改 `lib/data/contributors.dart` 行 41-46 兩個 URL，把
  ```dart
  const githubContributorsUrl =
      'https://github.com/GoneTone/genshin-impact-wish-gacha-analyzer/graphs/contributors';

  /// Crowdin 翻譯專案 URL。
  const translationCrowdinUrl =
      'https://crowdin.com/project/genshin-impact-wish-gacha-analyzer';
  ```
  改為
  ```dart
  const githubContributorsUrl =
      'https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer/graphs/contributors';

  /// Crowdin 翻譯專案 URL。
  const translationCrowdinUrl =
      'https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer';
  ```
- [ ] 改 `lib/data/contributors.dart` 行 49-50 `licenseUrl`，把
  ```dart
  const licenseUrl =
      'https://github.com/GoneTone/genshin-impact-wish-gacha-analyzer/blob/master/LICENSE';
  ```
  改為
  ```dart
  const licenseUrl =
      'https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer/blob/master/LICENSE';
  ```
  （testers 行 26 的 `hoyolab.com/genshin/accountCenter` 是貢獻者 Zhi 的**個人遊戲頁面連結**，非本軟體品牌——保留，避免改壞貢獻者個資。）
- [ ] 改 `.github/release-footer.md` 行 6，把
  ```markdown
  <https://crowdin.com/project/genshin-impact-wish-gacha-analyzer>
  ```
  改為
  ```markdown
  <https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer>
  ```
- [ ] **README ×3 完全由本 plan（plan01）負責**：直接以最終鳴潮版內容**整檔覆寫** `README.md`、`README_EN.md`、`README_ZH-HANS.md`——**不**做「只換 slug + 留原神敘述 + 加 plan-10 TODO」的過渡做法（plan09/plan10 不存在，不得引用）。最終內容須反映鳴潮事實：**8 卡池**（角色／武器／常駐角色／常駐武器／新手／新手自選／啟航角色／啟航武器）、**無頌願**、圖片來源為 **guide-server**（角色有圖、武器與道具無圖）、稀有度為 **3★ / 4★ / 5★（無 2★）**。以下為三檔的最終內容，逐檔 `Write` 覆寫（保留現有截圖區塊與開發章節結構；只把品牌、slug、卡池說明、稀有度、圖片來源敘述換成鳴潮版）。
- [ ] 用最終內容覆寫 `README.md`（繁中）：
  ````markdown
  # 鳴潮喚取卡池分析 Wuthering Waves Convene Gacha Analyzer

  繁體中文 | [简体中文](README_ZH-HANS.md) | [English](README_EN.md)

  [![Crowdin](https://badges.crowdin.net/wuthering-waves-convene-gacha-analyzer/localized.svg)](https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer)

  我開發了一套用來分析喚取卡池歷史記錄的軟體，一開啟各種數據清清楚楚，不用再手動計算啦！

  本軟體原理是按下「更新資料」後會在本機啟動一個只跑在您電腦上的代理伺服器，並自動安裝一張本機產生的根憑證，藉此攔截鳴潮喚取記錄頁面對官方喚取歷史 API 的請求，所以要在按下更新後再到遊戲內開啟喚取記錄才能攔到，取得網址後拆解參數，參數會用於官方喚取相關的 API。

  第一次按下「更新資料」會加載您完整的喚取歷史，這可能需要一些時間，完成後會將資料存放在您的電腦內，這樣下次開啟軟體就不用再花時間等待資料加載。之後想取得新資料按一下「更新資料」即可，軟體會記住先前攔到的網址，能用就直接用、不用每次重新攔截；如果網址過期，軟體會請您再到遊戲開一次喚取記錄頁面以重新取得網址。

  請放心：本軟體不會讀取或竄改任何遊戲檔案、記憶體與遊戲傳輸的資料，只會在喚取記錄頁面開啟時攔下那一條請求網址，所以不會有被封鎖帳號的風險。如果有被封號，請思考您是不是其他原因被封鎖，不要怪罪我們。

  ## 多國語言

  請協助我們將軟體翻譯成各國語言！

  <https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer>

  ## 下載軟體

  軟體在安裝或執行時有可能會被防毒軟體阻擋。原因是本軟體會自行產生並安裝一張本機根憑證、並在按下更新時短暫設定系統代理以攔截鳴潮喚取記錄頁面的請求──這類行為與惡意程式相似，但本軟體只攔截官方喚取歷史 API，且憑證只留在您的電腦。如果無法正常執行，請嘗試關閉防毒軟體後再執行看看，本軟體保證無毒。

  <https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer/releases>

  ## 使用方式

  1. 啟動鳴潮，先別開啟喚取記錄頁面。
  2. 開啟本軟體並按下「更新資料」，軟體會在背景啟動本機代理伺服器並等候攔截。
  3. 切回遊戲，到「喚取 → 喚取記錄」開啟喚取記錄頁面。
  4. 軟體攔到網址後會自動關閉代理、還原系統代理設定並開始抓取資料；之後想再更新只要重複步驟 2，網址未過期就會直接套用。

  ## 功能與特色

  - 自動攔截鳴潮喚取記錄頁面對官方喚取歷史 API 的請求（透過本機代理伺服器與自簽根憑證），不需手動貼網址
  - 支援國際服 (暫不支援中國服)
  - 涵蓋 8 種卡池：角色活動喚取、武器活動喚取、常駐角色喚取、常駐武器喚取、新手喚取、新手自選喚取、啟航角色喚取、啟航武器喚取
  - 多帳號 (UID) 管理：自訂別名、拖曳排序、一鍵切換
  - 自動合併新舊資料，不覆蓋過去記錄，不會因為官方歷史記錄過時而消失
  - 總抽數及 5★ / 4★ / 3★ 件數與占比統計
  - 5★ 與 4★ 雙保底進度條，並顯示距離保底剩餘抽數
  - 5★ / 4★ 平均出貨抽數統計（各卡池與整體）
  - 各卡池 5★ 時間軸
  - 5★ 總覽：橫向陳列抽到過的所有不重複 5★，每個附累計次數徽章、可點開詳情；各卡池頁、綜合數據頁與分享圖皆會顯示
  - 各卡池最高稀有度件數比較長條圖
  - 稀有度分布圓餅圖
  - 類型分布圓餅圖
  - 歷史記錄表格：多欄排序、模糊搜尋、稀有度與物品類型篩選、分頁
  - 自動補上角色圖示與資料（來源：官方 guide-server）：角色有圖、武器與道具無圖；表格與時間軸會附角色圖示，點擊物品可查看詳情
  - 一鍵生成分享圖（可選深色 / 淺色主題、UID 全顯或只留前三碼遮罩），自動存檔並複製到剪貼簿
  - 帳號資料匯出 / 匯入 JSON
  - 深色 / 淺色主題切換
  - 多國語言（[協助翻譯](https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer)）
  - 可在設定開啟介面 UID 遮罩（只顯示前三碼），保護隱私
  - 啟動時自動檢查新版本，也可在設定頁手動觸發
  - 所有資料留在本機，不上傳

  ## 截圖

  ![綜合數據頁](docs/images/zh-Hant/1.png)
  ![角色活動喚取頁](docs/images/zh-Hant/2.png)
  ![武器活動喚取頁](docs/images/zh-Hant/3.png)
  ![常駐喚取頁](docs/images/zh-Hant/4.png)
  ![設定頁](docs/images/zh-Hant/5.png)
  ![分享圖生成設定](docs/images/zh-Hant/6.png)
  ![分享圖](docs/images/zh-Hant/7.png)
  ![物品詳情顯示](docs/images/zh-Hant/8.png)

  ## 開發

  ### 前置需求

  - 目前僅支援 Windows
  - [Flutter SDK](https://docs.flutter.dev/install)（最新穩定版）
  - [Rust toolchain](https://rustup.rs/)（stable）
  - 執行 `flutter doctor`，依提示補齊缺少的工具

  ### 取得原始碼並安裝依賴

  ```bash
  git clone https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer.git
  cd wuthering-waves-convene-gacha-analyzer
  flutter pub get
  ```

  Rust 會在 `flutter run` / `flutter build` 時由 `rust_builder/` 的 cargokit 自動編譯，不需手動 `cargo build`（但需先安裝 Rust toolchain）。

  ### 開發模式執行

  ```bash
  flutter run -d windows
  ```

  ### Rust ↔ Dart 橋接程式碼產生

  修改 `rust/src/api/` 內的 Rust 函式後，重新產生橋接程式碼。第一次使用前先安裝 codegen 工具：

  ```bash
  cargo install flutter_rust_bridge_codegen --version 2.12.0
  ```

  之後每次修改 API 都執行：

  ```bash
  flutter_rust_bridge_codegen generate
  ```

  產生的檔案位於 `lib/src/rust/`。

  ### 編譯生產版

  ```bash
  flutter build windows --release
  ```

  輸出：`build\windows\x64\runner\Release\`

  ### 執行測試

  ```bash
  flutter test
  cargo test --manifest-path rust/Cargo.toml
  ```
  ````
  （截圖檔名沿用既有路徑；如截圖內容尚未替換成鳴潮版，圖片更新屬另議資產，不影響本 plan 的文字交付。「文章」連結段已移除原神專屬貼文連結，避免品牌殘留。）
- [ ] 用最終內容覆寫 `README_EN.md`（English，與繁中版對應；8 卡池、無頌願、圖片來源 guide-server 角色有圖／武器道具無圖、稀有度 3★/4★/5★ 無 2★）：
  ````markdown
  # 鳴潮喚取卡池分析 Wuthering Waves Convene Gacha Analyzer

  [繁體中文](README.md) | [简体中文](README_ZH-HANS.md) | English

  [![Crowdin](https://badges.crowdin.net/wuthering-waves-convene-gacha-analyzer/localized.svg)](https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer)

  I have developed a utility for analyzing convene history, where all data and numbers are well-organized in a convenient manner.

  When you press *Update*, the utility starts a local proxy server (running only on your computer) and automatically installs a locally generated root certificate, so it can intercept Wuthering Waves' convene-record page request to the official convene history API. You therefore need to open the convene record page in the game *after* pressing *Update*, so the request can be captured. The captured URL is parsed and the resulting parameters are used to call the official API.

  The first time you press *Update*, the utility loads your full convene history, which may take a while. The data is then stored locally so you don't have to wait again on the next launch. To pull new records, just press *Update*: the utility remembers the previously captured URL and reuses it as long as it's still valid, so you don't have to repeat the capture every time. If the captured URL has expired, the utility will ask you to open the convene record page in the game again to re-capture.

  Rest assured: this utility does not read or modify any game file, game memory, or in-game network traffic. It only intercepts the convene record page request, so there is no risk of being banned for using it. If you have been banned, it was likely for a different reason. Please do not blame us, thanks.

  ## Multiple Language

  Please help us translate this software.

  <https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer>

  ## Download Software

  The utility may trigger anti-virus software during installation and execution. This is because it generates and installs a local root certificate, and briefly configures a system proxy when you press *Update* to intercept the convene-record page request — behavior that resembles malware. However, the utility only intercepts the official convene history API, and the certificate stays on your computer. If the utility doesn't function correctly, please try disabling any anti-virus software you have installed. We guarantee this utility is safe and virus-free.

  <https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer/releases>

  ## How to Use

  1. Launch Wuthering Waves (don't open the convene record page yet).
  2. Open this utility and press *Update*. The utility will start a local proxy server in the background and wait for the request.
  3. Switch back to the game and open *Convene → Convene History* to view the convene record page.
  4. Once captured, the utility automatically shuts down the proxy, restores your system proxy settings, and starts fetching your data. To update again later, just repeat step 2 — the captured URL will be reused if still valid.

  ## Features

  - Auto-intercepts the convene-record page request to the official convene history API via a local proxy and a self-signed root certificate — no need to paste URLs by hand
  - Supports the Global server (CN server not supported yet)
  - Covers all 8 convene types: Character Event Convene, Weapon Event Convene, Standard Character Convene, Standard Weapon Convene, Beginner Convene, Beginner's Choice Convene, New Voyage Character Convene, New Voyage Weapon Convene
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
  - Convene history table: multi-column sort, fuzzy search, rarity and item-type filters, pagination
  - Auto-fetched character icons and details (from the official guide-server): characters have artwork, weapons and items do not; the table and timelines show character icons, and clicking an item opens its details
  - Generate a share image in one click (dark / light theme, full UID or first-3-digits mask), auto-saved and copied to the clipboard
  - Export / Import accounts as JSON
  - Dark / Light theme toggle
  - Multi-language ([help us translate](https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer))
  - Optional UID masking in the UI (first 3 digits only) for added privacy
  - Automatic update check on launch, with a manual trigger in Settings
  - All data stays on your machine — nothing is uploaded

  ## Screenshot

  ![Overview page](docs/images/en/1.png)
  ![Character Event Convene page](docs/images/en/2.png)
  ![Weapon Event Convene page](docs/images/en/3.png)
  ![Standard Convene page](docs/images/en/4.png)
  ![Settings page](docs/images/en/5.png)
  ![Share image options](docs/images/en/6.png)
  ![Share image](docs/images/en/7.png)
  ![Item details](docs/images/en/8.png)

  ## Development

  ### Prerequisites

  - Windows only for now
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
  flutter run -d windows
  ```

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

  ```bash
  flutter build windows --release
  ```

  Output: `build\windows\x64\runner\Release\`

  ### Run tests

  ```bash
  flutter test
  cargo test --manifest-path rust/Cargo.toml
  ```
  ````
- [ ] 用最終內容覆寫 `README_ZH-HANS.md`（简中，與繁中版對應）：
  ````markdown
  # 鸣潮唤取卡池分析 Wuthering Waves Convene Gacha Analyzer

  [繁體中文](README.md) | 简体中文 | [English](README_EN.md)

  [![Crowdin](https://badges.crowdin.net/wuthering-waves-convene-gacha-analyzer/localized.svg)](https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer)

  我开发了一套用来分析唤取卡池历史记录的软件，一打开各种数据清清楚楚，不用再手动计算啦！

  本软件的原理是：按下「更新数据」后会在本机启动一个只跑在您电脑上的代理服务器，并自动安装一张本机生成的根证书，借此拦截鸣潮唤取记录页面对官方唤取历史 API 的请求，所以要在按下更新后再到游戏内打开唤取记录才能拦到，拿到网址后解析参数，参数会用于官方唤取相关的 API。

  第一次按下「更新数据」会加载您完整的唤取历史，这可能需要一些时间，完成后会将数据保存在您的电脑上，这样下次打开软件就不用再花时间等待数据加载。之后想获取新数据按一下「更新数据」即可，软件会记住先前拦到的网址，能用就直接用、不用每次重新拦截；如果网址过期，软件会请您再到游戏打开一次唤取记录页面以重新获取网址。

  请放心：本软件不会读取或篡改任何游戏文件、内存与游戏传输的数据，只会在唤取记录页面打开时拦下那一条请求网址，所以不会有账号被封禁的风险。如果您被封号，请思考是否因为其他原因被封禁，不要怪我们。

  ## 多国语言

  请帮我们将软件翻译成各国语言！

  <https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer>

  ## 下载软件

  软件在安装或运行时有可能会被杀毒软件拦截。原因是本软件会自行生成并安装一张本机根证书，并在按下更新时短暂设置系统代理以拦截鸣潮唤取记录页面的请求——这类行为与恶意程序相似，但本软件只拦截官方唤取历史 API，且证书只留在您的电脑上。如果无法正常运行，请尝试关闭杀毒软件后再运行试试，本软件保证无毒。

  <https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer/releases>

  ## 使用方法

  1. 启动鸣潮，先别打开唤取记录页面。
  2. 打开本软件并按下「更新数据」，软件会在后台启动本机代理服务器并等候拦截。
  3. 切回游戏，到「唤取 → 唤取记录」打开唤取记录页面。
  4. 软件拦到网址后会自动关闭代理、还原系统代理设置并开始抓取数据；之后想再更新只要重复步骤 2，网址未过期就会直接使用。

  ## 功能与特色

  - 自动拦截鸣潮唤取记录页面对官方唤取历史 API 的请求（通过本机代理服务器与自签根证书），无需手动粘贴网址
  - 支持国际服（暂不支持国服）
  - 涵盖 8 种卡池：角色活动唤取、武器活动唤取、常驻角色唤取、常驻武器唤取、新手唤取、新手自选唤取、启航角色唤取、启航武器唤取
  - 多账号 (UID) 管理：自定义别名、拖动排序、一键切换
  - 自动合并新旧数据，不覆盖过往记录，不会因为官方历史记录过期而丢失
  - 总抽数及 5★ / 4★ / 3★ 数量与占比统计
  - 5★ 与 4★ 双保底进度条，并显示距离保底的剩余抽数
  - 5★ / 4★ 平均出货抽数统计（各卡池与整体）
  - 各卡池 5★ 时间轴
  - 5★ 总览：横向陈列抽到过的所有不重复 5★，每个附累计次数徽章、可点开详情；各卡池页、综合数据页与分享图都会显示
  - 各卡池最高稀有度数量对比柱状图
  - 稀有度分布饼图
  - 类型分布饼图
  - 历史记录表格：多列排序、模糊搜索、稀有度与物品类型筛选、分页
  - 自动补上角色图标与资料（来源：官方 guide-server）：角色有图、武器与道具无图；表格与时间轴会附角色图标，点击物品可查看详情
  - 一键生成分享图（可选深色 / 浅色主题、UID 全显或只留前三码遮罩），自动存档并复制到剪贴板
  - 账号数据导出 / 导入 JSON
  - 深色 / 浅色主题切换
  - 多国语言（[协助翻译](https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer)）
  - 可在设置开启界面 UID 遮罩（只显示前三码），保护隐私
  - 启动时自动检查新版本，也可在设置页手动触发
  - 所有数据留在本机，不上传

  ## 截图

  ![综合数据页](docs/images/zh-Hans/1.png)
  ![角色活动唤取页](docs/images/zh-Hans/2.png)
  ![武器活动唤取页](docs/images/zh-Hans/3.png)
  ![常驻唤取页](docs/images/zh-Hans/4.png)
  ![设置页](docs/images/zh-Hans/5.png)
  ![分享图生成设置](docs/images/zh-Hans/6.png)
  ![分享图](docs/images/zh-Hans/7.png)
  ![物品详情显示](docs/images/zh-Hans/8.png)

  ## 开发

  ### 前置需求

  - 目前仅支持 Windows
  - [Flutter SDK](https://docs.flutter.dev/install)（最新稳定版）
  - [Rust toolchain](https://rustup.rs/)（stable）
  - 运行 `flutter doctor`，根据提示补齐缺少的工具

  ### 获取源代码并安装依赖

  ```bash
  git clone https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer.git
  cd wuthering-waves-convene-gacha-analyzer
  flutter pub get
  ```

  Rust 会在 `flutter run` / `flutter build` 时由 `rust_builder/` 的 cargokit 自动编译，无需手动 `cargo build`（但需先安装 Rust toolchain）。

  ### 开发模式运行

  ```bash
  flutter run -d windows
  ```

  ### Rust ↔ Dart 桥接代码生成

  修改 `rust/src/api/` 内的 Rust 函数后，重新生成桥接代码。第一次使用前先安装 codegen 工具：

  ```bash
  cargo install flutter_rust_bridge_codegen --version 2.12.0
  ```

  之后每次修改 API 都运行：

  ```bash
  flutter_rust_bridge_codegen generate
  ```

  生成的文件位于 `lib/src/rust/`。

  ### 编译生产版

  ```bash
  flutter build windows --release
  ```

  输出：`build\windows\x64\runner\Release\`

  ### 运行测试

  ```bash
  flutter test
  cargo test --manifest-path rust/Cargo.toml
  ```
  ````
- [ ] 確認三份 README 再無舊 slug / 原神品牌標題：`Select-String -Path README.md,README_EN.md,README_ZH-HANS.md -Pattern "genshin-impact-wish-gacha-analyzer|Genshin Impact Wish|原神祈願|原神祈愿|頌願|颂愿|TODO\(plan-10\)"`（預期：無輸出）。
- [ ] 確認 Dart 識別碼層再無舊 slug：`Select-String -Path lib\data\app_repo.dart,lib\data\contributors.dart,.github\release-footer.md -SimpleMatch "genshin-impact-wish-gacha-analyzer"`（預期：無輸出）。
- [ ] 跑 analyze 確認 Dart 改動無誤：`flutter analyze`（比對：錯誤數 ≤ Task 0 的 `N0`）。
- [ ] `dart format lib/ test/`（預期：完成、無錯）。
- [ ] commit（無 git 則略）：
  ```
  docs(brand): repoint GitHub/Crowdin coordinates and rewrite READMEs to Wuthering Waves

  Update AppRepo.repo, contributors URLs and the release-footer Crowdin link to
  the wuthering-waves-convene-gacha-analyzer repo, and fully rewrite the three
  READMEs to the final Wuthering Waves content: 8 convene types, no Odes, image
  source is the official guide-server (characters have artwork, weapons/items do
  not), rarities 3★/4★/5★ with no 2★. This plan fully owns the READMEs; no
  deferral and no plan-10 placeholders.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

---

## Task 9：去原神化最終掃描（identifier/brand 殘留全庫稽核）

**Files:**
- Read-only 稽核 + 補漏：全庫掃 `genshin` / `Genshin` / `原神` / `genshin_capture_core` / `genshin_impact_wish_gacha_analyzer` 殘留，分類「本 plan 應處理（識別名/品牌）」vs「其他 plan 處理（業務字串如 `hoyowiki_*`、`*.hoyoverse.com`、`getGachaLog`）」。

> **掃描排除：** `rust_builder/`（vendored）、`build/`（產物）、`docs/`（設計文件本就保留原神對照）、`.dart_tool/`、`analyze_baseline.txt`。

**步驟：**

- [ ] 掃 import 前綴是否歸零（本 plan Task 1 範圍）：`(Get-ChildItem -Recurse -Include *.dart lib,test | Select-String -SimpleMatch "package:genshin_impact_wish_gacha_analyzer/" | Measure-Object).Count`（預期：0）。
- [ ] 掃 Rust crate 名是否歸零（Task 2/3 範圍，排除 Cargo.lock 的衍生 hash 行）：`Select-String -Path rust\Cargo.toml,windows\CMakeLists.txt,lib\src\rust\frb_generated.dart,AGENTS.md -SimpleMatch "genshin_capture_core"`（預期：無輸出）。
- [ ] 掃 bare package 名殘留於 config/原生（Task 1/5/7 範圍）：`Select-String -Path pubspec.yaml,windows\CMakeLists.txt,windows\runner\Runner.rc,scripts\build_installer\installer.iss -SimpleMatch "genshin_impact_wish_gacha_analyzer"`（預期：無輸出）。
- [ ] 掃 CA 識別字串（Task 4 範圍）：`Select-String -Path rust\src\ca.rs -Pattern "Genshin Impact"`（預期：無輸出）。
- [ ] 掃原生 splash 品牌標題殘留（Task 5 範圍；appName ARB 屬 plan07，本 plan 不掃 ARB 值）：`Select-String -Path windows\runner\main.cpp -Pattern "原神祈願|原神祈愿|Genshin Impact Wish"`（預期：無輸出）。
- [ ] **分流剩餘殘留**——全庫掃 `genshin`（不分大小寫），把命中分兩類：
  ```powershell
  Get-ChildItem -Recurse -File -Path lib,rust,windows,scripts,.github,test `
    -Include *.dart,*.rs,*.toml,*.cpp,*.rc,*.txt,*.iss,*.ps1,*.md,*.yml,*.arb |
    Where-Object { $_.FullName -notmatch 'rust_builder|\\build\\|\.dart_tool' } |
    Select-String -Pattern 'genshin' -CaseSensitive:$false |
    Select-Object Path, LineNumber, Line
  ```
  對每筆命中判定：
  - **屬本 plan（識別名/品牌）** → 回到對應 Task 補修。
  - **屬其他 plan（業務邏輯字串）**：如 `hoyowiki_*`（→ plan06 圖片）、`*.hoyoverse.com` / `getGachaLog` / `getBeyondGachaLog`（→ plan02 Rust 攔截 + plan04 抓取）、`HoYoWikiIndex`（→ plan06 圖片）、`actionViewOnHoYoWiki` 引用與其餘 HoYoWiki UI 字串（→ plan07 UI/i18n）。**這些不在本 plan 改**，僅列出確認屬其他 plan 範圍、不誤改。
  - **README 敘述段**：本 plan Task 8 已整檔覆寫為最終鳴潮版，README 不應再有任何 `genshin` 命中（若有，回 Task 8 補修，**不**留待後續 plan）。
- [ ] 把上一步分流結果記在 commit body（或 PR 描述），明列「本 plan 已清除的識別名/品牌」與「刻意留給其他 plan 的業務字串清單」，供後續 plan 對照。
- [ ] 跑最終 analyze：`flutter analyze`（比對：錯誤數 ≤ Task 0 的 `N0`，且輸出**無任何** `genshin_impact_wish_gacha_analyzer` 相關的 URI/identifier 錯誤）。
- [ ] 清理基準暫存檔（不入庫）：`Remove-Item analyze_baseline.txt -ErrorAction SilentlyContinue`。
- [ ] commit（無 git 則略）：
  ```
  chore(rename): audit residual Genshin identifiers after rename migration

  Final sweep confirming all package/crate/CA/brand identifiers and the three
  READMEs are renamed/rewritten to the Wuthering Waves namespace. Business-logic
  strings (hoyowiki_*, *.hoyoverse.com, getGachaLog, HoYoWiki UI references) are
  intentionally left for the Rust(plan02)/fetch(plan04)/image(plan06)/UI(plan07)
  plans and are listed below for cross-plan tracking.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

---

## 驗收總結（本 plan 完成定義）

本 plan 純命名／品牌，**不負責讓整體 compile 全綠**（那由各業務 plan 與 plan07 的最後一個 Task 收尾）。本 plan 的完成定義：

1. **import 前綴**：`package:genshin_impact_wish_gacha_analyzer/` 全庫 0 殘留，`flutter pub get` 認得新 package name。
2. **Rust crate lockstep**：`flutter build windows --release` 成功，產出 `gacha_capture_core.dll` 與 `wuthering_waves_convene_gacha_analyzer.exe`，舊名 DLL/exe 不再產出。
3. **CA 去原神化**：`cargo test --manifest-path rust/Cargo.toml` 全綠，新 CN 為 `Wuthering Waves Convene Gacha Analyzer Root CA`。
4. **ARB（不在本 plan 範圍）**：所有 ARB key（含 appName 四語品牌）由 plan07 改值並跑 `flutter gen-l10n`；本 plan 不碰 ARB。
5. **installer 並存**：釘死 AppId `{27F3CD23-7E15-4570-8EBB-79D2801C9C85}` + 全新路徑，與原神版可同機並存不覆蓋。
6. **README ×3**：三份 README 已整檔覆寫為最終鳴潮版（8 卡池、無頌願、guide-server 圖片來源、3/4/5★），由本 plan 完全擁有、無 plan-10 占位。
7. **無新增錯誤**：`flutter analyze` 錯誤數 ≤ Task 0 基準 `N0`，且無任何因改名造成的 URI/identifier 錯誤。
8. **稽核**：Task 9 確認識別名/品牌 0 殘留，業務字串明列移交其他 plan。

**驗收指令（固定）：**
- `dart format lib/ test/`
- `flutter analyze`（本 plan 期望：錯誤數 ≤ 基準、無改名相關錯誤；**全綠 `No issues found!` 待 plan07 的最後一個 Task**）
- `flutter test`（本 plan 不要求 `All tests passed!`，因其他 plan 型別未完成；確認**本 plan 未新增測試失敗**）
- `cargo test --manifest-path rust/Cargo.toml`（期望：`test result: ok`）
- `flutter build windows --release`（期望：build 成功、產出新名 DLL/exe）