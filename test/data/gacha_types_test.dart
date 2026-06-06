import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/data/gacha_types.dart';

void main() {
  group('gachaTypes registry', () {
    test('共 10 個 type，cardPoolType 為 [1,2,3,4,5,6,8,9,10,11]（無 7）', () {
      expect(gachaTypes.length, 10);
      expect(gachaTypes.map((t) => t.cardPoolType).toList(), [
        1,
        2,
        3,
        4,
        5,
        6,
        8,
        9,
        10,
        11,
      ]);
    });

    test('key getter = cardPoolType.toString()', () {
      for (final t in gachaTypes) {
        expect(t.key, t.cardPoolType.toString());
      }
      expect(gachaTypes.firstWhere((t) => t.cardPoolType == 8).key, '8');
    });

    test('每個 type 都有 5★ 與 4★ 兩條 pity', () {
      for (final t in gachaTypes) {
        expect(t.pities, hasLength(2), reason: t.key);
        expect(t.primaryPity.rank, 5);
        expect(t.secondaryPity!.rank, 4);
      }
    });

    test('primaryPity 是 pities[0]、secondaryPity 是 pities[1]', () {
      for (final t in gachaTypes) {
        expect(t.primaryPity, same(t.pities.first));
        expect(t.secondaryPity, same(t.pities[1]));
      }
    });

    test('type 1/2/3/4/6/8/9/10/11 → 5★80 / 4★10', () {
      for (final cpt in [1, 2, 3, 4, 6, 8, 9, 10, 11]) {
        final t = gachaTypes.firstWhere((g) => g.cardPoolType == cpt);
        expect(t.primaryPity.threshold, 80, reason: 'type $cpt 5star');
        expect(t.secondaryPity!.threshold, 10, reason: 'type $cpt 4star');
      }
    });

    test('type 5（新手喚取）→ 5★50 / 4★10', () {
      final t = gachaTypes.firstWhere((g) => g.cardPoolType == 5);
      expect(t.primaryPity.threshold, 50);
      expect(t.secondaryPity!.threshold, 10);
    });

    test('nameKey 對齊 10 個鳴潮卡池 key', () {
      expect(gachaTypes.map((t) => t.nameKey).toList(), [
        'gachaTypeCharacter',
        'gachaTypeWeapon',
        'gachaTypeStandardCharacter',
        'gachaTypeStandardWeapon',
        'gachaTypeBeginner',
        'gachaTypeBeginnerChoice',
        'gachaTypeNewVoyageCharacter',
        'gachaTypeNewVoyageWeapon',
        'gachaTypeCollabCharacter',
        'gachaTypeCollabWeapon',
      ]);
    });
  });
}
