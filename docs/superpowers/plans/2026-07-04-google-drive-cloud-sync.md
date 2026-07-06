# Google Drive 雲端同步 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 使用者連結自己的 Google 帳號後，喚取紀錄以手動匯出同格式（`AccountsBundle`）自動備份到 Google Drive `appDataFolder` 並雙向同步。

**Architecture:** 沿用現有 `exportAccounts` / `importAccounts` / `mergeBackupRecords` 資料路徑，新增三層：`GoogleAuthService`（OAuth ＋ token 安全儲存）→ `DriveSyncRemote`（appDataFolder 單檔下載／上傳）→ `runSyncRound`（下載→合併→上傳編排，純函式可測）。`CloudSyncNotifier`（Riverpod）管理連結狀態、四個觸發入口與 5 秒 debounce。

**Tech Stack:** Flutter（Windows only）、Riverpod 3.x NotifierProvider、`googleapis`（Drive v3 ＋ oauth2 userinfo）、`googleapis_auth`（installed-app loopback 授權）、`flutter_secure_storage`（DPAPI 存 refresh token）、`synchronized`（已有）。

**Spec:** `docs/superpowers/specs/2026-07-04-google-drive-cloud-sync-design.md`

## Global Constraints

- 所有 Flutter／Dart 指令優先透過 `fvm`（`fvm flutter test` 等）；找不到 fvm 才退回 `flutter`／`dart`。
- 每個 task 的 commit 前置條件：`fvm dart format lib/ test/`（勿對 `.` 跑）、`fvm flutter analyze` 輸出 `No issues found!`、`fvm flutter test` 輸出 `All tests passed!`。
- Commit message 一律英文、conventional commits；**絕不 `git push`**。
- 所有新宣告（class／method／field／top-level，含 private）要有一行 `///` dartdoc；Flutter override（`build()` 等）不寫。
- UI 文字只改核心四 ARB：`lib/l10n/app_zh.arb`（template）、`app_zh_Hans.arb`、`app_en.arb`、`app_ja.arb`；其他 locale 由 Crowdin 補。改完跑 `fvm flutter gen-l10n`。
- 中文文案用全形標點，但省略號一律 ASCII `...`。
- Dialog 一律用 `AppDialog`（透過既有 `confirm_dialog.dart` helper）。
- Logger 樹：`cloudsync.auth`、`cloudsync.sync`；UID 過 `sanitizeUid`（`lib/services/log_sanitize.dart`）；**絕不記 token 內容**。
- 狀態管理一律 `NotifierProvider`（Riverpod 3.x，`StateProvider` 已棄用）。
- 分支：`feat/cloud-sync`（已存在，spec 已在上面）。

## File Structure

| 檔案 | 動作 | 職責 |
|------|------|------|
| `lib/services/cloud_sync/cloud_sync_config.dart` | Create | OAuth client id／secret 常數、scopes、雲端檔名、`isCloudSyncConfigured` |
| `lib/services/cloud_sync/token_store.dart` | Create | `TokenStore` 介面＋`SecureTokenStore`（flutter_secure_storage） |
| `lib/services/cloud_sync/google_auth_service.dart` | Create | 登入（loopback consent）、restore（refresh token 續期）、登出（revoke）、email 取得 |
| `lib/services/cloud_sync/cloud_sync_remote.dart` | Create | `CloudSyncRemote` 介面＋`DriveSyncRemote`（Drive v3 appDataFolder 單檔） |
| `lib/services/cloud_sync/cloud_sync_service.dart` | Create | `runSyncRound`（下載→合併→上傳）、`syncFingerprint`、pendingRemovals 剔除、schema 保護 |
| `lib/state/cloud_sync.dart` | Create | `CloudSyncNotifier`＋phase 狀態＋services providers＋debounce 觸發 |
| `lib/state/gacha_repository.dart` | Modify | 新增 `importBundleForCloudSync`（無 progress UI 的靜默匯入）＋`CloudSyncBusyException` |
| `lib/services/settings_storage.dart` | Modify | `AppSettings` 加 4 個 cloud 欄位＋`SettingsStorage` 讀寫 |
| `lib/state/settings.dart` | Modify | `SettingsNotifier` 加 cloud setter 群 |
| `lib/widgets/cards/cloud_sync_section.dart` | Create | 設定頁「雲端同步」區塊（公開 widget，比照 `AccountManagement`） |
| `lib/pages/settings_page.dart` | Modify | 插入雲端同步 `SectionCard` |
| `lib/widgets/dialogs/confirm_dialog.dart` | Modify | 打字確認 dialog 加選配 checkbox |
| `lib/widgets/cards/account_management.dart` | Modify | 刪帳號時「同時從雲端移除」勾選 |
| `lib/pages/app_shell.dart` | Modify | 啟動時 `cloudSyncProvider.notifier.start()` |
| ARB 四檔 | Modify | 新增 cloudSync* 字串 |

---

### Task 1: 新依賴與 cloud sync 設定欄位

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/services/settings_storage.dart`
- Modify: `lib/state/settings.dart`
- Test: `test/state/settings_cloud_sync_test.dart`

**Interfaces:**
- Consumes: 既有 `AppSettings`／`SettingsStorage`／`SettingsNotifier`。
- Produces（後續 task 依賴的確切簽名）:
  - `AppSettings.cloudAccountEmail: String?`（null = 未連結）
  - `AppSettings.cloudAutoSyncEnabled: bool`（預設 `true`）
  - `AppSettings.cloudLastSyncedAt: DateTime?`
  - `AppSettings.cloudPendingRemovals: List<String>`（預設 `const []`）
  - `SettingsNotifier.setCloudAccount(String email)`（設 email 並把 autoSync 重設為 true）
  - `SettingsNotifier.clearCloudAccount()`（清 email＋lastSyncedAt、autoSync 重設 true；**pendingRemovals 保留**）
  - `SettingsNotifier.setCloudAutoSyncEnabled(bool value)`
  - `SettingsNotifier.setCloudLastSyncedAt(DateTime at)`
  - `SettingsNotifier.addCloudPendingRemoval(String uid)`
  - `SettingsNotifier.removeCloudPendingRemovals(List<String> uids)`

- [ ] **Step 1: 加依賴**

```
fvm flutter pub add googleapis googleapis_auth flutter_secure_storage
```

Expected: `pubspec.yaml` dependencies 出現三個套件，`Got dependencies!`。

- [ ] **Step 2: 寫失敗測試**

建立 `test/state/settings_cloud_sync_test.dart`：

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/settings_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 建立已完成載入的 container。
  Future<ProviderContainer> makeContainer() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).waitForLoad();
    return container;
  }

  test('預設值：未連結、autoSync=true、無同步時間、無待移除', () async {
    final container = await makeContainer();
    final s = container.read(settingsProvider);
    expect(s.cloudAccountEmail, isNull);
    expect(s.cloudAutoSyncEnabled, isTrue);
    expect(s.cloudLastSyncedAt, isNull);
    expect(s.cloudPendingRemovals, isEmpty);
  });

  test('setCloudAccount 寫入 email 並重設 autoSync=true，持久化', () async {
    final container = await makeContainer();
    final n = container.read(settingsProvider.notifier);
    await n.setCloudAutoSyncEnabled(false);
    await n.setCloudAccount('user@example.com');

    expect(
      container.read(settingsProvider).cloudAccountEmail,
      'user@example.com',
    );
    expect(container.read(settingsProvider).cloudAutoSyncEnabled, isTrue);
    final reloaded = await SettingsStorage.load();
    expect(reloaded.cloudAccountEmail, 'user@example.com');
    expect(reloaded.cloudAutoSyncEnabled, isTrue);
  });

  test('clearCloudAccount 清 email 與 lastSyncedAt，保留 pendingRemovals', () async {
    final container = await makeContainer();
    final n = container.read(settingsProvider.notifier);
    await n.setCloudAccount('user@example.com');
    await n.setCloudLastSyncedAt(DateTime.utc(2026, 7, 4));
    await n.addCloudPendingRemoval('100000001');

    await n.clearCloudAccount();

    final s = container.read(settingsProvider);
    expect(s.cloudAccountEmail, isNull);
    expect(s.cloudLastSyncedAt, isNull);
    expect(s.cloudAutoSyncEnabled, isTrue);
    expect(s.cloudPendingRemovals, ['100000001']);
    final reloaded = await SettingsStorage.load();
    expect(reloaded.cloudAccountEmail, isNull);
    expect(reloaded.cloudPendingRemovals, ['100000001']);
  });

  test('setCloudLastSyncedAt 持久化為 UTC', () async {
    final container = await makeContainer();
    final n = container.read(settingsProvider.notifier);
    await n.setCloudLastSyncedAt(DateTime.utc(2026, 7, 4, 12, 30));

    final reloaded = await SettingsStorage.load();
    expect(reloaded.cloudLastSyncedAt, DateTime.utc(2026, 7, 4, 12, 30));
  });

  test('addCloudPendingRemoval 去重、removeCloudPendingRemovals 移除', () async {
    final container = await makeContainer();
    final n = container.read(settingsProvider.notifier);
    await n.addCloudPendingRemoval('A');
    await n.addCloudPendingRemoval('A');
    await n.addCloudPendingRemoval('B');
    expect(container.read(settingsProvider).cloudPendingRemovals, ['A', 'B']);

    await n.removeCloudPendingRemovals(['A']);
    expect(container.read(settingsProvider).cloudPendingRemovals, ['B']);
    final reloaded = await SettingsStorage.load();
    expect(reloaded.cloudPendingRemovals, ['B']);
  });

  test('pendingRemovals 損毀 JSON → 回空 list', () async {
    SharedPreferences.setMockInitialValues({
      'pref.cloudPendingRemovals': 'not-json',
    });
    final reloaded = await SettingsStorage.load();
    expect(reloaded.cloudPendingRemovals, isEmpty);
  });
}
```

- [ ] **Step 3: 跑測試確認失敗**

Run: `fvm flutter test test/state/settings_cloud_sync_test.dart`
Expected: 編譯失敗（`cloudAccountEmail` 等欄位不存在）。

- [ ] **Step 4: 實作 AppSettings 欄位**

`lib/services/settings_storage.dart` 的 `AppSettings`：

1. constructor 加參數（放在 `dataLanguageSeeded` 後）：

```dart
    this.cloudAccountEmail,
    this.cloudAutoSyncEnabled = true,
    this.cloudLastSyncedAt,
    this.cloudPendingRemovals = const [],
```

2. 欄位宣告（放在 `dataLanguageSeeded` 欄位後）：

```dart
  /// 已連結的 Google 帳號 email；null 代表未連結雲端同步。
  final String? cloudAccountEmail;

  /// 是否啟用自動雲端同步（App 啟動與資料變動後自動跑一輪）。
  final bool cloudAutoSyncEnabled;

  /// 上次雲端同步成功時間（UTC）；null 代表尚未同步過。
  final DateTime? cloudLastSyncedAt;

  /// 待從雲端移除的 UID 清單（刪帳號勾「連雲端一起刪」時排入，同步成功後清除）。
  final List<String> cloudPendingRemovals;
```

3. `copyWith` 加參數與對應行：

```dart
    String? cloudAccountEmail,
    bool clearCloudAccountEmail = false,
    bool? cloudAutoSyncEnabled,
    DateTime? cloudLastSyncedAt,
    bool clearCloudLastSyncedAt = false,
    List<String>? cloudPendingRemovals,
```

```dart
    cloudAccountEmail: clearCloudAccountEmail
        ? null
        : (cloudAccountEmail ?? this.cloudAccountEmail),
    cloudAutoSyncEnabled: cloudAutoSyncEnabled ?? this.cloudAutoSyncEnabled,
    cloudLastSyncedAt: clearCloudLastSyncedAt
        ? null
        : (cloudLastSyncedAt ?? this.cloudLastSyncedAt),
    cloudPendingRemovals: cloudPendingRemovals ?? this.cloudPendingRemovals,
```

4. `SettingsStorage` 加 key 常數：

