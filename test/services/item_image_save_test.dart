import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_save.dart';

void main() {
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
