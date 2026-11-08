import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/client_log_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/client_log_source.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';

/// 監看遊戲 Client.log，等待新附加的喚取記錄 URL 並轉成憑證。
abstract class ClientLogWatch {
  /// 以 [source] 目前長度為起點開始監看；只處理之後新增的內容，`result` 永不 completeError。
  Future<CaptureSession> start(ClientLogSource source);
}

/// 以固定間隔輪詢檔案增量的 [ClientLogWatch]。
class PollingClientLogWatch implements ClientLogWatch {
  /// 建立 [PollingClientLogWatch]，[interval] 為輪詢間隔，[maxReadBytes] 為單輪讀取上限。
  PollingClientLogWatch({
    this.interval = const Duration(seconds: 1),
    this.maxReadBytes = 2 * 1024 * 1024,
  });

  /// 輪詢間隔。
  final Duration interval;

  /// 單輪最多讀取的位元組數；積壓更多時分到後續輪次讀，避免一次拉太多（shell 來源尤其明顯）。
  final int maxReadBytes;

  /// 本監看器的 logger。
  static final _log = Logger('gacha.clientLog');

  /// 未遇換行時 carry 的上限，超過即丟棄以防無限成長。
  static const _maxCarryBytes = 1024 * 1024;

  /// 描述例外但不含原始路徑（`FileSystemException.toString()` 會帶路徑）。
  static String _describe(Object e) => e is FileSystemException
      ? 'os=${e.osError?.message}'
      : 'error=${e.runtimeType}';

  @override
  Future<CaptureSession> start(ClientLogSource source) async {
    final completer = Completer<GachaCredential?>();
    var offset = 0;
    try {
      offset = await source.length();
    } on Object catch (e) {
      _log.warning(
        'client log baseline failed source=${source.logLabel} '
        '${_describe(e)}; using offset=0',
      );
    }
    var carry = Uint8List(0);
    var polling = false;
    _log.info(
      'client log watch started source=${source.logLabel} offset=$offset',
    );

    /// 單輪輪詢：偵測輪替、讀取增量、解碼並嘗試取得憑證。
    Future<void> poll() async {
      if (polling || completer.isCompleted) return;
      polling = true;
      try {
        final length = await source.length();
        if (length < offset) {
          offset = 0;
          carry = Uint8List(0);
          _log.info('client log rotated length=$length');
        }
        if (length == offset) return;
        final chunk = await source.read(
          offset,
          math.min(length - offset, maxReadBytes),
        );
        if (chunk.isEmpty) return;
        offset += chunk.length;
        final scan = await _scanInBackground(carry, chunk);
        carry = scan.carry;
        if (carry.length > _maxCarryBytes) {
          _log.warning('client log carry overflow bytes=${carry.length}');
          carry = Uint8List(0);
        }
        for (final reason in scan.rejected) {
          _log.warning('client log url rejected reason=$reason');
        }
        final cred = scan.cred;
        if (cred != null && !completer.isCompleted) {
          _log.info(
            'client log hit cred=${sanitizeCredential(cred.toJsonString())}',
          );
          completer.complete(cred);
        }
      } on Object catch (e) {
        _log.warning(
          'client log read failed source=${source.logLabel} ${_describe(e)}',
        );
      } finally {
        polling = false;
      }
    }

    Future<void>? inFlight;
    final timer = Timer.periodic(interval, (_) {
      if (polling || completer.isCompleted) return;
      inFlight = poll();
    });
    unawaited(completer.future.whenComplete(timer.cancel));

    return CaptureSession(
      result: completer.future,
      cancel: () async {
        if (!completer.isCompleted) completer.complete(null);
        timer.cancel();
        await inFlight;
      },
    );
  }
}

/// 一輪增量的掃描結果：尚未成行的 [carry]、找到的最新憑證、被拒網址的原因（背景 isolate 的 log 不會進 App log，交回主 isolate 寫）。
typedef _ScanResult = ({
  Uint8List carry,
  GachaCredential? cred,
  List<String> rejected,
});

/// 在背景 isolate 執行 [_scanChunk]；閉包只抓參數，避免把呼叫端的 Timer／Completer 一起送過去。
Future<_ScanResult> _scanInBackground(Uint8List carry, Uint8List chunk) =>
    Isolate.run(() => _scanChunk(carry, chunk));

/// 把 [carry] 接上解碼後的 [chunk]，只在完整的行內找最新且合法的喚取記錄憑證。
_ScanResult _scanChunk(Uint8List carry, Uint8List chunk) {
  final buf =
      (BytesBuilder(copy: false)
            ..add(carry)
            ..add(decodeClientLogBytes(chunk)))
          .takeBytes();
  final end = buf.lastIndexOf(0x0A);
  if (end < 0) return (carry: buf, cred: null, rejected: const <String>[]);
  final rejected = <String>[];
  final cred = latestCredentialIn(
    utf8.decode(Uint8List.sublistView(buf, 0, end + 1), allowMalformed: true),
    onRejected: (e) => rejected.add(e.message),
  );
  return (carry: buf.sublist(end + 1), cred: cred, rejected: rejected);
}

/// 提供 [ClientLogWatch]，測試可 override。
final clientLogWatchProvider = Provider<ClientLogWatch>(
  (ref) => PollingClientLogWatch(),
);
