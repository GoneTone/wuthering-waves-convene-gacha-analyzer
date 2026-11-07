/// 符合 `vX.Y.Z` 或 `vX.Y.Z-rc.N` 的 release tag 格式。
final _tagPattern = RegExp(r'^v(\d+)\.(\d+)\.(\d+)(?:-rc\.(\d+))?$');

/// 正式版的尾碼，使其永遠大於同版本的任何 rc。
const _releaseSuffix = 99;

/// 將 release tag 換算為 Play 的 versionCode：`MAJOR*1000000 + MINOR*10000 + PATCH*100 + 尾碼`。
///
/// 正式版尾碼為 99，`-rc.N` 尾碼為 N（1..98）；格式不合或超出範圍時拋 [FormatException]。
int androidVersionCodeForTag(String tag) {
  final m = _tagPattern.firstMatch(tag);
  if (m == null) throw FormatException('Invalid release tag', tag);
  final major = int.parse(m[1]!);
  final minor = int.parse(m[2]!);
  final patch = int.parse(m[3]!);
  final rc = m[4] == null ? null : int.parse(m[4]!);
  final suffix = rc ?? _releaseSuffix;
  if (major < 1 ||
      minor > 99 ||
      patch > 99 ||
      (rc != null && (rc < 1 || rc >= _releaseSuffix))) {
    throw FormatException('Release tag out of range', tag);
  }
  return major * 1000000 + minor * 10000 + patch * 100 + suffix;
}

/// 由 Play versionCode 反推 release tag；無法由 [androidVersionCodeForTag] 產生者回傳 null。
String? tagForAndroidVersionCode(int code) {
  final major = code ~/ 1000000;
  final suffix = code % 100;
  if (major < 1 || suffix == 0) return null;
  final base = 'v$major.${code ~/ 10000 % 100}.${code ~/ 100 % 100}';
  return suffix == _releaseSuffix ? base : '$base-rc.$suffix';
}
