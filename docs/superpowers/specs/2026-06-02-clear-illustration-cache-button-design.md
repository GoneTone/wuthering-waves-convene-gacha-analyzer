# 補回設定頁「清除立繪快取」按鈕

- 日期：2026-06-02
- 分支：feat/wuwa-migration
- 狀態：設計定稿，待 review

## 背景與問題

原神版本（main）設定頁的「圖片快取」區塊（`_ImageCacheSection`）提供三樣東西：用量顯示、**「清除詳情圖快取」按鈕**、「強制重抓物品圖片」按鈕。

鳴潮遷移後，同區塊只剩用量顯示（小圖示 / 立繪 / 總計）與「強制重抓物品圖片」按鈕，**「清除詳情圖快取」整串被漏掉**：UI 按鈕、`_clearGallery()` 方法、storage 刪除方法、四語 ARB 文案都沒被移植。

佐證這是遷移遺漏而非刻意移除：

1. `lib/pages/settings_page.dart:676` 該區塊 dartdoc 仍寫「提供『清除詳情圖快取』與『強制重抓物品圖片』按鈕」，但實作只剩後者。
2. 用量顯示仍列「立繪」大小（`illustrationBytes`），使用者看得到大小卻沒有任何入口能清除——半套狀態。

本 spec 補回此功能，並適配鳴潮的快取目錄結構與術語（「立繪」）。

## 目標

在設定頁「圖片快取」區塊補回「清除立繪快取」按鈕：清除 cache 目錄下的角色立繪大圖檔（保留 icon 小圖與 index），清完即時刷新用量顯示。行為對齊原神 `deleteGalleryCacheFiles`：只刪檔、保留 index url，下次打開角色詳情時 lazy 重新下載。

## 設計

### 1. Service 層（`lib/services/item_image_index.dart`）

在 `ItemImageIndexStorage` 新增 `deleteIllustrationCacheFiles()`，與既有 `wipeCacheDirectory()` 同層，共用既有的 `_illustration.` 檔名約定（與 `lib/state/item_image_cache_usage.dart:48` 的用量掃描一致）：

```dart
/// 刪除 cache 目錄下所有立繪大圖檔（檔名含 `_illustration.`），保留 icon 小圖；
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

不動 `ItemImageIndex`（保留各 entry 的 illustrationUrl），與「強制重抓」（`resetAll` 清 index + 整個 cache 目錄）區隔清楚。

### 2. UI（`lib/pages/settings_page.dart` `_ImageCacheSection`）

**按鈕設計完全照原版**：在現有 `Wrap` 內、於「強制重抓物品圖片」**左側**新增一顆 `FilledButton.icon`，與原版（及鳴潮現有的「強制重抓」）同款 danger 紅底白字、icon `Icons.delete_sweep_outlined`，順序為「清除立繪快取 → 強制重抓物品圖片」：

```dart
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
```

新增 `_clearGallery()`，照原版 + 同檔既有 `_refetchAll()` 的 `AppDialog` 流程（CLAUDE.md：dialog 一律 `AppDialog`），確認鈕同為 danger 紅底白字：

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
    Logger('item_image.usage').info('user cleared illustration cache: $removed files');
  } catch (e, st) {
    Logger('item_image.usage').warning('clear illustration cache failed', e, st);
    if (!ctx.mounted) return;
    ref.invalidate(itemImageCacheUsageProvider);
    ScaffoldMessenger.of(ctx)
        .showSnackBar(SnackBar(content: Text(l.settingsImageCacheFailed)));
  }
}
```

按鈕配色、icon、排序、disable 條件（`progress` 進行中或 `illustrationBytes <= 0` 即 disable）、確認鈕 danger 配色、catch 內也 `invalidate` 用量——全部對齊原版 `_clearGallery`；差別僅在 provider 名（`itemImageCacheUsageProvider` / `itemImageIndexStorageProvider`）、方法名（`deleteIllustrationCacheFiles`）、欄位（`illustrationBytes`）與術語（「立繪」）。

順手把該區塊 dartdoc（`settings_page.dart:676`）更新為「提供『清除立繪快取』與『強制重抓物品圖片』按鈕」，與實作一致。

### 3. ARB 四語（`lib/l10n/app_{zh,zh_Hans,en,ja}.arb`）

新增四個 key（`confirmClearGalleryCacheBody` 帶 `size` string placeholder）：

| key | app_zh（繁中） | app_zh_Hans（簡中） | app_en | app_ja |
|---|---|---|---|---|
| `settingsImageCacheClearGallery` | 清除立繪快取 | 清除立绘缓存 | Clear illustration cache | 立ち絵キャッシュを削除 |
| `confirmClearGalleryCacheTitle` | 清除立繪快取？ | 清除立绘缓存？ | Clear illustration cache? | 立ち絵キャッシュを削除しますか？ |
| `confirmClearGalleryCacheBody` | 將刪除約 {size} 的角色立繪圖檔，小圖示快取保留。下次打開角色詳情時會重新下載。 | 将删除约 {size} 的角色立绘图片，小图标缓存保留。下次打开角色详情时会重新下载。 | This deletes about {size} of character illustration images. The icon cache is kept; they will be re-downloaded next time you open a character's details. | 約 {size} のキャラクター立ち絵画像を削除します。アイコンキャッシュは保持され、次回キャラクター詳細を開いたときに再ダウンロードされます。 |
| `confirmClearGalleryCacheConfirm` | 清除 | 清除 | Clear | 削除 |

`confirmClearGalleryCacheBody` 的 placeholder：`{ "size": { "type": "String" } }`。新增後重跑 l10n codegen 讓 `app_localizations*.dart` 更新。

### 4. 測試（`test/services/item_image_index_test.dart`）

新增案例：在臨時 cache 目錄建 `1_icon.png`、`1_illustration.png`、`2_illustration.jpg`，呼叫 `deleteIllustrationCacheFiles()`，斷言：

- 回傳值 == 2；
- `1_illustration.png`、`2_illustration.jpg` 已不存在；
- `1_icon.png` 仍存在；
- 空目錄 / 不存在目錄呼叫回傳 0、不丟例外。

## 不做（YAGNI）

- 不加「清除 icon 快取」按鈕（原神也只清 gallery；icon 走「強制重抓」整批重建）。
- 不動「強制重抓物品圖片」既有行為。
- 不抽 `_illustration.` 字面常數（沿用既有 `item_image_cache_usage.dart` 的字面風格）。
- 清立繪不動 index url（不做「連 url 一起清」的選項）。

## 驗收

1. `dart format lib/ test/`
2. `flutter analyze` → `No issues found!`
3. `flutter test` → `All tests passed!`
4. 邏輯確認：設定頁「圖片快取」區塊出現「清除立繪快取」按鈕（有立繪快取且無更新進行中時可按）；按下確認後立繪檔被刪、icon 保留、用量的「立繪」歸零、「小圖示」不變；之後打開角色詳情能重新下載立繪。

## 影響檔案

- `lib/services/item_image_index.dart`（新增 `deleteIllustrationCacheFiles()`）
- `lib/pages/settings_page.dart`（`_ImageCacheSection` 加按鈕 + `_clearGallery()`；修正區塊 dartdoc）
- `lib/l10n/app_zh.arb`、`app_zh_Hans.arb`、`app_en.arb`、`app_ja.arb`（新增四個 key）
- `test/services/item_image_index_test.dart`（新增刪立繪測試）
