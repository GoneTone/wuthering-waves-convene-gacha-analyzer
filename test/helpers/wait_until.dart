import 'package:flutter_test/flutter_test.dart';

/// 反覆讓出事件迴圈直到 [cond] 成立，最多等 [timeout] 的實際時間。
///
/// 以時間而非固定輪數為上限：被測程式有真正的檔案 I/O，整套測試平行跑、機器忙時，
/// 1000 輪空轉可能在 I/O 回來前就跑完而誤判失敗。每輪仍只讓出一次（`Duration.zero`），
/// 條件一成立就返回，正常情況的速度與行為不變。
Future<void> waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!cond() && stopwatch.elapsed < timeout) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(cond(), isTrue, reason: 'condition never became true');
}
