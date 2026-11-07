import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_update/in_app_update.dart';

/// Play 回報的更新資訊。
class PlayUpdateInfo {
  /// 建立 [PlayUpdateInfo]。
  const PlayUpdateInfo({
    required this.available,
    required this.availableVersionCode,
    required this.flexibleAllowed,
  });

  /// Play 是否有可用的新版。
  final bool available;

  /// Play 上新版的 versionCode；無新版時可能為 null。
  final int? availableVersionCode;

  /// 此次更新是否允許彈性（背景下載）更新。
  final bool flexibleAllowed;
}

/// 彈性更新下載的結果。
enum PlayDownloadResult {
  /// 下載完成，可呼叫 [PlayUpdateGateway.completeFlexible] 安裝。
  downloaded,

  /// 使用者拒絕更新。
  denied,

  /// 下載或啟動更新失敗。
  failed,
}

/// in_app_update 的最小介面（測試替換用）。
abstract class PlayUpdateGateway {
  /// 查詢 Play 是否有新版；不是從 Play 安裝等狀況會拋例外。
  Future<PlayUpdateInfo> check();

  /// 開始彈性更新，下載完成才回傳。
  Future<PlayDownloadResult> downloadFlexible();

  /// 安裝已下載的更新（App 會重新啟動）。
  Future<void> completeFlexible();
}

/// 以 `in_app_update` 套件實作的 [PlayUpdateGateway]。
class InAppUpdatePlayGateway implements PlayUpdateGateway {
  @override
  Future<PlayUpdateInfo> check() async {
    final info = await InAppUpdate.checkForUpdate();
    return PlayUpdateInfo(
      available: info.updateAvailability == UpdateAvailability.updateAvailable,
      availableVersionCode: info.availableVersionCode,
      flexibleAllowed: info.flexibleUpdateAllowed,
    );
  }

  @override
  Future<PlayDownloadResult> downloadFlexible() async {
    try {
      return switch (await InAppUpdate.startFlexibleUpdate()) {
        AppUpdateResult.success => PlayDownloadResult.downloaded,
        AppUpdateResult.userDeniedUpdate => PlayDownloadResult.denied,
        AppUpdateResult.inAppUpdateFailed => PlayDownloadResult.failed,
      };
    } on PlatformException {
      return PlayDownloadResult.failed;
    }
  }

  @override
  Future<void> completeFlexible() => InAppUpdate.completeFlexibleUpdate();
}

/// [PlayUpdateGateway] 的 provider；測試 override 成 fake。
final playUpdateGatewayProvider = Provider<PlayUpdateGateway>(
  (ref) => InAppUpdatePlayGateway(),
);
