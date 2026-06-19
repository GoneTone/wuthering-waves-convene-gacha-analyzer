import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/luck_palette.dart';

void main() {
  group('luckTierFor — 80 池', () {
    test('40 抽（ratio 0.5）= 歐', () {
      expect(luckTierFor(40, 80), LuckTier.lucky);
    });
    test('41 抽 = 普通', () {
      expect(luckTierFor(41, 80), LuckTier.average);
    });
    test('64 抽（ratio 0.8）= 普通', () {
      expect(luckTierFor(64, 80), LuckTier.average);
    });
    test('65 抽 = 非', () {
      expect(luckTierFor(65, 80), LuckTier.unlucky);
    });
    test('80 抽 = 非', () {
      expect(luckTierFor(80, 80), LuckTier.unlucky);
    });
    test('81 抽（ratio > 1）= 非', () {
      expect(luckTierFor(81, 80), LuckTier.unlucky);
    });
  });

  group('luckTierFor — 50 池', () {
    test('25 抽 = 歐', () => expect(luckTierFor(25, 50), LuckTier.lucky));
    test('26 抽 = 普通', () => expect(luckTierFor(26, 50), LuckTier.average));
    test('40 抽 = 普通', () => expect(luckTierFor(40, 50), LuckTier.average));
    test('41 抽 = 非', () => expect(luckTierFor(41, 50), LuckTier.unlucky));
  });

  group('luckTierFor — 10 池', () {
    test('5 抽 = 歐', () => expect(luckTierFor(5, 10), LuckTier.lucky));
    test('6 抽 = 普通', () => expect(luckTierFor(6, 10), LuckTier.average));
    test('8 抽 = 普通', () => expect(luckTierFor(8, 10), LuckTier.average));
    test('9 抽 = 非', () => expect(luckTierFor(9, 10), LuckTier.unlucky));
  });

  test('pityThreshold <= 0 防呆 = 非', () {
    expect(luckTierFor(1, 0), LuckTier.unlucky);
  });

  group('luckColorFor 對應既有語意色', () {
    const t = GachaTokens.dark;
    test('歐 → stateSuccess', () {
      expect(luckColorFor(LuckTier.lucky, t), t.stateSuccess);
    });
    test('普通 → stateWarning', () {
      expect(luckColorFor(LuckTier.average, t), t.stateWarning);
    });
    test('非 → stateDanger', () {
      expect(luckColorFor(LuckTier.unlucky, t), t.stateDanger);
    });
  });
}
