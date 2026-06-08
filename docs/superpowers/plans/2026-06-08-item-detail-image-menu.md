# 物品詳情圖片右上角選單 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在物品詳情 dialog 的圖片區右上角加一個溢出選單，提供「複製圖片／儲存圖片／重抓圖片」三個動作。

**Architecture:** 新增可測試的 `item_image_save` 服務（PNG 編碼 + 存檔 + 寫剪貼簿，仿 `share_image_export.dart` 的 seam 結構）；在 `gacha_item_detail_dialog.dart` 的 `_ImageReady` 分支疊一顆 `PopupMenuButton`，呼叫服務並以 `SnackBar` 回報；重抓沿用既有 `_fetchAndCache`／`_captureLuckdraw`，新增 icon 重抓並以全域 cache revision 讓 dialog 標題縮圖與記錄列表縮圖同步刷新。

**Tech Stack:** Flutter / Riverpod / `file_selector`（存檔對話框）/ `super_clipboard`（剪貼簿）/ `dart:ui`（PNG 編碼）/ `image`（測試造 PNG）/ ARB l10n。

---

## 背景與既有資產（實作前必讀）

- 目標檔：`lib/widgets/dialogs/gacha_item_detail_dialog.dart`。圖片區由 `_buildCurrentImageArea` 依 `_ImageLoadState`（`_ImageReady`／`_ImageLoading`／`_ImageFailed`）切換。
- chip 三類（`_ChipKind`）：`skin`（HTTP 下載，`_fetchAndCache`）、`luckdraw`（WebView 擷取，`_captureLuckdraw`）、`icon`（更新時預抓、永遠 ready）。
- 既有 `_retryEntry` 只在 `_ImageFailed` 由「重試」按鈕觸發，本計畫會以新的 `_refetchEntry` 取代它（涵蓋三類 + 快取失效處理）。
- 存檔對照組：`lib/services/share_image_export.dart` + `test/services/share_image_export_test.dart`，示範 `getSaveLocation` / `super_clipboard` / `@visibleForTesting` seam / `reset...Seams()` 寫法。本計畫的新服務照抄此結構。
- PNG 編碼參考：`lib/services/share_image_renderer.dart`（`toByteData(format: ui.ImageByteFormat.png)`）、`lib/widgets/share/preloaded_item_images.dart`（`ui.instantiateImageCodec` + `getNextFrame`）。
- 快取路徑：`itemIconCacheFile`／`itemIllustrationCacheFile`／`itemLuckdrawCacheFile`（`lib/services/item_image_index.dart`）。原子寫檔：`writeImageFileAtomic`（同檔）。
- 列表縮圖 widget：`lib/widgets/gacha_item_icon.dart` 的 `GachaItemIcon`，`ref.watch(itemImageIndexProvider)` 後以 **無 key 的** `Image.file(file)` 顯示。
- log 脫敏：`sanitizeFsPath`／`sanitizeUrl`（`lib/services/log_sanitize.dart`）。

### 關鍵技術決策：快取失效

重抓 ready 圖時快取路徑不變（skin 由 URL 推導、luckdraw 固定、icon 同 URL）。Flutter `ImageCache` 以 path 為 key，已掛載且 key 不變的 `Image` 不會自動重抓。處理策略分兩塊：

1. **dialog 圖片區**：重抓時 `setState` 切到 `_ImageLoading`（spinner），再回 `_ImageReady`。loading 與 ready 是不同 widget 型別 → element 重建 → 新的 `Image` 會重新 resolve。只要重抓前 `imageCache.evict(FileImage(file))`，重 resolve 就會讀到磁碟新檔。**圖片區的 `Image` key 維持 `ValueKey(file.path)` 不變**（既有測試靠它定位）。
2. **dialog 標題縮圖 + 記錄列表縮圖（僅 icon 重抓需要）**：這兩處的 `Image` 一直掛載、不經 loading 重建，evict 後也不會自己重抓。新增全域 `itemImageCacheRevisionProvider`（`StateProvider<int>`），讓標題與 `GachaItemIcon` 的 `Image.file` key 帶上 revision；icon 重抓成功後 `revision++` → 兩處 `Image` 換 key 重建 → 配合 evict 讀到新檔。skin／luckdraw 重抓**不**動 revision（它們只出現在 dialog 圖片區，已由策略 1 處理）。

---

## File Structure

| 檔案 | 動作 | 責任 |
|---|---|---|
| `lib/services/item_image_save.dart` | 建立 | PNG 編碼（`encodeImageFileToPng`）、存檔（`saveImagePng`）、寫剪貼簿（`copyImagePngToClipboard`）+ 測試 seam |
| `test/services/item_image_save_test.dart` | 建立 | 上述服務的單元測試 |
| `lib/state/item_image_index.dart` | 修改 | 新增 `itemImageCacheRevisionProvider` |
| `lib/widgets/gacha_item_icon.dart` | 修改 | `Image.file` 加上 revision key |
| `lib/widgets/dialogs/gacha_item_detail_dialog.dart` | 修改 | 圖片區疊選單按鈕；新增 `_refetchEntry`／`_refetchIcon`／save／copy handler；標題縮圖加 revision key |
| `lib/l10n/app_zh.arb` 等四檔 | 修改 | 新增 7 條字串 |
| `lib/l10n/generated/*` | 產生 | `gen-l10n` 自動產生（勿手改） |
| `test/widgets/dialogs/gacha_item_detail_dialog_test.dart` | 修改 | 選單存在性 + 重抓行為測試 |

