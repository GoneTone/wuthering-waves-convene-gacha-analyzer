import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_stats.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

GachaRecord _r({
  int rank = 5,
  String resourceType = '角色',
  int resourceId = 1211,
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: rank,
  resourceType: resourceType,
  cardPoolType: '1',
  name: 'x',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, 3),
);

ItemImageIndex _idx(Map<int, String> kinds) => ItemImageIndex(
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

/// id 固定對應表：角色=1211，武器=21010024，道具=21040084。
const _charId = 1211;
const _weaponId = 21010024;
const _itemId = 21040084;

final _fullIdx = _idx({
  _charId: kItemKindCharacter,
  _weaponId: kItemKindWeapon,
  _itemId: kItemKindItem,
});

void main() {
  group('GachaStats', () {
    test('空 list 全 0', () {
      final s = computeGachaStats(const [], const ItemImageIndex.empty());
      expect(s.total, 0);
      expect(s.fiveStarCount, 0);
      expect(s.byItemType, isEmpty);
      expect(s.fiveStarRate, 0.0);
    });

    test('混合 list 計數正確（只有 5/4/3，無 2★）', () {
      final records = [
        _r(rank: 5, resourceType: '角色', resourceId: _charId),
        _r(rank: 4, resourceType: '武器', resourceId: _weaponId),
        _r(rank: 4, resourceType: '角色', resourceId: _charId),
        _r(rank: 3, resourceType: '武器', resourceId: _weaponId),
        _r(rank: 3, resourceType: '武器', resourceId: _weaponId),
      ];
      final s = computeGachaStats(records, _fullIdx);
      expect(s.total, 5);
      expect(s.fiveStarCount, 1);
      expect(s.fourStarCount, 2);
      expect(s.threeStarCount, 2);
      expect(s.fiveStarRate, closeTo(0.2, 1e-9));
    });

    test('byItemType 以 canonical kind 聚合（含道具）', () {
      final records = [
        _r(rank: 5, resourceType: '角色', resourceId: _charId),
        _r(rank: 4, resourceType: '角色', resourceId: _charId),
        _r(rank: 4, resourceType: '武器', resourceId: _weaponId),
        _r(rank: 4, resourceType: '道具', resourceId: _itemId),
      ];
      final stats = computeGachaStats(records, _fullIdx);
      expect(stats.byItemType, {
        'kind:character': 2,
        'kind:weapon': 1,
        'kind:item': 1,
      });
    });

    test('跨語系同類型以 canonical kind 合併，不分裂', () {
      // index 命中 → 同一 id 無論原始 resourceType 語系均映射同一 kind。
      final stats = computeGachaStats([
        _r(rank: 5, resourceType: '角色', resourceId: _charId),
        _r(rank: 5, resourceType: 'Character', resourceId: _charId),
        _r(rank: 5, resourceType: 'キャラクター', resourceId: _charId),
      ], _idx({_charId: kItemKindCharacter}));
      expect(stats.byItemType, {'kind:character': 3});
    });

    test('未知 resourceType fallback 原字串（index 無此 id）', () {
      final stats = computeGachaStats([
        _r(rank: 5, resourceType: 'Mystery', resourceId: 9999),
      ], const ItemImageIndex.empty());
      expect(stats.byItemType, {'Mystery': 1});
    });

    test('sortedItemTypes 依 count desc 排序', () {
      final records = <GachaRecord>[
        for (var i = 0; i < 5; i++)
          _r(resourceType: '武器', resourceId: _weaponId),
        for (var i = 0; i < 3; i++) _r(resourceType: '角色', resourceId: _charId),
        _r(resourceType: '道具', resourceId: _itemId),
      ];
      final stats = computeGachaStats(records, _fullIdx);
      expect(stats.sortedItemTypes().map((e) => e.key).toList(), [
        'kind:weapon',
        'kind:character',
        'kind:item',
      ]);
    });
  });
}
