import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';
import 'package:webview_windows/webview_windows.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 喚取（Luckdraw）立繪擷取服務：驅動全域隱藏 [WebviewController] 載入 encore 角色頁、
/// 擷取已渲染的 Spine canvas，存本機快取並回傳檔。webview 由 `LuckdrawCaptureHost`
/// 於 app 啟動時 [attachWebview]；未 attach（含 WebView2 runtime 缺失）時 [capture] 回 null。
class LuckdrawCaptureService {
  /// 建立服務；[cacheDir] 為圖檔快取根目錄、[timeout] 為單次擷取上限。
  LuckdrawCaptureService({
    required this.cacheDir,
    this.timeout = const Duration(seconds: 30),
  });

  /// 圖檔快取根目錄。
  final Directory cacheDir;

  /// 單次擷取（載入＋渲染＋讀回）逾時。
  final Duration timeout;

  /// Logger 實例。
  static final _log = Logger('gacha.luckdraw.capture');

  /// 由 host 注入的可重用離屏 webview；null 表示尚未就緒。
  WebviewController? _webview;

  /// 序列化擷取：單一 webview 一次只跑一個。
  final _lock = Lock();

  /// host 是否已注入 webview。
  bool get isReady => _webview != null;

  /// 由 `LuckdrawCaptureHost` 註冊的延遲初始化 callback：首次擷取時才呼叫以按需
  /// 初始化離屏 webview，避免「從不看喚取立繪」的使用者開 app 就多付一個常駐
  /// WebView2 行程。回傳就緒的 controller；缺 runtime／失敗回 null。
  Future<WebviewController?> Function()? _initializer;

  /// 由 `LuckdrawCaptureHost` 在 initState 註冊延遲初始化 callback。
  void registerInitializer(Future<WebviewController?> Function() initializer) {
    _initializer = initializer;
  }

  /// 由 `LuckdrawCaptureHost` 在 webview 初始化完成後呼叫。
  void attachWebview(WebviewController controller) {
    _webview = controller;
    _log.info('host webview attached');
  }

  /// host dispose 時呼叫，避免持有失效 controller。
  void detachWebview() {
    _webview = null;
    _initializer = null;
    _log.info('host webview detached');
  }

  /// 推導某 [resourceId] 的喚取立繪快取檔。
  File cacheFileFor(int resourceId) =>
      itemLuckdrawCacheFile(baseDir: cacheDir, resourceId: resourceId);

