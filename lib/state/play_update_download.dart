import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/play_update.dart';

/// 彈性更新下載狀態。
enum PlayDownloadPhase {
  /// 尚未開始，或下載被拒絕／失敗後回到的初始狀態。
  idle,

  /// 正在由 Play 下載。
  downloading,

  /// 下載完成，等待使用者重新啟動安裝。
  downloaded,
}

/// 管理 Google Play 彈性更新的下載與安裝。
class PlayUpdateDownloadNotifier extends Notifier<PlayDownloadPhase> {
  /// 此類別的 logger。
  static final _log = Logger('release');

  @override
  PlayDownloadPhase build() => PlayDownloadPhase.idle;

  /// 開始下載；已在下載或已下載完時不重複觸發。
  Future<void> start() async {
    if (state != PlayDownloadPhase.idle) return;
    state = PlayDownloadPhase.downloading;
    _log.info('play flexible update start');
    var result = PlayDownloadResult.failed;
    try {
      result = await ref.read(playUpdateGatewayProvider).downloadFlexible();
    } catch (e) {
      _log.warning('play flexible update threw: $e');
    }
    _log.info('play flexible update result=${result.name}');
    state = result == PlayDownloadResult.downloaded
        ? PlayDownloadPhase.downloaded
        : PlayDownloadPhase.idle;
  }

  /// 安裝已下載的更新；失敗只記 log，狀態維持不變。
  Future<void> install() async {
    _log.info('play flexible update install');
    try {
      await ref.read(playUpdateGatewayProvider).completeFlexible();
    } catch (e) {
      _log.warning('play flexible update install failed: $e');
    }
  }
}

/// 彈性更新下載狀態的 provider。
final playUpdateDownloadProvider =
    NotifierProvider<PlayUpdateDownloadNotifier, PlayDownloadPhase>(
      PlayUpdateDownloadNotifier.new,
    );
