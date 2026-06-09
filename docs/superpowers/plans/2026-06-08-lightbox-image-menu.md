# Lightbox 大圖影像選單（copy／save）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `ZoomableImageOverlay` 大圖上，用右鍵或右上角 `...` 按鈕叫出「複製圖片／儲存圖片」選單，重用既有共用 helper，並在 lightbox 內部彈 SnackBar 回饋。

**Architecture:** 在 `ZoomableImageOverlay` 鏡像 `GachaItemDetailDialog` 既有的影像選單 pattern（`_imageMenuItems`／`_onImageMenuSelected`／`_showImageContextMenu` + `PopupMenuButton`），copy/save 直接呼叫 `lib/services/item_image_save.dart` 的共用函式。把 overlay 內容包一層自帶 `ScaffoldMessenger`（用 `GlobalKey<ScaffoldMessengerState>` 定址），讓回饋 SnackBar 顯示在全螢幕 overlay 內、不被蓋住。`showZoomableImageOverlay` 加可選 `suggestedFileName`，由 detail dialog 帶入。

**Tech Stack:** Flutter（`PopupMenuButton`／`showMenu`／`ScaffoldMessenger`）、既有 `item_image_save.dart` 共用函式與其可注入測試 seam、`flutter_test`、FVM 釘住的 SDK。

**Spec:** `docs/superpowers/specs/2026-06-08-lightbox-image-menu-design.md`

---

## File Structure

| 檔案 | 責任 | 改動 |
|---|---|---|
| `lib/widgets/dialogs/zoomable_image_overlay.dart` | overlay 互動與 UI | 修改：`suggestedFileName` 參數、ScaffoldMessenger 包裹、選單 items／分派／copy／save／`_suggestedName`／`_showSnack`、右鍵 `onSecondaryTapDown`、右上 `...` PopupMenuButton |
| `lib/widgets/dialogs/gacha_item_detail_dialog.dart` | detail dialog | 修改：開 overlay 時帶 `suggestedFileName` |
| `test/widgets/dialogs/zoomable_image_overlay_test.dart` | overlay 測試 | 修改：`openOverlay` 加參數、選單／右鍵／copy／save／檔名測試 |
| `test/widgets/dialogs/gacha_item_detail_dialog_test.dart` | dialog 測試 | 修改：既有 zoom-open 測試補 `suggestedFileName` 斷言 |

**指令一律優先 `fvm`**（找不到再退回 `flutter`／`dart`）。

---

## Task 1: overlay 影像選單（copy／save）+ 兩種觸發 + 內部回饋

**Files:**
- Modify: `lib/widgets/dialogs/zoomable_image_overlay.dart`
- Test: `test/widgets/dialogs/zoomable_image_overlay_test.dart`

- [ ] **Step 1: 測試檔加 import 並讓 `openOverlay` 支援可選 `suggestedFileName`**

在 `test/widgets/dialogs/zoomable_image_overlay_test.dart` 頂部 import 區，加入：

```dart
import 'package:file_selector/file_selector.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_save.dart';
```

找到既有 helper：

```dart
  Future<void> openOverlay(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () =>
                  showZoomableImageOverlay(ctx, imageFile: imageFile),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // pump a few frames — file image codec on tempDir may never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
```

替換為（新增可選具名參數，預設行為不變）：

```dart
  Future<void> openOverlay(
    WidgetTester tester, {
    String? suggestedFileName,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showZoomableImageOverlay(
                ctx,
                imageFile: imageFile,
                suggestedFileName: suggestedFileName,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // pump a few frames — file image codec on tempDir may never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
```

- [ ] **Step 2: 寫失敗測試——選單觸發（結構）與 copy／save（行為）**

在 `test/widgets/dialogs/zoomable_image_overlay_test.dart` 檔尾 `}`（`void main()` 收尾）前新增兩個 group：