---

## Task 1：新增 item_image_save 服務（PNG 編碼 + 存檔 + 剪貼簿）

**Files:**
- Create: `lib/services/item_image_save.dart`
- Test: `test/services/item_image_save_test.dart`

- [ ] **Step 1: 先寫 bytes 處理的失敗測試（存檔 / 剪貼簿，走 seam）**

`test/services/item_image_save_test.dart`：

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_save.dart';

void main() {
  final png = Uint8List.fromList([1, 2, 3, 4]);

  tearDown(resetItemImageSaveSeams);

  test('saveImagePng：使用者選了路徑 → 寫檔並回 true', () async {
    final tmp = '${Directory.systemTemp.path}/item_save_a.png';
    itemImageSaveLocationPicker = (name) async => FileSaveLocation(tmp);

    final ok = await saveImagePng(png, suggestedName: 'a.png');

    expect(ok, isTrue);
    expect(await File(tmp).readAsBytes(), png);
    await File(tmp).delete();
  });

  test('saveImagePng：使用者取消 → 回 false、不寫檔', () async {
    itemImageSaveLocationPicker = (name) async => null;

    final ok = await saveImagePng(png, suggestedName: 'a.png');

    expect(ok, isFalse);
  });

  test('copyImagePngToClipboard：clipboard 成功 → 回 true', () async {
    Uint8List? captured;
    itemImageClipboardWriter = (bytes) async {
      captured = bytes;
      return true;
    };

    final ok = await copyImagePngToClipboard(png);

    expect(ok, isTrue);
    expect(captured, png);
  });

  test('copyImagePngToClipboard：clipboard 不支援 → 回 false', () async {
    itemImageClipboardWriter = (bytes) async => false;

    final ok = await copyImagePngToClipboard(png);

    expect(ok, isFalse);
  });
}
```

- [ ] **Step 2: 跑測試確認 fail**

Run: `fvm flutter test test/services/item_image_save_test.dart`
Expected: 編譯失敗（`item_image_save.dart` 不存在 / 函式未定義）。

- [ ] **Step 3: 實作服務**

`lib/services/item_image_save.dart`：

```dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 物品圖片儲存／複製流程的 logger（命名空間 gacha.itemimage.save）。
final _log = Logger('gacha.itemimage.save');

/// 把任意格式的本地圖檔解碼後重新編碼成 PNG bytes；任何失敗（讀檔／解碼／編碼）
/// 回 null，呼叫端據此提示失敗。
///
/// 統一輸出 PNG：來源可能是 webp／jpg（icon／造型副檔名隨 URL），轉 PNG 後
/// 存檔與複製到剪貼簿格式一致。
Future<Uint8List?> encodeImageFileToPng(File file) async {
  try {
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (data == null) {
      _log.warning('encode png null path=${sanitizeFsPath(file.path)}');
      return null;
    }
    return data.buffer.asUint8List();
  } catch (e, st) {
    _log.warning('encode png failed path=${sanitizeFsPath(file.path)}', e, st);
    return null;
  }
}

/// 預設存檔位置選擇器：開啟系統 save dialog，回傳使用者選擇的路徑（取消為 null）。
Future<FileSaveLocation?> _defaultSaveLocationPicker(String name) =>
    getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG', extensions: ['png']),
      ],
    );

/// 預設剪貼簿寫入：寫 PNG 到系統剪貼簿，回傳是否成功（平台不支援回 false）。
Future<bool> _defaultClipboardWriter(Uint8List png) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return false;
  final item = DataWriterItem();
  item.add(Formats.png(png));
  await clipboard.write([item]);
  return true;
}

/// 預設檔案寫入實作：直接寫入磁碟。
Future<void> _defaultFileWriter(String path, Uint8List png) =>
    File(path).writeAsBytes(png);

/// 存檔位置選擇器 seam，讓 flutter test 不開啟真實系統 dialog。
@visibleForTesting
Future<FileSaveLocation?> Function(String suggestedName)
itemImageSaveLocationPicker = _defaultSaveLocationPicker;

/// 剪貼簿寫入 seam，讓 flutter test 不碰真實剪貼簿（SystemClipboard.instance 為 null）。
@visibleForTesting
Future<bool> Function(Uint8List png) itemImageClipboardWriter =
    _defaultClipboardWriter;

/// 檔案寫入 seam，讓 flutter test 不碰真實 FS。
@visibleForTesting
Future<void> Function(String path, Uint8List png) itemImageFileWriter =
    _defaultFileWriter;

/// 將所有 seam 重設為預設實作，供 tearDown 使用。
@visibleForTesting
void resetItemImageSaveSeams() {
  itemImageSaveLocationPicker = _defaultSaveLocationPicker;
  itemImageClipboardWriter = _defaultClipboardWriter;
  itemImageFileWriter = _defaultFileWriter;
}

