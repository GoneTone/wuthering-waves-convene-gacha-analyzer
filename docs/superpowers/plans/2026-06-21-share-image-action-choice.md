# 分享圖按鈕「儲存／複製」選擇 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓使用者在分享圖設定 dialog 內二選一「儲存圖片」或「複製圖片」，取代現在強制「存檔＋複製」一起做。

**Architecture:** 設定 dialog 回傳 `(options, action)` record；服務層把合併式 `exportShareImage` 拆成獨立的 `saveShareImage` / `copyShareImage`；`generateAndShareImage` 依 action 分流並沿用既有 `showExportResultDialog` 回報。任務以「先加新、後刪舊」排序，確保每個 task 結束時 `analyze` / `test` 全綠。

**Tech Stack:** Flutter、Dart、Riverpod、`super_clipboard`、`file_selector`、Flutter gen-l10n（4 核心 ARB）。

## Global Constraints

- 指令一律優先用 `fvm`（找不到才退回 `flutter` / `dart`）。
- 提交前依序通過：`fvm dart format lib/ test/`、`fvm flutter analyze`（`No issues found!`）、`fvm flutter test`（`All tests passed!`）。
- 不要主動 `git push`。
- 省略號用 ASCII `...`；CJK 文字用全形標點（含 ARB），英文半形。
- 所有新宣告（含 private）寫一行 `///` dartdoc；關鍵節點補 `Logger` log（沿用 `share.image` 命名）。
- commit message 一律英文、conventional commits 格式。
- l10n 只改核心 4 ARB：`app_zh.arb`、`app_zh_Hans.arb`、`app_en.arb`、`app_ja.arb`；generated 為 gitignore。

---

### Task 1: 新增 `ShareImageAction` enum

**Files:**
- Modify: `lib/models/share_image_options.dart`
- Test: `test/models/share_image_options_test.dart`

**Interfaces:**
- Consumes: 無。
- Produces: `enum ShareImageAction { save, copy }`（Task 4、Task 5 使用）。

- [ ] **Step 1: 寫失敗測試**

在 `test/models/share_image_options_test.dart` 的 `main()` 內最後加入：

```dart
  test('ShareImageAction 含 save 與 copy 兩值', () {
    expect(
      ShareImageAction.values,
      containsAll([ShareImageAction.save, ShareImageAction.copy]),
    );
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/models/share_image_options_test.dart`
Expected: FAIL（`ShareImageAction` undefined / 編譯錯誤）。

- [ ] **Step 3: 加入 enum**

在 `lib/models/share_image_options.dart` 檔尾（`ShareImageOptions` class 之後）加入：

```dart
/// 使用者在分享圖設定 dialog 選擇的終端動作。
enum ShareImageAction { save, copy }
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/models/share_image_options_test.dart`
Expected: PASS。

- [ ] **Step 5: 格式化並提交**

```bash
fvm dart format lib/ test/
git add lib/models/share_image_options.dart test/models/share_image_options_test.dart
git commit -m "feat(share): add ShareImageAction enum"
```

---

### Task 2: 新增 l10n 字串 `shareImageSaved` / `shareImageCopyFailed`

僅「加」字串（舊字串 Task 5 才移除），確保中間每步可編譯。

**Files:**
- Modify: `lib/l10n/app_zh.arb`、`lib/l10n/app_zh_Hans.arb`、`lib/l10n/app_en.arb`、`lib/l10n/app_ja.arb`

**Interfaces:**
- Produces：`l.shareImageSaved(path)`、`l.shareImageCopyFailed`（Task 5 helper 使用）。

- [ ] **Step 1: `app_zh.arb` 加字串**

在 `"shareImageCopiedOnly": "已複製到剪貼簿",`（約第 471 行）之後插入：

```json
  "shareImageSaved": "已存檔：{path}",
  "@shareImageSaved": {
    "placeholders": { "path": { "type": "String" } }
  },
  "shareImageCopyFailed": "複製到剪貼簿失敗",
```

- [ ] **Step 2: `app_zh_Hans.arb` 加字串**

在 `"shareImageCopiedOnly": "已复制到剪贴板",` 之後插入：

