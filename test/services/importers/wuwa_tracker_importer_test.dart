import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/accounts_import.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/importers/wuwa_tracker_importer.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';

const _sample = '''
{
  "siteVersion": "v4.7.19",
  "version": "0.0.2",
  "date": "2026-06-07T10:12:24.472Z",
  "playerId": "701146588",
  "pulls": [
    {"cardPoolType": 1, "resourceId": 1211, "qualityLevel": 5, "name": "Denia", "time": "2026-05-21T02:39:03+00:00", "isSorted": true, "group": 1},
    {"cardPoolType": 1, "resourceId": 21020023, "qualityLevel": 3, "name": "Sword of Night", "time": "2026-05-21T03:03:18+00:00", "isSorted": true, "group": 2},
    {"cardPoolType": 2, "resourceId": 21010024, "qualityLevel": 4, "name": "Cosmic Ripples", "time": "2026-05-20T01:00:00+00:00", "isSorted": true, "group": 1},
    {"cardPoolType": 4, "resourceId": 21050043, "qualityLevel": 3, "name": "Rectifier", "time": "2026-05-19T05:00:00+00:00", "isSorted": true, "group": 1},
    {"cardPoolType": 7, "resourceId": 99999999, "qualityLevel": 3, "name": "Ghost Pool", "time": "2026-05-18T00:00:00+00:00", "isSorted": true, "group": 1}
  ]
}
''';

void main() {
  const importer = WuwaTrackerImporter();

  test('parses pulls into a single-account AccountsBundle', () {
    final bundle = importer.parse(_sample);
    expect(bundle.accounts, hasLength(1));
    expect(bundle.accounts.single.data.playerId, '701146588');
    expect(bundle.lastActiveUid, '701146588');
  });

  test('groups by cardPoolType and skips unknown pools', () {
    final banners = importer.parse(_sample).accounts.single.data.banners;
    expect(banners.keys.toSet(), {'1', '2', '4'});
    expect(banners.containsKey('7'), isFalse);
    expect(banners['1'], hasLength(2));
  });

  test('converts UTC time to CST (+8) wall-clock matching official capture', () {
    final banners = importer.parse(_sample).accounts.single.data.banners;
    // 由新到舊：Sword 11:03:18 在前，Denia 10:39:03 在後。
    final sword = banners['1']![0];
    final denia = banners['1']![1];
    expect(sword.name, 'Sword of Night');
    expect(sword.time, parseGachaTime('2026-05-21 11:03:18'));
    expect(denia.name, 'Denia');
    expect(denia.time, parseGachaTime('2026-05-21 10:39:03'));
    // 與官方擷取一致：local-kind DateTime（isUtc=false）。
    expect(sword.time.isUtc, isFalse);
  });

  test('fills count=1, languageCode=en, and canonical kind resourceType', () {
    final banners = importer.parse(_sample).accounts.single.data.banners;
    final denia = banners['1']![1];
    final sword = banners['1']![0];
    expect(denia.count, 1);
    expect(denia.languageCode, 'en');
    expect(denia.cardPoolType, '1');
    expect(denia.resourceType, kItemKindCharacter); // 4 碼
    expect(sword.resourceType, kItemKindWeapon); // 8 碼
  });

  test('non-JSON → FormatException', () {
    expect(() => importer.parse('not json'), throwsFormatException);
  });

  test('JSON array → ForeignBundleException', () {
    expect(() => importer.parse('[]'), throwsA(isA<ForeignBundleException>()));
  });

  test('object without pulls/playerId → ForeignBundleException', () {
    const native = '{"schema_version": 2, "accounts": []}';
    expect(
      () => importer.parse(native),
      throwsA(isA<ForeignBundleException>()),
    );
  });

  test('playerId present but pulls not a list → ForeignBundleException', () {
    const bad = '{"playerId": "701146588", "pulls": {}}';
    expect(() => importer.parse(bad), throwsA(isA<ForeignBundleException>()));
  });

  test('empty pulls → valid bundle with no banners', () {
    const empty = '{"playerId": "701146588", "pulls": []}';
    final bundle = importer.parse(empty);
    expect(bundle.accounts.single.data.playerId, '701146588');
    expect(bundle.accounts.single.data.banners, isEmpty);
  });

  test('same-timestamp records keep original array order (stable)', () {
    const sameTime = '''
{
  "playerId": "701146588",
  "pulls": [
    {"cardPoolType": 1, "resourceId": 1101, "qualityLevel": 4, "name": "First", "time": "2026-05-21T03:03:18+00:00"},
    {"cardPoolType": 1, "resourceId": 1102, "qualityLevel": 4, "name": "Second", "time": "2026-05-21T03:03:18+00:00"},
    {"cardPoolType": 1, "resourceId": 1103, "qualityLevel": 4, "name": "Third", "time": "2026-05-21T03:03:18+00:00"}
  ]
}
''';
    final pool = importer.parse(sameTime).accounts.single.data.banners['1']!;
    expect(pool.map((r) => r.name).toList(), ['First', 'Second', 'Third']);
  });
}
