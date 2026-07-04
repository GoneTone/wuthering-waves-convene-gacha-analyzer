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