```dart
  /// SharedPreferences key：已連結的雲端帳號 email。
  static const _kCloudAccountEmail = 'pref.cloudAccountEmail';

  /// SharedPreferences key：自動雲端同步開關。
  static const _kCloudAutoSyncEnabled = 'pref.cloudAutoSyncEnabled';

  /// SharedPreferences key：上次雲端同步成功時間（ISO8601 UTC）。
  static const _kCloudLastSyncedAt = 'pref.cloudLastSyncedAt';

  /// SharedPreferences key：待雲端移除 UID 清單 JSON。
  static const _kCloudPendingRemovals = 'pref.cloudPendingRemovals';
```

5. `load()` 回傳的 `AppSettings(...)` 加：

```dart
      cloudAccountEmail: prefs.getString(_kCloudAccountEmail),
      cloudAutoSyncEnabled: prefs.getBool(_kCloudAutoSyncEnabled) ?? true,
      cloudLastSyncedAt: _parseUtcTime(prefs.getString(_kCloudLastSyncedAt)),
      cloudPendingRemovals: _parseOrder(prefs.getString(_kCloudPendingRemovals)),
```

（`_parseOrder` 直接複用既有 helper——同樣是 string list JSON。）

6. `save()` 加：

```dart
    if (s.cloudAccountEmail == null) {
      await prefs.remove(_kCloudAccountEmail);
    } else {
      await prefs.setString(_kCloudAccountEmail, s.cloudAccountEmail!);
    }
    await prefs.setBool(_kCloudAutoSyncEnabled, s.cloudAutoSyncEnabled);
    if (s.cloudLastSyncedAt == null) {
      await prefs.remove(_kCloudLastSyncedAt);
    } else {
      await prefs.setString(
        _kCloudLastSyncedAt,
        s.cloudLastSyncedAt!.toUtc().toIso8601String(),
      );
    }
    await prefs.setString(
      _kCloudPendingRemovals,
      jsonEncode(s.cloudPendingRemovals),
    );
```

7. 新增 private helper（放 `_parseOrder` 後）：

```dart
  /// 解析 ISO8601 時間字串為 UTC DateTime，null 或格式錯誤回 null。
  static DateTime? _parseUtcTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }
```

- [ ] **Step 5: 實作 SettingsNotifier setter 群**

`lib/state/settings.dart` 的 `SettingsNotifier`（放在 `clearAllUidPreferences` 前）：

```dart
  /// 記錄已連結的雲端帳號 email，並把自動同步重設為預設開啟。
  Future<void> setCloudAccount(String email) async {
    state = state.copyWith(cloudAccountEmail: email, cloudAutoSyncEnabled: true);
    await SettingsStorage.save(state);
    Logger('cloudsync.auth').info('cloud account linked');
  }

  /// 清除雲端帳號連結（email、上次同步時間），autoSync 重設為 true。
  ///
  /// 待移除清單刻意**保留**：刪帳號的意圖在重新連結後仍應補刪。
  Future<void> clearCloudAccount() async {
    state = state.copyWith(
      clearCloudAccountEmail: true,
      clearCloudLastSyncedAt: true,
      cloudAutoSyncEnabled: true,
    );
    await SettingsStorage.save(state);
    Logger('cloudsync.auth').info('cloud account unlinked');
  }

  /// 切換自動雲端同步開關並持久化。
  Future<void> setCloudAutoSyncEnabled(bool value) async {
    state = state.copyWith(cloudAutoSyncEnabled: value);
    await SettingsStorage.save(state);
    Logger('cloudsync.sync').info('autoSync toggled=$value');
  }

  /// 記錄上次雲端同步成功時間並持久化。
  Future<void> setCloudLastSyncedAt(DateTime at) async {
    state = state.copyWith(cloudLastSyncedAt: at.toUtc());
    await SettingsStorage.save(state);
  }

  /// 把 [uid] 排入待雲端移除清單（去重）並持久化。
  Future<void> addCloudPendingRemoval(String uid) async {
    if (state.cloudPendingRemovals.contains(uid)) return;
    state = state.copyWith(
      cloudPendingRemovals: List.unmodifiable([
        ...state.cloudPendingRemovals,
        uid,
      ]),
    );
    await SettingsStorage.save(state);
  }

  /// 從待雲端移除清單移除 [uids]（同步成功後呼叫）並持久化。
  Future<void> removeCloudPendingRemovals(List<String> uids) async {
    if (uids.isEmpty) return;
    final remove = uids.toSet();
    state = state.copyWith(
      cloudPendingRemovals: List.unmodifiable(
        state.cloudPendingRemovals.where((u) => !remove.contains(u)),
      ),
    );
    await SettingsStorage.save(state);
  }
```

- [ ] **Step 6: 跑測試確認通過**

Run: `fvm flutter test test/state/settings_cloud_sync_test.dart`
Expected: All tests passed!

- [ ] **Step 7: 全套驗證＋commit**

```
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add pubspec.yaml pubspec.lock lib/services/settings_storage.dart lib/state/settings.dart test/state/settings_cloud_sync_test.dart
git commit -m "feat(cloud-sync): add deps and cloud sync settings fields"
```

---

### Task 2: OAuth 設定常數、TokenStore 與 GoogleAuthService

**Files:**
- Create: `lib/services/cloud_sync/cloud_sync_config.dart`
- Create: `lib/services/cloud_sync/token_store.dart`
- Create: `lib/services/cloud_sync/google_auth_service.dart`
- Test: `test/services/cloud_sync/google_auth_service_test.dart`

**Interfaces:**
- Consumes: 無（僅外部套件）。
- Produces:
  - `isCloudSyncConfigured: bool`（getter）、`cloudSyncFileName: String`、`cloudSyncScopes: List<String>`
  - `abstract class TokenStore { Future<String?> readRefreshToken(); Future<void> writeRefreshToken(String token); Future<void> deleteRefreshToken(); }`
  - `class SecureTokenStore implements TokenStore`
  - `class CloudReauthRequiredException implements Exception`
  - `class CloudAuthSession { final AuthClient client; final String email; }`
  - `class GoogleAuthService { Future<CloudAuthSession> signIn(void Function(String url) openUrl); Future<AuthClient?> restore(); Future<void> signOut(); }`（方法皆 virtual，測試可 subclass override）
  - top-level `bool isInvalidGrant(Object e)`、`AccessCredentials buildResumeCredentials(String refreshToken)`

- [ ] **Step 1: 寫失敗測試（純邏輯部分）**

建立 `test/services/cloud_sync/google_auth_service_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_auth_service.dart';

void main() {
  group('isInvalidGrant', () {
    test('訊息含 invalid_grant → true', () {
      expect(isInvalidGrant(Exception('Refresh failed: invalid_grant')), isTrue);
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
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/cloud_sync/google_auth_service_test.dart`
Expected: 編譯失敗（檔案不存在）。

- [ ] **Step 3: 建立 cloud_sync_config.dart**

```dart
/// Google Cloud Console「Desktop app」OAuth 用戶端 ID。
///
/// Installed app 的 client id／secret 依 Google 官方定義不視為機密
/// （必然可自使用者端取出），直接寫在原始碼供任何人 clone 即建置可用。
/// 空字串代表此建置未設定，雲端同步功能整體停用（見 [isCloudSyncConfigured]）。
const String cloudSyncClientId = '';

/// Google OAuth 用戶端 secret（Desktop app 類型，非機密，見 [cloudSyncClientId]）。
const String cloudSyncClientSecret = '';

/// 雲端同步是否已設定 OAuth 憑證；false 時設定頁顯示未設定提示、所有同步入口 no-op。
bool get isCloudSyncConfigured =>
    cloudSyncClientId.isNotEmpty && cloudSyncClientSecret.isNotEmpty;

/// Google Drive appDataFolder 內的同步檔名，內容即 AccountsBundle JSON。
const String cloudSyncFileName = 'wuwa_convene_sync.json';

/// 要求的 OAuth scopes：appDataFolder 最小權限＋email（設定頁顯示已連結帳號）。
const List<String> cloudSyncScopes = [
  'https://www.googleapis.com/auth/drive.appdata',
  'email',
];
```

- [ ] **Step 4: 建立 token_store.dart**

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// refresh token 的安全儲存介面；抽象化以便測試注入 in-memory 實作。
abstract class TokenStore {
  /// 讀取已存的 refresh token；無則回 null。
  Future<String?> readRefreshToken();

  /// 寫入 refresh token。
  Future<void> writeRefreshToken(String token);

  /// 刪除已存的 refresh token。
  Future<void> deleteRefreshToken();
}

/// 以 flutter_secure_storage（Windows 底層 DPAPI）實作的 [TokenStore]。
class SecureTokenStore implements TokenStore {
  /// 底層安全儲存。
  static const _storage = FlutterSecureStorage();

  /// refresh token 的儲存 key。
  static const _kRefreshToken = 'cloudsync.refreshToken';

  @override
  Future<String?> readRefreshToken() => _storage.read(key: _kRefreshToken);

  @override
  Future<void> writeRefreshToken(String token) =>
      _storage.write(key: _kRefreshToken, value: token);

  @override
  Future<void> deleteRefreshToken() => _storage.delete(key: _kRefreshToken);
}
```

- [ ] **Step 5: 建立 google_auth_service.dart**

```dart
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

  @override
  AccessCredentials get credentials => _inner.credentials;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

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
  GoogleAuthService({required this.tokenStore, required this.baseClientFactory});

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
        await base.post(
          Uri.parse('https://oauth2.googleapis.com/revoke'),
          body: {'token': refresh},
        );
        _log.info('revoke ok');
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
```

> 注意：`signIn`／`restore`／`signOut` 是外部套件的 thin wrapper，單元測試只覆蓋純邏輯（`isInvalidGrant`、`buildResumeCredentials`）；真實 OAuth 流程於 Task 9 手動驗證。若 `clientViaUserConsent`／`refreshCredentials`／`autoRefreshingClient` 的實際簽名與此處不符（以裝好的 googleapis_auth 版本為準），依套件原始碼調整呼叫方式，介面（`signIn`/`restore`/`signOut`）不變。

- [ ] **Step 6: 跑測試確認通過**

Run: `fvm flutter test test/services/cloud_sync/google_auth_service_test.dart`
Expected: All tests passed!

- [ ] **Step 7: 全套驗證＋commit**

```
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/services/cloud_sync/ test/services/cloud_sync/
git commit -m "feat(cloud-sync): add OAuth config, token store and Google auth service"
```

---

### Task 3: CloudSyncRemote 介面與 DriveSyncRemote

**Files:**
- Create: `lib/services/cloud_sync/cloud_sync_remote.dart`
- Test: `test/services/cloud_sync/drive_sync_remote_test.dart`

**Interfaces:**
- Consumes: `cloudSyncFileName`（Task 2）。
- Produces:
  - `abstract class CloudSyncRemote { Future<String?> download(); Future<void> upload(String json); }`
  - `class DriveSyncRemote implements CloudSyncRemote { DriveSyncRemote(http.Client client); }`

- [ ] **Step 1: 寫失敗測試**

建立 `test/services/cloud_sync/drive_sync_remote_test.dart`（用 `MockClient` 模擬 Drive REST）：

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_remote.dart';

/// 回傳 JSON 200 回應。
http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('download：雲端無檔 → null', () async {
    final client = MockClient((req) async {
      expect(req.url.path, '/drive/v3/files');
      return _json({'files': <Object>[]});
    });
    final remote = DriveSyncRemote(client);
    expect(await remote.download(), isNull);
  });

  test('download：有檔 → 回傳內容', () async {
    final client = MockClient((req) async {
      if (req.url.queryParameters['alt'] == 'media') {
        return http.Response('{"hello":1}', 200);
      }
      return _json({
        'files': [
          {'id': 'file-1'},
        ],
      });
    });
    final remote = DriveSyncRemote(client);
    expect(await remote.download(), '{"hello":1}');
  });

  test('upload：雲端無檔 → 走 create（POST /upload）', () async {
    final calls = <String>[];
    final client = MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      if (req.url.path == '/drive/v3/files') return _json({'files': <Object>[]});
      return _json({'id': 'new-file'});
    });
    final remote = DriveSyncRemote(client);
    await remote.upload('{"a":1}');
    expect(calls.any((c) => c.startsWith('POST /upload/drive/v3/files')), isTrue);
  });

  test('upload：雲端已有檔 → 走 update（PATCH /upload/.../file-1）', () async {
    final calls = <String>[];
    final client = MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      if (req.url.path == '/drive/v3/files') {
        return _json({
          'files': [
            {'id': 'file-1'},
          ],
        });
      }
      return _json({'id': 'file-1'});
    });
    final remote = DriveSyncRemote(client);
    await remote.upload('{"a":1}');
    expect(
      calls.any((c) => c.startsWith('PATCH /upload/drive/v3/files/file-1')),
      isTrue,
    );
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/cloud_sync/drive_sync_remote_test.dart`
Expected: 編譯失敗（檔案不存在）。

