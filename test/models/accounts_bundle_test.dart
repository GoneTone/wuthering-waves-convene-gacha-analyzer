import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

GachaRecord _r(int id) => GachaRecord(
  resourceId: id,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: '1',
  name: '達妮婭',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, 3),
);

BannerStorage _bs(String playerId) => BannerStorage(
  playerId: playerId,
  languageCode: 'zh-Hant',
  lastUpdated: DateTime.utc(2026, 5, 21),
  banners: {
    '1': [_r(1211)],
  },
);

void main() {
  test('schemaVersion 為 2', () {
    expect(AccountsBundle.currentSchemaVersion, 2);
  });

  test('toJson / fromJson roundtrip 保留順序、alias、last_active_uid', () {
    final bundle = AccountsBundle(
      exportedAt: DateTime.utc(2026, 5, 21, 8, 30),
      appVersion: '2.0.0',
      lastActiveUid: 'A',
      accounts: [
        ExportedAccount(alias: '主號', data: _bs('A')),
        ExportedAccount(data: _bs('B')),
      ],
    );
    final back = AccountsBundle.fromJson(bundle.toJson());
    expect(back.schemaVersion, 2);
    expect(back.lastActiveUid, 'A');
    expect(back.accounts.map((a) => a.data.playerId).toList(), ['A', 'B']);
    expect(back.accounts[0].alias, '主號');
    expect(back.accounts[1].alias, isNull);
  });

  test('schema_version 較舊（version=1）→ 接受並還原', () {
    final json = {
      'schema_version': 1,
      'exported_at': '2026-05-21T00:00:00.000Z',
      'app_version': '1.0.0',
      'accounts': <Map<String, dynamic>>[],
    };
    final bundle = AccountsBundle.fromJson(json);
    expect(bundle.accounts, isEmpty);
  });

  test('schema_version 為較新版本（999）→ UnsupportedSchemaVersionException', () {
    final json = {
      'schema_version': 999,
      'exported_at': '2026-05-21T00:00:00.000Z',
      'accounts': <Map<String, dynamic>>[],
    };
    expect(
      () => AccountsBundle.fromJson(json),
      throwsA(isA<UnsupportedSchemaVersionException>()),
    );
  });

  test('缺 schema_version → 拋例外', () {
    expect(
      () => AccountsBundle.fromJson({'accounts': []}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('schema_version'),
        ),
      ),
    );
  });

  test('accounts 非陣列 → 拋例外', () {
    expect(
      () => AccountsBundle.fromJson({'schema_version': 2, 'accounts': 'nope'}),
      throwsA(isA<FormatException>()),
    );
  });

  test('重複 playerId → 拋例外', () {
    final accountJson = _bs('X').toJson();
    expect(
      () => AccountsBundle.fromJson({
        'schema_version': 2,
        'accounts': [accountJson, accountJson],
      }),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Duplicate'),
        ),
      ),
    );
  });

  test('alias 空白字串讀回為 null', () {
    final bundle = AccountsBundle.fromJson({
      'schema_version': 2,
      'accounts': [
        {..._bs('A').toJson(), 'alias': '   '},
      ],
    });
    expect(bundle.accounts.single.alias, isNull);
  });

  test('alias_updated_at 沒有別名時仍寫出，代表已清空；讀回時保留', () {
    final account = ExportedAccount(
      data: _bs('A'),
      aliasUpdatedAt: DateTime.utc(2026, 11, 24, 1),
    );
    final json = account.toJson();
    expect(json.containsKey('alias'), isFalse);
    expect(json['alias_updated_at'], '2026-11-24T01:00:00.000Z');

    final back = ExportedAccount.fromJson(json);
    expect(back.alias, isNull);
    expect(back.aliasUpdatedAt, DateTime.utc(2026, 11, 24, 1));
  });

  test('alias_updated_at 型別不對 → 視為沒有時間，帳號照常讀取', () {
    final back = ExportedAccount.fromJson({
      ..._bs('A').toJson(),
      'alias': '主號',
      'alias_updated_at': 42,
    });
    expect(back.data.playerId, 'A');
    expect(back.alias, '主號');
    expect(back.aliasUpdatedAt, isNull);
  });
}
