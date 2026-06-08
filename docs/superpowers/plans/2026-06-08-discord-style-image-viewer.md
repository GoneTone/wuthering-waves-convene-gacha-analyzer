# Discord 風格圖片檢視器互動 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `ZoomableImageOverlay` 的互動改成 Discord 體驗——單擊切換 fit↔2x、游標依縮放狀態切換放大鏡＋／−、右上角加一顆依狀態切換的縮放鈕。

**Architecture:** 改 `lib/widgets/dialogs/zoomable_image_overlay.dart` 單一 widget。把內層 image `GestureDetector` 的 `onDoubleTapDown` 換成 `onTapUp`（單擊 toggle）；用兩個各自獨立的 `ValueListenableBuilder<Matrix4>(_ctrl)` 分別驅動「圖片區游標（MouseRegion）」與「右上縮放鈕（icon／tooltip／行為）」，避免重建 InteractiveViewer 子樹。新增 2 個 ARB key。

**Tech Stack:** Flutter、`InteractiveViewer` + `TransformationController`（本身是 `ValueNotifier<Matrix4>`）、Flutter gen-l10n（ARB）、FVM 釘住的 SDK、`flutter_test`。

**Spec:** `docs/superpowers/specs/2026-06-08-discord-style-image-viewer-design.md`

---

## File Structure

| 檔案 | 責任 | 改動 |
|---|---|---|
| `lib/widgets/dialogs/zoomable_image_overlay.dart` | overlay 互動與 UI | 修改：單擊 toggle、`_isZoomed` 判斷、游標 MouseRegion、右上按鈕列＋`_OverlayCircleButton`、`_onZoomButtonPressed` |
| `lib/l10n/app_zh.arb`、`app_zh_Hans.arb`、`app_ja.arb`、`app_en.arb` | 核心四語系字串 | 新增 `actionZoomIn`／`actionZoomOut` |
| `test/widgets/dialogs/zoomable_image_overlay_test.dart` | 互動測試 | 雙擊群組→單擊、結構斷言更新、補游標／按鈕測試 |

**指令一律優先 `fvm`**（找不到再退回 `flutter`／`dart`）。

---

## Task 1: 新增 i18n key（actionZoomIn／actionZoomOut）

**Files:**
- Modify: `lib/l10n/app_zh.arb`（緊接 `actionCloseImagePreview` 區塊後）
- Modify: `lib/l10n/app_zh_Hans.arb`
- Modify: `lib/l10n/app_ja.arb`
- Modify: `lib/l10n/app_en.arb`

只改這四個「核心已翻譯」ARB（其餘空殼語系交給 Crowdin pipeline）。從 `app_zh.arb` 起手。

- [ ] **Step 1: 在 `app_zh.arb` 的 `actionCloseImagePreview` 區塊後插入兩個 key**

找到 `app_zh.arb` 內這段（在 `actionViewOnEncore` 之前）：

```json
  "actionCloseImagePreview": "關閉圖片預覽",
  "@actionCloseImagePreview": {
    "description": "Tooltip and semantic label for the close (X) button on the full-screen zoomable image overlay opened from the item detail dialog gallery."
  },

  "actionViewOnEncore": "在 encore.moe 查看",
```

改成（在中間插入兩個 key）：

```json
  "actionCloseImagePreview": "關閉圖片預覽",
  "@actionCloseImagePreview": {
    "description": "Tooltip and semantic label for the close (X) button on the full-screen zoomable image overlay opened from the item detail dialog gallery."
  },

  "actionZoomIn": "放大",
  "@actionZoomIn": {
    "description": "Tooltip and semantic label for the zoom toggle button on the full-screen zoomable image overlay when the image is at fit (a click will zoom in)."
  },

  "actionZoomOut": "縮小",
  "@actionZoomOut": {
    "description": "Tooltip and semantic label for the zoom toggle button on the full-screen zoomable image overlay when the image is zoomed in (a click will zoom out)."
  },

  "actionViewOnEncore": "在 encore.moe 查看",
```

- [ ] **Step 2: 在 `app_en.arb` 同位置插入英文**

找到 `app_en.arb` 內 `actionCloseImagePreview`（值為 `"Close image preview"`）區塊，於其後、`actionViewOnEncore` 前插入：