```dart
  group('ZoomableImageOverlay image menu triggers', () {
    AppLocalizations loc(WidgetTester tester) =>
        AppLocalizations.of(tester.element(find.byType(ZoomableImageOverlay)))!;

    testWidgets('top-right ... button opens copy/save menu (no refetch)', (
      tester,
    ) async {
      await openOverlay(tester);
      final l = loc(tester);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text(l.actionCopyImage), findsOneWidget);
      expect(find.text(l.actionSaveImage), findsOneWidget);
      expect(find.text(l.actionRefetchImage), findsNothing);
    });

    testWidgets('right-click on image opens copy/save menu', (tester) async {
      await openOverlay(tester);
      final l = loc(tester);
      await tester.tapAt(
        tester.getCenter(find.byType(InteractiveViewer)),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text(l.actionCopyImage), findsOneWidget);
      expect(find.text(l.actionSaveImage), findsOneWidget);
    });
  });

  group('ZoomableImageOverlay copy/save actions', () {
    AppLocalizations loc(WidgetTester tester) =>
        AppLocalizations.of(tester.element(find.byType(ZoomableImageOverlay)))!;

    tearDown(resetItemImageSaveSeams);

    /// 開 ... 選單並點選 [itemText]，讓真實的 PNG decode + 後續 future 完成。
    Future<void> pickMenu(WidgetTester tester, String itemText) async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text(itemText));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('copy writes PNG to clipboard and shows copied snackbar', (
      tester,
    ) async {
      var copyCalled = false;
      itemImageClipboardWriter = (bytes) async {
        copyCalled = true;
        return true;
      };
      await openOverlay(tester);
      final l = loc(tester);
      await pickMenu(tester, l.actionCopyImage);
      expect(copyCalled, isTrue);
      expect(find.text(l.itemImageCopied), findsOneWidget);
    });

    testWidgets('save calls picker with suggestedFileName and shows saved snackbar', (
      tester,
    ) async {
      String? capturedName;
      String? writtenPath;
      final tmp = '${tempDir.path}/saved.png';
      itemImageSaveLocationPicker = (name) async {
        capturedName = name;
        return FileSaveLocation(tmp);
      };
      itemImageFileWriter = (path, png) async {
        writtenPath = path;
        await File(path).writeAsBytes(png);
      };
      await openOverlay(tester, suggestedFileName: 'Char_Splash.png');
      final l = loc(tester);
      await pickMenu(tester, l.actionSaveImage);
      expect(capturedName, 'Char_Splash.png');
      expect(writtenPath, tmp);
      expect(find.text(l.itemImageSavedTo(tmp)), findsOneWidget);
    });

    testWidgets('save cancelled shows no snackbar', (tester) async {
      itemImageSaveLocationPicker = (name) async => null;
      await openOverlay(tester);
      final l = loc(tester);
      await pickMenu(tester, l.actionSaveImage);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('save without suggestedFileName falls back to file basename', (
      tester,
    ) async {
      String? capturedName;
      itemImageSaveLocationPicker = (name) async {
        capturedName = name;
        return null;
      };
      await openOverlay(tester);
      final l = loc(tester);
      await pickMenu(tester, l.actionSaveImage);
      expect(capturedName, 'test.png');
    });
  });
```

- [ ] **Step 3: 跑測試，確認失敗（紅燈）**

Run: `fvm flutter test test/widgets/dialogs/zoomable_image_overlay_test.dart`
Expected: FAIL——新 group 失敗（目前 overlay 沒有 `...` 鈕／右鍵選單／copy／save）。

- [ ] **Step 4: 加 import 與 ScaffoldMessenger key 欄位**

在 `lib/widgets/dialogs/zoomable_image_overlay.dart` 頂部 import 區（現有 `import 'dart:io';` 之後）加：

```dart
import 'dart:async';
```

並在 package import 區（`app_localizations.dart` 那行附近）加：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_save.dart';
```

在 `_ZoomableImageOverlayState` 的欄位區（`_ivKey` 宣告附近）加：

```dart
  /// lightbox 自帶的 ScaffoldMessenger key；copy/save 的 SnackBar 透過它顯示在
  /// 全螢幕 overlay 內部，而非被覆蓋的 app Scaffold。
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
```

- [ ] **Step 5: 加 `suggestedFileName` 參數（widget + show 函式）**

找到 `showZoomableImageOverlay`：

```dart
Future<void> showZoomableImageOverlay(
  BuildContext context, {
  required File imageFile,
}) {
  Logger('gacha.itemimage.zoom').info('overlay open file=${imageFile.path}');
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.75),
    // barrierDismissible: true 讓 Flutter Navigator 內建 ESC 關閉生效。
    barrierDismissible: true,
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: ZoomableImageOverlay(imageFile: imageFile),
    ),
  );
}
```

替換為：

```dart
Future<void> showZoomableImageOverlay(
  BuildContext context, {
  required File imageFile,
  String? suggestedFileName,
}) {
  Logger('gacha.itemimage.zoom').info('overlay open file=${imageFile.path}');
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.75),
    // barrierDismissible: true 讓 Flutter Navigator 內建 ESC 關閉生效。
    barrierDismissible: true,
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: ZoomableImageOverlay(
        imageFile: imageFile,
        suggestedFileName: suggestedFileName,
      ),
    ),
  );
}
```

找到 widget 宣告：

```dart
class ZoomableImageOverlay extends StatefulWidget {
  /// 建立 [ZoomableImageOverlay]。
  const ZoomableImageOverlay({super.key, required this.imageFile});

