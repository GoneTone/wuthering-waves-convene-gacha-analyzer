import 'package:googleapis/oauth2/v2.dart' as oauth2;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/token_store.dart';

/// refresh token 已失效（使用者於 Google 端撤銷授權），需要重新連結時拋出。
class CloudReauthRequiredException implements Exception {
  /// 建立 [CloudReauthRequiredException]。
  const CloudReauthRequiredException();

  @override
  String toString() => 'CloudReauthRequiredException';
}

/// 判斷例外是否為 OAuth `invalid_grant`（refresh token 被撤銷／過期）。
bool isInvalidGrant(Object e) => e.toString().contains('invalid_grant');

/// 以既存 refresh token 建立「已過期」的種子憑證，供 refreshCredentials 換新 access token。
AccessCredentials buildResumeCredentials(String refreshToken) =>
    AccessCredentials(
      AccessToken(
        'Bearer',
        '',
        DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      ),
      refreshToken,
      cloudSyncScopes,
    );

/// 登入成功的授權會話：可用的 [AuthClient] 與帳號 email。
class CloudAuthSession {
  /// 建立 [CloudAuthSession]。
  const CloudAuthSession({required this.client, required this.email});

  /// 自動續期的授權 HTTP client；用畢由呼叫端 close。
  final AuthClient client;

  /// 已連結帳號的 email。
  final String email;
}

/// 包住 [AutoRefreshingAuthClient]，close 時連同自建的底層 base client 一併關閉。
class _OwningAuthClient extends http.BaseClient implements AuthClient {
  /// 建立 [_OwningAuthClient]。
  _OwningAuthClient(this._inner, this._base);

  /// 實際的自動續期授權 client。
  final AutoRefreshingAuthClient _inner;

  /// 自建的底層 client，close 時一併關閉。
  final http.Client _base;

  /// 目前的授權憑證（委派給內部 client）。
  @override
  AccessCredentials get credentials => _inner.credentials;

  /// 發送授權請求（委派給內部 client）。
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  /// 關閉授權 client 與底層 HTTP client。
  @override
  void close() {
    _inner.close();
    _base.close();
    super.close();
  }
}

/// Google OAuth 授權服務：登入（系統瀏覽器 loopback）、以 refresh token 還原、登出。
class GoogleAuthService {
  /// 建立 [GoogleAuthService]。
  GoogleAuthService({
    required this.tokenStore,
    required this.baseClientFactory,
  });

  /// refresh token 的安全儲存。
  final TokenStore tokenStore;

  /// 建立底層 HTTP client 的工廠（測試注入 MockClient 用）。
  final http.Client Function() baseClientFactory;

  /// Logger 實例（授權流程）。
  static final _log = Logger('cloudsync.auth');

  /// OAuth 用戶端識別。
  static final _clientId = ClientId(cloudSyncClientId, cloudSyncClientSecret);

  /// 走 installed-app loopback 流程登入：[openUrl] 收到授權頁 URL 時開啟系統瀏覽器。
  ///
  /// 成功後 refresh token 存入 [tokenStore] 並抓取帳號 email。
  Future<CloudAuthSession> signIn(void Function(String url) openUrl) async {
    _log.info('signIn start');
    final client = await clientViaUserConsent(
      _clientId,
      cloudSyncScopes,
      openUrl,
    );
    try {
      final refresh = client.credentials.refreshToken;
      if (refresh == null) {
        throw StateError('OAuth flow returned no refresh token');
      }
      await tokenStore.writeRefreshToken(refresh);
      final email = await _fetchEmail(client);
      _log.info('signIn ok');
      return CloudAuthSession(client: client, email: email);
    } catch (e) {
      client.close();
      rethrow;
    }
  }

  /// 以已存的 refresh token 還原授權 client；無 token 回 null。
  ///
  /// token 已被撤銷（invalid_grant）時拋 [CloudReauthRequiredException]。
  Future<AuthClient?> restore() async {
    final refresh = await tokenStore.readRefreshToken();
    if (refresh == null) {
      _log.info('restore: no stored token');
      return null;
    }
    final base = baseClientFactory();
    try {
      final refreshed = await refreshCredentials(
        _clientId,
        buildResumeCredentials(refresh),
        base,
      );
      _log.info('restore ok');
      return _OwningAuthClient(
        autoRefreshingClient(_clientId, refreshed, base),
        base,
      );
    } catch (e) {
      base.close();
      if (isInvalidGrant(e)) {
        _log.warning('restore: invalid_grant, reauth required');
        throw const CloudReauthRequiredException();
      }
      rethrow;
    }
  }

  /// 登出：向 Google revoke（盡力而為，失敗不阻擋）並刪除本機 refresh token。
  Future<void> signOut() async {
    final refresh = await tokenStore.readRefreshToken();
    if (refresh != null) {
      final base = baseClientFactory();
      try {
        final res = await base.post(
          Uri.parse('https://oauth2.googleapis.com/revoke'),
          body: {'token': refresh},
        );
        if (res.statusCode == 200) {
          _log.info('revoke ok');
        } else {
          _log.warning('revoke failed (ignored): HTTP ${res.statusCode}');
        }
      } catch (e) {
        _log.warning('revoke failed (ignored): $e');
      } finally {
        base.close();
      }
    }
    await tokenStore.deleteRefreshToken();
    _log.info('signOut done');
  }

  /// 以 userinfo API 取得已授權帳號的 email。
  Future<String> _fetchEmail(http.Client client) async {
    final info = await oauth2.Oauth2Api(client).userinfo.get();
    final email = info.email;
    if (email == null || email.isEmpty) {
      throw StateError('userinfo returned no email');
    }
    return email;
  }
}
