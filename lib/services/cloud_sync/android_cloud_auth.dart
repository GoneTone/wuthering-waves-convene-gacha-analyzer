import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_auth.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_auth_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_authorization_gateway.dart';

/// Android 的 [CloudAuth]：以 Play services 授權 API 取短效通行證，不保存 refresh token。
class AndroidCloudAuth implements CloudAuth {
  /// 建立 [AndroidCloudAuth]。
  AndroidCloudAuth({required this.gateway, required this.baseClientFactory});

  /// 授權 API 的最小介面。
  final GoogleAuthorizationGateway gateway;

  /// 建立底層 HTTP client 的工廠（測試注入 MockClient 用）。
  final http.Client Function() baseClientFactory;

  /// Logger 實例（授權流程）。
  static final _log = Logger('cloudsync.auth');

  /// 通行證的假定有效期；Google 實際約 1 小時，留 5 分鐘餘裕。
  static const _tokenLifetime = Duration(minutes: 55);

  @override
  bool get keepsClientAcrossRounds => false;

  /// 以 [token] 建立帶 Bearer 憑證的 client，close 時連同底層 client 一併關閉。
  http.Client _clientFor(String token) => authenticatedClient(
    baseClientFactory(),
    AccessCredentials(
      AccessToken('Bearer', token, DateTime.now().toUtc().add(_tokenLifetime)),
      null,
      cloudSyncScopes,
    ),
    closeUnderlyingClient: true,
  );

  /// 取得並驗證通行證（以 userinfo 確認未被撤銷）；回傳 client 與 email。
  ///
  /// 通行證被 API 拒絕（401）時清掉系統快取並以同一種方式重取一次；
  /// 第二次仍被拒（同樣清掉快取）：[interactive] 為 true 拋出錯誤，否則回 null。靜默拿不到時回 null。
  Future<({http.Client client, String email})?> _verifiedToken({
    required bool interactive,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final token = interactive
          ? await gateway.interactiveToken()
          : await gateway.silentToken();
      if (token == null) return null;
      final client = _clientFor(token);
      try {
        return (client: client, email: await fetchCloudEmail(client));
      } catch (e) {
        client.close();
        if (!isInvalidToken(e)) rethrow;
        _log.info('android token rejected (401), clearing cache and retrying');
        await gateway.clearToken(token);
        if (attempt >= 1) {
          if (interactive) rethrow;
          return null;
        }
      }
    }
  }

  @override
  Future<CloudLinkResult> link({
    required void Function(String url) openUrl,
    String? postAuthPage,
  }) async {
    _log.info('android link start');
    final verified = (await _verifiedToken(interactive: true))!;
    _log.info('android link ok');
    return CloudLinkResult(
      client: verified.client,
      email: verified.email,
      commit: () async {},
    );
  }

  @override
  Future<http.Client?> restoreClient({required String expectedEmail}) async {
    final verified = await _verifiedToken(interactive: false);
    if (verified == null) {
      _log.info('android restore: needs user interaction');
      return null;
    }
    if (verified.email != expectedEmail) {
      verified.client.close();
      _log.warning('android restore: account mismatch, relink required');
      throw const CloudReauthRequiredException();
    }
    return verified.client;
  }

  @override
  Future<void> unlink() async {
    final token = await gateway.silentToken();
    if (token != null) await gateway.clearToken(token);
    await gateway.signOut();
    _log.info('android unlink done (local only)');
  }
}
