# 失敗訊息在地化設計

## 背景與目標

姐妹專案（原神）的 PR #110「localize import/export failure reasons」修正了「匯入資料失敗時跳出英文訊息」的問題。本專案（鳴潮）稽核後確認**完全沒有套用同樣的修正**，且還多一條原神沒有的鳴潮專屬路徑。

追根究柢：外層的「匯入失敗：{reason}」（`settingsImportFailed`）／「匯出失敗：{error}」（`settingsExportFailed`）本身有在地化，但帶入的 `{reason}`／`{error}` 是底層硬編英文 `FormatException` 的 `.message`、或平台 IO 例外的 `.toString()`，所以前綴是使用者語言、原因卻是英文。喚取／擷取失敗路徑同理：英文例外經 `UpdateErrorOther` 直送 `UpdateProgressDialog` 顯示。

### 涉及的英文來源

**Path A — 匯入／匯出（與原神 PR #110 同款 bug）**

- `lib/services/accounts_import.dart`：`'Invalid JSON'`、`'Top-level value must be an object'`、`'Failed to parse: $e'`
- `lib/models/accounts_bundle.dart`：`'Missing or invalid "schema_version"'`、`schema_version != currentSchemaVersion` 的混語訊息、`'Missing or invalid "accounts" array'`、`'accounts[$i] must be an object'`、`'accounts[$i]: $e'`、`'Duplicate playerId in accounts: ...'`
- `lib/pages/settings_page.dart`：匯入讀檔失敗（line 517 `e.toString()`）、匯入解析失敗（line 526 `e.message`）、匯出寫檔失敗（line 485 `e.toString()`）直接把英文例外當原因顯示

**Path B — 喚取／擷取失敗（鳴潮專屬，原神無此 MITM 擷取路徑）**

- `lib/services/gacha_credential.dart`：`'captured body is not valid JSON'`、`'captured body is not a JSON object'`、`'captured body missing field "$key"'`（但這些在 `gacha_repository` line 242 被當「未命中」攔下重攔，不直送 UI）
- `lib/state/gacha_repository.dart` `_friendlyError`（line 1165-1176）：`http.ClientException` 的 `'$message ($uri)'`、泛用 `e.toString()` 經 `UpdateErrorOther` → `UpdateProgressDialog` `_resolveError`（line 272 直接顯示 message）

### 範圍與排除

- **納入**：Path A（匯入／匯出失敗原因）＋ Path B（喚取／擷取憑證／網路失敗）。
- **排除**：
  - `settings_page.dart:998` 的 `settingsLogsExportFailed(e.toString())`——日誌匯出偏技術面，沿用原神刻意保留 toString 的決定。
  - `settings_page.dart:307/310` 的 `'Developed by '` / `'GoneTone'`——非失敗訊息，屬「D10 外部身分待後續」範圍。

### 成功條件

- 匯入／匯出／喚取失敗時，SnackBar／結果 dialog／`UpdateProgressDialog` 顯示的原因為使用者語言，無殘留英文。
- 可區隔的特例（版本不相容）給出明確訊息，與一般「格式不正確」失敗區隔。
- 英文技術細節不丟失：保留在 log（既有 `_log.warning`／`_log.severe`，並補上目前缺漏的匯入讀檔失敗那條 log）。
- `fvm flutter analyze` 全綠、`fvm flutter test` 全綠。

## 決策摘要

| 面向 | 決策 |
|------|------|
| 修正方式 | 型別化例外 ＋ 在 UI/dialog 邊界依「捕捉到的例外型別」挑在地化文案；底層英文 `FormatException` 保留，從此只供 log／測試，不再進 UI（比照原神 PR #110，與既有 `UpdateErrorGachaFailed → l.errorGachaFailed` pattern 一致） |
| 不採方案 | 全域 error-code enum（過重，YAGNI 否決）；在 throw 處在地化（service 要吃 `BuildContext`，破壞分層，否決） |
| Path A 版本不符措辭 | **版本中性**單一訊息「此備份的資料版本與目前 App 不相容，無法匯入」。本專案 `!=` 同時涵蓋較舊／較新兩向，不承諾「更新就能匯入」，語意最誠實 |
| Path A 特例辨識 | 只為「版本不相容」加一個專屬例外型別 `UnsupportedSchemaVersionException`，讓 UI 能與一般 malformed 區隔；不引入錯誤分類 enum |
| Path B 呈現策略 | `_friendlyError` 改 emit 型別化 `UpdateError`，於 dialog `_resolveError` 解析成 l10n；移除會帶英文的 `UpdateErrorOther` |
| wrapper 重用 | Path A 重用既有 `settingsImportFailed(reason)`／`settingsExportFailed(error)`，只替換帶入的原因字串 |
| 新增 ARB key | 4 個 import/export reason key ＋ 2 個 update error key（見下表） |
| 翻譯範圍 | 全部先寫來源 `app_zh.arb` ＋ `app_en.arb`；3 個與原神語意相同的 key（invalidFormat／unreadable／writeFailed）回填原神現有語系譯文；版本中性 key 與 2 個 update error key 為新措辭／新 key，核心 ARB 先行、其餘交 Crowdin pipeline |

