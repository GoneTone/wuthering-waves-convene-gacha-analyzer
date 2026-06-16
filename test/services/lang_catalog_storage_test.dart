import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('langcat'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('idByName excludes names that map to multiple ids', () {
    final c = LangCatalog(
      lang: 'en',
      fetchedAt: DateTime.utc(2026),
      byId: {
        1: (name: 'Solo', kind: kItemKindCharacter),
        2: (name: 'Dup', kind: kItemKindCharacter),
        3: (name: 'Dup', kind: kItemKindWeapon),
      },
    );
    expect(c.idByName['Solo'], 1);
    expect(c.idByName.containsKey('Dup'), isFalse);
  });

  test('fromEncore flattens nameByKindId', () {
    const enc = EncoreCatalog(
      iconByKindId: {},
      nameByKindId: {
        kItemKindCharacter: {1304: 'Jinhsi'},
        kItemKindWeapon: {21010011: 'Sword'},
      },
    );
    final c = LangCatalog.fromEncore(
      lang: 'en',
      fetchedAt: DateTime.utc(2026),
      catalog: enc,
    );
    expect(c.byId[1304]!.name, 'Jinhsi');
    expect(c.byId[1304]!.kind, kItemKindCharacter);
    expect(c.byId[21010011]!.kind, kItemKindWeapon);
  });

  test('save/load round-trip', () async {
    final storage = LangCatalogStorage(dir);
    final c = LangCatalog(
      lang: 'ja',
      fetchedAt: DateTime.utc(2026, 6, 16),
      byId: {1304: (name: '今汐', kind: kItemKindCharacter)},
    );
    await storage.save(c);
    final loaded = await storage.load('ja');
    expect(loaded, isNotNull);
    expect(loaded!.byId[1304]!.name, '今汐');
    expect(loaded.byId[1304]!.kind, kItemKindCharacter);
    expect(loaded.idByName['今汐'], 1304);
  });

  test('load missing returns null', () async {
    expect(await LangCatalogStorage(dir).load('ko'), isNull);
  });

  test('load corrupt returns null', () async {
    File('${dir.path}/lang_catalog/fr.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{ not json');
    expect(await LangCatalogStorage(dir).load('fr'), isNull);
  });
}
