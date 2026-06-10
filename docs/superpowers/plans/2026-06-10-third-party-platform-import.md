# 第三方平台歷史紀錄匯入（WuWa Tracker）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在設定頁新增「匯入資料（其他平台）」入口，先支援 WuWa Tracker 的 `wuwatracker-pulls` 匯出檔，並以可擴充的 `PlatformImporter` 架構接回現有匯入下游。

**Architecture:** 每個平台一個 `PlatformImporter`，只負責「外部格式 → 本軟體 `AccountsBundle`」；轉完接回既有下游（帳號挑選 → 確認 → `importAccountsAndFetchItemImages`，含合併去重／寫檔／補圖）。新增平台＝加一個 class＋在 `kPlatformImporters` 註冊一行。

**Tech Stack:** Flutter／Dart、Riverpod、`file_selector`、`flutter_test`、Flutter `gen-l10n`（FVM 釘住 SDK）。

**設計 spec：** `docs/superpowers/specs/2026-06-10-third-party-platform-import-design.md`

---

## 檔案結構

| 動作 | 檔案 | 職責 |
|---|---|---|
| Create | `lib/services/platform_import.dart` | `PlatformImporter` 介面 + `kPlatformImporters` 註冊清單 |
| Create | `lib/services/importers/wuwa_tracker_importer.dart` | `WuwaTrackerImporter`（`parse` 純函式 + 平台 metadata）+ `kWuwaServerUtcOffset` |
| Create | `lib/widgets/dialogs/platform_picker_dialog.dart` | `showPlatformPickerDialog` 單選平台 dialog |
| Modify | `lib/models/gacha_record.dart:36-37` | `resourceType` dartdoc 補一行（允用 canonical kind 鍵） |
| Modify | `lib/pages/settings_page.dart` | 新增按鈕、`_importFromPlatform`、把 `_import` 尾段抽成 `_runBundleImport`、補 import |
| Modify | `lib/l10n/app_zh.arb`（template）/ `app_en.arb` / `app_zh_Hans.arb` / `app_ja.arb` | 新增 5 個字串 |
| Create | `test/services/importers/wuwa_tracker_importer_test.dart` | parser golden + 例外測試 |
| Create | `test/widgets/dialogs/platform_picker_dialog_test.dart` | dialog widget 測試 |
| Modify | `test/pages/settings_page_import_button_test.dart` | 新按鈕 enabled/disabled 測試（既有測試維持綠燈） |

> 指令一律優先 `fvm flutter` / `fvm dart`，找不到 `fvm` 才退回 `flutter` / `dart`。`lib/l10n/generated/` 為 gitignore，不要 `git add`。

---

## Task 1: l10n 字串

**Files:**
- Modify: `lib/l10n/app_zh.arb`（template-arb-file）
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_zh_Hans.arb`
- Modify: `lib/l10n/app_ja.arb`

- [ ] **Step 1: app_zh.arb（template）新增 4 個按鈕/dialog 鍵**

在 `"settingsImportData": "匯入資料",` 這行**之後**插入：

```json
  "settingsImportOtherPlatform": "匯入資料（其他平台）",
  "platformPickerTitle": "選擇匯入來源平台",
  "platformWuwaTracker": "WuWa Tracker",
  "platformWuwaTrackerSubtitle": "wuwatracker.com・pulls JSON",
```

- [ ] **Step 2: app_zh.arb（template）新增錯誤原因鍵（含 placeholder metadata）**

在 `"importReasonForeignApp": "此檔案不是由本軟體匯出的備份",` 這行**之後**插入：

```json
  "importReasonNotPlatformFile": "此檔案不是有效的 {platform} 匯出檔",
  "@importReasonNotPlatformFile": {
    "placeholders": { "platform": { "type": "String" } }
  },
```

- [ ] **Step 3: app_en.arb 新增對應字串**

在 `"settingsImportData": "Import data",` 之後插入：

```json
  "settingsImportOtherPlatform": "Import data (other platforms)",
  "platformPickerTitle": "Select a source platform",
  "platformWuwaTracker": "WuWa Tracker",
  "platformWuwaTrackerSubtitle": "wuwatracker.com・pulls JSON",