## 設計

### 新增 ARB key

| key | zh-Hant（來源） | 來源／回填 |
|-----|----------------|-----------|
| `importReasonInvalidFormat` | 檔案格式不正確或已損毀 | 回填原神現有語系 |
| `importReasonIncompatibleVersion` | 此備份的資料版本與目前 App 不相容，無法匯入 | 版本中性新措辭，核心 ARB ＋ Crowdin |
| `importReasonUnreadable` | 無法讀取檔案 | 回填原神現有語系 |
| `exportReasonWriteFailed` | 無法寫入檔案，請確認儲存位置與權限 | 回填原神現有語系 |
| `errorNetwork` | 網路連線失敗，請檢查網路後重試 | 鳴潮新 key，核心 ARB ＋ Crowdin |
| `errorUnexpected` | 發生未預期的錯誤，請稍後再試 | 鳴潮新 key，核心 ARB ＋ Crowdin |

### Path A — 匯入／匯出

#### 1. `lib/models/accounts_bundle.dart`：新增可辨識的版本例外

新增 top-level 例外型別（附一行 `///` dartdoc）：

```dart
/// 匯入檔的 schema 版本與目前 App 支援版本不符時拋出，供 UI 給出「版本不相容」訊息。
class UnsupportedSchemaVersionException implements Exception {
  /// 建立 [UnsupportedSchemaVersionException]。
  const UnsupportedSchemaVersionException(this.version);

  /// 匯入檔宣告的 schema 版本（與 [AccountsBundle.currentSchemaVersion] 不符）。
  final int version;
}
```

把原本的版本不符分支（line 73-78）：

```dart
if (version != currentSchemaVersion) {
  throw FormatException(
    'schema_version=$version 與本版（$currentSchemaVersion）不相容：'
    '此備份來自不相容的舊版本，無法匯入。',
  );
}
```

換成：

```dart
if (version != currentSchemaVersion) {
  throw UnsupportedSchemaVersionException(version);
}
```

其餘 `FormatException`（schema_version 缺漏、accounts 非陣列、accounts[i] 非物件、Duplicate playerId 等）**全部不動**——歸到「格式不正確」這一桶，英文訊息續供 log／測試。

#### 2. `lib/services/accounts_import.dart`：讓版本例外原樣上拋

`importAccounts` 包住 `AccountsBundle.fromJson` 的 try/catch 要先攔 `UnsupportedSchemaVersionException` 原樣 rethrow（先 log），避免被泛用 catch 吞成 `FormatException`：

```dart
try {
  return AccountsBundle.fromJson(raw);
} on UnsupportedSchemaVersionException catch (e) {
  _log.warning('import failed: unsupported schema version ${e.version}');
  rethrow;
} on FormatException catch (e) {
  _log.warning('import failed: ${e.message}');
  rethrow;
} catch (e, st) {
  _log.warning('import failed: parse error', e, st);
  throw FormatException('Failed to parse: $e');
}
```

對外契約變為：可能拋 `UnsupportedSchemaVersionException`（版本不符）或 `FormatException`（其餘 malformed）。

#### 3. `lib/pages/settings_page.dart`：三個失敗點停止把英文丟進 UI

- **匯出寫檔失敗**（line 482-486）：`message: l.settingsExportFailed(l.exportReasonWriteFailed)`
- **匯入讀檔失敗**（line 515-518）：補上目前缺漏的 `Logger('accounts.io').warning(...)`，並改 `_showSnack(ctx, l.settingsImportFailed(l.importReasonUnreadable))`
- **匯入解析失敗**（line 522-528）：拆兩個 catch——

