import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

GachaRecord _r({
  int resourceId = 1211,
  String resourceType = '角色',
  String lang = 'zh-Hant',
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: 5,
  resourceType: resourceType,
  cardPoolType: '1',
  name: 'x',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, 3),
  languageCode: lang,
);

ItemImageIndex _indexWith(Map<int, String> kinds) => ItemImageIndex(
  items: {
    for (final e in kinds.entries)
      e.key: ItemImageEntry(
        iconUrl: 'u',
        noImage: false,
        permanentNoImage: false,
        kind: e.value,
      ),
  },
);

void main() {
  group('itemTypeKeyOf（依 index 的 encore 歸屬 kind）', () {
    test('index 命中 → 回 canonical kind', () {
      final index = _indexWith({1211: kItemKindCharacter});
      expect(itemTypeKeyOf(_r(resourceId: 1211), index), kItemKindCharacter);
    });

    test('同一 id 不同擷取語言 → 同一 canonical kind（跨語言合併）', () {
      final index = _indexWith({1211: kItemKindCharacter});
      expect(
        itemTypeKeyOf(_r(resourceId: 1211, lang: 'zh-Hant'), index),
        itemTypeKeyOf(_r(resourceId: 1211, lang: 'en'), index),
      );
    });

    test('index 無此 id → fallback 原始 resourceType 字串', () {
      const empty = ItemImageIndex.empty();
      expect(itemTypeKeyOf(_r(resourceType: '캐릭터'), empty), '캐릭터');
    });

    test('index entry 有但 kind==null → fallback 原始字串', () {
      final index = ItemImageIndex(
        items: {
          1211: const ItemImageEntry(
            iconUrl: null,
            noImage: true,
            permanentNoImage: false,
          ),
        },
      );
      expect(itemTypeKeyOf(_r(resourceType: 'Mystery'), index), 'Mystery');
    });
  });

  group('itemTypeKeyLabel', () {
    test('canonical key 轉在地化標籤；fallback 原樣（en）', () async {
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      expect(itemTypeKeyLabel(kItemKindCharacter, l), 'Character');
      expect(itemTypeKeyLabel(kItemKindWeapon, l), 'Weapon');
      expect(itemTypeKeyLabel(kItemKindItem, l), l.kindItem);
      expect(itemTypeKeyLabel('', l), l.kindUnknown);
      expect(itemTypeKeyLabel('Mystery', l), 'Mystery');
    });
  });
}
