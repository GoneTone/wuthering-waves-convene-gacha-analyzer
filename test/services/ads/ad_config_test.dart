import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/ads/ad_config.dart';

void main() {
  group('resolveBannerUnitId', () {
    test('release 且有注入時使用注入值', () {
      expect(
        resolveBannerUnitId(release: true, injected: 'ca-app-pub-1/2'),
        'ca-app-pub-1/2',
      );
    });

    test('release 但未注入時退回測試 ID', () {
      expect(
        resolveBannerUnitId(release: true, injected: ''),
        kTestAdmobBannerUnitId,
      );
    });

    test('非 release 一律使用測試 ID', () {
      expect(
        resolveBannerUnitId(release: false, injected: 'ca-app-pub-1/2'),
        kTestAdmobBannerUnitId,
      );
    });
  });

  group('resolveNativeUnitId', () {
    test('release 且有注入時使用注入值', () {
      expect(resolveNativeUnitId(release: true, injected: 'x'), 'x');
    });

    test('release 但未注入時退回測試 ID', () {
      expect(
        resolveNativeUnitId(release: true, injected: ''),
        kTestAdmobNativeUnitId,
      );
    });

    test('非 release 一律使用測試 ID', () {
      expect(
        resolveNativeUnitId(release: false, injected: 'x'),
        kTestAdmobNativeUnitId,
      );
    });
  });
}
