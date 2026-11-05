import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 擷取所需的最小 webview 操作；正式環境由 [HeadlessInAppWebView] 實作，測試注入假實作。
abstract interface class LuckdrawWebEngine {
  /// 載入 [url]。
  Future<void> loadUrl(String url);

  /// 執行 [js] 並回傳結果。
  Future<dynamic> evaluate(String js);

  /// 釋放 webview。
  Future<void> dispose();
}

/// 喚取（Luckdraw）立繪擷取服務：以延遲建立、可重用的 headless webview 載入 encore
/// 角色頁、擷取已渲染的 Spine canvas，存本機快取並回傳檔。Android 與 Windows 共用；
/// webview 無法建立（Windows 缺 WebView2 runtime 等）時 [capture] 回 null。
class LuckdrawCaptureService {
  /// 建立服務；[cacheDir] 為圖檔快取根目錄、[timeout] 為單次擷取上限；
  /// [engineFactory] 預設建立 [HeadlessInAppWebView]，測試可注入假實作。
  LuckdrawCaptureService({
    required this.cacheDir,
    this.timeout = const Duration(seconds: 30),
    Future<LuckdrawWebEngine?> Function()? engineFactory,
  }) : _engineFactory = engineFactory ?? _InAppWebEngine.create;

  /// 圖檔快取根目錄。
  final Directory cacheDir;

  /// 單次擷取（載入＋渲染＋讀回）逾時。
  final Duration timeout;

  /// Logger 實例。
  static final _log = Logger('gacha.luckdraw.capture');

  /// 建立 webview 的工廠。
  final Future<LuckdrawWebEngine?> Function() _engineFactory;

  /// 已建立、跨擷取重用的 webview；null 表示尚未建立或建立失敗。
  LuckdrawWebEngine? _engine;

  /// 是否已嘗試建立過 webview（失敗只試一次，不反覆重試）。
  bool _engineAttempted = false;

  /// 序列化擷取與 webview 建立：單一 webview 一次只跑一個。
  final _lock = Lock();

  /// 推導某 [resourceId] 的喚取立繪快取檔。
  File cacheFileFor(int resourceId) =>
      itemLuckdrawCacheFile(baseDir: cacheDir, resourceId: resourceId);

  /// 取得某角色的喚取立繪檔：命中快取直接回；未命中則驅動 webview 擷取後快取。
  /// 失敗（webview 無法建立／逾時／頁面無 canvas／解碼錯）一律回 null。
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
    return _lock.synchronized(() async {
      if (!force && file.existsSync()) return file; // 取得鎖後再確認一次
      final engine = await _ensureEngine();
      if (engine == null) {
        _log.warning('capture rid=$resourceId webview unavailable');
        return null;
      }
      return _captureWith(engine, resourceId, kind, lang, file);
    });
  }

  /// 延遲建立 webview：首次擷取才建立（從不看喚取立繪的使用者不付常駐 webview 成本）；
  /// 失敗只試一次。須在 [_lock] 內呼叫。
  Future<LuckdrawWebEngine?> _ensureEngine() async {
    if (_engine != null || _engineAttempted) return _engine;
    _engineAttempted = true;
    try {
      _engine = await _engineFactory();
      if (_engine == null) {
        _log.warning('webview engine unavailable; luckdraw capture disabled');
      } else {
        _log.info('webview engine ready (lazy, ${Platform.operatingSystem})');
      }
    } catch (e, st) {
      _log.warning('webview engine init failed', e, st);
      _engine = null;
    }
    return _engine;
  }

  /// 以 [engine] 擷取 [resourceId] 的立繪並寫入 [file]；失敗回 null。結束時一律導回空白頁。
  Future<File?> _captureWith(
    LuckdrawWebEngine engine,
    int resourceId,
    String kind,
    String lang,
    File file,
  ) async {
    final url = encoreItemUrl(kind: kind, resourceId: resourceId, lang: lang);
    final sw = Stopwatch()..start();
    try {
      await engine.loadUrl(url);
      final deadline = DateTime.now().add(timeout);
      Map<String, dynamic>? probe;
      var armed = false;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final raw = await engine.evaluate(_jsProbe);
        if (raw is! String) continue;
        probe = jsonDecode(raw) as Map<String, dynamic>;
        if (probe['hasCanvas'] == true && probe['armed'] != true && !armed) {
          await engine.evaluate(_jsArm);
          armed = true;
        }
        final capLen = probe['capLen'];
        if (probe['capReady'] == true && capLen is num && capLen > 0) break;
      }
      final capLen = probe?['capLen'];
      if (probe == null || probe['capReady'] != true || capLen is! num) {
        _log.warning(
          'capture rid=$resourceId timeout url=${sanitizeUrl(url)} '
          'last=${probe == null ? "null" : jsonEncode(probe)}',
        );
        return null;
      }
      final total = capLen.toInt();
      final sb = StringBuffer();
      const chunk = 200000;
      for (var i = 0; i < total; i += chunk) {
        final part = await engine.evaluate('window.__cap.substr($i,$chunk)');
        if (part is! String) {
          _log.warning('capture rid=$resourceId chunk@$i not string');
          return null;
        }
        sb.write(part);
      }
      final bytes = base64Decode(sb.toString().split(',').last);
      await writeImageFileAtomic(file, bytes);
      _log.info(
        'capture ok rid=$resourceId bytes=${bytes.length} '
        'ms=${sw.elapsedMilliseconds} canvas=${probe['cw']}x${probe['ch']} '
        'dpr=${probe['dpr']} vw=${probe['vw']} url=${sanitizeUrl(url)}',
      );
      return file;
    } catch (e, st) {
      _log.warning(
        'capture failed rid=$resourceId url=${sanitizeUrl(url)}',
        e,
        st,
      );
      return null;
    } finally {
      // 擷取後導回空白頁，停止 encore 頁面渲染、釋放資源。
      try {
        await engine.loadUrl('about:blank');
      } catch (_) {}
    }
  }

  /// 釋放已建立的 webview（provider dispose 時呼叫）。
  Future<void> dispose() async {
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    try {
      await engine.dispose();
    } catch (e, st) {
      _log.warning('webview engine dispose failed', e, st);
    }
  }
}

