import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/client_log_credential.dart';

import '../helpers/client_log_fixtures.dart';

void main() {
  const host = 'https://aki-gm-resources-oversea.aki-game.net';
  const path = '/aki/gacha/index.html#/record?svr_id=S&record_id=';

  group('decodeClientLogBytes', () {
    test('原始奇數位元組 XOR 0xA5、偶數位元組 XOR 0xEF', () {
      expect(decodeClientLogBytes(Uint8List.fromList([0xAF])), [0x0A]);
      expect(decodeClientLogBytes(Uint8List.fromList([0x0A])), [0xE5]);
    });

    test('可還原 encodeClientLog 的輸出且不改動輸入', () {
      final raw = encodeClientLog('abc\n');
      final copy = Uint8List.fromList(raw);
      expect(utf8.decode(decodeClientLogBytes(raw)), 'abc\n');
      expect(raw, copy);
    });
  });

  group('findConveneUrls', () {
    test('多筆時依出現順序全部回傳', () {
      final text = 'a $host${path}A1 b\n$host${path}B2 c';
      expect(findConveneUrls(text), ['$host${path}A1', '$host${path}B2']);
    });

    for (final end in ['"', ',', ' ', '\n']) {
      test('遇到 ${jsonEncode(end)} 結尾即停止', () {
        expect(findConveneUrls('$host${path}X$end tail'), ['$host${path}X']);
      });
    }

    test('只有國服 host 時回傳空清單', () {
      const cn =
          'https://aki-gm-resources.aki-game.com/aki/gacha/index.html#/record?record_id=A';
      expect(findConveneUrls(cn), isEmpty);
    });
  });

  group('latestCredentialIn', () {
    String url(String id) =>
        '$host/aki/gacha/index.html#/record?svr_id=s&player_id=1&lang=en'
        '&gacha_id=1&resources_id=r&record_id=$id';

    // 飛航模式在遊戲內複製到的整段錯誤頁文字（帳號資料為假值）。
    const airplaneText =
        '網頁無法使用\n無法載入位於 '
        'https://aki-gm-resources-oversea.aki-game.net/aki/gacha/index.html#/record'
        '?svr_id=s1&player_id=700000001&lang=zh-Hant&gacha_id=100087&gacha_type=1'
        '&svr_area=global&record_id=rec1&resources_id=res1&platform=Android '
        '的網頁，原因如下：\n\nnet::ERR_NAME_NOT_RESOLVED';

    test('從飛航模式複製的整段錯誤頁文字取出憑證', () {
      final c = latestCredentialIn(airplaneText)!;
      expect(c.recordId, 'rec1');
      expect(c.playerId, '700000001');
      expect(c.cardPoolId, 'res1');
    });

    test('網址後緊接全形標點仍能正確解析', () {
      expect(latestCredentialIn('「${url('rec2')}」。')!.recordId, 'rec2');
    });

    test('多個網址取最新且合法的那個', () {
      expect(
        latestCredentialIn('${url('old')} ${url('new')}')!.recordId,
        'new',
      );
      final bad = url('x').replaceAll('&record_id=x', '');
      final rejected = <FormatException>[];
      expect(
        latestCredentialIn(
          '${url('ok')}\n$bad',
          onRejected: rejected.add,
        )!.recordId,
        'ok',
      );
      expect(rejected, hasLength(1));
    });

    test('沒有網址時回傳 null', () {
      expect(latestCredentialIn('hello'), isNull);
    });

    test('Client.log 位元組會先解碼再找網址', () {
      expect(
        credentialFromClientLogBytes(
          encodeClientLog('x ${url('r3')}\n'),
        )!.recordId,
        'r3',
      );
    });
  });
}
