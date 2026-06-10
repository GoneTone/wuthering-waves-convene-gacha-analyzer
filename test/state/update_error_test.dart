import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/update_error.dart';

void main() {
  test('UpdateErrorGachaFailed carries code and message', () {
    const e = UpdateErrorGachaFailed(-1, '请求游戏获取日志异常!');
    expect(e, isA<UpdateError>());
    expect(e.code, -1);
    expect(e.message, '请求游戏获取日志异常!');
  });

  test('UpdateErrorNetwork is a const UpdateError', () {
    const e = UpdateErrorNetwork();
    expect(e, isA<UpdateError>());
  });

  test('UpdateErrorUnexpected is a const UpdateError', () {
    const e = UpdateErrorUnexpected();
    expect(e, isA<UpdateError>());
  });
}
