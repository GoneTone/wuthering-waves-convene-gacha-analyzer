import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/data/related_projects.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/app_link.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/other_game_versions.dart';

/// 將 [OtherGameVersions] 包進英文語系的 [MaterialApp]，套用提供 `theme.gacha`
/// 的暗色主題。
Widget _wrap() => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  theme: buildDarkTheme(),
  home: const Scaffold(body: OtherGameVersions()),
);

void main() {
  testWidgets('renders title, Genshin link and future note', (tester) async {
    await tester.pumpWidget(_wrap());

    expect(find.text('Versions for Other Games'), findsOneWidget);
    expect(find.text('Genshin Impact'), findsOneWidget);
    expect(
      find.text('More games may be supported in the future...'),
      findsOneWidget,
    );
  });

  testWidgets('Genshin link points to the related project url', (tester) async {
    await tester.pumpWidget(_wrap());

    final link = tester.widget<AppLink>(
      find.ancestor(
        of: find.text('Genshin Impact'),
        matching: find.byType(AppLink),
      ),
    );
    expect(link.url, RelatedProjects.genshinImpactAnalyzer);
  });
}
