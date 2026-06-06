import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/data/gacha_types.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/banner_colors.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/banner_top_rarity_bars.dart';

GachaRecord _r({
  required String cardPoolType,
  required int rank,
  required DateTime time,
  int resourceId = 1001,
  String name = 'X',
  String resourceType = '角色',
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: rank,
  resourceType: resourceType,
  cardPoolType: cardPoolType,
  name: name,
  count: 1,
  time: time,
);

Widget _wrap(
  Widget Function(BuildContext ctx, BannerColors colors) build, {
  Locale? locale,
  double width = 800,
}) => MaterialApp(
  theme: buildDarkTheme(),
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    // 以 SingleChildScrollView 給 8 列 bars 不受限的垂直空間（測試視窗預設僅
    // 800×600，固定高 SizedBox 會被夾到 600 而誤觸 RenderFlex overflow）；
    // width 仍由 SizedBox 鎖死，用以逼出窄欄換行驗證。
    body: SingleChildScrollView(
      child: SizedBox(
        width: width,
        child: Builder(
          builder: (ctx) {
            final colors = BannerColors.of(Theme.of(ctx).brightness);
            return build(ctx, colors);
          },
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('empty banners → renders one row per gachaType', (tester) async {
    await tester.pumpWidget(
      _wrap(
        (ctx, colors) => BannerTopRarityBars(
          types: gachaTypes,
          banners: const {},
          colors: colors,
        ),
      ),
    );
    final l = AppLocalizations.of(
      tester.element(find.byType(BannerTopRarityBars)),
    )!;
    for (final t in gachaTypes) {
      expect(find.text(t.resolveName(l)), findsOneWidget);
    }
    // 鳴潮 8 池主稀有度皆 5★，空資料時每列顯示「暫無 5★」。
    expect(
      find.text(l.pityNoMainRarity(l.rarityStar(5))),
      findsNWidgets(gachaTypes.length),
    );
    // 件數全為 0；分隔點「·」出現 N 次
    expect(find.text('0'), findsNWidgets(gachaTypes.length));
    expect(find.text('·'), findsNWidgets(gachaTypes.length));
  });

  testWidgets('renders 5★ count and "距上次 5★" subtitle correctly', (
    tester,
  ) async {
    // 卡池 1 character: desc-by-time → [4★, 4★, 5★A] → 5★ count = 1, pulls since last 5★ = 2
    final t0 = DateTime(2025, 1, 1);
    final banners = <String, List<GachaRecord>>{
      '1': [
        _r(cardPoolType: '1', rank: 4, time: t0.add(const Duration(days: 3))),
        _r(cardPoolType: '1', rank: 4, time: t0.add(const Duration(days: 2))),
        _r(cardPoolType: '1', rank: 5, time: t0.add(const Duration(days: 1))),
      ],
    };
    await tester.pumpWidget(
      _wrap(
        (ctx, colors) => BannerTopRarityBars(
          types: gachaTypes,
          banners: banners,
          colors: colors,
        ),
      ),
    );
    final l = AppLocalizations.of(
      tester.element(find.byType(BannerTopRarityBars)),
    )!;
    // count = 1 appears once (others are 0)
    expect(find.text('1'), findsOneWidget);
    expect(
      find.text(l.bannerTopRarityPullsSinceLast(l.rarityStar(5), 2)),
      findsOneWidget,
    );
  });

  testWidgets('bar widthFactor = topCount / max(topCount across banners)', (
    tester,
  ) async {
    expect(
      gachaTypes.map((t) => t.key).toList(),
      const ['1', '2', '3', '4', '5', '6', '8', '9', '10', '11'],
      reason: 'test assumes gachaTypes order — update if order changes',
    );
    final t0 = DateTime(2025, 1, 1);
    // 卡池 1: 4×5★; 卡池 2: 1×5★; others: 0
    final banners = <String, List<GachaRecord>>{
      '1': [
        for (var i = 0; i < 4; i++)
          _r(
            cardPoolType: '1',
            rank: 5,
            time: t0.add(Duration(days: i)),
          ),
      ],
      '2': [_r(cardPoolType: '2', rank: 5, time: t0)],
    };
    await tester.pumpWidget(
      _wrap(
        (ctx, colors) => BannerTopRarityBars(
          types: gachaTypes,
          banners: banners,
          colors: colors,
        ),
      ),
    );
    final fractions = tester
        .widgetList<FractionallySizedBox>(
          find.descendant(
            of: find.byType(BannerTopRarityBars),
            matching: find.byType(FractionallySizedBox),
          ),
        )
        .toList();
    expect(fractions.length, gachaTypes.length);
    expect(fractions[0].widthFactor, 1.0);
    expect(fractions[1].widthFactor, closeTo(0.25, 1e-6));
    for (var i = 2; i < fractions.length; i++) {
      expect(fractions[i].widthFactor, 0.0);
    }
  });

  testWidgets('bar color matches BannerColors.colorFor(cardPoolType)', (
    tester,
  ) async {
    final t0 = DateTime(2025, 1, 1);
    final banners = <String, List<GachaRecord>>{
      for (final t in gachaTypes)
        t.key: [_r(cardPoolType: t.key, rank: t.primaryPity.rank, time: t0)],
    };
    await tester.pumpWidget(
      _wrap(
        (ctx, colors) => BannerTopRarityBars(
          types: gachaTypes,
          banners: banners,
          colors: colors,
        ),
      ),
    );
    final colors = BannerColors.of(
      Theme.of(tester.element(find.byType(BannerTopRarityBars))).brightness,
    );
    final containers = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(BannerTopRarityBars),
            matching: find.byType(Container),
          ),
        )
        .where(
          (c) => (c.decoration as BoxDecoration?)?.gradient is LinearGradient,
        )
        .toList();
    expect(containers.length, gachaTypes.length);
    for (var i = 0; i < gachaTypes.length; i++) {
      final gradient =
          (containers[i].decoration as BoxDecoration).gradient
              as LinearGradient;
      expect(gradient.colors.last, colors.colorFor(gachaTypes[i].key));
    }
  });

  testWidgets('依每個 type 自己的 primaryPity.rank 算件數（皆 5★）', (tester) async {
    final character = gachaTypes.firstWhere((t) => t.key == '1');
    final weapon = gachaTypes.firstWhere((t) => t.key == '2');
    final t0 = DateTime(2025, 1, 1);
    final banners = <String, List<GachaRecord>>{
      // 角色活動 primary = 5★：只有 1 件 5★ 算入（4★ 不算）
      '1': [
        _r(cardPoolType: '1', rank: 5, time: t0),
        _r(cardPoolType: '1', rank: 4, time: t0.add(const Duration(days: 1))),
      ],
      // 武器活動 primary = 5★：只有 1 件 5★ 算入（3★ 不算）
      '2': [
        _r(cardPoolType: '2', rank: 5, time: t0),
        _r(cardPoolType: '2', rank: 3, time: t0.add(const Duration(days: 1))),
      ],
    };
    await tester.pumpWidget(
      _wrap(
        (ctx, colors) => BannerTopRarityBars(
          types: [character, weapon],
          banners: banners,
          colors: colors,
        ),
      ),
    );
    // 兩條 bar 各 1 件
    expect(find.text('1'), findsNWidgets(2));
  });

  testWidgets('英文窄視窗：名稱/說明不截斷（無 ellipsis）、bar 仍渲染', (tester) async {
    await tester.pumpWidget(
      _wrap(
        (ctx, colors) => BannerTopRarityBars(
          types: gachaTypes,
          banners: const {},
          colors: colors,
        ),
        locale: const Locale('en'),
        width: 360, // 刻意窄，逼出換行（高度由 SingleChildScrollView 自適應）
      ),
    );
    // 等 locale 切換 / 版面 settle 完成
    await tester.pumpAndSettle();

    final l = AppLocalizations.of(
      tester.element(find.byType(BannerTopRarityBars)),
    )!;

    // 名稱 Text 不得有 ellipsis（完整換行顯示）
    // 取 gachaTypes.first（卡池 1 角色活動）的 en 名稱
    final firstName = gachaTypes.first.resolveName(l);
    final nameText = tester.widget<Text>(find.text(firstName));
    expect(nameText.overflow, isNot(TextOverflow.ellipsis));
    expect(nameText.maxLines, isNull);

    // 右側 subtitle Text 不得有 ellipsis（空 banners → "No 5★ yet"）
    // 對所有符合的 subtitle Text 逐一斷言
    final noMainRarityStr = l.pityNoMainRarity(l.rarityStar(5));
    for (final subtitleText in tester.widgetList<Text>(
      find.text(noMainRarityStr),
    )) {
      expect(subtitleText.overflow, isNot(TextOverflow.ellipsis));
      expect(subtitleText.maxLines, isNull);
    }

    // bar 仍每列渲染
    expect(
      find.descendant(
        of: find.byType(BannerTopRarityBars),
        matching: find.byType(FractionallySizedBox),
      ),
      findsNWidgets(gachaTypes.length),
    );

    // 版面未拋 overflow 例外
    expect(tester.takeException(), isNull);
  });
}
