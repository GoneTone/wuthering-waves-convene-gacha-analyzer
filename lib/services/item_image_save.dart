import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 物品圖片編碼流程的 logger（命名空間 gacha.itemimage.save）。
final _log = Logger('gacha.itemimage.save');

/// 把任意格式的本地圖檔解碼後重新編碼成 PNG bytes；任何失敗（讀檔／解碼／編碼）
/// 回 null，呼叫端據此提示失敗。
///
/// 統一輸出 PNG：來源可能是 webp／jpg（icon／造型副檔名隨 URL），轉 PNG 後
/// 存檔、分享與複製到剪貼簿格式一致。
///
/// 呼叫端應使用此函式而非直接呼叫 [itemImageEncoder]；內部透過 seam 讓測試可替換。
Future<Uint8List?> encodeImageFileToPng(File file) => itemImageEncoder(file);

/// 底層 PNG 編碼實作；[encodeImageFileToPng] 的真實預設。
Future<Uint8List?> _defaultEncoder(File file) async {
  try {
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (data == null) {
      _log.warning('encode png null path=${sanitizeFsPath(file.path)}');
      return null;
    }
    return data.buffer.asUint8List();
  } catch (e, st) {
    _log.warning('encode png failed path=${sanitizeFsPath(file.path)}', e, st);
    return null;
  }
}

/// 圖檔編碼 seam，讓 flutter test 繞過 ui.instantiateImageCodec（需 runAsync 才能完成）。
/// 預設使用 [_defaultEncoder]；測試可替換成同步返回假資料的 stub。
/// 呼叫端請用 [encodeImageFileToPng]，勿直接呼叫此 seam。
@visibleForTesting
Future<Uint8List?> Function(File file) itemImageEncoder = _defaultEncoder;

/// 將編碼 seam 重設為預設實作，供 tearDown 使用。
@visibleForTesting
void resetItemImageSaveSeams() {
  itemImageEncoder = _defaultEncoder;
}