```json
  "actionZoomIn": "Zoom in",
  "@actionZoomIn": {
    "description": "Tooltip and semantic label for the zoom toggle button on the full-screen zoomable image overlay when the image is at fit (a click will zoom in)."
  },

  "actionZoomOut": "Zoom out",
  "@actionZoomOut": {
    "description": "Tooltip and semantic label for the zoom toggle button on the full-screen zoomable image overlay when the image is zoomed in (a click will zoom out)."
  },
```

- [ ] **Step 3: 在 `app_ja.arb` 同位置插入日文**

找到 `app_ja.arb` 內 `actionCloseImagePreview`（值為 `"画像プレビューを閉じる"`）區塊，於其後插入（描述沿用英文）：

```json
  "actionZoomIn": "拡大",
  "@actionZoomIn": {
    "description": "Tooltip and semantic label for the zoom toggle button on the full-screen zoomable image overlay when the image is at fit (a click will zoom in)."
  },

  "actionZoomOut": "縮小",
  "@actionZoomOut": {
    "description": "Tooltip and semantic label for the zoom toggle button on the full-screen zoomable image overlay when the image is zoomed in (a click will zoom out)."
  },
```

- [ ] **Step 4: 在 `app_zh_Hans.arb` 同位置插入簡中**

找到 `app_zh_Hans.arb` 內 `actionCloseImagePreview`（值為 `"关闭图片预览"`）區塊，於其後插入：

```json
  "actionZoomIn": "放大",
  "@actionZoomIn": {
    "description": "Tooltip and semantic label for the zoom toggle button on the full-screen zoomable image overlay when the image is at fit (a click will zoom in)."
  },

  "actionZoomOut": "缩小",
  "@actionZoomOut": {
    "description": "Tooltip and semantic label for the zoom toggle button on the full-screen zoomable image overlay when the image is zoomed in (a click will zoom out)."
  },
```

- [ ] **Step 5: 重新產生 l10n 並確認 getter 存在**

Run: `fvm flutter gen-l10n`
Expected: 無錯誤；產生的 `app_localizations.dart` 內出現 `String get actionZoomIn` 與 `String get actionZoomOut`。

驗證 getter（PowerShell）:
Run: `Select-String -Path lib/l10n/generated/app_localizations.dart -Pattern "actionZoomIn|actionZoomOut"`
Expected: 各語系類別內均出現兩個 getter。

- [ ] **Step 6: analyze 確認 ARB 無格式錯誤**

Run: `fvm flutter analyze lib/l10n`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add lib/l10n/app_zh.arb lib/l10n/app_zh_Hans.arb lib/l10n/app_ja.arb lib/l10n/app_en.arb
git commit -m "feat(i18n): add zoom in/out tooltips for image overlay"
```

（產生檔 `lib/l10n/generated/` 為 gitignore，不進 commit。）

---

## Task 2: 單擊切換 fit↔2x，取代雙擊

**Files:**
- Modify: `lib/widgets/dialogs/zoomable_image_overlay.dart`
- Test: `test/widgets/dialogs/zoomable_image_overlay_test.dart`

把內層 image `GestureDetector` 的雙擊縮放換成單擊 toggle。常數 `_doubleTapScale` 改名為 `_zoomedScale`（已無雙擊語意）。

- [ ] **Step 1: 改寫測試——「double-tap toggle」群組改為單擊**

在 `test/widgets/dialogs/zoomable_image_overlay_test.dart` 中，把整個 `group('ZoomableImageOverlay double-tap toggle', ...)`（含其內 `doubleTapAt` helper 與 4 個 testWidgets）整段替換為下列單擊版本：

```dart
  group('ZoomableImageOverlay single-tap toggle', () {
    double currentScale(WidgetTester tester) {
      final iv = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      return iv.transformationController!.value.getMaxScaleOnAxis();
    }

    testWidgets('from fit (scale=1), single tap goes to 2x', (tester) async {
      await openOverlay(tester);
      expect(currentScale(tester), 1.0);
      await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(currentScale(tester), closeTo(2.0, 1e-6));
    });

    testWidgets('from non-fit, single tap returns to fit (1x)', (tester) async {
      await openOverlay(tester);
      final center = tester.getCenter(find.byType(InteractiveViewer));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      for (var i = 0; i < 12; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0, -100),
          ),
        );
        await tester.pump();
      }
      expect(currentScale(tester), greaterThan(2.5));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 100));
      expect(currentScale(tester), closeTo(1.0, 1e-6));
    });

    testWidgets(
      'single tap back to fit at off-center clears translation (identity)',
      (tester) async {
        await openOverlay(tester);
        // 先單擊偏左上放大到 2x（產生 focal-centered translation）。
        final ivRect = tester.getRect(find.byType(InteractiveViewer));
        final offCenter = Offset(
          ivRect.left + ivRect.width * 0.25,
          ivRect.top + ivRect.height * 0.25,
        );
        await tester.tapAt(offCenter);
        await tester.pump(const Duration(milliseconds: 100));
        expect(currentScale(tester), closeTo(2.0, 1e-6));

        // 再單擊回 fit — matrix 必須是 identity（scale=1 AND translation=0）。
        await tester.tapAt(offCenter);
        await tester.pump(const Duration(milliseconds: 100));
        expect(currentScale(tester), closeTo(1.0, 1e-6));
        final iv = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        final translation = iv.transformationController!.value.getTranslation();
        expect(translation.x, closeTo(0, 1e-6));
        expect(translation.y, closeTo(0, 1e-6));
      },
    );
  });
