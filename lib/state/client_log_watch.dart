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

/// Client.log 監看的起點：從 [offset] 之後開始讀，[id] 是當時的檔案識別（null 為未知）。
typedef ClientLogPosition = ({int offset, String? id});

/// 監看遊戲 Client.log，等待新附加的喚取記錄 URL 並轉成憑證。
abstract class ClientLogWatch {
  /// 從 [from]（預設為 [source] 目前的結尾）開始監看；只處理之後新增的內容，`result` 永不 completeError。
  Future<CaptureSession> start(
    ClientLogSource source, {
    ClientLogPosition? from,
  });
}

/// 以固定間隔輪詢檔案增量的 [ClientLogWatch]。
class PollingClientLogWatch implements ClientLogWatch {
  /// 建立 [PollingClientLogWatch]，[interval] 為輪詢間隔，[maxReadBytes] 為單次讀取上限。
  PollingClientLogWatch({
    this.interval = const Duration(seconds: 1),
    this.maxReadBytes = clientLogChunkBytes,
  });

  /// 輪詢間隔。
  final Duration interval;

  /// 單次最多讀取的位元組數；積壓更多時改由新到舊分段讀（shell 來源每段要數秒）。
  final int maxReadBytes;

  /// 本監看器的 logger。
  static final _log = Logger('gacha.clientLog');

