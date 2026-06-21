import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 分享圖匯出流程的 logger（命名空間 share.image）。
final _log = Logger('share.image');

/// 預設剪貼簿寫入：寫 PNG 到系統剪貼簿，回傳是否成功
/// （平台不支援時回傳 false）。
/// 平台原生路徑；unit test 以 [shareClipboardWriter] seam 取代覆蓋（flutter test 環境 SystemClipboard.instance 為 null）。
Future<bool> _defaultClipboardWriter(Uint8List png) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return false;
  final item = DataWriterItem();
  item.add(Formats.png(png));
  await clipboard.write([item]);
  return true;
}

/// 預設存檔位置選擇器：開啟系統 save dialog，回傳使用者選擇的路徑（取消為 null）。
Future<FileSaveLocation?> _defaultSaveLocationPicker(String name) =>
    getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG', extensions: ['png']),
      ],
    );

/// 存檔位置選擇器 seam，讓 flutter test 不開啟真實系統 dialog。
@visibleForTesting
Future<FileSaveLocation?> Function(String suggestedName)
shareSaveLocationPicker = _defaultSaveLocationPicker;

/// 剪貼簿寫入 seam，讓 flutter test 不碰真實剪貼簿（SystemClipboard.instance 為 null）。
@visibleForTesting
Future<bool> Function(Uint8List png) shareClipboardWriter =
    _defaultClipboardWriter;

/// 檔案寫入 seam，讓 flutter test 不碰真實 FS。
@visibleForTesting
Future<void> Function(String path, Uint8List png) shareFileWriter =
    _defaultFileWriter;

/// 預設檔案寫入實作：直接寫入磁碟。
Future<void> _defaultFileWriter(String path, Uint8List png) =>
    File(path).writeAsBytes(png);

/// 將所有 seam 重設為預設實作，供 tearDown 使用。
@visibleForTesting
void resetShareImageExportSeams() {
  shareSaveLocationPicker = _defaultSaveLocationPicker;
  shareClipboardWriter = _defaultClipboardWriter;
  shareFileWriter = _defaultFileWriter;
}

/// 讓使用者選位置存 PNG。成功回**實際存檔路徑**（供呼叫端顯示完整路徑）；
/// 使用者取消回 null（非錯誤）；已選路徑但寫檔失敗記 severe log 後 rethrow。
Future<String?> saveShareImage(
  Uint8List png, {
  required String suggestedName,
}) async {
  final loc = await shareSaveLocationPicker(suggestedName);
  if (loc == null) {
    _log.info('share image save cancelled');
    return null;
  }
  try {
    await shareFileWriter(loc.path, png);
  } catch (e, st) {
    _log.severe('share image write failed ${sanitizeFsPath(loc.path)}', e, st);
    rethrow;
  }
  _log.info(
    'share image saved ${sanitizeFsPath(loc.path)}; bytes=${png.length}',
  );
  return loc.path;
}

/// 把 PNG 寫入系統剪貼簿。成功回 true；平台不支援回 false；例外記 warning 後回 false。
Future<bool> copyShareImage(Uint8List png) async {
  try {
    final ok = await shareClipboardWriter(png);
    _log.info('share image copy clipboard=$ok bytes=${png.length}');
    return ok;
  } catch (e, st) {
    _log.warning('share image copy failed', e, st);
    return false;
  }
}
