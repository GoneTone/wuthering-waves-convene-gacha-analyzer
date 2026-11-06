import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

/// 執行外部程式；測試以替身取代 [Process.run]。
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// 常見 root 工具放 `su` 的位置。
const defaultSuPaths = [
  '/system/bin/su',
  '/system/xbin/su',
  '/sbin/su',
  '/su/bin/su',
  '/debug_ramdisk/su',
  '/system_ext/bin/su',
];

/// `su` 執行失敗（被拒絕或非 0 結束）。
class RootShellException implements Exception {
  /// 建立例外。
  RootShellException(this.message);

  /// 失敗原因。
  final String message;

  @override
  String toString() => 'RootShellException: $message';
}

/// 用 `su -c` 以 root 執行指令。
class RootShell {
  /// 建立 root shell；[run] 與 [suPaths] 僅供測試替換。
  RootShell({ProcessRunner? run, this.suPaths = defaultSuPaths})
    : _run = run ?? _defaultRun;

  /// 檢查 `su` 是否存在的路徑。
  final List<String> suPaths;

  /// 執行外部程式的函式。
  final ProcessRunner _run;

  /// 本類別的 logger。
  static final _log = Logger('capture.android');

  /// 預設的 [ProcessRunner]：stdout 保留原始位元組。
  static Future<ProcessResult> _defaultRun(String exe, List<String> args) =>
      Process.run(exe, args, stdoutEncoding: null);

  /// 裝置上是否有 `su` 執行檔；沒有時不呼叫 `su`，避免沒有 root 的裝置多等一次逾時。
  Future<bool> isSuPresent() async {
    for (final path in suPaths) {
      if (await File(path).exists()) return true;
    }
    return false;
  }

  /// 執行 `su -c id` 確認拿得到 root（會跳出 root 工具的授權詢問）。
  Future<bool> verify() async {
    try {
      final r = await _run('su', ['-c', 'id']);
      final out = r.stdout is List<int>
          ? utf8.decode(r.stdout as List<int>, allowMalformed: true)
          : '${r.stdout}';
      final ok = r.exitCode == 0 && out.contains('uid=0');
      _log.info('root verify ok=$ok exit=${r.exitCode}');
      return ok;
    } catch (e) {
      _log.info('root verify failed error=${e.runtimeType}');
      return false;
    }
  }

  /// 以 root 執行 [command]，回傳 stdout 原始位元組；非 0 結束時丟 [RootShellException]。
  Future<Uint8List> exec(String command) async {
    final r = await _run('su', ['-c', command]);
    if (r.exitCode != 0) {
      throw RootShellException('su exited with ${r.exitCode}');
    }
    final out = r.stdout;
    return out is List<int>
        ? Uint8List.fromList(out)
        : Uint8List.fromList(utf8.encode('$out'));
  }
}
