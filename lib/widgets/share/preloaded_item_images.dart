import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_lookup.dart';

final _log = Logger('gacha.itemimage.preload');

/// 提供分享圖 sync pipeline 用的預解碼 icon [ui.Image] map（key = resourceId）。
class PreloadedItemImages extends InheritedWidget {
  /// 建立 [PreloadedItemImages]。
  const PreloadedItemImages({
    super.key,
    required this.images,
    required super.child,
  });

  /// resourceId → 預解碼的 [ui.Image]（已 owned；render 結束需 dispose）。
  final Map<int, ui.Image> images;

  /// 從祖先 [PreloadedItemImages] 取得；不存在回 null。
  static PreloadedItemImages? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PreloadedItemImages>();

  @override
  bool updateShouldNotify(PreloadedItemImages oldWidget) =>
      !identical(images, oldWidget.images);
}

/// 預解碼 [records] 對應的角色 icon cache 檔成 [ui.Image] map。
///
/// 只預載有圖（[hasItemImage] 為 true）且 cache 檔在的角色 icon；其餘 record
/// 直接跳過（分享圖內走 placeholder）。illustration 大圖不進 preload（體積大）。
/// 回傳的 map 須由 caller 在 render 結束後呼叫 [disposePreloadedItemImages] 釋放。
Future<Map<int, ui.Image>> preloadItemImages({
  required ItemImageIndex index,
  required Directory cacheDir,
  required Iterable<GachaRecord> records,
}) async {
  final out = <int, ui.Image>{};
  for (final r in records) {
    if (out.containsKey(r.resourceId)) continue;
    if (!hasItemImage(index, r)) continue;
    final entry = index.lookupImage(r.resourceId)!;
    final file = itemIconCacheFile(
      baseDir: cacheDir,
      resourceId: r.resourceId,
      url: entry.iconUrl!,
    );
    if (!file.existsSync()) continue;
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      out[r.resourceId] = frame.image;
    } catch (e, st) {
      _log.warning('preload decode failed resourceId=${r.resourceId}', e, st);
    }
  }
  return out;
}

/// dispose 由 [preloadItemImages] 產出的所有 [ui.Image]。
void disposePreloadedItemImages(Map<int, ui.Image> images) {
  for (final img in images.values) {
    img.dispose();
  }
}