```

- [ ] **Step 2: 更新「tap-to-close structure」內層 GD 斷言**

在同檔 `group('ZoomableImageOverlay tap-to-close structure', ...)` 內，找到第一個 testWidgets（標題 `'inner GD (image absorber) carries onTap (empty absorber) and onDoubleTapDown (zoom)'`）。把它整段替換為：

```dart
    testWidgets(
      'inner GD (image) carries onTapUp (single-tap zoom), no double-tap',
      (tester) async {
        await openOverlay(tester);

        // Image 外那層 GestureDetector 負責單擊縮放（onTapUp），並吸收 image
        // 像素上的點擊（不冒泡到外層的 close）。改成單擊後不再掛 onDoubleTap*。
        final innerGd = tester.widget<GestureDetector>(
          find
              .ancestor(
                of: find.byType(Image),
                matching: find.byType(GestureDetector),
              )
              .first,
        );
        expect(innerGd.behavior, HitTestBehavior.opaque);
        expect(innerGd.onTapUp, isNotNull);
        expect(innerGd.onDoubleTapDown, isNull);
        expect(innerGd.onDoubleTap, isNull);

        // 該 GestureDetector 要在 LayoutBuilder 出來的 SizedBox 內，hit-test
        // 範圍才會是 image painted rect。
        expect(
          find.ancestor(
            of: find.byType(Image),
            matching: find.byType(SizedBox),
          ),
          findsWidgets,
        );
        expect(
          find.ancestor(
            of: find.byType(Image),
            matching: find.byType(LayoutBuilder),
          ),
          findsOneWidget,
        );
      },
    );
```

（同群組第二個 testWidgets「outer InteractiveViewer wrapper has onTap (no onDoubleTap)」維持不變——外層仍是單純 onTap。）

- [ ] **Step 3: 跑測試，確認失敗（紅燈）**

Run: `fvm flutter test test/widgets/dialogs/zoomable_image_overlay_test.dart`
Expected: FAIL——`single-tap toggle` 三個測試與 structure 測試失敗（目前實作仍是 `onDoubleTapDown`、單擊無作用）。

- [ ] **Step 4: 改名常數 `_doubleTapScale` → `_zoomedScale`**

在 `lib/widgets/dialogs/zoomable_image_overlay.dart` 找到：

```dart
  /// 雙擊時的目標 scale；fit ↔ 2x 切換。
  static const double _doubleTapScale = 2.0;
```

替換為：

```dart
  /// 放大後的目標 scale；單擊／縮放鈕在 fit ↔ 2x 之間切換。
  static const double _zoomedScale = 2.0;
```

- [ ] **Step 5: 用 `_onTapZoom` 取代 `_onDoubleTapDown`**

找到：

```dart
  /// 雙擊：當前接近 fit → 放大到 [_doubleTapScale]；否則回 fit。以 tap 落點為焦點縮放。
  void _onDoubleTapDown(TapDownDetails details) {
    final current = _ctrl.value.getMaxScaleOnAxis();
    final atFit = (current - _minScale).abs() < 0.05;
    final target = atFit ? _doubleTapScale : _minScale;
    _zoomAt(localFocal: details.localPosition, scaleDelta: target / current);
  }