  @override
  Future<CaptureSession> start(
    ClientLogSource source, {
    ClientLogPosition? from,
  }) async {
    final completer = Completer<GachaCredential?>();
    var offset = 0;
    String? id;
    if (from != null) {
      (offset: offset, id: id) = from;
    } else {
      try {
        final p = await source.probe();
        offset = p.length;
        id = p.id;
      } on Object catch (e) {
        _log.warning(
          'client log baseline failed source=${source.logLabel} '
          '${_describe(e)}; using offset=0',
        );
      }
    }
    var carry = Uint8List(0);
    var polling = false;
    _log.info(
      'client log watch started source=${source.logLabel} offset=$offset',
    );

    /// 掃描結果交回主 isolate：寫被拒原因、更新 carry、命中就完成。
    void handle(GachaCredential? cred, Uint8List tail, List<String> rejected) {
      carry = tail;
      if (carry.length > _maxCarryBytes) {
        _log.warning('client log carry overflow bytes=${carry.length}');
        carry = Uint8List(0);
      }
      for (final reason in rejected) {
        _log.warning('client log url rejected reason=$reason');
      }
      if (cred != null && !completer.isCompleted) {
        _log.info(
          'client log hit cred=${sanitizeCredential(cred.toJsonString())}',
        );
        completer.complete(cred);
      }
    }

    /// 單輪輪詢：偵測換檔、讀取增量、解碼並嘗試取得憑證。
    Future<void> poll() async {
      if (polling || completer.isCompleted) return;
      polling = true;
      try {
        final p = await source.probe();
        final rotated = p.length < offset
            ? 'shrink'
            : id != null && p.id != null && p.id != id
            ? 'identity'
            : null;
        if (rotated != null) {
          offset = 0;
          carry = Uint8List(0);
          _log.info('client log rotated length=${p.length} by=$rotated');
        }
        // 讀不到識別時沿用舊值：未知只代表無法判斷，不是換檔。
        id = p.id ?? id;
        final backlog = p.length - offset;
        if (backlog <= 0) return;
        if (backlog <= maxReadBytes) {
          final chunk = await source.read(offset, backlog);
          if (chunk.isEmpty) return;
          offset += chunk.length;
          final scan = await _scanInBackground(carry, chunk);
          handle(scan.cred, scan.carry, scan.rejected);
          return;
        }
        // 玩家在遊戲裡時 App 被凍結，回來可能積了幾十 MB；網址在最後面，從新到舊讀才不用等全部讀完。
        _log.info('client log backlog bytes=$backlog, reading newest first');
        final sw = Stopwatch()..start();
        final scan = await scanClientLogBackward(
          source,
          from: offset,
          to: p.length,
          chunkBytes: maxReadBytes,
          prefix: carry,
          isStopped: () => completer.isCompleted,
        );
        offset = p.length;
        _log.info(
          'client log backlog scanned ms=${sw.elapsedMilliseconds} '
          'hit=${scan.cred != null}',
        );
        handle(scan.cred, scan.tail, scan.rejected);
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

/// 單次讀取 Client.log 的預設上限。
const int clientLogChunkBytes = 2 * 1024 * 1024;

/// 未遇換行時 carry 的上限，超過即丟棄以防無限成長。
const _maxCarryBytes = 1024 * 1024;

/// 換行字元（解碼後）。
const _newline = 0x0A;

/// 描述例外但不含原始路徑（`FileSystemException.toString()` 會帶路徑）。
String _describe(Object e) => e is FileSystemException
    ? 'os=${e.osError?.message}'
    : 'error=${e.runtimeType}';

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
  final buf = _join(carry, decodeClientLogBytes(chunk));
  final end = buf.lastIndexOf(_newline);
  if (end < 0) return (carry: buf, cred: null, rejected: const <String>[]);
  final rejected = <String>[];
  final cred = _credentialIn(Uint8List.sublistView(buf, 0, end + 1), rejected);
  return (carry: buf.sublist(end + 1), cred: cred, rejected: rejected);
}

/// [scanClientLogBackward] 的結果：最新的合法憑證、區間最後一段還沒換行的內容（已解碼）、被拒網址的原因。
typedef ClientLogBackwardScan = ({
  GachaCredential? cred,
  Uint8List tail,
  List<String> rejected,
});

/// 由新到舊、每段 [chunkBytes] 讀 [source] 的 `[from, to)`，找到最新的合法憑證就停。
///
/// 只掃完整的行：區間結尾還沒換行的內容放進 `tail`，跨段的行會接起來再掃，
/// 避免把被切斷的網址當成完整網址。[prefix] 是 [from] 之前還沒成行的內容（已解碼），
/// 傳 null 代表 [from] 不在行首，最舊那段開頭的殘行直接略過。[isStopped] 回 true 時中途停止。
Future<ClientLogBackwardScan> scanClientLogBackward(
  ClientLogSource source, {
  required int from,
  required int to,
  required int chunkBytes,
  Uint8List? prefix,
  bool Function()? isStopped,
}) async {
  final rejected = <String>[];
  var after = Uint8List(0);
  Uint8List? tail;
  var hi = to;
  while (hi > from && !(isStopped?.call() ?? false)) {
    final lo = math.max(from, hi - chunkBytes);
    final raw = await source.read(lo, hi - lo);
    final lineStart = lo == from ? prefix : null;
    final step = await _backInBackground(raw, after, tail != null, lineStart);
    rejected.addAll(step.rejected);
    tail ??= step.tail;
    after = step.after;
    if (step.cred != null) {
      return (cred: step.cred, tail: tail ?? after, rejected: rejected);
    }
    hi = lo;
  }
  return (cred: null, tail: tail ?? after, rejected: rejected);
}

/// 在背景 isolate 執行 [_scanBackChunk]；理由同 [_scanInBackground]。
Future<_BackStep> _backInBackground(
  Uint8List raw,
  Uint8List after,
  bool tailFound,
  Uint8List? lineStart,
) => Isolate.run(() => _scanBackChunk(raw, after, tailFound, lineStart));

/// [_scanBackChunk] 的結果：[after] 交給下一段（較舊）接在後面，[tail] 在找到區間最後一個換行時才有值。
typedef _BackStep = ({
  GachaCredential? cred,
  Uint8List after,
  Uint8List? tail,
  List<String> rejected,
});

/// 處理由新到舊的一段：[after] 是較新那段開頭的殘行（或尚未找到換行時累積的結尾），
/// [tailFound] 為 false 時先找出區間最後一個換行。[lineStart] 非 null 代表本段開頭就是行首，前面接上它。
_BackStep _scanBackChunk(
  Uint8List raw,
  Uint8List after,
  bool tailFound,
  Uint8List? lineStart,
) {
  var buf = _join(decodeClientLogBytes(raw), after);
  Uint8List? tail;
  if (!tailFound) {
    final last = buf.lastIndexOf(_newline);
    if (last < 0) {
      // 整段都還在同一行裡：最舊那段就結束，否則繼續往前累積。
      return lineStart != null
          ? (
              cred: null,
              after: Uint8List(0),
              tail: _join(lineStart, buf),
              rejected: const <String>[],
            )
          : (cred: null, after: buf, tail: null, rejected: const <String>[]);
    }
    tail = buf.sublist(last + 1);
    buf = buf.sublist(0, last + 1);
  }
  final Uint8List lines;
  final Uint8List next;
  if (lineStart != null) {
    lines = _join(lineStart, buf);
    next = Uint8List(0);
  } else {
    final first = buf.indexOf(_newline);
    if (first < 0) {
      return (cred: null, after: buf, tail: tail, rejected: const <String>[]);
    }
    next = buf.sublist(0, first + 1);
    lines = buf.sublist(first + 1);
  }
  final rejected = <String>[];
  final cred = lines.isEmpty ? null : _credentialIn(lines, rejected);
  return (cred: cred, after: next, tail: tail, rejected: rejected);
}

/// 從整份 Client.log 結尾往前找最新的合法憑證；[maxBytes] 為 null 時讀整份，否則只讀最後這麼多。
///
/// 回傳的 `end` 是下一步監看的起點：結尾還沒換行的那行會留給監看重讀，不會漏掉。
Future<({GachaCredential? cred, ClientLogPosition end, List<String> rejected})>
findLatestClientLogCredential(
  ClientLogSource source, {
  int? maxBytes,
  int chunkBytes = clientLogChunkBytes,
  bool Function()? isStopped,
}) async {
  final p = await source.probe();
  final from = maxBytes == null ? 0 : math.max(0, p.length - maxBytes);
  final scan = await scanClientLogBackward(
    source,
    from: from,
    to: p.length,
    chunkBytes: chunkBytes,
    prefix: from == 0 ? Uint8List(0) : null,
    isStopped: isStopped,
  );
  return (
    cred: scan.cred,
    end: (offset: p.length - scan.tail.length, id: p.id),
    rejected: scan.rejected,
  );
}

/// 在完整的行（已解碼）裡找最新且合法的憑證，被拒原因加進 [rejected]。
GachaCredential? _credentialIn(Uint8List lines, List<String> rejected) =>
    latestCredentialIn(
      utf8.decode(lines, allowMalformed: true),
      onRejected: (e) => rejected.add(e.message),
    );

/// 串接兩段位元組。
Uint8List _join(Uint8List a, Uint8List b) =>
    (BytesBuilder(copy: false)
          ..add(a)
          ..add(b))
        .takeBytes();

/// 提供 [ClientLogWatch]，測試可 override。
final clientLogWatchProvider = Provider<ClientLogWatch>(
  (ref) => PollingClientLogWatch(),
);
