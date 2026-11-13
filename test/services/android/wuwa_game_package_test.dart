import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/wuwa_game_package.dart';

void main() {
  test('only global wuthering waves package names are accepted', () {
    for (final ok in [
      wuwaGlobalPackage,
      wuwaSamsungPackage,
      wuwaPackagePrefix,
      '$wuwaPackagePrefix.store_2',
    ]) {
      expect(isWuwaPackage(ok), isTrue, reason: ok);
    }
    for (final bad in [
      'com.kurogame.mingchao',
      'com.kurogame.wutheringwavesx',
      "$wuwaPackagePrefix.x'; rm -rf /",
      '$wuwaPackagePrefix.',
      '$wuwaPackagePrefix.a/b',
    ]) {
      expect(isWuwaPackage(bad), isFalse, reason: bad);
    }
  });

  test('log path follows the package and rejects others', () {
    expect(
      androidClientLogPathFor(wuwaSamsungPackage),
      '/sdcard/Android/data/$wuwaSamsungPackage/files/UE4Game/'
      'Client/Client/Saved/Logs/Client.log',
    );
    expect(
      () => androidClientLogPathFor("com.kurogame.mingchao'"),
      throwsArgumentError,
    );
  });

  test('known versions come first, others sorted, duplicates dropped', () {
    expect(
      sortWuwaPackages([
        '$wuwaPackagePrefix.zz',
        wuwaSamsungPackage,
        'com.example.other',
        '$wuwaPackagePrefix.aa',
        wuwaGlobalPackage,
        wuwaSamsungPackage,
      ]),
      [
        wuwaGlobalPackage,
        wuwaSamsungPackage,
        '$wuwaPackagePrefix.aa',
        '$wuwaPackagePrefix.zz',
      ],
    );
  });
}
