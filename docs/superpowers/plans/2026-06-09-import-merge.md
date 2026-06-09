# Import Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「匯入資料」從整帳號覆蓋改為非破壞性合併——以有序序列對齊去重（鳴潮無唯一 id）、永不丟本機紀錄、偏好只補空缺、放寬確認流程（移除打字閘）、回報新增/已存在筆數，使用者體驗對齊原神版。

**Architecture:** 新增記錄級雙向合併原語 `mergeBackupRecords`（`record_merge.dart`，複用既有 `_findAlignment`/`recordsEqual`），帳號級包裝 `BannerStorage.mergeWith`；`_runImport` 改成「本機沒有 → 直接存、已有 → mergeWith 後存」並統計 added/duplicate；`ImportResult` 改欄位；確認流程抽取既有內聯 confirm 成共用 `showConfirmDialog`（不重造輪子），picker badge 與文案改合併語意。

**Tech Stack:** Flutter / Dart、Riverpod、`flutter gen-l10n`（ARB 多語）、`flutter_test`。一律優先用 `fvm`（找不到再退回 `flutter`／`dart`）。

**規格依據：** `docs/superpowers/specs/2026-06-09-import-merge-design.md`。**分支：** `feat/import-merge`（已建立）。

---

## File Structure

| 檔案 | 角色 |
|------|------|
| `lib/services/record_merge.dart` | 新增 `mergeBackupRecords` + `_overlapEquals`（不動 `mergeOrderedRecords`） |
| `test/services/record_merge_test.dart` | 既有檔，加 `mergeBackupRecords` group |
| `lib/models/banner_storage.dart` | 新增 `mergeWith`（逐池呼叫 `mergeBackupRecords`、`lastUpdated`/`languageCode` 取較新） |
| `test/models/banner_storage_test.dart` | 既有檔，加 `mergeWith` 測試 |
| `lib/state/update_progress.dart` | `ImportResult` 欄位：`addedRecords`/`duplicateRecords`（移除 `totalRecords`） |
| `lib/state/gacha_repository.dart` | `_runImport` 合併邏輯＋計數＋偏好只補空缺＋active 保留本機＋log；`importAccountsAndFetchItemImages` 的 `emptyResult` 與 log 改欄位 |
| `lib/widgets/update_progress_dialog.dart` | 完成摘要改新欄位／新 `progressDoneImportSummary` 簽名 |
| `lib/widgets/dialogs/confirm_dialog.dart` | 新增無打字 `showConfirmDialog`（`isDanger` 參數） |
| `lib/pages/settings_page.dart` | `_import` 改合併語意＋用 `showConfirmDialog`；`_refetchAll`／`_clearGallery` 改用共用 helper |
| `lib/widgets/dialogs/accounts_picker_dialog.dart` | `_PickerRow` badge 改中性色、`AccountPickerEntry.badge` dartdoc 改中性描述 |
| `lib/l10n/app_zh.arb` + `app_en` / `app_ja` / `app_zh_Hans` | 新增/改寫/刪除 key（見各 Task） |
| 既有測試 | `test/state/gacha_repository_test.dart`、`test/widgets/dialogs/confirm_dialog_test.dart`、`test/widgets/dialogs/accounts_picker_dialog_test.dart` 改新語意 |

**核心手改語系（其餘 26 個 ARB 為 24-byte Crowdin 空殼，不動）：** `app_zh.arb`(template)、`app_en.arb`、`app_ja.arb`、`app_zh_Hans.arb`。

---

## Task 1: `mergeBackupRecords` 雙向合併原語

**Files:**
- Modify: `lib/services/record_merge.dart`
- Test: `test/services/record_merge_test.dart`

- [ ] **Step 1: 寫失敗測試**

在 `test/services/record_merge_test.dart`，於最後一個 group（`mergeOrderedRecords 增量`）的結尾 `});`（約第 211 行）之後、`main` 的結尾 `}`（約第 212 行）之前，插入：

