import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/luckdraw_capture_service.dart';

/// 假 webview：依腳本內容回應 probe／arm／分塊讀回，並記錄載入過的網址。
class _FakeEngine implements LuckdrawWebEngine {
  /// 建立假 engine；[capData] 為 null 時 probe 永遠回「尚未擷取完成」。
  /// [throwOnEvaluate] 模擬 webview 已死（renderer 被回收等）；[armsNeeded] 模擬頁面
  /// 在 arm 之後自行重載、需要再 arm 幾次才會擷取完成。
  _FakeEngine({
    this.capData,
    this.throwOnEvaluate = false,
    this.armsNeeded = 1,
  });

  /// 模擬 `window.__cap` 的 data URL；null 代表頁面一直沒有可擷取的 canvas。
  final String? capData;

  /// 每次 evaluate 都丟例外。
  final bool throwOnEvaluate;

  /// 需要 arm 的次數才會進入擷取完成狀態。
  final int armsNeeded;

  /// 已收到的 arm 次數。
  int arms = 0;

  /// 依序載入過的網址。
  final loadedUrls = <String>[];

  /// 是否已被 dispose。
  bool disposed = false;

  @override
  Future<void> loadUrl(String url) async => loadedUrls.add(url);

  @override
  Future<dynamic> evaluate(String js) async {
    if (throwOnEvaluate) throw StateError('webview gone');
    final substr = RegExp(r'__cap\.substr\((\d+),(\d+)\)').firstMatch(js);
    if (substr != null) {
      final start = int.parse(substr.group(1)!);
      final len = int.parse(substr.group(2)!);
      final data = capData!;
      return data.substring(start, (start + len).clamp(0, data.length));
    }
    if (js.contains('hasCanvas')) {
      final data = capData;
      final ready = data != null && arms >= armsNeeded;
      return jsonEncode({
        'hasCanvas': data != null,
        // 達到所需 arm 次數前，頁面每次 arm 後都會自行重載而失去旗標。
        'armed': arms >= armsNeeded,
        'capReady': ready,
        'capLen': ready ? data.length : 0,
        'cw': 1600,
        'ch': 1334,
        'dpr': 2,
        'vw': 1400,
      });
    }
    if (js.contains('__capArmed = true')) arms++;
    return 'armed';
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('luckdraw_cap_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  /// 建立服務，並以 [factory] 取代真的 headless webview。
  LuckdrawCaptureService serviceWith(
    Future<LuckdrawWebEngine?> Function() factory, {
    Duration timeout = const Duration(seconds: 30),
  }) => LuckdrawCaptureService(
    cacheDir: tempDir,
    timeout: timeout,
    engineFactory: factory,
  );

  test('cache hit：檔已存在直接回傳，不建立 webview', () async {
    var created = 0;
    final service = serviceWith(() async {
      created++;
      return null;
    });
    final f = itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1211);
    await f.writeAsBytes([1, 2, 3]);
    final got = await service.capture(
      resourceId: 1211,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
    );
    expect(got?.path, f.path);
    expect(created, 0);
  });

  test('webview 無法建立（factory 回 null）→ 回 null，且只嘗試一次', () async {
    var created = 0;
    final service = serviceWith(() async {
      created++;
      return null;
    });
    for (final rid in [9998, 9999]) {
      final got = await service.capture(
        resourceId: rid,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
      );
      expect(got, isNull);
    }
    expect(created, 1);
  });

  test('webview 建立時丟例外 → 回 null、不往外拋', () async {
    final service = serviceWith(() async => throw StateError('no platform'));
    final got = await service.capture(
      resourceId: 9999,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
    );
    expect(got, isNull);
  });

  test('並發兩次擷取 → webview 只建立一次', () async {
    var created = 0;
    final service = serviceWith(() async {
      created++;
      return _FakeEngine();
    }, timeout: const Duration(milliseconds: 900));
    final results = await Future.wait([
      service.capture(resourceId: 1, kind: kItemKindCharacter, lang: 'zh-Hant'),
      service.capture(resourceId: 2, kind: kItemKindCharacter, lang: 'zh-Hant'),
    ]);
    expect(results, [isNull, isNull]);
    expect(created, 1);
  });

  test('成功路徑：分塊讀回寫入快取，最後導回 about:blank', () async {
    final png = List<int>.generate(300000, (i) => i % 251);
    final engine = _FakeEngine(
      capData: 'data:image/png;base64,${base64Encode(png)}',
    );
    final service = serviceWith(() async => engine);
    final got = await service.capture(
      resourceId: 1508,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
    );
    expect(got, isNotNull);
    expect(await got!.readAsBytes(), png);
    expect(engine.loadedUrls.first, contains('/character/1508'));
    expect(engine.loadedUrls.last, 'about:blank');
  });

  test('force: true：檔已存在仍重新擷取（webview 無法建立故回 null）', () async {
    final service = serviceWith(() async => null);
    final f = itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1211);
    await f.writeAsBytes([1, 2, 3]);
    final got = await service.capture(
      resourceId: 1211,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
      force: true,
    );
    expect(got, isNull);
    expect(await f.readAsBytes(), [1, 2, 3]);
  });

