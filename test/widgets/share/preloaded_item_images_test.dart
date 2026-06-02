import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/share/preloaded_item_images.dart';

void main() {
  test('preload key 為 int resourceId；無 icon 的 record 跳過', () async {
    final tempDir = await Directory.systemTemp.createTemp('preload_test_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    });
    // 空 index → 任何 record 都無 icon → 回空 map
    const index = ItemImageIndex.empty();
    final out = await preloadItemImages(
      index: index,
      cacheDir: tempDir,
      records: [
        GachaRecord(
          resourceId: 111,
          qualityLevel: 5,
          resourceType: '角色',
          cardPoolType: '1',
          name: 'x',
          count: 1,
          time: DateTime(2026),
        ),
      ],
    );
    expect(out, isEmpty);
  });
}