  /// 要顯示的本地圖檔。
  final File imageFile;
```

替換為：

```dart
class ZoomableImageOverlay extends StatefulWidget {
  /// 建立 [ZoomableImageOverlay]。
  const ZoomableImageOverlay({
    super.key,
    required this.imageFile,
    this.suggestedFileName,
  });

  /// 要顯示的本地圖檔。
  final File imageFile;

  /// 存檔對話框的建議檔名；null 時 fallback 用 [imageFile] 的 basename。
  final String? suggestedFileName;
```

- [ ] **Step 6: 加選單／分派／copy／save／檔名／回饋方法**

在 `_ZoomableImageOverlayState` 內 `_onZoomButtonPressed()` 方法**之後**，加入下列方法：

```dart
  /// 影像選單項目（複製圖片 / 儲存圖片）；右鍵與右上 `...` 鈕共用。
  List<PopupMenuEntry<String>> _imageMenuItems(AppLocalizations l) => [
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
  ];

  /// 分派影像選單選擇：複製 / 儲存。
  void _onImageMenuSelected(String value) {
    switch (value) {
      case 'copy':
        unawaited(_copyImage());
      case 'save':
        unawaited(_saveImage());
    }
  }

  /// 右鍵在圖片上叫出影像選單，位置跟著游標。
  Future<void> _showImageContextMenu(Offset globalPosition) async {
    final l = AppLocalizations.of(context)!;
    Logger('gacha.itemimage.zoom').info('menu open source=rightclick');
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: _imageMenuItems(l),
    );
    if (selected == null || !mounted) return;
    _onImageMenuSelected(selected);
  }

  /// 存檔建議檔名；caller 未帶 [ZoomableImageOverlay.suggestedFileName] 則用檔案 basename。
  String _suggestedName() =>
      widget.suggestedFileName ?? widget.imageFile.uri.pathSegments.last;

  /// 複製目前圖片到剪貼簿：解碼 PNG → 寫剪貼簿，結果以 lightbox 內 SnackBar 回報。
  Future<void> _copyImage() async {
    final l = AppLocalizations.of(context)!;
    final png = await encodeImageFileToPng(widget.imageFile);
    if (!mounted) return;
    if (png == null) {
      Logger('gacha.itemimage.zoom').warning('copy encode failed');
      _showSnack(l.itemImageCopyFailed);
      return;
    }
    final ok = await copyImagePngToClipboard(png);
    if (!mounted) return;
    Logger('gacha.itemimage.zoom').info('copy done ok=$ok');
    _showSnack(ok ? l.itemImageCopied : l.itemImageCopyFailed);
  }

  /// 儲存目前圖片：解碼 PNG → 系統存檔對話框，結果以 lightbox 內 SnackBar 回報。
  /// 使用者取消不提示；寫檔失敗提示失敗。
  Future<void> _saveImage() async {
    final l = AppLocalizations.of(context)!;
    final png = await encodeImageFileToPng(widget.imageFile);
    if (!mounted) return;
    if (png == null) {
      Logger('gacha.itemimage.zoom').warning('save encode failed');
      _showSnack(l.itemImageSaveFailed);
      return;
    }
    try {
      final savedPath = await saveImagePng(png, suggestedName: _suggestedName());
      if (!mounted || savedPath == null) return;
      Logger('gacha.itemimage.zoom').info('save done');
      _showSnack(l.itemImageSavedTo(savedPath));
    } catch (_) {
      if (!mounted) return;
      Logger('gacha.itemimage.zoom').warning('save failed');
      _showSnack(l.itemImageSaveFailed);
    }
  }

