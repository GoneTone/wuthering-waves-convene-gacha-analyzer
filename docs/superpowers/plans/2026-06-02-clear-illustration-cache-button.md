# 補回設定頁「清除立繪快取」按鈕 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 補回遷移時遺漏的設定頁「清除立繪快取」按鈕——刪除 cache 目錄下的角色立繪大圖、保留 icon 與 index，清完即時刷新用量。

**Architecture:** storage 層新增「只刪 `_illustration.` 檔」的方法；設定頁「圖片快取」區塊照原版在「強制重抓」左側加一顆 danger 按鈕，走既有 `AppDialog` 確認流程；四語 ARB 補回對應文案。

**Tech Stack:** Flutter、Riverpod、flutter l10n（ARB → generated）、`dart:io` File API。

設計來源：`docs/superpowers/specs/2026-06-02-clear-illustration-cache-button-design.md`

---

## File Structure

- `lib/services/item_image_index.dart` — `ItemImageIndexStorage` 新增 `deleteIllustrationCacheFiles()`。
- `lib/l10n/app_{zh,zh_Hans,en,ja}.arb` — 補回 `settingsImageCacheClearGallery` + `confirmClearGalleryCache{Title,Body,Confirm}`。
- `lib/pages/settings_page.dart` — `_ImageCacheSection` 加按鈕 + `_clearGallery()`；修正區塊 dartdoc。
- `test/services/item_image_index_test.dart` — 新增 `deleteIllustrationCacheFiles` 測試。

任務順序：Task 1（service，TDD）→ Task 2（ARB）→ Task 3（UI，串接 service + ARB）。

---

## Task 1: storage 新增 `deleteIllustrationCacheFiles()`（TDD）

**Files:**
- Test: `test/services/item_image_index_test.dart`
- Modify: `lib/services/item_image_index.dart`（`ItemImageIndexStorage` class，`wipeCacheDirectory()` 之後）

- [ ] **Step 1: 寫 failing test**

在 `test/services/item_image_index_test.dart` 的 `group('ItemImageIndexStorage', ...)` 內，緊接 `'wipeCacheDirectory 目錄不存在時建空目錄'` 測試之後新增：

```dart
    test('deleteIllustrationCacheFiles 只刪立繪、保留 icon、回傳刪除數', () async {
      await File('${tempDir.path}/1211_icon.png').writeAsBytes([1, 2, 3]);
      await File(
        '${tempDir.path}/1211_illustration.png',
      ).writeAsBytes([4, 5, 6]);
      await File(
        '${tempDir.path}/21010024_illustration.jpg',
      ).writeAsBytes([7, 8, 9]);

      final removed = await storage.deleteIllustrationCacheFiles();

      expect(removed, 2);
      expect(
        File('${tempDir.path}/1211_illustration.png').existsSync(),
        isFalse,
      );
      expect(
        File('${tempDir.path}/21010024_illustration.jpg').existsSync(),
        isFalse,
      );
      expect(File('${tempDir.path}/1211_icon.png').existsSync(), isTrue);
    });

    test('deleteIllustrationCacheFiles 目錄不存在回 0、不丟例外', () async {
      final parent = await Directory.systemTemp.createTemp('item_image_del_');
      addTearDown(() async {
        if (await parent.exists()) await parent.delete(recursive: true);
      });
      final dir = Directory('${parent.path}/missing');
      final s = ItemImageIndexStorage(dir);
      expect(await s.deleteIllustrationCacheFiles(), 0);
    });
```

- [ ] **Step 2: Run，確認 fail**

Run: `flutter test test/services/item_image_index_test.dart --plain-name "deleteIllustrationCacheFiles"`
Expected: FAIL —— compile error，`deleteIllustrationCacheFiles` 未定義。

- [ ] **Step 3: 實作 `deleteIllustrationCacheFiles`**

在 `lib/services/item_image_index.dart` 的 `ItemImageIndexStorage` class 內、`wipeCacheDirectory()` method（結尾 `}`）之後、class 結尾 `}` 之前，新增：

```dart
  /// 刪除 [baseDir] 內所有立繪大圖檔（檔名含 `_illustration.`），保留 icon 小圖；
  /// 回傳刪除的檔案數。index 不動 —— 下次打開角色詳情會 lazy 重新下載立繪。
  Future<int> deleteIllustrationCacheFiles() async {
    if (!await baseDir.exists()) return 0;
    var deleted = 0;
    await for (final entity in baseDir.list()) {
      if (entity is! File) continue;
      if (entity.path.contains('_illustration.')) {
        await entity.delete();
        deleted++;
      }
    }
    _log.info('deleteIllustrationCacheFiles: removed $deleted files');
    return deleted;
  }
```

- [ ] **Step 4: Run，確認 pass**

Run: `flutter test test/services/item_image_index_test.dart`
Expected: PASS（含新增兩案例與原有案例）。

