import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_lookup.dart';

GachaRecord _rec(int resourceId) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: '1',
  name: 'X',
  count: 1,
  time: DateTime.utc(2026, 5, 21),
);

void main() {
  group('hasItemImage', () {
    test('索引有成功 icon → true', () {
      final index = ItemImageIndex(
        items: const {
          1211: ItemImageEntry(
            iconUrl: 'https://x/card.png',
            noImage: false,
            permanentNoImage: false,
          ),
        },
      );
      expect(hasItemImage(index, _rec(1211)), isTrue);
    });

    test('索引為負取 → false', () {
      const index = ItemImageIndex(
        items: {
          21010024: ItemImageEntry(
            iconUrl: null,
            noImage: true,
            permanentNoImage: false,
          ),
        },
      );
      expect(hasItemImage(index, _rec(21010024)), isFalse);
    });

    test('索引無此 resourceId（未抓）→ false', () {
      const index = ItemImageIndex.empty();
      expect(hasItemImage(index, _rec(1211)), isFalse);
    });
  });
}
