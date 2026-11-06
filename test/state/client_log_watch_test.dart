import 'dart:async';
import 'dart:io';

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
  Future<CaptureSession> begin({int? maxReadBytes}) => PollingClientLogWatch(
    interval: const Duration(milliseconds: 20),
    maxReadBytes: maxReadBytes ?? 2 * 1024 * 1024,
  ).start(LocalFileLogSource(file.path));

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
}

/// [failing] 為 true 時 length/read 丟例外的本機檔案來源。
class _FlakySource extends LocalFileLogSource {
  /// 建立讀 [path] 的來源。
  _FlakySource(super.path);

  /// 為 true 時所有讀取都失敗。
  bool failing = false;

  @override
  Future<int> length() {
    if (failing) throw const FileSystemException('flaky');
    return super.length();
  }
}
