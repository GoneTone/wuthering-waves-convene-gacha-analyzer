import 'package:flutter/material.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/data/gacha_types.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/five_star_collection.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_stats.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/overview_sections.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/timeline_entries.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/layout.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/utils/relative_time.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/utils/stat_format.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/banner_colors.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/banner_top_rarity_bars.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/chart_card.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/stat_card.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/five_star_overview.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/timeline_vertical.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/empty_state.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/last_updated_label.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/inline_section_title.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/item_type_pie.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/loading_state.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/page_header.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/rarity_pie.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/share/share_action_button.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/share/share_card.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/share/share_image_helper.dart';

/// 總覽頁，聚合所有 12 池的統計、圖表與 timeline。
class OverviewPage extends ConsumerWidget {
  /// 建立 [OverviewPage]。
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context)!;
    final tokens = Theme.of(context).gacha;
    final state = ref.watch(gachaRepositoryProvider);
    final activeData = state.activeData;
    if (state.isBootstrapping) {
      return const LoadingState();
    }
    if (activeData == null) {
      return noSyncPageBody(context);
    }

    final imageIndex = ref.watch(itemImageIndexProvider);
    final sec = buildOverviewSections(activeData.banners, imageIndex);
    final bannerColors = BannerColors.of(Theme.of(context).brightness);

    final statCards = <Widget>[
      StatCard(
        label: l.statsTotal,
        value: '${sec.stats.total}',
        accent: tokens.accentPrimary,
      ),
      StatCard(
        label: l.statsRankCount(l.rarityStar(5)),
        value: '${sec.stats.fiveStarCount}',
        accent: tokens.fiveStar,
        subtitle: formatRateWithAvg(l, sec.stats.fiveStarRate, sec.fiveStarAvg),
      ),
      StatCard(
        label: l.statsRankCount(l.rarityStar(4)),
        value: '${sec.stats.fourStarCount}',
        accent: tokens.fourStar,
        subtitle: formatRateWithAvg(l, sec.stats.fourStarRate, sec.fourStarAvg),
      ),
    ];

    // 按需建構：標題列與區塊內容都是清單裡的獨立項目，畫面外的五星一覽與時間軸不會被建構。
    return CustomScrollView(
      scrollCacheExtent: pageScrollCacheExtent(),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.all(
            isCompactLayout(context) ? AppSpacing.m : AppSpacing.l,
          ),
          sliver: SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(
                      child: PageHeader(
                        title: l.pageOverviewTitle,
                        icon: Icons.dashboard_outlined,
                        trailing: phoneLandscapeLastUpdated(context),
                      ),
                    ),
                    ShareActionButton(
                      enabled: activeData.banners.values.any(
                        (r) => r.isNotEmpty,
                      ),
                      onGenerate: () =>
                          _generateOverviewShare(context, ref, l, activeData),
                    ),
                  ],
                ),
              ),
              _OverviewSection(
                title: l.pageOverviewGachaSection,
                types: sec.types,
                banners: sec.banners,
                stats: sec.stats,
                bannerColors: bannerColors,
                statCards: statCards,
                emptyTitle: l.emptyNoGachaRecords,
                timeline: sec.timeline,
                timelineNowPulls: sec.timelineNowPulls,
                timelineRank: sec.timelineRank,
                fiveStarItems: buildFiveStarCollectionAcrossBanners(
                  sec.banners,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 產生並分享總覽統計截圖。
  Future<void> _generateOverviewShare(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l,
    BannerStorage activeData,
  ) async {
    final appVersion = ref.read(appVersionProvider);
    await generateAndShareImage(
      context: context,
      l: l,
      suggestedName: 'wuwa_convene_share_overview_${fileTimestamp()}.png',
      recordsForPreload: activeData.banners.values.expand((records) => records),
      buildCard: (icon, options) => ShareCard.overview(
        l: l,
        appVersion: appVersion,
        appIcon: icon,
        options: options,
        uid: activeData.playerId,
        updatedAt: activeData.lastUpdated.toLocal(),
        banners: activeData.banners,
        index: ref.read(itemImageIndexProvider),
      ),
    );
  }
}

/// 總覽頁的聚合段落，包含 stat 卡、圖表與 timeline；以 sliver 回傳，讓每個區塊按需建構。
class _OverviewSection extends StatelessWidget {
  const _OverviewSection({
    required this.title,
    required this.types,
    required this.banners,
    required this.stats,
    required this.bannerColors,
    required this.statCards,
    required this.emptyTitle,
    required this.timeline,
    required this.timelineNowPulls,
    required this.timelineRank,
    this.fiveStarItems = const [],
  });

  /// 段落標題文字。
  final String title;

  /// 此段落包含的 [GachaType] 清單。
  final List<GachaType> types;

  /// 各卡池的喚取記錄 map。
  final Map<String, List<GachaRecord>> banners;

  /// 此段落的聚合統計。
  final GachaStats stats;

  /// 各卡池顏色對照。
  final BannerColors bannerColors;

  /// 三張 stat 卡 widget（總抽、主稀有度、次稀有度）。
  final List<Widget> statCards;

  /// 無記錄時顯示的空狀態標題。
  final String emptyTitle;

  /// 跨卡池合併後的 timeline 條目。
  final List<TimelineEntry> timeline;

  /// 距離最後一次主稀有度的現有累積抽數。
  final int timelineNowPulls;

  /// timeline 目標稀有度。
  final int timelineRank;

  /// 此段的五星一覽清單；空清單時不顯示該區塊（12 池聚合段一律有五星一覽）。
  final List<FiveStarCollectionItem> fiveStarItems;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final hasData = banners.values.any((r) => r.isNotEmpty);

    if (!hasData) {
      return SliverList.list(
        children: [
          InlineSectionTitle(icon: Icons.summarize_outlined, title: title),
          const SizedBox(height: AppSpacing.m),
          EmptyState.noRecords(context, title: emptyTitle, compact: true),
        ],
      );
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverList.list(
          children: [
            InlineSectionTitle(icon: Icons.summarize_outlined, title: title),
            const SizedBox(height: AppSpacing.m),

            // Stat row: 三聯卡片（無保底）
            LayoutBuilder(
              builder: (context, c) {
                final wide = c.maxWidth >= 1024;
                final mid = c.maxWidth < 1024;

                if (wide) {
                  return IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 6, child: statCards[0]),
                        const SizedBox(width: AppSpacing.m),
                        Expanded(flex: 3, child: statCards[1]),
                        const SizedBox(width: AppSpacing.m),
                        Expanded(flex: 3, child: statCards[2]),
                      ],
                    ),
                  );
                }
                if (mid) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      statCards[0],
                      const SizedBox(height: AppSpacing.m),
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: statCards[1]),
                            const SizedBox(width: AppSpacing.m),
                            Expanded(child: statCards[2]),
                          ],
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < statCards.length; i++) ...[
                      if (i > 0) const SizedBox(height: AppSpacing.m),
                      statCards[i],
                    ],
                  ],
                );
              },
            ),

            const SizedBox(height: AppSpacing.l),

            // Pie row: 稀有度 + 物品類型
            LayoutBuilder(
              builder: (context, c) {
                final wide = c.maxWidth >= 1024;
                final mid = c.maxWidth >= 800 && c.maxWidth < 1024;

                final layout = ChartCardLayout.of(context, c.maxWidth);
                final rarityCard = RarityChartCard(
                  stats: stats,
                  layout: layout,
                );
                final itemTypeCard = ItemTypeChartCard(
                  stats: stats,
                  layout: layout,
                );

                if (wide) {
                  // 對齊 Stat row（flex 6/3/3 + 兩個 m gap）：
                  // 第 1 卡寬 = (maxWidth - 24) / 2 = Stat row「總抽數」寬度。
                  final card1Width = (c.maxWidth - AppSpacing.m * 2) / 2;
                  return IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: card1Width, child: rarityCard),
                        const SizedBox(width: AppSpacing.m),
                        Expanded(child: itemTypeCard),
                      ],
                    ),
                  );
                }
                if (mid || layout == ChartCardLayout.compactTitleBeside) {
                  return IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: rarityCard),
                        const SizedBox(width: AppSpacing.m),
                        Expanded(child: itemTypeCard),
                      ],
                    ),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    rarityCard,
                    const SizedBox(height: AppSpacing.m),
                    itemTypeCard,
                  ],
                );
              },
            ),

            const SizedBox(height: AppSpacing.m),

            // 各卡池主稀有度件數
            ChartCard(
              title: l.bannerTopRarityCountTitle,
              icon: Icons.bar_chart,
              height: null,
              chart: BannerTopRarityBars(
                types: types,
                banners: banners,
                colors: bannerColors,
              ),
            ),

            const SizedBox(height: AppSpacing.xl),
            if (fiveStarItems.isNotEmpty) ...[
              InlineSectionTitle(
                icon: Icons.star_outline,
                title: l.rarityOverviewTitle(l.rarityStar(5)),
              ),
              const SizedBox(height: AppSpacing.s),
            ],
          ],
        ),
        // 五星一覽獨立成按列建構的 sliver：數十個圖示一次建好會在捲入的那一幀卡頓。
        if (fiveStarItems.isNotEmpty) ...[
          SliverFiveStarOverview(items: fiveStarItems),
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
        ],
        SliverList.list(
          children: [
            InlineSectionTitle(
              icon: Icons.timeline,
              title: l.timelineTopRarityTitle(
                l.rarityStar(timelineRank),
                timeline.length,
              ),
            ),
            const SizedBox(height: AppSpacing.s),
            TimelineVertical(
              entries: timeline,
              colors: bannerColors,
              targetRank: timelineRank,
              nowPulls: timelineNowPulls,
              isAcrossBanners: true,
              showLuckLegend: true,
            ),
          ],
        ),
      ],
    );
  }
}
