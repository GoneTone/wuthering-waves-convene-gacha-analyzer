import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:win32_registry/win32_registry.dart';

import 'log_sanitize.dart';

/// 遊戲資料夾的來源。
enum GameDirSource {
  /// 使用者在設定中指定。
  setting,

  /// 從登錄檔的啟動器安裝路徑推得。
  registry,

  /// 常見預設安裝路徑。
  common,
}

/// 已確認有效的遊戲資料夾與其來源。
class GameDirLocation {
  /// 建立定位結果。
  const GameDirLocation(this.path, this.source);

  /// 遊戲資料夾（內含 `Client\Saved\Logs\Client.log`）。
  final String path;

  /// 該資料夾是從哪裡找到的。
  final GameDirSource source;
}

/// 讀取登錄檔中所有啟動器 InstallPath 的函式（可注入以利測試）。
typedef RegistryInstallPathReader = Future<List<String>> Function();

/// 尋找並驗證鳴潮遊戲資料夾（設定 → 登錄檔 → 常見路徑）。
class GameDirLocator {
  /// 建立 locator；[readInstallPaths]、[commonDirs] 預設為真實登錄檔與常見路徑。
  GameDirLocator({
    RegistryInstallPathReader? readInstallPaths,
    List<String>? commonDirs,
  }) : _readInstallPaths = readInstallPaths ?? _readRegistryInstallPaths,
       _commonDirs = commonDirs ?? _defaultCommonDirs;

  static final Logger _log = Logger('gacha.clientLog');

  /// 啟動器資料夾底下的遊戲子資料夾名稱。
  static const String _gameSubDir = 'Wuthering Waves Game';

  /// 預設常見安裝路徑（Epic／Xbox 路徑無法查證，故不列入）。
  static const List<String> _defaultCommonDirs = [
    r'C:\Program Files\Wuthering Waves\Wuthering Waves Game',
    r'C:\Wuthering Waves\Wuthering Waves Game',
    r'C:\Program Files (x86)\Steam\steamapps\common\Wuthering Waves\Wuthering Waves Game',
  ];

  /// 啟動器解除安裝項目在登錄檔的子路徑（WOW6432Node 以外的 hive 共用）。
  static const String _uninstallPath =
      r'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\KRInstall Wuthering Waves Overseas';

  /// 依序查詢的（hive，子路徑），InstallPath 值存於其下。
  static const List<(RegistryHive, String)> _registryKeys = [
    (
      RegistryHive.localMachine,
      r'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\KRInstall Wuthering Waves Overseas',
    ),
    (RegistryHive.localMachine, _uninstallPath),
    (RegistryHive.currentUser, _uninstallPath),
  ];

  /// 讀取登錄檔 InstallPath 的函式。
  final RegistryInstallPathReader _readInstallPaths;

  /// 常見安裝路徑清單。
  final List<String> _commonDirs;

  /// 依序查 [_registryKeys]，回傳所有讀到的 InstallPath；key 或值不存在、讀值失敗都只略過該 key。
  static Future<List<String>> _readRegistryInstallPaths() async {
    final paths = <String>[];
    for (final (hive, path) in _registryKeys) {
      final RegistryKey key;
      try {
        key = Registry.openPath(hive, path: path);
      } on Exception {
        continue;
      }
      try {
        final value = key.getStringValue('InstallPath')?.trim();
        if (value != null && value.isNotEmpty) paths.add(value);
      } on Exception catch (e) {
        _log.warning(
          'registry value read failed hive=${hive.name} error=${e.runtimeType}',
        );
      } finally {
        key.close();
      }
    }
    return paths;
  }

  /// `<gameDir>\Client\Saved\Logs\Client.log` 的路徑。
  static String clientLogPath(String gameDir) =>
      '$gameDir\\Client\\Saved\\Logs\\Client.log';

  /// 有效遊戲資料夾 ⇔ Client.log 存在。
  Future<bool> _isValid(String dir) => File(clientLogPath(dir)).exists();

  /// 驗證 [picked]：本身有效回傳自身；選到啟動器資料夾則修正為其遊戲子資料夾；否則 null。
  Future<String?> normalize(String picked) async {
    if (await _isValid(picked)) return picked;
    final sub = '$picked\\$_gameSubDir';
    if (await _isValid(sub)) return sub;
    return null;
  }

  /// 依 [settingDir] → 登錄檔 → 常見路徑的順序找第一個有效的遊戲資料夾。
  Future<GameDirLocation?> locate({String? settingDir}) async {
    final found =
        await _firstValid(GameDirSource.setting, [?settingDir]) ??
        await _firstValid(GameDirSource.registry, await _safeRegistry()) ??
        await _firstValid(GameDirSource.common, _commonDirs);
    if (found == null) {
      _log.info('game dir not found');
    } else {
      _log.info(
        'game dir resolved source=${found.source.name} '
        'path=${sanitizeFsPath(found.path)}',
      );
    }
    return found;
  }

  /// 讀登錄檔；任何例外只記 log 並視為空清單。
  Future<List<String>> _safeRegistry() async {
    try {
      return await _readInstallPaths();
    } catch (e) {
      _log.warning('registry read failed error=$e');
      return const [];
    }
  }

  /// 回傳 [candidates] 中第一個經 normalize 有效者。
  Future<GameDirLocation?> _firstValid(
    GameDirSource source,
    List<String> candidates,
  ) async {
    for (final c in candidates) {
      final dir = await normalize(c);
      if (dir != null) return GameDirLocation(dir, source);
    }
    return null;
  }
}

/// 提供 [GameDirLocator] 單例。
final gameDirLocatorProvider = Provider<GameDirLocator>(
  (ref) => GameDirLocator(),
);
