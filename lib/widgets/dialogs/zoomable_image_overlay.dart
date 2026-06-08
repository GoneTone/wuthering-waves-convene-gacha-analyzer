import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';

/// 開啟全螢幕 lightbox 顯示 [imageFile]，可拖曳平移、滾輪 / 單擊縮放、ESC / 點背景 / X 關閉。
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

/// 全螢幕 lightbox 圖片檢視器；獨立可重用，不耦合 caller。
class ZoomableImageOverlay extends StatefulWidget {
  /// 建立 [ZoomableImageOverlay]。
  const ZoomableImageOverlay({super.key, required this.imageFile});

  /// 要顯示的本地圖檔。
  final File imageFile;

  @override
  State<ZoomableImageOverlay> createState() => _ZoomableImageOverlayState();
}

/// [ZoomableImageOverlay] 的 state — 管理 [_ctrl] 縮放矩陣與 close 路徑。
class _ZoomableImageOverlayState extends State<ZoomableImageOverlay> {
  /// 縮放最小值（= fit，整圖可見）。
  static const double _minScale = 1.0;

  /// 縮放最大值。
  static const double _maxScale = 5.0;

  /// 滑鼠滾輪每一格的縮放係數（×1.1 in / ÷1.1 out）。
  static const double _wheelStep = 1.1;

  /// 放大後的目標 scale；單擊／縮放鈕在 fit ↔ 2x 之間切換。
  static const double _zoomedScale = 2.0;

  /// 控制 InteractiveViewer 的 Matrix4；wheel / 單擊會手動設置 scale，
  /// InteractiveViewer 自動處理 pan。
  final TransformationController _ctrl = TransformationController();

  /// InteractiveViewer 的 key；右上縮放鈕用它取 viewport render size，以
  /// viewport 中心為焦點縮放（按鈕不像點擊那樣有落點）。
  final GlobalKey _ivKey = GlobalKey();

  /// 共用的 [FileImage] provider；同時餵給 [Image] 渲染與 [_stream] 取得 intrinsic size，
  /// 避免兩次 decode。
  late final FileImage _imageProvider = FileImage(widget.imageFile);

  /// [_imageProvider] resolve 出的 stream；用來監聽 decode 完成事件以取得 intrinsic size。
  ImageStream? _stream;

  /// 監聽 image decode 完成的 listener；[dispose] 內 removeListener 解除註冊。
  late final ImageStreamListener _streamListener = ImageStreamListener((
    info,
    _,
  ) {
    if (!mounted) return;
    setState(() {
      _imageSize = Size(
        info.image.width.toDouble(),
        info.image.height.toDouble(),
      );
    });
  });

