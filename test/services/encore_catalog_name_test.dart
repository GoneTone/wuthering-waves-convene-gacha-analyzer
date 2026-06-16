import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

void main() {
  test('EncoreCatalog exposes nameByKindId', () {
    const cat = EncoreCatalog(
      iconByKindId: {
        kItemKindCharacter: {1304: 'http://x/icon.png'},
      },
      nameByKindId: {
        kItemKindCharacter: {1304: 'Jinhsi'},
      },
    );
    expect(cat.nameByKindId[kItemKindCharacter]![1304], 'Jinhsi');
  });
}