  /// 在 lightbox 內部彈 SnackBar（用自帶 [_messengerKey]，不被全螢幕 overlay 蓋住）。
  void _showSnack(String message) {
    _messengerKey.currentState
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
```

- [ ] **Step 7: 把 build 的 Stack 包進自帶 ScaffoldMessenger + Scaffold**

找到 `build` 開頭：

```dart
    final l = AppLocalizations.of(context)!;
    return Stack(
      children: [
```

替換為：

```dart
    final l = AppLocalizations.of(context)!;
    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
```

並在 `build` 的結尾找到 Stack 的收尾：

```dart
        ),
      ],
    );
  }
}
```

替換為（多收兩層 `Scaffold` / `ScaffoldMessenger`）：

```dart
        ),
          ],
        ),
      ),
    );
  }
}
```

> 注意：這是 `build()` 最後對應 `Stack(children: [...])` 的收尾。實作時請依實際縮排把原本 `Stack` 的 `children: [ ... ]` 整段內縮包進 `Scaffold(body: ...)`；跑 `fvm dart format` 會自動修正縮排，重點是括號層級正確（`ScaffoldMessenger > Scaffold > Stack`）。

- [ ] **Step 8: 內層圖片 GestureDetector 加右鍵**

找到內層 image GestureDetector：

```dart
                            behavior: HitTestBehavior.opaque,
                            onTapUp: _onTapZoom,
                            child: Image(
```

替換為：

```dart
                            behavior: HitTestBehavior.opaque,
                            onTapUp: _onTapZoom,
                            onSecondaryTapDown: (d) =>
                                unawaited(_showImageContextMenu(d.globalPosition)),
                            child: Image(
```

- [ ] **Step 9: 右上按鈕列加 `...` PopupMenuButton（最左）**

找到右上按鈕列的 Row：

```dart
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<Matrix4>(
                valueListenable: _ctrl,
                builder: (_, matrix, _) {
                  final zoomed = _isZoomed(matrix);
                  return _OverlayCircleButton(
                    tooltip: zoomed ? l.actionZoomOut : l.actionZoomIn,
                    icon: zoomed ? Icons.zoom_out : Icons.zoom_in,
                    onPressed: _onZoomButtonPressed,
                  );
                },
              ),
              const SizedBox(width: 8),
              _OverlayCircleButton(
                tooltip: l.actionCloseImagePreview,
                icon: Icons.close,
                onPressed: () => _close('button'),
              ),
            ],
          ),
```

替換為（在最前面插入 `...` 鈕 + 間隔）：

```dart
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Material(
                color: Colors.black.withValues(alpha: 0.4),
                shape: const CircleBorder(),
                child: PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: Colors.white),
                  tooltip: '',
                  onOpened: () => Logger(
                    'gacha.itemimage.zoom',
                  ).info('menu open source=button'),
                  onSelected: _onImageMenuSelected,
                  itemBuilder: (_) => _imageMenuItems(l),
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<Matrix4>(
                valueListenable: _ctrl,
                builder: (_, matrix, _) {
                  final zoomed = _isZoomed(matrix);
                  return _OverlayCircleButton(
                    tooltip: zoomed ? l.actionZoomOut : l.actionZoomIn,
                    icon: zoomed ? Icons.zoom_out : Icons.zoom_in,
                    onPressed: _onZoomButtonPressed,
                  );
                },
              ),
              const SizedBox(width: 8),
              _OverlayCircleButton(
                tooltip: l.actionCloseImagePreview,
                icon: Icons.close,
                onPressed: () => _close('button'),
              ),
            ],
          ),
```

- [ ] **Step 10: 跑測試，確認通過（綠燈）**

Run: `fvm flutter test test/widgets/dialogs/zoomable_image_overlay_test.dart`
Expected: PASS——`All tests passed!`（新 6 個測試 + 既有 22 個皆綠）。

若 copy/save 行為測試偶發未 settle，先確認 `pickMenu` 的 `runAsync` 內 delay 足夠（encode 1×1 PNG 通常 <100ms）；不要改既有結構測試。

- [ ] **Step 11: 格式化 + analyze**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 12: Commit**

```bash
git add lib/widgets/dialogs/zoomable_image_overlay.dart test/widgets/dialogs/zoomable_image_overlay_test.dart
git commit -m "feat(image-overlay): copy/save menu via right-click and overflow button"
```

---

## Task 2: detail dialog 開 lightbox 時帶入建議檔名

**Files:**
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`
- Test: `test/widgets/dialogs/gacha_item_detail_dialog_test.dart`

- [ ] **Step 1: 既有 zoom-open 測試補 `suggestedFileName` 斷言（先紅）**

在 `test/widgets/dialogs/gacha_item_detail_dialog_test.dart` 找到測試 `'點 illustration → 開啟 ZoomableImageOverlay'` 結尾：

```dart
      await tester.tap(mainImage);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(ZoomableImageOverlay), findsOneWidget);
    });
```

