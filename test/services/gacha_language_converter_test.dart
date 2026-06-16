import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_language_converter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';

GachaRecord rec({
  required int id,
  required String name,
  required String lang,
  String type = '角色',
}) => GachaRecord(
  resourceId: id,
  qualityLevel: 5,
  resourceType: type,
  cardPoolType: '1',
  name: name,
  count: 1,
  time: DateTime.utc(2026, 1, 1),
  languageCode: lang,
);

BannerStorage store(List<GachaRecord> records) => BannerStorage(
  playerId: 'p1',
  languageCode: 'zh-Hant',
  lastUpdated: DateTime.utc(2026, 1, 1),
  banners: {'1': records},
);

LangCatalog cat(String lang, Map<int, ({String name, String kind})> byId) =>
    LangCatalog(lang: lang, fetchedAt: DateTime.utc(2026), byId: byId);

void main() {
  test(
    'direct id mapping converts name + languageCode, keeps resourceType',
    () async {
      final catalogs = {
        'ja': cat('ja', {1304: (name: '今汐', kind: kItemKindCharacter)}),
      };
      final conv = GachaLanguageConverter(
        ensureCatalog: (l) async => catalogs[l]!,
      );
      final out = await conv.convert(
        store([rec(id: 1304, name: 'Jinhsi', lang: 'en')]),
        'ja',
      );
      final r = out.data.banners['1']!.single;
      expect(r.name, '今汐');
      expect(r.languageCode, 'ja');
      expect(r.resourceType, '角色'); // untouched
      expect(out.result.converted, 1);
      expect(out.result.unresolved, 0);
    },
  );

  test('synthetic id backfilled via source-name lookup', () async {
    final catalogs = {
      'ja': cat('ja', {1304: (name: '今汐', kind: kItemKindCharacter)}),
      'en': cat('en', {1304: (name: 'Jinhsi', kind: kItemKindCharacter)}),
    };
    final conv = GachaLanguageConverter(
      ensureCatalog: (l) async => catalogs[l]!,
    );
    final out = await conv.convert(
      store([rec(id: -42, name: 'Jinhsi', lang: 'en')]),
      'ja',
    );
    final r = out.data.banners['1']!.single;
    expect(r.resourceId, 1304); // adopted real id
    expect(r.name, '今汐');
    expect(r.languageCode, 'ja');
    expect(out.result.backfilledId, 1);
    expect(out.result.converted, 1);
  });

  test('unresolved record left fully untouched', () async {
    final catalogs = {'ja': cat('ja', const {}), 'en': cat('en', const {})};
    final conv = GachaLanguageConverter(
      ensureCatalog: (l) async => catalogs[l]!,
    );
    final original = rec(id: -7, name: 'Mystery', lang: 'en');
    final out = await conv.convert(store([original]), 'ja');
    final r = out.data.banners['1']!.single;
    expect(r.resourceId, -7);
    expect(r.name, 'Mystery');
    expect(r.languageCode, 'en');
    expect(out.result.unresolved, 1);
    expect(out.result.converted, 0);
  });

  test('records already in target language are not counted', () async {
    final catalogs = {
      'ja': cat('ja', {1304: (name: '今汐', kind: kItemKindCharacter)}),
      'en': cat('en', {1304: (name: 'Jinhsi', kind: kItemKindCharacter)}),
    };
    final conv = GachaLanguageConverter(
      ensureCatalog: (l) async => catalogs[l]!,
    );
    final out = await conv.convert(
      store([
        rec(id: 1304, name: '今汐', lang: 'ja'), // 已是目標語言 → 不計、不動
        rec(id: 1304, name: 'Jinhsi', lang: 'en'), // 需轉換 → 計 1
      ]),
      'ja',
    );
    expect(out.result.converted, 1); // 只算真正換語言的那筆
    expect(out.result.unresolved, 0);
    final records = out.data.banners['1']!;
    expect(records[0].name, '今汐'); // 同語言原樣保留
    expect(records[0].languageCode, 'ja');
    expect(records[1].name, '今汐'); // en → ja 已轉換
    expect(records[1].languageCode, 'ja');
  });

  test('LangConvertResult sums', () {
    const a = LangConvertResult(total: 1, converted: 1);
    const b = LangConvertResult(total: 1, unresolved: 1);
    final c = a + b;
    expect(c.total, 2);
    expect(c.converted, 1);
    expect(c.unresolved, 1);
  });
}
