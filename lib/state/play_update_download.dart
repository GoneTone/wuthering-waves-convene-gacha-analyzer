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
    final gateway = ref.read(playUpdateGatewayProvider);
    var result = PlayDownloadResult.failed;
    try {
      // 已下載完或不允許彈性更新時 plugin 不會啟動流程，也永遠不回覆，所以先重查再決定。
      final info = await gateway.check();
      if (info.downloaded) {
        result = PlayDownloadResult.downloaded;
      } else if (!info.flexibleAllowed) {
        _log.warning(
          'play flexible update not allowed '
          'availability=${info.updateAvailability.name} '
          'installStatus=${info.installStatus.name}',
        );
      } else {
        result = await gateway.downloadFlexible();
      }
    } catch (e) {
      _log.warning('play flexible update threw: $e');
    }
    _log.info('play flexible update result=${result.name}');
    state = result == PlayDownloadResult.downloaded
        ? PlayDownloadPhase.downloaded
        : PlayDownloadPhase.idle;
  }

  /// 依 Play 回報的進度同步狀態（例如重新開啟 App 時接續之前開始的更新）；只往前推進，不會倒退。
  ///
  /// shortcut: plugin 的進度事件只在本 process 呼叫過 startFlexibleUpdate 後才會送出，
  /// 所以接續中的下載要等下次檢查（手動檢查或下次啟動）才會變成 downloaded；
  /// 背景下載失敗也要到下次啟動才回到 idle。若 plugin 改成啟動就註冊監聽，再改用 installUpdateListener。
  void syncWithPlay(PlayUpdateInfo info) {
    if (info.downloaded) {
      state = PlayDownloadPhase.downloaded;
    } else if (info.downloading && state == PlayDownloadPhase.idle) {
      state = PlayDownloadPhase.downloading;
    }
  }

  /// 安裝已下載的更新；失敗只記 log，狀態維持不變。
  ///
  /// plugin 的 completeFlexibleUpdate 成功時不會回覆（App 直接重新啟動），
  /// 所以這裡只會收到前置條件不符（例如未先 check）之類的例外。
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
