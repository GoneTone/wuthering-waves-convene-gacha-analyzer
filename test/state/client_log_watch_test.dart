import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/client_log_watch.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import '../helpers/client_log_fixtures.dart';

/// 以 [id] 為 record_id 組出一筆完整的國際服喚取 URL。
String _url(String id) =>
    'https://aki-gm-resources-oversea.aki-game.net/aki/gacha/index.html#/record'
    '?svr_id=s&player_id=1&lang=en&gacha_id=1&resources_id=r&record_id=$id';

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

  /// 啟動監看並登記，tearDown 前由測試自行 cancel。
  /// 啟動監看。
  CaptureSession begin() => PollingClientLogWatch(
    interval: const Duration(milliseconds: 20),
  ).start(file.path);

  test('ignores url written before start', () async {
    _append(file, '${_url('A')}\n');
    final s = begin();
    var done = false;
    unawaited(s.result.then((_) => done = true));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(done, isFalse);
    await s.cancel();
    expect(await _await(s.result), isNull);
    await s.cancel();
  });

  test('completes with url appended after start', () async {
    final s = begin();
    _append(file, 'noise ${_url('B')}\n');
    expect((await _await(s.result))!.recordId, 'B');
    await s.cancel();
  });

  test('joins url split across two reads', () async {
    final s = begin();
    final full = _url('SPLIT');
    _append(file, full.substring(0, 80));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _append(file, '${full.substring(80)}\n');
    expect((await _await(s.result))!.recordId, 'SPLIT');
    await s.cancel();
  });

  test('resets offset when file shrinks', () async {
    _append(file, '${'x' * 400}\n');
    final s = begin();
    file.writeAsBytesSync(encodeClientLog('${_url('C')}\n'));
    expect((await _await(s.result))!.recordId, 'C');
    await s.cancel();
  });

  test('missing file then created', () async {
    final warnings = <LogRecord>[];
    final sub = Logger('gacha.clientLog').onRecord.listen((r) {
      if (r.level >= Level.WARNING) warnings.add(r);
    });
    final s = begin();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(warnings, isEmpty);
    _append(file, '${_url('D')}\n');
    expect((await _await(s.result))!.recordId, 'D');
    await s.cancel();
    await sub.cancel();
  });

  test('malformed url keeps waiting', () async {
    final s = begin();
    _append(file, '${_url('X').replaceAll('&record_id=X', '')}\n');
    var done = false;
    unawaited(s.result.then((_) => done = true));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(done, isFalse);
    _append(file, '${_url('E')}\n');
    expect((await _await(s.result))!.recordId, 'E');
    await s.cancel();
  });
}
