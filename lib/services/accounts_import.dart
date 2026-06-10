import 'dart:convert';

import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';

/// Logger 實例（帳號匯入/匯出）。
final _log = Logger('accounts.io');

/// 把 JSON 文字解析回 [AccountsBundle]。schema 版本不符時原樣上拋
/// [UnsupportedSchemaVersionException]；其餘結構或型別不符統一拋出
/// [FormatException]，皆供 UI 挑在地化文案顯示。
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
  try {
    return AccountsBundle.fromJson(raw);
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
