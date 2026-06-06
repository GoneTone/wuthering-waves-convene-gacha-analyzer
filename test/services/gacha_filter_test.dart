import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_filter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_row.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

GachaRecord _r({
  required int rank,
  required String resourceType,
  required String name,
  required DateTime time,
}) => GachaRecord(
  resourceId: name.hashCode & 0xffff,
  qualityLevel: rank,
  resourceType: resourceType,
  cardPoolType: '1',
  name: name,
  count: 1,
  time: time,
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

/// 依 name.hashCode & 0xffff 為各測試 record 建立 index（角色→character，武器→weapon）。
ItemImageIndex _recordIdx(List<GachaRecord> records) => _idx({
  for (final r in records)
    r.resourceId: r.resourceType == '角色' || r.resourceType == 'Character'
        ? kItemKindCharacter
        : kItemKindWeapon,
});

void main() {
  late List<GachaRecord> records;
  setUp(() {
    // 以 time desc 排序（與 gacha_repository 一致）；name 作為行身分。
    records = [
      _r(rank: 5, resourceType: '角色', name: '夜蘭', time: DateTime(2025, 5, 1)),
      _r(rank: 4, resourceType: '武器', name: '匣裡龍吟', time: DateTime(2025, 4, 1)),
      _r(rank: 3, resourceType: '武器', name: '黑纓槍', time: DateTime(2025, 3, 1)),
      _r(rank: 4, resourceType: '角色', name: '煙緋', time: DateTime(2025, 2, 1)),
      _r(rank: 5, resourceType: '武器', name: '若水', time: DateTime(2025, 1, 1)),
    ];
  });

  group('RecordFilter', () {
    test('預設 itemType 為 null，hasAny=false', () {
      const f = RecordFilter();
      expect(f.itemType, isNull);
      expect(f.hasAny, isFalse);
    });

    test('itemType 非 null → hasAny=true', () {
      const f = RecordFilter(itemType: '角色');
      expect(f.hasAny, isTrue);
    });

    test('copyWith：itemType=null 真的把它清掉（用 sentinel 區分）', () {
      const original = RecordFilter(itemType: '武器');
      final cleared = original.copyWith(itemType: null);
      expect(cleared.itemType, isNull);
    });

    test('copyWith：未傳 itemType 時保留原值', () {
      const original = RecordFilter(itemType: '武器', query: 'x');
      final updated = original.copyWith(query: 'y');
      expect(updated.itemType, '武器');
      expect(updated.query, 'y');
    });
  });

  group('filterRecordRows', () {
    late List<RecordRow> rows;
    setUp(() {
      // itemTypeKeyOf 以 index 的 encore 歸屬 kind 映射（kind:character 等）；
      // 以下 filter 測試以 canonical 鍵比對。
      rows = buildRecordRows(records, _recordIdx(records));
    });

    test('5★ + 武器 → 只剩 1 row，且 totalIndex / pity 不變', () {
      final out = filterRecordRows(
        rows,
        const RecordFilter(
          rarity: RarityFilter.fiveStar,
          itemType: 'kind:weapon',
        ),
      );
      expect(out.length, 1);
      expect(out.first.record.name, '若水');
      // 若水是最舊一筆 → totalIndex = 1
      expect(out.first.totalIndex, 1);
    });

    test('itemType="kind:character" → 只剩 character 條目', () {
      final out = filterRecordRows(
        rows,
        const RecordFilter(itemType: 'kind:character'),
      );
      expect(out.map((r) => r.record.name).toSet(), {'夜蘭', '煙緋'});
    });

    test('itemType=null → 不過濾 itemType', () {
      final out = filterRecordRows(rows, const RecordFilter());
      expect(out.length, rows.length);
    });

    test('filterRecordRows 依 itemTypeKey 過濾', () {
      final out = filterRecordRows(
        rows,
        const RecordFilter(itemType: 'kind:character'),
      );
      expect(out.every((r) => r.itemTypeKey == 'kind:character'), isTrue);
    });

    test('搜尋 query 過濾 row 集', () {
      final out = filterRecordRows(rows, const RecordFilter(query: '夜'));
      expect(out.map((r) => r.record.name), ['夜蘭']);
    });
  });

  group('sortRecordRows', () {
    late List<RecordRow> rows;
    setUp(() {
      rows = buildRecordRows(records, _recordIdx(records));
    });

    test('null → 不排序，保持輸入順序', () {
      final out = sortRecordRows(rows, null);
      expect(out.map((r) => r.record.name), ['夜蘭', '匣裡龍吟', '黑纓槍', '煙緋', '若水']);
    });

    test('time desc / asc', () {
      final desc = sortRecordRows(
        rows,
        const TableSort(column: SortColumn.time, direction: SortDirection.desc),
      );
      expect(desc.map((r) => r.record.name), ['夜蘭', '匣裡龍吟', '黑纓槍', '煙緋', '若水']);

      final asc = sortRecordRows(
        rows,
        const TableSort(column: SortColumn.time, direction: SortDirection.asc),
      );
      expect(asc.map((r) => r.record.name), ['若水', '煙緋', '黑纓槍', '匣裡龍吟', '夜蘭']);
    });

    test('rarity desc：5★ 在前，二級鍵以 time desc', () {
      final out = sortRecordRows(
        rows,
        const TableSort(
          column: SortColumn.rarity,
          direction: SortDirection.desc,
        ),
      );
      expect(out.first.record.qualityLevel, 5);
      expect(out.last.record.qualityLevel, 3);
      // 兩個 5★（夜蘭 2025-05-01、若水 2025-01-01）→ 夜蘭在前
      final fives = out.where((r) => r.record.qualityLevel == 5).toList();
      expect(fives.map((r) => r.record.name), ['夜蘭', '若水']);
    });

    test('rarity asc', () {
      final out = sortRecordRows(
        rows,
        const TableSort(
          column: SortColumn.rarity,
          direction: SortDirection.asc,
        ),
      );
      expect(out.first.record.qualityLevel, 3);
      expect(out.last.record.qualityLevel, 5);
    });

    test('totalIndex asc / desc', () {
      final asc = sortRecordRows(
        rows,
        const TableSort(
          column: SortColumn.totalIndex,
          direction: SortDirection.asc,
        ),
      );
      expect(asc.map((r) => r.totalIndex), [1, 2, 3, 4, 5]);
      final desc = sortRecordRows(
        rows,
        const TableSort(
          column: SortColumn.totalIndex,
          direction: SortDirection.desc,
        ),
      );
      expect(desc.map((r) => r.totalIndex), [5, 4, 3, 2, 1]);
    });

    test('fiveStarPity asc', () {
      final out = sortRecordRows(
        rows,
        const TableSort(
          column: SortColumn.mainPity,
          direction: SortDirection.asc,
        ),
      );
      // buildRecordRows 由 asc 視角（若水→夜蘭）累計，ranks = 5,4,3,4,5：
      //   若水 pity=1（寫後重置 0）, 煙緋 pity=1, 黑纓槍 pity=2, 匣裡龍吟 pity=3,
      //   夜蘭 pity=4
      // asc by pity → [pity=1 兩個, 2, 3, 4]
      // 二級鍵 time desc → 兩個 pity=1 中煙緋（02-01）比若水（01-01）新
      // 最終：[煙緋, 若水, 黑纓槍, 匣裡龍吟, 夜蘭]
      expect(out.map((r) => r.record.name), ['煙緋', '若水', '黑纓槍', '匣裡龍吟', '夜蘭']);
    });

    test('name 排序', () {
      final out = sortRecordRows(
        rows,
        const TableSort(column: SortColumn.name, direction: SortDirection.asc),
      );
      expect(out.length, rows.length);
    });

    test('SortColumn.kind 依 itemTypeKey 排序', () {
      final kindRows = [
        RecordRow(
          record: _r(
            rank: 4,
            resourceType: '武器',
            name: '匣裡龍吟',
            time: DateTime(2025, 4, 1),
          ),
          totalIndex: 1,
          mainPityIndex: 1,
          itemTypeKey: 'kind:weapon',
        ),
        RecordRow(
          record: _r(
            rank: 5,
            resourceType: '角色',
            name: '夜蘭',
            time: DateTime(2025, 5, 1),
          ),
          totalIndex: 2,
          mainPityIndex: 2,
          itemTypeKey: 'kind:character',
        ),
      ];
      final sorted = sortRecordRows(
        kindRows,
        const TableSort(column: SortColumn.kind, direction: SortDirection.asc),
      );
      // 'kind:character' < 'kind:weapon' 字典序，asc 時 character 在前
      expect(sorted.first.itemTypeKey, 'kind:character');
      expect(sorted.last.itemTypeKey, 'kind:weapon');
    });
  });
}
