import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/banner_colors.dart';

void main() {
  const keys = ['1', '2', '3', '4', '5', '6', '8', '9', '10', '11'];

  for (final b in [Brightness.dark, Brightness.light]) {
    test('colorFor 對 10 個 cardPoolType 皆有獨特色 ($b)', () {
      final c = BannerColors.of(b);
      final colors = keys.map(c.colorFor).toList();
      expect(colors.toSet(), hasLength(10), reason: '10 色不可重複');
      expect(c.colorFor('7'), c.fallback, reason: '無 7 池 → fallback');
      expect(c.colorFor('999'), c.fallback, reason: '未知 → fallback');
    });
  }
}
