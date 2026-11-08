import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/timeline_entries.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/banner_colors.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/stat_card.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/timeline_horizontal.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/timeline_node.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/timeline_vertical.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/data/pager.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/scroll/scroll_affordance.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/uid_indicator.dart';

// 阿拉伯文、希伯來文會讓整個畫面左右鏡像；寫死 left／right 的元件會跑錯邊。

TimelineEntry _e(String name, int pulls, DateTime time) => TimelineEntry(
  name: name,
  gachaType: '1',
  time: time,
  pullsSincePrev: pulls,
);

/// 以阿拉伯文（由右往左）建出 [build] 的內容，寬 [width]。
Widget _rtl(
  Widget Function(BuildContext ctx, BannerColors colors) build, {
  double width = 600,
}) => ProviderScope(
  child: MaterialApp(
    theme: buildDarkTheme(),
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SizedBox(
        width: width,
        child: Builder(
          builder: (ctx) =>
              build(ctx, BannerColors.of(Theme.of(ctx).brightness)),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('horizontal timeline: the arrow toward older entries is on '
      'the left', (tester) async {
    await tester.pumpWidget(
      _rtl(
        (ctx, colors) => SizedBox(
          height: 160,
          child: TimelineHorizontal(
            entries: [
              for (var i = 0; i < 20; i++)
                _e('角色$i', 50 + i, DateTime(2026, 1, 1 + i)),
            ],
            targetRank: 5,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final arrows = find.byType(ScrollArrowButton);
    expect(arrows, findsOneWidget);
    expect(tester.getCenter(arrows).dx, lessThan(300));
    final fade = tester.widget<ScrollEdgeFade>(find.byType(ScrollEdgeFade));
    expect(tester.getCenter(find.byWidget(fade)).dx, lessThan(300));
  });

  testWidgets('vertical timeline: the rail runs through the dots', (
    tester,
  ) async {
    await tester.pumpWidget(
      _rtl(
        (ctx, colors) => TimelineVertical(
          entries: [
            _e('甲', 60, DateTime(2026, 2, 1)),
            _e('乙', 70, DateTime(2026, 1, 1)),
          ],
          colors: colors,
          targetRank: 5,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rail = find.byWidgetPredicate((w) => w is Positioned && w.width == 2);
    expect(rail, findsOneWidget);
    final dot = find.byType(TimelineNode).first;
    expect(tester.getCenter(rail).dx, closeTo(tester.getCenter(dot).dx, 2));
  });

  testWidgets('pager keeps "1 / 81" in reading order', (tester) async {
    await tester.pumpWidget(
      _rtl((ctx, colors) => Pager(page: 0, totalPages: 81, onChanged: (_) {})),
    );
    final label = tester.widget<Text>(find.text('1 / 81'));
    expect(label.textDirection, TextDirection.ltr);
  });

  testWidgets('stat card accent bar sits on the start (right) side', (
    tester,
  ) async {
    await tester.pumpWidget(
      _rtl(
        (ctx, colors) =>
            const StatCard(label: 'L', value: '1', accent: Colors.red),
      ),
    );
    final box = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(StatCard),
            matching: find.byType(Container),
          )
          .first,
    );
    final border = (box.decoration! as BoxDecoration).border!;
    expect(border, isA<BorderDirectional>());
    expect((border as BorderDirectional).start.width, 3);
  });

  testWidgets('masked UID keeps its digits first', (tester) async {
    await tester.pumpWidget(
      _rtl(
        (ctx, colors) => const AccountTriggerLabel(
          activeUid: '701000000',
          alias: '我的帳號',
          maskUid: true,
        ),
      ),
    );
    final uid = tester.widget<Text>(find.text('(701••••••) '));
    expect(uid.textDirection, TextDirection.ltr);
  });
}