```dart

  group('mergeBackupRecords', () {
    /// 斷言 [sub] 為 [full] 的子序列（保序、可不連續）。
    bool isSubseq(List<GachaRecord> sub, List<GachaRecord> full) {
      var i = 0;
      for (final f in full) {
        if (i < sub.length && recordsEqual(sub[i], f)) i++;
      }
      return i == sub.length;
    }

    test('incoming 較新且完全重疊 → 接上新頭、保留本機', () {
      final local = [r(30, sec: 30), r(20, sec: 20), r(10, sec: 10)];
      final incoming = [
        r(50, sec: 50),
        r(40, sec: 40),
        r(30, sec: 30),
        r(20, sec: 20),
        r(10, sec: 10),
      ];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [50, 40, 30, 20, 10]);
    });

    test('incoming 較舊（補回更舊尾段）→ 保留本機、接上舊尾', () {
      final local = [r(30, sec: 30), r(20, sec: 20)];
      final incoming = [r(20, sec: 20), r(10, sec: 10), r(5, sec: 5)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [30, 20, 10, 5]);
    });

    test('incoming 完全包住 local（兩端都更長）→ 縫成完整聯集', () {
      final local = [r(4, sec: 4), r(3, sec: 3)];
      final incoming = [
        r(6, sec: 6),
        r(5, sec: 5),
        r(4, sec: 4),
        r(3, sec: 3),
        r(2, sec: 2),
        r(1, sec: 1),
      ];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [6, 5, 4, 3, 2, 1]);
    });

    test('local 完全包住 incoming → 回 local、不漏不重', () {
      final local = [
        r(5, sec: 5),
        r(4, sec: 4),
        r(3, sec: 3),
        r(2, sec: 2),
        r(1, sec: 1),
      ];
      final incoming = [r(4, sec: 4), r(3, sec: 3), r(2, sec: 2)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [5, 4, 3, 2, 1]);
    });

    test('完全不相交（incoming 較舊）→ 全部保留、較新在前', () {
      final local = [r(30, sec: 30), r(20, sec: 20)];
      final incoming = [r(10, sec: 10), r(5, sec: 5)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [30, 20, 10, 5]);
    });

    test('完全不相交（incoming 較新）→ 全部保留、incoming 在前', () {
      final local = [r(10, sec: 10), r(5, sec: 5)];
      final incoming = [r(30, sec: 30), r(20, sec: 20)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [30, 20, 10, 5]);
    });

    test('重疊落在同十連同 time 連續段 → 段內順序不被打亂', () {
      // t=30 的十連有兩筆（resourceId 31/32，sec 皆 30）
      final local = [r(40, sec: 40), r(31, sec: 30), r(32, sec: 30), r(20, sec: 20)];
      final incoming = [r(50, sec: 50), r(40, sec: 40), r(31, sec: 30), r(32, sec: 30)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [50, 40, 31, 32, 20]);
    });

    test('同十連同道具重複兩筆 → 多重數保留、不誤併', () {
      final local = [r(99, name: 'A', sec: 20), r(99, name: 'A', sec: 20)];
      final incoming = [r(99, name: 'A', sec: 20), r(99, name: 'A', sec: 20)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [99, 99]);
      expect(merged.length, 2);
    });

    test('空 local → 回 incoming；空 incoming → 回 local', () {
      final incoming = [r(2, sec: 2), r(1, sec: 1)];
      expect(
        mergeBackupRecords(const [], incoming).map((e) => e.resourceId),
        [2, 1],
      );
      final local = [r(3, sec: 3)];
      expect(
        mergeBackupRecords(local, const []).map((e) => e.resourceId),
        [3],
      );
    });

    test('不漏資料：local 與 incoming 皆為輸出子序列', () {
      final local = [r(30, sec: 30), r(20, sec: 20)];
      final incoming = [r(20, sec: 20), r(10, sec: 10), r(5, sec: 5)];
      final merged = mergeBackupRecords(local, incoming);
      expect(isSubseq(local, merged), isTrue);
      expect(isSubseq(incoming, merged), isTrue);
    });
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/record_merge_test.dart`
Expected: FAIL（`mergeBackupRecords` 未定義 → 編譯錯誤）。

- [ ] **Step 3: 實作 `mergeBackupRecords` + `_overlapEquals`**

在 `lib/services/record_merge.dart` 結尾（`_findAlignment` 函式之後，約第 88 行 `}` 之後）新增：

```dart

/// 將兩份同 UID、同卡池的喚取紀錄（皆由新到舊）做非破壞性雙向合併，回傳合併後
/// 的完整有序清單（由新到舊）。
///
/// [local] 整段一律保留（含重疊那筆保留本機版本），只把 [incoming] 比 [local]
/// 「更新的頭」與「更舊的尾」接上。錨點命中後**逐筆驗證整段重疊**才縫合，避免短
/// 錨點在重複片段誤命中錯位置。完全對不到一致重疊時（不相交／斷層／輸入損毀）
/// 保留兩段、不漏，較新者在前並 log warning。
///
/// 與 [mergeOrderedRecords]（更新流程的單向增量）刻意分開：匯入的備份可能比本機
/// 更舊（補回早期段），單向版對不到錨點會丟掉另一段。
List<GachaRecord> mergeBackupRecords(
  List<GachaRecord> local,
  List<GachaRecord> incoming,
) {
  if (local.isEmpty) return List<GachaRecord>.from(incoming);
  if (incoming.isEmpty) return List<GachaRecord>.from(local);

  // Case 1：local 的開頭出現在 incoming 中（incoming 較新或頭部對齊）。
  final maxAnchor1 = local.length < _anchorBase ? local.length : _anchorBase;
  for (var anchorLen = maxAnchor1; anchorLen >= 1; anchorLen--) {
    final j = _findAlignment(incoming, local, anchorLen);
    if (j != null) {
      final overlapLen = local.length < incoming.length - j
          ? local.length
          : incoming.length - j;
      if (_overlapEquals(incoming, j, local, 0, overlapLen)) {
        final olderStart = j + local.length < incoming.length
            ? j + local.length
            : incoming.length;
        return [
          ...incoming.sublist(0, j),
          ...local,
          ...incoming.sublist(olderStart),
        ];
      }
    }
  }

  // Case 2：incoming 的開頭出現在 local 中（incoming 較舊或被 local 包含）。
  final maxAnchor2 = incoming.length < _anchorBase
      ? incoming.length
      : _anchorBase;
  for (var anchorLen = maxAnchor2; anchorLen >= 1; anchorLen--) {
    final i = _findAlignment(local, incoming, anchorLen);
    if (i != null) {
      final overlapLen = incoming.length < local.length - i
          ? incoming.length
          : local.length - i;
      if (_overlapEquals(local, i, incoming, 0, overlapLen)) {
        final olderStart = local.length - i < incoming.length
            ? local.length - i
            : incoming.length;
        return [...local, ...incoming.sublist(olderStart)];
      }
    }
  }

  // Case 3：找不到一致重疊 → 全部保留（不漏優先於不重），較新者在前。
  // 不做全域 time 排序：同十連多筆共用同一 time，排序會打亂十連內順序、破壞日後對齊。
  _log.warning(
    'mergeBackupRecords: no consistent overlap; keeping both '
    '(local=${local.length} incoming=${incoming.length})',
  );
  return incoming.first.time.isAfter(local.first.time)
      ? [...incoming, ...local]
      : [...local, ...incoming];
}

/// 逐筆比較 [a] 從 [aStart] 起與 [b] 從 [bStart] 起連續 [len] 筆是否全部 [recordsEqual]。
bool _overlapEquals(
  List<GachaRecord> a,
  int aStart,
  List<GachaRecord> b,
  int bStart,
  int len,
) {
  for (var k = 0; k < len; k++) {
    if (!recordsEqual(a[aStart + k], b[bStart + k])) return false;
  }
  return true;
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/services/record_merge_test.dart`
Expected: PASS（既有 + 10 個新 `mergeBackupRecords` 測試全綠）。

