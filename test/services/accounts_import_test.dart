import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/accounts_import.dart';

void main() {
  test('parses a minimal valid bundle', () {
    const text = '''
{
  "schema_version": 2,
  "exported_at": "2026-05-12T08:30:00.000Z",
  "app_version": "1.0.0",
  "last_active_uid": null,
  "accounts": []
}
''';
    final bundle = importAccounts(text);
    expect(bundle.schemaVersion, 2);
    expect(bundle.accounts, isEmpty);
  });

  test('not JSON → FormatException("Invalid JSON")', () {
    expect(
      () => importAccounts('definitely not json'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Invalid JSON'),
        ),
      ),
    );
  });

  test('top-level array → FormatException', () {
    expect(
      () => importAccounts('[]'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('object'),
        ),
      ),
    );
  });

  test('schema_version older than current is accepted', () {
    const text = '{"schema_version": 1, "accounts": []}';
    final bundle = importAccounts(text);
    expect(bundle.accounts, isEmpty);
  });

  test(
    'schema_version newer than current → UnsupportedSchemaVersionException',
    () {
      const text = '{"schema_version": 3, "accounts": []}';
      expect(
        () => importAccounts(text),
        throwsA(isA<UnsupportedSchemaVersionException>()),
      );
    },
  );

  test('bundle with matching app identifier is imported', () {
    const text = '''
{
  "schema_version": 2,
  "app": "wuthering_waves_convene_gacha_analyzer",
  "exported_at": "2026-05-12T08:30:00.000Z",
  "app_version": "1.0.0",
  "last_active_uid": null,
  "accounts": [
    {
      "player_id": "100000001",
      "language_code": "zh-Hant",
      "last_updated": "2026-05-12T08:30:00.000Z",
      "banners": {"1": []}
    }
  ]
}
''';
    final bundle = importAccounts(text);
    expect(bundle.accounts.single.data.playerId, '100000001');
  });

  test('bundle with foreign app identifier → ForeignBundleException', () {
    const text = '''
{
  "schema_version": 2,
  "app": "genshin_impact_wish_gacha_analyzer",
  "accounts": []
}
''';
    expect(() => importAccounts(text), throwsA(isA<ForeignBundleException>()));
  });

  test('legacy bundle (no app) with WuWa pool codes is imported', () {
    const text = '''
{
  "schema_version": 2,
  "exported_at": "2026-05-12T08:30:00.000Z",
  "app_version": "1.0.0",
  "last_active_uid": null,
  "accounts": [
    {
      "player_id": "100000001",
      "language_code": "zh-Hant",
      "last_updated": "2026-05-12T08:30:00.000Z",
      "banners": {"1": [], "2": []}
    }
  ]
}
''';
    final bundle = importAccounts(text);
    expect(bundle.accounts.single.data.banners.keys, containsAll(['1', '2']));
  });

  test(
    'legacy bundle (no app) with only Genshin codes → ForeignBundleException',
    () {
      const text = '''
{
  "schema_version": 2,
  "accounts": [
    {
      "player_id": "800000001",
      "language_code": "zh-Hant",
      "last_updated": "2026-05-12T08:30:00.000Z",
      "banners": {"301": [], "302": []}
    }
  ]
}
''';
      expect(
        () => importAccounts(text),
        throwsA(isA<ForeignBundleException>()),
      );
    },
  );

  test('legacy bundle (no app) with mixed codes keeps only WuWa banners', () {
    const text = '''
{
  "schema_version": 2,
  "accounts": [
    {
      "player_id": "100000001",
      "language_code": "zh-Hant",
      "last_updated": "2026-05-12T08:30:00.000Z",
      "banners": {"1": [], "301": []}
    }
  ]
}
''';
    final bundle = importAccounts(text);
    final banners = bundle.accounts.single.data.banners;
    expect(banners.keys, ['1']);
    expect(banners.containsKey('301'), isFalse);
  });
}
