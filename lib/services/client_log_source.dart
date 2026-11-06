import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// Android 國際服鳴潮 `Client.log` 的固定路徑。
const String androidClientLogPath =
    '/sdcard/Android/data/com.kurogame.wutheringwaves.global/files/UE4Game/'
    'Client/Client/Saved/Logs/Client.log';

/// 提供 Client.log 的長度與指定範圍的原始（未解碼）位元組。
abstract interface class ClientLogSource {
  /// 檔案目前長度；檔案不存在時回 0。
  Future<int> length();

  /// 讀取 [offset] 起最多 [length] 個位元組。
  Future<Uint8List> read(int offset, int length);

  /// 寫進 log 用的來源描述（已脫敏）。
  String get logLabel;
}

/// 直接用 [File] 讀本機路徑的 [ClientLogSource]（電腦版、Android 10 以下）。
class LocalFileLogSource implements ClientLogSource {
  /// 建立讀取 [path] 的來源。
  LocalFileLogSource(this.path);

  /// Client.log 的完整路徑。
  final String path;

  @override
  String get logLabel => sanitizeFsPath(path);

  @override
  Future<int> length() async {
    final file = File(path);
    return await file.exists() ? file.length() : 0;
  }

  @override
  Future<Uint8List> read(int offset, int length) async {
    final raf = await File(path).open();
    try {
      await raf.setPosition(offset);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }
}

/// 執行一條 shell 指令並回傳 stdout 原始位元組。
typedef ShellExec = Future<Uint8List> Function(String command);

/// 透過 shell（root 的 `su` 或無線偵錯的 shell 串流）讀檔的 [ClientLogSource]。
class ShellLogSource implements ClientLogSource {
  /// 建立來源；[exec] 執行指令，[label] 寫進 log 用。
  ShellLogSource({
    required ShellExec exec,
    this.path = androidClientLogPath,
    String label = 'shell',
  }) : _exec = exec,
       _label = label;

  /// 執行 shell 指令的函式。
  final ShellExec _exec;

  /// 寫進 log 的來源名稱。
  final String _label;

  /// Client.log 的完整路徑。
  final String path;

  @override
  String get logLabel => _label;

  @override
  Future<int> length() async {
    final out = utf8.decode(
      await _exec(clientLogLengthCommand(path)),
      allowMalformed: true,
    );
    // 檔案不存在時 stat 只輸出錯誤（stdout 為空），視為長度 0。
    return int.tryParse(out.trim()) ?? 0;
  }

  @override
  Future<Uint8List> read(int offset, int length) =>
      _exec(clientLogReadCommand(path, offset, length));
}

/// 產生取得 [path] 長度的 shell 指令。
String clientLogLengthCommand(String path) {
  _checkPath(path);
  return "stat -c %s '$path'";
}

/// 產生讀取 [path] 自 [offset] 起 [length] 位元組的 shell 指令。
String clientLogReadCommand(String path, int offset, int length) {
  _checkPath(path);
  if (offset < 0) throw ArgumentError.value(offset, 'offset');
  if (length <= 0) throw ArgumentError.value(length, 'length');
  return "tail -c +${offset + 1} '$path' | head -c $length";
}

/// 路徑會被單引號包住，不允許含單引號以免跳出字串。
void _checkPath(String path) {
  if (path.contains("'")) throw ArgumentError.value(path, 'path');
}
