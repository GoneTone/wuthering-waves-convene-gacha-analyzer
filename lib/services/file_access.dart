import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 檔案存取（存檔／分享／剪貼簿／選檔）流程的 logger。
final _log = Logger('io.file');

/// 存檔結果：[displayName] 給成功訊息顯示；[path] 只在桌面有值。
class SavedFile {
  /// 建立存檔結果。
  const SavedFile({required this.displayName, this.path});

  /// 顯示給使用者看的檔名。
  final String displayName;

  /// 桌面的實際檔案路徑；Android 為 null。
  final String? path;
}

/// 開啟系統存檔對話框並寫入 bytes，回傳 file_picker 給的原始字串（取消為 null）。
typedef FileSaveDialog =
    Future<String?> Function(
      Uint8List bytes,
      String suggestedName,
      String extension,
      String mimeType,
      String? dialogTitle,
    );

/// 開啟系統選檔對話框並回傳檔案內容（取消為 null）。
typedef FileOpenDialog =
    Future<Uint8List?> Function(List<String>? extensions, String? dialogTitle);

/// 開啟系統選資料夾對話框並回傳路徑（取消為 null）。
typedef DirectoryDialog = Future<String?> Function(String? dialogTitle);

/// 以系統分享面板分享 bytes。
typedef FileSharer =
    Future<void> Function(Uint8List bytes, String fileName, String mimeType);

/// 預設存檔對話框：桌面回傳選擇路徑；Android 回傳 content Uri 去掉 scheme 的路徑
/// （如 `/document/primary:Download/a.json`）。
Future<String?> _defaultSaveDialog(
  Uint8List bytes,
  String suggestedName,
  String extension,
  String mimeType,
  String? dialogTitle,
) => FilePicker.saveFile(
  dialogTitle: dialogTitle,
  fileName: suggestedName,
  bytes: bytes,
  type: FileType.custom,
  allowedExtensions: [extension],
  lockParentWindow: true,
);

/// 預設選檔對話框；拿不到 bytes 時退回讀 path。
Future<Uint8List?> _defaultOpenDialog(
  List<String>? extensions,
  String? dialogTitle,
) async {
  final result = await FilePicker.pickFiles(
    dialogTitle: dialogTitle,
    type: extensions == null ? FileType.any : FileType.custom,
    allowedExtensions: extensions,
    withData: true,
    lockParentWindow: true,
  );
  final file = result?.files.single;
  if (file == null) return null;
  final path = file.path;
  final bytes =
      file.bytes ?? (path == null ? null : await File(path).readAsBytes());
  await _clearPickerCache();
  return bytes;
}

/// 清掉 Android 上 file_picker 複製進 cache 的選檔殘留（即使 withData 也會複製）。
///
/// 只在 Android 呼叫：其他平台的 platform 預設實作會丟 UnimplementedError。失敗只記 warning。
Future<void> _clearPickerCache() async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await FilePicker.clearTemporaryFiles();
  } catch (e, st) {
    _log.warning('clear picker cache failed', e, st);
  }
}

/// 預設選資料夾對話框。
Future<String?> _defaultDirectoryDialog(String? dialogTitle) =>
    FilePicker.getDirectoryPath(
      dialogTitle: dialogTitle,
      lockParentWindow: true,
    );

/// 預設分享：以記憶體檔案交給 share_plus。
Future<void> _defaultSharer(
  Uint8List bytes,
  String fileName,
  String mimeType,
) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(bytes, name: fileName, mimeType: mimeType)],
      fileNameOverrides: [fileName],
    ),
  );
}

/// 預設剪貼簿寫入：寫 PNG 到系統剪貼簿，平台不支援回 false。
Future<bool> _defaultClipboardWriter(Uint8List png) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return false;
  final item = DataWriterItem();
  item.add(Formats.png(png));
  await clipboard.write([item]);
  return true;
}

/// 存檔對話框 seam，讓測試不開真實對話框。
@visibleForTesting
FileSaveDialog fileSaveDialog = _defaultSaveDialog;

/// 選檔對話框 seam。
@visibleForTesting
FileOpenDialog fileOpenDialog = _defaultOpenDialog;

/// 選資料夾對話框 seam。
@visibleForTesting
DirectoryDialog directoryDialog = _defaultDirectoryDialog;

/// 分享 seam。
@visibleForTesting
FileSharer fileSharer = _defaultSharer;

