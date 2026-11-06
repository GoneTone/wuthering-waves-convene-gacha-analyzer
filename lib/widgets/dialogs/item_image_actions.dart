import 'dart:io';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/file_access.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_save.dart';

/// 物品圖選單動作的 logger（命名空間 gacha.itemimage.save）。
final _log = Logger('gacha.itemimage.save');

/// 物品圖選單項目（複製圖片 / 儲存圖片 /（[share] 為 true 時）分享）；
/// 詳情對話框與看圖 overlay 共用。
List<PopupMenuEntry<String>> itemImageMenuItems(
  AppLocalizations l, {
  required bool share,
}) => [
  _menuItem('copy', Icons.copy, l.actionCopyImage),
  _menuItem('save', Icons.save_alt, l.actionSaveImage),
  if (share) _menuItem('share', Icons.share, l.actionShare),
];

/// 建立單一選單項目。
PopupMenuItem<String> _menuItem(String value, IconData icon, String title) =>
    PopupMenuItem(
      value: value,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: 20),
        title: Text(title),
      ),
    );

/// 執行 [itemImageMenuItems] 的選項（`copy`／`save`／`share`，其他值不處理）：
/// 把 [file] 轉成 PNG 後複製、存檔或分享，結果以 [toast] 回報，並記一行 info log。
///
/// [toast] 會在非同步完成後才被呼叫，呼叫端需自行確認 widget 仍 mounted。
Future<void> runItemImageAction(
  String value, {
  required File file,
  required String suggestedName,
  required AppLocalizations l,
  required void Function(String message) toast,
}) async {
  if (value != 'copy' && value != 'save' && value != 'share') return;
  final outcome = await _perform(
    value,
    file: file,
    suggestedName: suggestedName,
    l: l,
    toast: toast,
  );
  _log.info('item image action=$value name=$suggestedName outcome=$outcome');
}

/// 實際執行 [runItemImageAction] 的動作，回傳結果 `ok`／`cancelled`／`failed`。
Future<String> _perform(
  String value, {
  required File file,
  required String suggestedName,
  required AppLocalizations l,
  required void Function(String message) toast,
}) async {
  final png = await encodeImageFileToPng(file);
  if (png == null) {
    _log.warning('$value encode failed name=$suggestedName');
    toast(switch (value) {
      'copy' => l.itemImageCopyFailed,
      'save' => l.itemImageSaveFailed,
      _ => l.shareFailed,
    });
    return 'failed';
  }
  switch (value) {
    case 'copy':
      final ok = await copyPngToClipboard(png);
      toast(ok ? l.itemImageCopied : l.itemImageCopyFailed);
      return ok ? 'ok' : 'failed';
    case 'save':
      try {
        final saved = await saveBytes(
          png,
          suggestedName: suggestedName,
          extension: 'png',
          mimeType: 'image/png',
          dialogTitle: l.dialogSaveAsTitle,
        );
        if (saved == null) return 'cancelled';
        toast(l.itemImageSavedTo(saved.path ?? saved.displayName));
        return 'ok';
      } catch (_) {
        toast(l.itemImageSaveFailed);
        return 'failed';
      }
    default:
      final ok = await shareBytes(
        png,
        fileName: suggestedName,
        mimeType: 'image/png',
      );
      if (!ok) toast(l.shareFailed);
      return ok ? 'ok' : 'failed';
  }
}