- [ ] **Step 5: commit**

```bash
git add lib/services/record_merge.dart test/services/record_merge_test.dart
git commit -m "feat(import): add bidirectional mergeBackupRecords primitive"
```

---

## Task 2: `BannerStorage.mergeWith` 帳號級合併

**Files:**
- Modify: `lib/models/banner_storage.dart`
- Test: `test/models/banner_storage_test.dart`

- [ ] **Step 1: 寫失敗測試**

在 `test/models/banner_storage_test.dart`，於頂部 helper `_r`（約第 5-13 行）之後新增一個 sec 可變的 helper：

```dart

GachaRecord _rt(int id, int sec) => GachaRecord(
  resourceId: id,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: '1',
  name: 'x',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, sec),
);
```

並在 `main()` 結尾 `}`（約第 125 行）之前插入：

```dart

  test('mergeWith: 逐池對齊去重，保留本機並接上 incoming 較舊尾段', () {
    final local = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 5, 12),
      banners: {
        '1': [_rt(3, 30), _rt(2, 20)],
      },
    );
    final incoming = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: {
        '1': [_rt(2, 20), _rt(1, 10)],
      },
    );
    final merged = local.mergeWith(incoming);
    expect(merged.banners['1']!.map((r) => r.resourceId).toList(), [3, 2, 1]);
  });

  test('mergeWith: banner key 取聯集', () {
    final local = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: {
        '1': [_rt(1, 10)],
      },
    );
    final incoming = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: {
        '8': [_rt(2, 20)],
      },
    );
    final merged = local.mergeWith(incoming);
    expect(merged.banners.keys.toSet(), {'1', '8'});
    expect(merged.banners['1']!.single.resourceId, 1);
    expect(merged.banners['8']!.single.resourceId, 2);
  });

  test('mergeWith: lastUpdated 與 languageCode 取較新一方', () {
    final older = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: const {'1': []},
    );
    final newer = BannerStorage(
      playerId: 'p',
      languageCode: 'en',
      lastUpdated: DateTime.utc(2026, 5, 12),
      banners: const {'1': []},
    );
    final mergedA = older.mergeWith(newer);
    expect(mergedA.lastUpdated, DateTime.utc(2026, 5, 12));
    expect(mergedA.languageCode, 'en');
    final mergedB = newer.mergeWith(older);
    expect(mergedB.lastUpdated, DateTime.utc(2026, 5, 12));
    expect(mergedB.languageCode, 'en');
  });

  test('mergeWith: 空本機 → 合併為 incoming 內容', () {
    final local = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: const {},
    );
    final incoming = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 5, 12),
      banners: {
        '1': [_rt(2, 20), _rt(1, 10)],
      },
    );
    final merged = local.mergeWith(incoming);
    expect(merged.banners['1']!.map((r) => r.resourceId).toList(), [2, 1]);
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/models/banner_storage_test.dart`
Expected: FAIL（`mergeWith` 未定義 → 編譯錯誤）。

- [ ] **Step 3: 實作 `mergeWith`**

`lib/models/banner_storage.dart`，先在檔頭既有 import（第 1 行）之後新增：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/record_merge.dart';
```

接著在 `copyWith`（約第 70-79 行）之後、`allRecords` getter（約第 82 行）之前新增：

```dart

  /// 將 [incoming]（同一 playerId 的另一份存檔）合併進本份，回傳新的 [BannerStorage]。
  ///
  /// 逐卡池以 [mergeBackupRecords] 對齊去重；本機既有紀錄一律保留（含重疊那筆保留
  /// 本機版本）。[lastUpdated] 與帳號級 [languageCode] 取較新者（[incoming] 的
  /// lastUpdated 較新時採用 incoming 的）。playerId 不變。
  BannerStorage mergeWith(BannerStorage incoming) {
    final keys = {...banners.keys, ...incoming.banners.keys};
    final mergedBanners = <String, List<GachaRecord>>{
      for (final key in keys)
        key: mergeBackupRecords(
          banners[key] ?? const [],
          incoming.banners[key] ?? const [],
        ),
    };
    final incomingNewer = incoming.lastUpdated.isAfter(lastUpdated);
    return BannerStorage(
      playerId: playerId,
      languageCode: incomingNewer ? incoming.languageCode : languageCode,
      lastUpdated: incomingNewer ? incoming.lastUpdated : lastUpdated,
      banners: mergedBanners,
    );
  }
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/models/banner_storage_test.dart`
Expected: PASS（既有 + 4 個新 `mergeWith` 測試全綠）。

- [ ] **Step 5: commit**

```bash
git add lib/models/banner_storage.dart test/models/banner_storage_test.dart
git commit -m "feat(import): add BannerStorage.mergeWith via record alignment"
```

---

## Task 3: `_runImport` 合併邏輯 + `ImportResult` 欄位 + 摘要

把覆蓋改成合併、統計 added/duplicate、偏好只補空缺、active 保留本機，並改 `ImportResult` 欄位與下游摘要／log。此 Task 因欄位耦合需一次改到綠。

**Files:**
- Modify: `lib/state/update_progress.dart`（`ImportResult`）
- Modify: `lib/state/gacha_repository.dart`（`_runImport`、`importAccountsAndFetchItemImages`）
- Modify: `lib/widgets/update_progress_dialog.dart`（摘要呼叫）
- Modify: `lib/l10n/app_zh.arb` + `app_en` / `app_ja` / `app_zh_Hans`（`progressDoneImportSummary`）
- Test: `test/state/gacha_repository_test.dart`

- [ ] **Step 1: 改 `ImportResult` 欄位**

`lib/state/update_progress.dart`，把 `ImportResult`（約第 49-65 行）整段改為：

```dart
/// 帳號批次匯入的結果摘要。
class ImportResult {
  /// 建立 [ImportResult]。
  const ImportResult({
    required this.successAccounts,
    required this.addedRecords,
    required this.duplicateRecords,
    required this.failedUids,
  });

