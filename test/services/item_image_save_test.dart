import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_save.dart';

void main() {
  final png = Uint8List.fromList([1, 2, 3, 4]);

  tearDown(resetItemImageSaveSeams);

  test('saveImagePng：使用者選了路徑 → 寫檔並回實際路徑', () async {
    final tmp = '${Directory.systemTemp.path}/item_save_a.png';
    itemImageSaveLocationPicker = (name) async => FileSaveLocation(tmp);

    final saved = await saveImagePng(png, suggestedName: 'a.png');

    expect(saved, tmp);
    expect(await File(tmp).readAsBytes(), png);
    await File(tmp).delete();
  });

  test('saveImagePng：使用者取消 → 回 null、不寫檔', () async {
    itemImageSaveLocationPicker = (name) async => null;

    final saved = await saveImagePng(png, suggestedName: 'a.png');

    expect(saved, isNull);
  });

  test('copyImagePngToClipboard：clipboard 成功 → 回 true', () async {
    Uint8List? captured;
    itemImageClipboardWriter = (bytes) async {
      captured = bytes;
      return true;
    };

    final ok = await copyImagePngToClipboard(png);

    expect(ok, isTrue);
    expect(captured, png);
  });

  test('copyImagePngToClipboard：clipboard 不支援 → 回 false', () async {
    itemImageClipboardWriter = (bytes) async => false;

    final ok = await copyImagePngToClipboard(png);

    expect(ok, isFalse);
  });

  testWidgets('encodeImageFileToPng：可解碼圖 → 回非空 PNG bytes', (tester) async {
    await tester.runAsync(() async {
      final src = img.Image(width: 2, height: 2);
      final srcBytes = Uint8List.fromList(img.encodePng(src));
      final f = File('${Directory.systemTemp.path}/item_encode_a.png');
      await f.writeAsBytes(srcBytes);

      final out = await encodeImageFileToPng(f);

      expect(out, isNotNull);
      expect(out!.isNotEmpty, isTrue);
      expect(out.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      await f.delete();
    });
  });

  testWidgets('encodeImageFileToPng：不可解碼檔 → 回 null', (tester) async {
    await tester.runAsync(() async {
      final f = File('${Directory.systemTemp.path}/item_encode_bad.bin');
      await f.writeAsBytes([1, 2, 3, 4]);

      final out = await encodeImageFileToPng(f);

      expect(out, isNull);
      await f.delete();
    });
  });
}
