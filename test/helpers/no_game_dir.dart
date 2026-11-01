import 'package:wuthering_waves_convene_gacha_analyzer/services/game_dir_locator.dart';

/// 一律回報找不到遊戲資料夾的 locator，讓測試不碰真實登錄檔與檔案系統。
class NoGameDirLocator extends GameDirLocator {
  @override
  Future<GameDirLocation?> locate({String? settingDir}) async => null;
}

/// 停用 Client.log 監看的 override；凡會建立 `GachaRepository` 的測試 container 都要加。
final noGameDirOverride = gameDirLocatorProvider.overrideWithValue(
  NoGameDirLocator(),
);