```

替換為：

```dart
  /// 單擊圖片：在 fit 時放大到 [_zoomedScale]（焦點 = 落點），否則回 fit。
  /// 取代雙擊——無 DoubleTapGR 後 tap 立即觸發，不受 kDoubleTapTimeout 影響。
  void _onTapZoom(TapUpDetails details) {
    final current = _ctrl.value.getMaxScaleOnAxis();
    final atFit = (current - _minScale).abs() < 0.05;
    if (atFit) {
      _zoomAt(
        localFocal: details.localPosition,
        scaleDelta: _zoomedScale / current,
      );
    } else {
      _ctrl.value = Matrix4.identity();
    }
  }
```

- [ ] **Step 6: 內層 GestureDetector 改掛 `onTapUp`**

找到內層 GestureDetector（在 `SizedBox` 內、包住 `Image` 那層）：

```dart
                        child: GestureDetector(
                          // 此層雙重職責：
                          // (1) 吸收 image 像素上的單擊（onTap 空 callback），
                          //     避免「想看細節點到圖片就關掉」。
                          // (2) 承擔雙擊縮放（onDoubleTapDown），讓外層 GD 維持
                          //     單純 onTap 不受 DoubleTapGR arbitration 拖延。
                          // 滾輪走 Listener、拖曳走 InteractiveViewer pan，皆不受
                          // 此處 opaque 影響（pan 在 movement>slop 時贏 arena）。
                          behavior: HitTestBehavior.opaque,
                          onTap: () {},
                          onDoubleTapDown: _onDoubleTapDown,
                          child: Image(
```

替換為：

```dart
                        child: GestureDetector(
                          // 此層承擔單擊縮放（onTapUp），並因 opaque hit-test 吸收
                          // image 像素上的點擊，避免冒泡到外層 GD 觸發關閉。
                          // 靜止點擊 → TapGR 贏 → 縮放；有位移 → InteractiveViewer
                          // pan 贏 → 平移；滾輪走 Listener，互不打架。
                          behavior: HitTestBehavior.opaque,
                          onTapUp: _onTapZoom,
                          child: Image(
```

- [ ] **Step 7: 跑測試，確認通過（綠燈）**

Run: `fvm flutter test test/widgets/dialogs/zoomable_image_overlay_test.dart`
Expected: PASS——`All tests passed!`（單擊群組與結構斷言皆綠；滾輪／關閉群組不受影響）。

- [ ] **Step 8: 格式化 + analyze**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 9: Commit**

```bash
git add lib/widgets/dialogs/zoomable_image_overlay.dart test/widgets/dialogs/zoomable_image_overlay_test.dart
git commit -m "feat(image-overlay): single-tap toggle zoom replacing double-tap"
```

---

## Task 3: 圖片區游標依縮放狀態切換

**Files:**
- Modify: `lib/widgets/dialogs/zoomable_image_overlay.dart`
- Test: `test/widgets/dialogs/zoomable_image_overlay_test.dart`

新增 `_isZoomed` 判斷，並用 `ValueListenableBuilder<Matrix4>(_ctrl)` 包一層 `MouseRegion`，游標在 fit 時 `zoomIn`、放大後 `zoomOut`。

- [ ] **Step 1: 寫失敗測試——游標隨 scale 切換**

在 `test/widgets/dialogs/zoomable_image_overlay_test.dart` 檔尾 `}` 前（最後一個 group 之後）新增：

```dart
  group('ZoomableImageOverlay cursor state', () {
    /// 取得包住 Image 的最近一層 MouseRegion 的 cursor。
    MouseCursor imageCursor(WidgetTester tester) {
      final mr = tester.widget<MouseRegion>(
        find
            .ancestor(
              of: find.byType(Image),
              matching: find.byType(MouseRegion),
            )
            .first,
      );
      return mr.cursor;
    }

    testWidgets('at fit, image cursor is zoomIn', (tester) async {
      await openOverlay(tester);
      expect(imageCursor(tester), SystemMouseCursors.zoomIn);
    });

    testWidgets('when zoomed (via wheel), image cursor is zoomOut', (
      tester,
    ) async {
      await openOverlay(tester);
      final center = tester.getCenter(find.byType(InteractiveViewer));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, -100)),
      );
      await tester.pump();
      expect(imageCursor(tester), SystemMouseCursors.zoomOut);
    });
  });
