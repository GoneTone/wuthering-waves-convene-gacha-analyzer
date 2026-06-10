# 匯入時辨識備份來源（鳴潮）設計

## 背景與目標

鳴潮版與姐妹專案（原神 `genshin-impact-wish-gacha-analyzer`）共用同一套匯出／匯入架構（`AccountsBundle` → pretty JSON）。兩邊的備份檔結構幾乎相同，使用者很容易把原神的備份誤匯入鳴潮（反之亦然）——目前鳴潮的 `importAccounts` 完全不辨識來源，外來檔會被當成格式問題或部分解析，體驗不佳。

目標：**匯入時辨識備份是否由本軟體（鳴潮）匯出**，非本軟體的檔給出明確的在地化提示，而非含糊的「格式錯誤」。

原神專案已完整實作此機制，本設計忠實移植，並補上鳴潮專屬的卡池代碼集合與 schema 對齊。

## 關鍵前提

- **鳴潮現行版本已用 `schema_version: 2` 出貨，且匯出檔不含 `app` 欄位。** 野外已存在「無 `app` 的合法鳴潮備份」，本次改動必須讓它們仍能匯入——這是需要 legacy screening 的原因。
- **兩遊戲卡池代碼天生不重疊**：原神為 `"100" / "200" / "301" / "302" / "500"`；鳴潮為 `"1"~"11"`（無 `"7"`，集合 `{1,2,3,4,5,6,8,9,10,11}`）。因此「靠 `banners` 的 key 辨識舊檔來源」對鳴潮 100% 可靠。

## 整體架構

沿用原神的兩層辨識策略，不改既有匯入流程的其他環節（accounts picker、confirm dialog、merge 邏輯一律不動）：

1. **新檔**：匯出時寫入頂層 `app` 識別碼，匯入時比對。
2. **舊檔（無 `app`）**：靠 `banners` 的 key 與鳴潮已知卡池代碼集合比對辨識。

## 詳細設計

### 1. 匯出端

**`lib/models/accounts_bundle.dart`**

- 新增 top-level 常數：
  ```dart
  /// 本軟體的匯出識別字串，寫入備份檔的 `app` 欄位供匯入端辨識來源。
  ///
  /// 值對齊 pubspec 套件名；姐妹專案（原神）為 `genshin_impact_wish_gacha_analyzer`，天生相異。
  const String accountsBundleAppId = 'wuthering_waves_convene_gacha_analyzer';
  ```
- `AccountsBundle.toJson()` 在 `schema_version` 之後多寫一欄 `'app': accountsBundleAppId`。

**`lib/services/accounts_export.dart`**：不需改動（透過 `toJson` 自動帶上 `app`）。

### 2. 匯入端

**`lib/models/accounts_bundle.dart`**

- `AccountsBundle.fromJson()` 的 schema 檢查由 `version != currentSchemaVersion` 改為 `version > currentSchemaVersion`（對齊原神，只拒「比目前新」的版本，接受等於或較舊者）。其餘 fromJson 邏輯不動。

**`lib/services/accounts_import.dart`**

- 新增例外型別：
  ```dart
  /// 匯入檔不是由本軟體匯出（`app` 識別碼不符，或舊檔卡池代碼非鳴潮已知集合）時拋出。
  class ForeignBundleException implements Exception { const ForeignBundleException(); }
  ```
- `importAccounts(String text)`：解析出 top-level `Map<String, dynamic>` 後，
  - 取 `raw['app']`：
    - 是字串且 `!= accountsBundleAppId` → `Logger('accounts.io').warning('import failed: foreign bundle (app=$app)')`、丟 `ForeignBundleException`。
    - 是字串且相等 → 完全信任，原樣交給 `AccountsBundle.fromJson`。
    - 非字串（無 `app`）→ 進 `_screenLegacyBundle(raw)`，以回傳值交給 `fromJson`。
  - 既有的 `UnsupportedSchemaVersionException` / `FormatException` rethrow 區塊維持不變。
