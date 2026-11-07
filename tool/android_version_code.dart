import 'dart:io';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android_version_code.dart';

/// 由 release tag 印出 Android 建置用的 `VERSION_CODE` 與 `BUILD_NAME`，供 CI 寫入 `GITHUB_ENV`。
///
/// 用法：`dart run tool/android_version_code.dart v1.9.0-rc.2`
void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/android_version_code.dart <tag>');
    exitCode = 64;
    return;
  }
  try {
    stdout.writeln('VERSION_CODE=${androidVersionCodeForTag(args[0])}');
    stdout.writeln('BUILD_NAME=${args[0].substring(1)}');
  } on FormatException catch (e) {
    stderr.writeln('${e.message}: ${e.source}');
    exitCode = 1;
  }
}