```

- [ ] **Step 2: 跑測試，確認失敗（紅燈）**

Run: `fvm flutter test test/widgets/dialogs/zoomable_image_overlay_test.dart -p vm --plain-name "cursor state"`
Expected: FAIL——找不到包住 Image 的 MouseRegion（目前 overlay 內未對圖片區設游標）。

- [ ] **Step 3: 新增 `_isZoomed` helper**

在 `lib/widgets/dialogs/zoomable_image_overlay.dart` 的 `_zoomAt(...)` 方法**之後**新增：

```dart
  /// 目前矩陣是否已放大（scale 明顯大於 fit）。游標與右上縮放鈕共用此判斷，
  /// 確保兩者狀態一致。
  bool _isZoomed(Matrix4 matrix) =>
      matrix.getMaxScaleOnAxis() > _minScale + 0.01;
```

- [ ] **Step 4: 用 ValueListenableBuilder + MouseRegion 包住內層 image**

找到 Step 6（Task 2）改好的 `SizedBox`（在 `LayoutBuilder` 的 `return` 內）：

```dart
                      return SizedBox(
                        width: w,
                        height: h,
                        child: GestureDetector(
                          // 此層承擔單擊縮放（onTapUp），並因 opaque hit-test 吸收
                          // image 像素上的點擊，避免冒泡到外層 GD 觸發關閉。
                          // 靜止點擊 → TapGR 贏 → 縮放；有位移 → InteractiveViewer
                          // pan 贏 → 平移；滾輪走 Listener，互不打架。
                          behavior: HitTestBehavior.opaque,
                          onTapUp: _onTapZoom,
                          child: Image(
                            image: _imageProvider,
                            fit: BoxFit.contain,
                            errorBuilder: (_, e, st) {
                              Logger('gacha.itemimage.zoom').warning(
                                'image errorBuilder file=${widget.imageFile.path}',
                                e,
                                st,
                              );
                              return const SizedBox.shrink();
                            },
                          ),
                        ),
                      );
```

替換為（把 GestureDetector+Image 當作不重建的 `child`，只讓 MouseRegion 隨 scale 重建）：

```dart
                      return SizedBox(
                        width: w,
                        height: h,
                        child: ValueListenableBuilder<Matrix4>(
                          valueListenable: _ctrl,
                          child: GestureDetector(
                            // 此層承擔單擊縮放（onTapUp），並因 opaque hit-test
                            // 吸收 image 像素上的點擊，避免冒泡到外層 GD 觸發關閉。
                            // 靜止點擊 → TapGR 贏 → 縮放；有位移 → InteractiveViewer
                            // pan 贏 → 平移；滾輪走 Listener，互不打架。
                            behavior: HitTestBehavior.opaque,
                            onTapUp: _onTapZoom,
                            child: Image(
                              image: _imageProvider,
                              fit: BoxFit.contain,
                              errorBuilder: (_, e, st) {
                                Logger('gacha.itemimage.zoom').warning(
                                  'image errorBuilder file=${widget.imageFile.path}',
                                  e,
                                  st,
                                );
                                return const SizedBox.shrink();
                              },
                            ),
                          ),
                          builder: (_, matrix, child) => MouseRegion(
                            cursor: _isZoomed(matrix)
                                ? SystemMouseCursors.zoomOut
                                : SystemMouseCursors.zoomIn,
                            child: child,
                          ),
                        ),
                      );
```

- [ ] **Step 5: 跑測試，確認通過（綠燈）**

Run: `fvm flutter test test/widgets/dialogs/zoomable_image_overlay_test.dart`
Expected: PASS——`All tests passed!`

- [ ] **Step 6: 格式化 + analyze**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add lib/widgets/dialogs/zoomable_image_overlay.dart test/widgets/dialogs/zoomable_image_overlay_test.dart
git commit -m "feat(image-overlay): state-driven zoom-in/out cursor over image"
```

---

## Task 4: 右上角縮放切換鈕（Discord 風格按鈕列）

**Files:**
- Modify: `lib/widgets/dialogs/zoomable_image_overlay.dart`
- Test: `test/widgets/dialogs/zoomable_image_overlay_test.dart`