```dart
try {
  bundle = importAccounts(text);
} on UnsupportedSchemaVersionException {
  if (!ctx.mounted) return;
  _showSnack(ctx, l.settingsImportFailed(l.importReasonIncompatibleVersion));
  return;
} on FormatException {
  if (!ctx.mounted) return;
  _showSnack(ctx, l.settingsImportFailed(l.importReasonInvalidFormat));
  return;
}
```

### Path B — 喚取／擷取失敗

#### 4. `lib/state/update_error.dart`：型別化取代會帶英文的 fallback

移除 `UpdateErrorOther`（其 `message` 直接顯示英文），新增兩個無 payload 的型別（皆附 `///` dartdoc）：

```dart
/// 網路層失敗（連線中斷／逾時等）。技術細節（含脫敏 URL）只進 log。
class UpdateErrorNetwork extends UpdateError {
  /// 建立 [UpdateErrorNetwork]。
  const UpdateErrorNetwork();
}

/// 未預期的錯誤（解析失敗等非可行動原因的收斂桶）。技術細節只進 log。
class UpdateErrorUnexpected extends UpdateError {
  /// 建立 [UpdateErrorUnexpected]。
  const UpdateErrorUnexpected();
}
```

#### 5. `lib/state/gacha_repository.dart`：`_friendlyError` 改 emit 型別化錯誤

```dart
UpdateError _friendlyError(Object e) => switch (e) {
  _NoRecordsException() => const UpdateErrorNoRecords(),
  GachaApiException(:final code, :final message) =>
    UpdateErrorGachaFailed(code, message),
  http.ClientException() => const UpdateErrorNetwork(),
  _ => const UpdateErrorUnexpected(),
};
```

`FormatException` 併入泛用 `_`（→ `UpdateErrorUnexpected`）。英文細節已在呼叫處（line 307-308／314／328-330／336）有 `_log.warning`／`_log.severe`，保留不變。

#### 6. `lib/widgets/update_progress_dialog.dart`：`_resolveError` 解析新型別

移除 `UpdateErrorOther` 分支，加：

```dart
UpdateErrorNetwork() => l.errorNetwork,
UpdateErrorUnexpected() => l.errorUnexpected,
```

`UpdateErrorGachaFailed → l.errorGachaFailed`、`UpdateErrorNoRecords → l.errorNoRecords`、`UpdateErrorWipeItemImageCache → l.updateErrorWipeItemImageCache(detail)` 維持不變。

## 測試

- `test/models/accounts_bundle_test.dart`：版本不符斷言丟 `UnsupportedSchemaVersionException`（而非 `FormatException` 字串比對）；其餘 malformed 仍丟 `FormatException`。
- `test/services/accounts_import_test.dart`：版本不符例外原樣上拋（不被吞成 `FormatException`）；其餘維持 `FormatException`。
- `gacha_repository` `_friendlyError` 映射：`http.ClientException → UpdateErrorNetwork`、`FormatException`／泛用 → `UpdateErrorUnexpected`、`GachaApiException → UpdateErrorGachaFailed`、`_NoRecordsException → UpdateErrorNoRecords`（若 `_friendlyError` 為 private，於既有可達測試點驗，或加 `@visibleForTesting` 包裝——實作時依既有測試慣例決定）。
- 全綠 `fvm flutter analyze` ＋ `fvm flutter test`。

## 影響檔案清單

| 檔案 | 改動 |
|------|------|
| `lib/models/accounts_bundle.dart` | 新增 `UnsupportedSchemaVersionException`；版本不符分支改丟此例外 |
| `lib/services/accounts_import.dart` | try/catch 加 `on UnsupportedSchemaVersionException rethrow` |
| `lib/pages/settings_page.dart` | 匯出／匯入讀檔／匯入解析三個失敗點改用 reason key；補匯入讀檔 log |
| `lib/state/update_error.dart` | 移除 `UpdateErrorOther`，新增 `UpdateErrorNetwork`／`UpdateErrorUnexpected` |
| `lib/state/gacha_repository.dart` | `_friendlyError` 改 emit 型別化錯誤 |
| `lib/widgets/update_progress_dialog.dart` | `_resolveError` 解析新型別 |
| `lib/l10n/app_zh.arb`／`app_en.arb` | 新增 6 個 key（含 `@` metadata） |
| 其餘語系 ARB | 回填原神既有 3 個語意相同 key；其餘交 Crowdin |
| `test/models/accounts_bundle_test.dart`／`test/services/accounts_import_test.dart` | 更新斷言為型別檢查 |