/// 讓使用者選位置存 PNG。成功回 true；使用者取消回 false（非錯誤）；
/// 已選路徑但寫檔失敗會記 severe log 後 rethrow，由呼叫端提示。
Future<bool> saveImagePng(
  Uint8List png, {
  required String suggestedName,
}) async {
  final loc = await itemImageSaveLocationPicker(suggestedName);
  if (loc == null) {
    _log.info('save cancelled');
    return false;
  }
  try {
    await itemImageFileWriter(loc.path, png);
  } catch (e, st) {
    _log.severe('save image failed ${sanitizeFsPath(loc.path)}', e, st);
    rethrow;
  }
  _log.info('save image ok ${sanitizeFsPath(loc.path)} bytes=${png.length}');
  return true;
}

/// 把 PNG 寫入系統剪貼簿。成功回 true；平台不支援回 false；例外記 warning 後回 false。
Future<bool> copyImagePngToClipboard(Uint8List png) async {
  try {
    final ok = await itemImageClipboardWriter(png);
    _log.info('copy image clipboard=$ok bytes=${png.length}');
    return ok;
  } catch (e, st) {
    _log.warning('copy image failed', e, st);
    return false;
  }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/services/item_image_save_test.dart`
Expected: All tests passed!（4 個）

- [ ] **Step 5: 為 encodeImageFileToPng 補一個真實解碼測試**

把以下測試加進同檔 `main()`（`encodeImageFileToPng` 走 `dart:ui` 引擎解碼，需 `testWidgets` + `runAsync`，並用 `image` 套件造一張真的 PNG）：

```dart
// 檔案頂端 import 區補上：
// import 'package:image/image.dart' as img;

  testWidgets('encodeImageFileToPng：可解碼圖 → 回非空 PNG bytes', (tester) async {
    await tester.runAsync(() async {
      final src = img.Image(width: 2, height: 2);
      final srcBytes = Uint8List.fromList(img.encodePng(src));
      final f = File('${Directory.systemTemp.path}/item_encode_a.png');
      await f.writeAsBytes(srcBytes);

      final out = await encodeImageFileToPng(f);

      expect(out, isNotNull);
      expect(out!.isNotEmpty, isTrue);
      // PNG magic：89 50 4E 47。
      expect(out.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      await f.delete();
    });
  });

  testWidgets('encodeImageFileToPng：不可解碼檔 → 回 null', (tester) async {
    await tester.runAsync(() async {
      final f = File('${Directory.systemTemp.path}/item_encode_bad.bin');
      await f.writeAsBytes([1, 2, 3, 4]);

      final out = await encodeImageFileToPng(f);

      expect(out, isNull);
      await f.delete();
    });
  });
```

- [ ] **Step 6: 跑測試確認通過**

Run: `fvm flutter test test/services/item_image_save_test.dart`
Expected: All tests passed!（6 個）

- [ ] **Step 7: Commit**

```bash
git add lib/services/item_image_save.dart test/services/item_image_save_test.dart
git commit -m "feat(item-image): add save/copy/encode service for detail images"
```

---

## Task 2：新增 itemImageCacheRevisionProvider

**Files:**
- Modify: `lib/state/item_image_index.dart`（在檔尾既有 provider 區之後新增）

- [ ] **Step 1: 新增 provider**

在 `lib/state/item_image_index.dart` 的 import 區確認已有 `flutter_riverpod`（已有），於 `itemImageFetcherProvider` 宣告之後新增：

```dart
/// 物品圖片快取 revision；手動「重抓」覆蓋既有 icon 後 `bump()`，讓已掛載、
/// 路徑不變的縮圖（dialog 標題、記錄列表 [GachaItemIcon]）以新 key 重建並讀到新檔
/// （單純 evict 對已掛載 Image 不會自動重抓）。
final itemImageCacheRevisionProvider =
    NotifierProvider<ItemImageCacheRevisionNotifier, int>(
      ItemImageCacheRevisionNotifier.new,
    );

/// 維護單調遞增的快取 revision 計數；[bump] 觸發訂閱縮圖以新 key 重建。
class ItemImageCacheRevisionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// 遞增 revision。
  void bump() => state = state + 1;
}
```

> 註：Riverpod 3.x 已把 `StateProvider` 移到 deprecated 的 `legacy.dart`，本專案統一用 `NotifierProvider`，故以 `bump()` 取代 `state++`。下游 Task 3／5／7 對 revision 的遞增一律呼叫 `ref.read(itemImageCacheRevisionProvider.notifier).bump()`（測試端同）。

- [ ] **Step 2: analyze 確認無誤**

Run: `fvm flutter analyze lib/state/item_image_index.dart`
Expected: No issues found!

- [ ] **Step 3: Commit**

```bash
git add lib/state/item_image_index.dart
git commit -m "feat(item-image): add cache revision provider for thumbnail refresh"
```

---

## Task 3：GachaItemIcon 的 Image.file 加上 revision key

**Files:**
- Modify: `lib/widgets/gacha_item_icon.dart:62-68`

- [ ] **Step 1: 先寫測試 — 重抓 revision 變動後列表縮圖換新 key 重建**

在 `test/widgets/` 下新增 `test/widgets/gacha_item_icon_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/gacha_item_icon.dart';

GachaRecord _rec(int id) => GachaRecord(
  resourceId: id,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: '1',
  name: 'C',
  count: 1,
  time: DateTime(2026, 6, 8),
  languageCode: '',
);

void main() {
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gacha_item_icon_test_');
    container = ProviderContainer(
      overrides: [
        itemImageIndexStorageProvider.overrideWithValue(
          ItemImageIndexStorage(tempDir),
        ),
        itemImageCacheDirProvider.overrideWithValue(tempDir),
      ],
    );
    addTearDown(container.dispose);
    await container.read(itemImageIndexProvider.notifier).waitForLoad();
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  testWidgets('icon 存在 → Image.file key 帶 revision；revision++ 後 key 改變', (
    tester,
  ) async {
    const iconUrl = 'https://cdn.example.com/x_icon.png';
    late File iconFile;
    await tester.runAsync(() async {
      await container.read(itemImageIndexProvider.notifier).mergeIcon(
        resourceId: 111,
        iconUrl: iconUrl,
        noImage: false,
        permanentNoImage: false,
      );
      iconFile = itemIconCacheFile(
        baseDir: tempDir,
        resourceId: 111,
        url: iconUrl,
      );
      await iconFile.create(recursive: true);
      await iconFile.writeAsBytes([0x89, 0x50, 0x4E, 0x47]);
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: GachaItemIcon(record: _rec(111), size: 48)),
        ),
      ),
    );

    expect(find.byKey(ValueKey('${iconFile.path}#0')), findsOneWidget);

    container.read(itemImageCacheRevisionProvider.notifier).bump();
    await tester.pump();

    expect(find.byKey(ValueKey('${iconFile.path}#1')), findsOneWidget);
  });
}
```

- [ ] **Step 2: 跑測試確認 fail**

Run: `fvm flutter test test/widgets/gacha_item_icon_test.dart`
Expected: FAIL（目前 `Image.file` 無 key，找不到 `ValueKey('...#0')`）。

- [ ] **Step 3: 實作 — Image.file 加 revision key**

`lib/widgets/gacha_item_icon.dart`：在 `build` 內 `ref.watch(itemImageCacheDirProvider)` 之後新增一行讀 revision，並把第 62-68 行的 `Image.file` 加上 key。

import 區補上（若尚無）：`itemImageCacheRevisionProvider` 已在同一 `state/item_image_index.dart`，現有 import 已涵蓋。

build 內，於 `final tokens = ...` 之後加：

```dart
    final cacheRevision = ref.watch(itemImageCacheRevisionProvider);
