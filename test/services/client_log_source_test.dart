import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/client_log_source.dart';

/// 回傳固定字串輸出的 [ShellExec]。
ShellExec _out(String text) =>
    (_) async => Uint8List.fromList(utf8.encode(text));

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('client_log_source'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('read command quotes path and uses 1-based tail offset', () {
    expect(
      clientLogReadCommand('/a/Client.log', 0, 10),
      "tail -c +1 '/a/Client.log' | head -c 10",
    );
    expect(
      clientLogReadCommand('/a/Client.log', 99, 5),
      "tail -c +100 '/a/Client.log' | head -c 5",
    );
  });

  test('length command quotes path', () {
    expect(
      clientLogLengthCommand('/a/Client.log'),
      "stat -c %s '/a/Client.log'",
    );
  });

  test('read command rejects quote in path and bad ranges', () {
    expect(() => clientLogReadCommand("/a/x'y", 0, 1), throwsArgumentError);
    expect(() => clientLogReadCommand('/a', -1, 1), throwsArgumentError);
    expect(() => clientLogReadCommand('/a', 0, 0), throwsArgumentError);
    expect(() => clientLogLengthCommand("/a/x'y"), throwsArgumentError);
  });

  test(
    'shell length parses trimmed stat output, empty or garbage is 0',
    () async {
      for (final (out, want) in [
        ('1234\n', 1234),
        ('', 0),
        ('stat: No such file\n', 0),
      ]) {
        expect(
          await ShellLogSource(exec: _out(out)).length(),
          want,
          reason: out,
        );
      }
    },
  );

  test('shell length sends the length command for the android path', () async {
    final sent = <String>[];
    final src = ShellLogSource(
      exec: (c) async {
        sent.add(c);
        return Uint8List.fromList(utf8.encode('7\n'));
      },
    );
    await src.length();
    expect(sent.single, clientLogLengthCommand(androidClientLogPath));
  });

  test('shell read sends the read command and returns raw bytes', () async {
    final sent = <String>[];
    final src = ShellLogSource(
      exec: (c) async {
        sent.add(c);
        return Uint8List.fromList([1, 2, 3]);
      },
    );
    expect(await src.read(5, 3), [1, 2, 3]);
    expect(sent.single, clientLogReadCommand(androidClientLogPath, 5, 3));
  });

  test('local file source: missing file has length 0', () async {
    expect(await LocalFileLogSource('${tmp.path}/nope.log').length(), 0);
  });

  test('local file source reads the requested range', () async {
    final f = File('${tmp.path}/Client.log')..writeAsBytesSync([9, 8, 7, 6, 5]);
    final src = LocalFileLogSource(f.path);
    expect(await src.length(), 5);
    expect(await src.read(1, 3), [8, 7, 6]);
  });
}
