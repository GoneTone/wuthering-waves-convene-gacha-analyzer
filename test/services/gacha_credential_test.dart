import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';

void main() {
  const sampleBody = '''
{
  "playerId": "701000000",
  "cardPoolId": "2e2300000000000000000000002768",
  "cardPoolType": 1,
  "serverId": "86d500000000000000000000009650",
  "languageCode": "zh-Hant",
  "recordId": "0632000000000000000000008550"
}
''';

  group('GachaCredential.fromCapturedBody', () {
    test('解析典型 body 五欄位', () {
      final cred = GachaCredential.fromCapturedBody(sampleBody);
      expect(cred.playerId, '701000000');
      expect(cred.cardPoolId, '2e2300000000000000000000002768');
      expect(cred.serverId, '86d500000000000000000000009650');
      expect(cred.languageCode, 'zh-Hant');
      expect(cred.recordId, '0632000000000000000000008550');
    });

    test('cardPoolType 為數字時不影響五欄位解析（迭代時自行替換）', () {
      final cred = GachaCredential.fromCapturedBody(sampleBody);
      expect(cred.playerId, isNotEmpty);
    });

    test('缺必要欄位時丟 FormatException', () {
      const missing = '{"playerId":"701","cardPoolId":"x"}';
      expect(
        () => GachaCredential.fromCapturedBody(missing),
        throwsA(isA<FormatException>()),
      );
    });

    test('非 JSON 字串丟 FormatException', () {
      expect(
        () => GachaCredential.fromCapturedBody('not json at all'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('GachaCredential.toRequestBody', () {
    test('共用五欄位、只換 cardPoolType（int）', () {
      final cred = GachaCredential.fromCapturedBody(sampleBody);
      final body = cred.toRequestBody(8);
      expect(body['playerId'], '701000000');
      expect(body['cardPoolId'], '2e2300000000000000000000002768');
      expect(body['serverId'], '86d500000000000000000000009650');
      expect(body['languageCode'], 'zh-Hant');
      expect(body['recordId'], '0632000000000000000000008550');
      expect(body['cardPoolType'], 8);
      expect(body['cardPoolType'], isA<int>());
    });

    test('toRequestBody 可被 jsonEncode 序列化', () {
      final cred = GachaCredential.fromCapturedBody(sampleBody);
      final encoded = jsonEncode(cred.toRequestBody(2));
      expect(jsonDecode(encoded), isA<Map<String, dynamic>>());
    });
  });

  group('GachaCredential.toJsonString 往返', () {
    test('輸出五欄位 JSON，可被 fromCapturedBody 還原（roundtrip）', () {
      final cred = GachaCredential.fromCapturedBody(sampleBody);
      final restored = GachaCredential.fromCapturedBody(cred.toJsonString());
      expect(restored.playerId, cred.playerId);
      expect(restored.cardPoolId, cred.cardPoolId);
      expect(restored.serverId, cred.serverId);
      expect(restored.recordId, cred.recordId);
      expect(restored.languageCode, cred.languageCode);
    });

    test('toJsonString 含全部五欄位 key', () {
      final cred = GachaCredential.fromCapturedBody(sampleBody);
      final json = jsonDecode(cred.toJsonString()) as Map<String, dynamic>;
      expect(json.keys.toSet(), {
        'playerId',
        'cardPoolId',
        'serverId',
        'recordId',
        'languageCode',
      });
      expect(json['playerId'], '701000000');
      expect(json['languageCode'], 'zh-Hant');
    });
  });
}