```json
  "shareImageSaved": "已保存：{path}",
  "@shareImageSaved": {
    "placeholders": { "path": { "type": "String" } }
  },
  "shareImageCopyFailed": "复制到剪贴板失败",
```

- [ ] **Step 3: `app_en.arb` 加字串**

在 `"shareImageCopiedOnly": "Copied to clipboard",` 之後插入：

```json
  "shareImageSaved": "Saved: {path}",
  "@shareImageSaved": {
    "placeholders": { "path": { "type": "String" } }
  },
  "shareImageCopyFailed": "Failed to copy to clipboard",
```

- [ ] **Step 4: `app_ja.arb` 加字串**

在 `"shareImageCopiedOnly": "クリップボードにコピーしました",` 之後插入：

```json
  "shareImageSaved": "保存しました：{path}",
  "@shareImageSaved": {
    "placeholders": { "path": { "type": "String" } }
  },
  "shareImageCopyFailed": "クリップボードへのコピーに失敗しました",
```

- [ ] **Step 5: 重新產生 l10n 並驗證**

Run: `fvm flutter gen-l10n && fvm flutter analyze`
Expected: gen-l10n 成功、`No issues found!`。

- [ ] **Step 6: 提交**

```bash
git add lib/l10n/app_zh.arb lib/l10n/app_zh_Hans.arb lib/l10n/app_en.arb lib/l10n/app_ja.arb
git commit -m "i18n(share): add shareImageSaved and shareImageCopyFailed strings"
```

---

### Task 3: 服務層新增 `saveShareImage` / `copyShareImage`

新增兩個獨立方法，**保留** `exportShareImage`（Task 5 才刪），沿用既有 seam 與 `share.image` logger。同時把服務測試改寫成覆蓋新方法。

**Files:**
- Modify: `lib/services/share_image_export.dart`
- Test: `test/services/share_image_export_test.dart`（整檔取代）

**Interfaces:**
- Consumes：既有 seam `shareSaveLocationPicker`、`shareClipboardWriter`、`shareFileWriter`、`resetShareImageExportSeams`、`_log`（`share.image`）、`sanitizeFsPath`。
- Produces：
  - `Future<String?> saveShareImage(Uint8List png, {required String suggestedName})` — 成功回實際路徑、取消回 null、寫檔失敗 rethrow。
  - `Future<bool> copyShareImage(Uint8List png)` — 成功 true、不支援/例外 false。

- [ ] **Step 1: 改寫服務測試（失敗）**

將 `test/services/share_image_export_test.dart` 整檔取代為：

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/share_image_export.dart';

