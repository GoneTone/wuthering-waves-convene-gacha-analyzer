import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:webview_windows/webview_windows.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/state/luckdraw_capture.dart';

/// 全域隱藏離屏 webview 宿主：持有可重用 [WebviewController] 供
/// [LuckdrawCaptureService] 擷取喚取立繪。掛在 app 根、藏於 app 內容之後，
/// 以極低不透明度保持繪製（rAF 不被節流）。**延遲初始化**：app 啟動時只註冊
/// callback，首次擷取才開 WebView2，避免從不看喚取立繪的使用者多付常駐行程。
/// WebView2 runtime 缺失時不掛載。
class LuckdrawCaptureHost extends ConsumerStatefulWidget {
  /// 建立 [LuckdrawCaptureHost]。
  const LuckdrawCaptureHost({super.key});

  @override
  ConsumerState<LuckdrawCaptureHost> createState() =>
      _LuckdrawCaptureHostState();
}

/// [LuckdrawCaptureHost] 的 state：管理離屏 [WebviewController] 生命週期與就緒旗標。
class _LuckdrawCaptureHostState extends ConsumerState<LuckdrawCaptureHost> {
  /// Logger 實例。
  static final _log = Logger('gacha.luckdraw.capture');

  /// 可重用的離屏 webview controller（一次初始化、跨擷取重用）。
  final WebviewController _controller = WebviewController();

  /// webview 是否初始化完成、可供擷取。
  bool _ready = false;

  /// 是否正在初始化中（防並發擷取重複初始化）。
  bool _initing = false;

  /// 初始化是否已失敗（缺 runtime／例外）；失敗只試一次，不反覆重試。
  bool _initFailed = false;

  @override
  void initState() {
    super.initState();
    // 不 eager init；註冊延遲初始化 callback，首次擷取時由 service 呼叫。
    ref
        .read(luckdrawCaptureServiceProvider)
        .registerInitializer(_ensureInitialized);
  }

  /// 延遲初始化：首次擷取時由 [LuckdrawCaptureService] 呼叫。偵測 WebView2 runtime、
  /// 初始化 controller、等下一幀讓 build() 把隱藏 Webview 掛進樹（平台 view 需在繪製樹
  /// 中才渲染），再 attach 給 service。回傳就緒的 controller；缺 runtime／失敗回 null
  /// （只試一次）。
  Future<WebviewController?> _ensureInitialized() async {
    if (_ready) return _controller;
    if (_initFailed) return null;
    if (_initing) {
      while (_initing) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return _ready ? _controller : null;
    }
    _initing = true;
    try {
      final ver = await WebviewController.getWebViewVersion();
      if (ver == null) {
        _log.warning('WebView2 runtime missing; luckdraw capture disabled');
        _initFailed = true;
        return null;
      }
      await _controller.initialize();
      await _controller.loadUrl('about:blank');
      if (!mounted) {
        _initFailed = true;
        return null;
      }
      setState(() => _ready = true);
      // 等下一幀讓 build() 掛上隱藏 Webview widget，平台 view 才會開始渲染。
      await WidgetsBinding.instance.endOfFrame;
      ref.read(luckdrawCaptureServiceProvider).attachWebview(_controller);
      _log.info('luckdraw capture host ready (lazy, webview2 $ver)');
      return _controller;
    } catch (e, st) {
      _log.warning('luckdraw capture host init failed', e, st);
      _initFailed = true;
      return null;
    } finally {
      _initing = false;
    }
  }

  @override
  void dispose() {
    ref.read(luckdrawCaptureServiceProvider).detachWebview();
    try {
      _controller.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();
    return IgnorePointer(
      child: Opacity(
        opacity: 0.004,
        // 尺寸決定 encore 渲染的 canvas 解析度（高 DPI 下偏小→模糊）。實測 2000×1680
        // 可達 canvas 飽和值（~1422×1185），再大無增益、只多吃記憶體。
        child: SizedBox(width: 2000, height: 1680, child: Webview(_controller)),
      ),
    );
  }
}
