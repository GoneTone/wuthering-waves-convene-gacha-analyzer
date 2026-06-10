# 失敗訊息在地化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把匯入／匯出與喚取／擷取失敗時顯示給使用者的硬編英文訊息改為在地化，無殘留英文。

**Architecture:** 底層英文 `FormatException` 保留只供 log／測試；UI 與 dialog 邊界依「捕捉到的例外型別」挑在地化文案。新增型別化例外 `UnsupportedSchemaVersionException`（匯入版本不符）與型別化 `UpdateError` 子類 `UpdateErrorNetwork`／`UpdateErrorUnexpected`（取代會帶英文的 `UpdateErrorOther`），於 dialog `_resolveError` 解析成 ARB 文案。

**Tech Stack:** Flutter、flutter_localizations（gen-l10n，template = `app_zh.arb`）、Riverpod、`fvm`。

**設計文件：** `docs/superpowers/specs/2026-06-10-failure-message-l10n-design.md`

**慣例提醒：**
- 指令一律優先用 `fvm`（`fvm flutter ...`／`fvm dart ...`），找不到再退回 `flutter`／`dart`。
- 改 ARB 後須跑 `fvm flutter gen-l10n` 重新產生 `lib/l10n/generated/`（gitignore，不進 commit，但編譯需要）才能引用新 key。
- 省略號用 ASCII `...`（本專案慣例）。CJK 文案用全形標點。
- 每個 task commit 前先跑 `fvm dart format lib/ test/`。commit message 用英文 conventional commits。
- 不要 `git push`。

---

### Task 1: 新增 ARB 來源 key（app_zh.arb + app_en.arb）

新增 6 個 key。reason 與 error 文案皆無 placeholder，不需 `@` metadata（對齊既有 `errorGachaFailed`）。

**Files:**
- Modify: `lib/l10n/app_zh.arb`（template／來源）
- Modify: `lib/l10n/app_en.arb`

- [ ] **Step 1: app_zh.arb 新增兩個 update error key**

把這一行：

```json
  "errorNoRecords": "此帳號尚無任何卡池紀錄",
```

換成：

```json
  "errorNoRecords": "此帳號尚無任何卡池紀錄",
  "errorNetwork": "網路連線失敗，請檢查網路後重試",
  "errorUnexpected": "發生未預期的錯誤，請稍後再試",
```

- [ ] **Step 2: app_zh.arb 新增四個 import/export reason key**

把這一行：

```json
  "settingsImportFailed": "匯入失敗：{reason}",
```

換成：

```json
  "importReasonInvalidFormat": "檔案格式不正確或已損毀",
  "importReasonIncompatibleVersion": "此備份的資料版本與目前 App 不相容，無法匯入",
  "importReasonUnreadable": "無法讀取檔案",
  "exportReasonWriteFailed": "無法寫入檔案，請確認儲存位置與權限",
  "settingsImportFailed": "匯入失敗：{reason}",
```

- [ ] **Step 3: app_en.arb 新增兩個 update error key**

把這一行：

```json
  "errorNoRecords": "This account has no Convene records yet",
```

換成：

```json
  "errorNoRecords": "This account has no Convene records yet",
  "errorNetwork": "Network connection failed. Please check your connection and try again.",
  "errorUnexpected": "An unexpected error occurred. Please try again later.",
```

- [ ] **Step 4: app_en.arb 新增四個 import/export reason key**

把這一行：

```json
  "settingsImportFailed": "Import failed: {reason}",
```

換成：

```json
  "importReasonInvalidFormat": "The file format is invalid or the file is corrupted",
  "importReasonIncompatibleVersion": "This backup's data version is incompatible with the current app and cannot be imported",
  "importReasonUnreadable": "Unable to read the file",
  "exportReasonWriteFailed": "Unable to write the file, please check the save location and permissions",
  "settingsImportFailed": "Import failed: {reason}",
```

- [ ] **Step 5: 重新產生 l10n 並驗證**

Run: `fvm flutter gen-l10n && fvm flutter analyze`
Expected: gen-l10n 成功；analyze 輸出 `No issues found!`（新 key 尚未被引用，但 ARB 合法、getter 已產生）。

- [ ] **Step 6: Commit**

```bash
git add lib/l10n/app_zh.arb lib/l10n/app_en.arb
git commit -m "feat(l10n): add failure-reason strings for import/export and update errors"
```

