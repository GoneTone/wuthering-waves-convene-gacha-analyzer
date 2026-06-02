import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_cache_usage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';

void main() {
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('item_image_usage_');
    container = ProviderContainer(
      overrides: [itemImageCacheDirProvider.overrideWithValue(tempDir)],
    );
    addTearDown(container.dispose);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> touch(String name, int size) async {
    final f = File('${tempDir.path}/$name');
    await f.writeAsBytes(List<int>.filled(size, 0));
  }

  test('空目錄 → 0 / 0', () async {
    final usage = await container.read(itemImageCacheUsageProvider.future);
    expect(usage.iconBytes, 0);
    expect(usage.illustrationBytes, 0);
    expect(usage.totalBytes, 0);
  });

  test('只 icon', () async {
    await touch('1211_icon.png', 1234);
    await touch('1601_icon.jpg', 4321);
    final usage = await container.read(itemImageCacheUsageProvider.future);
    expect(usage.iconBytes, 1234 + 4321);
    expect(usage.illustrationBytes, 0);
  });

  test('只 illustration', () async {
    await touch('1211_illustration.png', 5000);
    final usage = await container.read(itemImageCacheUsageProvider.future);
    expect(usage.iconBytes, 0);
    expect(usage.illustrationBytes, 5000);
  });

  test('混合 + 其他檔被忽略', () async {
    await touch('1211_icon.png', 100);
    await touch('1211_illustration.webp', 200);
    await touch('item_image_index.json', 999);
    await touch('readme.txt', 50);
    final usage = await container.read(itemImageCacheUsageProvider.future);
    expect(usage.iconBytes, 100);
    expect(usage.illustrationBytes, 200);
    expect(usage.totalBytes, 300);
  });

  test('cache 目錄不存在 → 0 / 0（不拋例外）', () async {
    await tempDir.delete(recursive: true);
    final usage = await container.read(itemImageCacheUsageProvider.future);
    expect(usage.iconBytes, 0);
    expect(usage.illustrationBytes, 0);
  });
}
