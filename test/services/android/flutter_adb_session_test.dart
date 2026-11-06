import 'dart:typed_data';

import 'package:flutter_adb/adb_connection.dart';
import 'package:flutter_adb/adb_protocol.dart';
import 'package:flutter_adb/adb_stream.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/flutter_adb_session.dart';

/// 開出的串流永遠不回應的連線替身，記錄送出的訊息。
class _SilentConnection implements AdbConnection {
  /// 送出的訊息。
  final sent = <Uint8List>[];

  @override
  Future<AdbStream> open(String destination) async =>
      AdbStream(1, this)..remoteId = 9;

  @override
  Future<void> sendMessage(Uint8List messageData, {bool flush = false}) async =>
      sent.add(messageData);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('timed-out shell closes its stream on the device side', () async {
    // 不送 CLSE 的話裝置端串流一直開著，下一個串流可能拿到相同的 localId。
    final conn = _SilentConnection();
    final session = FlutterAdbSession(
      conn,
      timeout: const Duration(milliseconds: 10),
    );
    await expectLater(session.shell('id'), throwsA(anything));
    expect(conn.sent, [AdbProtocol.generateClose(1, 9)]);
  });
}
