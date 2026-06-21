import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/share_image_export.dart';

void main() {
  final png = Uint8List.fromList([1, 2, 3, 4]);

  tearDown(resetShareImageExportSeams);

  group('saveShareImage', () {
    test('選了路徑 → 寫檔並回傳實際路徑', () async {
      final tmp = '${Directory.systemTemp.path}/share_save_a.png';
      shareSaveLocationPicker = (name) async => FileSaveLocation(tmp);

      final path = await saveShareImage(png, suggestedName: 'a.png');

      expect(path, tmp);
      expect(await File(tmp).readAsBytes(), png);
      await File(tmp).delete();
    });

    test('使用者取消 → 回傳 null', () async {
      shareSaveLocationPicker = (name) async => null;

      final path = await saveShareImage(png, suggestedName: 'a.png');

      expect(path, isNull);
    });

    test('已選路徑但寫檔失敗 → rethrow', () async {
      shareSaveLocationPicker = (name) async => FileSaveLocation('x.png');
      shareFileWriter = (p, bytes) async =>
          throw const FileSystemException('boom');

      await expectLater(
        () => saveShareImage(png, suggestedName: 'a.png'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('copyShareImage', () {
    test('剪貼簿成功 → true', () async {
      shareClipboardWriter = (bytes) async => true;
      expect(await copyShareImage(png), isTrue);
    });

    test('平台不支援 → false', () async {
      shareClipboardWriter = (bytes) async => false;
      expect(await copyShareImage(png), isFalse);
    });

    test('剪貼簿例外 → false（吞掉）', () async {
      shareClipboardWriter = (bytes) async => throw Exception('boom');
      expect(await copyShareImage(png), isFalse);
    });
  });
}
