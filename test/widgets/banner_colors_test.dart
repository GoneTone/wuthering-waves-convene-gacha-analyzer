import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/banner_colors.dart';

void main() {
  const keys = ['1', '2', '3', '4', '5', '6', '8', '9', '10', '11', '12', '13'];

  for (final b in [Brightness.dark, Brightness.light]) {
    test('colorFor 對 12 個 cardPoolType 皆有獨特色 ($b)', () {
      final c = BannerColors.of(b);
      final colors = keys.map(c.colorFor).toList();
      expect(colors.toSet(), hasLength(12), reason: '12 色不可重複');
      expect(c.colorFor('7'), c.fallback, reason: '無 7 池 → fallback');
      expect(c.colorFor('999'), c.fallback, reason: '未知 → fallback');
    });

    test('卡池色不得等於歐非三色（綠/琥珀/紅），避免視覺混淆 ($b)', () {
      final c = BannerColors.of(b);
      final t = b == Brightness.dark ? GachaTokens.dark : GachaTokens.light;
      final luck = {t.stateSuccess, t.stateWarning, t.stateDanger};
      for (final key in keys) {
        expect(
          luck.contains(c.colorFor(key)),
          isFalse,
          reason: '卡池 $key 與歐非色撞色',
        );
      }
    });
  }
}
