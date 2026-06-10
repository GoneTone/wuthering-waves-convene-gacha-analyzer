# Import Source Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect on import whether a backup was exported by this app (鳴潮), rejecting foreign bundles (e.g. the sister 原神 app) with a clear localized message.

**Architecture:** Mirror the sister project's two-layer detection: write an `app` identifier on export; on import, reject when `app` mismatches, and for app-less legacy backups fall back to screening `banners` keys against 鳴潮's known card-pool codes (the two games' codes never overlap). Also align the schema check to forward-compatible `>` semantics.

**Tech Stack:** Flutter / Dart, `flutter_test`, FVM-pinned SDK, ARB-based l10n (`fvm flutter gen-l10n`).

---

## File Structure

- `lib/models/accounts_bundle.dart` — add `accountsBundleAppId` const, write `app` in `toJson`, change schema check to `>`.
- `lib/services/accounts_export.dart` — no change (carries `app` via `toJson`); listed for reference only.
- `lib/services/accounts_import.dart` — add `ForeignBundleException`, the `app` check in `importAccounts`, and the private `_screenLegacyBundle`.
- `lib/pages/settings_page.dart` — add an `on ForeignBundleException` catch in `_import`.
- `lib/l10n/app_zh.arb` / `app_en.arb` / `app_ja.arb` / `app_zh_Hans.arb` — add `importReasonForeignApp`.
- `test/services/accounts_export_test.dart` — assert `app` is written.
- `test/services/accounts_import_test.dart` — app-match / foreign-app / legacy / mixed / schema-boundary tests; update the now-obsolete schema-1 test.

---

## Task 1: Export writes the `app` identifier

**Files:**
- Modify: `lib/models/accounts_bundle.dart`
- Test: `test/services/accounts_export_test.dart`

- [ ] **Step 1: Write the failing test**

Add this test inside `main()` in `test/services/accounts_export_test.dart`:

```dart
  test('export writes the app identifier', () {
    final byUid = {'A': _bs('A', DateTime.utc(2026, 5, 10))};
    final out = exportAccounts(
      byUid: byUid,
      uidOrder: const ['A'],
      uidAliases: const {},
      lastActiveUid: null,
      appVersion: '9.9.9',
      now: DateTime.utc(2026, 5, 12),
    );
    final decoded = jsonDecode(out) as Map<String, dynamic>;
    expect(decoded['app'], 'wuthering_waves_convene_gacha_analyzer');
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/services/accounts_export_test.dart`
Expected: FAIL — `decoded['app']` is `null`, not the expected string.

- [ ] **Step 3: Add the const and write the field**

In `lib/models/accounts_bundle.dart`, add this top-level const just below the `import` line (above `UnsupportedSchemaVersionException`):

```dart
/// 本軟體的匯出識別字串，寫入備份檔的 `app` 欄位供匯入端辨識來源。
///
/// 值對齊 pubspec 套件名；姐妹專案（原神）為 `genshin_impact_wish_gacha_analyzer`，天生相異。
const String accountsBundleAppId = 'wuthering_waves_convene_gacha_analyzer';
```

Then in `AccountsBundle.toJson()`, insert the `app` entry right after `schema_version`:

```dart
  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'app': accountsBundleAppId,
    'exported_at': exportedAt.toUtc().toIso8601String(),
    'app_version': appVersion,
    'last_active_uid': lastActiveUid,
    'accounts': accounts.map((a) => a.toJson()).toList(growable: false),
  };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `fvm flutter test test/services/accounts_export_test.dart`
Expected: PASS (all tests in file).

- [ ] **Step 5: Commit**

```bash
git add lib/models/accounts_bundle.dart test/services/accounts_export_test.dart
git commit -m "feat(export): write app identifier into backup bundle"
```

---

## Task 2: Forward-compatible schema check (`>`)

**Files:**
- Modify: `lib/models/accounts_bundle.dart:83`
- Test: `test/services/accounts_import_test.dart`

- [ ] **Step 1: Update the obsolete test and add the boundary tests**

In `test/services/accounts_import_test.dart`, **replace** the existing test block:

```dart
  test(
    'schema_version 不符 → UnsupportedSchemaVersionException（不被吞成 FormatException）',
    () {
      const text = '{"schema_version": 1, "accounts": []}';
      expect(
        () => importAccounts(text),
        throwsA(isA<UnsupportedSchemaVersionException>()),
      );
    },
  );
```

with these two tests (older/equal accepted, newer rejected):

```dart
  test('schema_version older than current is accepted', () {
    const text = '{"schema_version": 1, "accounts": []}';
    final bundle = importAccounts(text);
    expect(bundle.accounts, isEmpty);
  });

  test('schema_version newer than current → UnsupportedSchemaVersionException', () {
    const text = '{"schema_version": 3, "accounts": []}';
    expect(
      () => importAccounts(text),
      throwsA(isA<UnsupportedSchemaVersionException>()),
    );
  });
```

- [ ] **Step 2: Run tests to verify the new boundary tests fail**

Run: `fvm flutter test test/services/accounts_import_test.dart`
Expected: `schema_version older than current is accepted` FAILS (current `!=` still throws for version 1). The `newer` test passes already.

- [ ] **Step 3: Change the comparison operator**

In `lib/models/accounts_bundle.dart`, in `AccountsBundle.fromJson`, change:

```dart
    if (version != currentSchemaVersion) {
      throw UnsupportedSchemaVersionException(version);
    }
```

to:

```dart
    if (version > currentSchemaVersion) {
      throw UnsupportedSchemaVersionException(version);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `fvm flutter test test/services/accounts_import_test.dart`
Expected: PASS (all tests in file).

- [ ] **Step 5: Commit**

```bash
git add lib/models/accounts_bundle.dart test/services/accounts_import_test.dart
git commit -m "feat(import): accept older schema versions (forward-compatible)"
```

---

## Task 3: Reject foreign bundles by `app` identifier

**Files:**
- Modify: `lib/services/accounts_import.dart`
- Test: `test/services/accounts_import_test.dart`

- [ ] **Step 1: Write the failing tests**

Add these tests inside `main()` in `test/services/accounts_import_test.dart`:

```dart
  test('bundle with matching app identifier is imported', () {
    const text = '''
{
  "schema_version": 2,
  "app": "wuthering_waves_convene_gacha_analyzer",
  "exported_at": "2026-05-12T08:30:00.000Z",
  "app_version": "1.0.0",
  "last_active_uid": null,
  "accounts": [
    {
      "player_id": "100000001",
      "language_code": "zh-Hant",
      "last_updated": "2026-05-12T08:30:00.000Z",
      "banners": {"1": []}
    }
  ]
}
''';
    final bundle = importAccounts(text);
    expect(bundle.accounts.single.data.playerId, '100000001');
  });

  test('bundle with foreign app identifier → ForeignBundleException', () {
    const text = '''
{
  "schema_version": 2,
  "app": "genshin_impact_wish_gacha_analyzer",
  "accounts": []
}
''';
    expect(
      () => importAccounts(text),
      throwsA(isA<ForeignBundleException>()),
    );
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `fvm flutter test test/services/accounts_import_test.dart`
Expected: COMPILE ERROR — `ForeignBundleException` is undefined.

- [ ] **Step 3: Add the exception and the app check**

In `lib/services/accounts_import.dart`, add the import for the bundle const is already present (the file imports `accounts_bundle.dart`). Add the exception class just below `final _log = Logger('accounts.io');`:

```dart
/// 匯入檔不是由本軟體匯出（`app` 識別碼不符，或舊檔卡池代碼非鳴潮已知集合）時拋出。
class ForeignBundleException implements Exception {
  /// 建立 [ForeignBundleException]。
  const ForeignBundleException();

  @override
  String toString() => 'ForeignBundleException';
}
```

Then, in `importAccounts`, **after** the `raw is! Map<String, dynamic>` guard and **before** the `try { return AccountsBundle.fromJson(raw); }` block, insert the app dispatch and feed `prepared` into `fromJson`:

```dart
  final app = raw['app'];
  final Map<String, dynamic> prepared;
  if (app is String) {
    if (app != accountsBundleAppId) {
      _log.warning('import failed: foreign bundle (app=$app)');
      throw const ForeignBundleException();
    }
    prepared = raw; // 本軟體自己的檔，完整信任、不過濾
  } else {
    prepared = raw; // 暫時直通；legacy screening 於 Task 4 接上
  }
  try {
    return AccountsBundle.fromJson(prepared);
```

(Keep the existing `on UnsupportedSchemaVersionException` / `on FormatException` / `catch` blocks unchanged.)

Update the function dartdoc above `importAccounts` to mention the new exception:

```dart
/// 把 JSON 文字解析回 [AccountsBundle]。
/// schema 版本過新時拋出 [UnsupportedSchemaVersionException]；
/// 非本軟體產生的備份時拋出 [ForeignBundleException]；
/// 其餘結構或型別不符統一拋出 [FormatException]，皆供 UI 挑在地化文案顯示。
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `fvm flutter test test/services/accounts_import_test.dart`
Expected: PASS (all tests in file).

- [ ] **Step 5: Commit**

```bash
git add lib/services/accounts_import.dart test/services/accounts_import_test.dart
git commit -m "feat(import): reject foreign bundles by app identifier"
```

---

## Task 4: Legacy screening for app-less backups

**Files:**
- Modify: `lib/services/accounts_import.dart`
- Test: `test/services/accounts_import_test.dart`

- [ ] **Step 1: Write the failing tests**

Add these tests inside `main()` in `test/services/accounts_import_test.dart`:

```dart
  test('legacy bundle (no app) with WuWa pool codes is imported', () {
    const text = '''
{
  "schema_version": 2,
  "exported_at": "2026-05-12T08:30:00.000Z",
  "app_version": "1.0.0",
  "last_active_uid": null,
  "accounts": [
    {
      "player_id": "100000001",
      "language_code": "zh-Hant",
      "last_updated": "2026-05-12T08:30:00.000Z",
      "banners": {"1": [], "2": []}
    }
  ]
}
''';
    final bundle = importAccounts(text);
    expect(bundle.accounts.single.data.banners.keys, containsAll(['1', '2']));
  });

  test('legacy bundle (no app) with only Genshin codes → ForeignBundleException', () {
    const text = '''
{
  "schema_version": 2,
  "accounts": [
    {
      "player_id": "800000001",
      "language_code": "zh-Hant",
      "last_updated": "2026-05-12T08:30:00.000Z",
      "banners": {"301": [], "302": []}
    }
  ]
}
''';
    expect(
      () => importAccounts(text),
      throwsA(isA<ForeignBundleException>()),
    );
  });

  test('legacy bundle (no app) with mixed codes keeps only WuWa banners', () {
    const text = '''
{
  "schema_version": 2,
  "accounts": [
    {
      "player_id": "100000001",
      "language_code": "zh-Hant",
      "last_updated": "2026-05-12T08:30:00.000Z",
      "banners": {"1": [], "301": []}
    }
  ]
}
''';
    final bundle = importAccounts(text);
    final banners = bundle.accounts.single.data.banners;
    expect(banners.keys, ['1']);
    expect(banners.containsKey('301'), isFalse);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `fvm flutter test test/services/accounts_import_test.dart`
Expected: the Genshin-only test FAILS (no `ForeignBundleException` yet — it would currently throw `FormatException` from `fromJson` parsing the `301` records, or parse them as foreign data); the mixed test FAILS (`301` kept).

- [ ] **Step 3: Implement `_screenLegacyBundle` and wire it in**

In `lib/services/accounts_import.dart`, add the `gacha_types` import alongside the existing imports:

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/data/gacha_types.dart';
```

In `importAccounts`, change the app-less branch to call the screener:

```dart
  } else {
    prepared = _screenLegacyBundle(raw);
  }
```

Add the private helper at the end of the file:

```dart
/// 處理無 `app` 欄位的舊備份：依卡池代碼判別是否為本軟體（鳴潮）檔，並濾掉非鳴潮 banner。
///
/// 蒐集 `accounts[*].banners` 的 key 與 [gachaTypes] 已知集合比對：確有卡池資料但無一是
/// 鳴潮代碼 → 丟 [ForeignBundleException]（純外來，如原神檔）；否則回傳濾除未知 banner 後的
/// raw（未知代碼的 banner 整條跳過、濾空的帳號一併移除），只留可辨識的鳴潮 banner。
/// 讀不出任何卡池資料（空檔／結構模糊）→ 原樣交回，由 [AccountsBundle.fromJson] 後續處理。
Map<String, dynamic> _screenLegacyBundle(Map<String, dynamic> raw) {
  final known = {for (final t in gachaTypes) t.key};
  final accountsRaw = raw['accounts'];
  if (accountsRaw is! List) return raw;

  var sawAnyCode = false;
  var keptAnyKnown = false;
  // 非預期型別的 entry 原樣保留，讓 AccountsBundle.fromJson 拋出帶位置的結構錯誤。
  final filteredAccounts = <dynamic>[];
  for (final entry in accountsRaw) {
    if (entry is! Map<String, dynamic>) {
      filteredAccounts.add(entry);
      continue;
    }
    final bannersRaw = entry['banners'];
    if (bannersRaw is! Map<String, dynamic>) {
      filteredAccounts.add(entry);
      continue;
    }
    final keptBanners = <String, dynamic>{};
    for (final code in bannersRaw.keys) {
      sawAnyCode = true;
      if (known.contains(code)) {
        keptBanners[code] = bannersRaw[code];
        keptAnyKnown = true;
      }
    }
    if (keptBanners.isNotEmpty) {
      filteredAccounts.add({...entry, 'banners': keptBanners});
    }
  }

  if (sawAnyCode && !keptAnyKnown) {
    _log.warning('import failed: foreign bundle (no WuWa pools)');
    throw const ForeignBundleException();
  }
  return {...raw, 'accounts': filteredAccounts};
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `fvm flutter test test/services/accounts_import_test.dart`
Expected: PASS (all tests in file, including the legacy/mixed/foreign cases and the earlier schema + app tests).

- [ ] **Step 5: Commit**

```bash
git add lib/services/accounts_import.dart test/services/accounts_import_test.dart
git commit -m "feat(import): screen app-less legacy backups by pool codes"
```

---

## Task 5: Localized message + settings-page wiring

**Files:**
- Modify: `lib/l10n/app_zh.arb`, `lib/l10n/app_en.arb`, `lib/l10n/app_ja.arb`, `lib/l10n/app_zh_Hans.arb`
- Modify: `lib/pages/settings_page.dart` (in `_import`, around line 527)

- [ ] **Step 1: Add the ARB strings**

In `lib/l10n/app_zh.arb`, add next to the other `importReason*` keys:

```json
  "importReasonForeignApp": "此檔案不是由本軟體匯出的備份",
  "@importReasonForeignApp": {
    "description": "Import failure reason shown when the selected file was not exported by this app (e.g. a backup from the sister Genshin app)."
  },
```

In `lib/l10n/app_en.arb`:

```json
  "importReasonForeignApp": "This file was not exported by the app",
```

In `lib/l10n/app_ja.arb`:

```json
  "importReasonForeignApp": "このファイルは本ツールでエクスポートされたバックアップではありません",
```

In `lib/l10n/app_zh_Hans.arb`:

```json
  "importReasonForeignApp": "此文件不是由本软件导出的备份",
```

(Only `app_zh.arb` carries the `@`-metadata block — it is the template ARB; the other locales hold the value only, matching the existing `importReason*` entries.)

- [ ] **Step 2: Regenerate localizations**

Run: `fvm flutter gen-l10n`
Expected: completes without error; `l.importReasonForeignApp` becomes available on `AppLocalizations`.

- [ ] **Step 3: Add the catch in `_import`**

In `lib/pages/settings_page.dart`, in `_import`, add a new catch **before** `on UnsupportedSchemaVersionException`:

```dart
    final AccountsBundle bundle;
    try {
      bundle = importAccounts(text);
    } on ForeignBundleException {
      if (!ctx.mounted) return;
      _showSnack(ctx, l.settingsImportFailed(l.importReasonForeignApp));
      return;
    } on UnsupportedSchemaVersionException {
```

Ensure `ForeignBundleException` is in scope — it is exported from `accounts_import.dart`, which `settings_page.dart` already imports (it calls `importAccounts`). If the analyzer reports it unresolved, confirm the existing `import '.../services/accounts_import.dart';` line is present.

- [ ] **Step 4: Static analysis**

Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/l10n/app_zh.arb lib/l10n/app_en.arb lib/l10n/app_ja.arb lib/l10n/app_zh_Hans.arb lib/pages/settings_page.dart
git commit -m "feat(import): show localized reason for foreign backups"
```

---

## Task 6: Full quality gate

**Files:** none (verification only)

- [ ] **Step 1: Format**

Run: `fvm dart format lib/ test/`
Expected: reports formatted files (or none changed).

- [ ] **Step 2: Analyze**

Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: Full test suite**

Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 4: Commit any formatting changes**

```bash
git add -A
git commit -m "style: apply dart format" || echo "nothing to format"
```

---

## Self-Review Notes

- **Spec coverage:** export `app` field (Task 1) ✓; schema `>` (Task 2) ✓; `ForeignBundleException` + app check (Task 3) ✓; `_screenLegacyBundle` with `gachaTypes`-derived known set (Task 4) ✓; UI catch + `importReasonForeignApp` in core four ARB (Task 5) ✓; all spec test cases mapped across Tasks 2–4 ✓; log on both foreign branches (Task 3 app-mismatch, Task 4 no-WuWa-pools) ✓.
- **Obsolete test:** the pre-existing `schema_version 1 → UnsupportedSchemaVersionException` test is explicitly replaced in Task 2 because `>` now accepts version 1.
- **Known-set source:** `_screenLegacyBundle` derives codes from `gachaTypes` via `t.key` — no hard-coded code strings (spec D4 alignment).
- **Type consistency:** `ForeignBundleException` (const, no fields), `accountsBundleAppId` (String const), `_screenLegacyBundle(Map<String, dynamic>) -> Map<String, dynamic>` used consistently across tasks. 鳴潮 uses `playerId` (not `uid`) — reflected in test assertions.
