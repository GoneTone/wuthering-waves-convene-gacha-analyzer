import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/oauth2/v2.dart' show DetailedApiRequestError;
import 'package:googleapis_auth/googleapis_auth.dart'
    show AccessDeniedException;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_auth_service.dart';

import '../../helpers/cloud_sync_fakes.dart';

void main() {
  test(
    'signOut deletes the stored token without any network request',
    () async {
      var requests = 0;
      final store = InMemoryTokenStore()..token = 'refresh-1';
      final svc = GoogleAuthService(
        tokenStore: store,
        baseClientFactory: () => MockClient((_) async {
          requests++;
          return http.Response('', 200);
        }),
      );
      await svc.unlink();
      expect(store.token, isNull);
      expect(requests, 0);
    },
  );

  group('isInvalidGrant', () {
    test('訊息含 invalid_grant → true', () {
      expect(
        isInvalidGrant(Exception('Refresh failed: invalid_grant')),
        isTrue,
      );
    });

    test('一般網路錯誤 → false', () {
      expect(isInvalidGrant(Exception('Connection refused')), isFalse);
    });
  });

  group('buildResumeCredentials', () {
    test('產出已過期的 UTC Bearer 種子憑證並保留 refresh token', () {
      final c = buildResumeCredentials('refresh-abc');
      expect(c.refreshToken, 'refresh-abc');
      expect(c.accessToken.type, 'Bearer');
      expect(c.accessToken.expiry.isUtc, isTrue);
      expect(c.accessToken.expiry.isBefore(DateTime.now().toUtc()), isTrue);
      expect(c.scopes, cloudSyncScopes);
    });
  });

  group('hasRequiredCloudScopes', () {
    test('含 drive.appdata（不論 email 以何種形式回傳）→ true', () {
      expect(
        hasRequiredCloudScopes(const [
          'https://www.googleapis.com/auth/drive.appdata',
          'https://www.googleapis.com/auth/userinfo.email',
          'openid',
        ]),
        isTrue,
      );
    });

    test('只授予 email／openid（漏勾雲端硬碟）→ false', () {
      expect(
        hasRequiredCloudScopes(const [
          'https://www.googleapis.com/auth/userinfo.email',
          'openid',
        ]),
        isFalse,
      );
    });

    test('空清單 → false', () {
      expect(hasRequiredCloudScopes(const []), isFalse);
    });
  });

  group('isInsufficientScope', () {
    test(
      'Drive 403 insufficient_scope 訊息（www-authenticate header 路徑）→ true',
      () {
        expect(
          isInsufficientScope(
            Exception(
              'Access was denied (www-authenticate header was: '
              'Bearer realm="https://accounts.google.com/", '
              'error="insufficient_scope", scope="...").',
            ),
          ),
          isTrue,
        );
      },
    );

    test('DetailedApiRequestError 的 JSON message 路徑 → true', () {
      expect(
        isInsufficientScope(
          Exception(
            'DetailedApiRequestError(status: 403, message: '
            'Request had insufficient authentication scopes.)',
          ),
        ),
        isTrue,
      );
    });

    test('結構化 reason ACCESS_TOKEN_SCOPE_INSUFFICIENT → true', () {
      expect(
        isInsufficientScope(
          Exception('reason: ACCESS_TOKEN_SCOPE_INSUFFICIENT'),
        ),
        isTrue,
      );
    });

    test('一般網路錯誤 → false', () {
      expect(isInsufficientScope(Exception('Connection refused')), isFalse);
    });
  });

  group('isInvalidToken', () {
    test('DetailedApiRequestError 401 → true', () {
      expect(isInvalidToken(DetailedApiRequestError(401, 'x')), isTrue);
    });

    test('AccessDeniedException 帶 invalid_token → true', () {
      expect(
        isInvalidToken(
          AccessDeniedException(
            'Access was denied (www-authenticate header was: '
            'Bearer realm="https://accounts.google.com/", '
            'error="invalid_token").',
          ),
        ),
        isTrue,
      );
    });

    test('insufficient_scope 的 AccessDeniedException → false', () {
      expect(
        isInvalidToken(
          AccessDeniedException(
            'Access was denied (www-authenticate header was: '
            'Bearer error="insufficient_scope").',
          ),
        ),
        isFalse,
      );
    });

    test('DetailedApiRequestError 403 → false', () {
      expect(isInvalidToken(DetailedApiRequestError(403, 'x')), isFalse);
    });

    test('一般網路錯誤 → false', () {
      expect(isInvalidToken(Exception('Connection refused')), isFalse);
    });
  });
}
