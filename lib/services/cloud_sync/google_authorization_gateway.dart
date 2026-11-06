import 'package:google_sign_in/google_sign_in.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_auth.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';

/// google_sign_in 授權 API 的最小介面（測試替換用）。
abstract class GoogleAuthorizationGateway {
  /// 不跳任何畫面取得通行證；需要使用者操作時回 null。
  Future<String?> silentToken();

  /// 跳帳號選擇／授權畫面取得通行證；使用者取消時拋 [CloudLinkCancelledException]。
  Future<String> interactiveToken();

  /// 清掉系統快取的這張通行證。
  Future<void> clearToken(String token);

  /// 清掉本機登入狀態（不撤銷）。
  Future<void> signOut();
}

/// 以 google_sign_in 的授權 API（Play services）實作 [GoogleAuthorizationGateway]。
class PluginGoogleAuthorizationGateway implements GoogleAuthorizationGateway {
  /// 進行中或已完成的初始化；失敗時重設為 null 以便下次重試。
  Future<void>? _init;

  /// 確保 [GoogleSignIn.instance] 已初始化後回傳其授權 client。
  Future<GoogleSignInAuthorizationClient> _client() async {
    try {
      await (_init ??= GoogleSignIn.instance.initialize());
    } catch (_) {
      _init = null;
      rethrow;
    }
    return GoogleSignIn.instance.authorizationClient;
  }

  @override
  Future<String?> silentToken() async {
    final auth = await (await _client()).authorizationForScopes(
      cloudSyncScopes,
    );
    return auth?.accessToken;
  }

  @override
  Future<String> interactiveToken() async {
    final client = await _client();
    try {
      return (await client.authorizeScopes(cloudSyncScopes)).accessToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw CloudLinkCancelledException(e.code.name);
      }
      rethrow;
    }
  }

  @override
  Future<void> clearToken(String token) async =>
      (await _client()).clearAuthorizationToken(accessToken: token);

  @override
  Future<void> signOut() async {
    await _client();
    await GoogleSignIn.instance.signOut();
  }
}