```

在 `"importReasonForeignApp": "This file was not exported by this app",` 之後插入：

```json
  "importReasonNotPlatformFile": "This file is not a valid {platform} export",
```

- [ ] **Step 4: app_zh_Hans.arb 新增對應字串**

在 `"settingsImportData": "导入数据",` 之後插入：

```json
  "settingsImportOtherPlatform": "导入数据（其他平台）",
  "platformPickerTitle": "选择导入来源平台",
  "platformWuwaTracker": "WuWa Tracker",
  "platformWuwaTrackerSubtitle": "wuwatracker.com・pulls JSON",
```

在 `"importReasonForeignApp": ...`（簡中既有那行）之後插入：

```json
  "importReasonNotPlatformFile": "此文件不是有效的 {platform} 导出文件",
```

- [ ] **Step 5: app_ja.arb 新增對應字串**

在 `"settingsImportData": "データをインポート",` 之後插入：

```json
  "settingsImportOtherPlatform": "データをインポート（他プラットフォーム）",
  "platformPickerTitle": "インポート元のプラットフォームを選択",
  "platformWuwaTracker": "WuWa Tracker",
  "platformWuwaTrackerSubtitle": "wuwatracker.com・pulls JSON",
```

在 `"importReasonForeignApp": ...`（日文既有那行）之後插入：

```json
  "importReasonNotPlatformFile": "このファイルは有効な {platform} のエクスポートではありません",
```

- [ ] **Step 6: 產生 l10n 程式碼**

Run: `fvm flutter gen-l10n`
Expected: 無錯誤；`lib/l10n/generated/app_localizations.dart` 出現 `settingsImportOtherPlatform`、`platformPickerTitle`、`platformWuwaTracker`、`platformWuwaTrackerSubtitle`、`importReasonNotPlatformFile(String platform)` 等 getter/method。

- [ ] **Step 7: 靜態分析**

Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 8: Commit**

```bash
git add lib/l10n/app_zh.arb lib/l10n/app_en.arb lib/l10n/app_zh_Hans.arb lib/l10n/app_ja.arb
git commit -m "feat(import): add l10n strings for third-party platform import"
```

---

## Task 2: PlatformImporter 介面 + WuwaTrackerImporter

**Files:**
- Create: `lib/services/platform_import.dart`
- Create: `lib/services/importers/wuwa_tracker_importer.dart`
- Modify: `lib/models/gacha_record.dart:36-37`
- Test: `test/services/importers/wuwa_tracker_importer_test.dart`

- [ ] **Step 1: 寫失敗測試**

Create `test/services/importers/wuwa_tracker_importer_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/accounts_import.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/importers/wuwa_tracker_importer.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

const _sample = '''
{
  "siteVersion": "v4.7.19",
  "version": "0.0.2",
  "date": "2026-06-07T10:12:24.472Z",
  "playerId": "701146588",
  "pulls": [
    {"cardPoolType": 1, "resourceId": 1211, "qualityLevel": 5, "name": "Denia", "time": "2026-05-21T02:39:03+00:00", "isSorted": true, "group": 1},
    {"cardPoolType": 1, "resourceId": 21020023, "qualityLevel": 3, "name": "Sword of Night", "time": "2026-05-21T03:03:18+00:00", "isSorted": true, "group": 2},
    {"cardPoolType": 2, "resourceId": 21010024, "qualityLevel": 4, "name": "Cosmic Ripples", "time": "2026-05-20T01:00:00+00:00", "isSorted": true, "group": 1},
    {"cardPoolType": 4, "resourceId": 21050043, "qualityLevel": 3, "name": "Rectifier", "time": "2026-05-19T05:00:00+00:00", "isSorted": true, "group": 1},
    {"cardPoolType": 7, "resourceId": 99999999, "qualityLevel": 3, "name": "Ghost Pool", "time": "2026-05-18T00:00:00+00:00", "isSorted": true, "group": 1}
  ]
}
''';