void main() {
  final png = Uint8List.fromList([1, 2, 3, 4]);

  tearDown(resetShareImageExportSeams);

  group('saveShareImage', () {
    test('選了路徑 → 寫檔並回傳實際路徑', () async {
      final tmp = '${Directory.systemTemp.path}/share_save_a.png';
      shareSaveLocationPicker = (name) async => FileSaveLocation(tmp);

      final path = await saveShareImage(png, suggestedName: 'a.png');

      expect(path, tmp);
      expect(await File(tmp).readAsBytes(), png);
      await File(tmp).delete();
    });

    test('使用者取消 → 回傳 null', () async {
      shareSaveLocationPicker = (name) async => null;

      final path = await saveShareImage(png, suggestedName: 'a.png');

      expect(path, isNull);
    });

    test('已選路徑但寫檔失敗 → rethrow', () async {
      shareSaveLocationPicker = (name) async => FileSaveLocation('x.png');
      shareFileWriter = (p, bytes) async =>
          throw const FileSystemException('boom');

      expect(
        () => saveShareImage(png, suggestedName: 'a.png'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('copyShareImage', () {
    test('剪貼簿成功 → true', () async {
      shareClipboardWriter = (bytes) async => true;
      expect(await copyShareImage(png), isTrue);
    });

    test('平台不支援 → false', () async {
      shareClipboardWriter = (bytes) async => false;
      expect(await copyShareImage(png), isFalse);
    });

    test('剪貼簿例外 → false（吞掉）', () async {
      shareClipboardWriter = (bytes) async => throw Exception('boom');
      expect(await copyShareImage(png), isFalse);
    });
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/share_image_export_test.dart`
Expected: FAIL（`saveShareImage` / `copyShareImage` undefined）。

- [ ] **Step 3: 加入兩個新方法**

在 `lib/services/share_image_export.dart` 檔尾（`exportShareImage` 之後、暫不刪它）加入：

```dart
/// 讓使用者選位置存 PNG。成功回**實際存檔路徑**（供呼叫端顯示完整路徑）；
/// 使用者取消回 null（非錯誤）；已選路徑但寫檔失敗記 severe log 後 rethrow。
Future<String?> saveShareImage(
  Uint8List png, {
  required String suggestedName,
}) async {
  final loc = await shareSaveLocationPicker(suggestedName);
  if (loc == null) {
    _log.info('share image save cancelled');
    return null;
  }
  try {
    await shareFileWriter(loc.path, png);
  } catch (e, st) {
    _log.severe('share image write failed ${sanitizeFsPath(loc.path)}', e, st);
    rethrow;
  }
  _log.info(
    'share image saved ${sanitizeFsPath(loc.path)}; bytes=${png.length}',
  );
  return loc.path;
}

/// 把 PNG 寫入系統剪貼簿。成功回 true；平台不支援回 false；例外記 warning 後回 false。
Future<bool> copyShareImage(Uint8List png) async {
  try {
    final ok = await shareClipboardWriter(png);
    _log.info('share image copy clipboard=$ok bytes=${png.length}');
    return ok;
  } catch (e, st) {
    _log.warning('share image copy failed', e, st);
    return false;
  }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/services/share_image_export_test.dart`
Expected: PASS（6 tests）。

- [ ] **Step 5: 格式化、分析、提交**

```bash
fvm dart format lib/ test/
fvm flutter analyze
git add lib/services/share_image_export.dart test/services/share_image_export_test.dart
git commit -m "feat(share): add saveShareImage and copyShareImage service methods"
```

Expected analyze: `No issues found!`。

---

### Task 4: 設定 dialog 回傳 record + 兩顆動作鈕，helper 依 action 分流

dialog 回傳型別與 helper 消費端由同一份 record contract 耦合，故同一 task 一併改，確保編譯不中斷。

**Files:**
- Modify: `lib/widgets/dialogs/share_image_dialog.dart`
- Modify: `lib/widgets/share/share_image_helper.dart`
- Test: `test/widgets/dialogs/share_image_dialog_test.dart`（整檔取代）

**Interfaces:**
- Consumes：`ShareImageOptions`、`ShareImageAction`（Task 1）、`saveShareImage` / `copyShareImage`（Task 3）、`l.actionSaveImage` / `l.actionCopyImage` / `l.actionCancel`、`l.shareImageSaved` / `l.shareImageCopiedOnly` / `l.shareImageCopyFailed` / `l.shareImageFailed`（Task 2 與既有）、`showExportResultDialog`。
- Produces：
  - `Future<({ShareImageOptions options, ShareImageAction action})?> showShareImageDialog(...)`。
  - `generateAndShareImage(...)` 簽名不變（pages 不需改）。

- [ ] **Step 1: 改寫 dialog 測試（失敗）**

將 `test/widgets/dialogs/share_image_dialog_test.dart` 整檔取代為：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/share_image_options.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/share_image_dialog.dart';

/// 包一個按鈕開啟 dialog，把回傳寫進 [onResult]。
Widget _host(
  void Function(({ShareImageOptions options, ShareImageAction action})? r)
  onResult,
) {
  return MaterialApp(
    theme: buildDarkTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              onResult(
                await showShareImageDialog(
                  ctx,
                  initialBrightness: Brightness.dark,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('按「儲存圖片」→ action=save，預設深色 + 不顯示完整 UID', (t) async {
    ({ShareImageOptions options, ShareImageAction action})? result;
    await t.pumpWidget(_host((r) => result = r));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    await t.tap(find.text(l.actionSaveImage));
    await t.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.action, ShareImageAction.save);
    expect(result!.options.brightness, Brightness.dark);
    expect(result!.options.showFullUid, isFalse);
  });

  testWidgets('按「複製圖片」→ action=copy', (t) async {
    ({ShareImageOptions options, ShareImageAction action})? result;
    await t.pumpWidget(_host((r) => result = r));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    await t.tap(find.text(l.actionCopyImage));
    await t.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.action, ShareImageAction.copy);
  });

  testWidgets('取消回傳 null', (t) async {
    ({ShareImageOptions options, ShareImageAction action})? result = (
      options: const ShareImageOptions(),
      action: ShareImageAction.save,
    );
    await t.pumpWidget(_host((r) => result = r));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    await t.tap(find.text(l.actionCancel));
    await t.pumpAndSettle();

    expect(result, isNull);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/dialogs/share_image_dialog_test.dart`
Expected: FAIL（回傳型別不符 / 找不到 `actionSaveImage` 鈕）。

- [ ] **Step 3: 改 dialog 回傳型別**

`lib/widgets/dialogs/share_image_dialog.dart` 的 `showShareImageDialog` 改為：

```dart
/// 開啟分享圖選項 dialog。回傳 null 表示使用者取消；否則含選項與所選動作。
Future<({ShareImageOptions options, ShareImageAction action})?>
showShareImageDialog(
  BuildContext context, {
  required Brightness initialBrightness,
}) {
  return showDialog<({ShareImageOptions options, ShareImageAction action})>(
    context: context,
    builder: (_) => _ShareImageDialog(initialBrightness: initialBrightness),
  );
}
```

- [ ] **Step 4: 換底部按鈕**

把 `_ShareImageDialogState.build` 的 `actions:` 區塊整段換成：

```dart
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop((
            options: ShareImageOptions(
              brightness: _brightness,
              showFullUid: _showFullUid,
            ),
            action: ShareImageAction.copy,
          )),
          child: Text(l.actionCopyImage),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            options: ShareImageOptions(
              brightness: _brightness,
              showFullUid: _showFullUid,
            ),
            action: ShareImageAction.save,
          )),
          child: Text(l.actionSaveImage),
        ),
      ],
```

- [ ] **Step 5: 跑 dialog 測試確認通過**

Run: `fvm flutter test test/widgets/dialogs/share_image_dialog_test.dart`
Expected: PASS（3 tests）。

- [ ] **Step 6: 改 helper 依 action 分流**

`lib/widgets/share/share_image_helper.dart`：

(a) 刪除 `_shareResultToDialog(...)` 整個函式（含其 dartdoc）。

(b) 把 `generateAndShareImage` 內「取得 options」與「export + 結果」兩段改寫。原本：

```dart
  final options = await showShareImageDialog(
    context,
    initialBrightness: brightness,
  );
  if (options == null) return;
  if (!context.mounted) return;
```

改為：

```dart
  final selection = await showShareImageDialog(
    context,
    initialBrightness: brightness,
  );
  if (selection == null) return;
  if (!context.mounted) return;
  final options = selection.options;
  final action = selection.action;
```

原本 try 區塊內（`final png = ...` 之後）：

```dart
    final result = await exportShareImage(png, suggestedName: suggestedName);
    if (!context.mounted) return;
    final m = _shareResultToDialog(l, result);
    await showExportResultDialog(
      context,
      success: true,
      message: m.message,
      revealPath: m.revealPath,
    );
```

改為：

```dart
    if (!context.mounted) return;
    switch (action) {
      case ShareImageAction.save:
        final path = await saveShareImage(png, suggestedName: suggestedName);
        if (!context.mounted) return;
        // 使用者取消存檔對話框：不彈任何結果，保持安靜。
        if (path == null) return;
        await showExportResultDialog(
          context,
          success: true,
          message: l.shareImageSaved(path),
          revealPath: path,
        );
      case ShareImageAction.copy:
        final ok = await copyShareImage(png);
        if (!context.mounted) return;
        await showExportResultDialog(
          context,
          success: ok,
          message: ok ? l.shareImageCopiedOnly : l.shareImageCopyFailed,
        );
    }
```

`catch` / `finally` 區塊維持不變（渲染或存檔失敗 → `l.shareImageFailed` 失敗彈窗；`finally` dispose icon 與 preloaded）。`ShareImageAction` 透過既有的 `share_image_options.dart` import 取得，無需新增 import。

- [ ] **Step 7: 全量格式化、分析、測試**

Run:
```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
```
Expected: `No issues found!` 與 `All tests passed!`。

- [ ] **Step 8: 提交**

```bash
git add lib/widgets/dialogs/share_image_dialog.dart lib/widgets/share/share_image_helper.dart test/widgets/dialogs/share_image_dialog_test.dart
git commit -m "feat(share): let user choose save or copy in share dialog"
```

---

### Task 5: 清除死碼（舊合併 API 與死字串）

此時已無任何引用，安全移除。

**Files:**
- Modify: `lib/services/share_image_export.dart`
- Modify: `lib/l10n/app_zh.arb`、`lib/l10n/app_zh_Hans.arb`、`lib/l10n/app_en.arb`、`lib/l10n/app_ja.arb`

**Interfaces:**
- 移除：`exportShareImage`、`ShareExportStatus`、`ShareExportResult`；ARB 的 `shareImageSavedAndCopied`、`shareImageSavedOnly`、`shareImageGenerate`。

- [ ] **Step 1: 確認無殘留引用**

Run:
```bash
grep -rn "exportShareImage\|ShareExportStatus\|ShareExportResult\|shareImageGenerate\|shareImageSavedAndCopied\|shareImageSavedOnly" lib/ test/
```
Expected: 僅 `lib/services/share_image_export.dart` 自身定義行（`exportShareImage` 等）與 `lib/l10n/*.arb` 的待刪字串；不應出現在任何 helper / dialog / test 的「使用」位置。若出現使用位置，先回頭修正。

- [ ] **Step 2: 移除服務層死碼**

`lib/services/share_image_export.dart` 刪除：
- `enum ShareExportStatus { ... }`（含 dartdoc 與三個值）。
- `class ShareExportResult { ... }`（整段，含 dartdoc）。
- `Future<ShareExportResult> exportShareImage(...) async { ... }`（整段，含 dartdoc）。

保留：所有 seam（`shareSaveLocationPicker`、`shareClipboardWriter`、`shareFileWriter`）、`_defaultClipboardWriter` / `_defaultSaveLocationPicker` / `_defaultFileWriter`、`resetShareImageExportSeams`、`_log`、`saveShareImage`、`copyShareImage`。

- [ ] **Step 3: 移除 4 個 ARB 的死字串**

在 `app_zh.arb`、`app_zh_Hans.arb`、`app_en.arb`、`app_ja.arb` 各刪除這三組（含其 `@` metadata 區塊）：
- `"shareImageGenerate": ...`
- `"shareImageSavedAndCopied": ...` 與其 `"@shareImageSavedAndCopied": { ... }`
- `"shareImageSavedOnly": ...` 與其 `"@shareImageSavedOnly": { ... }`

保留 `shareImageCopiedOnly`、`shareImageSaved`、`shareImageCopyFailed`、`shareImageFailed`。注意刪除後務必確認 JSON 仍合法（逗號收尾正確）。

- [ ] **Step 4: 重新產生 l10n、分析、測試**

Run:
```bash
fvm flutter gen-l10n
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
```
Expected: gen-l10n 成功、`No issues found!`、`All tests passed!`。

- [ ] **Step 5: 提交**

```bash
git add lib/services/share_image_export.dart lib/l10n/app_zh.arb lib/l10n/app_zh_Hans.arb lib/l10n/app_en.arb lib/l10n/app_ja.arb
git commit -m "refactor(share): remove combined export API and dead strings"
```

---

## 收尾驗證（手動，非 commit gate）

- 點 OverviewPage / BannerPage 分享鈕 → 設定 dialog 底部顯示「取消／複製圖片／儲存圖片」三鈕。
- 選「儲存圖片」→ 只開系統存檔對話框；存檔成功彈「已存檔：<path>」+「開啟資料夾」；取消存檔不彈窗。
- 選「複製圖片」→ 只寫剪貼簿；成功彈「已複製到剪貼簿」；失敗彈「複製到剪貼簿失敗」。
- 主題（深／淺）與「顯示完整 UID」選項對兩個動作皆正確生效。
