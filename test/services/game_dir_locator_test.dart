import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/game_dir_locator.dart';

void main() {
  late Directory tmp;

  /// 在 [dir] 下建立假的有效遊戲資料夾（含 Client.log）。
  String makeGameDir(String dir) {
    File(GameDirLocator.clientLogPath(dir)).createSync(recursive: true);
    return dir;
  }

  setUp(() => tmp = Directory.systemTemp.createTempSync('gdl_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('normalize', () {
    test('valid game dir returns itself', () async {
      final game = makeGameDir('${tmp.path}\\Game');
      expect(await GameDirLocator().normalize(game), game);
    });

    test('launcher dir is corrected to its game subfolder', () async {
      final launcher = '${tmp.path}\\Wuthering Waves';
      final game = makeGameDir('$launcher\\Wuthering Waves Game');
      expect(await GameDirLocator().normalize(launcher), game);
    });

    test('empty dir returns null', () async {
      expect(await GameDirLocator().normalize(tmp.path), isNull);
    });
  });

  group('locate', () {
    test('valid setting wins', () async {
      final game = makeGameDir('${tmp.path}\\S');
      final r = await GameDirLocator(
        readInstallPaths: () async => [],
        commonDirs: [],
      ).locate(settingDir: game);
      expect(r?.path, game);
      expect(r?.source, GameDirSource.setting);
    });

    test('invalid setting falls back to registry', () async {
      final launcher = '${tmp.path}\\L';
      final game = makeGameDir('$launcher\\Wuthering Waves Game');
      final r = await GameDirLocator(
        readInstallPaths: () async => [launcher],
        commonDirs: [],
      ).locate(settingDir: '${tmp.path}\\nope');
      expect(r?.path, game);
      expect(r?.source, GameDirSource.registry);
    });

    test('empty registry falls back to first valid common dir', () async {
      final game = makeGameDir('${tmp.path}\\C2');
      final r = await GameDirLocator(
        readInstallPaths: () async => [],
        commonDirs: ['${tmp.path}\\C1', game],
      ).locate();
      expect(r?.path, game);
      expect(r?.source, GameDirSource.common);
    });

    test('nothing valid returns null', () async {
      final r = await GameDirLocator(
        readInstallPaths: () async => [],
        commonDirs: ['${tmp.path}\\x'],
      ).locate();
      expect(r, isNull);
    });

    test('reader exception does not propagate', () async {
      final game = makeGameDir('${tmp.path}\\C');
      final r = await GameDirLocator(
        readInstallPaths: () async => throw Exception('boom'),
        commonDirs: [game],
      ).locate();
      expect(r?.source, GameDirSource.common);
    });
  });
}