- [ ] **Step 5: Commit**

```bash
git add lib/services/item_image_index.dart test/services/item_image_index_test.dart
git commit -m "feat(storage): add deleteIllustrationCacheFiles (keep icons)"
```

---

## Task 2: 補回四語 ARB 文案

**Files:**
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_zh_Hans.arb`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_ja.arb`

- [ ] **Step 1: 四語各新增四個 key**

在每個檔案的 `"settingsImageCacheFailed"` 之 `@`-metadata block（結尾 `},`）**後面**插入對應片段。

`lib/l10n/app_zh.arb`：

```json
  "settingsImageCacheClearGallery": "清除立繪快取",
  "confirmClearGalleryCacheTitle": "清除立繪快取？",
  "confirmClearGalleryCacheBody": "將刪除約 {size} 的角色立繪圖檔，小圖示快取保留。下次打開角色詳情時會重新下載。",
  "@confirmClearGalleryCacheBody": {
    "placeholders": {
      "size": { "type": "String" }
    }
  },
  "confirmClearGalleryCacheConfirm": "清除",
```

`lib/l10n/app_zh_Hans.arb`：

```json
  "settingsImageCacheClearGallery": "清除立绘缓存",
  "confirmClearGalleryCacheTitle": "清除立绘缓存？",
  "confirmClearGalleryCacheBody": "将删除约 {size} 的角色立绘图片，小图标缓存保留。下次打开角色详情时会重新下载。",
  "@confirmClearGalleryCacheBody": {
    "placeholders": {
      "size": {
        "type": "String"
      }
    }
  },
  "confirmClearGalleryCacheConfirm": "清除",
```

`lib/l10n/app_en.arb`：

```json
  "settingsImageCacheClearGallery": "Clear illustration cache",
  "confirmClearGalleryCacheTitle": "Clear illustration cache?",
  "confirmClearGalleryCacheBody": "This deletes about {size} of character illustration images. The icon cache is kept; they will be re-downloaded next time you open a character's details.",
  "@confirmClearGalleryCacheBody": {
    "placeholders": {
      "size": {
        "type": "String"
      }
    }
  },
  "confirmClearGalleryCacheConfirm": "Clear",
```

`lib/l10n/app_ja.arb`：

```json
  "settingsImageCacheClearGallery": "立ち絵キャッシュを削除",
  "confirmClearGalleryCacheTitle": "立ち絵キャッシュを削除しますか？",
  "confirmClearGalleryCacheBody": "約 {size} のキャラクター立ち絵画像を削除します。アイコンキャッシュは保持され、次回キャラクター詳細を開いたときに再ダウンロードされます。",
  "@confirmClearGalleryCacheBody": {
    "placeholders": {
      "size": {
        "type": "String"
      }
    }
  },
  "confirmClearGalleryCacheConfirm": "削除",
```

- [ ] **Step 2: 重新產生 l10n**

Run: `flutter gen-l10n`
Expected: 無錯誤；generated 重新產生。

- [ ] **Step 3: 驗證 generated 出現新 getter**

Run: `grep -rn "settingsImageCacheClearGallery\|confirmClearGalleryCacheBody" lib/l10n/generated/app_localizations.dart`
Expected: 找到 `String get settingsImageCacheClearGallery;` 與 `String confirmClearGalleryCacheBody(String size);`。

- [ ] **Step 4: 靜態分析**

Run: `flutter analyze`
Expected: `No issues found!`。

- [ ] **Step 5: Commit**

```bash
git add lib/l10n/
git commit -m "i18n(settings): restore clear-illustration-cache strings"
```

---

## Task 3: 設定頁加「清除立繪快取」按鈕

**Files:**
- Modify: `lib/pages/settings_page.dart`（`_ImageCacheSection`：dartdoc、`Wrap` children、新增 `_clearGallery()`）

- [ ] **Step 1: 修正區塊 dartdoc**

把 `lib/pages/settings_page.dart` `_ImageCacheSection` 上方的 dartdoc：

```dart
/// 圖片快取區塊：顯示用量（icon / gallery / 總計），提供「清除詳情圖快取」
/// 與「強制重抓物品圖片」按鈕。
```

替換為：

```dart
/// 圖片快取區塊：顯示用量（小圖示 / 立繪 / 總計），提供「清除立繪快取」
/// 與「強制重抓物品圖片」按鈕。
```

- [ ] **Step 2: 在 `Wrap` 內、強制重抓左側加清除按鈕**

把 `_ImageCacheSectionState.build` 內的 `Wrap`（目前 children 只含「強制重抓」的 `Tooltip(...)`）：

```dart
        Wrap(
          spacing: AppSpacing.s,
          runSpacing: AppSpacing.s,
          children: [
            Tooltip(
              message: !hasData ? l.settingsRefetchItemImagesEmpty : '',
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: tokens.stateDanger,
                  foregroundColor: Colors.white,
                ),
                onPressed: (!hasData || progress != null)
                    ? null
                    : () => _refetchAll(context),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l.settingsRefetchItemImagesTitle),
              ),
            ),
          ],
        ),
```

