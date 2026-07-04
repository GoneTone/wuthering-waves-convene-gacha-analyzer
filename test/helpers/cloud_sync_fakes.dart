import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_remote.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_auth_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/token_store.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';

/// 測試用 in-memory token store。
class InMemoryTokenStore implements TokenStore {
  /// 目前存放的 token。
  String? token;

  @override
  Future<String?> readRefreshToken() async => token;

  @override
  Future<void> writeRefreshToken(String t) async => token = t;

  @override
  Future<void> deleteRefreshToken() async => token = null;
}

/// 不發真請求的 fake AuthClient。
class FakeAuthClient extends http.BaseClient implements AuthClient {
  @override
  AccessCredentials get credentials => throw UnimplementedError();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();
}

/// 可程式化行為的 fake 授權服務。
class FakeAuthService extends GoogleAuthService {
  /// 建立 [FakeAuthService]，以 [store] 作為底層 token store。
  FakeAuthService(this.store)
    : super(tokenStore: store, baseClientFactory: http.Client.new);

  /// 供斷言的 token store。
  final InMemoryTokenStore store;

  /// restore 是否要拋 invalid_grant。
  bool restoreThrowsReauth = false;

  @override
  Future<CloudAuthSession> signIn(void Function(String url) openUrl) async {
    openUrl('https://accounts.google.com/consent');
    await store.writeRefreshToken('refresh-1');
    return CloudAuthSession(client: FakeAuthClient(), email: 'u@example.com');
  }

  @override
  Future<AuthClient?> restore() async {
    if (restoreThrowsReauth) throw const CloudReauthRequiredException();
    if (store.token == null) return null;
    return FakeAuthClient();
  }

  @override
  Future<void> signOut() async => store.deleteRefreshToken();
}

/// 記錄呼叫的 fake 遠端。
class FakeRemote implements CloudSyncRemote {
  /// 雲端檔內容。
  String? content;

  /// upload 次數。
  int uploads = 0;

  @override
  Future<String?> download() async => content;

  @override
  Future<void> upload(String json) async {
    uploads++;
    content = json;
  }
}

/// 不會被觸發的 fake capture。
class FakeCapture implements GachaCapture {
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(null), cancel: () async {});
}
