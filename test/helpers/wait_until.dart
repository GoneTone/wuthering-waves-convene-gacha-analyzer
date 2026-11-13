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

/// widget 測試用：被測程式在背景 isolate 做事、結果要真實時間才回來時，
/// 每輪讓背景跑一下（[WidgetTester.runAsync]）再推進畫面，直到 [cond] 成立
/// （最多 [timeout] 的實際時間），最後再 settle。
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!cond() && stopwatch.elapsed < timeout) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}
