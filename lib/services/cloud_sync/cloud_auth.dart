import 'package:googleapis/oauth2/v2.dart' as oauth2;
import 'package:http/http.dart' as http;

/// 一次互動式連結的結果；呼叫端確認結果仍有效後才 [commit]。
class CloudLinkResult {
  /// 建立 [CloudLinkResult]。
  const CloudLinkResult({
    required this.client,
    required this.email,
    required this.commit,
  });

  /// 已授權的 HTTP client；用畢由呼叫端 close。
  final http.Client client;

  /// 已連結帳號的 email。
  final String email;

  /// 持久化本次授權（Windows：寫入 refresh token；Android：no-op）。
  final Future<void> Function() commit;
}

/// 使用者在授權畫面取消時拋出。
class CloudLinkCancelledException implements Exception {
  /// 建立 [CloudLinkCancelledException]。
  const CloudLinkCancelledException(this.reason);

  /// 取消原因，僅供 log（例如 GoogleSignInExceptionCode 名稱）。
  final String reason;

  @override
  String toString() => 'CloudLinkCancelledException($reason)';
}

/// 雲端同步的授權介面，依平台各自實作。
abstract class CloudAuth {
  /// 這個實作的 client 能否跨多輪同步沿用。
  bool get keepsClientAcrossRounds;

  /// 互動式連結：[openUrl] 收到授權頁 URL 時開啟瀏覽器；[postAuthPage] 為授權成功後顯示的 HTML。
  Future<CloudLinkResult> link({
    required void Function(String url) openUrl,
    String? postAuthPage,
  });

  /// 還原已連結帳號的授權 client；無法靜默還原時回 null 或拋 `CloudReauthRequiredException`。
  Future<http.Client?> restoreClient({required String expectedEmail});

  /// 中斷連結：只忘記本機，不向 Google 撤銷。
  Future<void> unlink();
}

/// 以已授權的 [client] 呼叫 userinfo 取 email；沒有 email 時拋 [StateError]。
Future<String> fetchCloudEmail(http.Client client) async {
  final info = await oauth2.Oauth2Api(client).userinfo.get();
  final email = info.email;
  if (email == null || email.isEmpty) {
    throw StateError('userinfo returned no email');
  }
  return email;
}