替換為（補上對帶入檔名的驗證；record name 為 `'Char'`，故建議檔名以 `Char` 開頭、`.png` 結尾）：

```dart
      await tester.tap(mainImage);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(ZoomableImageOverlay), findsOneWidget);
      final overlay = tester.widget<ZoomableImageOverlay>(
        find.byType(ZoomableImageOverlay),
      );
      expect(overlay.suggestedFileName, isNotNull);
      expect(overlay.suggestedFileName, startsWith('Char'));
      expect(overlay.suggestedFileName, endsWith('.png'));
    });
```

確認該測試檔已 import `ZoomableImageOverlay`（既有測試已用 `find.byType(ZoomableImageOverlay)`，故 import 已存在；若無則加 `import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/zoomable_image_overlay.dart';`）。

- [ ] **Step 2: 跑測試，確認失敗（紅燈）**

Run: `fvm flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart --plain-name "開啟 ZoomableImageOverlay"`
Expected: FAIL——`overlay.suggestedFileName` 為 null（dialog 尚未帶入）。

- [ ] **Step 3: 開 overlay 時帶入 `suggestedFileName`**

在 `lib/widgets/dialogs/gacha_item_detail_dialog.dart` 找到（`_buildCurrentImageArea` 內、ready 圖的 onTap）：

```dart
                  onTap: () {
                    _log.info('open zoom path=${sanitizeFsPath(file.path)}');
                    showZoomableImageOverlay(context, imageFile: file);
                  },
```

替換為：

```dart
                  onTap: () {
                    _log.info('open zoom path=${sanitizeFsPath(file.path)}');
                    showZoomableImageOverlay(
                      context,
                      imageFile: file,
                      suggestedFileName: _suggestedFileName(current),
                    );
                  },
```

（`_suggestedFileName(_ImageChipEntry)` 為 dialog 既有方法，回傳 `角色名_標籤.png`；`current` 在此 closure 範圍內可用。）

- [ ] **Step 4: 跑測試，確認通過（綠燈）**

Run: `fvm flutter test test/widgets/dialogs/gacha_item_detail_dialog_test.dart --plain-name "開啟 ZoomableImageOverlay"`
Expected: PASS。

- [ ] **Step 5: 格式化 + analyze**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/dialogs/gacha_item_detail_dialog.dart test/widgets/dialogs/gacha_item_detail_dialog_test.dart
git commit -m "feat(item-detail): pass suggested filename when opening lightbox"
```

---

## Task 3: 全套驗證與手動檢查

**Files:** 無新增改動，僅驗證。

- [ ] **Step 1: 全套品質檢查**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`
Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 2: 手動驗證（release）**

Run: `fvm flutter run --release`

進 app → 開 5★ 角色 detail dialog → 點主圖開 lightbox，逐項確認：

- 右鍵圖片、按右上 `...`，都能開出「複製圖片／儲存圖片」（**無**「重抓圖片」）。
- 複製 → lightbox 內彈「已複製」；貼到外部程式確認圖片正確。
- 儲存 → 系統存檔對話框預設檔名為「角色名_標籤.png」；存完 lightbox 內彈含完整路徑的提示；取消不提示。
- 右上列為 `[...] [縮放切換] [X]`，窄視窗不溢出。
- 既有單擊縮放／游標／滾輪／拖曳／ESC／背景關閉皆不受影響。

- [ ] **Step 3: （可選）若手動發現問題**

回對應 Task 修正後重跑 Step 1。全綠且手動通過即完成。不要 `git push`。

---

## Self-Review Notes

- **Spec coverage**：右鍵 + `...` 觸發（Task 1 Step 8/9）、copy/save 重用共用 helper（Task 1 Step 6）、lightbox 內部 SnackBar 回饋（Task 1 Step 4/6/7）、`suggestedFileName` 參數與 fallback（Task 1 Step 5/6、Task 2）、不新增 ARB（全用既有 key）、不放 refetch（選單只 copy/save）、logging（Task 1 Step 6/9）、測試（Task 1 Step 2、Task 2 Step 1）——皆有對應任務。
- **型別一致**：`_imageMenuItems(AppLocalizations)`／`_onImageMenuSelected(String)`／`_showImageContextMenu(Offset)`／`_copyImage()`／`_saveImage()`／`_suggestedName()`／`_showSnack(String)`／`_messengerKey`（`GlobalKey<ScaffoldMessengerState>`）定義與使用一致；`suggestedFileName` 在 widget／show 函式／呼叫端一致。
- **無 placeholder**：所有 code step 皆附完整 old→new 程式碼。
