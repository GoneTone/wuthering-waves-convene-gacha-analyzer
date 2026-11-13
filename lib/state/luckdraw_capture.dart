import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/luckdraw_capture_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';

/// 全域喚取立繪擷取服務；cacheDir 取自 [itemImageCacheDirProvider]，dispose 時釋放 webview。
final luckdrawCaptureServiceProvider = Provider<LuckdrawCaptureService>((ref) {
  final service = LuckdrawCaptureService(
    cacheDir: ref.watch(itemImageCacheDirProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
