import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/relative_time_text.dart';

/// 目前帳號的「最後更新」文字；尚未同步時顯示「尚未同步」。外殼底部列與手機橫向頁首共用。
class LastUpdatedLabel extends ConsumerWidget {
  /// 建立 [LastUpdatedLabel]；[style] 為 null 時用 `bodySmall`。
  const LastUpdatedLabel({super.key, this.style});

  /// 文字樣式。
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context)!;
    final activeData = ref.watch(
      gachaRepositoryProvider.select((s) => s.activeData),
    );
    final textStyle = style ?? Theme.of(context).textTheme.bodySmall;
    return activeData == null
        ? Text(
            l.footerNotSynced,
            style: textStyle,
            overflow: TextOverflow.ellipsis,
          )
        : RelativeTimeText(
            time: activeData.lastUpdated,
            templateBuilder: l.footerLastUpdated,
            style: textStyle,
            overflow: TextOverflow.ellipsis,
          );
  }
}