替換為（在最前面插入清除立繪按鈕，強制重抓不變）：

```dart
        Wrap(
          spacing: AppSpacing.s,
          runSpacing: AppSpacing.s,
          children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: tokens.stateDanger,
                foregroundColor: Colors.white,
              ),
              onPressed:
                  (progress != null ||
                      usageAsync.when(
                        loading: () => true,
                        error: (e, _) => false,
                        data: (u) => u.illustrationBytes <= 0,
                      ))
                  ? null
                  : () => _clearGallery(context),
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: Text(l.settingsImageCacheClearGallery),
            ),
            Tooltip(
              message: !hasData ? l.settingsRefetchItemImagesEmpty : '',
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: tokens.stateDanger,
                  foregroundColor: Colors.white,
                ),
                onPressed: (!hasData || progress != null)
                    ? null
                    : () => _refetchAll(context),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l.settingsRefetchItemImagesTitle),
              ),
            ),
          ],
        ),
```

- [ ] **Step 3: 新增 `_clearGallery()`**

在 `_ImageCacheSectionState` class 內、`_refetchAll()` method 之後新增：

```dart
  /// 顯示「清除立繪快取」確認 dialog，確認後刪除立繪快取並刷新用量顯示。
  Future<void> _clearGallery(BuildContext ctx) async {
    final l = AppLocalizations.of(ctx)!;
    final usage = ref.read(itemImageCacheUsageProvider).value;
    final sizeText = usage == null ? '' : formatBytes(usage.illustrationBytes);
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (d) => AppDialog(
        title: Text(l.confirmClearGalleryCacheTitle),
        content: Text(l.confirmClearGalleryCacheBody(sizeText)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(d).gacha.stateDanger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(d).pop(true),
            child: Text(l.confirmClearGalleryCacheConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final removed = await ref
          .read(itemImageIndexStorageProvider)
          .deleteIllustrationCacheFiles();
      if (!ctx.mounted) return;
      ref.invalidate(itemImageCacheUsageProvider);
      Logger(
        'item_image.usage',
      ).info('user cleared illustration cache: $removed files');
    } catch (e, st) {
      Logger('item_image.usage').warning('clear illustration cache failed', e, st);
      if (!ctx.mounted) return;
      ref.invalidate(itemImageCacheUsageProvider);
      ScaffoldMessenger.of(
        ctx,
      ).showSnackBar(SnackBar(content: Text(l.settingsImageCacheFailed)));
    }
  }
```

（`itemImageIndexStorageProvider`、`itemImageCacheUsageProvider`、`AppDialog`、`formatBytes`、`Logger`、`Theme.of(d).gacha` 皆為同檔既有 import / 既用符號。）

- [ ] **Step 4: 全套品質檢查**

Run: `dart format lib/ test/ && flutter analyze && flutter test`
Expected: `No issues found!` 與 `All tests passed!`。

- [ ] **Step 5: 人工驗收（執行者自行確認）**

啟動 app → 設定頁「圖片快取」：在「強制重抓物品圖片」左側出現紅色「清除立繪快取」按鈕；有立繪快取且無更新進行中時可按；按下確認後立繪用量歸零、小圖示用量不變；之後打開角色詳情能重新下載立繪。

- [ ] **Step 6: Commit**

```bash
git add lib/pages/settings_page.dart
git commit -m "feat(settings): restore clear-illustration-cache button"
```

---

## Self-Review 紀錄

- **Spec 覆蓋**：service `deleteIllustrationCacheFiles`（Task 1）、ARB 四語（Task 2）、UI 按鈕 + `_clearGallery` + dartdoc 修正（Task 3）、行為「只刪檔保留 index」（Task 1 不動 index）、測試（Task 1）——皆有對應。按鈕配色 / icon / 排序 / disable 條件 / 確認鈕 danger 配色 / catch 內 invalidate 全部照原版（Task 3 Step 2-3）。
- **Type consistency**：`deleteIllustrationCacheFiles()` → `Future<int>` 在 Task 1 定義、Task 3 呼叫一致；`settingsImageCacheClearGallery`（無參）、`confirmClearGalleryCacheBody(String size)`、`confirmClearGalleryCacheTitle` / `Confirm`（無參）在 Task 2 定義、Task 3 使用一致；`itemImageIndexStorageProvider` / `itemImageCacheUsageProvider` / `ItemImageCacheUsage.illustrationBytes` 沿用現有。
- **No placeholders**：每步皆含完整程式碼與確切指令。
- **YAGNI**：未加「清 icon」按鈕、未動強制重抓、未抽 `_illustration.` 常數、未做「連 index url 一起清」。
