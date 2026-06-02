import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_fetcher.dart';

void main() {
  test('GachaApiException carries code and message', () {
    const e = GachaApiException(-1, '请求游戏获取日志异常!');
    expect(e.code, -1);
    expect(e.message, '请求游戏获取日志异常!');
    expect(e, isA<Exception>());
    expect(e.toString(), contains('-1'));
    expect(e.toString(), contains('请求游戏获取日志异常!'));
  });
}
