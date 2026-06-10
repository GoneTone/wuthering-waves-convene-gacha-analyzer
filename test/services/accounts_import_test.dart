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
}
