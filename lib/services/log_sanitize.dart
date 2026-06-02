import 'dart:convert';

/// 把 authkey / authkey_ver / sign_type / game_biz 等敏感 query value 改成 `***`,
/// 其餘 query 保留。malformed URL 回 `<malformed url>`。
String sanitizeUrl(String raw) {
  final Uri uri;
  try {
    uri = Uri.parse(raw);
  } catch (_) {
    return '<malformed url>';
  }
  if (uri.host.isEmpty && uri.scheme.isEmpty) {
    return '<malformed url>';
  }
  const redactKeys = {'authkey', 'authkey_ver', 'sign_type', 'game_biz'};
  if (uri.queryParameters.isEmpty) return uri.toString();
  // Build query string manually to avoid Uri percent-encoding the `*` markers.
  final parts = uri.queryParameters.entries.map((e) {
    final v = redactKeys.contains(e.key) ? '***' : e.value;
    return '${e.key}=$v';
  });
  final base = uri.replace(query: '').toString();
  // uri.replace(query:'') leaves a trailing '?', strip it if present.
  final baseNoQ = base.endsWith('?')
      ? base.substring(0, base.length - 1)
      : base;
  return '$baseNoQ?${parts.join('&')}';
}

/// UID 中段遮蔽:`123****890`(前 3 + 後 3)。長度 < 6 全遮 `***`。
String sanitizeUid(String uid) {
  if (uid.length < 6) return '***';
  return '${uid.substring(0, 3)}****${uid.substring(uid.length - 3)}';
}

/// 掃描自由文字 log 訊息中內嵌的 http(s) URL,逐段套 [sanitizeUrl] 後原位替換,
/// 非 URL 內容原樣保留。Rust log 跨橋進 Dart 時統一呼叫,作為單一脫敏匣道,
/// 避免在 Rust 端複製脫敏邏輯。
String sanitizeLogMessage(String message) {
  // log 訊息中 URL 皆為末段或後接空白,以非空白序列界定 token 邊界即足夠。
  final urlPattern = RegExp(r'https?://\S+', caseSensitive: false);
  return message.replaceAllMapped(urlPattern, (m) => sanitizeUrl(m.group(0)!));
}

/// 把檔案路徑內的 home 段 username 換成 `***`，避免 log 洩漏使用者名稱。
///
/// - Windows：`C:\Users\<name>\...` → `C:\Users\***\...`（drive letter 大小寫不敏感）
/// - macOS：`/Users/<name>/...` → `/Users/***/...`
/// - Linux：`/home/<name>/...` → `/home/***/...`
/// - 其他路徑（如 `C:\Tools\...`、`/tmp/...`）原樣返回。
String sanitizeFsPath(String raw) {
  // 三種 home prefix 各對一個 anchored regex；group(1) = prefix（保留），group(2) = username（換成 ***）
  for (final re in [
    RegExp(r'^([A-Za-z]:\\Users\\)([^\\]+)'),
    RegExp(r'^(/Users/)([^/]+)'),
    RegExp(r'^(/home/)([^/]+)'),
  ]) {
    if (re.hasMatch(raw)) {
      return raw.replaceFirstMapped(re, (m) => '${m.group(1)}***');
    }
  }
  return raw;
}

/// 把攔到的喚取 body JSON 脫敏後輸出，供 log 使用。
///
/// playerId 走 [sanitizeUid]；recordId / serverId / cardPoolId 等 hash 走前 4 後 4
/// 遮罩；languageCode / cardPoolType 等非敏感欄位原樣保留。非 JSON 物件時回
/// `<malformed credential>`，避免原文（含 playerId）漏進 log。
String sanitizeCredential(String bodyJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(bodyJson);
  } catch (_) {
    return '<malformed credential>';
  }
  if (decoded is! Map<String, dynamic>) {
    return '<malformed credential>';
  }
  const hashKeys = {'recordId', 'serverId', 'cardPoolId'};
  final out = <String, dynamic>{};
  decoded.forEach((key, value) {
    if (key == 'playerId' && value is String) {
      out[key] = sanitizeUid(value);
    } else if (hashKeys.contains(key) && value is String) {
      out[key] = _maskHash(value);
    } else {
      out[key] = value;
    }
  });
  return jsonEncode(out);
}

/// hash 字串遮罩：保留前 4 後 4，中段以 `****` 取代；長度 < 9 全遮 `***`。
String _maskHash(String raw) {
  if (raw.length < 9) return '***';
  return '${raw.substring(0, 4)}****${raw.substring(raw.length - 4)}';
}