- [ ] **Step 3: 實作 cloud_sync_remote.dart**

```dart
import 'dart:convert';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';

/// 雲端同步檔的遠端存取介面；抽象化以便測試注入 fake。
abstract class CloudSyncRemote {
  /// 下載同步檔內容；檔案不存在回 null。
  Future<String?> download();

  /// 上傳（覆蓋）同步檔內容。
  Future<void> upload(String json);
}

/// 以 Google Drive v3 appDataFolder 實作的 [CloudSyncRemote]，單一檔案
/// [cloudSyncFileName]。
class DriveSyncRemote implements CloudSyncRemote {
  /// 建立 [DriveSyncRemote]，[client] 需為已授權的 HTTP client。
  DriveSyncRemote(http.Client client) : _api = drive.DriveApi(client);

  /// Drive v3 API 入口。
  final drive.DriveApi _api;

  /// Logger 實例（同步遠端存取）。
  static final _log = Logger('cloudsync.sync');

  /// 查找 appDataFolder 內同步檔的 file id；不存在回 null。
  Future<String?> _findFileId() async {
    final list = await _api.files.list(
      spaces: 'appDataFolder',
      q: "name = '$cloudSyncFileName'",
      $fields: 'files(id)',
    );
    final files = list.files;
    if (files == null || files.isEmpty) return null;
    return files.first.id;
  }

  @override
  Future<String?> download() async {
    final id = await _findFileId();
    if (id == null) {
      _log.info('download: no remote file');
      return null;
    }
    final media =
        await _api.files.get(id, downloadOptions: drive.DownloadOptions.fullMedia)
            as drive.Media;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in media.stream) {
      bytes.add(chunk);
    }
    _log.info('download: ${bytes.length} bytes');
    return utf8.decode(bytes.takeBytes());
  }

  @override
  Future<void> upload(String json) async {
    final data = utf8.encode(json);
    final media = drive.Media(Stream.value(data), data.length);
    final id = await _findFileId();
    if (id == null) {
      await _api.files.create(
        drive.File()
          ..name = cloudSyncFileName
          ..parents = ['appDataFolder'],
        uploadMedia: media,
      );
      _log.info('upload: created, ${data.length} bytes');
    } else {
      await _api.files.update(drive.File(), id, uploadMedia: media);
      _log.info('upload: updated, ${data.length} bytes');
    }
  }
}
```

（`BytesBuilder` 來自 `dart:typed_data`，若 analyzer 報未定義，加 `import 'dart:typed_data';`。）

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/services/cloud_sync/drive_sync_remote_test.dart`
Expected: All tests passed!（若 googleapis 實際 REST 路徑與 mock 斷言不符，以測試失敗訊息中的真實 method／path 修正**測試**斷言，實作不變。）

- [ ] **Step 5: 全套驗證＋commit**

```
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/services/cloud_sync/cloud_sync_remote.dart test/services/cloud_sync/drive_sync_remote_test.dart
git commit -m "feat(cloud-sync): add Drive appDataFolder remote store"
```

---

### Task 4: 同步編排 runSyncRound 與 syncFingerprint

**Files:**
- Create: `lib/services/cloud_sync/cloud_sync_service.dart`
- Test: `test/services/cloud_sync/cloud_sync_service_test.dart`

**Interfaces:**
- Consumes: `CloudSyncRemote`（Task 3）、`importAccounts`／`AccountsBundle`／`UnsupportedSchemaVersionException`／`ForeignBundleException`（既有）。
- Produces:
  - `String syncFingerprint(String bundleJson)`——去除 `exported_at` 後的 SHA-256。
  - `sealed class CloudSyncOutcome`；`class CloudSyncSuccess extends CloudSyncOutcome { final String uploadedFingerprint; }`；`class CloudSyncSkippedSchemaTooNew extends CloudSyncOutcome`
  - `Future<CloudSyncOutcome> runSyncRound({ required CloudSyncRemote remote, required List<String> pendingRemovals, required Future<void> Function(AccountsBundle bundle) applyRemote, required String Function() exportLocal, required Future<void> Function(List<String> uids) clearPendingRemovals })`

**同步一輪的規則（測試即規格）：**
1. 雲端無檔 → 不合併，直接上傳本機。
2. 雲端有檔 → 解析＋剔除 pendingRemovals → `applyRemote` 合併 → 上傳本機 → 清 pendingRemovals。
3. 雲端 schema 過新 → 回 `CloudSyncSkippedSchemaTooNew`，**不合併、不上傳、不清 pendingRemovals**。
4. 雲端檔損毀（FormatException／ForeignBundle）→ 視為無檔（log severe），上傳本機自癒。
5. 剔除後帳號為空 → 跳過 `applyRemote`，仍上傳。

- [ ] **Step 1: 寫失敗測試**

建立 `test/services/cloud_sync/cloud_sync_service_test.dart`：

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_remote.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_service.dart';

/// 記錄呼叫的 fake 遠端。
class _FakeRemote implements CloudSyncRemote {
  _FakeRemote({this.content});

  /// 目前雲端檔內容；null = 不存在。
  String? content;

  /// upload 被呼叫的次數。
  int uploads = 0;

  @override
  Future<String?> download() async => content;

  @override
  Future<void> upload(String json) async {
    uploads++;
    content = json;
  }
}

/// 產生單帳號的 bundle JSON（schema v2、正確 app id）。
String _bundleJson({List<String> uids = const ['100000001'], int? schema}) =>
    jsonEncode({
      'schema_version': schema ?? AccountsBundle.currentSchemaVersion,
      'app': accountsBundleAppId,
      'exported_at': '2026-07-04T00:00:00.000Z',
      'app_version': '1.5.0',
      'last_active_uid': uids.first,
      'accounts': [
        for (final uid in uids)
          {
            'player_id': uid,
            'language_code': 'zh-Hant',
            'last_updated': '2026-07-01T00:00:00.000Z',
            'banners': {'1': <Object>[]},
          },
      ],
    });

/// 本機匯出內容（固定字串即可，內容真實性由整合層測試保證）。
String _localJson() => _bundleJson(uids: ['200000002']);

void main() {
  group('syncFingerprint', () {
    test('僅 exported_at 不同 → 指紋相同', () {
      final a = jsonDecode(_bundleJson()) as Map<String, dynamic>;
      final b = jsonDecode(_bundleJson()) as Map<String, dynamic>;
      b['exported_at'] = '2030-01-01T00:00:00.000Z';
      expect(syncFingerprint(jsonEncode(a)), syncFingerprint(jsonEncode(b)));
    });

    test('帳號內容不同 → 指紋不同', () {
      expect(
        syncFingerprint(_bundleJson(uids: ['A'])),
        isNot(syncFingerprint(_bundleJson(uids: ['B']))),
      );
    });
  });

  group('runSyncRound', () {
    test('雲端無檔 → 不合併、直接上傳本機', () async {
      final remote = _FakeRemote();
      var applied = false;
      final outcome = await runSyncRound(
        remote: remote,
        pendingRemovals: const [],
        applyRemote: (_) async => applied = true,
        exportLocal: _localJson,
        clearPendingRemovals: (_) async {},
      );
      expect(applied, isFalse);
      expect(remote.uploads, 1);
      expect(remote.content, _localJson());
      expect(outcome, isA<CloudSyncSuccess>());
      expect(
        (outcome as CloudSyncSuccess).uploadedFingerprint,
        syncFingerprint(_localJson()),
      );
    });

    test('雲端有檔 → 合併後上傳、清 pendingRemovals', () async {
      final remote = _FakeRemote(content: _bundleJson(uids: ['100000001']));
      AccountsBundle? appliedBundle;
      List<String>? cleared;
      await runSyncRound(
        remote: remote,
        pendingRemovals: const ['999'],
        applyRemote: (b) async => appliedBundle = b,
        exportLocal: _localJson,
        clearPendingRemovals: (uids) async => cleared = uids,
      );
      expect(appliedBundle, isNotNull);
      expect(appliedBundle!.accounts.single.data.playerId, '100000001');
      expect(remote.uploads, 1);
      expect(cleared, ['999']);
    });

    test('pendingRemovals 剔除雲端帳號，避免剛刪的帳號復活', () async {
      final remote = _FakeRemote(
        content: _bundleJson(uids: ['100000001', '100000002']),
      );
      AccountsBundle? appliedBundle;
      await runSyncRound(
        remote: remote,
        pendingRemovals: const ['100000001'],
        applyRemote: (b) async => appliedBundle = b,
        exportLocal: _localJson,
        clearPendingRemovals: (_) async {},
      );
      expect(
        appliedBundle!.accounts.map((a) => a.data.playerId),
        ['100000002'],
      );
    });

    test('剔除後帳號為空 → 跳過 applyRemote、仍上傳', () async {
      final remote = _FakeRemote(content: _bundleJson(uids: ['100000001']));
      var applied = false;
      await runSyncRound(
        remote: remote,
        pendingRemovals: const ['100000001'],
        applyRemote: (_) async => applied = true,
        exportLocal: _localJson,
        clearPendingRemovals: (_) async {},
      );
      expect(applied, isFalse);
      expect(remote.uploads, 1);
    });

    test('雲端 schema 過新 → 跳過整輪：不合併、不上傳、不清 pendingRemovals', () async {
      final remote = _FakeRemote(
        content: _bundleJson(schema: AccountsBundle.currentSchemaVersion + 1),
      );
      var applied = false;
      var cleared = false;
      final outcome = await runSyncRound(
        remote: remote,
        pendingRemovals: const ['999'],
        applyRemote: (_) async => applied = true,
        exportLocal: _localJson,
        clearPendingRemovals: (_) async => cleared = true,
      );
      expect(outcome, isA<CloudSyncSkippedSchemaTooNew>());
      expect(applied, isFalse);
      expect(remote.uploads, 0);
      expect(cleared, isFalse);
    });

    test('雲端檔損毀 → 視為無檔，上傳本機自癒', () async {
      final remote = _FakeRemote(content: 'not-json{{{');
      var applied = false;
      final outcome = await runSyncRound(
        remote: remote,
        pendingRemovals: const [],
        applyRemote: (_) async => applied = true,
        exportLocal: _localJson,
        clearPendingRemovals: (_) async {},
      );
      expect(applied, isFalse);
      expect(remote.uploads, 1);
      expect(outcome, isA<CloudSyncSuccess>());
    });
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/cloud_sync/cloud_sync_service_test.dart`
Expected: 編譯失敗（檔案不存在）。

- [ ] **Step 3: 實作 cloud_sync_service.dart**

