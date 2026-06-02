import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';

/// Logger 實例（item_image.usage 命名空間）。
final _log = Logger('item_image.usage');

/// 物品圖片快取用量分項。
@immutable
class ItemImageCacheUsage {
  /// 建立 [ItemImageCacheUsage]。
  const ItemImageCacheUsage({
    required this.iconBytes,
    required this.illustrationBytes,
  });

  /// 角色 icon 圖檔總大小（bytes）。
  final int iconBytes;

  /// 角色 illustration 大圖圖檔總大小（bytes）。
  final int illustrationBytes;

  /// icon + illustration 總和。
  int get totalBytes => iconBytes + illustrationBytes;
}

/// 掃描 [itemImageCacheDirProvider] 目錄，分項計算 icon 與 illustration 總大小。
///
/// `autoDispose` → 離開設定頁自動釋放，下次進設定頁重新計算。
/// 失敗（權限等）讓 `FutureProvider` 自然進 `AsyncError` 狀態。
final itemImageCacheUsageProvider =
    FutureProvider.autoDispose<ItemImageCacheUsage>((ref) async {
      final dir = ref.read(itemImageCacheDirProvider);
      if (!await dir.exists()) {
        _log.fine('cache dir not exist → zero');
        return const ItemImageCacheUsage(iconBytes: 0, illustrationBytes: 0);
      }
      var iconBytes = 0;
      var illustrationBytes = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final path = entity.path;
        final size = await entity.length();
        if (path.contains('_illustration') || path.contains('_luckdraw')) {
          illustrationBytes += size;
        } else if (path.contains('_icon.')) {
          iconBytes += size;
        }
      }
      _log.fine('scan done icon=$iconBytes illustration=$illustrationBytes');
      return ItemImageCacheUsage(
        iconBytes: iconBytes,
        illustrationBytes: illustrationBytes,
      );
    });
