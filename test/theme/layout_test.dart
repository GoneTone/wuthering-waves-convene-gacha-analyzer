import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/theme/layout.dart';

void main() {
  for (final (platform, size, want) in [
    (TargetPlatform.android, const Size(360, 800), true),
    (TargetPlatform.android, const Size(800, 360), true),
    (TargetPlatform.android, const Size(1280, 800), false),
    (TargetPlatform.android, const Size(600, 1000), false),
    (TargetPlatform.windows, const Size(1093, 560), false),
    (TargetPlatform.windows, const Size(500, 900), true),
    (TargetPlatform.windows, const Size(600, 450), false),
    (TargetPlatform.windows, const Size(1280, 800), false),
  ]) {
    testWidgets(
      'isCompactLayout ${platform.name} ${size.width}x${size.height} is $want',
      (tester) async {
        late bool got;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(size: size),
            child: Builder(
              builder: (c) {
                got = isCompactLayout(c);
                return const SizedBox();
              },
            ),
          ),
        );
        expect(got, want);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
}
