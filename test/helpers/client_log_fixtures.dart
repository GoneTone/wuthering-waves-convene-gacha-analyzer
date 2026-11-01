import 'dart:convert';
import 'dart:typed_data';

/// 將 [text] 編碼成遊戲 Client.log 的混淆格式（`decodeClientLogBytes` 的反運算），供測試造 fixture。
Uint8List encodeClientLog(String text) => Uint8List.fromList([
  for (final p in utf8.encode(text)) p ^ ((p & 1) == 0 ? 0xA5 : 0xEF),
]);
