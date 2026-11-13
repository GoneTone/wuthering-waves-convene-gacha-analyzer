import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/data/app_repo.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/data/team_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/app_link.dart';

/// AppShell 底部 footer 右側的團隊資訊列：
/// 3 個社群 icon（Facebook / Discord / GitHub）+ 分隔線 + 團隊名稱連結。
class TeamLinksBar extends StatelessWidget {
  /// 建立 [TeamLinksBar]；[compact] 為手機排版。
  const TeamLinksBar({super.key, this.compact = false});

  /// 手機排版：只留三個圖示，觸控區放大到 48dp。
  final bool compact;

  /// 圖示大小。
  static const double _iconSize = 16;

  /// 非 compact 時圖示按鈕的最小寬度。
  static const double _iconButtonMinWidth = 40;

  /// 非 compact 時，圖示按鈕在圖示兩側自帶的空白。整列要置中時在文字那一端補同寬，
  /// 看得到的內容才會左右對稱。
  static const double iconInset = (_iconButtonMinWidth - _iconSize) / 2;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).gacha;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconLink(
          icon: FontAwesomeIcons.facebookF,
          tooltip: 'Facebook',
          url: TeamInfo.facebookUrl,
          compact: compact,
        ),
        _IconLink(
          icon: FontAwesomeIcons.discord,
          tooltip: 'Discord',
          url: TeamInfo.discordUrl,
          compact: compact,
        ),
        _IconLink(
          icon: FontAwesomeIcons.github,
          tooltip: 'GitHub',
          url: AppRepo.githubUrl,
          compact: compact,
        ),
        if (!compact) ...[
          const SizedBox(width: AppSpacing.xs),
          Container(width: 1, height: 16, color: tokens.textMuted),
          const SizedBox(width: AppSpacing.s),
          AppLink(
            url: TeamInfo.websiteUrl,
            child: Text(
              TeamInfo.name,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ],
    );
  }
}

/// 單一社群平台的圖示連結按鈕。
class _IconLink extends StatelessWidget {
  /// 建立 [_IconLink]。
  const _IconLink({
    required this.icon,
    required this.tooltip,
    required this.url,
    required this.compact,
  });

  /// FontAwesome 圖示。
  final FaIconData icon;

  /// Tooltip 文字。
  final String tooltip;

  /// 點擊後開啟的目標 URL。
  final String url;

  /// 手機排版：觸控區 48dp。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).gacha;
    return IconButton(
      tooltip: tooltip,
      iconSize: TeamLinksBar._iconSize,
      // compact 密度會把 48dp 觸控區縮成 40，手機排版改回標準密度。
      visualDensity: compact ? VisualDensity.standard : VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
      constraints: compact
          ? const BoxConstraints(minWidth: 48, minHeight: 48)
          : const BoxConstraints(
              minWidth: TeamLinksBar._iconButtonMinWidth,
              minHeight: 32,
            ),
      mouseCursor: SystemMouseCursors.click,
      icon: FaIcon(icon, color: tokens.textSecondary),
      onPressed: () => openExternalUrlString(url, context: 'TeamLinksBar'),
    );
  }
}
