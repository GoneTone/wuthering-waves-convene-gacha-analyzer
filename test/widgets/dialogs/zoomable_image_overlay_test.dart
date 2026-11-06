import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_save.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/zoomable_image_overlay.dart';

/// 1×1 透明 PNG，最小可被 Flutter decode 的 valid PNG。
const List<int> _onePxPng = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

/// 取得目前 InteractiveViewer 的 scale（最大軸）。
double currentScale(WidgetTester tester) {
  final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
  return iv.transformationController!.value.getMaxScaleOnAxis();
}

void main() {
  late Directory tempDir;
  late File imageFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zoom_overlay_test_');
    imageFile = File('${tempDir.path}/test.png');
    await imageFile.writeAsBytes(_onePxPng);
  });

  tearDown(() async {
    // per memory project_image_cache_cross_test_race
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  /// 把 [showZoomableImageOverlay] 開出來的 widget 在乾淨 MaterialApp 內呈現。
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

  group('ZoomableImageOverlay open/close', () {
    testWidgets('opens with Image.file rendering the given file', (
      tester,
    ) async {
      await openOverlay(tester);
      expect(find.byType(ZoomableImageOverlay), findsOneWidget);
      final img = tester.widget<Image>(
        find.descendant(
          of: find.byType(ZoomableImageOverlay),
          matching: find.byType(Image),
        ),
      );
      expect(img.image, isA<FileImage>());
      expect((img.image as FileImage).file.path, imageFile.path);
    });

    testWidgets('ESC closes overlay', (tester) async {
      await openOverlay(tester);
      expect(find.byType(ZoomableImageOverlay), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ZoomableImageOverlay), findsNothing);
    });

    testWidgets('tap on backdrop area closes overlay', (tester) async {
      await openOverlay(tester);
      expect(find.byType(ZoomableImageOverlay), findsOneWidget);
      // 點視窗左上角 (5,5) — 必定落在 InteractiveViewer 以外的 backdrop padding。
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(ZoomableImageOverlay), findsNothing);
    });

    testWidgets('tap X button closes overlay', (tester) async {
      await openOverlay(tester);
      final l = AppLocalizations.of(
        tester.element(find.byType(ZoomableImageOverlay)),
      )!;
      // X 按鈕用 tooltip 識別（同時是 a11y label）。
      await tester.tap(find.byTooltip(l.actionCloseImagePreview));
      await tester.pumpAndSettle();
      expect(find.byType(ZoomableImageOverlay), findsNothing);
    });
  });

  group('ZoomableImageOverlay InteractiveViewer wiring', () {
    testWidgets('uses InteractiveViewer with pinch zoom and pan enabled', (
      tester,
    ) async {
      await openOverlay(tester);
      final iv = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(iv.scaleEnabled, isTrue);
      expect(iv.panEnabled, isTrue);
      expect(iv.minScale, 1.0);
      expect(iv.maxScale, 5.0);
    });

    testWidgets('initial transform is identity (scale = 1)', (tester) async {
      await openOverlay(tester);
      final iv = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(iv.transformationController!.value.getMaxScaleOnAxis(), 1.0);
    });
  });

  group('ZoomableImageOverlay wheel zoom', () {
    /// 對 [position] 派發一次滾輪事件。[deltaY] 為 scrollDelta.dy；負值 = 向上 = 放大。
    Future<void> sendWheel(
      WidgetTester tester,
      Offset position,
      double deltaY,
    ) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(position));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: position, scrollDelta: Offset(0, deltaY)),
      );
      await tester.pump();
    }

    testWidgets('wheel up zooms in (scale > 1)', (tester) async {
      await openOverlay(tester);
      expect(currentScale(tester), 1.0);
      final center = tester.getCenter(find.byType(InteractiveViewer));
      await sendWheel(tester, center, -100);
      expect(currentScale(tester), greaterThan(1.0));
    });

    testWidgets('one wheel step zooms exactly 1.1x', (tester) async {
      // 開了雙指縮放後 InteractiveViewer 也會自己處理滾輪；不能和這裡的縮放疊加。
      await openOverlay(tester);
      final center = tester.getCenter(find.byType(InteractiveViewer));
      await sendWheel(tester, center, -100);
      expect(currentScale(tester), closeTo(1.1, 1e-6));
    });

    testWidgets('wheel down at fit stays at minScale', (tester) async {
      await openOverlay(tester);
      final center = tester.getCenter(find.byType(InteractiveViewer));
      await sendWheel(tester, center, 100);
      expect(currentScale(tester), 1.0);
    });

    testWidgets('many wheel ups clamp at maxScale (5.0)', (tester) async {
      await openOverlay(tester);
      final center = tester.getCenter(find.byType(InteractiveViewer));
      // 1.1^20 ≈ 6.7 > 5.0；確保打到上限。
      for (var i = 0; i < 20; i++) {
        await sendWheel(tester, center, -100);
      }
      expect(currentScale(tester), closeTo(5.0, 1e-6));
    });

    testWidgets('cursor-centered: zoom at offset keeps scene point at cursor', (
      tester,
    ) async {
      await openOverlay(tester);
      final ivFinder = find.byType(InteractiveViewer);
      final ivCenter = tester.getCenter(ivFinder);
      final ivRect = tester.getRect(ivFinder);
      // 選一個離中心明顯偏右下的點。
      final focal = Offset(ivCenter.dx + 100, ivCenter.dy + 80);
      final focalLocal = focal - ivRect.topLeft;

      final iv = tester.widget<InteractiveViewer>(ivFinder);
      final ctrl = iv.transformationController!;

      // scale = 1 時，scene point 對應 cursor 局部座標的「圖內位置」= focalLocal
      // （恆等變換）。
      final beforeScene = ctrl.toScene(focalLocal);

      await sendWheel(tester, focal, -100);
      // 縮放後，同一 scene point 應該還是落在 focalLocal 附近（cursor-centered 不變）。
      final afterScene = ctrl.toScene(focalLocal);
      expect((afterScene - beforeScene).distance, lessThan(1.0));
    });

    testWidgets('horizontal wheel scroll does not zoom', (tester) async {
      await openOverlay(tester);
      final center = tester.getCenter(find.byType(InteractiveViewer));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(100, 0)),
      );
      await tester.pump();
      expect(currentScale(tester), 1.0);
    });
  });

  group('ZoomableImageOverlay single-tap toggle', () {
    testWidgets('from fit (scale=1), single tap goes to 2x', (tester) async {
      await openOverlay(tester);
      expect(currentScale(tester), 1.0);
      await tester.tapAt(
        tester.getCenter(find.byType(InteractiveViewer)),
        kind: PointerDeviceKind.mouse,
      );
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
      await tester.tapAt(center, kind: PointerDeviceKind.mouse);
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
        await tester.tapAt(offCenter, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 100));
        expect(currentScale(tester), closeTo(2.0, 1e-6));

        // 再單擊回 fit — matrix 必須是 identity（scale=1 AND translation=0）。
        await tester.tapAt(offCenter, kind: PointerDeviceKind.mouse);
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

  group('ZoomableImageOverlay wheel zoom identity reset', () {
    testWidgets(
      'wheel-zoom-out clamped to minScale also resets matrix to identity',
      (tester) async {
        await openOverlay(tester);
        final center = tester.getCenter(find.byType(InteractiveViewer));
        // 焦點刻意偏中心以製造非零 translation。
        final offCenter = Offset(center.dx + 80, center.dy + 60);
        final pointer = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(offCenter));
        for (var i = 0; i < 6; i++) {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: offCenter,
              scrollDelta: const Offset(0, -100),
            ),
          );
          await tester.pump();
        }
        expect(currentScale(tester), greaterThan(1.5));

        // zoom out 大量格數確保 clamp 到 minScale。
        for (var i = 0; i < 20; i++) {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: offCenter,
              scrollDelta: const Offset(0, 100),
            ),
          );
          await tester.pump();
        }
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
        PointerScrollEvent(
          position: center,
          scrollDelta: const Offset(0, -100),
        ),
      );
      await tester.pump();
      expect(imageCursor(tester), SystemMouseCursors.zoomOut);
    });
  });

  group('ZoomableImageOverlay zoom toggle button', () {
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

    testWidgets(
      'when zoomed shows zoom-out button; pressing it returns to fit',
      (tester) async {
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
      },
    );

    testWidgets('close button still present with its own tooltip', (
      tester,
    ) async {
      await openOverlay(tester);
      final l = loc(tester);
      expect(find.byTooltip(l.actionCloseImagePreview), findsOneWidget);
    });
  });

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

    /// 開 ... 選單並點選 [itemText]。
    /// itemImageEncoder seam 已換成同步回傳，故 pumpAndSettle 即可讓所有 future 完成。
    Future<void> pickMenu(WidgetTester tester, String itemText) async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text(itemText));
      await tester.pumpAndSettle();
    }

    testWidgets('copy writes PNG to clipboard and shows copied toast', (
      tester,
    ) async {
      var copyCalled = false;
      itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
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

    testWidgets(
      'save calls picker with suggestedFileName and shows saved toast',
      (tester) async {
        String? capturedName;
        String? writtenPath;
        final tmp = '${tempDir.path}/saved.png';
        itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
        itemImageSaveLocationPicker = (name) async {
          capturedName = name;
          return FileSaveLocation(tmp);
        };
        itemImageFileWriter = (path, png) async {
          writtenPath = path;
        };
        await openOverlay(tester, suggestedFileName: 'Char_Splash.png');
        final l = loc(tester);
        await pickMenu(tester, l.actionSaveImage);
        expect(capturedName, 'Char_Splash.png');
        expect(writtenPath, tmp);
        expect(find.text(l.itemImageSavedTo(tmp)), findsOneWidget);
      },
    );

    testWidgets('save cancelled shows no toast', (tester) async {
      itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
      itemImageSaveLocationPicker = (name) async => null;
      await openOverlay(tester);
      final l = loc(tester);
      await pickMenu(tester, l.actionSaveImage);
      expect(find.byKey(const ValueKey('dialogToast')), findsNothing);
    });

    testWidgets('save without suggestedFileName falls back to file basename', (
      tester,
    ) async {
      String? capturedName;
      itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
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

  group('ZoomableImageOverlay tap-to-close structure', () {
    // 行為層測試（dim 區 tap 真的關 / image 區 tap 真的不關）需要 image
    // 實際 decode 完成才能驗證 SizedBox 縮到 painted rect；testWidgets 沒有
    // 可靠的 file codec 同步路徑，因此這裡只測結構，行為由使用者 manual 驗證。

    testWidgets(
      'inner GD (image) carries onTapUp (single-tap zoom), no double-tap',
      (tester) async {
        await openOverlay(tester);

        // Image 外那層 GestureDetector 負責單擊縮放（onTapUp），並吸收 image
        // 像素上的點擊（不冒泡到外層的 close）。改成單擊後不再掛 onDoubleTap*。
        // 最內層另有一個只處理觸控長按的 GestureDetector；這裡找負責單擊縮放的那一層。
        final innerGd = tester
            .widgetList<GestureDetector>(
              find.ancestor(
                of: find.byType(Image),
                matching: find.byType(GestureDetector),
              ),
            )
            .firstWhere((g) => g.onTapUp != null);
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

    testWidgets(
      'outer InteractiveViewer wrapper has onTap (no onDoubleTap) for instant dim-area close',
      (tester) async {
        await openOverlay(tester);

        // 包住 InteractiveViewer 的 GestureDetector 必須只有 onTap、不可掛
        // onDoubleTap*：與 DoubleTapGR 在同一 arena 競爭會讓 onTap 被
        // kDoubleTapTimeout（300ms）卡住才 fire，造成可感知延遲。
        final outerGd = tester.widget<GestureDetector>(
          find
              .ancestor(
                of: find.byType(InteractiveViewer),
                matching: find.byType(GestureDetector),
              )
              .first,
        );
        expect(outerGd.onTap, isNotNull);
        expect(outerGd.onDoubleTap, isNull);
        expect(outerGd.onDoubleTapDown, isNull);
      },
    );
  });

  group('ZoomableImageOverlay touch', () {
    AppLocalizations loc(WidgetTester tester) =>
        AppLocalizations.of(tester.element(find.byType(ZoomableImageOverlay)))!;

    Offset center(WidgetTester tester) =>
        tester.getCenter(find.byType(InteractiveViewer));

    testWidgets('pinch zooms in', (tester) async {
      await openOverlay(tester);
      final c = center(tester);
      final g1 = await tester.startGesture(c - const Offset(20, 0), pointer: 1);
      final g2 = await tester.startGesture(c + const Offset(20, 0), pointer: 2);
      for (var i = 0; i < 5; i++) {
        await g1.moveBy(const Offset(-20, 0));
        await g2.moveBy(const Offset(20, 0));
        await tester.pump();
      }
      await g1.up();
      await g2.up();
      await tester.pump();
      expect(currentScale(tester), greaterThan(1.0));
    });

    testWidgets('single touch tap does nothing', (tester) async {
      await openOverlay(tester);
      await tester.tapAt(center(tester));
      await tester.pump(const Duration(milliseconds: 400));
      expect(currentScale(tester), 1.0);
      expect(find.byType(ZoomableImageOverlay), findsOneWidget);
    });

    testWidgets('double touch tap toggles zoom', (tester) async {
      await openOverlay(tester);
      final c = center(tester);
      await tester.tapAt(c);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(c);
      await tester.pump();
      expect(currentScale(tester), closeTo(2.0, 1e-6));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(c);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(c);
      await tester.pump();
      expect(currentScale(tester), closeTo(1.0, 1e-6));
    });

    testWidgets('mouse click zooms immediately', (tester) async {
      await openOverlay(tester);
      await tester.tapAt(center(tester), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(currentScale(tester), closeTo(2.0, 1e-6));
    });

    testWidgets('long press opens the image menu', (tester) async {
      await openOverlay(tester);
      final l = loc(tester);
      await tester.longPressAt(center(tester));
      await tester.pumpAndSettle();
      expect(find.text(l.actionCopyImage), findsOneWidget);
      expect(find.text(l.actionSaveImage), findsOneWidget);
    });

    testWidgets('mouse long press still zooms instead of opening the menu', (
      tester,
    ) async {
      // 桌面行為不變：滑鼠按久一點放開仍是單擊縮放，不會跳出選單。
      await openOverlay(tester);
      final l = loc(tester);
      await tester.longPressAt(center(tester), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.text(l.actionCopyImage), findsNothing);
      expect(currentScale(tester), closeTo(2.0, 1e-6));
    });

    testWidgets('swipe down closes when not zoomed', (tester) async {
      await openOverlay(tester);
      await tester.dragFrom(center(tester), const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(find.byType(ZoomableImageOverlay), findsNothing);
    });

    testWidgets('swipe down pans when zoomed', (tester) async {
      await openOverlay(tester);
      await tester.tapAt(center(tester), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.dragFrom(center(tester), const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(find.byType(ZoomableImageOverlay), findsOneWidget);
    });

    testWidgets('mouse drag down does not close', (tester) async {
      await openOverlay(tester);
      await tester.dragFrom(
        center(tester),
        const Offset(0, 200),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ZoomableImageOverlay), findsOneWidget);
    });

    testWidgets('rotating resets the zoom', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await openOverlay(tester);
      await tester.tapAt(center(tester), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(currentScale(tester), closeTo(2.0, 1e-6));
      tester.view.physicalSize = const Size(800, 360);
      await tester.pump();
      await tester.pump();
      expect(currentScale(tester), 1.0);
    });

    testWidgets('phone padding is 8', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await openOverlay(tester);
      expect(tester.getRect(find.byType(InteractiveViewer)).left, 8);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
}
