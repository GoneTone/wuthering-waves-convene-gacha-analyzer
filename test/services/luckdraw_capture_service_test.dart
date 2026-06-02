import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/luckdraw_capture_service.dart';

void main() {
  late Directory tempDir;
  late LuckdrawCaptureService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('luckdraw_cap_test_');
    service = LuckdrawCaptureService(cacheDir: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('cache hit：檔已存在直接回傳，毋須 webview', () async {
    final f = itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1211);
    await f.writeAsBytes([1, 2, 3]);
    final got = await service.capture(
      resourceId: 1211,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
    );
    expect(got?.path, f.path);
  });

  test('host 未就緒（webview 未 attach）→ 回 null', () async {
    final got = await service.capture(
      resourceId: 9999,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
    );
    expect(got, isNull);
  });

  test('cacheFileFor：<id>_luckdraw.png', () {
    expect(
      service.cacheFileFor(1211).path,
      itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1211).path,
    );
  });
}
