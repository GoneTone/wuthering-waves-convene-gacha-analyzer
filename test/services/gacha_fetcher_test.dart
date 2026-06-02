import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_fetcher.dart';

GachaCredential _cred() => GachaCredential(
  playerId: '701000000',
  cardPoolId: '2e23deadbeef2768',
  serverId: '86d5deadbeef9650',
  recordId: '0632deadbeef8550',
  languageCode: 'zh-Hant',
);

Uri get _endpoint =>
    Uri.parse('https://gmserver-api.aki-game2.net/gacha/record/query');

http.Response _ok(List<Map<String, dynamic>> data) => http.Response(
  jsonEncode({'code': 0, 'message': 'success', 'data': data}),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _fail(int code, String message) => http.Response(
  jsonEncode({'code': code, 'message': message, 'data': <dynamic>[]}),
  200,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _row({
  required int resourceId,
  required int quality,
  required String type,
  required String name,
  required String time,
}) => {
  'cardPoolType': '1',
  'resourceId': resourceId,
  'qualityLevel': quality,
  'resourceType': type,
  'name': name,
  'count': 1,
  'time': time,
};

void main() {
  group('GachaFetcher.fetchPool', () {
    test('POSTs JSON body and parses code==0 data list', () async {
      String? capturedBody;
      String? capturedContentType;
      final mock = MockClient((req) async {
        capturedBody = req.body;
        capturedContentType = req.headers['content-type'];
        expect(req.method, 'POST');
        expect(req.url, _endpoint);
        return _ok([
          _row(
            resourceId: 1211,
            quality: 5,
            type: '角色',
            name: '達妮婭',
            time: '2026-05-21 10:39:03',
          ),
        ]);
      });
      final fetcher = GachaFetcher(rateLimit: Duration.zero);
      final result = await fetcher.fetchPool(
        endpoint: _endpoint,
        cred: _cred(),
        cardPoolType: 1,
        client: mock,
      );
      expect(result.records, hasLength(1));
      expect(result.records.first.resourceId, 1211);
      expect(result.records.first.cardPoolType, '1');
      // request body carries the credential + cardPoolType (int)
      final sent = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(sent['playerId'], '701000000');
      expect(sent['cardPoolType'], 1);
      expect(capturedContentType, contains('application/json'));
    });

    test(
      'empty data on code==0 is a successful empty pool (not an error)',
      () async {
        final mock = MockClient((req) async => _ok(const []));
        final fetcher = GachaFetcher(rateLimit: Duration.zero);
        final result = await fetcher.fetchPool(
          endpoint: _endpoint,
          cred: _cred(),
          cardPoolType: 9,
          client: mock,
        );
        expect(result.records, isEmpty);
      },
    );

    test('code!=0 throws GachaApiException with code+message', () async {
      final mock = MockClient((req) async => _fail(-1, '请求游戏获取日志异常!'));
      final fetcher = GachaFetcher(rateLimit: Duration.zero);
      await expectLater(
        () => fetcher.fetchPool(
          endpoint: _endpoint,
          cred: _cred(),
          cardPoolType: 1,
          client: mock,
        ),
        throwsA(
          isA<GachaApiException>()
              .having((e) => e.code, 'code', -1)
              .having((e) => e.message, 'message', '请求游戏获取日志异常!'),
        ),
      );
    });
  });

  group('logging instrumentation', () {
    setUp(() => Logger.root.level = Level.ALL);
    tearDown(() => Logger.root.clearListeners());

    test('emits SEVERE when code!=0', () async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      final mock = MockClient((req) async => _fail(-1, 'boom'));
      final fetcher = GachaFetcher(rateLimit: Duration.zero);
      await expectLater(
        () => fetcher.fetchPool(
          endpoint: _endpoint,
          cred: _cred(),
          cardPoolType: 1,
          client: mock,
        ),
        throwsA(isA<GachaApiException>()),
      );
      final severe = records.firstWhere(
        (r) => r.level == Level.SEVERE && r.loggerName == 'gacha.fetcher',
        orElse: () => throw StateError('no SEVERE from gacha.fetcher'),
      );
      expect(severe.message, contains('code=-1'));
    });
  });
}