```

把：

```dart
      if (file.existsSync()) {
        return SizedBox(
          width: size,
          height: size,
          child: _clipIcon(Image.file(file, fit: BoxFit.cover)),
        );
      }
```

改為：

```dart
      if (file.existsSync()) {
        return SizedBox(
          width: size,
          height: size,
          child: _clipIcon(
            Image.file(
              file,
              key: ValueKey('${file.path}#$cacheRevision'),
              fit: BoxFit.cover,
            ),
          ),
        );
      }
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/gacha_item_icon_test.dart`
Expected: All tests passed!

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/gacha_item_icon.dart test/widgets/gacha_item_icon_test.dart
git commit -m "feat(item-image): key list thumbnail by cache revision for live refresh"
```

---

## Task 4：新增 ARB 字串並產生 l10n

**Files:**
- Modify: `lib/l10n/app_zh.arb`、`lib/l10n/app_zh_Hans.arb`、`lib/l10n/app_en.arb`、`lib/l10n/app_ja.arb`

- [ ] **Step 1: 在 `app_zh.arb` 既有 `actionRetry` 區塊之後插入 7 條字串**

```json
  "actionCopyImage": "複製圖片",
  "@actionCopyImage": {
    "description": "Menu item in item detail image overflow menu: copy the current image to clipboard."
  },
  "actionSaveImage": "儲存圖片",
  "@actionSaveImage": {
    "description": "Menu item in item detail image overflow menu: save the current image to a file."
  },
  "actionRefetchImage": "重抓圖片",
  "@actionRefetchImage": {
    "description": "Menu item in item detail image overflow menu: re-fetch the current image."
  },
  "itemImageSavedTo": "已儲存圖片至 {path}",
  "@itemImageSavedTo": {
    "placeholders": { "path": { "type": "String" } },
    "description": "Snackbar after saving an item detail image to the given path."
  },
  "itemImageSaveFailed": "儲存圖片失敗",
  "@itemImageSaveFailed": {
    "description": "Snackbar when saving an item detail image fails."
  },
  "itemImageCopied": "已複製圖片到剪貼簿",
  "@itemImageCopied": {
    "description": "Snackbar after copying an item detail image to clipboard."
  },
  "itemImageCopyFailed": "複製圖片失敗",
  "@itemImageCopyFailed": {
    "description": "Snackbar when copying an item detail image to clipboard fails."
  },
```

- [ ] **Step 2: 在 `app_zh_Hans.arb` 對應位置插入（簡中、無需重複 @ 描述）**

```json
  "actionCopyImage": "复制图片",
  "actionSaveImage": "保存图片",
  "actionRefetchImage": "重新抓取图片",
  "itemImageSavedTo": "已保存图片至 {path}",
  "itemImageSaveFailed": "保存图片失败",
  "itemImageCopied": "已复制图片到剪贴板",
  "itemImageCopyFailed": "复制图片失败",
```

- [ ] **Step 3: 在 `app_en.arb` 對應位置插入**

```json
  "actionCopyImage": "Copy image",
  "actionSaveImage": "Save image",
  "actionRefetchImage": "Re-fetch image",
  "itemImageSavedTo": "Image saved to {path}",
  "itemImageSaveFailed": "Failed to save image",
  "itemImageCopied": "Image copied to clipboard",
  "itemImageCopyFailed": "Failed to copy image",
```

