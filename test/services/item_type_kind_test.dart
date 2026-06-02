import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

/// 建立測試用 [GachaRecord]；只需指定 [resourceType]。
GachaRecord _r({required String resourceType}) => GachaRecord(
  resourceId: 1211,
  qualityLevel: 5,
  resourceType: resourceType,
  cardPoolType: '1',
  name: 'x',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, 3),
);

void main() {
  group('itemTypeKeyOf（依 resourceType 映射 canonical kind）', () {
    test('zh-Hant 角色 → kind:character', () {
      expect(itemTypeKeyOf(_r(resourceType: '角色')), kItemKindCharacter);
    });

    test('zh-Hant 武器 → kind:weapon', () {
      expect(itemTypeKeyOf(_r(resourceType: '武器')), kItemKindWeapon);
    });

    test('zh-Hant 道具 → kind:item', () {
      expect(itemTypeKeyOf(_r(resourceType: '道具')), kItemKindItem);
    });

    test('zh-Hans 角色／武器／道具 → 對應 canonical kind', () {
      expect(itemTypeKeyOf(_r(resourceType: '角色')), kItemKindCharacter);
      expect(itemTypeKeyOf(_r(resourceType: '武器')), kItemKindWeapon);
      expect(itemTypeKeyOf(_r(resourceType: '道具')), kItemKindItem);
    });

    test('en Character／Weapon → 對應 canonical kind（跨語系合併）', () {
      expect(itemTypeKeyOf(_r(resourceType: 'Character')), kItemKindCharacter);
      expect(itemTypeKeyOf(_r(resourceType: 'Weapon')), kItemKindWeapon);
    });

    test('ja キャラクター／武器 → 對應 canonical kind', () {
      expect(itemTypeKeyOf(_r(resourceType: 'キャラクター')), kItemKindCharacter);
      expect(itemTypeKeyOf(_r(resourceType: '武器')), kItemKindWeapon);
    });

    test('未知字串 → fallback 原字串', () {
      expect(itemTypeKeyOf(_r(resourceType: 'Mystery')), 'Mystery');
    });

    test('空字串 → 回空字串', () {
      expect(itemTypeKeyOf(_r(resourceType: '')), '');
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
