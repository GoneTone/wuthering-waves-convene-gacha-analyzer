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

  group('findLastConveneUrl', () {
    test('多筆時回傳最後一筆', () {
      final text = 'a $host${path}A1 b\n$host${path}B2 c';
      expect(findLastConveneUrl(text), '$host${path}B2');
    });

    for (final end in ['"', ',', ' ', '\n']) {
      test('遇到 ${jsonEncode(end)} 結尾即停止', () {
        expect(findLastConveneUrl('$host${path}X$end tail'), '$host${path}X');
      });
    }

    test('只有國服 host 時回傳 null', () {
      const cn =
          'https://aki-gm-resources.aki-game.com/aki/gacha/index.html#/record?record_id=A';
      expect(findLastConveneUrl(cn), isNull);
    });
  });
}