- [ ] **Step 4: 在 `app_ja.arb` 對應位置插入**

```json
  "actionCopyImage": "画像をコピー",
  "actionSaveImage": "画像を保存",
  "actionRefetchImage": "画像を再取得",
  "itemImageSavedTo": "画像を保存しました：{path}",
  "itemImageSaveFailed": "画像の保存に失敗しました",
  "itemImageCopied": "画像をクリップボードにコピーしました",
  "itemImageCopyFailed": "画像のコピーに失敗しました",
```

- [ ] **Step 5: 產生 l10n**

Run: `fvm flutter gen-l10n`
Expected: 無錯誤；`lib/l10n/generated/app_localizations.dart` 出現 `actionCopyImage` / `actionSaveImage` / `actionRefetchImage` / `itemImageSavedTo` / `itemImageSaveFailed` / `itemImageCopied` / `itemImageCopyFailed` getter。

- [ ] **Step 6: analyze 確認 l10n 一致**

Run: `fvm flutter analyze`
Expected: No issues found!（若報未翻譯 locale，補齊對應檔；本專案僅四 locale）

- [ ] **Step 7: Commit**

```bash
git add lib/l10n/app_zh.arb lib/l10n/app_zh_Hans.arb lib/l10n/app_en.arb lib/l10n/app_ja.arb lib/l10n/generated
git commit -m "feat(l10n): add item detail image menu strings"
```

---

## Task 5：dialog 重抓邏輯（以 `_refetchEntry` 取代 `_retryEntry`，含 icon + 快取失效）

**Files:**
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`

- [ ] **Step 1: 先寫重抓行為測試**

在 `test/widgets/dialogs/gacha_item_detail_dialog_test.dart` 檔尾（`main()` 內最後一個 group 之後）新增。本測試以「造型圖快取檔已存在 → 重抓會先刪 ImageCache 並切回 loading（spinner 出現）」驗證重抓有觸發：

先在檔案頂端 import 區補上：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart'
    show itemImageCacheRevisionProvider;
```

（註：該檔已 import `state/item_image_index.dart`，若已整檔 import 則此 show 省略，直接用既有 import。）

新增 group：

```dart
  group('GachaItemDetailDialog 圖片選單與重抓', () {
    /// seed 一個「角色 icon + 單一造型立繪」並建立兩個 cache 檔，回傳造型檔。
    Future<File> seedCharacterWithSkin(WidgetTester tester) async {
      const iconUrl = 'https://cdn.example.com/m_icon.png';
      const illustUrl = 'https://cdn.example.com/m_illust.png';
      late File illustFile;
      await tester.runAsync(() async {
        final n = container.read(itemImageIndexProvider.notifier);
        await n.mergeIcon(
          resourceId: 111,
          iconUrl: iconUrl,
          noImage: false,
          permanentNoImage: false,
        );
        await n.mergeItemDetail(
          resourceId: 111,
          lang: 'zh-Hant',
          detail: const ItemDetailL10n(
            intro: '',
            elementName: '',
            weaponTypeName: '',
            skins: [
              ItemSkin(
                formationCard: illustUrl,
                name: '造型A',
                subDecName: '',
                bgDescription: '',
              ),
            ],
          ),
        );
        final iconCacheFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: iconUrl,
        );
        await _touchFile(tempDir, iconCacheFile.uri.pathSegments.last);
        illustFile = itemIllustrationCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: illustUrl,
        );
        await _touchFile(tempDir, illustFile.uri.pathSegments.last);
      });
      rebuildContainer();
      await tester.runAsync(loadIndex);
      return illustFile;
    }

    testWidgets('ready 圖 → 圖片區有溢出選單按鈕（more_vert）', (tester) async {
      await seedCharacterWithSkin(tester);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      expect(
        find.descendant(
          of: find.byType(GachaItemDetailDialog),
          matching: find.byIcon(Icons.more_vert),
        ),
        findsOneWidget,
      );
    });

    testWidgets('選單三項：複製圖片 / 儲存圖片 / 重抓圖片', (tester) async {
      await seedCharacterWithSkin(tester);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(GachaItemDetailDialog),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('複製圖片'), findsOneWidget);
      expect(find.text('儲存圖片'), findsOneWidget);
      expect(find.text('重抓圖片'), findsOneWidget);
    });

    testWidgets('點重抓圖片 → 造型圖切回 loading（spinner 出現）', (tester) async {
      final illustFile = await seedCharacterWithSkin(tester);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      // 預設顯示造型立繪（ready）。
      expect(find.byKey(ValueKey(illustFile.path)), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byType(GachaItemDetailDialog),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('重抓圖片'));
      await tester.pump();

      // 重抓後切到 loading → spinner 出現、ready 圖消失。
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(ValueKey(illustFile.path)), findsNothing);
    });
  });
```

- [ ] **Step 2: 跑測試確認 fail**

Run: `fvm flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart --plain-name "圖片選單與重抓"`
Expected: FAIL（more_vert 不存在 / 選單未實作）。

- [ ] **Step 3: 加入 import 與 `_refetchIcon` / `_refetchEntry`，移除 `_retryEntry`**

