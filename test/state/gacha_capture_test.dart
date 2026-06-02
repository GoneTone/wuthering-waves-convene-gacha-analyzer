import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';

void main() {
  test('CaptureSession.result resolves to a GachaCredential', () async {
    final cred = GachaCredential(
      playerId: '701000000',
      cardPoolId: '2e23deadbeef2768',
      serverId: '86d5deadbeef9650',
      recordId: '0632deadbeef8550',
      languageCode: 'zh-Hant',
    );
    final session = CaptureSession(
      result: Future.value(cred),
      cancel: () async {},
    );
    final got = await session.result;
    expect(got, isNotNull);
    expect(got!.playerId, '701000000');
    expect(got.languageCode, 'zh-Hant');
  });
}
