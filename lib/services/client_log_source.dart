import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// Client.log 某一刻的長度與檔案識別。
///
/// [id] 用來判斷遊戲是否換了新檔（舊檔改名成 `Client-backup-*.log`、另開新檔）；
/// 讀不到時為 null，代表「無法判斷」，只能退回用長度變短判斷。
typedef ClientLogProbe = ({int length, String? id});

/// 提供 Client.log 的長度、檔案識別與指定範圍的原始（未解碼）位元組。
abstract interface class ClientLogSource {
  /// 檔案目前的長度與識別；檔案不存在時長度為 0、識別為 null。
  Future<ClientLogProbe> probe();

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
  Future<ClientLogProbe> probe() async {
    final file = File(path);
    if (!await file.exists()) return (length: 0, id: null);
    final length = await file.length();
    if (length < clientLogHeaderBytes) return (length: length, id: null);
    // 遊戲每個新檔開頭都是精確到秒的「Log file open, [時間]」，用檔頭當識別（shell 來源用它的雜湊）。
    return (
      length: length,
      id: base64.encode(await read(0, clientLogHeaderBytes)),
    );
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
    required this.path,
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
  Future<ClientLogProbe> probe() async {
    final out = utf8.decode(
      await _exec(clientLogProbeCommand(path)),
      allowMalformed: true,
    );
    // 檔案不存在時指令本身印 0；空的或看不懂的輸出是讀取出錯，若當成 0 會被誤判為 log 輪替而從頭重讀。
    final parts = out.trim().split(' ');
    final length = int.parse(parts.first);
    return (
      length: length,
      id:
          length >= clientLogHeaderBytes &&
              parts.length > 1 &&
              parts[1].isNotEmpty
          ? parts[1]
          : null,
    );
  }

  @override
  Future<Uint8List> read(int offset, int length) =>
      _exec(clientLogReadCommand(path, offset, length));
}

/// 用來當識別的檔頭長度（涵蓋「Log file open, [時間]」整行）。
const int clientLogHeaderBytes = 48;

/// 產生一次取得 [path] 長度與檔頭雜湊的 shell 指令；檔案不存在時只印 0。
///
/// 不用 inode：實機上遊戲換檔後新 `Client.log` 沿用舊 inode（舊內容的 backup 反而是新 inode）。
String clientLogProbeCommand(String path) {
  _checkPath(path);
  return "s=\$(stat -c %s '$path' 2>/dev/null) && "
      "echo \"\$s \$(head -c $clientLogHeaderBytes '$path' | md5sum)\" || echo 0";
}

/// 產生讀取 [path] 自 [offset] 起 [length] 位元組的 shell 指令。
String clientLogReadCommand(String path, int offset, int length) {
  _checkPath(path);
  if (offset < 0) throw ArgumentError.value(offset, 'offset');
  if (length <= 0) throw ArgumentError.value(length, 'length');
  return "tail -c +${offset + 1} '$path' | head -c $length";
}

/// 產生「[path] 不存在時列出 [dataDir] 底下的 `.log` 檔」的 shell 指令；檔案存在時沒有輸出。
///
/// 用來確認沒見過的版本 log 放在哪裡（例如 Galaxy Store 版），只列路徑、不讀內容。
String clientLogMissingCommand(String path, String dataDir) {
  _checkPath(path);
  _checkPath(dataDir);
  return "[ -e '$path' ] || "
      "find '$dataDir' -maxdepth 6 -name '*.log' 2>&1 | head -n 10";
}

/// 路徑會被單引號包住，不允許含單引號以免跳出字串。
void _checkPath(String path) {
  if (path.contains("'")) throw ArgumentError.value(path, 'path');
}
