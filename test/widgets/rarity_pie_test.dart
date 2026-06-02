import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_stats.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/rarity_pie.dart';

void main() {
  group('rarityDistributionEntries', () {
    late AppLocalizations zh;
    late AppLocalizations ja;

    setUpAll(() async {
      zh = await AppLocalizations.delegate.load(const Locale('zh'));
      ja = await AppLocalizations.delegate.load(const Locale('ja'));
    });

    test('returns 5★/4★/3★ entries with correct counts and rates (zh)', () {
      const stats = GachaStats(
        total: 100,
        fiveStarCount: 1,
        fourStarCount: 9,
        threeStarCount: 90,
        byItemType: {},
      );
      final entries = rarityDistributionEntries(stats, GachaTokens.dark, zh);
      expect(entries, hasLength(3));
      expect(entries[0].name, '5★');
      expect(entries[0].count, 1);
      expect(entries[0].rate, closeTo(0.01, 1e-9));
      expect(entries[0].color, GachaTokens.dark.fiveStar);
      expect(entries[1].name, '4★');
      expect(entries[1].count, 9);
      expect(entries[2].name, '3★');
      expect(entries[2].count, 90);
    });

    test('keeps zero-count entries (zh)', () {
      const stats = GachaStats(
        total: 0,
        fiveStarCount: 0,
        fourStarCount: 0,
        threeStarCount: 0,
        byItemType: {},
      );
      final entries = rarityDistributionEntries(stats, GachaTokens.dark, zh);
      expect(entries, hasLength(3));
      expect(entries.every((e) => e.count == 0), isTrue);
    });

    test('ja 用 ★N 順序', () {
      const stats = GachaStats(
        total: 10,
        fiveStarCount: 1,
        fourStarCount: 2,
        threeStarCount: 7,
        byItemType: {},
      );
      final entries = rarityDistributionEntries(stats, GachaTokens.dark, ja);
      expect(entries.map((e) => e.name).toList(), ['★5', '★4', '★3']);
    });
  });
}