```dart
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/accounts_import.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_remote.dart';

/// Logger 實例（同步編排）。
final _log = Logger('cloudsync.sync');

/// 計算 bundle JSON 的同步指紋：去除 `exported_at` 後的 SHA-256。
///
/// 用於「本機資料變動」觸發的跳過判斷——內容沒變（只有匯出時間戳會變）就不再跑一輪。
String syncFingerprint(String bundleJson) {
  final map = Map<String, dynamic>.from(
    jsonDecode(bundleJson) as Map<String, dynamic>,
  )..remove('exported_at');
  return sha256.convert(utf8.encode(jsonEncode(map))).toString();
}

/// 一輪同步的結果。
sealed class CloudSyncOutcome {
  /// 建立 [CloudSyncOutcome]。
  const CloudSyncOutcome();
}

/// 同步成功：已上傳本機資料。
class CloudSyncSuccess extends CloudSyncOutcome {
  /// 建立 [CloudSyncSuccess]。
  const CloudSyncSuccess({required this.uploadedFingerprint});

  /// 已上傳內容的 [syncFingerprint]，供後續變動觸發的跳過判斷。
  final String uploadedFingerprint;
}

/// 雲端檔 schema 比本機支援的新，整輪跳過（不合併、不上傳），提示使用者更新 App。
class CloudSyncSkippedSchemaTooNew extends CloudSyncOutcome {
  /// 建立 [CloudSyncSkippedSchemaTooNew]。
  const CloudSyncSkippedSchemaTooNew();
}

/// 執行一輪「下載 → 合併 → 上傳」同步。
///
/// - [pendingRemovals] 內的 UID 會先從下載的雲端 bundle 剔除（防止剛刪的帳號
///   被合併復活），上傳成功後經 [clearPendingRemovals] 清除。
/// - 雲端檔損毀（非 JSON／外來檔）視為不存在，直接以本機內容上傳自癒。
/// - [applyRemote] 拋出的例外（如更新進行中）原樣往外傳，由呼叫端重排。
Future<CloudSyncOutcome> runSyncRound({
  required CloudSyncRemote remote,
  required List<String> pendingRemovals,
  required Future<void> Function(AccountsBundle bundle) applyRemote,
  required String Function() exportLocal,
  required Future<void> Function(List<String> uids) clearPendingRemovals,
}) async {
  final sw = Stopwatch()..start();
  final remoteJson = await remote.download();

  if (remoteJson != null) {
    AccountsBundle? bundle;
    try {
      bundle = importAccounts(remoteJson);
    } on UnsupportedSchemaVersionException catch (e) {
      _log.warning('skip round: remote schema v${e.version} too new');
      return const CloudSyncSkippedSchemaTooNew();
    } on FormatException catch (e) {
      _log.severe('remote file corrupt (treated as absent): ${e.message}');
    } on ForeignBundleException {
      _log.severe('remote file foreign (treated as absent)');
    }
    if (bundle != null) {
      final filtered = _withoutUids(bundle, pendingRemovals.toSet());
      if (filtered.accounts.isNotEmpty) {
        await applyRemote(filtered);
      } else {
        _log.info('merge skipped: remote has no applicable accounts');
      }
    }
  }

  final localJson = exportLocal();
  await remote.upload(localJson);
  await clearPendingRemovals(pendingRemovals);
  _log.info(
    'round done in ${sw.elapsedMilliseconds}ms, '
    'remote=${remoteJson?.length ?? 0}B uploaded=${localJson.length}B '
    'pendingRemovalsCleared=${pendingRemovals.length}',
  );
  return CloudSyncSuccess(uploadedFingerprint: syncFingerprint(localJson));
}

/// 回傳剔除 [uids] 帳號後的新 bundle（其餘欄位不變）。
AccountsBundle _withoutUids(AccountsBundle bundle, Set<String> uids) {
  if (uids.isEmpty) return bundle;
  return AccountsBundle(
    exportedAt: bundle.exportedAt,
    appVersion: bundle.appVersion,
    lastActiveUid: bundle.lastActiveUid,
    accounts: bundle.accounts
        .where((a) => !uids.contains(a.data.playerId))
        .toList(growable: false),
  );
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/services/cloud_sync/cloud_sync_service_test.dart`
Expected: All tests passed!

- [ ] **Step 5: 全套驗證＋commit**

```
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/services/cloud_sync/cloud_sync_service.dart test/services/cloud_sync/cloud_sync_service_test.dart
git commit -m "feat(cloud-sync): add sync round orchestration and fingerprint"
```

---

### Task 5: GachaRepository 靜默匯入入口

**Files:**
- Modify: `lib/state/gacha_repository.dart`
- Test: `test/state/gacha_repository_cloud_import_test.dart`

**Interfaces:**
- Consumes: 既有 private `_runImport(AccountsBundle)`（合併寫入＋偏好整併，不動 progress UI）。
- Produces:
  - `class CloudSyncBusyException implements Exception`（定義於 `gacha_repository.dart`）
  - `GachaRepository.importBundleForCloudSync(AccountsBundle bundle) → Future<ImportResult>`——不啟動 progress／不抓物品圖片；有更新或匯入進行中時拋 `CloudSyncBusyException`。

> 已知取捨（spec §3）：雲端合併進來的新紀錄不觸發物品圖片下載，圖示先顯示既有的 missing-icon placeholder，下次「更新」或手動匯入時補齊。

- [ ] **Step 1: 寫失敗測試**

建立 `test/state/gacha_repository_cloud_import_test.dart`（fake 樣板抄自 `test/state/gacha_repository_test.dart`）：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';

/// 不會被觸發的 fake capture。
class _FakeCapture implements GachaCapture {
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(null), cancel: () async {});
}