/// 以 [HeadlessInAppWebView] 實作的 [LuckdrawWebEngine]（Android／Windows 共用）。
class _InAppWebEngine implements LuckdrawWebEngine {
  /// 包住已執行的 headless webview 與其 controller。
  _InAppWebEngine(this._webview, this._controller);

  /// 執行中的 headless webview。
  final HeadlessInAppWebView _webview;

  /// headless webview 的 controller。
  final InAppWebViewController _controller;

  /// canvas 寬度目標（實體像素）；encore 的 canvas 寬度＝其 CSS 寬度 × dpr。
  static const _targetCanvasPx = 1600.0;

  /// Android 上 encore canvas CSS 寬度約為 viewport 寬度的比例（實機量測，700 寬時）。
  static const _canvasToViewport = 0.775;

  /// Windows 以 CDP 模擬的 dpr（headless 預設 1，canvas 只有 ~1246 寬）。
  static const _windowsDeviceScaleFactor = 2.0;

  /// 建立並啟動 headless webview；平台不支援（Windows 缺 WebView2 runtime 等）時回 null。
  static Future<LuckdrawWebEngine?> create() async {
    if (Platform.isWindows &&
        await WebViewEnvironment.getAvailableVersion() == null) {
      return null;
    }
    final size = _viewportSize();
    final created = Completer<InAppWebViewController>();
    final webview = HeadlessInAppWebView(
      initialSize: size,
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
      ),
      onWebViewCreated: (c) {
        if (!created.isCompleted) created.complete(c);
      },
    );
    await webview.run();
    final controller = await created.future.timeout(
      const Duration(seconds: 15),
    );
    if (Platform.isWindows) {
      await controller.callDevToolsProtocolMethod(
        methodName: 'Emulation.setDeviceMetricsOverride',
        parameters: {
          'width': size.width.toInt(),
          'height': size.height.toInt(),
          'deviceScaleFactor': _windowsDeviceScaleFactor,
          'mobile': false,
        },
      );
    }
    return _InAppWebEngine(webview, controller);
  }

  /// 依平台決定 viewport 邏輯尺寸，使 canvas 寬度接近 [_targetCanvasPx]。
  /// encore 版面隨 viewport 寬度切換，canvas 佔 viewport 的比例不固定：Windows 用實測值
  /// （1400 寬、dpr 2 → canvas 1624）；Android 依裝置 dpr 反推。
  static Size _viewportSize() {
    if (Platform.isWindows) return const Size(1400, 1180);
    final dpr = PlatformDispatcher.instance.views.first.devicePixelRatio;
    final width = (_targetCanvasPx / dpr / _canvasToViewport).clamp(
      600.0,
      1400.0,
    );
    return Size(width, width * 0.843);
  }

  @override
  Future<void> loadUrl(String url) =>
      _controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

  @override
  Future<dynamic> evaluate(String js) =>
      _controller.evaluateJavascript(source: js);

  @override
  Future<void> dispose() => _webview.dispose();
}

/// 探測腳本：以 JSON 字串回傳頁面與 canvas 狀態（同步、非 rAF）。
/// 回字串是因為 flutter_inappwebview 對 JS 物件的回傳型別在各平台不一致。
const String _jsProbe = r'''
(function () {
  var cv = document.querySelector('#luckdraw-section canvas');
  return JSON.stringify({
    rs: document.readyState,
    hasCanvas: !!cv,
    armed: !!window.__capArmed,
    capReady: !!window.__capReady,
    capLen: window.__cap ? window.__cap.length : 0,
    cw: cv ? cv.width : 0,
    ch: cv ? cv.height : 0,
    dpr: window.devicePixelRatio,
    vw: window.innerWidth
  });
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