void main() {
  const importer = WuwaTrackerImporter();

  test('parses pulls into a single-account AccountsBundle', () {
    final bundle = importer.parse(_sample);
    expect(bundle.accounts, hasLength(1));
    expect(bundle.accounts.single.data.playerId, '701146588');
    expect(bundle.lastActiveUid, '701146588');
  });

  test('groups by cardPoolType and skips unknown pools', () {
    final banners = importer.parse(_sample).accounts.single.data.banners;
    expect(banners.keys.toSet(), {'1', '2', '4'});
    expect(banners.containsKey('7'), isFalse);
    expect(banners['1'], hasLength(2));
  });

  test('converts UTC time to CST (+8) wall-clock matching official capture', () {
    final banners = importer.parse(_sample).accounts.single.data.banners;
    // 由新到舊：Sword 11:03:18 在前，Denia 10:39:03 在後。
    final sword = banners['1']![0];
    final denia = banners['1']![1];
    expect(sword.name, 'Sword of Night');
    expect(sword.time, parseGachaTime('2026-05-21 11:03:18'));
    expect(denia.name, 'Denia');
    expect(denia.time, parseGachaTime('2026-05-21 10:39:03'));
    // 與官方擷取一致：local-kind DateTime（isUtc=false）。
    expect(sword.time.isUtc, isFalse);
  });

  test('fills count=1, languageCode=en, and canonical kind resourceType', () {
    final banners = importer.parse(_sample).accounts.single.data.banners;
    final denia = banners['1']![1];
    final sword = banners['1']![0];
    expect(denia.count, 1);
    expect(denia.languageCode, 'en');
    expect(denia.cardPoolType, '1');
    expect(denia.resourceType, kItemKindCharacter); // 4 碼
    expect(sword.resourceType, kItemKindWeapon); // 8 碼
  });

  test('non-JSON → FormatException', () {
    expect(() => importer.parse('not json'), throwsFormatException);
  });

  test('JSON array → ForeignBundleException', () {
    expect(() => importer.parse('[]'), throwsA(isA<ForeignBundleException>()));
  });

  test('object without pulls/playerId → ForeignBundleException', () {
    const native = '{"schema_version": 2, "accounts": []}';
    expect(
      () => importer.parse(native),
      throwsA(isA<ForeignBundleException>()),
    );
  });

  test('playerId present but pulls not a list → ForeignBundleException', () {
    const bad = '{"playerId": "701146588", "pulls": {}}';
    expect(() => importer.parse(bad), throwsA(isA<ForeignBundleException>()));
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/importers/wuwa_tracker_importer_test.dart`
Expected: 編譯失敗（找不到 `WuwaTrackerImporter`／`wuwa_tracker_importer.dart`）。

- [ ] **Step 3: 建立介面與註冊清單**

Create `lib/services/platform_import.dart`：

```dart
import 'package:flutter/widgets.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/importers/wuwa_tracker_importer.dart';

/// 第三方平台匯入器：把該平台的匯出檔轉成本軟體的 [AccountsBundle]，之後接回
/// 既有匯入下游（帳號挑選 → 確認 → 合併寫入＋補圖）。新增平台＝加一個實作類別
/// 並在 [kPlatformImporters] 註冊一行。
abstract interface class PlatformImporter {
  /// 穩定識別鍵（如 `'wuwa_tracker'`）。
  String get id;

  /// 平台顯示名（在地化）。
  String displayName(AppLocalizations l);

  /// 平台清單列的副標（在地化）；null 表示不顯示。
  String? subtitle(AppLocalizations l);

  /// 平台清單列的前置 icon。
  IconData get icon;

  /// 可接受的副檔名（如 `['json']`）。
  List<String> get fileExtensions;

  /// 解析檔案內容為 [AccountsBundle]。
  ///
  /// 非此平台格式丟 `ForeignBundleException`；結構／型別不符丟 [FormatException]。
  AccountsBundle parse(String content);
}

/// 已支援的第三方平台清單。新增平台時在此追加。
const List<PlatformImporter> kPlatformImporters = [WuwaTrackerImporter()];
```

Create `lib/services/importers/wuwa_tracker_importer.dart`：

```dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/data/gacha_types.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/accounts_import.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/platform_import.dart';

/// Logger 實例（第三方平台匯入）。
final _log = Logger('wish.import.platform');

/// 鳴潮全球統一伺服器時間相對 UTC 的固定偏移（中國標準時間 CST = UTC+8）。
///
/// WuWa Tracker 匯出檔的 `time` 為 UTC instant；鳴潮五服共用 CST 伺服器時間，故
/// 一律加回 +8 還原成官方喚取 API 的伺服器在地牆鐘，對所有區服皆正確。詳見
/// 設計 spec §3 與 memory/wuwa-unified-cst-server-time.md。
const Duration kWuwaServerUtcOffset = Duration(hours: 8);

/// WuWa Tracker（wuwatracker.com）的 `wuwatracker-pulls` 匯出檔匯入器。
class WuwaTrackerImporter implements PlatformImporter {
  /// 建立 [WuwaTrackerImporter]。
  const WuwaTrackerImporter();

  @override
  String get id => 'wuwa_tracker';

  @override
  String displayName(AppLocalizations l) => l.platformWuwaTracker;

  @override
  String? subtitle(AppLocalizations l) => l.platformWuwaTrackerSubtitle;

  @override
  IconData get icon => Icons.cloud_sync_outlined;

  @override
  List<String> get fileExtensions => const ['json'];

  @override
  AccountsBundle parse(String content) {
    Object? raw;
    try {
      raw = jsonDecode(content);
    } catch (e) {
      _log.warning('wuwa_tracker import: invalid JSON ($e)');
      throw const FormatException('Invalid JSON');
    }
    if (raw is! Map<String, dynamic>) {
      throw const ForeignBundleException();
    }
    final playerId = raw['playerId'];
    final pulls = raw['pulls'];
    if (playerId is! String || playerId.isEmpty || pulls is! List) {
      // 缺頂層 playerId / pulls：不是 WuWa Tracker 的 pulls 匯出。
      throw const ForeignBundleException();
    }

    try {
      final known = <String>{for (final t in gachaTypes) t.key};
      final banners = <String, List<GachaRecord>>{};
      var skipped = 0;
      for (final entry in pulls) {
        if (entry is! Map<String, dynamic>) {
          throw const FormatException('pulls[] entry must be an object');
        }
        final cardPoolType = (entry['cardPoolType'] as num).toInt().toString();
        if (!known.contains(cardPoolType)) {
          skipped++;
          continue;
        }
        final resourceId = (entry['resourceId'] as num).toInt();
        banners.putIfAbsent(cardPoolType, () => <GachaRecord>[]).add(
          GachaRecord(
            resourceId: resourceId,
            qualityLevel: (entry['qualityLevel'] as num).toInt(),
            // resourceType 缺：存 canonical kind 鍵（4 碼角色、8 碼武器）。匯入後
            // encore 分類接手，少數 8 碼道具會被修正為 kItemKindItem。見 spec §3。
            resourceType: resourceId.toString().length <= 4
                ? kItemKindCharacter
                : kItemKindWeapon,
            cardPoolType: cardPoolType,
            name: entry['name'] as String,
            count: 1,
            // WHY：WuWa Tracker 的 time 是 UTC instant，鳴潮全球統一 CST(+8)。
            // toUtc() 先取絕對 instant（與裝置時區無關）→ +8 → format 成牆鐘字串
            // → parse 回 local-kind DateTime，與官方擷取的 time 表示法（local-kind、
            // 相同欄位）完全一致；recordsEqual 依 DateTime==（含 isUtc 旗標）比對，
            // 唯有同表示法才對得齊。
            time: parseGachaTime(
              formatGachaTime(
                DateTime.parse(entry['time'] as String)
                    .toUtc()
                    .add(kWuwaServerUtcOffset),
              ),
            ),
            languageCode: 'en',
          ),
        );
      }

      // 每池由新到舊；同 time 以原陣列順序穩定 tiebreak（decorate-sort 保決定性）。
      for (final list in banners.values) {
        final indexed = list.indexed.toList();
        indexed.sort((a, b) {
          final byTime = b.$2.time.compareTo(a.$2.time);
          return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
        });
        list
          ..clear()
          ..addAll([for (final e in indexed) e.$2]);
      }

      final rawDate = raw['date'];
      final exportedAt =
          (rawDate is String ? DateTime.tryParse(rawDate)?.toUtc() : null) ??
              DateTime.now().toUtc();

      final total = banners.values.fold<int>(0, (a, b) => a + b.length);
      _log.info(
        'wuwa_tracker import parsed: player=${sanitizeUid(playerId)} '
        'pools=${banners.length} records=$total skipped=$skipped',
      );

      final storage = BannerStorage(
        playerId: playerId,
        languageCode: 'en',
        lastUpdated: exportedAt,
        banners: banners,
      );
      return AccountsBundle(
        exportedAt: exportedAt,
        appVersion: '',
        lastActiveUid: playerId,
        accounts: [ExportedAccount(data: storage)],
      );
    } on FormatException {
      rethrow;
    } catch (e, st) {
      _log.warning('wuwa_tracker import: parse error', e, st);
      throw FormatException('Failed to parse WuWa Tracker file: $e');
    }
  }
}
```

Modify `lib/models/gacha_record.dart` 第 36-37 行的 `resourceType` dartdoc，由：

```dart
  /// 道具類型字串（`角色` / `武器` / `道具`，隨 languageCode 變化）。
  final String resourceType;
```

改為：

```dart
  /// 道具類型字串（官方 API 來源為 `角色` / `武器` / `道具`，隨 languageCode 變化）。
  ///
  /// 第三方平台匯入（缺此欄）改存 canonical kind 鍵（見 `item_type_kind.dart`）；
  /// 唯一消費點 `itemTypeKeyOf` / `itemTypeKeyLabel` 本就以 canonical 鍵為主分支。
  final String resourceType;
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/services/importers/wuwa_tracker_importer_test.dart`
Expected: All tests passed!

- [ ] **Step 5: 靜態分析**

Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/services/platform_import.dart lib/services/importers/wuwa_tracker_importer.dart lib/models/gacha_record.dart test/services/importers/wuwa_tracker_importer_test.dart
git commit -m "feat(import): add WuWa Tracker importer and PlatformImporter registry"
```

---

## Task 3: 平台選擇 Dialog

**Files:**
- Create: `lib/widgets/dialogs/platform_picker_dialog.dart`
- Test: `test/widgets/dialogs/platform_picker_dialog_test.dart`

- [ ] **Step 1: 寫失敗測試**

Create `test/widgets/dialogs/platform_picker_dialog_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/importers/wuwa_tracker_importer.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/platform_import.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/platform_picker_dialog.dart';

// 用 file-level 變數捕捉 dialog 結果（同 accounts_picker_dialog_test.dart 模式）。
PlatformImporter? _result;
bool _completed = false;

Future<void> _open(WidgetTester tester) async {
  _result = null;
  _completed = false;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'Hant'),
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  _result = await showPlatformPickerDialog(context: ctx);
                  _completed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists WuWa Tracker and returns it on tap', (tester) async {
    await _open(tester);
    expect(find.text('WuWa Tracker'), findsOneWidget);

    await tester.tap(find.text('WuWa Tracker'));
    await tester.pumpAndSettle();

    expect(_completed, isTrue);
    expect(_result, isA<WuwaTrackerImporter>());
  });

  testWidgets('cancel returns null', (tester) async {
    await _open(tester);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(_completed, isTrue);
    expect(_result, isNull);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/dialogs/platform_picker_dialog_test.dart`
Expected: 編譯失敗（找不到 `platform_picker_dialog.dart`）。

- [ ] **Step 3: 實作 dialog**

Create `lib/widgets/dialogs/platform_picker_dialog.dart`：

```dart
import 'package:flutter/material.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/platform_import.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/app_dialog.dart';

/// 顯示平台選擇對話框；單選導覽式：點一列即回傳該 [PlatformImporter]，取消回 null。
Future<PlatformImporter?> showPlatformPickerDialog({
  required BuildContext context,
}) {
  return showDialog<PlatformImporter>(
    context: context,
    builder: (_) => const _PlatformPickerDialog(),
  );
}

/// 平台選擇 dialog 的實作 widget。
class _PlatformPickerDialog extends StatelessWidget {
  const _PlatformPickerDialog();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AppDialog(
      size: AppDialogSize.sm,
      title: Text(l.platformPickerTitle),
      content: ListView(
        shrinkWrap: true,
        children: [
          for (final importer in kPlatformImporters)
            ListTile(
              leading: Icon(importer.icon),
              title: Text(importer.displayName(l)),
              subtitle: importer.subtitle(l) == null
                  ? null
                  : Text(importer.subtitle(l)!),
              onTap: () => Navigator.of(context).pop(importer),
            ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, size: 18),
          label: Text(l.actionCancel),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/dialogs/platform_picker_dialog_test.dart`
Expected: All tests passed!

- [ ] **Step 5: 靜態分析**

Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/dialogs/platform_picker_dialog.dart test/widgets/dialogs/platform_picker_dialog_test.dart
git commit -m "feat(import): add single-select platform picker dialog"
```

---

## Task 4: 設定頁串接（按鈕 + 流程 + 共用重構）

**Files:**
- Modify: `lib/pages/settings_page.dart`（import、`_DataManagement` Wrap、`_import` 重構、新增 `_importFromPlatform` 與 `_runBundleImport`）
- Test: `test/pages/settings_page_import_button_test.dart`

- [ ] **Step 1: 寫失敗測試（新按鈕 enabled/disabled）**

在 `test/pages/settings_page_import_button_test.dart` 的 `void main() {` 內、`}` 結尾之前，追加兩個 test：

```dart
  testWidgets('progress 為 null：其他平台匯入按鈕 enabled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _setupContainer(
        storage: GachaStorage(tempDir),
        tempDir: tempDir,
      );
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final btn = find.widgetWithText(OutlinedButton, '匯入資料（其他平台）');
    expect(btn, findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(btn).onPressed,
      isNotNull,
      reason: '其他平台匯入按鈕在 progress 為 null 時應 enabled',
    );
  });

  testWidgets('progress 非 null：其他平台匯入按鈕 disabled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _setupContainer(
        storage: GachaStorage(tempDir),
        tempDir: tempDir,
      );
    });
    addTearDown(container.dispose);

    container
        .read(gachaRepositoryProvider.notifier)
        .debugSetProgress(const Preparing());

    await tester.pumpWidget(_wrap(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final btn = find.widgetWithText(OutlinedButton, '匯入資料（其他平台）');
    expect(btn, findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(btn).onPressed,
      isNull,
      reason: 'progress 非 null 時其他平台匯入按鈕應 disabled',
    );
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/pages/settings_page_import_button_test.dart`
Expected: 新增的兩個 test FAIL（找不到「匯入資料（其他平台）」按鈕）；既有兩個 test 仍 PASS。

- [ ] **Step 3: 加入 import**

在 `lib/pages/settings_page.dart` 既有 import 區（與其他 `widgets/dialogs/...` import 相鄰）加入：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/platform_import.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/platform_picker_dialog.dart';
```

- [ ] **Step 4: 在 `_DataManagement` 的 Wrap 新增按鈕**

在現有「匯入資料」按鈕（`OutlinedButton.icon` with `l.settingsImportData`）**之後**插入：

```dart
        OutlinedButton.icon(
          onPressed: progress != null
              ? null
              : () => _importFromPlatform(context, ref),
          icon: const Icon(Icons.cloud_sync_outlined, size: 18),
          label: Text(l.settingsImportOtherPlatform),
        ),
```

- [ ] **Step 5: 把 `_import` 尾段抽成 `_runBundleImport`**

把 `_import` 方法中**自 `// Picker：列出檔案內的帳號讓使用者勾選。` 起、到結尾 `unawaited(...)` 區塊止**的整段（即現行第 544-636 行）剪下，替換為：

```dart
    if (!ctx.mounted) return;
    await _runBundleImport(ctx, ref, bundle);
  }
```

接著在 `_import` 方法之後新增 `_runBundleImport`（貼上剛剪下的整段，並在開頭補 `final l`）：

```dart
  /// 拿到（已解析的）[bundle] 後的共用匯入下游：帳號挑選 → 確認 → 寫入＋補圖。
  /// 由本軟體備份匯入（[_import]）與第三方平台匯入（[_importFromPlatform]）共用。
  Future<void> _runBundleImport(
    BuildContext ctx,
    WidgetRef ref,
    AccountsBundle bundle,
  ) async {
    final l = AppLocalizations.of(ctx)!;

    // Picker：列出檔案內的帳號讓使用者勾選。
    final existing = ref.read(gachaRepositoryProvider).byUid.keys.toSet();
    final entries = [
      for (final a in bundle.accounts)
        AccountPickerEntry(
          uid: a.data.playerId,
          alias: a.alias,
          lastUpdated: a.data.lastUpdated,
          recordCount: a.data.allRecords.length,
          badge: existing.contains(a.data.playerId)
              ? l.settingsImportMergeBadge
              : null,
        ),
    ];
    if (!ctx.mounted) return;
    final picked = await showAccountsPickerDialog(
      context: ctx,
      title: l.settingsImportSelectTitle,
      confirmLabel: l.confirmContinue,
      entries: entries,
    );
    if (picked == null || picked.isEmpty) return;
    if (!ctx.mounted) return;

    final pickedSet = picked.toSet();
    final filteredBundle = AccountsBundle(
      exportedAt: bundle.exportedAt,
      appVersion: bundle.appVersion,
      lastActiveUid: pickedSet.contains(bundle.lastActiveUid)
          ? bundle.lastActiveUid
          : null,
      accounts: bundle.accounts
          .where((a) => pickedSet.contains(a.data.playerId))
          .toList(growable: false),
    );

    // Confirm dialog：以 filteredBundle 重新計算 incoming / conflicts / preserved。
    final incoming = filteredBundle.accounts
        .map((a) => a.data.playerId)
        .toList(growable: false);
    final conflicts = incoming.where(existing.contains).toList(growable: false);
    final preserved = (existing.toSet()..removeAll(incoming)).toList()..sort();

    var totalRecords = 0;
    for (final a in filteredBundle.accounts) {
      for (final list in a.data.banners.values) {
        totalRecords += list.length;
      }
    }

    final buf = StringBuffer()
      ..writeln(l.settingsImportConfirmIntro(incoming.length, totalRecords));
    for (final a in filteredBundle.accounts) {
      final alias = a.alias;
      buf.writeln(
        alias == null || alias.isEmpty
            ? '  • ${a.data.playerId}'
            : '  • ${a.data.playerId} ($alias)',
      );
    }
    buf.writeln();
    if (conflicts.isEmpty) {
      buf.writeln(l.settingsImportConfirmNoConflict);
    } else {
      buf.writeln(l.settingsImportConfirmMergeHeader);
      for (final uid in conflicts) {
        buf.writeln('  • $uid');
      }
    }
    if (preserved.isNotEmpty) {
      buf.writeln();
      buf.writeln(l.settingsImportConfirmPreserveFooter(preserved.join(', ')));
    }

    final ok = await showConfirmDialog(
      context: ctx,
      title: l.settingsImportConfirmTitle,
      body: buf.toString(),
      cancelLabel: l.actionCancel,
      confirmLabel: l.confirmImport,
      confirmIcon: Icons.check,
    );
    if (ok != true) return;
    if (!ctx.mounted) return;

    // fire-and-forget：progress dialog 由 app_shell 既有 ref.listen 自動接管。
    unawaited(
      ref
          .read(gachaRepositoryProvider.notifier)
          .importAccountsAndFetchItemImages(
            jsonEncode(filteredBundle.toJson()),
          ),
    );
  }
```

- [ ] **Step 6: 新增 `_importFromPlatform`**

在 `_runBundleImport` 之後新增：

```dart
  /// 從第三方平台匯入：選平台 → 選檔 → 解析 → 共用下游 [_runBundleImport]。
  Future<void> _importFromPlatform(BuildContext ctx, WidgetRef ref) async {
    final l = AppLocalizations.of(ctx)!;
    final platform = await showPlatformPickerDialog(context: ctx);
    if (platform == null) return;
    if (!ctx.mounted) return;

    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: 'JSON', extensions: platform.fileExtensions),
      ],
    );
    if (file == null) return;

    final String text;
    try {
      text = await file.readAsString();
    } catch (e, st) {
      Logger('wish.import.platform').warning('read failed', e, st);
      if (!ctx.mounted) return;
      _showSnack(ctx, l.settingsImportFailed(l.importReasonUnreadable));
      return;
    }

    final AccountsBundle bundle;
    try {
      bundle = platform.parse(text);
    } on ForeignBundleException {
      if (!ctx.mounted) return;
      _showSnack(
        ctx,
        l.settingsImportFailed(
          l.importReasonNotPlatformFile(platform.displayName(l)),
        ),
      );
      return;
    } on FormatException {
      if (!ctx.mounted) return;
      _showSnack(ctx, l.settingsImportFailed(l.importReasonInvalidFormat));
      return;
    }

    if (!ctx.mounted) return;
    await _runBundleImport(ctx, ref, bundle);
  }
```

- [ ] **Step 7: 跑該檔測試確認通過**

Run: `fvm flutter test test/pages/settings_page_import_button_test.dart`
Expected: All tests passed!（既有 2 + 新增 2，共 4 個）

- [ ] **Step 8: 全套測試與分析**

Run: `fvm flutter analyze`
Expected: `No issues found!`

Run: `fvm flutter test`
Expected: All tests passed!

- [ ] **Step 9: Commit**

```bash
git add lib/pages/settings_page.dart test/pages/settings_page_import_button_test.dart
git commit -m "feat(import): wire up 'import data (other platforms)' in settings"
```

---

## Task 5: 收尾驗證

**Files:** 無（驗證 + 視需要格式化）

- [ ] **Step 1: 格式化**

Run: `fvm dart format lib/ test/`
Expected: 若有檔案被重排，`git add` 後補一個 commit；無變更則略過。

- [ ] **Step 2: 靜態分析**

Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: 全套測試**

Run: `fvm flutter test`
Expected: All tests passed!

- [ ] **Step 4: 手動煙霧測試（建議，非必須）**

啟動 app → 設定頁 → 點「匯入資料（其他平台）」→ 選 WuWa Tracker → 選 `C:\Users\p2902\Downloads\701146588_2026-06-07_wuwatracker-pulls.json` → 帳號挑選 → 確認 → 觀察：
- 紀錄出現於角色活動（pool 1）／武器活動（pool 2）／武器常駐（pool 4）。
- 5★ 達妮婭時間顯示為 `2026-05-21 10:39:03`（伺服器在地 CST 牆鐘）。
- 補圖管線完成後類型分組（角色／武器）正確。
- 餵一個非 WuWa Tracker 的 JSON → 顯示「匯入失敗：此檔案不是有效的 WuWa Tracker 匯出檔」。

- [ ] **Step 5: 若 Step 1 有格式變更才 Commit**

```bash
git add -A
git commit -m "style(import): apply dart format"
```

---

## 自我審查（已對 spec 核對）

- **時間還原（spec §3）**：Task 2 `parse` 以 `kWuwaServerUtcOffset` +8，並 `format→parse` 還原為 local-kind DateTime 對齊官方擷取；測試逐秒驗證。✓
- **resourceType canonical kind（spec §3）**：Task 2 存 `kItemKindCharacter`/`kItemKindWeapon`，gacha_record dartdoc 補註。✓
- **count=1 / languageCode=en / 未知池跳過 / 由新到舊排序（spec §3）**：Task 2 實作 + 測試。✓
- **架構與註冊（spec §4）**：Task 2 `PlatformImporter` + `kPlatformImporters`。✓
- **資料流／共用下游（spec §5、§7）**：Task 4 `_runBundleImport` 抽出共用，`_importFromPlatform` 接入。✓
- **UI（spec §6）**：Task 4 按鈕 + Task 3 單選 dialog。✓
- **l10n（spec §8）**：Task 1 五鍵、template=app_zh.arb 含 placeholder metadata。✓
- **Logging（spec §9）**：Task 2 `wish.import.platform` 記 player（脫敏）/pools/records/skipped。✓
- **範圍（spec §10）**：僅 `wuwatracker-pulls`；缺 shape → ForeignBundleException。✓
- **測試（spec §11）**：Task 2 golden+例外、Task 3 dialog、Task 4 按鈕、Task 5 全綠。✓
- **驗收（spec §12）**：Task 5 手動煙霧 + 全綠涵蓋；新增第二平台僅需加 class + 註冊一行（架構可擴充性）。✓