/// 單帳號 bundle（1 筆五星紀錄）。
AccountsBundle _bundle(String uid) => AccountsBundle.fromJson(
  jsonDecode(
        jsonEncode({
          'schema_version': AccountsBundle.currentSchemaVersion,
          'app': accountsBundleAppId,
          'exported_at': '2026-07-04T00:00:00.000Z',
          'app_version': '1.5.0',
          'last_active_uid': uid,
          'accounts': [
            {
              'player_id': uid,
              'language_code': 'zh-Hant',
              'last_updated': '2026-07-01T00:00:00.000Z',
              'banners': {
                '1': [
                  {
                    'card_pool_type': 1,
                    'resource_id': 21050016,
                    'quality_level': 5,
                    'resource_type': '武器',
                    'name': '測試武器',
                    'count': 1,
                    'time': '2026-06-30 12:00:00',
                    'language_code': 'zh-Hant',
                  },
                ],
              },
            },
          ],
        }),
      )
      as Map<String, dynamic>,
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cloud_import_test_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
        gachaCaptureProvider.overrideWithValue(_FakeCapture()),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('', 500)),
            cancel: () {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('importBundleForCloudSync 合併進本機且不啟動 progress', () async {
    final container = makeContainer();
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();

    final result = await repo.importBundleForCloudSync(_bundle('100000001'));

    expect(result.successAccounts, 1);
    expect(result.addedRecords, 1);
    final state = container.read(gachaRepositoryProvider);
    expect(state.byUid.keys, contains('100000001'));
    expect(state.progress, isNull);
  });

  test('重複匯入同 bundle → 全數 duplicate', () async {
    final container = makeContainer();
    final repo = container.read(gachaRepositoryProvider.notifier);
    await repo.waitForBootstrap();

    await repo.importBundleForCloudSync(_bundle('100000001'));
    final second = await repo.importBundleForCloudSync(_bundle('100000001'));

    expect(second.addedRecords, 0);
    expect(second.duplicateRecords, 1);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/state/gacha_repository_cloud_import_test.dart`
Expected: 編譯失敗（`importBundleForCloudSync` 不存在）。

- [ ] **Step 3: 實作**

`lib/state/gacha_repository.dart`：

1. 在 `_AllPoolsFailedException` 附近（top-level）加：

```dart
/// 雲端同步請求匯入時，已有更新或匯入進行中而無法執行時拋出；呼叫端應稍後重試。
class CloudSyncBusyException implements Exception {
  /// 建立 [CloudSyncBusyException]。
  const CloudSyncBusyException();

  @override
  String toString() => 'CloudSyncBusyException';
}
```

2. 在 `importAccountsAndFetchItemImages` 方法後加：

```dart
  /// 雲端同步專用的靜默匯入：純資料合併（寫入 storage＋整併偏好），
  /// 不啟動 progress UI、不抓物品圖片。
  ///
  /// 已有更新或匯入進行中時拋 [CloudSyncBusyException]，由雲端同步層重排。
  Future<ImportResult> importBundleForCloudSync(AccountsBundle bundle) async {
    if (state.progress != null || _isUpdating) {
      _importLog.info('cloud sync import rejected: busy');
      throw const CloudSyncBusyException();
    }
    _isUpdating = true;
    try {
      _importLog.info('cloud sync import start, accounts=${bundle.accounts.length}');
      return await _runImport(bundle);
    } finally {
      _isUpdating = false;
    }
  }
```

（若 `_isUpdating` 欄位名不同，以檔內 `importAccountsAndFetchItemImages` 開頭互斥檢查用的實際欄位為準，兩處保持一致。）

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/state/gacha_repository_cloud_import_test.dart`
Expected: All tests passed!（若 `_bundle` 內 record JSON 欄位與 `GachaRecord.fromStorageJson` 實際 schema 不符導致解析失敗，打開 `lib/models/gacha_record.dart` 對齊欄位名，只改測試 fixture。）

- [ ] **Step 5: 全套驗證＋commit**

```
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/state/gacha_repository.dart test/state/gacha_repository_cloud_import_test.dart
git commit -m "feat(cloud-sync): add silent bundle import entry to GachaRepository"
```

---

### Task 6: CloudSyncNotifier 狀態機

**Files:**
- Create: `lib/state/cloud_sync.dart`
- Test: `test/state/cloud_sync_test.dart`

**Interfaces:**
- Consumes: Task 1–5 全部產出＋`exportAccounts`／`appVersionProvider`／`settingsProvider`／`gachaRepositoryProvider`。
- Produces:
  - `enum CloudSyncPhase { idle, awaitingConsent, syncing, error, reauthRequired }`
  - `class CloudSyncState { final CloudSyncPhase phase; final String? errorToken; }`（errorToken ∈ `'network'`｜`'busy'`｜`'schemaTooNew'`｜`'authFailed'`）
  - `final cloudSyncProvider = NotifierProvider<CloudSyncNotifier, CloudSyncState>(...)`
  - `CloudSyncNotifier` 方法：`start()`、`link()`、`cancelLink()`、`unlink()`、`syncNow({required bool manual})`、`queueCloudRemoval(String uid)`
  - Providers：`tokenStoreProvider`、`googleAuthServiceProvider`、`cloudSyncRemoteFactoryProvider`（`CloudSyncRemote Function(http.Client)`）、`cloudSyncUrlOpenerProvider`（`void Function(String url)`）
  - UI 的「是否已連結／email／開關／上次同步時間」一律直接 watch `settingsProvider`，不在 CloudSyncState 重複持有。

- [ ] **Step 1: 寫失敗測試**

建立 `test/state/cloud_sync_test.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_remote.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_auth_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/token_store.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/cloud_sync.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';

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
class _FakeAuthClient extends http.BaseClient implements AuthClient {
  @override
  AccessCredentials get credentials => throw UnimplementedError();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();
}

/// 可程式化行為的 fake 授權服務。
class _FakeAuthService extends GoogleAuthService {
  _FakeAuthService(this.store)
    : super(tokenStore: store, baseClientFactory: http.Client.new);

  /// 供斷言的 token store。
  final InMemoryTokenStore store;

  /// restore 是否要拋 invalid_grant。
  bool restoreThrowsReauth = false;

  @override
  Future<CloudAuthSession> signIn(void Function(String url) openUrl) async {
    openUrl('https://accounts.google.com/consent');
    await store.writeRefreshToken('refresh-1');
    return CloudAuthSession(client: _FakeAuthClient(), email: 'u@example.com');
  }

  @override
  Future<AuthClient?> restore() async {
    if (restoreThrowsReauth) throw const CloudReauthRequiredException();
    if (store.token == null) return null;
    return _FakeAuthClient();
  }

  @override
  Future<void> signOut() async => store.deleteRefreshToken();
}

/// 記錄呼叫的 fake 遠端。
class _FakeRemote implements CloudSyncRemote {
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
class _FakeCapture implements GachaCapture {
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(null), cancel: () async {});
}

/// 產生雲端側 bundle JSON。
String _cloudBundleJson(String uid) => jsonEncode({
  'schema_version': AccountsBundle.currentSchemaVersion,
  'app': accountsBundleAppId,
  'exported_at': '2026-07-04T00:00:00.000Z',
  'app_version': '1.5.0',
  'last_active_uid': uid,
  'accounts': [
    {
      'player_id': uid,
      'language_code': 'zh-Hant',
      'last_updated': '2026-07-01T00:00:00.000Z',
      'banners': {'1': <Object>[]},
    },
  ],
});

void main() {
  late Directory tempDir;
  late InMemoryTokenStore tokenStore;
  late _FakeAuthService authService;
  late _FakeRemote remote;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cloud_sync_test_');
    SharedPreferences.setMockInitialValues({});
    tokenStore = InMemoryTokenStore();
    authService = _FakeAuthService(tokenStore);
    remote = _FakeRemote();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        appVersionProvider.overrideWithValue('1.5.0'),
        gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
        gachaCaptureProvider.overrideWithValue(_FakeCapture()),
        cancellableHttpClientFactoryProvider.overrideWithValue(
          () => CancellableHttpClient(
            client: MockClient((_) async => http.Response('', 500)),
            cancel: () {},
          ),
        ),
        tokenStoreProvider.overrideWithValue(tokenStore),
        googleAuthServiceProvider.overrideWithValue(authService),
        cloudSyncRemoteFactoryProvider.overrideWithValue((_) => remote),
        cloudSyncUrlOpenerProvider.overrideWithValue((_) {}),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('link 成功 → 寫 email、存 token、跑第一輪同步', () async {
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    await container.read(cloudSyncProvider.notifier).link();

    expect(
      container.read(settingsProvider).cloudAccountEmail,
      'u@example.com',
    );
    expect(tokenStore.token, 'refresh-1');
    expect(remote.uploads, 1);
    expect(container.read(settingsProvider).cloudLastSyncedAt, isNotNull);
    expect(container.read(cloudSyncProvider).phase, CloudSyncPhase.idle);
  });

  test('syncNow 把雲端帳號合併進本機並上傳', () async {
    remote.content = _cloudBundleJson('100000001');
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    await container.read(cloudSyncProvider.notifier).link();

    expect(
      container.read(gachaRepositoryProvider).byUid.keys,
      contains('100000001'),
    );
    final uploaded =
        jsonDecode(remote.content!) as Map<String, dynamic>;
    final uids = (uploaded['accounts'] as List)
        .map((a) => (a as Map<String, dynamic>)['player_id'])
        .toList();
    expect(uids, contains('100000001'));
  });

  test('雲端 schema 過新 → error(schemaTooNew)、不上傳', () async {
    final map =
        jsonDecode(_cloudBundleJson('100000001')) as Map<String, dynamic>;
    map['schema_version'] = AccountsBundle.currentSchemaVersion + 1;
    remote.content = jsonEncode(map);
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    await container.read(cloudSyncProvider.notifier).link();

    final s = container.read(cloudSyncProvider);
    expect(s.phase, CloudSyncPhase.error);
    expect(s.errorToken, 'schemaTooNew');
    expect(remote.uploads, 0);
  });

  test('start：token 失效 → reauthRequired、不跑同步', () async {
    SharedPreferences.setMockInitialValues({
      'pref.cloudAccountEmail': 'u@example.com',
    });
    authService.restoreThrowsReauth = true;
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();

    await container.read(cloudSyncProvider.notifier).start();

    expect(
      container.read(cloudSyncProvider).phase,
      CloudSyncPhase.reauthRequired,
    );
    expect(remote.uploads, 0);
  });

  test('unlink → 清 email、刪 token、雲端檔保留', () async {
    remote.content = _cloudBundleJson('100000001');
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    await container.read(cloudSyncProvider.notifier).link();

    await container.read(cloudSyncProvider.notifier).unlink();

    expect(container.read(settingsProvider).cloudAccountEmail, isNull);
    expect(tokenStore.token, isNull);
    expect(remote.content, isNotNull);
  });

  test('queueCloudRemoval → 上傳內容剔除該 UID、清 pendingRemovals', () async {
    remote.content = _cloudBundleJson('100000001');
    final container = makeContainer();
    await container.read(settingsProvider.notifier).waitForLoad();
    await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    await container.read(cloudSyncProvider.notifier).link();
    // 模擬本機已刪：直接從 repo 移除
    await container
        .read(gachaRepositoryProvider.notifier)
        .removeUid('100000001');

    await container
        .read(cloudSyncProvider.notifier)
        .queueCloudRemoval('100000001');

    final uploaded = jsonDecode(remote.content!) as Map<String, dynamic>;
    final uids = (uploaded['accounts'] as List)
        .map((a) => (a as Map<String, dynamic>)['player_id'])
        .toList();
    expect(uids, isNot(contains('100000001')));
    expect(container.read(settingsProvider).cloudPendingRemovals, isEmpty);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/state/cloud_sync_test.dart`
Expected: 編譯失敗（`lib/state/cloud_sync.dart` 不存在）。

- [ ] **Step 3: 實作 lib/state/cloud_sync.dart**

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/accounts_export.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_remote.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_auth_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/token_store.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';

/// 雲端同步的即時狀態。
enum CloudSyncPhase {
  /// 閒置（未連結時也是此狀態，連結與否由 settings 的 email 判斷）。
  idle,

  /// 等待使用者在瀏覽器完成授權。
  awaitingConsent,

  /// 同步進行中。
  syncing,

  /// 最近一輪同步失敗（原因見 [CloudSyncState.errorToken]）。
  error,

  /// refresh token 已失效，需要重新連結。
  reauthRequired,
}

/// [CloudSyncNotifier] 的狀態快照。
@immutable
class CloudSyncState {
  /// 建立 [CloudSyncState]。
  const CloudSyncState({this.phase = CloudSyncPhase.idle, this.errorToken});

  /// 目前階段。
  final CloudSyncPhase phase;

  /// phase == error 時的原因 token（'network'｜'busy'｜'schemaTooNew'｜'authFailed'），
  /// UI 端解 i18n。
  final String? errorToken;
}

/// [TokenStore] provider，預設 DPAPI 安全儲存。
final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

/// [GoogleAuthService] provider。
final googleAuthServiceProvider = Provider<GoogleAuthService>(
  (ref) => GoogleAuthService(
    tokenStore: ref.watch(tokenStoreProvider),
    baseClientFactory: http.Client.new,
  ),
);

/// 以授權 client 建立 [CloudSyncRemote] 的工廠 provider。
final cloudSyncRemoteFactoryProvider =
    Provider<CloudSyncRemote Function(http.Client)>(
      (ref) => DriveSyncRemote.new,
    );

/// 開啟授權頁 URL 的 provider（測試 override 成 no-op）。
final cloudSyncUrlOpenerProvider = Provider<void Function(String url)>(
  (ref) => (url) => unawaited(launchUrl(Uri.parse(url))),
);

/// [CloudSyncNotifier] 的 Riverpod provider。
final cloudSyncProvider = NotifierProvider<CloudSyncNotifier, CloudSyncState>(
  CloudSyncNotifier.new,
);

/// 雲端同步狀態管理：連結／登出、四個觸發入口、5 秒 debounce 與單飛鎖。
class CloudSyncNotifier extends Notifier<CloudSyncState> {
  /// Logger 實例（同步流程）。
  static final _log = Logger('cloudsync.sync');

  /// 目前的授權 client；null = 尚未還原或未連結。
  AuthClient? _client;

  /// 資料變動觸發的 debounce timer。
  Timer? _debounce;

  /// 單飛鎖：一輪同步進行中。
  bool _syncing = false;

  /// 進行中又被觸發 → 結束後補跑一輪。
  bool _pendingRerun = false;

  /// 上次上傳內容的指紋，供資料變動觸發的跳過判斷。
  String? _lastFingerprint;

  /// 授權流程世代號；cancelLink／unlink 時遞增以拋棄過期的授權結果。
  int _authGeneration = 0;

  @override
  CloudSyncState build() {
    ref.onDispose(() {
      _debounce?.cancel();
      _client?.close();
    });
    ref.listen(
      gachaRepositoryProvider.select((s) => s.byUid),
      (_, __) => _onLocalChange(),
    );
    ref.listen(
      settingsProvider.select((s) => s.uidAliases),
      (_, __) => _onLocalChange(),
    );
    return const CloudSyncState();
  }

  /// 是否已連結雲端帳號。
  bool get _linked =>
      ref.read(settingsProvider).cloudAccountEmail != null;

  /// App 啟動入口：已連結則還原授權，開關開啟時靜默跑一輪。
  Future<void> start() async {
    if (!isCloudSyncConfigured) return;
    await ref.read(settingsProvider.notifier).waitForLoad();
    if (!ref.mounted || !_linked) return;
    try {
      await _ensureClient();
    } on CloudReauthRequiredException {
      state = const CloudSyncState(phase: CloudSyncPhase.reauthRequired);
      return;
    } catch (e) {
      _log.warning('startup restore failed: $e');
      state = const CloudSyncState(
        phase: CloudSyncPhase.error,
        errorToken: 'network',
      );
      return;
    }
    if (ref.read(settingsProvider).cloudAutoSyncEnabled) {
      await syncNow(manual: false);
    }
  }

  /// 連結 Google 帳號：開瀏覽器授權，成功後存 email 並立即同步一輪。
  Future<void> link() async {
    if (!isCloudSyncConfigured) return;
    if (state.phase == CloudSyncPhase.awaitingConsent) return;
    final gen = ++_authGeneration;
    state = const CloudSyncState(phase: CloudSyncPhase.awaitingConsent);
    final auth = ref.read(googleAuthServiceProvider);
    final openUrl = ref.read(cloudSyncUrlOpenerProvider);
    try {
      final session = await auth.signIn(openUrl);
      if (!ref.mounted || gen != _authGeneration) {
        session.client.close();
        return;
      }
      _client?.close();
      _client = session.client;
      await ref.read(settingsProvider.notifier).setCloudAccount(session.email);
      if (!ref.mounted) return;
      state = const CloudSyncState();
      await syncNow(manual: true);
    } catch (e) {
      if (!ref.mounted || gen != _authGeneration) return;
      _log.warning('link failed: $e');
      state = const CloudSyncState(
        phase: CloudSyncPhase.error,
        errorToken: 'authFailed',
      );
    }
  }

  /// 取消進行中的授權等待（拋棄結果，回到閒置）。
  void cancelLink() {
    if (state.phase != CloudSyncPhase.awaitingConsent) return;
    _authGeneration++;
    state = const CloudSyncState();
    _log.info('link cancelled');
  }

  /// 中斷連結：revoke＋刪 token＋清 settings；本機與雲端資料皆保留。
  Future<void> unlink() async {
    _authGeneration++;
    _debounce?.cancel();
    await ref.read(googleAuthServiceProvider).signOut();
    if (!ref.mounted) return;
    _client?.close();
    _client = null;
    _lastFingerprint = null;
    await ref.read(settingsProvider.notifier).clearCloudAccount();
    if (!ref.mounted) return;
    state = const CloudSyncState();
  }

  /// 切換自動同步；開啟時立即補跑一輪。
  Future<void> setAutoSync(bool value) async {
    await ref.read(settingsProvider.notifier).setCloudAutoSyncEnabled(value);
    if (!ref.mounted) return;
    if (value && _linked) await syncNow(manual: false);
  }

  /// 把 [uid] 排入待雲端移除清單並立即同步（離線時清單留待下輪補刪）。
  Future<void> queueCloudRemoval(String uid) async {
    await ref.read(settingsProvider.notifier).addCloudPendingRemoval(uid);
    if (!ref.mounted) return;
    _debounce?.cancel();
    await syncNow(manual: false);
  }

  /// 跑一輪同步。[manual] 目前僅影響 log 標記；錯誤一律以狀態列呈現（spec §8）。
  Future<void> syncNow({required bool manual}) async {
    if (!isCloudSyncConfigured || !_linked) return;
    if (_syncing) {
      _pendingRerun = true;
      return;
    }
    _syncing = true;
    state = const CloudSyncState(phase: CloudSyncPhase.syncing);
    _log.info('sync round start manual=$manual');
    try {
      await _ensureClient();
      final settings = ref.read(settingsProvider);
      final pending = settings.cloudPendingRemovals;
      final outcome = await runSyncRound(
        remote: ref.read(cloudSyncRemoteFactoryProvider)(_client!),
        pendingRemovals: pending,
        applyRemote: (bundle) => ref
            .read(gachaRepositoryProvider.notifier)
            .importBundleForCloudSync(bundle),
        exportLocal: _exportLocal,
        clearPendingRemovals: (uids) => ref
            .read(settingsProvider.notifier)
            .removeCloudPendingRemovals(uids),
      );
      if (!ref.mounted) return;
      switch (outcome) {
        case CloudSyncSuccess(:final uploadedFingerprint):
          _lastFingerprint = uploadedFingerprint;
          await ref
              .read(settingsProvider.notifier)
              .setCloudLastSyncedAt(DateTime.now().toUtc());
          if (!ref.mounted) return;
          state = const CloudSyncState();
        case CloudSyncSkippedSchemaTooNew():
          state = const CloudSyncState(
            phase: CloudSyncPhase.error,
            errorToken: 'schemaTooNew',
          );
      }
    } on CloudReauthRequiredException {
      if (!ref.mounted) return;
      state = const CloudSyncState(phase: CloudSyncPhase.reauthRequired);
    } on CloudSyncBusyException {
      if (!ref.mounted) return;
      _log.info('sync deferred: repository busy');
      state = const CloudSyncState(
        phase: CloudSyncPhase.error,
        errorToken: 'busy',
      );
      _scheduleDebounced();
    } catch (e, st) {
      if (!ref.mounted) return;
      _log.warning('sync round failed', e, st);
      state = const CloudSyncState(
        phase: CloudSyncPhase.error,
        errorToken: 'network',
      );
    } finally {
      _syncing = false;
      if (_pendingRerun && ref.mounted) {
        _pendingRerun = false;
        unawaited(syncNow(manual: false));
      }
    }
  }

  /// 還原授權 client（已有就直接用）；無 token 視同需要重新連結。
  Future<void> _ensureClient() async {
    if (_client != null) return;
    final restored = await ref.read(googleAuthServiceProvider).restore();
    if (restored == null) throw const CloudReauthRequiredException();
    _client = restored;
  }

  /// 本機資料（byUid／別名）變動時排程 debounce 同步。
  void _onLocalChange() {
    if (!isCloudSyncConfigured || !_linked) return;
    if (!ref.read(settingsProvider).cloudAutoSyncEnabled) return;
    if (ref.read(gachaRepositoryProvider).isBootstrapping) return;
    _scheduleDebounced();
  }

  /// 5 秒後跑一輪；到點時指紋沒變就跳過（避免同步自身的合併寫入造成空轉輪）。
  void _scheduleDebounced() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 5), () {
      if (!ref.mounted || !_linked) return;
      if (syncFingerprint(_exportLocal()) == _lastFingerprint) return;
      unawaited(syncNow(manual: false));
    });
  }

  /// 把本機全帳號打包成與手動匯出同格式的 bundle JSON。
  String _exportLocal() {
    final gacha = ref.read(gachaRepositoryProvider);
    final settings = ref.read(settingsProvider);
    return exportAccounts(
      byUid: gacha.byUid,
      uidOrder: settings.uidOrder,
      uidAliases: settings.uidAliases,
      lastActiveUid: gacha.activeUid,
      appVersion: ref.read(appVersionProvider),
      now: DateTime.now(),
    );
  }
}
```

> 測試注意：測試環境 `isCloudSyncConfigured` 為 false（常數是空字串），會讓所有入口 no-op。解法：`cloud_sync_config.dart` 的 `isCloudSyncConfigured` 改為可測試的變數注入——在 `cloud_sync_config.dart` 加：
>
> ```dart
> /// 測試用 override；null 時以憑證常數判斷。
> @visibleForTesting
> bool? debugCloudSyncConfiguredOverride;
> ```
>
> 並把 getter 改為：
>
> ```dart
> bool get isCloudSyncConfigured =>
>     debugCloudSyncConfiguredOverride ??
>     (cloudSyncClientId.isNotEmpty && cloudSyncClientSecret.isNotEmpty);
> ```
>
> （需 `import 'package:flutter/foundation.dart';`。）測試的 `setUp` 加 `debugCloudSyncConfiguredOverride = true;`、`tearDown` 還原 null。把這段補進 Step 3 實作與 Step 1 測試檔。

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/state/cloud_sync_test.dart`
Expected: All tests passed!