  /// image 的 intrinsic 大小；null 時為 decode 尚未完成。用來把 image 像素區的
  /// tap absorber 精準框在 BoxFit.contain 後的 painted rect 上，讓暗區的 tap
  /// 能傳到外層 GestureDetector 觸發關閉。
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    _stream = _imageProvider.resolve(ImageConfiguration.empty);
    _stream!.addListener(_streamListener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_streamListener);
    _ctrl.dispose();
    super.dispose();
  }

  /// 關 overlay 並 log 來源。[reason] 走 `backdrop | outside-image | button` 三選一；ESC 由 Navigator barrierDismissible 處理，不經此路徑。
  void _close(String reason) {
    Logger('gacha.itemimage.zoom').info('overlay close reason=$reason');
    Navigator.of(context).pop();
  }

  /// 以 [localFocal]（Listener / InteractiveViewer 局部座標）為中心套用 [scaleDelta]
  /// 倍縮放。公式：T(focal) · S(delta) · T(-focal) · M，確保焦點 scene 位置在縮放後不動。
  /// 新 scale 會 clamp 在 [_minScale]..[_maxScale]。
  void _zoomAt({required Offset localFocal, required double scaleDelta}) {
    final current = _ctrl.value.getMaxScaleOnAxis();
    final next = (current * scaleDelta).clamp(_minScale, _maxScale);
    // 回到 fit（_minScale）→ 強制單位矩陣，否則 focal-centered 縮放公式會留下
    // translation 殘量，讓 scale=1 時圖片仍偏離 viewport（要拖一下 InteractiveViewer
    // 的 pan handler 才會 clamp 回來）。InteractiveViewer 的 constrained=true 只
    // 在使用者互動 pan 時 clamp，手動寫 matrix 必須自己處理。
    if ((next - _minScale).abs() < 1e-6) {
      _ctrl.value = Matrix4.identity();
      return;
    }
    final actual = next / current;
    if ((actual - 1).abs() < 1e-6) return;
    _ctrl.value =
        (Matrix4.identity()
          ..translateByDouble(localFocal.dx, localFocal.dy, 0, 1)
          ..scaleByDouble(actual, actual, actual, 1)
          ..translateByDouble(-localFocal.dx, -localFocal.dy, 0, 1)) *
        _ctrl.value;
  }

  /// 目前矩陣是否已放大（scale 明顯大於 fit）。游標與右上縮放鈕共用此判斷，
  /// 確保兩者狀態一致。
  bool _isZoomed(Matrix4 matrix) =>
      matrix.getMaxScaleOnAxis() > _minScale + 0.01;

  /// 處理 mouse wheel：向上（scrollDelta.dy < 0）放大、向下縮小，以游標為中心。
  /// 純水平滾動（dy == 0）忽略，避免 trackpad 兩指水平滑動誤觸發縮放。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dy == 0) return;
    final delta = event.scrollDelta.dy < 0 ? _wheelStep : 1 / _wheelStep;
    _zoomAt(localFocal: event.localPosition, scaleDelta: delta);
  }

  /// 單擊圖片：在 fit 時放大到 [_zoomedScale]（焦點 = 落點），否則回 fit。
  /// 回 fit 直接寫 `Matrix4.identity()`（非走 `_zoomAt`），確保 translation 同步歸零。
  /// 取代雙擊——無 DoubleTapGR 後 tap 立即觸發，不受 kDoubleTapTimeout 影響。
  void _onTapZoom(TapUpDetails details) {
    if (_isZoomed(_ctrl.value)) {
      _ctrl.value = Matrix4.identity();
      return;
    }
    final current = _ctrl.value.getMaxScaleOnAxis();
    _zoomAt(
      localFocal: details.localPosition,
      scaleDelta: _zoomedScale / current,
    );
  }

  /// 右上縮放鈕：fit 時放大到 [_zoomedScale]（焦點 = viewport 中心），否則回 fit。
  void _onZoomButtonPressed() {
    if (_isZoomed(_ctrl.value)) {
      _ctrl.value = Matrix4.identity();
      return;
    }
    final current = _ctrl.value.getMaxScaleOnAxis();
    final box = _ivKey.currentContext?.findRenderObject() as RenderBox?;
    final focal = box != null ? box.size.center(Offset.zero) : Offset.zero;
    _zoomAt(localFocal: focal, scaleDelta: _zoomedScale / current);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Stack(
      children: [
        // backdrop — 滿屏，點任一處（落在 InteractiveViewer 以外）即關閉。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _close('backdrop'),
          ),
        ),
        // 中央圖片區 — 留 48px padding 給 backdrop tap 區。
        Padding(
          padding: const EdgeInsets.all(48),
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: GestureDetector(
              // image 像素外的暗區（BoxFit.contain 留白）也視為背景，點擊立即關閉。
              // 只掛 onTap（不掛 onDoubleTap），避免日後若有人加 DoubleTapGR 進同一
              // arena 會讓此 tap 被 kDoubleTapTimeout（300ms）拖延才 fire。
              onTap: () => _close('outside-image'),
              child: InteractiveViewer(
                key: _ivKey,
                transformationController: _ctrl,
                panEnabled: true,
                // wheel / 單擊自管 scale，避免兩套 scale source 打架。
                scaleEnabled: false,
                minScale: _minScale,
                maxScale: _maxScale,
                child: Center(
                  // 把 image 包進 SizedBox 並 size 到 BoxFit.contain 後的 painted
                  // rect，讓內層 GestureDetector absorber 只覆蓋圖片像素區；image
                  // 外的 letterbox 暗區留給外層 GestureDetector 處理 onTap 關閉。
                  // _imageSize 為 null（decode 尚未完成）時退化為填滿可用空間，
                  // 此時 absorber 暫時覆蓋整個 viewer；本地檔案 decode 通常在
                  // 第一幀就完成，使用者察覺不到。
                  child: LayoutBuilder(
                    builder: (_, constraints) {
                      final imgSize = _imageSize;
                      double w = constraints.maxWidth;
                      double h = constraints.maxHeight;
                      if (imgSize != null &&
                          imgSize.width > 0 &&
                          imgSize.height > 0) {
                        final scale = (w / imgSize.width) < (h / imgSize.height)
                            ? w / imgSize.width
                            : h / imgSize.height;
                        w = imgSize.width * scale;
                        h = imgSize.height * scale;
                      }
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
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
        // 右上按鈕列 — 縮放切換鈕 + 關閉鈕，半透明黑底圓鈕，永遠最上層。
        Positioned(
          top: 16,
          right: 16,
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
        ),
      ],
    );
  }
}

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
