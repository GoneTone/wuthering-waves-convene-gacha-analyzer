import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_auth_service.dart';

void main() {
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
    test('Drive 403 insufficient_scope 訊息 → true', () {
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
    });

    test('一般網路錯誤 → false', () {
      expect(isInsufficientScope(Exception('Connection refused')), isFalse);
    });
  });
}