- [ ] **Step 5: 全套驗證＋commit**

```
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/state/cloud_sync.dart lib/services/cloud_sync/cloud_sync_config.dart test/state/cloud_sync_test.dart
git commit -m "feat(cloud-sync): add CloudSyncNotifier state machine with debounced triggers"
```

---

### Task 7: 設定頁「雲端同步」區塊與 ARB 字串

**Files:**
- Create: `lib/widgets/cards/cloud_sync_section.dart`
- Modify: `lib/pages/settings_page.dart`
- Modify: `lib/l10n/app_zh.arb`、`lib/l10n/app_zh_Hans.arb`、`lib/l10n/app_en.arb`、`lib/l10n/app_ja.arb`
- Test: `test/widgets/cloud_sync_section_test.dart`

**Interfaces:**
- Consumes: `cloudSyncProvider`／`CloudSyncPhase`（Task 6）、`settingsProvider` cloud 欄位（Task 1）、`isCloudSyncConfigured`。
- Produces: `class CloudSyncSection extends ConsumerWidget`（公開，供 settings page 與 widget test 使用）。

- [ ] **Step 1: 加 ARB 字串（先加字串，widget 才能編譯）**

`lib/l10n/app_zh.arb`（template；插在 `"settingsDataManagement"` 附近，帶 placeholder 的 key 要加 `@` metadata，格式照檔內既有 `@footerLastUpdated` 樣式）：

```json
"settingsCloudSync": "雲端同步",
"cloudSyncIntro": "連結 Google 帳號後，喚取紀錄會自動備份到你的 Google 雲端硬碟，並在多台電腦間同步。",
"cloudSyncUnconfigured": "此建置未設定 Google OAuth 憑證，雲端同步無法使用。",
"cloudSyncLink": "連結 Google 帳號",
"cloudSyncAwaitingConsent": "已開啟瀏覽器，請在瀏覽器完成授權...",
"cloudSyncLinkedAs": "已連結：{email}",
"@cloudSyncLinkedAs": {"placeholders": {"email": {"type": "String"}}},
"cloudSyncAutoToggle": "自動同步",
"cloudSyncAutoToggleHint": "App 啟動與資料變動後自動同步；關閉後仍可手動同步。",
"cloudSyncNow": "立即同步",
"cloudSyncUnlink": "中斷連結",
"cloudSyncUnlinkConfirmTitle": "中斷連結",
"cloudSyncUnlinkConfirmBody": "中斷後將停止同步。本機資料與雲端已備份的資料都會保留。",
"cloudSyncLastSynced": "上次同步：{time}",
"@cloudSyncLastSynced": {"placeholders": {"time": {"type": "String"}}},
"cloudSyncNeverSynced": "尚未同步",
"cloudSyncErrorNetwork": "同步失敗：網路連線問題，稍後會自動重試。",
"cloudSyncErrorBusy": "同步暫緩：目前有更新或匯入進行中，稍後會自動重試。",
"cloudSyncErrorSchemaTooNew": "同步已跳過：雲端資料由較新版本的 App 建立，請先更新 App。",
"cloudSyncErrorAuthFailed": "授權失敗，請再試一次。",
"cloudSyncReauthRequired": "授權已失效，請重新連結 Google 帳號。",
"cloudSyncRemoveFromCloud": "同時從雲端同步資料移除此帳號"
```

`app_zh_Hans.arb`（簡體）：

```json
"settingsCloudSync": "云端同步",
"cloudSyncIntro": "关联 Google 账号后，唤取记录会自动备份到你的 Google 云端硬盘，并在多台电脑间同步。",
"cloudSyncUnconfigured": "此构建未设置 Google OAuth 凭据，云端同步无法使用。",
"cloudSyncLink": "关联 Google 账号",
"cloudSyncAwaitingConsent": "已打开浏览器，请在浏览器完成授权...",
"cloudSyncLinkedAs": "已关联：{email}",
"@cloudSyncLinkedAs": {"placeholders": {"email": {"type": "String"}}},
"cloudSyncAutoToggle": "自动同步",
"cloudSyncAutoToggleHint": "App 启动与数据变动后自动同步；关闭后仍可手动同步。",
"cloudSyncNow": "立即同步",
"cloudSyncUnlink": "取消关联",
"cloudSyncUnlinkConfirmTitle": "取消关联",
"cloudSyncUnlinkConfirmBody": "取消后将停止同步。本机数据与云端已备份的数据都会保留。",
"cloudSyncLastSynced": "上次同步：{time}",
"@cloudSyncLastSynced": {"placeholders": {"time": {"type": "String"}}},
"cloudSyncNeverSynced": "尚未同步",
"cloudSyncErrorNetwork": "同步失败：网络连接问题，稍后会自动重试。",
"cloudSyncErrorBusy": "同步暂缓：当前有更新或导入进行中，稍后会自动重试。",
"cloudSyncErrorSchemaTooNew": "同步已跳过：云端数据由较新版本的 App 创建，请先更新 App。",
"cloudSyncErrorAuthFailed": "授权失败，请再试一次。",
"cloudSyncReauthRequired": "授权已失效，请重新关联 Google 账号。",
"cloudSyncRemoveFromCloud": "同时从云端同步数据中移除此账号"
```

`app_en.arb`：

```json
"settingsCloudSync": "Cloud sync",
"cloudSyncIntro": "Link your Google account to automatically back up convene records to your Google Drive and keep multiple computers in sync.",
"cloudSyncUnconfigured": "This build has no Google OAuth credentials configured; cloud sync is unavailable.",
"cloudSyncLink": "Link Google account",
"cloudSyncAwaitingConsent": "Browser opened. Please finish authorization in your browser...",
"cloudSyncLinkedAs": "Linked: {email}",
"@cloudSyncLinkedAs": {"placeholders": {"email": {"type": "String"}}},
"cloudSyncAutoToggle": "Auto sync",
"cloudSyncAutoToggleHint": "Syncs automatically on app start and after data changes; manual sync stays available when off.",
"cloudSyncNow": "Sync now",
"cloudSyncUnlink": "Unlink",
"cloudSyncUnlinkConfirmTitle": "Unlink",
"cloudSyncUnlinkConfirmBody": "Syncing will stop. Both local data and the cloud backup are kept.",
"cloudSyncLastSynced": "Last synced: {time}",
"@cloudSyncLastSynced": {"placeholders": {"time": {"type": "String"}}},
"cloudSyncNeverSynced": "Not synced yet",
"cloudSyncErrorNetwork": "Sync failed: network problem. Will retry automatically.",
"cloudSyncErrorBusy": "Sync deferred: an update or import is in progress. Will retry automatically.",
"cloudSyncErrorSchemaTooNew": "Sync skipped: the cloud data was created by a newer app version. Please update the app first.",
"cloudSyncErrorAuthFailed": "Authorization failed. Please try again.",
"cloudSyncReauthRequired": "Authorization expired. Please relink your Google account.",
"cloudSyncRemoveFromCloud": "Also remove this account from cloud sync data"
```

`app_ja.arb`：