  /// 取得某角色的喚取立繪檔：命中快取直接回；未命中則驅動 webview 擷取後快取。
  /// 失敗（host 未就緒／逾時／頁面無 canvas／解碼錯）一律回 null。
  ///
  /// [force] 為 true 時略過「快取檔已存在即回舊檔」短路、強制重新擷取（供使用者手動
  /// 「重抓」用）；擷取成功才以 [writeImageFileAtomic] 覆蓋，失敗則保留磁碟既有舊檔。
  Future<File?> capture({
    required int resourceId,
    required String kind,
    required String lang,
    bool force = false,
  }) async {
    final file = cacheFileFor(resourceId);
    if (!force && file.existsSync()) return file;
    // 延遲初始化：首次擷取時才請 host 開 WebView2（無 host／缺 runtime 回 null）。
    if (_webview == null) {
      final initializer = _initializer;
      if (initializer == null) {
        _log.warning('capture rid=$resourceId host not registered');
        return null;
      }
      await initializer();
    }
    final wv = _webview;
    if (wv == null) {
      _log.warning('capture rid=$resourceId host not ready');
      return null;
    }
    return _lock.synchronized(() async {
      if (!force && file.existsSync()) return file; // 取得鎖後再確認一次
      final url = encoreItemUrl(kind: kind, resourceId: resourceId, lang: lang);
      final sw = Stopwatch()..start();
      try {
        await wv.loadUrl(url);
        final deadline = DateTime.now().add(timeout);
        Map<dynamic, dynamic>? probe;
        var armed = false;
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          final res = await wv.executeScript(_jsProbe);
          if (res is! Map) continue;
          probe = res;
          if (res['hasCanvas'] == true && res['armed'] != true && !armed) {
            await wv.executeScript(_jsArm);
            armed = true;
          }
          final capLen = res['capLen'];
          if (res['capReady'] == true && capLen is num && capLen > 0) break;
        }
        final capLen = probe?['capLen'];
        if (probe == null || probe['capReady'] != true || capLen is! num) {
          _log.warning(
            'capture rid=$resourceId timeout url=${sanitizeUrl(url)} '
            'last=${probe == null ? "null" : jsonEncode(probe)}',
          );
          await _blank(wv);
          return null;
        }
        final total = capLen.toInt();
        final sb = StringBuffer();
        const chunk = 200000;
        for (var i = 0; i < total; i += chunk) {
          final part = await wv.executeScript('window.__cap.substr($i,$chunk)');
          if (part is String) {
            sb.write(part);
          } else {
            _log.warning('capture rid=$resourceId chunk@$i not string');
            await _blank(wv);
            return null;
          }
        }
        final bytes = base64Decode(sb.toString().split(',').last);
        await writeImageFileAtomic(file, bytes);
        _log.info(
          'capture ok rid=$resourceId bytes=${bytes.length} '
          'ms=${sw.elapsedMilliseconds} url=${sanitizeUrl(url)}',
        );
        await _blank(wv);
        return file;
      } catch (e, st) {
        _log.warning(
          'capture failed rid=$resourceId url=${sanitizeUrl(url)}',
          e,
          st,
        );
        await _blank(wv);
        return null;
      }
    });
  }

  /// 擷取後導回空白頁，停止 encore 頁面渲染、釋放資源。
  Future<void> _blank(WebviewController wv) async {
    try {
      await wv.loadUrl('about:blank');
    } catch (_) {}
  }
}

/// 探測腳本：回傳頁面與 canvas 狀態（同步、非 rAF）。
const String _jsProbe = r'''
(function () {
  var cv = document.querySelector('#luckdraw-section canvas');
  return {
    rs: document.readyState,
    hasCanvas: !!cv,
    armed: !!window.__capArmed,
    capReady: !!window.__capReady,
    capLen: window.__cap ? window.__cap.length : 0
  };
})()
''';

/// 武裝腳本：rAF 鏈中偵測 canvas 非空白後於同一幀全尺寸擷取存 window.__cap。
const String _jsArm = r'''
(function () {
  if (window.__capArmed) return 'already';
  window.__capArmed = true;
  window.__capReady = false;
  var tries = 0;
  function step() {
    tries++;
    var cv = document.querySelector('#luckdraw-section canvas');
    if (!cv) { if (tries < 900) requestAnimationFrame(step); return; }
    var sec = document.querySelector('#luckdraw-section');
    if (sec) { try { sec.scrollIntoView({ block: 'center' }); } catch (e) {} }
    var p = document.createElement('canvas'); p.width = 32; p.height = 32;
    var pc = p.getContext('2d'); pc.drawImage(cv, 0, 0, 32, 32);
    var d = pc.getImageData(0, 0, 32, 32).data;
    var op = 0, cols = {};
    for (var i = 0; i < d.length; i += 4) {
      if (d[i + 3] > 10) op++;
      cols[d[i] + ',' + d[i + 1] + ',' + d[i + 2]] = 1;
    }
    if (op > 40 && Object.keys(cols).length > 5) {
      var t = document.createElement('canvas'); t.width = cv.width; t.height = cv.height;
      t.getContext('2d').drawImage(cv, 0, 0);
      window.__cap = t.toDataURL('image/png');
      window.__capReady = true;
      return;
    }
    if (tries < 900) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
  return 'armed';
})()
''';
