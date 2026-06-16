# Gacha Data-Language Conversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a settings-page "data language" option (independent of app UI locale) that unifies mixed-language gacha history into one of 9 languages via encore.moe catalogs, with local per-language caching, a manual unify button, and auto-conversion on update/import.

**Architecture:** A new persistent per-language catalog cache (`lang_catalog/<lang>.json`) built from `EncoreCatalog`; a pure `GachaLanguageConverter` that mutates each record's `name` + `languageCode` (resolving by `resourceId`, backfilling synthetic IDs via name lookup); a tri-state setting (`unset` / `none` / code) with auto-seeding from the latest data; and conversion hooked as a post-step into `update()`, import, and a unify-all button. Type labels keep following the UI locale via existing ARB; detail display follows automatically from the `languageCode` mutation.

**Tech Stack:** Flutter 3.44.1 (FVM-pinned), Riverpod 3.x (`NotifierProvider`), SharedPreferences, `http`, JSON file storage. All Flutter/Dart commands run via `fvm`.

**Spec:** `docs/superpowers/specs/2026-06-16-gacha-data-language-conversion-design.md`

**Conventions:**
- Run all commands via `fvm flutter ...` / `fvm dart ...`.
- Before every commit: `fvm dart format lib/ test/` → `fvm flutter analyze` (must print `No issues found!`) → `fvm flutter test` (must print `All tests passed!`).
- Dartdoc (`///`) on every new declaration. Full-width CJK punctuation in comments/dartdoc/UI strings; ASCII `...` for ellipsis. Commit subjects in English, conventional commits.
- Do NOT `git push`.

**Import prefix used throughout:** package root is `package:wuthering_waves_convene_gacha_analyzer/`.

---

## Task 1: Add `nameByKindId` to `EncoreCatalog`

Gives the converter a language-specific `resourceId → name` map (parallel to the existing `iconByKindId`), reusing `fetchCatalog` instead of writing a new fetcher.

**Files:**
- Modify: `lib/services/item_image_fetcher.dart` (EncoreCatalog ~151-168, `fetchCatalog` ~234-273)
- Test: `test/services/encore_catalog_name_test.dart` (create)

- [ ] **Step 1: Write the failing test**

```dart
// test/services/encore_catalog_name_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

void main() {
  test('EncoreCatalog exposes nameByKindId', () {
    const cat = EncoreCatalog(
      iconByKindId: {
        kItemKindCharacter: {1304: 'http://x/icon.png'},
      },
      nameByKindId: {
        kItemKindCharacter: {1304: 'Jinhsi'},
      },
    );
    expect(cat.nameByKindId[kItemKindCharacter]![1304], 'Jinhsi');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/services/encore_catalog_name_test.dart`
Expected: FAIL — `EncoreCatalog` has no `nameByKindId` parameter.

- [ ] **Step 3: Add the field and populate it**

In `EncoreCatalog` (lib/services/item_image_fetcher.dart), add the field + constructor param:

```dart
class EncoreCatalog {
  /// 建立 [EncoreCatalog]。
  const EncoreCatalog({
    required this.iconByKindId,
    this.nameByKindId = const {},
    this.idByName = const {},
  });

  /// kind（`kItemKind*`）→ `{resourceId → iconUrl}`。
  final Map<String, Map<int, String>> iconByKindId;

  /// kind（`kItemKind*`）→ `{resourceId → 物品名稱}`，與 [iconByKindId] 平行，
  /// 供資料語言轉換以 `resourceId` 取該語言名稱。
  final Map<String, Map<int, String>> nameByKindId;

  // ... 既有 idByName / iconFor / resolveByName 不動 ...
```

In `fetchCatalog`, accumulate names per kind and pass them through. Add a `nameByKindId` map next to `iconByKindId` and fill it from each `parsed.names` (which is `{name → id}`; invert to `{id → name}`):

```dart
  Future<EncoreCatalog> fetchCatalog({
    required String lang,
    required Set<String> kinds,
    required http.Client client,
  }) async {
    final iconByKindId = <String, Map<int, String>>{};
    final nameByKindId = <String, Map<int, String>>{};
    final idByName = <String, ({int id, String kind})>{};
    final ambiguousNames = <String>{};
    final encLang = encoreLang(lang);
    for (final kind in kinds) {
      final seg = _kindToSegment[kind];
      if (seg == null) continue;
      final parsed = await _fetchCatalogKind(
        lang: encLang,
        kind: kind,
        seg: seg,
        client: client,
      );
      iconByKindId[kind] = parsed.icons;
      nameByKindId[kind] = {
        for (final e in parsed.names.entries) e.value: e.key,
      };
      parsed.names.forEach((name, id) {
        if (ambiguousNames.contains(name)) return;
        final existing = idByName[name];
        if (existing == null) {
          idByName[name] = (id: id, kind: kind);
        } else if (existing.id != id) {
          idByName.remove(name);
          ambiguousNames.add(name);
        }
      });
    }
    if (ambiguousNames.isNotEmpty) {
      _log.warning(
        'catalog: ${ambiguousNames.length} ambiguous name(s) excluded from '
        'idByName (same name across kinds) e.g. '
        '${ambiguousNames.take(5).toList()}',
      );
    }
    return EncoreCatalog(
      iconByKindId: iconByKindId,
      nameByKindId: nameByKindId,
      idByName: idByName,
    );
  }
```

> Note: `parsed.names` is `{name → id}` with `putIfAbsent`, so the first id wins per name. Inverting to `{id → name}` is unambiguous because each `id` has one `Name` in the source list.

- [ ] **Step 4: Run test to verify it passes**

Run: `fvm flutter test test/services/encore_catalog_name_test.dart`
Expected: PASS.

- [ ] **Step 5: Format, analyze, full test, commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/services/item_image_fetcher.dart test/services/encore_catalog_name_test.dart
git commit -m "feat(encore): expose nameByKindId on EncoreCatalog"
```

---

## Task 2: Data-language options constant

The 9 selectable data languages (independent of UI locale), with native-name labels and a membership check used by seeding.

**Files:**
- Create: `lib/services/data_language.dart`
- Test: `test/services/data_language_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/services/data_language_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/data_language.dart';