```json
"settingsCloudSync": "クラウド同期",
"cloudSyncIntro": "Google アカウントを連携すると、喚起履歴が自動的に Google ドライブへバックアップされ、複数の PC 間で同期されます。",
"cloudSyncUnconfigured": "このビルドには Google OAuth 認証情報が設定されていないため、クラウド同期は利用できません。",
"cloudSyncLink": "Google アカウントを連携",
"cloudSyncAwaitingConsent": "ブラウザを開きました。ブラウザで認可を完了してください...",
"cloudSyncLinkedAs": "連携中：{email}",
"@cloudSyncLinkedAs": {"placeholders": {"email": {"type": "String"}}},
"cloudSyncAutoToggle": "自動同期",
"cloudSyncAutoToggleHint": "アプリ起動時とデータ変更後に自動同期します。オフでも手動同期は可能です。",
"cloudSyncNow": "今すぐ同期",
"cloudSyncUnlink": "連携を解除",
"cloudSyncUnlinkConfirmTitle": "連携を解除",
"cloudSyncUnlinkConfirmBody": "解除すると同期は停止します。ローカルとクラウドのデータはどちらも保持されます。",
"cloudSyncLastSynced": "前回の同期：{time}",
"@cloudSyncLastSynced": {"placeholders": {"time": {"type": "String"}}},
"cloudSyncNeverSynced": "まだ同期していません",
"cloudSyncErrorNetwork": "同期に失敗しました：ネットワークの問題です。後で自動的に再試行します。",
"cloudSyncErrorBusy": "同期を保留しました：更新またはインポートが進行中です。後で自動的に再試行します。",
"cloudSyncErrorSchemaTooNew": "同期をスキップしました：クラウドのデータは新しいバージョンのアプリで作成されています。先にアプリを更新してください。",
"cloudSyncErrorAuthFailed": "認可に失敗しました。もう一度お試しください。",
"cloudSyncReauthRequired": "認可が失効しました。Google アカウントを再連携してください。",
"cloudSyncRemoveFromCloud": "クラウド同期データからもこのアカウントを削除する"
```

然後：`fvm flutter gen-l10n`
Expected: 無錯誤。

- [ ] **Step 2: 寫失敗 widget 測試**

建立 `test/widgets/cloud_sync_section_test.dart`（fake 們 import 自 Task 6 測試檔會造成重複——把 Task 6 測試檔中的 `InMemoryTokenStore`、`_FakeAuthService`、`_FakeRemote`、`_FakeCapture` 抽到共用 `test/helpers/cloud_sync_fakes.dart`（改成公開命名 `FakeAuthService`、`FakeRemote`、`FakeCapture`），Task 6 測試同步改 import；本測試也用它）：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/cloud_sync.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/cloud_sync_section.dart';