  test('dispose 會釋放已建立的 webview', () async {
    final engine = _FakeEngine();
    final service = serviceWith(
      () async => engine,
      timeout: const Duration(milliseconds: 500),
    );
    await service.capture(
      resourceId: 1,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
    );
    await service.dispose();
    expect(engine.disposed, isTrue);
  });

  test('webview 中途死掉（evaluate 丟例外）→ 下次擷取會重建 webview', () async {
    final engines = <_FakeEngine>[];
    final service = serviceWith(() async {
      final e = _FakeEngine(
        throwOnEvaluate: engines.isEmpty,
        capData: 'data:image/png;base64,${base64Encode([0x89, 0x50])}',
      );
      engines.add(e);
      return e;
    });
    expect(
      await service.capture(
        resourceId: 1,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
      ),
      isNull,
    );
    expect(engines.first.disposed, isTrue);
    expect(
      await service.capture(
        resourceId: 1,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
      ),
      isNotNull,
    );
    expect(engines, hasLength(2));
  });

  test('建立 webview 丟例外（可能是暫時的）→ 下次擷取會再試', () async {
    var calls = 0;
    final service = serviceWith(() async {
      calls++;
      if (calls == 1) throw TimeoutException('cold start');
      return _FakeEngine(
        capData: 'data:image/png;base64,${base64Encode([0x89, 0x50])}',
      );
    });
    expect(
      await service.capture(
        resourceId: 1,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
      ),
      isNull,
    );
    expect(
      await service.capture(
        resourceId: 1,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
      ),
      isNotNull,
    );
    expect(calls, 2);
  });

  test('頁面在 arm 之後自行重載 → 依頁面狀態重新 arm 並完成擷取', () async {
    final engine = _FakeEngine(
      capData: 'data:image/png;base64,${base64Encode([0x89, 0x50])}',
      armsNeeded: 2,
    );
    final service = serviceWith(() async => engine);
    final got = await service.capture(
      resourceId: 1,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
    );
    expect(got, isNotNull);
    expect(engine.arms, 2);
  });

  test('dispose 之後不再建立 webview', () async {
    var calls = 0;
    final service = serviceWith(() async {
      calls++;
      return _FakeEngine();
    });
    await service.dispose();
    expect(
      await service.capture(
        resourceId: 1,
        kind: kItemKindCharacter,
        lang: 'zh-Hant',
      ),
      isNull,
    );
    expect(calls, 0);
  });

  test('cacheFileFor：<id>_luckdraw.png', () {
    final service = serviceWith(() async => null);
    expect(
      service.cacheFileFor(1211).path,
      itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1211).path,
    );
  });
}
