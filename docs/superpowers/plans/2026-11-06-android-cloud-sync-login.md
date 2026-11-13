# Android 雲端同步登入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Android 版能用 Google Play 服務的授權 API 連結 Google 帳號，並和 PC 版同步同一份雲端硬碟檔案；兩個平台的「中斷連結」都改成只忘記本機。

**Architecture:** 新增平台無關的 `CloudAuth` 介面。`CloudSyncNotifier` 只依賴這個介面：Windows 由既有的 `GoogleAuthService` 實作，拿掉所有撤銷；Android 新增 `AndroidCloudAuth`，透過一層可替換的 `GoogleAuthorizationGateway` 呼叫 `google_sign_in` 的 authorization client。Android 的通行證每輪同步都重新靜默取得，遇到 401 時清掉快取、重取一次。

**Tech Stack:** Flutter（FVM 3.47.5）、Riverpod 3、`google_sign_in` ^7.2.0、`googleapis` / `googleapis_auth`（既有）、`flutter_test` + `http/testing.dart` 的 `MockClient`。

**Spec:** `docs/superpowers/specs/2026-11-06-android-cloud-sync-login-design.md`

## Global Constraints

- 一律用 `fvm flutter` / `fvm dart`。commit 前依序執行：`fvm dart format lib/ test/` → `fvm flutter analyze`（`No issues found!`）→ `fvm flutter test`（`All tests passed!`）。
- 不新增 define，也不建網頁應用程式用戶端。Android 上 `isCloudSyncConfigured` 改看 `CLOUD_SYNC_CLIENT_ID` 不為空；Windows 維持看 `CLIENT_ID`＋`CLIENT_SECRET`。
- Android 只用授權 API：`GoogleSignIn.instance.initialize()` 不帶參數，再用 `GoogleSignIn.instance.authorizationClient`。**不呼叫** `authenticate()`。
- 兩個平台都**不再向 Google 撤銷**（`oauth2.googleapis.com/revoke`）。中斷連結只清本機。
- Scopes 沿用 `cloudSyncScopes`（`drive.appdata`＋`email`）。email 由 userinfo API 取得。
- log 一律英文；Logger 沿用 `cloudsync.auth`／`cloudsync.sync`；不記通行證內容，email 不寫進 log。
- 每個宣告都要有一行 `///` dartdoc（含 private）；實作層註解只寫 WHY。CJK 文字一律全形標點，省略號用 ASCII `...`。
- 新字串只改四份核心 ARB：`app_en.arb`、`app_ja.arb`、`app_zh.arb`、`app_zh_Hans.arb`。
- 平台測試用 provider override（`isAndroidProvider`）或 `TargetPlatformVariant.only(...)`，不要在測試本體直接設 `debugDefaultTargetPlatformOverride`。
- commit message 用英文 conventional commits，結尾附：
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WreXjnEijW2movWG3V3c7c
  ```
- 不要 push。

## Review Focus

1. 使用者在 Google 帳戶設定撤銷了 App 的存取權，手機卻還快取著舊通行證。這時靜默還原應該清掉快取、重取一次；重取失敗就進入「需要重新連結」，不能一直卡在網路錯誤。（Task 2 測試 `restore: stale cached token that cannot be renewed → reauth`）
2. 快取的舊通行證還在時重新連結：互動授權拿回舊通行證，應該清掉快取再授權一次，最後成功連結。（Task 2 測試 `link: stale token from interactive authorize → clear and retry once`）
3. 連續兩輪同步，Android 第二輪也要重新取得通行證，不可沿用上一輪的 client（實際情況是開著超過 1 小時）。（Task 1 測試 `non-persistent auth → client restored again on the next round`）
4. Windows 中斷連結完全不打網路，只刪本機 token。（Task 1 測試 `signOut deletes the stored token without any network request`）
5. 在 Android 系統視窗按取消：回到閒置、不顯示「授權失敗」，也不寫入 email。（Task 1 測試 `link cancelled by the user → idle without error`）

---

## File Structure

| 檔案 | 動作 | 責任 |
|---|---|---|
| `lib/services/cloud_sync/cloud_auth.dart` | 新增 | `CloudAuth` 介面、`CloudLinkResult`、`CloudLinkCancelledException`、共用的 `fetchCloudEmail` |
| `lib/services/cloud_sync/google_auth_service.dart` | 修改 | 實作 `CloudAuth`（Windows）；拿掉所有撤銷；`_fetchEmail` 改用 `fetchCloudEmail` |
| `lib/services/cloud_sync/cloud_sync_config.dart` | 修改 | `cloudSyncConfiguredFor(...)` 純函式＋依平台的 `isCloudSyncConfigured` |
| `lib/services/cloud_sync/google_authorization_gateway.dart` | 新增 | `GoogleAuthorizationGateway` 介面＋`PluginGoogleAuthorizationGateway`（實際呼叫 `google_sign_in`） |
| `lib/services/cloud_sync/android_cloud_auth.dart` | 新增 | `AndroidCloudAuth implements CloudAuth` |
| `lib/state/cloud_sync.dart` | 修改 | `cloudAuthProvider`（依平台選實作）；notifier 改用 `CloudAuth`；取消處理；非持久 client |
| `lib/widgets/cards/cloud_sync_section.dart` | 修改 | Android 等待文字；Android 不呼叫把視窗帶回前景 |
| 四份核心 ARB | 修改 | 新增 `cloudSyncAwaitingConsentAndroid`；`cloudSyncIntro` 改成不限裝置 |
| `test/helpers/cloud_sync_fakes.dart` | 修改 | 拿掉 `revokeToken` / `lastRevokedToken` |
| `test/state/cloud_sync_test.dart`、`test/services/cloud_sync/*`、`test/widgets/cloud_sync_section_test.dart` | 修改／新增 | 見各 Task |
| `docs/Android移植筆記.md`、README ×4 | 修改 | Task 4 |

---

### Task 1: `CloudAuth` 介面、Windows 不再撤銷、notifier 改用介面

**Files:**
- Create: `lib/services/cloud_sync/cloud_auth.dart`
- Modify: `lib/services/cloud_sync/google_auth_service.dart`、`lib/services/cloud_sync/cloud_sync_config.dart`、`lib/state/cloud_sync.dart`
- Modify (tests): `test/helpers/cloud_sync_fakes.dart`、`test/state/cloud_sync_test.dart`、`test/services/cloud_sync/google_auth_service_test.dart`
- Create (test): `test/services/cloud_sync/cloud_sync_config_test.dart`

**Interfaces:**
- Produces（`cloud_auth.dart`）：
  ```dart
  /// 一次互動式連結的結果；呼叫端確認結果仍有效後才 [commit]。
  class CloudLinkResult {
    const CloudLinkResult({required this.client, required this.email, required this.commit});
    final http.Client client;
    final String email;
    final Future<void> Function() commit; // Windows：寫入 refresh token；Android：no-op
  }

  /// 使用者在授權畫面取消時拋出。
  class CloudLinkCancelledException implements Exception {
    const CloudLinkCancelledException(this.reason);
    final String reason; // 進 log 用（例如 GoogleSignInExceptionCode 名稱）
  }

  /// 雲端同步的授權介面，依平台各自實作。
  abstract class CloudAuth {
    /// 這個實作的 client 能否跨多輪同步沿用。
    bool get keepsClientAcrossRounds;
    Future<CloudLinkResult> link({required void Function(String url) openUrl, String? postAuthPage});
    /// 無法靜默還原時回 null 或拋 [CloudReauthRequiredException]。
    Future<http.Client?> restoreClient({required String expectedEmail});
    /// 只忘記本機，不向 Google 撤銷。
    Future<void> unlink();
  }

  /// 以已授權的 [client] 呼叫 userinfo 取 email；沒有 email 時拋 StateError。
  Future<String> fetchCloudEmail(http.Client client);
  ```
- Produces（`cloud_sync_config.dart`）：`bool cloudSyncConfiguredFor({required bool android, required String clientId, required String clientSecret})`。`isCloudSyncConfigured` 改用它，`android` 取 `defaultTargetPlatform == TargetPlatform.android`。`debugCloudSyncConfiguredOverride` 保留。
- Produces（`cloud_sync.dart`）：`final cloudAuthProvider = Provider<CloudAuth>(...)`。本 Task 一律回傳 `ref.watch(googleAuthServiceProvider)`，Android 分支在 Task 2 補上。
- `GoogleAuthService implements CloudAuth`：
  - `keepsClientAcrossRounds => true`。
  - `link` 呼叫既有的 `signIn(openUrl, postAuthPage:)`，`commit` 寫入 refresh token。
  - `restoreClient` 呼叫既有的 `restore()`，忽略 `expectedEmail`。
  - `unlink` 呼叫 `signOut()`。

- [ ] **Step 1: 寫失敗的測試**

`test/services/cloud_sync/cloud_sync_config_test.dart`：
```dart
test('android: configured when the desktop client id is present', () {
  expect(cloudSyncConfiguredFor(android: true, clientId: 'id', clientSecret: ''), isTrue);
  expect(cloudSyncConfiguredFor(android: true, clientId: '', clientSecret: 's'), isFalse);
});
test('windows: needs both id and secret', () {
  expect(cloudSyncConfiguredFor(android: false, clientId: 'id', clientSecret: 's'), isTrue);
  expect(cloudSyncConfiguredFor(android: false, clientId: 'id', clientSecret: ''), isFalse);
});
```

`test/services/cloud_sync/google_auth_service_test.dart`：
```dart
test('signOut deletes the stored token without any network request', () async {
  var requests = 0;
  final store = InMemoryTokenStore()..token = 'refresh-1';
  final svc = GoogleAuthService(
    tokenStore: store,
    baseClientFactory: () => MockClient((_) async { requests++; return http.Response('', 200); }),
  );
  await svc.unlink();
  expect(store.token, isNull);
  expect(requests, 0);
});
```

`test/state/cloud_sync_test.dart`：
- 既有 `'cancelLink 後遲到的授權結果不寫入 token store、原地 revoke (I1)'` 改名為 `'cancelLink 後遲到的授權結果不寫入 token store、不撤銷 (I1)'`。刪掉 `lastRevokedToken` 那行斷言，其餘斷言保留。
- 新增 `'link cancelled by the user → idle without error'`：fake 的 `signIn` 拋 `CloudLinkCancelledException('canceled')`。斷言 phase 是 `idle`、`errorToken` 是 null、`cloudAccountEmail` 是 null、`tokenStore.token` 是 null。
- 新增 `'non-persistent auth → client restored again on the next round'`：用一個 `keepsClientAcrossRounds == false` 的 fake `CloudAuth`，透過 `cloudAuthProvider.overrideWithValue(...)` 注入，`restoreClient` 回 `FakeAuthClient()` 並計次。settings 先設好 email，連續跑兩次 `syncNow(manual: true)`，斷言 `restoreClient` 被呼叫 2 次、`expectedEmail` 等於存的 email。

`test/helpers/cloud_sync_fakes.dart`：
- 移除 `revokeToken` override 與 `lastRevokedToken` 欄位（基底方法會在 Step 3 刪掉）。
- `FakeAuthService` 新增 `bool signInThrowsCancelled = false`：為 true 時，`signIn` 拋 `CloudLinkCancelledException('canceled')`。上面的取消測試用的就是它。

- [ ] **Step 2: 執行測試，確認失敗**

Run: `fvm flutter test test/services/cloud_sync test/state/cloud_sync_test.dart`
Expected: FAIL，原因是編譯錯誤：`cloudSyncConfiguredFor`、`CloudLinkCancelledException`、`cloudAuthProvider`、`unlink` 未定義。

- [ ] **Step 3: 實作**

- `cloud_auth.dart`：寫好上面列的介面。`fetchCloudEmail` 把 `GoogleAuthService._fetchEmail` 搬過來（`oauth2.Oauth2Api(client).userinfo.get()`），`GoogleAuthService` 改呼叫它。
- `GoogleAuthService`：
  - 刪除 `revokeToken()`。
  - `signIn` 授權缺 Drive scope 時，不撤銷，直接拋 `CloudScopeMissingException`（既有的 catch 會關閉 client）。
  - `signOut()` 只刪 token 並記 `signOut done (local only)`。
  - 照 Interfaces 實作 `CloudAuth`。
  - 類別 dartdoc 改成不再提撤銷。
- `CloudSyncNotifier`：
  - 一律讀 `cloudAuthProvider`。
  - `link`：
    - 呼叫 `auth.link(openUrl:, postAuthPage:)`。
    - 世代已過期（被取消）就關閉 client 後 return，**不撤銷**、不 commit。
    - 世代仍有效：先 `await result.commit()`，再存 client、存 email、跑同步。
    - `on CloudLinkCancelledException catch (e)`：世代仍有效時回到 `CloudSyncState()`，log `link cancelled by user reason=${e.reason}`（info）。
  - `unlink` 改呼叫 `auth.unlink()`。
  - `_ensureClient` 呼叫 `restoreClient(expectedEmail: settings.cloudAccountEmail!)`。`_client` 型別改成 `http.Client?`。
  - `syncNow` 的 `finally` 裡，若 `!auth.keepsClientAcrossRounds` 就關閉並清掉 `_client`。
  - `tokenStoreProvider` 仍由 `googleAuthServiceProvider` 使用，notifier 不再直接寫 token store。

- [ ] **Step 4: 執行測試，確認通過**

Run: `fvm flutter test test/services/cloud_sync test/state/cloud_sync_test.dart test/widgets/cloud_sync_section_test.dart`
Expected: PASS

- [ ] **Step 5: 品質檢查並 commit**

依 Global Constraints 跑 format、analyze 與完整測試，然後：
```bash
git add lib/services/cloud_sync lib/state/cloud_sync.dart test/helpers/cloud_sync_fakes.dart test/state/cloud_sync_test.dart test/services/cloud_sync
git commit -m "refactor(cloudsync): route sign-in through a platform auth interface and stop revoking grants"
```

---

### Task 2: Android 授權實作

**Files:**
- Modify: `pubspec.yaml`、`pubspec.lock`（`fvm flutter pub add google_sign_in:^7.2.0`）
- Create: `lib/services/cloud_sync/google_authorization_gateway.dart`、`lib/services/cloud_sync/android_cloud_auth.dart`
- Modify: `lib/state/cloud_sync.dart`（`cloudAuthProvider` 的 Android 分支）
- Create (test): `test/services/cloud_sync/android_cloud_auth_test.dart`

**Interfaces:**
- Consumes：Task 1 的 `CloudAuth`、`CloudLinkResult`、`CloudLinkCancelledException`、`fetchCloudEmail`、`CloudReauthRequiredException`。
- Produces（`google_authorization_gateway.dart`）：
  ```dart
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
  ```
  `PluginGoogleAuthorizationGateway` 的實作要點：
  - 初始化：`_init ??= GoogleSignIn.instance.initialize()`，失敗時把 `_init` 重設為 null，下次重試。
  - 取通行證：`GoogleSignIn.instance.authorizationClient` 的 `authorizationForScopes(cloudSyncScopes)` 或 `authorizeScopes(cloudSyncScopes)`，回傳其中的 `.accessToken`。
  - 清快取：`clearAuthorizationToken(accessToken:)`。
  - 登出：`GoogleSignIn.instance.signOut()`。
  - `GoogleSignInException` 的 code 是 `canceled` 時，轉成 `CloudLinkCancelledException(e.code.name)`。
- Produces（`android_cloud_auth.dart`）：`AndroidCloudAuth({required GoogleAuthorizationGateway gateway, required http.Client Function() baseClientFactory})`，`keepsClientAcrossRounds => false`。
  - client 用 `authenticatedClient(base, AccessCredentials(AccessToken('Bearer', token, <now UTC + 55 分鐘>), null, cloudSyncScopes), closeUnderlyingClient: true)` 建立。
  - 「已驗證的通行證」：拿到通行證後先跑 `fetchCloudEmail`。若拋出 `DetailedApiRequestError` 且 `status == 401`，就 `clearToken` 再用同一種方式（靜默或互動）重取**一次**、再驗證；第二次仍是 401 時：互動路徑拋出錯誤，靜默路徑回 null。
  - `link`：走互動路徑，`commit` 為 no-op。
  - `restoreClient`：
    - 靜默拿不到 → 回 null。
    - email 與 `expectedEmail` 不同 → 拋 `CloudReauthRequiredException`。
  - `unlink`：靜默拿得到通行證就 `clearToken`，然後 `signOut()`。不打 revoke。
- `cloudAuthProvider`：`ref.watch(isAndroidProvider)` 為 true 時，回傳 `AndroidCloudAuth(gateway: PluginGoogleAuthorizationGateway(), baseClientFactory: http.Client.new)`。gateway 另開 `googleAuthorizationGatewayProvider` 以便替換。

- [ ] **Step 1: 寫失敗的測試**

`test/services/cloud_sync/android_cloud_auth_test.dart`：
- `_FakeGateway`：
  - 可設定 `silent`、`interactive` 兩個佇列，每次呼叫取下一個值；值為 null 代表需要使用者操作。
  - 記錄 `cleared`（List）、`signOutCalls`。
  - 可設定 interactive 拋 `CloudLinkCancelledException`。
- userinfo 用 `MockClient` 模擬：通行證 `good-*` 回 200 `{"email":"u@example.com"}`；`stale` 回 401；`other` 回 200 `{"email":"x@example.com"}`。
- 各測試的斷言：

```dart
test('link: interactive token → email and a client', ...);
  // interactive=['good-1'] → result.email == 'u@example.com'; 呼叫 commit() 不拋錯
test('link: stale token from interactive authorize → clear and retry once', ...);
  // interactive=['stale','good-2'] → email 'u@example.com'; cleared == ['stale']
test('link: user cancels → CloudLinkCancelledException propagates', ...);
test('restore: silent token → client', ...);
  // silent=['good-1'], expectedEmail 'u@example.com' → 回傳非 null
test('restore: no silent token → null', ...);
test('restore: different account than the linked email → reauth', ...);
  // silent=['other'] → throwsA(isA<CloudReauthRequiredException>())
test('restore: stale cached token that cannot be renewed → reauth', ...);
  // silent=['stale', null] → 回傳 null; cleared == ['stale']
test('unlink: clears the cached token and signs out without revoking', ...);
  // silent=['good-1'] → cleared == ['good-1']; signOutCalls == 1; MockClient 沒收到任何 /revoke 請求
test('keepsClientAcrossRounds is false', ...);
```

- [ ] **Step 2: 執行測試，確認失敗**

Run: `fvm flutter test test/services/cloud_sync/android_cloud_auth_test.dart`
Expected: FAIL，原因是編譯錯誤：`AndroidCloudAuth`、`GoogleAuthorizationGateway` 未定義。

- [ ] **Step 3: 加入套件並實作**

先執行 `fvm flutter pub add google_sign_in:^7.2.0`，再依 Interfaces 實作兩個檔案與 provider 分支。log：
- `cloudsync.auth`：
  - `android link start`、`android link ok`
  - `android token rejected (401), clearing cache and retrying`
  - `android restore: needs user interaction`
  - `android restore: account mismatch, relink required`
  - `android unlink done (local only)`
- 不記 token 與 email。

- [ ] **Step 4: 執行測試，確認通過**

Run: `fvm flutter test test/services/cloud_sync test/state/cloud_sync_test.dart`
Expected: PASS

- [ ] **Step 5: Android 建置確認**

Run: `fvm flutter build apk --debug --dart-define-from-file=secrets/cloud_sync_defines.json`
Expected: `✓ Built build\app\outputs\flutter-apk\app-debug.apk`（`google_sign_in_android` 在現有 AGP 9／Kotlin 設定下可以編過；手機實驗時已實測過一次）

- [ ] **Step 6: 品質檢查並 commit**

```bash
git add pubspec.yaml pubspec.lock lib/services/cloud_sync lib/state/cloud_sync.dart test/services/cloud_sync/android_cloud_auth_test.dart
git commit -m "feat(cloudsync): sign in on Android with the Play services authorization API"
```

---

### Task 3: 手機介面文字與前景行為

**Files:**
- Modify: `lib/widgets/cards/cloud_sync_section.dart`
- Modify: `lib/l10n/app_en.arb`、`app_ja.arb`、`app_zh.arb`、`app_zh_Hans.arb`
- Modify (test): `test/widgets/cloud_sync_section_test.dart`

**Interfaces:**
- Consumes：`isAndroidProvider`（`lib/state/platform.dart`）、Task 1／2 的 `cloudAuthProvider`。
- 新 ARB key `cloudSyncAwaitingConsentAndroid`（en 檔要附 `@` 描述），文字如下：

| locale | `cloudSyncAwaitingConsentAndroid` | `cloudSyncIntro`（改寫） |
|---|---|---|
| zh | `請在 Google 視窗完成授權...` | `連結 Google 帳號後，喚取紀錄會自動備份到你的 Google 雲端硬碟，並在多台裝置間同步。` |
| zh_Hans | `请在 Google 窗口完成授权...` | `关联 Google 账号后，唤取记录会自动备份到你的 Google 云端硬盘，并在多台设备间同步。` |
| en | `Please finish authorization in the Google window...` | `Link your Google account to automatically back up convene records to your Google Drive and keep multiple devices in sync.` |
| ja | `Google の画面で認可を完了してください...` | `Google アカウントを連携すると、喚起履歴が自動的に Google ドライブへバックアップされ、複数のデバイス間で同期されます。` |

- 不改的部分：Android 等待授權時的「取消」按鈕保留；中斷連結的確認文字不改（spec 第七節交給實作者決定，這裡選擇不改）。

- [ ] **Step 1: 寫失敗的測試**

在 `test/widgets/cloud_sync_section_test.dart` 的 `wrap()` 加一個 `bool android = false` 參數，覆寫 `isAndroidProvider`。Android 的情境：
- 用一個 fake `CloudAuth`（`cloudAuthProvider` override），`link` 回傳一個不會完成的 Future，畫面停在等待授權。
- 另一個 fake 的 `link` 拋 `CloudScopeMissingException`，讓等待授權結束。

```dart
testWidgets('android: awaiting consent shows the Google window hint', ...);
  // 點連結 → find.text(l.cloudSyncAwaitingConsentAndroid) findsOneWidget；
  // find.text(l.cloudSyncAwaitingConsent) findsNothing
testWidgets('android: leaving consent does not bring the window to front', ...);
  // 連結結束（拋 scope missing）→ onForeground 呼叫次數 == 0
```

既有的 `'授權等待結束 → 自動把視窗帶回前景'`（Windows）維持不變，照樣要通過。

- [ ] **Step 2: 執行測試，確認失敗**

Run: `fvm flutter test test/widgets/cloud_sync_section_test.dart`
Expected: FAIL，原因是 `cloudSyncAwaitingConsentAndroid` 不存在，或文字對不上。

- [ ] **Step 3: 實作**

- 先改四份 ARB，再跑 `fvm flutter gen-l10n`。
- `_AwaitingConsentRow` 依 `isAndroidProvider` 選擇要顯示的字串。
- `CloudSyncSection` 裡把視窗帶回前景的 `ref.listen`：Android 時不呼叫 `windowForegroundProvider`。

- [ ] **Step 4: 執行測試，確認通過**

Run: `fvm flutter test test/widgets/cloud_sync_section_test.dart`
Expected: PASS

- [ ] **Step 5: 品質檢查並 commit**

```bash
git add lib/widgets/cards/cloud_sync_section.dart lib/l10n/app_en.arb lib/l10n/app_ja.arb lib/l10n/app_zh.arb lib/l10n/app_zh_Hans.arb test/widgets/cloud_sync_section_test.dart
git commit -m "feat(cloudsync): show Android-specific consent hint and device-neutral intro"
```

---

### Task 4: 文件

**Files:**
- Modify: `docs/Android移植筆記.md`（新增「## 九、雲端同步登入（子專案 5）」，從 #29 起編號）
- Modify: `README.md`、`README_EN.md`、`README_JA-JP.md`、`README_ZH-HANS.md` 的「自行建置啟用雲端同步」段落（約第 112–131 行）

- [ ] **Step 1: 移植筆記**

內容依 spec 第四節的實驗結果整理成條目，至少包含：
- 只走授權 API，不需要網頁用戶端。拿桌面用戶端 ID 當 `serverClientId` 會得到 `[28444]` 錯誤。
- Android 用戶端以套件名稱＋SHA-1 辨識，ID 不放進程式；tokeninfo 的 `azp` 是查證方法。
- 授權是整個專案共用一份，撤銷會讓所有裝置失效，所以中斷連結只忘記本機。
- Play 服務會快取已失效的通行證，要用 `clearAuthorizationToken` 清掉。
- 「只忘記本機」之後再連結會跳帳號選擇。
- **子專案 7 待辦**：上傳金鑰與 Play 簽署金鑰的 SHA-1 要補登記到 Android 用戶端。

- [ ] **Step 2: README ×4**

在既有步驟後補上：
- Android 沿用同一個 `secrets/cloud_sync_defines.json`。
- 要在同一個 Google Cloud 專案建立 Android 類型 OAuth 用戶端（套件名稱 `tw.reh.wuwa.gacha`＋簽章 SHA-1）。
- 範例 `flutter run -d <device> --dart-define-from-file=secrets/cloud_sync_defines.json`。

四種語言各自用該語言的標點慣例。

- [ ] **Step 3: commit**

```bash
git add docs/Android移植筆記.md README.md README_EN.md README_JA-JP.md README_ZH-HANS.md
git commit -m "docs(android): record cloud sync sign-in findings and Android build setup"
```

---

### Task 5: 實機驗收（主控執行，不交給子代理）

不寫新程式碼。發現問題時，就在對應的 Task 範圍內補測試、修正。

- [ ] **Step 1: 手機**

用 `fvm flutter build apk --debug --dart-define-from-file=secrets/cloud_sync_defines.json` 建置，以 `adb install -r` 安裝（保留資料）。依序確認：
1. 連結 → 帳號選擇 → 授權 → 設定頁顯示 email。
2. 首輪同步合併了 PC 的紀錄。
3. 手機新增或刪除資料，PC 同步後看得到。
4. 殺掉 App 重開，自動同步不必重新連結。
5. 中斷連結 → PC 按「立即同步」仍正常；手機再連結會跳帳號選擇。
6. App 開著超過 1 小時（可與其他步驟並行）後再觸發同步，仍然成功。

授權畫面需要使用者本人操作。

- [ ] **Step 2: Windows**

用 `fvm flutter run -d windows --dart-define-from-file=secrets/cloud_sync_defines.json` 執行，確認：
1. 連結、同步正常。
2. 中斷連結後，手機照常同步。
3. 再連結正常。

- [ ] **Step 3: 收尾**

依 Global Constraints 跑完品質檢查，結果記入移植筆記 §九；有修正就 commit。