在 `gacha_item_detail_dialog.dart` 頂端 import 區補上：

```dart
import 'package:flutter/foundation.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_save.dart';
```

（`flutter/foundation.dart` 提供 `Uint8List`；`flutter/material.dart` 已 export `PaintingBinding`／`imageCache`。）

把既有 `_retryEntry`（約 125-134 行）整段刪除，改為以下兩個方法：

```dart
  /// 重抓某 chip 的圖：先 evict 既有 ImageCache、切回 loading，再依類別重抓。
  ///
  /// 路徑不變的重抓必須 evict，否則 ready 圖重建後仍讀到舊快取（見檔頭策略）。
  /// 同時供失敗狀態的「重試」按鈕與圖片選單的「重抓圖片」共用。
  void _refetchEntry(_ImageChipEntry e) {
    PaintingBinding.instance.imageCache.evict(FileImage(e.file));
    _precachedPaths.remove(e.file.path);
    setState(() => _loadStates[e.file.path] = const _ImageLoading());
    switch (e.kind) {
      case _ChipKind.luckdraw:
        unawaited(
          _captureLuckdraw(file: e.file, lang: widget.record.languageCode),
        );
      case _ChipKind.skin:
        unawaited(_fetchAndCache(url: e.url, file: e.file));
      case _ChipKind.icon:
        unawaited(_refetchIcon(url: e.url, file: e.file));
    }
  }

  /// 重抓 icon：重新下載 [url] 覆蓋 [file]，成功後 evict + bump cache revision，
  /// 讓 dialog 標題縮圖與記錄列表 [GachaItemIcon] 同步顯示新 icon。
  ///
  /// 失敗時保留磁碟既有 icon（writeImageFileAtomic 只在成功時 rename 覆蓋），
  /// 但 chip 狀態轉 failed（沿用既有失敗 UI 的重試按鈕）。
  Future<void> _refetchIcon({required String url, required File file}) async {
    final fetcher = ref.read(itemImageFetcherProvider);
    try {
      final bytes = await fetcher.downloadImage(url, _client);
      if (bytes == null) {
        if (!mounted) return;
        setState(() => _loadStates[file.path] = const _ImageFailed());
        _log.warning(
          'icon refetch null rid=${widget.record.resourceId} '
          'url=${sanitizeUrl(url)}',
        );
        return;
      }
      await writeImageFileAtomic(file, bytes);
      if (!mounted) return;
      PaintingBinding.instance.imageCache.evict(FileImage(file));
      setState(() => _loadStates[file.path] = _ImageReady(file));
      ref.read(itemImageCacheRevisionProvider.notifier).bump();
      ref.invalidate(itemImageCacheUsageProvider);
      _log.info(
        'icon refetch ok rid=${widget.record.resourceId} '
        'bytes=${bytes.length} path=${sanitizeFsPath(file.path)}',
      );
    } catch (e, st) {
      if (!mounted) return;
      setState(() => _loadStates[file.path] = const _ImageFailed());
      _log.warning(
        'icon refetch failed rid=${widget.record.resourceId} '
        'url=${sanitizeUrl(url)}',
        e,
        st,
      );
    }
  }
```

把 `_buildCurrentImageArea` 內 `_ImageFailed` 分支的重試按鈕 `onPressed: () => _retryEntry(current)` 改為 `onPressed: () => _refetchEntry(current)`。

- [ ] **Step 4: 確認 `itemImageCacheRevisionProvider` 已可解析**

`gacha_item_detail_dialog.dart` 既有 `import '.../state/item_image_index.dart';`（提供 `itemImageIndexProvider`／`itemImageCacheDirProvider`），同檔已含 `itemImageCacheRevisionProvider`，無需新增 import。

- [ ] **Step 5: 跑全檔測試（選單三項與點擊重抓仍會因選單按鈕未加而 fail）**

Run: `fvm flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart --plain-name "圖片選單與重抓"`
Expected: 仍 FAIL（more_vert / 選單尚未加，Task 6 補）。但 analyze 應通過：
Run: `fvm flutter analyze lib/widgets/dialogs/gacha_item_detail_dialog.dart`
Expected: No issues found!

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/dialogs/gacha_item_detail_dialog.dart
git commit -m "feat(item-detail): add re-fetch with cache eviction for all image kinds"
```

---

## Task 6：dialog 圖片區疊溢出選單按鈕（複製 / 儲存 / 重抓）

**Files:**
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`

- [ ] **Step 1: 在 `_ImageReady` 分支用 Stack 疊選單按鈕**

把 `_buildCurrentImageArea` 的 `_ImageReady(:final file)` 分支改寫：原本回傳 `MouseRegion > GestureDetector > Image.file`，改為 `Stack`，圖在底、選單按鈕在右上。`current`（`_ImageChipEntry`）已是參數，handler 用它取 file/label/url。

把：

```dart
        _ImageReady(:final file) => MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _log.info('open zoom path=${sanitizeFsPath(file.path)}');
              showZoomableImageOverlay(context, imageFile: file);
            },
            child: Image.file(
              file,
              key: ValueKey(file.path),
              fit: BoxFit.contain,
              alignment: Alignment.center,
              gaplessPlayback: true,
              errorBuilder: (_, e, st) => const SizedBox.shrink(),
            ),
          ),
        ),
```

改為：

