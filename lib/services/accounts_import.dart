import 'dart:convert';

import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';

/// Logger 實例（帳號匯入/匯出）。
final _log = Logger('accounts.io');

/// 匯入檔不是由本軟體匯出（`app` 識別碼不符，或舊檔卡池代碼非鳴潮已知集合）時拋出。
class ForeignBundleException implements Exception {
  /// 建立 [ForeignBundleException]。
  const ForeignBundleException();

  @override
  String toString() => 'ForeignBundleException';
}

/// 把 JSON 文字解析回 [AccountsBundle]。
/// schema 版本過新時拋出 [UnsupportedSchemaVersionException]；
/// 非本軟體產生的備份時拋出 [ForeignBundleException]；
/// 其餘結構或型別不符統一拋出 [FormatException]，皆供 UI 挑在地化文案顯示。
AccountsBundle importAccounts(String text) {
  Object? raw;
  try {
    raw = jsonDecode(text);
  } catch (e) {
    _log.warning('import failed: invalid JSON ($e)');
    throw const FormatException('Invalid JSON');
  }
  if (raw is! Map<String, dynamic>) {
    _log.warning('import failed: top-level not an object');
    throw const FormatException('Top-level value must be an object');
  }
  final app = raw['app'];
  final Map<String, dynamic> prepared;
  if (app is String) {
    if (app != accountsBundleAppId) {
      _log.warning('import failed: foreign bundle (app=$app)');
      throw const ForeignBundleException();
    }
    prepared = raw; // 本軟體自己的檔，完整信任、不過濾
  } else {
    prepared = raw; // 暫時直通；legacy screening 於 Task 4 接上
  }
  try {
    return AccountsBundle.fromJson(prepared);
  } on UnsupportedSchemaVersionException catch (e) {
    _log.warning('import failed: unsupported schema version ${e.version}');
    rethrow;
  } on FormatException catch (e) {
    _log.warning('import failed: ${e.message}');
    rethrow;
  } catch (e, st) {
    _log.warning('import failed: parse error', e, st);
    throw FormatException('Failed to parse: $e');
  }
}