  /// 成功匯入的帳號數。
  final int successAccounts;

  /// 合併後新增的紀錄數（備份中本機原本沒有的）。
  final int addedRecords;

  /// 合併時已存在而略過的紀錄數（備份中本機原本就有的）。
  final int duplicateRecords;

  /// 匯入失敗的 UID 列表。
  final List<String> failedUids;
}
```

- [ ] **Step 2: 改寫 `_runImport` 的合併迴圈與計數**

`lib/state/gacha_repository.dart`，把 `_runImport` 開頭到帳號迴圈結束（約第 731-758 行）改為：

```dart
  Future<ImportResult> _runImport(AccountsBundle bundle) async {
    final storage = ref.read(gachaStorageProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);

    final newByUid = Map<String, BannerStorage>.from(state.byUid);
    final failed = <String>[];
    var addedRecords = 0;
    var duplicateRecords = 0;
    var successCount = 0;

    for (final account in bundle.accounts) {
      final incoming = account.data;
      try {
        final localBefore = newByUid[incoming.playerId];
        final toSave = localBefore == null
            ? incoming
            : localBefore.mergeWith(incoming);
        await storage.save(toSave);
        if (!ref.mounted) {
          return ImportResult(
            successAccounts: successCount,
            addedRecords: addedRecords,
            duplicateRecords: duplicateRecords,
            failedUids: failed,
          );
        }
        final added =
            toSave.allRecords.length - (localBefore?.allRecords.length ?? 0);
        addedRecords += added;
        duplicateRecords += incoming.allRecords.length - added;
        newByUid[incoming.playerId] = toSave;
        successCount++;
      } catch (_) {
        failed.add(incoming.playerId);
      }
    }
```

- [ ] **Step 3: 改別名為「只補空缺」**

同檔，把別名段（約第 760-770 行）改為：

```dart
    final currentSettings = ref.read(settingsProvider);
    final mergedAliases = Map<String, String>.from(currentSettings.uidAliases);
    for (final account in bundle.accounts) {
      final uid = account.data.playerId;
      if (failed.contains(uid)) continue;
      if (mergedAliases.containsKey(uid)) continue; // 本機已有別名 → 保留
      final a = account.alias?.trim();
      if (a != null && a.isNotEmpty) {
        mergedAliases[uid] = a;
      }
    }
```

- [ ] **Step 4: 改 `uidOrder` 為「本機不動、新 UID 接最後」**

同檔，把排序段（約第 772-780 行）改為：

```dart
    final localOrder = currentSettings.uidOrder;
    final localSet = localOrder.toSet();
    final appended = bundle.accounts
        .where((a) => !failed.contains(a.data.playerId))
        .map((a) => a.data.playerId)
        .where((uid) => !localSet.contains(uid))
        .toList(growable: false);
    final newOrder = [...localOrder, ...appended];
```

- [ ] **Step 5: 改 active 為「保留本機優先」**

同檔，把 active 計算段（約第 782-792 行，`final desiredActive = ...` 到 `final newActive = ...`）改為：

```dart
    final localActive = state.activeUid;
    final desiredActive = bundle.lastActiveUid;
    final newActive =
        (localActive != null && newByUid.containsKey(localActive))
        ? localActive
        : (desiredActive != null && newByUid.containsKey(desiredActive))
        ? desiredActive
        : (newByUid.isEmpty
              ? null
              : (newOrder.isEmpty ? newByUid.keys.first : newOrder.first));
```

- [ ] **Step 6: 改 unmount 提前返回、收尾 log 與最終 return**

同檔：

1. `applyImportedPreferences` 之後的 unmount 提前返回（約第 799-805 行）改為：

```dart
    if (!ref.mounted) {
      return ImportResult(
        successAccounts: successCount,
        addedRecords: addedRecords,
        duplicateRecords: duplicateRecords,
        failedUids: failed,
      );
    }
```

2. 收尾 log（約第 813-817 行）改為脫敏 + added/duplicate：

```dart
    _log.info(
      'import: success=$successCount '
      'failed=[${failed.map(sanitizeUid).join(",")}] '
      'added=$addedRecords duplicate=$duplicateRecords',
    );
```

3. 最終 return（約第 818-822 行）改為：

```dart
    return ImportResult(
      successAccounts: successCount,
      addedRecords: addedRecords,
      duplicateRecords: duplicateRecords,
      failedUids: failed,
    );
```

- [ ] **Step 7: 改 `importAccountsAndFetchItemImages` 的 emptyResult 與 log**

同檔：

1. `emptyResult`（約第 623-627 行）改為：

```dart
    const emptyResult = ImportResult(
      successAccounts: 0,
      addedRecords: 0,
      duplicateRecords: 0,
      failedUids: [],
    );
```

2. `import done` log（約第 657-661 行）改為：

```dart
      _importLog.info(
        'import done: success=${result.successAccounts} '
        'failed=[${result.failedUids.map(sanitizeUid).join(",")}] '
        'added=${result.addedRecords} duplicate=${result.duplicateRecords}',
      );
```

- [ ] **Step 8: 改 `progressDoneImportSummary` ARB（4 語系）**

`lib/l10n/app_zh.arb`（template），把 `progressDoneImportSummary` 的鍵值與其 `@progressDoneImportSummary` block（約第 170 行起）整段替換為：

```json
  "progressDoneImportSummary": "已合併 {accounts} 個帳號：新增 {added} 筆、已存在 {duplicate} 筆",
  "@progressDoneImportSummary": {
    "description": "Completion dialog line shown when the import-then-merge flow finishes: accounts merged, plus newly added vs already-present record counts.",
    "placeholders": {
      "accounts": { "type": "int" },
      "added": { "type": "int" },
      "duplicate": { "type": "int" }
    }
  },
```

`lib/l10n/app_en.arb`（約第 221-232 行）整段替換為：

```json
  "progressDoneImportSummary": "{accounts, plural, =1{Merged 1 account} other{Merged {accounts} accounts}}: {added} new, {duplicate} already present",
  "@progressDoneImportSummary": {
    "description": "Completion dialog line shown when the import-then-merge flow finishes: accounts merged, plus newly added vs already-present record counts.",
    "placeholders": {
      "accounts": { "type": "int" },
      "added": { "type": "int" },
      "duplicate": { "type": "int" }
    }
  },
```

`lib/l10n/app_ja.arb`（約第 221-232 行）整段替換為：

```json
  "progressDoneImportSummary": "{accounts} 件のアカウントを結合：新規 {added} 件、既存 {duplicate} 件",
  "@progressDoneImportSummary": {
    "description": "Completion dialog line shown when the import-then-merge flow finishes: accounts merged, plus newly added vs already-present record counts.",
    "placeholders": {
      "accounts": { "type": "int" },
      "added": { "type": "int" },
      "duplicate": { "type": "int" }
    }
  },
```

`lib/l10n/app_zh_Hans.arb`（約第 217-228 行）整段替換為：

```json
  "progressDoneImportSummary": "已合并 {accounts} 个账号：新增 {added} 条、已存在 {duplicate} 条",
  "@progressDoneImportSummary": {
    "description": "Completion dialog line shown when the import-then-merge flow finishes: accounts merged, plus newly added vs already-present record counts.",
    "placeholders": {
      "accounts": { "type": "int" },
      "added": { "type": "int" },
      "duplicate": { "type": "int" }
    }
  },
```

- [ ] **Step 9: 改完成對話框呼叫點**

`lib/widgets/update_progress_dialog.dart`（約第 229-235 行），把 `progressDoneImportSummary` 呼叫改為三參數：

```dart
            if (importSummary != null)
              Text(
                l.progressDoneImportSummary(
                  importSummary.successAccounts,
                  importSummary.addedRecords,
                  importSummary.duplicateRecords,
                ),
              )
```

- [ ] **Step 10: 重新產生 l10n**

Run: `fvm flutter gen-l10n`
Expected: 無錯誤；`progressDoneImportSummary(int accounts, int added, int duplicate)` 生成於 `lib/l10n/generated/`。

- [ ] **Step 11: 改既有 repo 測試到合併語意**

`test/state/gacha_repository_test.dart`：

(a) 檔頭 import 區（約第 8-9 行之間，`banner_storage.dart` import 之後）新增：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
```

(b) 測試 `importAccounts: per-UID overwrite preserves non-imported accounts`（約第 969-1053 行）：
- 改 test 名稱字串為 `importAccounts: merges into existing UID, preserves non-imported`。
- 把 `SharedPreferences.setMockInitialValues`（約第 990-992 行）改為帶 uidOrder/lastActiveUid 使結果決定性：

```dart
      SharedPreferences.setMockInitialValues({
        'pref.uidAliases': jsonEncode({'100000003': '另一支'}),
        'pref.uidOrder': jsonEncode(['100000001', '100000003']),
        'pref.lastActiveUid': '100000001',
      });
```

- 把註解 `// 100000001 overwritten`（約第 1041 行）改為 `// 100000001 merged: lastUpdated takes newer`（其下斷言值 `DateTime.utc(2026, 5, 12)` 不變）。
- 把 uidOrder 斷言（約第 1050 行）改為完整新順序：

```dart
      expect(settings.uidOrder, ['100000001', '100000003', '100000002']);
```

(c) 測試 `importAccounts: uidOrder merges imported order first, then remaining`（約第 1055-1122 行）：
- 改名為 `importAccounts: uidOrder keeps local order, appends new UIDs`。
- 把結尾註解與斷言（約第 1119-1120 行）改為：

```dart
      // local order [100000004, 100000001, 100000003] unchanged; new 100000002 appended
      expect(order, ['100000004', '100000001', '100000003', '100000002']);
```

(d) 測試 `importAccounts: bundle lastActiveUid switches active to it when imported`（約第 1189-1247 行）：
- 改名為 `importAccounts: keeps local active when local active is valid`。
- 把結尾兩個斷言（約第 1244-1245 行）改為：

```dart
      expect(container.read(gachaRepositoryProvider).activeUid, '200000001');
      expect(container.read(settingsProvider).lastActiveUid, '200000001');
```

(e) 在 (d) 的 `);`（約第 1247 行）之後、`group('logging instrumentation'`（約第 1248 行）之前，新增兩個測試：

```dart
  test(
    'importAccounts: adopts bundle lastActiveUid when local has no active',
    () async {
      final storage = GachaStorage(tempDir);
      final container = ProviderContainer(
        overrides: [
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(
              client: MockClient((_) async => http.Response('{}', 200)),
              cancel: () {},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final bundle = AccountsBundle(
        exportedAt: DateTime.utc(2026, 5, 12),
        appVersion: 'x',
        lastActiveUid: '200000002',
        accounts: [
          ExportedAccount(
            data: BannerStorage(
              playerId: '200000002',
              languageCode: 'zh-Hant',
              lastUpdated: DateTime.utc(2026, 5, 12),
              banners: const {'301': []},
            ),
          ),
        ],
      );

      await container
          .read(gachaRepositoryProvider.notifier)
          .debugImportOnly(bundle);

      expect(container.read(gachaRepositoryProvider).activeUid, '200000002');
    },
  );

  test(
    'importAccounts: merges records, never drops local, counts added/duplicate',
    () async {
      GachaRecord gr(int id, int sec) => GachaRecord(
        resourceId: id,
        qualityLevel: 5,
        resourceType: '角色',
        cardPoolType: '1',
        name: 'x',
        count: 1,
        time: DateTime(2026, 5, 21, 11, 0, sec),
      );

      final storage = GachaStorage(tempDir);
      await storage.save(
        BannerStorage(
          playerId: '100000001',
          languageCode: 'zh-Hant',
          lastUpdated: DateTime.utc(2026, 1, 1),
          banners: {
            '1': [gr(3, 30), gr(2, 20)],
          },
        ),
      );

      final container = ProviderContainer(
        overrides: [
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWithValue(_FakeCapture(null)),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(
              client: MockClient((_) async => http.Response('{}', 200)),
              cancel: () {},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(gachaRepositoryProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final bundle = AccountsBundle(
        exportedAt: DateTime.utc(2026, 5, 12),
        appVersion: 'x',
        lastActiveUid: null,
        accounts: [
          ExportedAccount(
            data: BannerStorage(
              playerId: '100000001',
              languageCode: 'zh-Hant',
              lastUpdated: DateTime.utc(2026, 5, 12),
              banners: {
                '1': [gr(2, 20), gr(1, 10)],
              },
            ),
          ),
        ],
      );

      final result = await container
          .read(gachaRepositoryProvider.notifier)
          .debugImportOnly(bundle);

      expect(result.addedRecords, 1); // id 1 是新的
      expect(result.duplicateRecords, 1); // id 2 已存在
      final merged = container
          .read(gachaRepositoryProvider)
          .byUid['100000001']!
          .banners['1']!
          .map((r) => r.resourceId)
          .toList();
      expect(merged, [3, 2, 1]); // 本機 id 3 沒被丟、降序
    },
  );
```

- [ ] **Step 12: 跑相關測試確認通過**

Run: `fvm flutter test test/state/gacha_repository_test.dart`
Expected: PASS（含新合併語意、新計數測試）。

- [ ] **Step 13: commit**

```bash
git add lib/state/update_progress.dart lib/state/gacha_repository.dart lib/widgets/update_progress_dialog.dart lib/l10n/ test/state/gacha_repository_test.dart
git commit -m "feat(import): merge records instead of overwriting account"
```

---

## Task 4: 共用 `showConfirmDialog`（抽取既有內聯 confirm）

`settings_page.dart` 的 `_refetchAll`／`_clearGallery` 已各自手寫無打字 confirm。抽成共用 helper（不重造輪子），新匯入確認也用它。

**Files:**
- Modify: `lib/widgets/dialogs/confirm_dialog.dart`（新增 `showConfirmDialog`）
- Modify: `lib/pages/settings_page.dart`（`_refetchAll`、`_clearGallery` 改用）
- Test: `test/widgets/dialogs/confirm_dialog_test.dart`

- [ ] **Step 1: 寫失敗測試**

`test/widgets/dialogs/confirm_dialog_test.dart`，在最後一個 `testWidgets` 之後、`main` 的結尾 `}`（約第 112 行）之前插入：

```dart

  testWidgets('showConfirmDialog: confirm enabled immediately, returns true', (
    tester,
  ) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  confirmed = await showConfirmDialog(
                    context: ctx,
                    title: 'Merge',
                    body: 'About to merge',
                    cancelLabel: 'Cancel',
                    confirmLabel: 'Import',
                    confirmIcon: Icons.check,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // 無 TextField；確認鍵一開始就 enabled
    expect(find.byType(TextField), findsNothing);
    final confirmBtn = find.widgetWithText(FilledButton, 'Import');
    expect(tester.widget<FilledButton>(confirmBtn).onPressed, isNotNull);

    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('showConfirmDialog: cancel returns false', (tester) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  confirmed = await showConfirmDialog(
                    context: ctx,
                    title: 'Merge',
                    body: 'About to merge',
                    cancelLabel: 'Cancel',
                    confirmLabel: 'Import',
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(confirmed, isFalse);
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/dialogs/confirm_dialog_test.dart`
Expected: FAIL（`showConfirmDialog` 未定義）。

- [ ] **Step 3: 新增 `showConfirmDialog`**

`lib/widgets/dialogs/confirm_dialog.dart`，在 `showConfirmTypeDialog` 函式（約第 29 行 `}` 結束）之後新增（檔案既有 import `theme/tokens.dart` 提供 `Theme.of(ctx).gacha`、`app_dialog.dart` 提供 `AppDialog`，不需新增 import）：

```dart

/// 顯示一個一般確認 dialog（無打字閘）。
/// 回傳值：true = 確認 / false = 取消 / null = 系統 dismiss。
/// [isDanger] 為 true 時確認鍵用 danger 紅；false 時用預設（中性）配色。
Future<bool?> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String body,
  required String cancelLabel,
  required String confirmLabel,
  IconData? confirmIcon,
  bool isDanger = false,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final tokens = Theme.of(ctx).gacha;
      final confirmStyle = isDanger
          ? FilledButton.styleFrom(
              backgroundColor: tokens.stateDanger,
              foregroundColor: Colors.white,
            )
          : null;
      return AppDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(cancelLabel),
          ),
          if (confirmIcon == null)
            FilledButton(
              style: confirmStyle,
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(confirmLabel),
            )
          else
            FilledButton.icon(
              style: confirmStyle,
              onPressed: () => Navigator.of(ctx).pop(true),
              icon: Icon(confirmIcon, size: 18),
              label: Text(confirmLabel),
            ),
        ],
      );
    },
  );
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/dialogs/confirm_dialog_test.dart`
Expected: PASS（既有打字測試 + 2 個新測試）。

- [ ] **Step 5: 把 `_refetchAll` 改用共用 helper**

`lib/pages/settings_page.dart`，把 `_refetchAll` 內的 `showDialog<bool>(...)`（約第 768-788 行）整段替換為：

```dart
    final ok = await showConfirmDialog(
      context: ctx,
      title: l.confirmRefetchItemImagesTitle,
      body: l.confirmRefetchItemImagesBody,
      cancelLabel: l.actionCancel,
      confirmLabel: l.confirmRefetchItemImagesConfirm,
      isDanger: true,
    );
```

- [ ] **Step 6: 把 `_clearGallery` 改用共用 helper**

同檔，把 `_clearGallery` 內的 `showDialog<bool>(...)`（約第 802-822 行）整段替換為：

```dart
    final ok = await showConfirmDialog(
      context: ctx,
      title: l.confirmClearGalleryCacheTitle,
      body: l.confirmClearGalleryCacheBody(sizeText),
      cancelLabel: l.actionCancel,
      confirmLabel: l.confirmClearGalleryCacheConfirm,
      isDanger: true,
    );
```

> `settings_page.dart` 已 import `confirm_dialog.dart`（既有 `showConfirmTypeDialog` 在用，第 37 行附近）。

- [ ] **Step 7: 跑分析 + 相關測試**

Run: `fvm flutter analyze`
Expected: `No issues found!`
Run: `fvm flutter test test/widgets/dialogs/confirm_dialog_test.dart`
Expected: PASS

- [ ] **Step 8: commit**

```bash
git add lib/widgets/dialogs/confirm_dialog.dart lib/pages/settings_page.dart test/widgets/dialogs/confirm_dialog_test.dart
git commit -m "refactor(dialogs): extract shared showConfirmDialog from inline confirms"
```

---

## Task 5: `_import` 改合併語意 + picker badge 中性化 + ARB

**Files:**
- Modify: `lib/pages/settings_page.dart`（`_import`）
- Modify: `lib/widgets/dialogs/accounts_picker_dialog.dart`（`_PickerRow` badge 色、dartdoc）
- Modify: `lib/l10n/app_zh.arb` + `app_en` / `app_ja` / `app_zh_Hans`（新增/改寫/刪除）
- Test: `test/widgets/dialogs/accounts_picker_dialog_test.dart`

- [ ] **Step 1: ARB — 改寫 `settingsImportConfirmIntro`（4 語系，僅改字串值）**

各 ARB 把 `settingsImportConfirmIntro` 的字串值改為（`@` block 不變）：

| 檔案 | 新值 |
|------|------|
| `app_zh.arb` | `"即將合併 {accounts} 個帳號（共 {records} 筆紀錄）："` |
| `app_en.arb` | `"About to merge {accounts} accounts ({records} records total):"` |
| `app_ja.arb` | `"{accounts} 個のアカウント（計 {records} 件の記録）を結合します："` |
| `app_zh_Hans.arb` | `"即将合并 {accounts} 个账号（共 {records} 条记录）："` |

- [ ] **Step 2: ARB — `settingsImportConfirmOverwriteHeader` → `settingsImportConfirmMergeHeader`（4 語系，改鍵名 + 值）**

各 ARB 把 `settingsImportConfirmOverwriteHeader` 整行（鍵名 + 值）替換為 `settingsImportConfirmMergeHeader`：

| 檔案 | 新行 |
|------|------|
| `app_zh.arb` | `  "settingsImportConfirmMergeHeader": "下列帳號將與本機資料合併，不會刪除既有紀錄：",` |
| `app_en.arb` | `  "settingsImportConfirmMergeHeader": "The following accounts will be merged with local data; existing records won't be deleted:",` |
| `app_ja.arb` | `  "settingsImportConfirmMergeHeader": "以下のアカウントはローカルデータと結合されます。既存の記録は削除されません：",` |
| `app_zh_Hans.arb` | `  "settingsImportConfirmMergeHeader": "以下账号将与本机数据合并，不会删除既有记录：",` |

- [ ] **Step 3: ARB — `settingsImportOverwriteBadge` → `settingsImportMergeBadge`（4 語系，改鍵名 + 值）**

各 ARB 把 `settingsImportOverwriteBadge` 整行替換為 `settingsImportMergeBadge`：

| 檔案 | 新行 |
|------|------|
| `app_zh.arb` | `  "settingsImportMergeBadge": "合併",` |
| `app_en.arb` | `  "settingsImportMergeBadge": "Merge",` |
| `app_ja.arb` | `  "settingsImportMergeBadge": "結合",` |
| `app_zh_Hans.arb` | `  "settingsImportMergeBadge": "合并",` |

- [ ] **Step 4: ARB — 刪除 `settingsImportConfirmWarning`（4 語系）**

各 ARB 刪除 `settingsImportConfirmWarning` 整行（該 key 無 `@` block）。

- [ ] **Step 5: 重新產生 l10n**

Run: `fvm flutter gen-l10n`
Expected: 無錯誤；`settingsImportMergeBadge`、`settingsImportConfirmMergeHeader` getter 生成，`settingsImportOverwriteBadge`／`settingsImportConfirmWarning`／`settingsImportConfirmOverwriteHeader` 三個 getter 消失。

- [ ] **Step 6: 改 `_import` badge → 合併**

`lib/pages/settings_page.dart`，把 picker entry 的 badge（約第 540-542 行）改為：

```dart
          badge: existing.contains(a.data.playerId)
              ? l.settingsImportMergeBadge
              : null,
```

- [ ] **Step 7: 改 `_import` 衝突區塊 + 移除警告 + 改確認 dialog**

同檔，把衝突標頭與警告組裝、確認呼叫（約第 594-617 行）整段改為：

```dart
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
```

> 此段移除了原本 `buf.writeln()` + `buf.write(l.settingsImportConfirmWarning)`（約第 604-605 行）與 `showConfirmTypeDialog(... expectedText: 'IMPORT' ...)`。其餘 `_import`（檔案讀取、picker、`filteredBundle`、`incoming/conflicts/preserved`、`settingsImportConfirmIntro` 前言與 `totalRecords` 計算、fire-and-forget 呼叫）不變。

- [ ] **Step 8: picker badge 改中性色 + dartdoc**

`lib/widgets/dialogs/accounts_picker_dialog.dart`，`_PickerRow` 的 badge `Container`（約第 217-232 行），把兩處 `tokens.stateDanger` 改為 `tokens.accentPrimary`：

```dart
          if (badge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: tokens.accentPrimary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                badge,
                style: TextStyle(
                  color: tokens.accentPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
```

同檔把 `AccountPickerEntry.badge` 的 dartdoc（約第 31-32 行「可選的紅色警示徽章文字…」）改為中性描述：

```dart
  /// 可選的徽章文字（如「合併」提示）。
```

- [ ] **Step 9: 改 picker 測試的 badge 文案**

`test/widgets/dialogs/accounts_picker_dialog_test.dart`：
- fixture `badge: '覆蓋'`（約第 26 行）改為 `badge: '合併'`。
- 測試 `overwrite badge shown only when entry.badge != null`（約第 162-167 行）改名為 `merge badge shown only when entry.badge != null`，並把斷言（約第 166 行）改為：

```dart
    expect(find.text('合併'), findsOneWidget);
```

- [ ] **Step 10: 跑分析 + 相關測試**

Run: `fvm flutter analyze`
Expected: `No issues found!`
Run: `fvm flutter test test/widgets/dialogs/accounts_picker_dialog_test.dart`
Expected: PASS

- [ ] **Step 11: commit**

```bash
git add lib/pages/settings_page.dart lib/widgets/dialogs/accounts_picker_dialog.dart lib/l10n/ test/widgets/dialogs/accounts_picker_dialog_test.dart
git commit -m "feat(import): non-destructive merge confirm flow and neutral badge"
```

---

## Task 6: 全套品質檢查

**Files:** 無（驗證）。

- [ ] **Step 1: 格式化**

Run: `fvm dart format lib/ test/`
Expected: 僅顯示被格式化的檔案數，無錯誤。

- [ ] **Step 2: 靜態分析**

Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: 全套測試**

Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 4: 確認舊 key／欄位無殘留引用**

Run: `git grep -n "settingsImportOverwriteBadge\|settingsImportConfirmWarning\|settingsImportConfirmOverwriteHeader" -- lib test`
Expected: 無命中（若 `lib/l10n/generated/` 仍有，表示 gen-l10n 未重跑）。

Run: `git grep -n "\.totalRecords" -- lib test`
Expected: 無命中（`ImportResult.totalRecords` 已全數改為 added/duplicate）。

- [ ] **Step 5: 若 format 有改動則 commit**

```bash
git add -A
git commit -m "style(import): apply dart format"
```

（若 Step 1 無改動則略過。）

---

## 完成後

- 本計畫不主動 `git push`。
- 26 個 Crowdin 空殼語系的新 key 由 Crowdin pipeline 後補，不在本計畫手動處理。
- 後續若要驗證實機行為（匯入兩份重疊備份看紀錄是否合併、確認框是否免打字），可用 `/run` 或 `/verify`。