void main() {
  test('9 options, encore-aligned codes, native labels', () {
    expect(kDataLanguageOptions.length, 9);
    expect(kDataLanguageOptions.map((o) => o.code).toList(), [
      'zh-Hant', 'zh-Hans', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'th',
    ]);
    expect(kDataLanguageOptions.first.label, '繁體中文');
  });

  test('isSupportedDataLanguage', () {
    expect(isSupportedDataLanguage('ja'), isTrue);
    expect(isSupportedDataLanguage('zh-Hant'), isTrue);
    expect(isSupportedDataLanguage('id'), isFalse); // encore supports it, we don't offer it
    expect(isSupportedDataLanguage(''), isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/services/data_language_test.dart`
Expected: FAIL — file/symbols not found.

- [ ] **Step 3: Create the file**

```dart
// lib/services/data_language.dart

/// 單一可選資料語言：encore 對齊的 [code] 與母語顯示 [label]。
typedef DataLanguageOption = ({String code, String label});

/// 可選的資料語言清單（顯示順序固定），代碼對齊 encore.moe，與 App UI 語言獨立。
const List<DataLanguageOption> kDataLanguageOptions = [
  (code: 'zh-Hant', label: '繁體中文'),
  (code: 'zh-Hans', label: '简体中文'),
  (code: 'en', label: 'English'),
  (code: 'ja', label: '日本語'),
  (code: 'ko', label: '한국어'),
  (code: 'fr', label: 'Français'),
  (code: 'de', label: 'Deutsch'),
  (code: 'es', label: 'Español'),
  (code: 'th', label: 'ภาษาไทย'),
];

/// 可選資料語言代碼集合（供 seeding 判定語言是否在選項內）。
final Set<String> kDataLanguageCodes = {
  for (final o in kDataLanguageOptions) o.code,
};

/// [code] 是否為可選資料語言（用於自動播種：落在選項外則維持未設定）。
bool isSupportedDataLanguage(String code) => kDataLanguageCodes.contains(code);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `fvm flutter test test/services/data_language_test.dart`
Expected: PASS.

- [ ] **Step 5: Format, analyze, commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/services/data_language.dart test/services/data_language_test.dart
git commit -m "feat(settings): add data-language options constant"
```

---

## Task 3: `AppSettings` + `SettingsStorage` tri-state persistence

Add `dataLanguage` (`String?`, null=未設定) + `dataLanguageSeeded` (bool) with three-state persistence: key absent = never initialized (seedable), `"none"` = explicitly unset, code = set.

**Files:**
- Modify: `lib/services/settings_storage.dart` (AppSettings 73-138, copyWith, keys 145-164, load 167-180, save 182-198)
- Test: `test/services/settings_storage_data_language_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/services/settings_storage_data_language_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/settings_storage.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('absent key => unset & not seeded', () async {
    final s = await SettingsStorage.load();
    expect(s.dataLanguage, isNull);
    expect(s.dataLanguageSeeded, isFalse);
  });

  test('round-trip: language code => set & seeded', () async {
    await SettingsStorage.save(
      AppSettings.defaults.copyWith(dataLanguage: 'ja', dataLanguageSeeded: true),
    );
    final s = await SettingsStorage.load();
    expect(s.dataLanguage, 'ja');
    expect(s.dataLanguageSeeded, isTrue);
  });

  test('round-trip: explicit none => unset but seeded', () async {
    await SettingsStorage.save(
      AppSettings.defaults
          .copyWith(clearDataLanguage: true, dataLanguageSeeded: true),
    );
    final s = await SettingsStorage.load();
    expect(s.dataLanguage, isNull);
    expect(s.dataLanguageSeeded, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/services/settings_storage_data_language_test.dart`
Expected: FAIL — `dataLanguage` / `dataLanguageSeeded` / `clearDataLanguage` not defined.

- [ ] **Step 3: Add fields, defaults, copyWith, key, load/save**

Add two fields to `AppSettings` (after `maskUidInUi`):

```dart
  /// 資料語言代碼（如 `ja`）；null 代表未設定（停用轉換）。獨立於 App UI 語言。
  final String? dataLanguage;

  /// 資料語言是否已初始化（自動播種或使用者明確選擇過）。false 代表可被自動播種。
  final bool dataLanguageSeeded;
```

Add to the constructor params:

```dart
    this.dataLanguage,
    this.dataLanguageSeeded = false,
```

Extend `copyWith` — add params and a `clearDataLanguage` flag (mirrors `clearLastActiveUid`):

```dart
  AppSettings copyWith({
    AppThemeMode? themeMode,
    LanguagePreference? locale,
    String? lastActiveUid,
    bool clearLastActiveUid = false,
    Map<String, String>? uidAliases,
    List<String>? uidOrder,
    String? skippedReleaseTag,
    bool clearSkippedReleaseTag = false,
    bool? maskUidInUi,
    String? dataLanguage,
    bool clearDataLanguage = false,
    bool? dataLanguageSeeded,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    locale: locale ?? this.locale,
    lastActiveUid: clearLastActiveUid
        ? null
        : (lastActiveUid ?? this.lastActiveUid),
    uidAliases: uidAliases ?? this.uidAliases,
    uidOrder: uidOrder ?? this.uidOrder,
    skippedReleaseTag: clearSkippedReleaseTag
        ? null
        : (skippedReleaseTag ?? this.skippedReleaseTag),
    maskUidInUi: maskUidInUi ?? this.maskUidInUi,
    dataLanguage: clearDataLanguage
        ? null
        : (dataLanguage ?? this.dataLanguage),
    dataLanguageSeeded: dataLanguageSeeded ?? this.dataLanguageSeeded,
  );
```

Add the pref key (near the other `_k...` constants):

```dart
  /// SharedPreferences key：資料語言（語言碼／`"none"`／不存在三態）。
  static const _kDataLanguage = 'pref.dataLanguage';
```

In `load()`, decode the three states (add to the `AppSettings(...)` returned):

```dart
    final dataLangRaw = prefs.getString(_kDataLanguage);
    // ...inside the returned AppSettings(...):
      dataLanguage: dataLangRaw == null || dataLangRaw == 'none'
          ? null
          : dataLangRaw,
      dataLanguageSeeded: dataLangRaw != null,
```

(Implement by reading `dataLangRaw` before the `return AppSettings(`, then add the two named args.)

In `save()`, encode the three states (append before the method end):

```dart
    if (!s.dataLanguageSeeded) {
      await prefs.remove(_kDataLanguage);
    } else {
      await prefs.setString(_kDataLanguage, s.dataLanguage ?? 'none');
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `fvm flutter test test/services/settings_storage_data_language_test.dart`
Expected: PASS.

- [ ] **Step 5: Format, analyze, full test, commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/services/settings_storage.dart test/services/settings_storage_data_language_test.dart
git commit -m "feat(settings): persist tri-state data-language preference"
```

---

## Task 4: `SettingsNotifier` setters + `dataLanguageProvider`

`setDataLanguage(code|null)` (any call marks seeded), `seedDataLanguageIfUnset(code)` (only when not seeded and code is offered), and a derived provider.

**Files:**
- Modify: `lib/state/settings.dart` (SettingsNotifier 7-116, providers 118-157)
- Test: `test/state/settings_data_language_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/state/settings_data_language_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('setDataLanguage sets value and marks seeded', () async {
    final c = makeContainer();
    await c.read(settingsProvider.notifier).waitForLoad();
    await c.read(settingsProvider.notifier).setDataLanguage('ja');
    expect(c.read(settingsProvider).dataLanguage, 'ja');
    expect(c.read(settingsProvider).dataLanguageSeeded, isTrue);
    expect(c.read(dataLanguageProvider), 'ja');
  });

  test('setDataLanguage(null) = explicit unset, marks seeded', () async {
    final c = makeContainer();
    await c.read(settingsProvider.notifier).waitForLoad();
    await c.read(settingsProvider.notifier).setDataLanguage(null);
    expect(c.read(settingsProvider).dataLanguage, isNull);
    expect(c.read(settingsProvider).dataLanguageSeeded, isTrue);
  });

  test('seedDataLanguageIfUnset seeds only when unseeded & supported', () async {
    final c = makeContainer();
    final n = c.read(settingsProvider.notifier);
    await n.waitForLoad();
    await n.seedDataLanguageIfUnset('id'); // not offered
    expect(c.read(settingsProvider).dataLanguage, isNull);
    expect(c.read(settingsProvider).dataLanguageSeeded, isFalse);
    await n.seedDataLanguageIfUnset('ko'); // offered
    expect(c.read(settingsProvider).dataLanguage, 'ko');
    expect(c.read(settingsProvider).dataLanguageSeeded, isTrue);
    await n.seedDataLanguageIfUnset('ja'); // already seeded => no-op
    expect(c.read(settingsProvider).dataLanguage, 'ko');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/state/settings_data_language_test.dart`
Expected: FAIL — methods/provider not defined.

- [ ] **Step 3: Add setters + provider**

Add the import at the top of `lib/state/settings.dart`:

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/data_language.dart';
```

Add two methods to `SettingsNotifier` (next to `setLocale`):

```dart
  /// 設定資料語言並持久化；[code] 為 null 代表使用者明確選「未設定」。
  /// 任何呼叫都標記 `dataLanguageSeeded=true`，停止後續自動播種。
  Future<void> setDataLanguage(String? code) async {
    state = state.copyWith(
      dataLanguage: code,
      clearDataLanguage: code == null,
      dataLanguageSeeded: true,
    );
    await SettingsStorage.save(state);
    Logger('app.settings').info('dataLanguage set=${code ?? 'none'}');
  }

  /// 僅當尚未初始化（`!dataLanguageSeeded`）且 [code] 屬可選資料語言時，
  /// 以 [code] 自動播種並標記 seeded；否則 no-op（留待之後在有效語言下播種）。
  Future<void> seedDataLanguageIfUnset(String code) async {
    if (state.dataLanguageSeeded) return;
    if (!isSupportedDataLanguage(code)) return;
    state = state.copyWith(dataLanguage: code, dataLanguageSeeded: true);
    await SettingsStorage.save(state);
    Logger('app.settings').info('dataLanguage seeded=$code');
  }
```

> `Logger` is already imported in this file (used by `setMaskUidInUi`). If not, add `import 'package:logging/logging.dart';`.

Add the derived provider (next to `localeProvider`):

```dart
/// 當前資料語言代碼（null = 未設定／停用轉換）。
final dataLanguageProvider = Provider<String?>(
  (ref) => ref.watch(settingsProvider.select((s) => s.dataLanguage)),
);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `fvm flutter test test/state/settings_data_language_test.dart`
Expected: PASS.

- [ ] **Step 5: Format, analyze, full test, commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/state/settings.dart test/state/settings_data_language_test.dart
git commit -m "feat(settings): data-language setter, seeder, provider"
```

---

## Task 5: `LangCatalog` model + `LangCatalogStorage`

Persistent per-language catalog (`resourceId → {name, kind}`) with a derived `name → id` reverse map (cross-id-ambiguous names excluded) for backfill. JSON file per language, atomic write.

**Files:**
- Create: `lib/services/lang_catalog_storage.dart`
- Test: `test/services/lang_catalog_storage_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/services/lang_catalog_storage_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('langcat'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('idByName excludes names that map to multiple ids', () {
    final c = LangCatalog(
      lang: 'en',
      fetchedAt: DateTime.utc(2026),
      byId: {
        1: (name: 'Solo', kind: kItemKindCharacter),
        2: (name: 'Dup', kind: kItemKindCharacter),
        3: (name: 'Dup', kind: kItemKindWeapon),
      },
    );
    expect(c.idByName['Solo'], 1);
    expect(c.idByName.containsKey('Dup'), isFalse);
  });

  test('fromEncore flattens nameByKindId', () {
    const enc = EncoreCatalog(
      iconByKindId: {},
      nameByKindId: {
        kItemKindCharacter: {1304: 'Jinhsi'},
        kItemKindWeapon: {21010011: 'Sword'},
      },
    );
    final c = LangCatalog.fromEncore(
      lang: 'en', fetchedAt: DateTime.utc(2026), catalog: enc,
    );
    expect(c.byId[1304]!.name, 'Jinhsi');
    expect(c.byId[1304]!.kind, kItemKindCharacter);
    expect(c.byId[21010011]!.kind, kItemKindWeapon);
  });

  test('save/load round-trip', () async {
    final storage = LangCatalogStorage(dir);
    final c = LangCatalog(
      lang: 'ja', fetchedAt: DateTime.utc(2026, 6, 16),
      byId: {1304: (name: '今汐', kind: kItemKindCharacter)},
    );
    await storage.save(c);
    final loaded = await storage.load('ja');
    expect(loaded, isNotNull);
    expect(loaded!.byId[1304]!.name, '今汐');
    expect(loaded.byId[1304]!.kind, kItemKindCharacter);
    expect(loaded.idByName['今汐'], 1304);
  });

  test('load missing returns null', () async {
    expect(await LangCatalogStorage(dir).load('ko'), isNull);
  });

  test('load corrupt returns null', () async {
    File('${dir.path}/lang_catalog/fr.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{ not json');
    expect(await LangCatalogStorage(dir).load('fr'), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/services/lang_catalog_storage_test.dart`
Expected: FAIL — file/symbols not found.

- [ ] **Step 3: Create the model + storage**

```dart
// lib/services/lang_catalog_storage.dart
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';

/// 單一語言的物品目錄：`resourceId → (name, kind)`，並附 `name → id` 反查表
/// （供第三方匯入合成 ID 回查；跨 id 同名者剔除）。
class LangCatalog {
  /// 建立 [LangCatalog]；[idByName] 由 [byId] 推導。
  LangCatalog({
    required this.lang,
    required this.fetchedAt,
    required this.byId,
  }) : idByName = _idByNameFrom(byId);

  /// 語言代碼（encore 對齊）。
  final String lang;

  /// 抓取時間（UTC）。
  final DateTime fetchedAt;

  /// `resourceId → (name, kind)`。
  final Map<int, ({String name, String kind})> byId;

  /// `name → resourceId`；同名對到不同 id 者剔除（無法判定歸屬）。
  final Map<String, int> idByName;

  /// 由 [byId] 推導 `name → id`，剔除對到多個 id 的同名。
  static Map<String, int> _idByNameFrom(
    Map<int, ({String name, String kind})> byId,
  ) {
    final out = <String, int>{};
    final ambiguous = <String>{};
    byId.forEach((id, v) {
      if (ambiguous.contains(v.name)) return;
      final existing = out[v.name];
      if (existing == null) {
        out[v.name] = id;
      } else if (existing != id) {
        out.remove(v.name);
        ambiguous.add(v.name);
      }
    });
    return out;
  }

  /// 由 [EncoreCatalog] 的 `nameByKindId` 攤平建立。
  factory LangCatalog.fromEncore({
    required String lang,
    required DateTime fetchedAt,
    required EncoreCatalog catalog,
  }) {
    final byId = <int, ({String name, String kind})>{};
    catalog.nameByKindId.forEach((kind, m) {
      m.forEach((id, name) {
        byId.putIfAbsent(id, () => (name: name, kind: kind));
      });
    });
    return LangCatalog(lang: lang, fetchedAt: fetchedAt, byId: byId);
  }

  /// 由 storage JSON 還原。
  factory LangCatalog.fromJson(Map<String, dynamic> json) {
    final items = (json['items'] as Map<String, dynamic>?) ?? const {};
    final byId = <int, ({String name, String kind})>{};
    items.forEach((k, v) {
      final id = int.tryParse(k);
      if (id == null || v is! Map<String, dynamic>) return;
      final name = v['name'] as String?;
      final kind = v['kind'] as String?;
      if (name == null || kind == null) return;
      byId[id] = (name: name, kind: kind);
    });
    return LangCatalog(
      lang: json['lang'] as String,
      fetchedAt: DateTime.parse(json['fetched_at'] as String),
      byId: byId,
    );
  }

  /// 序列化為 storage JSON。
  Map<String, dynamic> toJson() => {
    'lang': lang,
    'fetched_at': fetchedAt.toUtc().toIso8601String(),
    'items': byId.map(
      (id, v) => MapEntry('$id', {'name': v.name, 'kind': v.kind}),
    ),
  };
}

/// 負責 `lang_catalog/<lang>.json` 的讀寫（atomic write）。
class LangCatalogStorage {
  /// 建立 [LangCatalogStorage]，需指定資料根目錄 [baseDir]。
  LangCatalogStorage(this.baseDir);

  /// Logger 實例。
  static final _log = Logger('wish.langconvert.catalog');

  /// 資料根目錄（語言目錄寫入其下的 `lang_catalog/` 子目錄）。
  final Directory baseDir;

  /// 回傳 [lang] 對應的目錄檔案路徑。
  File _file(String lang) => File('${baseDir.path}/lang_catalog/$lang.json');

  /// 讀取 [lang] 的目錄；不存在或解析失敗回 null。
  Future<LangCatalog?> load(String lang) async {
    final f = _file(lang);
    if (!await f.exists()) return null;
    try {
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return LangCatalog.fromJson(json);
    } catch (e, st) {
      _log.warning('lang catalog load failed lang=$lang, treat as missing', e, st);
      return null;
    }
  }

  /// 將 [catalog] 原子寫入（`.tmp` + rename）。
  Future<void> save(LangCatalog catalog) async {
    final f = _file(catalog.lang);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(catalog.toJson()));
    await tmp.rename(f.path);
    _log.fine('lang catalog saved lang=${catalog.lang} items=${catalog.byId.length}');
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `fvm flutter test test/services/lang_catalog_storage_test.dart`
Expected: PASS.

- [ ] **Step 5: Format, analyze, full test, commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/services/lang_catalog_storage.dart test/services/lang_catalog_storage_test.dart
git commit -m "feat(langcat): add LangCatalog model and per-language storage"
```

---

## Task 6: `LangCatalogService.ensure` + provider

Resolve a language's catalog: load from disk; on miss, `fetchCatalog` all three kinds → build → persist. In-memory memo avoids repeated disk reads within one run.

**Files:**
- Create: `lib/services/lang_catalog_service.dart`
- Create: `lib/state/lang_catalog.dart` (provider)
- Test: `test/services/lang_catalog_service_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/services/lang_catalog_service_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('langsvc'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('miss => fetch + persist; second call hits disk, no extra fetch', () async {
    var fetchCount = 0;
    http.Client makeClient() => MockClient((req) async {
      fetchCount++;
      // encore list endpoint .../{lang}/{seg}
      if (req.url.path.endsWith('/character')) {
        return http.Response(
          '{"roleList":[{"Id":1304,"Name":"Jinhsi","RoleHeadIcon":"u"}]}', 200,
        );
      }
      return http.Response('{}', 200);
    });
    final svc = LangCatalogService(
      storage: LangCatalogStorage(dir),
      fetcher: ItemImageFetcher(),
      clientFactory: makeClient,
    );
    final c1 = await svc.ensure('en');
    expect(c1.byId[1304]!.name, 'Jinhsi');
    final after = fetchCount;

    // new service instance (fresh memo) => should read persisted file, not fetch
    final svc2 = LangCatalogService(
      storage: LangCatalogStorage(dir),
      fetcher: ItemImageFetcher(),
      clientFactory: () => MockClient((_) async {
        fail('should not fetch when cached on disk');
      }),
    );
    final c2 = await svc2.ensure('en');
    expect(c2.byId[1304]!.name, 'Jinhsi');
    expect(fetchCount, after); // unchanged
  });
}
```

> Adjust the mock if `ItemImageFetcher` needs a base-URL override; check `_encoreApiBase` in `item_image_fetcher.dart`. If the fetcher hard-codes the host, the `MockClient` still intercepts because `http.Client.get` is routed through the injected client. Keep the response keys (`roleList`/`Name`/`RoleHeadIcon`) matching `_fetchCatalogKind`.

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/services/lang_catalog_service_test.dart`
Expected: FAIL — file/symbols not found.

- [ ] **Step 3: Create service + provider**

```dart
// lib/services/lang_catalog_service.dart
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';

/// 解析某語言的物品目錄：先讀本地快取，缺則抓 encore 三清單、建檔、回傳。
/// 同一實例以記憶體 memo 避免單次轉換內重複讀檔／抓取。
class LangCatalogService {
  /// 建立 [LangCatalogService]。
  LangCatalogService({
    required this.storage,
    required this.fetcher,
    required this.clientFactory,
  });

  /// Logger 實例。
  static final _log = Logger('wish.langconvert.catalog');

  /// 目錄持久化。
  final LangCatalogStorage storage;

  /// encore 抓取器。
  final ItemImageFetcher fetcher;

  /// 建立 http client 的工廠（每次抓取用後即關）。
  final http.Client Function() clientFactory;

  /// 單次執行的記憶體快取。
  final Map<String, LangCatalog> _memo = {};

  /// 抓三清單時用的 kind 集合。
  static const _allKinds = {
    kItemKindCharacter,
    kItemKindWeapon,
    kItemKindItem,
  };

  /// 取得 [lang] 目錄：memo → 本地 → 抓取並落地。網路失敗時拋出（呼叫端決定如何處理）。
  Future<LangCatalog> ensure(String lang) async {
    final memo = _memo[lang];
    if (memo != null) return memo;

    final cached = await storage.load(lang);
    if (cached != null) {
      _memo[lang] = cached;
      _log.fine('lang catalog from disk lang=$lang');
      return cached;
    }

    final client = clientFactory();
    try {
      final catalog = await fetcher.fetchCatalog(
        lang: lang,
        kinds: _allKinds,
        client: client,
      );
      final lc = LangCatalog.fromEncore(
        lang: lang,
        fetchedAt: DateTime.now().toUtc(),
        catalog: catalog,
      );
      await storage.save(lc);
      _memo[lang] = lc;
      _log.info('lang catalog fetched lang=$lang items=${lc.byId.length}');
      return lc;
    } finally {
      client.close();
    }
  }
}
```

```dart
// lib/state/lang_catalog.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';

/// 提供建構好的 [LangCatalogService]（注入 storage、fetcher、client 工廠）。
final langCatalogServiceProvider = Provider<LangCatalogService>((ref) {
  final cacheDir = ref.watch(itemImageCacheDirProvider);
  final fetcher = ref.watch(itemImageFetcherProvider);
  return LangCatalogService(
    storage: LangCatalogStorage(cacheDir),
    fetcher: fetcher,
    clientFactory: http.Client.new,
  );
});
```

> Verify `itemImageFetcherProvider` lives in `lib/state/item_image_index.dart` (it is read there as `ref.read(itemImageFetcherProvider)` in `_fetchItemImages`). If it is defined elsewhere, fix the import. `itemImageCacheDirProvider` is in `lib/state/item_image_index.dart`. The `gacha_repository.dart` import is only needed if a symbol is referenced; remove it if unused to satisfy analyze.

- [ ] **Step 4: Run test to verify it passes**

Run: `fvm flutter test test/services/lang_catalog_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Format, analyze, full test, commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/services/lang_catalog_service.dart lib/state/lang_catalog.dart test/services/lang_catalog_service_test.dart
git commit -m "feat(langcat): ensure() service with disk cache + provider"
```

---

## Task 7: `GachaRecord.copyWith` + `GachaLanguageConverter`

The converter mutates only `name`, `resourceId` (backfill), and `languageCode`. Pure & testable via an injected `ensureCatalog` resolver.

**Files:**
- Modify: `lib/models/gacha_record.dart` (add `copyWith`)
- Create: `lib/services/gacha_language_converter.dart`
- Test: `test/services/gacha_language_converter_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/services/gacha_language_converter_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';

GachaRecord rec({
  required int id,
  required String name,
  required String lang,
  String type = '角色',
}) => GachaRecord(
  resourceId: id, qualityLevel: 5, resourceType: type, cardPoolType: '1',
  name: name, count: 1, time: DateTime.utc(2026, 1, 1), languageCode: lang,
);

BannerStorage store(List<GachaRecord> records) => BannerStorage(
  playerId: 'p1', languageCode: 'zh-Hant',
  lastUpdated: DateTime.utc(2026, 1, 1), banners: {'1': records},
);

LangCatalog cat(String lang, Map<int, ({String name, String kind})> byId) =>
    LangCatalog(lang: lang, fetchedAt: DateTime.utc(2026), byId: byId);

void main() {
  test('direct id mapping converts name + languageCode, keeps resourceType', () async {
    final catalogs = {
      'ja': cat('ja', {1304: (name: '今汐', kind: kItemKindCharacter)}),
    };
    final conv = GachaLanguageConverter(
      ensureCatalog: (l) async => catalogs[l]!,
    );
    final out = await conv.convert(
      store([rec(id: 1304, name: 'Jinhsi', lang: 'en')]),
      'ja',
    );
    final r = out.data.banners['1']!.single;
    expect(r.name, '今汐');
    expect(r.languageCode, 'ja');
    expect(r.resourceType, '角色'); // untouched
    expect(out.result.converted, 1);
    expect(out.result.unresolved, 0);
  });

  test('synthetic id backfilled via source-name lookup', () async {
    final catalogs = {
      'ja': cat('ja', {1304: (name: '今汐', kind: kItemKindCharacter)}),
      'en': cat('en', {1304: (name: 'Jinhsi', kind: kItemKindCharacter)}),
    };
    final conv = GachaLanguageConverter(
      ensureCatalog: (l) async => catalogs[l]!,
    );
    final out = await conv.convert(
      store([rec(id: -42, name: 'Jinhsi', lang: 'en')]),
      'ja',
    );
    final r = out.data.banners['1']!.single;
    expect(r.resourceId, 1304); // adopted real id
    expect(r.name, '今汐');
    expect(r.languageCode, 'ja');
    expect(out.result.backfilledId, 1);
    expect(out.result.converted, 1);
  });

  test('unresolved record left fully untouched', () async {
    final catalogs = {
      'ja': cat('ja', const {}),
      'en': cat('en', const {}),
    };
    final conv = GachaLanguageConverter(
      ensureCatalog: (l) async => catalogs[l]!,
    );
    final original = rec(id: -7, name: 'Mystery', lang: 'en');
    final out = await conv.convert(store([original]), 'ja');
    final r = out.data.banners['1']!.single;
    expect(r.resourceId, -7);
    expect(r.name, 'Mystery');
    expect(r.languageCode, 'en');
    expect(out.result.unresolved, 1);
    expect(out.result.converted, 0);
  });

  test('LangConvertResult sums', () {
    const a = LangConvertResult(total: 1, converted: 1);
    const b = LangConvertResult(total: 1, unresolved: 1);
    final c = a + b;
    expect(c.total, 2);
    expect(c.converted, 1);
    expect(c.unresolved, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/services/gacha_language_converter_test.dart`
Expected: FAIL — `copyWith` / converter symbols not found.

- [ ] **Step 3a: Add `copyWith` to `GachaRecord`**

In `lib/models/gacha_record.dart`, after `toStorageJson()`:

```dart
  /// 複製並選擇性覆蓋欄位（資料語言轉換用：改 name／resourceId／languageCode）。
  GachaRecord copyWith({
    int? resourceId,
    int? qualityLevel,
    String? resourceType,
    String? cardPoolType,
    String? name,
    int? count,
    DateTime? time,
    String? languageCode,
  }) => GachaRecord(
    resourceId: resourceId ?? this.resourceId,
    qualityLevel: qualityLevel ?? this.qualityLevel,
    resourceType: resourceType ?? this.resourceType,
    cardPoolType: cardPoolType ?? this.cardPoolType,
    name: name ?? this.name,
    count: count ?? this.count,
    time: time ?? this.time,
    languageCode: languageCode ?? this.languageCode,
  );
```

- [ ] **Step 3b: Create the converter**

```dart
// lib/services/gacha_language_converter.dart
import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 轉換結果計數（可相加聚合多帳號）。
class LangConvertResult {
  /// 建立 [LangConvertResult]。
  const LangConvertResult({
    this.total = 0,
    this.converted = 0,
    this.backfilledId = 0,
    this.unresolved = 0,
  });

  /// 處理總筆數。
  final int total;

  /// 成功轉換筆數（含回查補 ID）。
  final int converted;

  /// 其中靠名稱回查補上真實 ID 的筆數。
  final int backfilledId;

  /// 無法轉換、保持原狀的筆數。
  final int unresolved;

  /// 逐項相加。
  LangConvertResult operator +(LangConvertResult o) => LangConvertResult(
    total: total + o.total,
    converted: converted + o.converted,
    backfilledId: backfilledId + o.backfilledId,
    unresolved: unresolved + o.unresolved,
  );
}

/// 把一份 [BannerStorage] 的紀錄名稱統一成目標語言。
///
/// 只改 `name`／`resourceId`（回查補）／`languageCode`，不動 `resourceType`
/// （類型標籤跟 UI 語言，見 spec D8）。轉不了的紀錄完全保持原狀。
class GachaLanguageConverter {
  /// 建立 [GachaLanguageConverter]；[ensureCatalog] 取得某語言目錄（生產環境接
  /// `LangCatalogService.ensure`，測試注入 fake）。
  GachaLanguageConverter({required this.ensureCatalog});

  /// Logger 實例。
  static final _log = Logger('wish.langconvert');

  /// 取得某語言目錄的解析器。
  final Future<LangCatalog> Function(String lang) ensureCatalog;

  /// 轉換 [data] 為 [targetLang]，回傳新的存檔與計數摘要。
  Future<({BannerStorage data, LangConvertResult result})> convert(
    BannerStorage data,
    String targetLang,
  ) async {
    final targetCat = await ensureCatalog(targetLang);

    // 蒐集需回查的紀錄之原語言（合成／負值 id，或目標目錄查無 id）。
    final srcLangs = <String>{};
    for (final list in data.banners.values) {
      for (final r in list) {
        final needsBackfill =
            r.resourceId <= 0 || !targetCat.byId.containsKey(r.resourceId);
        if (needsBackfill && r.languageCode.isNotEmpty) {
          srcLangs.add(r.languageCode);
        }
      }
    }
    final srcCats = <String, LangCatalog>{};
    for (final lang in srcLangs) {
      srcCats[lang] = await ensureCatalog(lang);
    }

    var result = const LangConvertResult();
    final newBanners = <String, List<GachaRecord>>{};
    data.banners.forEach((key, list) {
      final out = <GachaRecord>[];
      for (final r in list) {
        result = result + const LangConvertResult(total: 1);

        // 直接以 resourceId 對應目標名。
        final direct =
            r.resourceId > 0 ? targetCat.byId[r.resourceId] : null;
        if (direct != null) {
          out.add(r.copyWith(name: direct.name, languageCode: targetLang));
          result = result + const LangConvertResult(converted: 1);
          continue;
        }

        // 以原名 + 原語言回查真實 id，再以目標目錄轉名。
        final realId = srcCats[r.languageCode]?.idByName[r.name];
        final viaBackfill =
            realId != null ? targetCat.byId[realId] : null;
        if (realId != null && viaBackfill != null) {
          out.add(
            r.copyWith(
              resourceId: realId,
              name: viaBackfill.name,
              languageCode: targetLang,
            ),
          );
          result = result +
              const LangConvertResult(converted: 1, backfilledId: 1);
          continue;
        }

        // 轉不了：完全保持原狀。
        out.add(r);
        result = result + const LangConvertResult(unresolved: 1);
      }
      newBanners[key] = out;
    });

    _log.info(
      'converted playerId=${sanitizeUid(data.playerId)} target=$targetLang '
      'total=${result.total} converted=${result.converted} '
      'backfilledId=${result.backfilledId} unresolved=${result.unresolved}',
    );
    return (data: data.copyWith(banners: newBanners), result: result);
  }
}
```

> `sanitizeUid` lives in `lib/services/log_sanitize.dart` (confirmed) — the import above is correct.

- [ ] **Step 4: Run test to verify it passes**

Run: `fvm flutter test test/services/gacha_language_converter_test.dart`
Expected: PASS.

- [ ] **Step 5: Format, analyze, full test, commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/models/gacha_record.dart lib/services/gacha_language_converter.dart test/services/gacha_language_converter_test.dart
git commit -m "feat(langconvert): add GachaLanguageConverter and GachaRecord.copyWith"
```

---

## Task 8: Repository — converter provider + convert one account helper

A provider for `GachaLanguageConverter` wired to `LangCatalogService`, plus a repository helper `_convertAccountToDataLanguage(data)` returning converted data (or original when data language is unset / conversion fails). This helper is reused by update, import, and unify.

**Files:**
- Create: `lib/state/gacha_language_converter.dart` (provider)
- Modify: `lib/state/gacha_repository.dart` (add helper method + import)
- Test: `test/state/gacha_language_converter_provider_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/state/gacha_language_converter_provider_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/lang_catalog.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'dart:io';

void main() {
  test('gachaLanguageConverterProvider builds a converter', () {
    final dir = Directory.systemTemp.createTempSync('conv');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c = ProviderContainer(
      overrides: [itemImageCacheDirProvider.overrideWithValue(dir)],
    );
    addTearDown(c.dispose);
    final conv = c.read(gachaLanguageConverterProvider);
    expect(conv, isA<GachaLanguageConverter>());
    // ensure the lang catalog service provider resolves too
    expect(c.read(langCatalogServiceProvider), isNotNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/state/gacha_language_converter_provider_test.dart`
Expected: FAIL — provider not defined.

- [ ] **Step 3a: Create the provider**

```dart
// lib/state/gacha_language_converter.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/lang_catalog.dart';

/// 提供 [GachaLanguageConverter]，其 `ensureCatalog` 接 [langCatalogServiceProvider]。
final gachaLanguageConverterProvider = Provider<GachaLanguageConverter>((ref) {
  final service = ref.watch(langCatalogServiceProvider);
  return GachaLanguageConverter(ensureCatalog: service.ensure);
});
```

- [ ] **Step 3b: Add the repository helper**

In `lib/state/gacha_repository.dart`, add imports:

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_language_converter.dart';
```

Add a private method to the repository notifier class (near `_fetchItemImages`):

```dart
  /// 若已設定資料語言，將 [data] 轉成該語言後回傳；未設定或轉換失敗則回原樣。
  ///
  /// 轉換失敗（如 catalog 補抓網路錯）不可中斷更新／匯入：吞例外、記 warning、
  /// 回傳未轉資料（D11）。
  Future<BannerStorage> _convertAccountToDataLanguage(BannerStorage data) async {
    final target = ref.read(dataLanguageProvider);
    if (target == null) return data;
    try {
      final converter = ref.read(gachaLanguageConverterProvider);
      final out = await converter.convert(data, target);
      return out.data;
    } catch (e, st) {
      Logger('wish.langconvert').warning(
        'convert failed for playerId=${sanitizeUid(data.playerId)} '
        'target=$target, keeping original data',
        e,
        st,
      );
      return data;
    }
  }
```

> Ensure `dataLanguageProvider` is imported (`package:.../state/settings.dart`). `Logger`, `sanitizeUid` are already used in this file.

- [ ] **Step 4: Run test to verify it passes**

Run: `fvm flutter test test/state/gacha_language_converter_provider_test.dart`
Expected: PASS.

- [ ] **Step 5: Format, analyze, full test, commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/state/gacha_language_converter.dart lib/state/gacha_repository.dart test/state/gacha_language_converter_provider_test.dart
git commit -m "feat(repo): converter provider + per-account convert helper"
```

---

## Task 9: Hook conversion + seeding into `update()`

After fetch/merge, convert the new `BannerStorage` before saving; then seed the data language if still unset.

**Files:**
- Modify: `lib/state/gacha_repository.dart` (`_fetchAllBanners` save block ~463-472)
- Test: `test/state/update_converts_data_language_test.dart` (integration-style; if the existing repo test harness is heavy, assert via the helper as a focused unit — see note)

- [ ] **Step 1: Write the failing test**

> The full `update()` path needs MITM/fetcher fakes. Prefer a focused test that the save block calls the convert helper and the seeder. If the repo already has a test harness (look in `test/state/` for existing `gacha_repository` tests and reuse their fakes), extend it. Minimal behavioral test below asserts seeding happens after a save when unset, using the existing repo test seam if present; otherwise mark this test `skip` with a TODO referencing the harness and rely on Task 8's helper test + the seam assertions in Step 3.

```dart
// test/state/update_converts_data_language_test.dart
// Reuse the existing gacha_repository test harness (fakes for fetcher + storage).
// Assert: after a successful update with dataLanguage unset, the captured
// language seeds settings.dataLanguage (when in the 9 options); and when
// dataLanguage is preset, the saved BannerStorage names are converted.
//
// Implement against the harness found in test/state/. If no harness exists,
// keep this file with a single `test('seeded after update', () {}, skip: 'needs repo harness')`
// and cover seeding via Task 8 + manual verification.
```

- [ ] **Step 2: Run test to verify current behavior**

Run: `fvm flutter test test/state/update_converts_data_language_test.dart`
Expected: FAIL (or skip) before wiring.

- [ ] **Step 3: Wire convert + seed into the save block**

In `_fetchAllBanners`, change the save block (currently builds `newData`, calls `storage.save(newData)`):

```dart
    final updatedAt = DateTime.now().toUtc();
    var newData = BannerStorage(
      playerId: playerId,
      languageCode: cred.languageCode,
      lastUpdated: updatedAt,
      banners: mergedBanners,
    );
    // 資料語言轉換（已設定時）：轉失敗回原樣，不中斷更新（D11）。
    newData = await _convertAccountToDataLanguage(newData);
    await storage.save(newData);
    if (!ref.mounted) return;
    await storage.saveCapturedCredential(playerId, cred.toJsonString());
    if (!ref.mounted) return;

    final newByUid = Map<String, BannerStorage>.from(state.byUid)
      ..[playerId] = newData;
    _log.info(
      'update completed: playerId=${sanitizeUid(playerId)} totalNew=$totalNew',
    );
    state = state.copyWith(byUid: newByUid, activeUid: playerId);
    if (!ref.mounted) return;
    await ref.read(settingsProvider.notifier).setLastActiveUid(playerId);
    // 首次更新自動播種資料語言（以本次擷取語言；落在 9 選項外則 no-op）。
    await ref
        .read(settingsProvider.notifier)
        .seedDataLanguageIfUnset(cred.languageCode);
```

> `mergedBanners`, `playerId`, `cred`, `totalNew` are the existing locals in this block (see repository lines 463-482). Only the two added lines (`_convertAccountToDataLanguage` reassignment and `seedDataLanguageIfUnset`) are new; `newData` becomes `var`.

- [ ] **Step 4: Run test / full suite**

Run: `fvm flutter test`
Expected: existing tests pass; new test passes or remains intentionally skipped per Step 1 note.

- [ ] **Step 5: Format, analyze, commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/state/gacha_repository.dart test/state/update_converts_data_language_test.dart
git commit -m "feat(repo): convert + seed data language on update"
```

---

## Task 10: Hook conversion + seeding into import

Convert each imported account before saving; seed from the imported account's language after import.

**Files:**
- Modify: `lib/state/gacha_repository.dart` (`_runImport` per-account save ~742-767, post-import settings ~800-818)
- Test: extend `test/state/` import coverage if a harness exists (same note as Task 9)

- [ ] **Step 1: Write/extend the failing test**

> Same harness caveat as Task 9. If `_runImport` is unit-testable via existing fakes, assert: imported account with `dataLanguage='ja'` preset has its saved names converted; and with unset, `dataLanguageSeeded` becomes true using the imported account's language. Otherwise keep a `skip` placeholder and rely on Task 7/8 unit coverage.

- [ ] **Step 2: Run test**

Run: `fvm flutter test test/state/`
Expected: FAIL or skip before wiring.

- [ ] **Step 3: Wire convert into the per-account save**

In `_runImport`, where it computes `toSave` then `await storage.save(toSave)` (line ~748-749):

```dart
      var toSave = localBefore == null ? incoming : localBefore.mergeWith(incoming);
      toSave = await _convertAccountToDataLanguage(toSave);
      await storage.save(toSave);
```

> Also use the converted `toSave` when building the new `byUid` state map in this loop (replace the variable that goes into `state.byUid`), so in-memory state matches disk. Match the existing local-name used after `storage.save` (the block puts the saved storage into the updated `byUid`).

After the loop, where post-import settings are applied (~800-818), seed from the bundle's last-active account language. Add after the existing `applyImportedPreferences` / settings update:

```dart
    // 首次匯入自動播種資料語言：取 bundle 中最新 last_updated 帳號的語言。
    final seedLang = _latestLanguageOf(
      bundle.accounts.map((a) => a.data),
    );
    if (seedLang != null) {
      await ref
          .read(settingsProvider.notifier)
          .seedDataLanguageIfUnset(seedLang);
    }
```

Add a small private helper to the class:

```dart
  /// 回傳 [stores] 中 `lastUpdated` 最新者的帳號級語言；空集合回 null。
  String? _latestLanguageOf(Iterable<BannerStorage> stores) {
    BannerStorage? latest;
    for (final s in stores) {
      if (latest == null || s.lastUpdated.isAfter(latest.lastUpdated)) {
        latest = s;
      }
    }
    return latest?.languageCode;
  }
```

> Confirm `AccountsBundle.accounts` element exposes `.data` (BannerStorage) — the importer returns `ExportedAccount(data: storage)`. Adjust `a.data` if the field name differs.

- [ ] **Step 4: Run full suite**

Run: `fvm flutter test`
Expected: pass (or intended skip).

- [ ] **Step 5: Format, analyze, commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/state/gacha_repository.dart test/state/
git commit -m "feat(repo): convert + seed data language on import"
```

---

## Task 11: Bootstrap seeding + unify-all method

Seed the data language at bootstrap from existing accounts (latest `last_updated`), and add `unifyDataLanguage()` that converts all known accounts to the configured language, saves them, refreshes state + images, and returns an aggregate result.

**Files:**
- Modify: `lib/state/gacha_repository.dart` (bootstrap method; add public `unifyDataLanguage`)
- Test: `test/state/unify_data_language_test.dart` (harness-dependent; seeding helper is unit-testable)

- [ ] **Step 1: Write the failing test**

```dart
// test/state/unify_data_language_test.dart
// With the repo test harness: seed two accounts with different last_updated,
// assert bootstrap seeds dataLanguage to the newer account's language.
// Then set dataLanguage='ja' and call unifyDataLanguage(); assert each saved
// account's records are converted (names from the fake catalog) and the
// returned LangConvertResult totals match. If no harness exists, cover the
// `_latestLanguageOf` helper directly and keep the rest skipped.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder until harness wired', () {}, skip: 'needs repo harness');
}
```

- [ ] **Step 2: Run test**

Run: `fvm flutter test test/state/unify_data_language_test.dart`
Expected: skip/pass.

- [ ] **Step 3a: Seed at bootstrap**

Locate the repository bootstrap method (the one that populates `state.byUid` from disk on startup — search for `listKnownUids` / `_bootstrapLoad`). After `state` is populated with all loaded accounts and after `settingsProvider` is ready, add:

```dart
    // Bootstrap 自動播種：取既有帳號中 last_updated 最新者的語言（落在 9 選項內才播）。
    final seedLang = _latestLanguageOf(state.byUid.values);
    if (seedLang != null) {
      await ref
          .read(settingsProvider.notifier)
          .seedDataLanguageIfUnset(seedLang);
    }
```

> If bootstrap awaits `settingsProvider.notifier.waitForLoad()` already (it reads `lastActiveUid`), place the seed call after that await so `dataLanguageSeeded` reflects persisted state.

- [ ] **Step 3b: Add `unifyDataLanguage()`**

Add a public method to the repository notifier:

```dart
  /// 將所有已知帳號的資料統一成目前設定的資料語言，存檔並刷新 state 與圖片。
  ///
  /// 未設定資料語言時直接回零結果（呼叫端按鈕應已禁用）。逐帳號轉換，單一帳號
  /// 轉換失敗（吞例外於 [_convertAccountToDataLanguage]）回原樣、不中斷其他帳號。
  Future<LangConvertResult> unifyDataLanguage() async {
    final target = ref.read(dataLanguageProvider);
    if (target == null) return const LangConvertResult();

    final converter = ref.read(gachaLanguageConverterProvider);
    var agg = const LangConvertResult();
    final newByUid = Map<String, BannerStorage>.from(state.byUid);
    for (final entry in state.byUid.entries) {
      try {
        final out = await converter.convert(entry.value, target);
        await storage.save(out.data);
        newByUid[entry.key] = out.data;
        agg = agg + out.result;
      } catch (e, st) {
        Logger('wish.langconvert').warning(
          'unify skip playerId=${sanitizeUid(entry.key)} target=$target',
          e,
          st,
        );
      }
      if (!ref.mounted) return agg;
    }
    state = state.copyWith(byUid: newByUid);
    if (!ref.mounted) return agg;
    // 補抓目標語言的 icon／詳情（backfill 的真實 id 也順帶補圖）。
    await _fetchItemImages(http.Client());
    _log.info(
      'unifyDataLanguage target=$target total=${agg.total} '
      'converted=${agg.converted} backfilledId=${agg.backfilledId} '
      'unresolved=${agg.unresolved}',
    );
    return agg;
  }
```

> Resolve `storage` the same way other repo methods do (the class field / `ref.read`). `_fetchItemImages` takes an `http.Client`; use a fresh `http.Client()` (the method closes/handles it like other call sites — verify how existing callers pass the client; reuse that pattern, e.g. a cancellable client if that's the convention). Import `package:http/http.dart` as `http` if not already.

- [ ] **Step 4: Run full suite**

Run: `fvm flutter test`
Expected: pass.

- [ ] **Step 5: Format, analyze, commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/state/gacha_repository.dart test/state/unify_data_language_test.dart
git commit -m "feat(repo): bootstrap seeding + unifyDataLanguage()"
```

---

## Task 12: ARB strings for the data-language section

Add UI strings to the four core ARB files (template `app_zh.arb` + `app_en.arb`, `app_zh_Hans.arb`, `app_ja.arb`). Other locales are Crowdin-managed and fall back to the template until translated.

**Files:**
- Modify: `lib/l10n/app_zh.arb` (template), `lib/l10n/app_en.arb`, `lib/l10n/app_zh_Hans.arb`, `lib/l10n/app_ja.arb`
- Generate: `lib/l10n/generated/` (via `gen-l10n`)

- [ ] **Step 1: Add keys to the template `app_zh.arb`**

Insert near the language section (after `settingsLocaleSystem`):

```json
  "settingsDataLanguage": "資料語言",
  "settingsDataLanguageDesc": "統一卡池歷史資料的顯示語言，獨立於應用程式介面語言。設定後更新或匯入資料會自動轉換成此語言。",
  "settingsDataLanguageUnset": "未設定（不轉換）",
  "settingsDataLanguageUnify": "統一資料語言",
  "settingsDataLanguageUnifying": "轉換中...",
  "settingsDataLanguageUnifyDone": "已轉換 {converted} 筆，回查補 ID {backfilled} 筆，{unresolved} 筆無法轉換。",
  "@settingsDataLanguageUnifyDone": {
    "placeholders": {
      "converted": { "type": "int" },
      "backfilled": { "type": "int" },
      "unresolved": { "type": "int" }
    }
  },
  "settingsDataLanguageUnifyFailed": "轉換失敗，資料未變更。請檢查網路後重試。"
```

- [ ] **Step 2: Add the same keys to `app_en.arb`**

```json
  "settingsDataLanguage": "Data language",
  "settingsDataLanguageDesc": "Unify the display language of your gacha history, independent of the app interface language. Once set, updating or importing data converts it to this language.",
  "settingsDataLanguageUnset": "Not set (no conversion)",
  "settingsDataLanguageUnify": "Unify data language",
  "settingsDataLanguageUnifying": "Converting...",
  "settingsDataLanguageUnifyDone": "Converted {converted}, recovered {backfilled} IDs, {unresolved} could not be converted.",
  "@settingsDataLanguageUnifyDone": {
    "placeholders": {
      "converted": { "type": "int" },
      "backfilled": { "type": "int" },
      "unresolved": { "type": "int" }
    }
  },
  "settingsDataLanguageUnifyFailed": "Conversion failed; data unchanged. Check your connection and try again."
```

- [ ] **Step 3: Add the same keys to `app_zh_Hans.arb`**

```json
  "settingsDataLanguage": "数据语言",
  "settingsDataLanguageDesc": "统一卡池历史数据的显示语言，独立于应用程序界面语言。设定后更新或导入数据会自动转换成此语言。",
  "settingsDataLanguageUnset": "未设定（不转换）",
  "settingsDataLanguageUnify": "统一数据语言",
  "settingsDataLanguageUnifying": "转换中...",
  "settingsDataLanguageUnifyDone": "已转换 {converted} 笔，回查补 ID {backfilled} 笔，{unresolved} 笔无法转换。",
  "@settingsDataLanguageUnifyDone": {
    "placeholders": {
      "converted": { "type": "int" },
      "backfilled": { "type": "int" },
      "unresolved": { "type": "int" }
    }
  },
  "settingsDataLanguageUnifyFailed": "转换失败，数据未变更。请检查网络后重试。"
```

- [ ] **Step 4: Add the same keys to `app_ja.arb`**

```json
  "settingsDataLanguage": "データ言語",
  "settingsDataLanguageDesc": "アプリのインターフェース言語とは独立して、ガチャ履歴の表示言語を統一します。設定すると、データの更新やインポート時にこの言語へ変換されます。",
  "settingsDataLanguageUnset": "未設定（変換しない）",
  "settingsDataLanguageUnify": "データ言語を統一",
  "settingsDataLanguageUnifying": "変換中...",
  "settingsDataLanguageUnifyDone": "{converted} 件を変換、{backfilled} 件のIDを補完、{unresolved} 件は変換できませんでした。",
  "@settingsDataLanguageUnifyDone": {
    "placeholders": {
      "converted": { "type": "int" },
      "backfilled": { "type": "int" },
      "unresolved": { "type": "int" }
    }
  },
  "settingsDataLanguageUnifyFailed": "変換に失敗しました。データは変更されていません。接続を確認して再試行してください。"
```

- [ ] **Step 5: Generate, analyze, commit**

```bash
fvm flutter gen-l10n
fvm flutter analyze
git add lib/l10n/app_zh.arb lib/l10n/app_en.arb lib/l10n/app_zh_Hans.arb lib/l10n/app_ja.arb
git commit -m "feat(l10n): add data-language section strings"
```

> `lib/l10n/generated/` is gitignored — do not stage it.

---

## Task 13: Settings page — data-language section UI

Add a `SectionCard` with the data-language dropdown (`未設定` + 9 native-name options) and the "unify" button with a busy state and a result `AppDialog`.

**Files:**
- Modify: `lib/pages/settings_page.dart` (insert SectionCard ~86-87; add `_DataLanguageSection` widget)
- Test: `test/pages/settings_data_language_section_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// test/pages/settings_data_language_section_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/settings_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows data-language dropdown; unify disabled when unset',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = await AppLocalizations.delegate.load(const Locale('en'));

    // Dropdown for data language present (find by the unset label).
    expect(find.text(l.settingsDataLanguage), findsOneWidget);

    // Unify button is disabled (onPressed == null) when data language unset.
    final unify = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text(l.settingsDataLanguageUnify),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(unify.onPressed, isNull);
  });
}
```

> If `SettingsPage` requires more providers to pump (e.g. `appVersionProvider`), override them in the `ProviderScope` like existing settings-page tests do — copy the override list from any current `test/pages/settings*` test. If none exists, wrap only the new widget `_DataLanguageSection` is not exported; test the public `SettingsPage`. Keep overrides minimal; add only what `pumpAndSettle` demands.

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/pages/settings_data_language_section_test.dart`
Expected: FAIL — strings/section not present.

- [ ] **Step 3: Insert the SectionCard and widget**

In `SettingsPage.build`, insert after the language `SectionCard` (after line ~86, before the `_PrivacySection` card):

```dart
              const SizedBox(height: AppSpacing.xl),
              SectionCard(
                title: l.settingsDataLanguage,
                icon: Icons.translate_outlined,
                child: const _DataLanguageSection(),
              ),
```

Add the widget (place near `_LocaleDropdown`):

```dart
/// 資料語言區塊：選擇資料語言（獨立於 UI 語言）＋「統一資料語言」按鈕。
class _DataLanguageSection extends ConsumerStatefulWidget {
  const _DataLanguageSection();

  @override
  ConsumerState<_DataLanguageSection> createState() =>
      _DataLanguageSectionState();
}

class _DataLanguageSectionState extends ConsumerState<_DataLanguageSection> {
  bool _busy = false;

  Future<void> _unify(AppLocalizations l) async {
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(gachaRepositoryProvider.notifier)
          .unifyDataLanguage();
      if (!mounted) return;
      await _showResultDialog(
        context,
        title: l.settingsDataLanguageUnify,
        body: l.settingsDataLanguageUnifyDone(
          result.converted,
          result.backfilledId,
          result.unresolved,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      await _showResultDialog(
        context,
        title: l.settingsDataLanguageUnify,
        body: l.settingsDataLanguageUnifyFailed,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 以 [AppDialog] 顯示結果／錯誤訊息（含關閉按鈕）。
  Future<void> _showResultDialog(
    BuildContext context, {
    required String title,
    required String body,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AppDialog(
        size: AppDialogSize.sm,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final current = ref.watch(dataLanguageProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.settingsDataLanguageDesc,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.gacha.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.s),
        DropdownButtonFormField<String?>(
          initialValue: current,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(l.settingsDataLanguageUnset),
            ),
            for (final o in kDataLanguageOptions)
              DropdownMenuItem<String?>(value: o.code, child: Text(o.label)),
          ],
          onChanged: _busy ? null : (v) => notifier.setDataLanguage(v),
        ),
        const SizedBox(height: AppSpacing.s),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: (current == null || _busy) ? null : () => _unify(l),
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            label: Text(
              _busy ? l.settingsDataLanguageUnifying : l.settingsDataLanguageUnify,
            ),
          ),
        ),
      ],
    );
  }
}
```

> Imports to add at the top of `settings_page.dart`: `package:.../services/data_language.dart` and `package:.../widgets/dialogs/app_dialog.dart` (for `AppDialog` / `AppDialogSize`). `dataLanguageProvider` comes from the already-imported `state/settings.dart`. **Confirmed facts:** `AppDialog` (`lib/widgets/dialogs/app_dialog.dart`) constructor is `AppDialog({required Widget title, required Widget content, List<Widget> actions = const [], AppDialogSize size = AppDialogSize.sm, bool scrollable = false, double? maxHeight})`; there is **no** `showAppDialog` helper — show it via `showDialog<void>(context:, builder: (ctx) => AppDialog(...))` (as `_showResultDialog` above does, matching `export_result_dialog.dart`). `gachaRepositoryProvider` is `NotifierProvider<GachaRepository, GachaState>` in `lib/state/gacha_repository.dart` (confirmed). `theme.gacha.textSecondary` extension is in scope (used by `_LocaleDropdown`).

- [ ] **Step 4: Run test to verify it passes**

Run: `fvm flutter test test/pages/settings_data_language_section_test.dart`
Expected: PASS.

- [ ] **Step 5: Format, analyze, full test, commit**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/pages/settings_page.dart test/pages/settings_data_language_section_test.dart
git commit -m "feat(settings): data-language section UI with unify button"
```

---

## Task 14: Final verification + memory note

- [ ] **Step 1: Full quality gate**

```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
```

Expected: `No issues found!` and `All tests passed!`.

- [ ] **Step 2: Manual smoke (real app)**

Run the app, open Settings → 資料語言:
- Dropdown shows 未設定 + 9 languages; selecting one persists across restart.
- With a language chosen, "統一資料語言" converts existing records' item names; mixed-language list becomes single-language; unresolved count shown.
- Trigger an update/import in a different game language → records arrive already converted.
- Switch data language away and back → no re-fetch (catalog read from `lang_catalog/<lang>.json`).

> Use the `run` skill / `fvm flutter run -d windows` per project convention.

- [ ] **Step 3: Update memory**

Add a memory file recording: data-language conversion feature shipped — independent of UI locale; 9 encore-aligned codes; tri-state pref (absent/`none`/code) with auto-seed from latest data; `lang_catalog/<lang>.json` persistent cache; converter mutates name+languageCode only (type follows UI locale, detail follows via languageCode); unify button + auto-convert on update/import. Link `[[wuwa-icon-sources]]`, `[[l10n-and-riverpod-facts]]`, `[[per-record-language]]` if present. Add a one-line pointer to `MEMORY.md`.

- [ ] **Step 4: Final commit (if memory/docs changed in-repo only; memory dir is outside repo)**

No repo commit needed for memory (stored outside the repo). Ensure the branch is clean:

```bash
git status
```

---

## Self-Review Notes (author)

- **Spec coverage:** Settings independent of UI locale (Tasks 2-4, 13) ✓; auto-convert on update/import (Tasks 9-10) ✓; unify button (Tasks 11, 13) ✓; local per-language cache no re-fetch (Tasks 5-6) ✓; convert name + detail, type follows UI (Tasks 7, 13; detail via languageCode mutation — no code needed, asserted in spec D9) ✓; default = latest data language + seeding + tri-state + `未設定` kept (Tasks 3-4, 9-11) ✓; backfill synthetic IDs by name (Task 7) ✓; failure never destroys data (Tasks 8, 11) ✓.
- **Type consistency:** `LangCatalog` / `LangConvertResult` / `GachaLanguageConverter.convert` return `({BannerStorage data, LangConvertResult result})` used consistently across Tasks 7-11; `_convertAccountToDataLanguage(BannerStorage) → BannerStorage`; `unifyDataLanguage() → LangConvertResult`; `seedDataLanguageIfUnset(String)` / `setDataLanguage(String?)` consistent across Tasks 4, 9-11, 13.
- **Harness caveat:** Tasks 9-11's full-path tests depend on the existing `gacha_repository` test harness. The executor must inspect `test/state/` first and reuse its fakes; where a harness seam is absent, the listed unit tests (Tasks 7-8) plus the Task 14 manual smoke cover behavior. This is a known, called-out gap, not a silent skip.
- **Verify-before-code anchors:** Several steps end with grep/verify notes (sanitize import, `gachaRepositoryProvider` name, `itemImageFetcherProvider` location, `AppDialog`/`showAppDialog` API, `AccountsBundle.accounts[].data`). These are intentional confirm-then-edit points, not placeholders — the code to write is fully specified; only the surrounding symbol names must be matched to the codebase.