/// PNG 剪貼簿寫入 seam。
@visibleForTesting
Future<bool> Function(Uint8List png) pngClipboardWriter =
    _defaultClipboardWriter;

/// 將所有 seam 重設為預設實作，供 tearDown 使用。
@visibleForTesting
void resetFileAccessSeams() {
  fileSaveDialog = _defaultSaveDialog;
  fileOpenDialog = _defaultOpenDialog;
  directoryDialog = _defaultDirectoryDialog;
  fileSharer = _defaultSharer;
  pngClipboardWriter = _defaultClipboardWriter;
}

/// 讓使用者選位置存檔。取消回 null；寫入失敗記 severe 後 rethrow。
Future<SavedFile?> saveBytes(
  Uint8List bytes, {
  required String suggestedName,
  required String extension,
  required String mimeType,
  String? dialogTitle,
}) async {
  final String? saved;
  try {
    saved = await fileSaveDialog(
      bytes,
      suggestedName,
      extension,
      mimeType,
      dialogTitle,
    );
  } catch (e, st) {
    _log.severe('save failed name=$suggestedName mime=$mimeType', e, st);
    rethrow;
  }
  if (saved == null) {
    _log.info('save cancelled name=$suggestedName');
    return null;
  }
  final displayName = displayNameForSavedPath(
    saved,
    suggestedName: suggestedName,
    extension: extension,
  );
  // 服務層沒有 Riverpod ref，無法讀 isAndroidProvider；兩者在正式環境一致。
  final isAndroid = defaultTargetPlatform == TargetPlatform.android;
  _log.info(
    'save ok name=$displayName ${isAndroid ? '' : 'path=${sanitizeFsPath(saved)} '}bytes=${bytes.length}',
  );
  return SavedFile(displayName: displayName, path: isAndroid ? null : saved);
}

/// 從存檔結果字串取出顯示檔名（最後一個分隔符之後）；副檔名不符
/// （如 Downloads provider 的 `/document/msf:1234`）時退回 [suggestedName]。
String displayNameForSavedPath(
  String saved, {
  required String suggestedName,
  required String extension,
}) {
  final name = saved.substring(saved.lastIndexOf(RegExp(r'[/\\]')) + 1);
  return name.toLowerCase().endsWith('.${extension.toLowerCase()}')
      ? name
      : suggestedName;
}

/// 以系統分享面板分享 bytes；使用者關掉面板也算成功，例外記 warning 回 false。
Future<bool> shareBytes(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
}) async {
  try {
    await fileSharer(bytes, fileName, mimeType);
    _log.info('share ok name=$fileName mime=$mimeType bytes=${bytes.length}');
    return true;
  } catch (e, st) {
    _log.warning('share failed name=$fileName mime=$mimeType', e, st);
    return false;
  }
}

/// 把 PNG 寫入系統剪貼簿。成功回 true；平台不支援回 false；例外記 warning 後回 false。
Future<bool> copyPngToClipboard(Uint8List png) async {
  try {
    final ok = await pngClipboardWriter(png);
    _log.info('copy png clipboard=$ok bytes=${png.length}');
    return ok;
  } catch (e, st) {
    _log.warning('copy png failed', e, st);
    return false;
  }
}

/// 讓使用者選檔並回傳內容；取消回 null。
Future<Uint8List?> pickFileBytes({
  List<String>? extensions,
  String? dialogTitle,
}) async {
  final bytes = await fileOpenDialog(extensions, dialogTitle);
  _log.info(
    bytes == null
        ? 'pick file cancelled'
        : 'pick file ok bytes=${bytes.length}',
  );
  return bytes;
}

/// 讓使用者選文字檔並以 UTF-8 解碼；取消回 null，不合法 UTF-8 丟 [FormatException]。
Future<String?> pickTextFile({
  required List<String> extensions,
  String? dialogTitle,
}) async {
  final bytes = await pickFileBytes(
    extensions: extensions,
    dialogTitle: dialogTitle,
  );
  if (bytes == null) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException catch (e, st) {
    _log.warning(
      'pick text file is not valid utf-8 bytes=${bytes.length}',
      e,
      st,
    );
    rethrow;
  }
}

/// 讓使用者選資料夾；取消回 null。
Future<String?> pickDirectory({String? dialogTitle}) async {
  final path = await directoryDialog(dialogTitle);
  _log.info(
    path == null
        ? 'pick directory cancelled'
        : 'pick directory ok path=${sanitizeFsPath(path)}',
  );
  return path;
}
