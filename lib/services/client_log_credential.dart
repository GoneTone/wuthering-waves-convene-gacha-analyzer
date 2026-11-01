import 'dart:typed_data';

/// 比對國際服喚取記錄頁 URL（含 fragment 內的 query），遇 `"`、空白、`,` 即結束。
final RegExp _conveneUrlPattern = RegExp(
  r'https://aki-gm-resources-oversea\.aki-game\.net/aki/gacha/index\.html#/record[^"\s,]*',
);

/// 解碼（亦即編碼，運算互為反函式）遊戲 Client.log 的逐位元組 XOR 混淆，回傳新 buffer。
Uint8List decodeClientLogBytes(Uint8List raw) {
  final out = Uint8List(raw.length);
  for (var i = 0; i < raw.length; i++) {
    final b = raw[i];
    out[i] = b ^ ((b & 1) != 0 ? 0xA5 : 0xEF);
  }
  return out;
}

/// 取 [text] 中最後一筆國際服喚取記錄 URL（最新、token 最可能有效）；無則回傳 null。
String? findLastConveneUrl(String text) {
  final matches = _conveneUrlPattern.allMatches(text);
  return matches.isEmpty ? null : matches.last.group(0);
}