把右上單顆 X 改為 `Row`：左為依狀態切換的縮放鈕、右為關閉鈕。抽出 `_OverlayCircleButton` 統一外觀。縮放鈕以 viewport 中心為焦點。

- [ ] **Step 1: 寫失敗測試——縮放鈕存在且能 fit↔2x**

在 `test/widgets/dialogs/zoomable_image_overlay_test.dart` 檔尾 `}` 前新增：

```dart
  group('ZoomableImageOverlay zoom toggle button', () {
    double currentScale(WidgetTester tester) {
      final iv = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      return iv.transformationController!.value.getMaxScaleOnAxis();
    }

    AppLocalizations loc(WidgetTester tester) =>
        AppLocalizations.of(tester.element(find.byType(ZoomableImageOverlay)))!;

    testWidgets('at fit shows zoom-in button; pressing it zooms to 2x', (
      tester,
    ) async {
      await openOverlay(tester);
      final l = loc(tester);
      expect(currentScale(tester), 1.0);
      expect(find.byTooltip(l.actionZoomIn), findsOneWidget);
      expect(find.byTooltip(l.actionZoomOut), findsNothing);

      await tester.tap(find.byTooltip(l.actionZoomIn));
      await tester.pump(const Duration(milliseconds: 100));
      expect(currentScale(tester), closeTo(2.0, 1e-6));
    });

    testWidgets('when zoomed shows zoom-out button; pressing it returns to fit', (
      tester,
    ) async {
      await openOverlay(tester);
      final l = loc(tester);
      await tester.tap(find.byTooltip(l.actionZoomIn));
      await tester.pump(const Duration(milliseconds: 100));
      expect(currentScale(tester), closeTo(2.0, 1e-6));

      expect(find.byTooltip(l.actionZoomOut), findsOneWidget);
      await tester.tap(find.byTooltip(l.actionZoomOut));
      await tester.pump(const Duration(milliseconds: 100));
      expect(currentScale(tester), closeTo(1.0, 1e-6));

      final iv = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      final translation = iv.transformationController!.value.getTranslation();
      expect(translation.x, closeTo(0, 1e-6));
      expect(translation.y, closeTo(0, 1e-6));
    });

    testWidgets('close button still present with its own tooltip', (
      tester,
    ) async {
      await openOverlay(tester);
      final l = loc(tester);
      expect(find.byTooltip(l.actionCloseImagePreview), findsOneWidget);
    });
  });
```

確認該測試檔頂部已 import `AppLocalizations`（既有 import：`package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart;`——已存在，無需新增）。

- [ ] **Step 2: 跑測試，確認失敗（紅燈）**

Run: `fvm flutter test test/widgets/dialogs/zoomable_image_overlay_test.dart -p vm --plain-name "zoom toggle button"`
Expected: FAIL——找不到 `actionZoomIn` tooltip 的按鈕（目前右上只有 close）。

- [ ] **Step 3: 新增 `_ivKey` 欄位並掛到 InteractiveViewer**

在 `_ZoomableImageOverlayState` 的欄位區（`_ctrl` 宣告附近）新增：

```dart
  /// InteractiveViewer 的 key；右上縮放鈕用它取 viewport render size，以
  /// viewport 中心為焦點縮放（按鈕不像點擊那樣有落點）。
  final GlobalKey _ivKey = GlobalKey();
```

並在 `InteractiveViewer(` 建構處加上 `key`：

```dart
              child: InteractiveViewer(
                key: _ivKey,
                transformationController: _ctrl,
```

- [ ] **Step 4: 新增 `_onZoomButtonPressed` 方法**

在 `_onTapZoom(...)` 之後新增：

```dart
  /// 右上縮放鈕：fit 時放大到 [_zoomedScale]（焦點 = viewport 中心），否則回 fit。
  void _onZoomButtonPressed() {
    if (_isZoomed(_ctrl.value)) {
      _ctrl.value = Matrix4.identity();
      return;
    }
    final current = _ctrl.value.getMaxScaleOnAxis();
    final box = _ivKey.currentContext?.findRenderObject() as RenderBox?;
    final focal = box != null
        ? box.size.center(Offset.zero)
        : Offset.zero;
    _zoomAt(localFocal: focal, scaleDelta: _zoomedScale / current);
  }
```