```dart
        _ImageReady(:final file) => Stack(
          children: [
            Positioned.fill(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _log.info('open zoom path=${sanitizeFsPath(file.path)}');
                    showZoomableImageOverlay(context, imageFile: file);
                  },
                  child: Image.file(
                    file,
                    key: ValueKey(file.path),
                    fit: BoxFit.contain,
                    alignment: Alignment.center,
                    gaplessPlayback: true,
                    errorBuilder: (_, e, st) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
            Positioned(
              top: AppSpacing.s,
              right: AppSpacing.s,
              child: _buildImageMenu(context, current),
            ),
          ],
        ),
```

- [ ] **Step 2: 新增 `_buildImageMenu` 與三個 handler**

在 `_GachaItemDetailDialogState` 內新增（建議放在 `_buildCurrentImageArea` 之前）：

```dart
  /// 圖片區右上角的溢出選單：複製圖片 / 儲存圖片 / --- / 重抓圖片。
  /// 沿用 lightbox X 鈕的半透明黑底圓鈕視覺，永遠顯示。
  Widget _buildImageMenu(BuildContext context, _ImageChipEntry current) {
    final l = AppLocalizations.of(context)!;
    return Material(
      color: Colors.black.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, color: Colors.white),
        tooltip: '',
        onSelected: (value) {
          switch (value) {
            case 'copy':
              unawaited(_copyImage(current));
            case 'save':
              unawaited(_saveImage(current));
            case 'refetch':
              _refetchEntry(current);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'copy',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.copy, size: 20),
              title: Text(l.actionCopyImage),
            ),
          ),
          PopupMenuItem(
            value: 'save',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.save_alt, size: 20),
              title: Text(l.actionSaveImage),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'refetch',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.refresh, size: 20),
              title: Text(l.actionRefetchImage),
            ),
          ),
        ],
      ),
    );
  }

  /// 把 record 名稱與 chip 標籤組成存檔建議檔名，並去掉檔名非法字元。
  String _suggestedFileName(_ImageChipEntry e) {
    final raw = '${widget.record.name}_${e.label}';
    // Windows 檔名非法字元（< > : " / \ | ? *）一律換 _，避免存檔對話框拒絕。
    final safe = raw.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return '$safe.png';
  }

  /// 複製目前圖片到剪貼簿：解碼成 PNG → 寫剪貼簿，結果以 SnackBar 回報。
  Future<void> _copyImage(_ImageChipEntry e) async {
    final l = AppLocalizations.of(context)!;
    final png = await encodeImageFileToPng(e.file);
    if (!mounted) return;
    if (png == null) {
      _showSnack(l.itemImageCopyFailed);
      return;
    }
    final ok = await copyImagePngToClipboard(png);
    if (!mounted) return;
    _showSnack(ok ? l.itemImageCopied : l.itemImageCopyFailed);
  }

  /// 儲存目前圖片：解碼成 PNG → 系統存檔對話框，結果以 SnackBar 回報。
  /// 使用者取消不提示；寫檔失敗提示失敗。
  Future<void> _saveImage(_ImageChipEntry e) async {
    final l = AppLocalizations.of(context)!;
    final png = await encodeImageFileToPng(e.file);
    if (!mounted) return;
    if (png == null) {
      _showSnack(l.itemImageSaveFailed);
      return;
    }
    try {
      final saved = await saveImagePng(png, suggestedName: _suggestedFileName(e));
      if (!mounted || !saved) return;
      _showSnack(l.itemImageSavedTo(_suggestedFileName(e)));
    } catch (_) {
      if (!mounted) return;
      _showSnack(l.itemImageSaveFailed);
    }
  }

  /// 以 SnackBar 顯示 [message]（dialog 之上找最近的 ScaffoldMessenger）。
  void _showSnack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
```

> 註：`itemImageSavedTo` 帶完整路徑會更明確，但 `saveImagePng` 未回傳實際路徑（只回 bool）。為避免擴大服務介面（YAGNI），此處以建議檔名作為 `{path}` 佔位內容；若日後要顯示完整路徑，再讓 `saveImagePng` 回傳路徑。

- [ ] **Step 3: 跑圖片選單測試確認通過**

Run: `fvm flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart --plain-name "圖片選單與重抓"`
Expected: All tests passed!（3 個）

- [ ] **Step 4: 跑整個 dialog 測試確認沒打壞既有案例**

Run: `fvm flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart`
Expected: All tests passed!

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/dialogs/gacha_item_detail_dialog.dart test/widgets/dialogs/gacha_item_detail_dialog_test.dart
git commit -m "feat(item-detail): add top-right image menu (copy/save/re-fetch)"
```

---

## Task 7：標題縮圖加 revision key（icon 重抓即時刷新）

**Files:**
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`（`build` 內 title 區 icon `Image.file`）

- [ ] **Step 1: 先寫測試 — icon 重抓 revision++ 後標題縮圖換 key**

在 Task 6 的 `圖片選單與重抓` group 內新增測試（武器只有 icon、選單重抓走 icon 路徑）：

