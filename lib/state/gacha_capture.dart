import 'dart:async';

import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/src/rust/api/capture.dart'
    as rust_capture;

/// 單次 MITM 捕獲會話，提供結果 future 與取消函式。
class CaptureSession {
  /// 建立 [CaptureSession]。
  CaptureSession({required this.result, required this.cancel});

  /// 解析為 [GachaCredential]，或 null 代表使用者取消 / MITM 在無命中下關閉。
  final Future<GachaCredential?> result;

  /// 觸發 stop_capture，等同使用者按取消
  final Future<void> Function() cancel;
}

/// 抽象喚取捕獲介面，實作由 Rust MITM 提供。
abstract class GachaCapture {
  /// 啟動一次捕獲會話並回傳 [CaptureSession]。
  CaptureSession start();
}

/// 以 Rust 端 WinDivert 重導向 + hudsucker MITM 實作的 [GachaCapture]。
class RustGachaCapture implements GachaCapture {
  static final _log = Logger('gacha.capture');

  @override
  CaptureSession start() {
    final completer = Completer<GachaCredential?>();
    GachaCredential? captured;
    _log.info('capture started');

    rust_capture.startCapture().listen(
      (event) {
        // 已命中過就不覆寫；只取第一筆成功解析的 body。
        if (captured != null) return;
        try {
          captured = GachaCredential.fromCapturedBody(event.body);
          _log.fine(
            'captured credential host=${event.host} '
            'body=${sanitizeCredential(event.body)}',
          );
        } catch (e) {
          // 命中目標 host 但 body 非預期 JSON → 視為未命中，繼續等下一筆。
          _log.warning('failed to parse captured body host=${event.host}: $e');
        }
        // 不在此 complete：等 stream onDone（MITM graceful shutdown + helper 停止、
        // WinDivert 重導向已還原），此時呼叫 HTTP fetcher 才不會被重導向誤導。
      },
      onError: (Object e, StackTrace st) {
        _log.severe('capture error', e, st);
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (captured == null) {
          _log.info('capture done with no match');
        } else {
          _log.info(
            'capture done, playerId=${sanitizeUid(captured!.playerId)}',
          );
        }
        if (!completer.isCompleted) completer.complete(captured);
      },
    );

    return CaptureSession(
      result: completer.future,
      cancel: () async {
        _log.info('capture cancelled by user');
        await rust_capture.stopCapture();
      },
    );
  }
}
