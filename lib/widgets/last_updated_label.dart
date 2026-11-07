import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/layout.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/empty_state.dart';
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

/// 手機橫向（沒有底部狀態列）時頁面自己顯示的弱色最後更新時間；其他情況回傳 null。
LastUpdatedLabel? _landscapeLabel(BuildContext context) {
  if (phoneOrientationOf(context) != PhoneOrientation.landscape) return null;
  return LastUpdatedLabel(
    style: Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: Theme.of(context).gacha.textMuted),
  );
}

/// 手機橫向時放在頁首標題列的最後更新時間（要放進 Row）；其他情況回傳 null。
Widget? phoneLandscapeLastUpdated(BuildContext context) {
  final label = _landscapeLabel(context);
  if (label == null) return null;
  return Flexible(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
      child: label,
    ),
  );
}

/// 尚未同步時的頁面內容；手機橫向在左上角多顯示「尚未同步」。
Widget noSyncPageBody(BuildContext context) {
  final label = _landscapeLabel(context);
  if (label == null) return EmptyState.noSync(context);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(padding: const EdgeInsets.all(AppSpacing.m), child: label),
      Expanded(child: EmptyState.noSync(context)),
    ],
  );
}
