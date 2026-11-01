import 'dart:typed_data';

/// 比對國際服喚取記錄頁 URL（含 fragment 內的 query），遇 `"`、空白、`,` 即結束。
final RegExp _conveneUrlPattern = RegExp(
  r'https://aki-gm-resources-oversea\.aki-game\.net/aki/gacha/index\.html#/record[^"\s,]*',
);

/// 解碼遊戲 Client.log 的逐位元組 XOR 混淆，回傳新 buffer；金鑰依「原始（檔案內）位元組」奇偶選擇，
/// 因此並非自反運算（編碼只存在於測試 helper）。
Uint8List decodeClientLogBytes(Uint8List raw) {
  final out = Uint8List(raw.length);
  for (var i = 0; i < raw.length; i++) {
    final b = raw[i];
    out[i] = b ^ ((b & 1) != 0 ? 0xA5 : 0xEF);
  }
  return out;
}

/// 依出現順序（舊→新）回傳 [text] 中所有國際服喚取記錄 URL；呼叫端應由新往舊嘗試。
List<String> findConveneUrls(String text) => [
  for (final m in _conveneUrlPattern.allMatches(text)) m.group(0)!,
];
