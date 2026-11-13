import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/client_log_source.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/client_log_watch.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import '../helpers/client_log_fixtures.dart';

/// 以 [id] 為 record_id 組出一筆完整的國際服喚取 URL。
String _url(String id) =>
    'https://aki-gm-resources-oversea.aki-game.net/aki/gacha/index.html#/record'
    '?svr_id=s&player_id=1&lang=en&gacha_id=1&resources_id=r&record_id=$id';

/// 遊戲在 [time] 開新檔時寫的第一行。
String _header(String time) => 'Log file open, [2026.11.10-$time]\r\n';

/// 以編碼後的位元組 append [text] 到 [file]。
void _append(File file, String text) => file.writeAsBytesSync(
  encodeClientLog(text),
  mode: FileMode.append,
  flush: true,
);

/// 等 [future] 完成，逾時視為測試失敗。
Future<GachaCredential?> _await(Future<GachaCredential?> future) =>
    future.timeout(const Duration(seconds: 5));

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('client_log_watch');
    file = File('${dir.path}/Client.log');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  /// 啟動監看，tearDown 前由測試自行 cancel。
  Future<CaptureSession> begin({int? maxReadBytes, ClientLogSource? source}) =>
      PollingClientLogWatch(
        interval: const Duration(milliseconds: 20),
        maxReadBytes: maxReadBytes ?? 2 * 1024 * 1024,
      ).start(source ?? LocalFileLogSource(file.path));

  test('ignores url written before start', () async {
    _append(file, '${_url('A')}\n');
    final s = await begin();
    var done = false;
    unawaited(s.result.then((_) => done = true));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(done, isFalse);
    await s.cancel();
    expect(await _await(s.result), isNull);
    await s.cancel();
  });

  test('completes with url appended after start', () async {
    final s = await begin();
    _append(file, 'noise ${_url('B')}\n');
    expect((await _await(s.result))!.recordId, 'B');
    await s.cancel();
  });

  test('joins url split across two reads', () async {
    final s = await begin();
    final full = _url('SPLIT');
    _append(file, full.substring(0, 80));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _append(file, '${full.substring(80)}\n');
    expect((await _await(s.result))!.recordId, 'SPLIT');
    await s.cancel();
  });

  test('resets offset when file shrinks', () async {
    _append(file, '${'x' * 400}\n');
    final s = await begin();
    file.writeAsBytesSync(encodeClientLog('${_url('C')}\n'));
    expect((await _await(s.result))!.recordId, 'C');
    await s.cancel();
  });

  test('reads a swapped-in longer file from its start', () async {
    // 遊戲更新後新檔比舊檔長，只看長度會以為沒換檔、從舊長度往後讀而漏掉前面的網址。
    _append(file, '${_header('10.00.00')}${'x' * 200}\n');
    final s = await begin();
    file.writeAsBytesSync(
      encodeClientLog('${_header('10.05.00')}${_url('G')}\n${'y' * 500}\n'),
    );
    expect((await _await(s.result))!.recordId, 'G');
    await s.cancel();
  });

  test('missing file then created', () async {
    final warnings = <LogRecord>[];
    final sub = Logger('gacha.clientLog').onRecord.listen((r) {
      if (r.level >= Level.WARNING) warnings.add(r);
    });
    final s = await begin();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(warnings, isEmpty);
    _append(file, '${_url('D')}\n');
    expect((await _await(s.result))!.recordId, 'D');
    await s.cancel();
    await sub.cancel();
  });

  test('malformed url keeps waiting', () async {
    final s = await begin();
    _append(file, '${_url('X').replaceAll('&record_id=X', '')}\n');
    var done = false;
    unawaited(s.result.then((_) => done = true));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(done, isFalse);
    _append(file, '${_url('E')}\n');
    expect((await _await(s.result))!.recordId, 'E');
    await s.cancel();
  });

  test('falls back to an earlier valid url in the same chunk', () async {
    final s = await begin();
    final bad = _url('X').replaceAll('&record_id=X', '');
    _append(file, '${_url('V')}\n$bad\n');
    expect((await _await(s.result))!.recordId, 'V');
    await s.cancel();
  });

  test('reads large backlog in maxReadBytes chunks', () async {
    final s = await begin(maxReadBytes: 64);
    _append(file, '${'x' * 500}\n${_url('C')}\n');
    expect((await _await(s.result))!.recordId, 'C');
    await s.cancel();
  });

  test('large backlog returns the newest url without reading it all', () async {
    final src = _CountingSource(file.path);
    final s = await begin(maxReadBytes: 64, source: src);
    _append(file, '${_url('OLD')}\n${'x' * 2000}\n${_url('NEW')}\n');
    expect((await _await(s.result))!.recordId, 'NEW');
    expect(src.bytesRead, lessThan(1000));
    await s.cancel();
  });

  test(
    'large backlog keeps an unfinished last line for the next poll',
    () async {
      final s = await begin(maxReadBytes: 64);
      final full = _url('H');
      _append(file, '${'x' * 300}\n${full.substring(0, 50)}');
      var done = false;
      unawaited(s.result.then((_) => done = true));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(done, isFalse);
      _append(file, '${full.substring(50)}\n');
      expect((await _await(s.result))!.recordId, 'H');
      await s.cancel();
    },
  );

  test('read errors from the source keep waiting', () async {
    final src = _FlakySource(file.path);
    final s = await PollingClientLogWatch(
      interval: const Duration(milliseconds: 20),
    ).start(src);
    src.failing = true;
    _append(file, '${_url('F')}\n');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    src.failing = false;
    expect((await _await(s.result))!.recordId, 'F');
    await s.cancel();
  });

  group('scanClientLogBackward', () {
    /// 以 [chunk] 位元組一段，由新到舊掃整份檔案。
    Future<ClientLogBackwardScan> scan(int chunk) => scanClientLogBackward(
      LocalFileLogSource(file.path),
      from: 0,
      to: file.lengthSync(),
      chunkBytes: chunk,
      prefix: Uint8List(0),
    );

    test('joins a url split across chunks', () async {
      _append(file, 'a\n${_url('SPLIT')}\n${'b' * 10}\n');
      for (final chunk in [7, 37, 64, 150]) {
        expect((await scan(chunk)).cred?.recordId, 'SPLIT', reason: '$chunk');
      }
    });

    test('never accepts the unfinished last line', () async {
      // 最後一行還沒換行（可能還在寫），即使看起來像完整網址也要留到下一輪。
      _append(file, 'a\n${_url('OK')}\n${_url('CUT')}');
      for (final chunk in [16, 64, 1000]) {
        final r = await scan(chunk);
        expect(r.cred?.recordId, 'OK', reason: '$chunk');
        expect(utf8.decode(r.tail), _url('CUT'), reason: '$chunk');
      }
    });
  });
}

/// [failing] 為 true 時 probe 丟例外的本機檔案來源。
class _FlakySource extends LocalFileLogSource {
  /// 建立讀 [path] 的來源。
  _FlakySource(super.path);

  /// 為 true 時所有讀取都失敗。
  bool failing = false;

  @override
  Future<ClientLogProbe> probe() {
    if (failing) throw const FileSystemException('flaky');
    return super.probe();
  }
}

/// 記錄讀了多少位元組的本機檔案來源。
class _CountingSource extends LocalFileLogSource {
  /// 建立讀 [path] 的來源。
  _CountingSource(super.path);

  /// 目前為止 [read] 讀到的位元組數（不含 [probe] 讀檔頭）。
  int bytesRead = 0;

  @override
  Future<Uint8List> read(int offset, int length) async {
    final out = await super.read(offset, length);
    if (offset > 0 || length != clientLogHeaderBytes) bytesRead += out.length;
    return out;
  }
}