import '../helpers/cloud_sync_fakes.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cloud_section_test_');
    SharedPreferences.setMockInitialValues({});
    debugCloudSyncConfiguredOverride = true;
  });

  tearDown(() async {
    debugCloudSyncConfiguredOverride = null;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget wrap() => ProviderScope(
    overrides: [
      appVersionProvider.overrideWithValue('1.5.0'),
      gachaStorageProvider.overrideWithValue(GachaStorage(tempDir)),
      gachaCaptureProvider.overrideWithValue(FakeCapture()),
      cancellableHttpClientFactoryProvider.overrideWithValue(
        () => CancellableHttpClient(
          client: MockClient((_) async => http.Response('', 500)),
          cancel: () {},
        ),
      ),
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      cloudSyncRemoteFactoryProvider.overrideWithValue((_) => FakeRemote()),
      cloudSyncUrlOpenerProvider.overrideWithValue((_) {}),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('en'),
      home: Scaffold(body: SingleChildScrollView(child: CloudSyncSection())),
    ),
  );

  testWidgets('未連結：顯示說明與連結按鈕', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Link Google account'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
  });

  testWidgets('已連結：顯示 email、開關、立即同步與中斷連結', (tester) async {
    SharedPreferences.setMockInitialValues({
      'pref.cloudAccountEmail': 'u@example.com',
    });
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.textContaining('u@example.com'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.text('Unlink'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
  });
}
```

- [ ] **Step 3: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/cloud_sync_section_test.dart`
Expected: 編譯失敗（`CloudSyncSection`／helper 不存在）。

- [ ] **Step 4: 抽共用 fakes、實作 CloudSyncSection**

(a) 建 `test/helpers/cloud_sync_fakes.dart`（內容即 Task 6 測試檔的四個 fake class，改公開命名，各加一行 dartdoc），Task 6 測試檔改為 import 它。

(b) 建 `lib/widgets/cards/cloud_sync_section.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/cloud_sync.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/confirm_dialog.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/relative_time_text.dart';

/// 設定頁「雲端同步」區塊：連結 Google 帳號、自動同步開關、立即同步與中斷連結。
class CloudSyncSection extends ConsumerWidget {
  /// 建立 [CloudSyncSection]。
  const CloudSyncSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context)!;
    final tokens = Theme.of(context).gacha;

    if (!isCloudSyncConfigured) {
      return Text(
        l.cloudSyncUnconfigured,
        style: TextStyle(color: tokens.textMuted),
      );
    }

    final email = ref.watch(
      settingsProvider.select((s) => s.cloudAccountEmail),
    );
    final sync = ref.watch(cloudSyncProvider);

    if (email == null) {
      return _UnlinkedView(l: l, phase: sync.phase);
    }
    return _LinkedView(l: l, email: email, sync: sync);
  }
}

/// 未連結狀態：說明文字＋連結按鈕（授權等待中顯示 spinner 與取消）。
class _UnlinkedView extends ConsumerWidget {
  /// 建立 [_UnlinkedView]。
  const _UnlinkedView({required this.l, required this.phase});

  /// 當前 i18n 字串實例。
  final AppLocalizations l;

  /// 當前同步階段。
  final CloudSyncPhase phase;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).gacha;
    final awaiting = phase == CloudSyncPhase.awaitingConsent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.cloudSyncIntro, style: TextStyle(color: tokens.textSecondary)),
        if (phase == CloudSyncPhase.error) ...[
          const SizedBox(height: AppSpacing.s),
          Text(
            l.cloudSyncErrorAuthFailed,
            style: TextStyle(color: tokens.stateDanger),
          ),
        ],
        const SizedBox(height: AppSpacing.m),
        if (awaiting)
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppSpacing.m),
              Expanded(
                child: Text(
                  l.cloudSyncAwaitingConsent,
                  style: TextStyle(color: tokens.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(cloudSyncProvider.notifier).cancelLink(),
                child: Text(l.actionCancel),
              ),
            ],
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => ref.read(cloudSyncProvider.notifier).link(),
              icon: const Icon(Icons.link, size: 18),
              label: Text(l.cloudSyncLink),
            ),
          ),
      ],
    );
  }
}

/// 已連結狀態：email、自動同步開關、同步狀態列、立即同步與中斷連結。
class _LinkedView extends ConsumerWidget {
  /// 建立 [_LinkedView]。
  const _LinkedView({required this.l, required this.email, required this.sync});

  /// 當前 i18n 字串實例。
  final AppLocalizations l;

  /// 已連結帳號 email。
  final String email;

  /// 當前同步狀態。
  final CloudSyncState sync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).gacha;
    final autoSync = ref.watch(
      settingsProvider.select((s) => s.cloudAutoSyncEnabled),
    );
    final lastSyncedAt = ref.watch(
      settingsProvider.select((s) => s.cloudLastSyncedAt),
    );
    final syncing = sync.phase == CloudSyncPhase.syncing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.cloudSyncLinkedAs(email)),
        const SizedBox(height: AppSpacing.s),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.cloudSyncAutoToggle),
          subtitle: Text(
            l.cloudSyncAutoToggleHint,
            style: TextStyle(color: tokens.textMuted, fontSize: 12),
          ),
          value: autoSync,
          onChanged: (v) => ref.read(cloudSyncProvider.notifier).setAutoSync(v),
        ),
        const SizedBox(height: AppSpacing.s),
        _StatusLine(l: l, sync: sync, lastSyncedAt: lastSyncedAt),
        const SizedBox(height: AppSpacing.m),
        Wrap(
          spacing: AppSpacing.m,
          runSpacing: AppSpacing.s,
          children: [
            FilledButton.icon(
              onPressed: syncing
                  ? null
                  : () => ref
                        .read(cloudSyncProvider.notifier)
                        .syncNow(manual: true),
              icon: syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_sync, size: 18),
              label: Text(l.cloudSyncNow),
            ),
            if (sync.phase == CloudSyncPhase.reauthRequired)
              FilledButton.icon(
                onPressed: () => ref.read(cloudSyncProvider.notifier).link(),
                icon: const Icon(Icons.link, size: 18),
                label: Text(l.cloudSyncLink),
              ),
            OutlinedButton.icon(
              onPressed: () => _confirmUnlink(context, ref),
              icon: const Icon(Icons.link_off, size: 18),
              label: Text(l.cloudSyncUnlink),
            ),
          ],
        ),
      ],
    );
  }

  /// 彈出中斷連結確認框，確認後執行 unlink。
  Future<void> _confirmUnlink(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context)!;
    final ok = await showConfirmDialog(
      context: context,
      title: l.cloudSyncUnlinkConfirmTitle,
      body: l.cloudSyncUnlinkConfirmBody,
      cancelLabel: l.actionCancel,
      confirmLabel: l.cloudSyncUnlink,
      confirmIcon: Icons.link_off,
    );
    if (ok != true) return;
    await ref.read(cloudSyncProvider.notifier).unlink();
  }
}

/// 同步狀態列：依 phase 顯示上次同步時間或錯誤原因。
class _StatusLine extends StatelessWidget {
  /// 建立 [_StatusLine]。
  const _StatusLine({
    required this.l,
    required this.sync,
    required this.lastSyncedAt,
  });

  /// 當前 i18n 字串實例。
  final AppLocalizations l;

  /// 當前同步狀態。
  final CloudSyncState sync;

  /// 上次同步成功時間。
  final DateTime? lastSyncedAt;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).gacha;
    switch (sync.phase) {
      case CloudSyncPhase.reauthRequired:
        return Text(
          l.cloudSyncReauthRequired,
          style: TextStyle(color: tokens.stateDanger),
        );
      case CloudSyncPhase.error:
        final text = switch (sync.errorToken) {
          'busy' => l.cloudSyncErrorBusy,
          'schemaTooNew' => l.cloudSyncErrorSchemaTooNew,
          'authFailed' => l.cloudSyncErrorAuthFailed,
          _ => l.cloudSyncErrorNetwork,
        };
        return Text(text, style: TextStyle(color: tokens.stateDanger));
      case CloudSyncPhase.idle:
      case CloudSyncPhase.syncing:
      case CloudSyncPhase.awaitingConsent:
        final at = lastSyncedAt;
        if (at == null) {
          return Text(
            l.cloudSyncNeverSynced,
            style: TextStyle(color: tokens.textMuted),
          );
        }
        return RelativeTimeText(
          time: at,
          templateBuilder: l.cloudSyncLastSynced,
          style: TextStyle(color: tokens.textMuted),
        );
    }
  }
}
```

（若 `RelativeTimeText` 的 `templateBuilder` 參數型別不合，照 `app_shell.dart` 的 `l.footerLastUpdated` 用法對齊。）

(c) `lib/pages/settings_page.dart`：在「資料管理」`SectionCard` 之後（`_ItemDataSection` 之前）插入：

```dart
              const SizedBox(height: AppSpacing.xl),
              SectionCard(
                title: l.settingsCloudSync,
                icon: Icons.cloud_sync_outlined,
                child: const CloudSyncSection(),
              ),
```

並加 import：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/cloud_sync_section.dart';
```

- [ ] **Step 5: 跑測試確認通過**

Run: `fvm flutter test test/widgets/cloud_sync_section_test.dart test/state/cloud_sync_test.dart`
Expected: All tests passed!

- [ ] **Step 6: 全套驗證＋commit**

```
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/widgets/cards/cloud_sync_section.dart lib/pages/settings_page.dart lib/l10n/ test/widgets/cloud_sync_section_test.dart test/helpers/cloud_sync_fakes.dart test/state/cloud_sync_test.dart
git commit -m "feat(cloud-sync): add settings page cloud sync section with i18n"
```

---

### Task 8: 刪帳號「同時從雲端移除」勾選

**Files:**
- Modify: `lib/widgets/dialogs/confirm_dialog.dart`
- Modify: `lib/widgets/cards/account_management.dart`
- Test: `test/widgets/confirm_dialog_checkbox_test.dart`

**Interfaces:**
- Consumes: `cloudSyncProvider.notifier.queueCloudRemoval(String uid)`（Task 6）、`settingsProvider` 的 `cloudAccountEmail`。
- Produces:
  - `class ConfirmTypeResult { final bool confirmed; final bool checkboxChecked; }`
  - `Future<ConfirmTypeResult?> showConfirmTypeDialogWithCheckbox({...同 showConfirmTypeDialog 參數..., required String checkboxLabel})`
  - 既有 `showConfirmTypeDialog` 簽名與行為不變。

- [ ] **Step 1: 寫失敗測試**

建立 `test/widgets/confirm_dialog_checkbox_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/confirm_dialog.dart';

void main() {
  /// 打開帶 checkbox 的打字確認 dialog 並回傳結果 future。
  Future<ConfirmTypeResult?> open(WidgetTester tester) async {
    ConfirmTypeResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showConfirmTypeDialogWithCheckbox(
                context: context,
                title: '確認',
                body: '刪除帳號 100000001？',
                expectedText: '100000001',
                cancelLabel: '取消',
                confirmLabel: '刪除',
                confirmIcon: Icons.delete_outline,
                checkboxLabel: '同時從雲端移除',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('打字正確＋勾選 → confirmed=true, checked=true', (tester) async {
    final resultFuture = open(tester);
    await tester.enterText(find.byType(TextField), '100000001');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刪除'));
    await tester.pumpAndSettle();

    final result = await resultFuture;
    expect(result, isNotNull);
    expect(result!.confirmed, isTrue);
    expect(result.checkboxChecked, isTrue);
  });

  testWidgets('不勾選 → checked=false；取消 → confirmed=false', (tester) async {
    final resultFuture = open(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    final result = await resultFuture;
    expect(result!.confirmed, isFalse);
    expect(result.checkboxChecked, isFalse);
  });
}
```

（`open` helper 內 `result` 在 dialog 關閉後才被賦值——await `resultFuture` 前 dialog 已 pop，直接回傳 `result` 即可；若 closure 捕捉時序有問題，改用 `Completer`。）

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/confirm_dialog_checkbox_test.dart`
Expected: 編譯失敗（`ConfirmTypeResult` 不存在）。

- [ ] **Step 3: 實作 confirm_dialog.dart**

1. 加 result 類別與新入口：

```dart
/// [showConfirmTypeDialogWithCheckbox] 的結果。
class ConfirmTypeResult {
  /// 建立 [ConfirmTypeResult]。
  const ConfirmTypeResult({
    required this.confirmed,
    required this.checkboxChecked,
  });

  /// 使用者是否按下確認（打字閘通過）。
  final bool confirmed;

  /// 附加 checkbox 是否勾選。
  final bool checkboxChecked;
}

/// 顯示帶附加 checkbox 的打字確認 dialog。
/// 回傳 null = 系統 dismiss；否則見 [ConfirmTypeResult]。
Future<ConfirmTypeResult?> showConfirmTypeDialogWithCheckbox({
  required BuildContext context,
  required String title,
  required String body,
  required String expectedText,
  required String cancelLabel,
  required String confirmLabel,
  required IconData confirmIcon,
  required String checkboxLabel,
}) {
  return showDialog<ConfirmTypeResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ConfirmDialog(
      title: title,
      body: body,
      expectedText: expectedText,
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
      confirmIcon: confirmIcon,
      checkboxLabel: checkboxLabel,
    ),
  );
}
```

2. `showConfirmTypeDialog`（既有）改為内部走同一 dialog、對外簽名不變：

```dart
Future<bool?> showConfirmTypeDialog({
  required BuildContext context,
  required String title,
  required String body,
  required String expectedText,
  required String cancelLabel,
  required String confirmLabel,
  required IconData confirmIcon,
}) async {
  final result = await showDialog<ConfirmTypeResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ConfirmDialog(
      title: title,
      body: body,
      expectedText: expectedText,
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
      confirmIcon: confirmIcon,
      checkboxLabel: null,
    ),
  );
  return result?.confirmed;
}
```

3. `_ConfirmDialog` 加欄位與 checkbox：constructor 加 `required this.checkboxLabel`；欄位：

```dart
  /// 附加 checkbox 的標籤；null 代表不顯示 checkbox。
  final String? checkboxLabel;
```

State 加：

```dart
  /// 附加 checkbox 目前是否勾選。
  bool _checked = false;
```

`build` 的 `content` Column 在 TextField 後加：

```dart
          if (widget.checkboxLabel != null) ...[
            const SizedBox(height: AppSpacing.m),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              title: Text(widget.checkboxLabel!),
              value: _checked,
              onChanged: (v) => setState(() => _checked = v ?? false),
            ),
          ],
```

兩顆按鈕的 pop 改為：

```dart
// 取消：
Navigator.of(context).pop(
  const ConfirmTypeResult(confirmed: false, checkboxChecked: false),
)
// 確認：
Navigator.of(context).pop(
  ConfirmTypeResult(confirmed: true, checkboxChecked: _checked),
)
```

（測試若用 `find.byType(Checkbox)` 找不到 `CheckboxListTile` 內部的 Checkbox，改斷言 `find.byType(CheckboxListTile)` 並 tap 它。）

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/confirm_dialog_checkbox_test.dart`
Expected: All tests passed!（既有全部 dialog 相關測試也必須仍綠：`fvm flutter test`。）

- [ ] **Step 5: account_management 接線**

`lib/widgets/cards/account_management.dart` 的 `_remove` 改為：

```dart
  /// 彈出打字確認 dialog（已連結雲端時附「同時從雲端移除」勾選），
  /// 確認後刪除本機帳號，勾選時再把 UID 排入雲端移除佇列。
  Future<void> _remove(BuildContext ctx, WidgetRef ref, String uid) async {
    final l = AppLocalizations.of(ctx)!;
    final linked =
        ref.read(settingsProvider).cloudAccountEmail != null;

    if (!linked) {
      final ok = await showConfirmTypeDialog(
        context: ctx,
        title: l.confirmTitle,
        body: l.confirmClearActiveBody(uid),
        expectedText: uid,
        cancelLabel: l.actionCancel,
        confirmLabel: l.confirmDelete,
        confirmIcon: Icons.delete_outline,
      );
      if (ok != true) return;
      await ref.read(gachaRepositoryProvider.notifier).removeUid(uid);
      return;
    }

    final result = await showConfirmTypeDialogWithCheckbox(
      context: ctx,
      title: l.confirmTitle,
      body: l.confirmClearActiveBody(uid),
      expectedText: uid,
      cancelLabel: l.actionCancel,
      confirmLabel: l.confirmDelete,
      confirmIcon: Icons.delete_outline,
      checkboxLabel: l.cloudSyncRemoveFromCloud,
    );
    if (result == null || !result.confirmed) return;
    await ref.read(gachaRepositoryProvider.notifier).removeUid(uid);
    if (result.checkboxChecked) {
      await ref.read(cloudSyncProvider.notifier).queueCloudRemoval(uid);
    }
  }
```

加 import：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/state/cloud_sync.dart';
```

- [ ] **Step 6: 全套驗證＋commit**

```
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/widgets/dialogs/confirm_dialog.dart lib/widgets/cards/account_management.dart test/widgets/confirm_dialog_checkbox_test.dart
git commit -m "feat(cloud-sync): add remove-from-cloud checkbox to account deletion"
```

---

### Task 9: 啟動接線、整體驗證與手動驗證指引

**Files:**
- Modify: `lib/pages/app_shell.dart`

**Interfaces:**
- Consumes: `cloudSyncProvider.notifier.start()`（Task 6）。
- Produces: 完整可用的功能（填入真實 OAuth 憑證後）。

- [ ] **Step 1: app_shell 啟動接線**

`lib/pages/app_shell.dart` 的 `initState` postFrameCallback 內、release check 之後加：

```dart
      ref.read(cloudSyncProvider.notifier).start();
```

加 import：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/state/cloud_sync.dart';
```

（`start()` 回傳 Future，這裡 fire-and-forget，與上一行 `check(manual: false)` 同模式；若 analyzer 抱怨 unawaited future，包 `unawaited(...)` 並 import `dart:async`。）

- [ ] **Step 2: 全套驗證＋commit**

```
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
git add lib/pages/app_shell.dart
git commit -m "feat(cloud-sync): trigger cloud sync on app startup"
```

- [ ] **Step 3: 手動驗證（需維護者操作，無法自動化）**

1. **建立 OAuth 憑證**（維護者 GoneTone 操作）：
   - [Google Cloud Console](https://console.cloud.google.com/) 建專案 → 「API 和服務」啟用 **Google Drive API**。
   - 「OAuth 同意畫面」：External、填 app 名稱與聯絡信箱；scopes 加 `.../auth/drive.appdata` 與 `email`（皆為非敏感，不需審查）；發布狀態先用 Testing＋加自己為測試使用者，正式發佈前再 Publish。
   - 「憑證」→ 建立 OAuth 用戶端 ID → 應用程式類型選 **電腦版應用程式（Desktop app）**。
   - 把產出的 client id／secret 填入 `lib/services/cloud_sync/cloud_sync_config.dart` 的 `cloudSyncClientId`／`cloudSyncClientSecret`，commit：`chore(cloud-sync): fill in Google OAuth client credentials`。
2. **實機流程驗證**（`fvm flutter run -d windows`）：
   - 設定頁「雲端同步」→「連結 Google 帳號」→ 瀏覽器完成授權 → 回 app 顯示 email、自動跑第一輪、顯示上次同步時間。
   - 重啟 app → 啟動自動靜默同步（看 log `cloudsync.sync`）。
   - 跑一次「更新」抓新紀錄 → 5 秒 debounce 後自動同步。
   - 刪一個測試帳號勾「同時從雲端移除」→ 同步後再匯入舊備份確認該帳號未從雲端復活（pendingRemovals 已生效）。
   - 「中斷連結」→ email 清除；重連 → 資料從雲端合併回來。
   - 模擬第二台電腦：暫時改名本機 `%APPDATA%`（applicationSupport）下的 `gacha_data/` 目錄後啟動、連結同帳號 → 雲端資料自動合併下來。
3. 匯出 log 檢查 `cloudsync.auth`／`cloudsync.sync` 節點內容齊全且無 token 洩漏。

---

## Self-Review 紀錄

- **Spec 覆蓋**：§2 檔案佈局／權限（Task 2、3）、§3 演算法＋合併細節＋schema 保護（Task 4、5；last_active_uid 與別名的本機優先由既有 `_runImport` 天然滿足）、§4 觸發四入口（Task 6、9）、§5 登入登出 token（Task 2、6）、§6 刪帳號（Task 8）、§7 UI（Task 7）、§8 錯誤三分流（Task 6 狀態＋Task 7 狀態列）、§9 logging（各 task 內嵌）、§10 落點（File Structure）、§11 測試（各 task TDD＋Task 9 手動）。
- **佔位符**：OAuth client id／secret 為刻意的空字串常數＋`isCloudSyncConfigured` 降級，屬設計而非佔位；Task 9 有填入步驟。
- **型別一致性**：`importBundleForCloudSync`／`runSyncRound`／`syncFingerprint`／`queueCloudRemoval`／`ConfirmTypeResult` 等簽名已跨 task 對齊 Interfaces 區塊。
- **已知外部 API 風險**：`googleapis_auth`／`googleapis` 的實際簽名以裝好的版本為準（Task 2 Step 5、Task 3 Step 4 已註明調整原則：內部呼叫可調、對外介面不變）。