---

### Task 2: Path A — `UnsupportedSchemaVersionException`（accounts_bundle）

schema 版本不符（`!=`，本專案 `currentSchemaVersion = 2`）改丟型別化例外，讓 UI 能與一般格式錯誤區隔。

**Files:**
- Modify: `lib/models/accounts_bundle.dart`
- Test: `test/models/accounts_bundle_test.dart:48-77`

- [ ] **Step 1: 改測試斷言為新例外型別**

`test/models/accounts_bundle_test.dart` 第一個版本測試（version=1）整段：

```dart
  test('schema_version != 2（不相容的舊備份 version=1）→ 友善訊息', () {
    final json = {
      'schema_version': 1,
      'exported_at': '2026-05-21T00:00:00.000Z',
      'app_version': '1.0.0',
      'accounts': <Map<String, dynamic>>[],
    };
    expect(
      () => AccountsBundle.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('不相容'),
        ),
      ),
    );
  });
```

換成：

```dart
  test('schema_version != 2（version=1）→ UnsupportedSchemaVersionException', () {
    final json = {
      'schema_version': 1,
      'exported_at': '2026-05-21T00:00:00.000Z',
      'app_version': '1.0.0',
      'accounts': <Map<String, dynamic>>[],
    };
    expect(
      () => AccountsBundle.fromJson(json),
      throwsA(
        isA<UnsupportedSchemaVersionException>().having(
          (e) => e.version,
          'version',
          1,
        ),
      ),
    );
  });
```

第二個版本測試（version=999）整段：

```dart
  test('schema_version 為較新版本（999）→ 同樣拒絕', () {
    final json = {
      'schema_version': 999,
      'exported_at': '2026-05-21T00:00:00.000Z',
      'accounts': <Map<String, dynamic>>[],
    };
    expect(
      () => AccountsBundle.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });
```

換成：

```dart
  test('schema_version 為較新版本（999）→ UnsupportedSchemaVersionException', () {
    final json = {
      'schema_version': 999,
      'exported_at': '2026-05-21T00:00:00.000Z',
      'accounts': <Map<String, dynamic>>[],
    };
    expect(
      () => AccountsBundle.fromJson(json),
      throwsA(isA<UnsupportedSchemaVersionException>()),
    );
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/models/accounts_bundle_test.dart`
Expected: FAIL —— `UnsupportedSchemaVersionException` 尚未定義（編譯錯）。

- [ ] **Step 3: 新增例外型別並改 throw 分支**

`lib/models/accounts_bundle.dart`：在 `AccountsBundle` class 定義之前（imports 之後）新增 top-level 例外型別：

```dart
/// 匯入檔的 schema 版本與目前 App 支援版本不符時拋出，供 UI 給出「版本不相容」訊息。
class UnsupportedSchemaVersionException implements Exception {
  /// 建立 [UnsupportedSchemaVersionException]。
  const UnsupportedSchemaVersionException(this.version);

  /// 匯入檔宣告的 schema 版本（與 [AccountsBundle.currentSchemaVersion] 不符）。
  final int version;
}
```

把版本不符分支：

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

把 `fromJson` 的 dartdoc：

```dart
  /// 從 JSON 還原 [AccountsBundle]，schema 版本不相容時丟 [FormatException]。
```

換成：

```dart
  /// 從 JSON 還原 [AccountsBundle]，schema 版本不符時丟
  /// [UnsupportedSchemaVersionException]，其餘格式錯誤丟 [FormatException]。
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/models/accounts_bundle_test.dart`
Expected: PASS（All tests passed!）。

- [ ] **Step 5: Commit**

```bash
fvm dart format lib/ test/
git add lib/models/accounts_bundle.dart test/models/accounts_bundle_test.dart
git commit -m "feat(import): throw typed UnsupportedSchemaVersionException on version mismatch"
```

---

### Task 3: Path A — accounts_import 讓版本例外原樣上拋

`importAccounts` 的泛用 catch 目前會把任何非 `FormatException` 包成英文 `FormatException('Failed to parse...')`，會吞掉新例外。要先攔截原樣 rethrow。

**Files:**
- Modify: `lib/services/accounts_import.dart:24-32`
- Test: `test/services/accounts_import_test.dart`

- [ ] **Step 1: 加測試（版本不符不被吞成 FormatException）**

