import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/share/preloaded_item_images.dart';

/// 顯示一筆喚取物品的 icon；無圖（武器/道具/負取/未抓）一律 [_Placeholder]。
///
/// 「是否有圖」權威為圖片索引的實際抓取結果（D7）：index 無成功 icon 時
/// 一律走 placeholder（依稀有度上色），絕不回 [SizedBox.shrink]。
class GachaItemIcon extends ConsumerWidget {
  /// 建立 [GachaItemIcon]。
  const GachaItemIcon({
    super.key,
    required this.record,
    required this.size,
    this.circular = false,
  });

  /// 喚取記錄；用其 resourceId / name / qualityLevel。
  final GachaRecord record;

  /// icon 邊長（px，依使用情境調整：時間軸等為 32、五星一覽為 48）。
  final double size;

  /// true 時以圓形裁切／圓形 placeholder 呈現（五星一覽用）。
  final bool circular;

  /// 依 [circular] 將 icon 圖片裁成圓形或 4px 圓角方塊。
  Widget _clipIcon(Widget child) => circular
      ? ClipOval(child: child)
      : ClipRRect(borderRadius: BorderRadius.circular(4), child: child);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(itemImageIndexProvider);
    final cacheDir = ref.watch(itemImageCacheDirProvider);
    final tokens = Theme.of(context).gacha;

    final entry = index.lookupImage(record.resourceId);
    final iconUrl = entry?.iconUrl;

    if (entry != null && iconUrl != null && iconUrl.isNotEmpty) {
      final preloaded = PreloadedItemImages.maybeOf(context);
      final preloadedImage = preloaded?.images[record.resourceId];
      if (preloadedImage != null) {
        return SizedBox(
          width: size,
          height: size,
          child: _clipIcon(RawImage(image: preloadedImage, fit: BoxFit.cover)),
        );
      }

      final file = itemIconCacheFile(
        baseDir: cacheDir,
        resourceId: record.resourceId,
        url: iconUrl,
      );
      if (file.existsSync()) {
        return SizedBox(
          width: size,
          height: size,
          child: _clipIcon(Image.file(file, fit: BoxFit.cover)),
        );
      }
    }

    return _Placeholder(
      qualityLevel: record.qualityLevel,
      size: size,
      tokens: tokens,
      circular: circular,
    );
  }
}

/// 缺 icon 時的固定尺寸方塊；底色依稀有度上色，中央疊一個 `?` icon。
class _Placeholder extends StatelessWidget {
  /// 建立 [_Placeholder]。
  const _Placeholder({
    required this.qualityLevel,
    required this.size,
    required this.tokens,
    this.circular = false,
  });

  /// 星級（3 / 4 / 5）；決定強調色。
  final int qualityLevel;

  /// 方塊邊長（px）。
  final double size;

  /// 主題 token；提供稀有度顏色。
  final GachaTokens tokens;

  /// true 時以圓形呈現。
  final bool circular;

  @override
  Widget build(BuildContext context) {
    final accent = switch (qualityLevel) {
      5 => tokens.fiveStar,
      4 => tokens.fourStar,
      _ => tokens.textMuted,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.18),
        border: Border.all(color: accent.withValues(alpha: 0.40)),
        shape: circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circular ? null : BorderRadius.circular(4),
      ),
      child: Center(
        child: Icon(Icons.question_mark, size: size * 0.55, color: accent),
      ),
    );
  }
}