```dart
    testWidgets('icon 重抓成功 → cache revision++、標題縮圖換 key', (tester) async {
      const iconUrl = 'https://cdn.example.com/w_icon.png';
      late File iconFile;
      await tester.runAsync(() async {
        await container.read(itemImageIndexProvider.notifier).mergeIcon(
          resourceId: 77,
          iconUrl: iconUrl,
          noImage: false,
          permanentNoImage: false,
        );
        iconFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 77,
          url: iconUrl,
        );
        await _touchFile(tempDir, iconFile.uri.pathSegments.last);
      });
      rebuildContainer();
      await tester.runAsync(loadIndex);

      await pumpDialog(
        tester,
        _rec(
          resourceId: 77,
          name: 'WeaponX',
          resourceType: '武器',
          languageCode: 'zh-Hant',
        ),
      );

      // 初始 revision 0：標題縮圖 key 帶 #0。
      expect(
        find.byKey(ValueKey('${iconFile.path}#0')),
        findsOneWidget,
      );

      // 直接 bump revision（不實際跑網路），驗證標題縮圖換 key 重建。
      container.read(itemImageCacheRevisionProvider.notifier).bump();
      await tester.pump();

      expect(find.byKey(ValueKey('${iconFile.path}#1')), findsOneWidget);
    });
```

- [ ] **Step 2: 跑測試確認 fail**

Run: `fvm flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart --plain-name "標題縮圖換 key"`
Expected: FAIL（標題 `Image.file` 目前無 key）。

- [ ] **Step 3: 實作 — 標題 icon Image.file 加 revision key**

在 `build` 內讀 revision（於 `final entry = index.lookupImage(...)` 之後加一行）：

```dart
    final cacheRevision = ref.watch(itemImageCacheRevisionProvider);
```

把 title 區（約 456-464 行）：

```dart
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Image.file(
                iconFile,
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, e, st) => const SizedBox.shrink(),
              ),
            ),
```

改為：

```dart
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Image.file(
                iconFile,
                key: ValueKey('${iconFile.path}#$cacheRevision'),
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, e, st) => const SizedBox.shrink(),
              ),
            ),
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart --plain-name "標題縮圖換 key"`
Expected: All tests passed!

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/dialogs/gacha_item_detail_dialog.dart test/widgets/dialogs/gacha_item_detail_dialog_test.dart
git commit -m "feat(item-detail): key title thumbnail by cache revision"
```

---

## Task 8：全量品質檢查與收尾

**Files:** 無（驗證）

- [ ] **Step 1: 格式化**

Run: `fvm dart format lib/ test/`
Expected: 僅本次變更檔被格式化，無非預期變動。

- [ ] **Step 2: 靜態分析**

Run: `fvm flutter analyze`
Expected: No issues found!

- [ ] **Step 3: 全測試**

Run: `fvm flutter test`
Expected: All tests passed!

- [ ] **Step 4: 手動驗證（建置機）**

啟動 app，開任一角色詳情：
- 圖片區右上角有溢出選單，永遠顯示。
- 選單由上到下為「複製圖片 / 儲存圖片 /（分隔線）/ 重抓圖片」。
- 造型、喚取、icon 三種 chip 各能：複製（貼到外部驗證）、儲存（存出 .png 可開）、重抓（spinner → 新圖）。
- icon 重抓後，dialog 標題縮圖即時更新；關閉 dialog 後記錄列表縮圖也是新 icon。

- [ ] **Step 5: 若 format 有改動則補 commit**

```bash
git add -A
git commit -m "style: format item image menu changes"
```

（若 Step 1 無改動則跳過。）

---

## Self-Review

**Spec coverage：**
- 圖片區右上角選單（一直顯示、ready 才有）→ Task 6 ✅
- 三項：複製 / 儲存 / 重抓，順序＋分隔線 → Task 6（`_buildImageMenu`）✅
- 儲存與複製統一轉 PNG → Task 1 `encodeImageFileToPng` 共用 ✅
- 儲存保留 .png 副檔名建議檔名 → Task 6 `_suggestedFileName` ✅
- 重抓套用三類（含 icon）→ Task 5 `_refetchEntry`／`_refetchIcon` ✅
- 重抓快取失效（evict + 版本 key）→ Task 5（圖片區 evict）＋ Task 2/3/7（revision key）✅
- icon 重抓連標題＋列表刷新 → Task 7（標題）＋ Task 3（列表）＋ Task 5（bump revision）✅
- 提示與 log（脫敏）→ Task 1（服務 log）＋ Task 6（SnackBar）✅
- i18n 四語 → Task 4 ✅
- 測試（服務 + dialog）→ Task 1 / 3 / 6 / 7 ✅

**Placeholder scan：** 無 TBD／TODO；每個 code step 皆含完整程式碼。`itemImageSavedTo` 的 `{path}` 以建議檔名填入，已於 Task 6 Step 2 註明取捨理由（非 placeholder 缺漏）。

**Type consistency：** 服務函式名 `encodeImageFileToPng`／`saveImagePng`／`copyImagePngToClipboard`、seam `itemImageSaveLocationPicker`／`itemImageClipboardWriter`／`itemImageFileWriter`／`resetItemImageSaveSeams`、provider `itemImageCacheRevisionProvider`、dialog 方法 `_refetchEntry`／`_refetchIcon`／`_buildImageMenu`／`_copyImage`／`_saveImage`／`_suggestedFileName`／`_showSnack` 在各 Task 間一致。圖片區 `Image` key 維持 `ValueKey(file.path)`（既有測試不動）；標題與列表縮圖改用 `ValueKey('${path}#$rev')`（新增 key，不衝突）。