`test/services/accounts_import_test.dart`：確認檔頭已 import accounts_bundle（型別來源），若無則於 import 區加：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
```

在既有 `main()` 內任一 `test(...)` 後新增：

```dart
  test('schema_version 不符 → UnsupportedSchemaVersionException（不被吞成 FormatException）', () {
    const text = '{"schema_version": 1, "accounts": []}';
    expect(
      () => importAccounts(text),
      throwsA(isA<UnsupportedSchemaVersionException>()),
    );
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/accounts_import_test.dart`
Expected: FAIL —— 目前泛用 catch 會把它包成 `FormatException`，斷言型別不符。

- [ ] **Step 3: 加 `on UnsupportedSchemaVersionException` rethrow**

`lib/services/accounts_import.dart` 把：

```dart
  try {
    return AccountsBundle.fromJson(raw);
  } on FormatException catch (e) {
    _log.warning('import failed: ${e.message}');
    rethrow;
  } catch (e, st) {
    _log.warning('import failed: parse error', e, st);
    throw FormatException('Failed to parse: $e');
  }
```

換成：

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

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/services/accounts_import_test.dart`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
fvm dart format lib/ test/
git add lib/services/accounts_import.dart test/services/accounts_import_test.dart
git commit -m "feat(import): rethrow UnsupportedSchemaVersionException without wrapping"
```

---

### Task 4: Path A — settings_page 三個失敗點改用在地化 reason

匯出寫檔、匯入讀檔、匯入解析三處停止把英文例外丟進 UI；補上目前缺漏的匯入讀檔失敗 log。此檔無單元測試，以 `analyze`（編譯）把關。

**Files:**
- Modify: `lib/pages/settings_page.dart`（約 475-528 行）

- [ ] **Step 1: 確認例外型別可取用**

確認 `lib/pages/settings_page.dart` 檔頭已 import accounts_bundle（已使用 `AccountsBundle` 型別，理應已 import）。若無，於 import 區加：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
```

- [ ] **Step 2: 匯出寫檔失敗改用 exportReasonWriteFailed**

把：

```dart
        message: l.settingsExportFailed(e.toString()),
```

換成：

```dart
        message: l.settingsExportFailed(l.exportReasonWriteFailed),
```

- [ ] **Step 3: 匯入讀檔失敗補 log 並改用 importReasonUnreadable**

把：

```dart
    } catch (e) {
      if (!ctx.mounted) return;
      _showSnack(ctx, l.settingsImportFailed(e.toString()));
      return;
    }
```

換成：

```dart
    } catch (e, st) {
      Logger('accounts.io').warning('import failed: unable to read file', e, st);
      if (!ctx.mounted) return;
      _showSnack(ctx, l.settingsImportFailed(l.importReasonUnreadable));
      return;
    }
```

（`Logger('accounts.io')` 在本檔匯出路徑已使用，`logging` 套件已 import，無需新增 import。）

- [ ] **Step 4: 匯入解析失敗拆兩個 catch**

把：

```dart
    try {
      bundle = importAccounts(text);
    } on FormatException catch (e) {
      if (!ctx.mounted) return;
      _showSnack(ctx, l.settingsImportFailed(e.message));
      return;
    }
```

換成：

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

- [ ] **Step 5: 驗證 analyze**

Run: `fvm flutter analyze`
Expected: `No issues found!`（無未使用變數警告——`e` 已不再於 reason 分支被引用，故移除了綁定。）

- [ ] **Step 6: Commit**

```bash
fvm dart format lib/ test/
git add lib/pages/settings_page.dart
git commit -m "feat(import): show localized reasons for import/export failures"
```

---

### Task 5: Path B — 型別化 UpdateError 取代 UpdateErrorOther

`UpdateErrorOther` 的 `message` 會直送 UI 顯示英文。移除它，改用無 payload 的 `UpdateErrorNetwork`／`UpdateErrorUnexpected`，於 dialog 解析成 ARB 文案。此改動跨 `update_error.dart`／`gacha_repository.dart`／`update_progress_dialog.dart` 與兩個測試檔，須一併修改以維持編譯（sealed class 窮舉）。

**Files:**
- Modify: `lib/state/update_error.dart:25-32`
- Modify: `lib/state/gacha_repository.dart:1165-1176`
- Modify: `lib/widgets/update_progress_dialog.dart:272`
- Test: `test/state/update_error_test.dart`、`test/state/gacha_repository_test.dart:321,343`

- [ ] **Step 1: 先改測試引用新型別（TDD：先讓它編不過）**

`test/state/gacha_repository_test.dart` 把：

```dart
    expect((progress as UpdateFailed).error, isA<UpdateErrorOther>());
```

換成：

```dart
    expect((progress as UpdateFailed).error, isA<UpdateErrorNetwork>());
```

（該測試以 `MockClient` 丟 `http.ClientException('network down', ...)` 觸發，對應新映射 `http.ClientException → UpdateErrorNetwork`。）

同檔把：

```dart
    notifier.debugSetProgress(const UpdateFailed(UpdateErrorOther('test')));
```

換成：

```dart
    notifier.debugSetProgress(const UpdateFailed(UpdateErrorUnexpected()));
```

`test/state/update_error_test.dart` 在 `main()` 內新增兩個型別測試：

```dart
  test('UpdateErrorNetwork is a const UpdateError', () {
    const e = UpdateErrorNetwork();
    expect(e, isA<UpdateError>());
  });

  test('UpdateErrorUnexpected is a const UpdateError', () {
    const e = UpdateErrorUnexpected();
    expect(e, isA<UpdateError>());
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/state/update_error_test.dart test/state/gacha_repository_test.dart`
Expected: FAIL —— `UpdateErrorNetwork`／`UpdateErrorUnexpected` 尚未定義（編譯錯）。

- [ ] **Step 3: update_error.dart 移除 Other、新增兩型別**

把：

```dart
/// fallback：訊息已是 user-readable（多半來自 FormatException 等），直接顯示。
class UpdateErrorOther extends UpdateError {
  /// 建立 [UpdateErrorOther]，[message] 為直接顯示給使用者的錯誤訊息。
  const UpdateErrorOther(this.message);

  /// 直接顯示給使用者的錯誤訊息。
  final String message;
}
```

換成：

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

- [ ] **Step 4: gacha_repository.dart `_friendlyError` 改 emit 型別化錯誤**

把：

```dart
  UpdateError _friendlyError(Object e) => switch (e) {
    _NoRecordsException() => const UpdateErrorNoRecords(),
    GachaApiException(:final code, :final message) => UpdateErrorGachaFailed(
      code,
      message,
    ),
    FormatException(:final message) => UpdateErrorOther(message),
    http.ClientException(:final message, :final uri) => UpdateErrorOther(
      uri != null ? '$message ($uri)' : message,
    ),
    _ => UpdateErrorOther(e.toString()),
  };
```

換成：

```dart
  UpdateError _friendlyError(Object e) => switch (e) {
    _NoRecordsException() => const UpdateErrorNoRecords(),
    GachaApiException(:final code, :final message) => UpdateErrorGachaFailed(
      code,
      message,
    ),
    http.ClientException() => const UpdateErrorNetwork(),
    _ => const UpdateErrorUnexpected(),
  };
```

（`FormatException` 併入泛用 `_ → UpdateErrorUnexpected`。`http.ClientException` 的 message／uri 英文細節已於呼叫處 line 307-308／328-330 有 `_log.warning`，泛用例外於 line 314／336 有 `_log.severe(..., e, st)`，保留不變。）

- [ ] **Step 5: update_progress_dialog.dart `_resolveError` 解析新型別**

把：

```dart
        UpdateErrorOther(:final message) => message,
```

換成：

```dart
        UpdateErrorNetwork() => l.errorNetwork,
        UpdateErrorUnexpected() => l.errorUnexpected,
```

- [ ] **Step 6: 確認無殘留 UpdateErrorOther 引用**

Run: `rg -n "UpdateErrorOther" lib/ test/`
Expected: 無輸出（全數移除）。

- [ ] **Step 7: 跑測試與分析確認通過**

Run: `fvm flutter analyze && fvm flutter test test/state/update_error_test.dart test/state/gacha_repository_test.dart`
Expected: analyze `No issues found!`；測試 All tests passed!。

- [ ] **Step 8: Commit**

```bash
fvm dart format lib/ test/
git add lib/state/update_error.dart lib/state/gacha_repository.dart lib/widgets/update_progress_dialog.dart test/state/update_error_test.dart test/state/gacha_repository_test.dart
git commit -m "feat(update): localize gacha fetch network/unexpected failure messages"
```

---

### Task 6: 回填 ja 與 zh_Hans 的 3 個語意相同 reason key

`importReasonInvalidFormat`／`importReasonUnreadable`／`exportReasonWriteFailed` 在姐妹專案已有 ja／zh_Hans 譯文，且這兩個語系在本專案是完整翻譯語系（~505 keys），直接回填。`importReasonIncompatibleVersion`／`errorNetwork`／`errorUnexpected` 為新措辭，交 Crowdin。其餘語系（es/fr/pt_BR/th/vi 等）為空殼，一律交 Crowdin。

**Files:**
- Modify: `lib/l10n/app_ja.arb`
- Modify: `lib/l10n/app_zh_Hans.arb`

- [ ] **Step 1: app_ja.arb 回填 3 key**

把：

```json
  "settingsImportFailed": "インポートに失敗しました：{reason}",
```

換成：

```json
  "importReasonInvalidFormat": "ファイル形式が正しくないか、ファイルが破損しています",
  "importReasonUnreadable": "ファイルを読み込めません",
  "exportReasonWriteFailed": "ファイルを書き込めません。保存先と権限を確認してください",
  "settingsImportFailed": "インポートに失敗しました：{reason}",
```

- [ ] **Step 2: app_zh_Hans.arb 回填 3 key**

把：

```json
  "settingsImportFailed": "导入失败：{reason}",
```

換成：

```json
  "importReasonInvalidFormat": "文件格式不正确或已损坏",
  "importReasonUnreadable": "无法读取文件",
  "exportReasonWriteFailed": "无法写入文件，请确认保存位置与权限",
  "settingsImportFailed": "导入失败：{reason}",
```

- [ ] **Step 3: 重新產生 l10n 並分析**

Run: `fvm flutter gen-l10n && fvm flutter analyze`
Expected: 成功；`No issues found!`。

- [ ] **Step 4: Commit**

```bash
git add lib/l10n/app_ja.arb lib/l10n/app_zh_Hans.arb
git commit -m "feat(l10n): backfill ja/zh-Hans import-export failure reasons"
```

---

### Task 7: 最終品質閘門

**Files:** 無（僅驗證）

- [ ] **Step 1: 格式化**

Run: `fvm dart format lib/ test/`
Expected: 無變更（前面各 task 已格式化）；若有變更則該檔被重排。

- [ ] **Step 2: 靜態分析**

Run: `fvm flutter analyze`
Expected: `No issues found!`。

- [ ] **Step 3: 全測試**

Run: `fvm flutter test`
Expected: `All tests passed!`。

- [ ] **Step 4: 若 Step 1 有重排檔案則補 commit**

```bash
git add -A
git commit -m "style: apply dart format"
```

（若 Step 1 無變更則跳過此步。）

---

## 影響檔案總覽

| 檔案 | Task | 改動 |
|------|------|------|
| `lib/l10n/app_zh.arb` | 1 | 新增 6 key（來源） |
| `lib/l10n/app_en.arb` | 1 | 新增 6 key |
| `lib/models/accounts_bundle.dart` | 2 | 新增 `UnsupportedSchemaVersionException`；版本分支改丟此例外 |
| `test/models/accounts_bundle_test.dart` | 2 | 2 個版本測試改型別斷言 |
| `lib/services/accounts_import.dart` | 3 | 加 `on UnsupportedSchemaVersionException rethrow` |
| `test/services/accounts_import_test.dart` | 3 | 新增版本例外上拋測試 |
| `lib/pages/settings_page.dart` | 4 | 三個失敗點改用 reason key；補匯入讀檔 log |
| `lib/state/update_error.dart` | 5 | 移除 `UpdateErrorOther`，新增 `UpdateErrorNetwork`／`UpdateErrorUnexpected` |
| `lib/state/gacha_repository.dart` | 5 | `_friendlyError` 改 emit 型別化錯誤 |
| `lib/widgets/update_progress_dialog.dart` | 5 | `_resolveError` 解析新型別 |
| `test/state/update_error_test.dart` | 5 | 新增兩型別測試 |
| `test/state/gacha_repository_test.dart` | 5 | 兩處 `UpdateErrorOther` 引用改新型別 |
| `lib/l10n/app_ja.arb`／`app_zh_Hans.arb` | 6 | 回填 3 個 reason key |
