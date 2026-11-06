import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/root_shell.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('root_shell'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// 建一個假的 su 執行檔路徑。
  String fakeSu() {
    final f = File('${tmp.path}/su')..writeAsStringSync('');
    return f.path;
  }

  test('su absent means no process is spawned', () async {
    var runs = 0;
    final shell = RootShell(
      suPaths: ['${tmp.path}/nope'],
      run: (exe, args) async {
        runs++;
        return ProcessResult(0, 0, '', '');
      },
    );
    expect(await shell.isSuPresent(), isFalse);
    expect(runs, 0);
  });

  test('root verify requires uid=0', () async {
    for (final (out, want) in [
      ('uid=2000(shell)', false),
      ('uid=0(root)', true),
    ]) {
      final shell = RootShell(
        suPaths: [fakeSu()],
        run: (exe, args) async => ProcessResult(0, 0, utf8.encode(out), ''),
      );
      expect(await shell.isSuPresent(), isTrue);
      expect(await shell.verify(), want, reason: out);
    }
  });

  test('verify is false when su is denied or throws', () async {
    final denied = RootShell(
      suPaths: [fakeSu()],
      run: (exe, args) async => ProcessResult(0, 1, <int>[], 'denied'),
    );
    expect(await denied.verify(), isFalse);
    final broken = RootShell(
      suPaths: [fakeSu()],
      run: (exe, args) => throw const ProcessException('su', []),
    );
    expect(await broken.verify(), isFalse);
  });

  test('exec runs su -c and returns raw stdout bytes', () async {
    late List<String> got;
    final shell = RootShell(
      suPaths: [fakeSu()],
      run: (exe, args) async {
        got = [exe, ...args];
        return ProcessResult(0, 0, [0xAF, 0x0A], '');
      },
    );
    expect(await shell.exec('cat x'), [0xAF, 0x0A]);
    expect(got, ['su', '-c', 'cat x']);
  });

  test('exec throws on non-zero exit', () async {
    final shell = RootShell(
      suPaths: [fakeSu()],
      run: (exe, args) async => ProcessResult(0, 1, <int>[], 'nope'),
    );
    await expectLater(shell.exec('x'), throwsA(isA<RootShellException>()));
  });
}