- 新增 private helper：
  ```dart
  /// 處理無 `app` 欄位的舊備份：依卡池代碼判別是否為本軟體（鳴潮）檔，並濾掉非鳴潮 banner。
  Map<String, dynamic> _screenLegacyBundle(Map<String, dynamic> raw)
  ```
  行為（移植原神 `_screenLegacyBundle`，已知集合改取自鳴潮 `gachaTypes`）：
  - 已知集合 `known = {for (final t in gachaTypes) t.key}`（不硬寫代碼字串）。
  - 走訪 `raw['accounts']`（非 List 直接原樣回傳，交由 `fromJson` 拋帶位置的結構錯誤）。
  - 逐 account 走訪 `entry['banners']`：
    - `banners` 非 `Map<String, dynamic>` → 該 entry 原樣保留。
    - 否則蒐集 key：在 `known` 內的 banner 保留，不在的跳過。`sawAnyCode` / `keptAnyKnown` 兩個旗標記錄全局狀態。
    - 過濾後 `banners` 非空才把（覆蓋過 `banners` 的）entry 放回。
  - 收尾：`sawAnyCode && !keptAnyKnown`（確有卡池資料但全非鳴潮代碼）→ `Logger('accounts.io').warning('import failed: foreign bundle (no WuWa pools)')`、丟 `ForeignBundleException`。
  - 否則回傳 `{...raw, 'accounts': filteredAccounts}`（讀不出任何代碼的空檔／模糊結構即原樣交回）。

> 注意：鳴潮 `BannerStorage` 用 `playerId`（非原神的 `uid`），但 `banners` 的 key 一樣是卡池代碼，screening 邏輯不受影響。

### 3. UI 與 l10n

**`lib/pages/settings_page.dart`**

- `_import()` 在現有 `on UnsupportedSchemaVersionException` 之前加一段：
  ```dart
  } on ForeignBundleException {
    if (!ctx.mounted) return;
    _showSnack(ctx, l.settingsImportFailed(l.importReasonForeignApp));
    return;
  }
  ```

**核心四 ARB**（`app_zh.arb` / `app_en.arb` / `app_ja.arb` / `app_zh_Hans.arb`）

- 新增 `importReasonForeignApp` 字串（含 `@importReasonForeignApp` metadata）。語意沿用原神：
  - zh-Hant：「此檔案不是由本軟體匯出的備份」
  - en：「This file was not exported by the app」
  - ja：「このファイルは本ツールでエクスポートされたバックアップではありません」
  - zh-Hans：「此文件不是由本软件导出的备份」
- 其餘 ~30 Crowdin locale 走既有翻譯流程（generated 為 gitignore，不在本次改動內）。
- 改完 ARB 後跑 `fvm flutter gen-l10n`。

## 測試

針對 `importAccounts` 補單元測試（`test/services/accounts_import_test.dart` 或既有對應檔）：

| 案例 | 預期 |
|---|---|
| 自家新檔（`app` = 鳴潮 ID） | 正常匯入 |
| 外來新檔（`app` = 原神 ID） | 丟 `ForeignBundleException` |
| 舊檔無 `app`、鳴潮代碼 | 正常匯入 |
| 舊檔無 `app`、純原神代碼（如 `"301"`） | 丟 `ForeignBundleException` |
| 舊檔無 `app`、鳴潮＋未知代碼混合 | 過濾後僅保留鳴潮 banner，濾空帳號移除 |
| 舊檔無 `app`、讀不出任何代碼（空 accounts） | 原樣交給 fromJson，不丟 ForeignBundleException |
| schema `>` 邊界 | 等於／較舊接受；較新丟 `UnsupportedSchemaVersionException` |

## 埋 log

`_screenLegacyBundle` 與 `app` 不符分支沿用 `Logger('accounts.io').warning(...)`，帶上 `app=` 值或「no WuWa pools」原因，便於使用者匯出 log 後定位「為什麼這個檔被拒」。無敏感資料（不含 URL／UID）。

## YAGNI

不新增抽象層、不預留多遊戲擴充參數。實質改動＝兩個檔案的辨識邏輯（`accounts_bundle.dart`、`accounts_import.dart`）＋ 一條 UI catch ＋ 一條在地化字串。

## 影響檔案

- `lib/models/accounts_bundle.dart`（新增常數＋`app` 欄位＋schema `>`）
- `lib/services/accounts_export.dart`（無改動，列此供對照）
- `lib/services/accounts_import.dart`（新增例外＋app 檢查＋`_screenLegacyBundle`）
- `lib/pages/settings_page.dart`（新增 `on ForeignBundleException` catch）
- `lib/l10n/app_zh.arb` / `app_en.arb` / `app_ja.arb` / `app_zh_Hans.arb`（新增 `importReasonForeignApp`）
- 對應單元測試檔
