import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart'
    show AccessDeniedException;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_auth.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_remote.dart';

void main() {
  group('fetchDriveMedia', () {
    test('帶 token 下載指定檔並以 UTF-8 解碼', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response.bytes(utf8.encode('{"名稱":"值"}'), 200);
      });
      final result = await fetchDriveMedia(client, 'file-1', 'tok');
      expect(result.text, '{"名稱":"值"}');
      expect(result.bytes, utf8.encode('{"名稱":"值"}').length);
      expect(seen.url.path, '/drive/v3/files/file-1');
      expect(seen.url.queryParameters['alt'], 'media');
      expect(seen.headers['Authorization'], 'Bearer tok');
    });

    test('回應帶 www-authenticate → AccessDeniedException，既有判斷認得出來', () async {
      final client = MockClient(
        (_) async => http.Response(
          '',
          401,
          headers: {'www-authenticate': 'Bearer error="invalid_token"'},
        ),
      );
      final error = await fetchDriveMedia(
        client,
        'f',
        't',
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<AccessDeniedException>());
      expect(isInvalidToken(error!), isTrue);
    });

    test('權限不足（無 www-authenticate）→ DetailedApiRequestError，判斷得出缺權限', () async {
      final client = MockClient(
        (_) async => http.Response(
          '{"error":{"message":"Request had insufficient authentication scopes."}}',
          403,
        ),
      );
      final error = await fetchDriveMedia(
        client,
        'f',
        't',
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<drive.DetailedApiRequestError>());
      expect((error! as drive.DetailedApiRequestError).status, 403);
      expect(isInsufficientScope(error), isTrue);
    });
  });

  group('putDriveMedia', () {
    test('以 PATCH uploadType=media 送出原始 UTF-8 位元組（不做 Base64）', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response('{}', 200);
      });
      const content = '{"名稱":"值"}';
      final sent = await putDriveMedia(client, 'file-1', 'tok', content);
      expect(sent, utf8.encode(content).length);
      expect(seen.method, 'PATCH');
      expect(seen.url.path, '/upload/drive/v3/files/file-1');
      expect(seen.url.queryParameters['uploadType'], 'media');
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(seen.bodyBytes, utf8.encode(content));
    });

    test('權杖失效（www-authenticate）→ 與下載相同的例外，既有判斷認得出來', () async {
      final client = MockClient(
        (_) async => http.Response(
          '',
          401,
          headers: {'www-authenticate': 'Bearer error="invalid_token"'},
        ),
      );
      final error = await putDriveMedia(
        client,
        'f',
        't',
        '{}',
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<AccessDeniedException>());
      expect(isInvalidToken(error!), isTrue);
    });
  });
}