- [ ] **Step 5: 把右上單顆 X 換成按鈕列**

找到目前的 close 按鈕區塊：

```dart
        // X 按鈕 — 半透明黑底圓鈕，永遠最上層。
        Positioned(
          top: 16,
          right: 16,
          child: Material(
            color: Colors.black.withValues(alpha: 0.4),
            shape: const CircleBorder(),
            child: IconButton(
              tooltip: l.actionCloseImagePreview,
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => _close('button'),
            ),
          ),
        ),
```

替換為（縮放鈕隨 scale 重建，close 鈕固定）：

```dart
        // 右上按鈕列 — 縮放切換鈕 + 關閉鈕，半透明黑底圓鈕，永遠最上層。
        Positioned(
          top: 16,
          right: 16,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<Matrix4>(
                valueListenable: _ctrl,
                builder: (_, matrix, __) {
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
        ),
```

- [ ] **Step 6: 新增 `_OverlayCircleButton` widget**

在檔案最末（`_ZoomableImageOverlayState` class 的 `}` 之後）新增：

```dart
/// overlay 右上角的半透明黑底圓形按鈕；統一 close／zoom 兩鈕的外觀。
class _OverlayCircleButton extends StatelessWidget {
  /// 建立 [_OverlayCircleButton]。
  const _OverlayCircleButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  /// tooltip 文字，同時擔任 semantic label。
  final String tooltip;

  /// 按鈕 icon。
  final IconData icon;

  /// 點擊 callback。
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, color: Colors.white),
        onPressed: onPressed,
      ),
    );
  }
}
```

- [ ] **Step 7: 跑測試，確認通過（綠燈）**

Run: `fvm flutter test test/widgets/dialogs/zoomable_image_overlay_test.dart`
Expected: PASS——`All tests passed!`（含既有「tap X button closes overlay」仍綠，close tooltip 未變）。

- [ ] **Step 8: 格式化 + analyze**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 9: Commit**

```bash
git add lib/widgets/dialogs/zoomable_image_overlay.dart test/widgets/dialogs/zoomable_image_overlay_test.dart
git commit -m "feat(image-overlay): Discord-style zoom toggle button in top-right"
```

---

## Task 5: 全套驗證與手動檢查

**Files:** 無新增改動，僅驗證。

- [ ] **Step 1: 全套品質檢查**

Run: `fvm dart format lib/ test/`
Run: `fvm flutter analyze`
Expected: `No issues found!`
Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 2: 手動驗證（release）**

Run: `fvm flutter run --release`

進 app → 開一張 5★ 角色 detail dialog → 點立繪 chip → 點主圖開 overlay，逐項確認：

- hover 圖片時，fit 顯示放大鏡＋游標、放大後顯示放大鏡−游標。
- 單擊圖片在 fit ↔ 2x 來回切換，且以落點為焦點。
- 右上縮放鈕 icon／tooltip 隨狀態切換（zoom_in↔zoom_out），按下正確 fit↔2x（以畫面中心）。
- 滾輪以游標為中心連續縮放、放大後拖曳平移仍正常。
- 點 letterbox 暗區／黑底、ESC、X 鈕都能關閉。
- GIF 圖在 overlay 下仍會動。

- [ ] **Step 3: （可選）若手動發現問題**

回對應 Task 修正後重跑 Step 1。全綠且手動通過即完成。不要 `git push`（依 CLAUDE.md，使用者要求才推）。

---

## Self-Review Notes

- **Spec coverage**：單擊 fit↔2x（Task 2）、移除雙擊（Task 2）、游標切換（Task 3）、右上縮放切換鈕（Task 4）、`actionZoomIn`／`actionZoomOut`（Task 1）、滾輪／拖曳／ESC／背景關閉保留（不改、Task 5 手動驗證）、ValueListenableBuilder 驅動（Task 3／4）、測試更新（各 Task）——皆有對應任務。
- **型別一致**：`_zoomedScale`（Task 2 改名後）於 Task 2／4 一致；`_isZoomed(Matrix4)`（Task 3 定義）於 Task 3／4 一致；`_OverlayCircleButton` 簽名（Task 4）與其呼叫處一致；`_ivKey`（Task 4）定義與使用一致。
- **無 placeholder**：所有 code step 皆附完整程式碼與 old→new 對照。
