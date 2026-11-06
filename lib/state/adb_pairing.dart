import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/adb_shell_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/flutter_adb_session.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_resolver.dart';

/// 無線偵錯設定流程的階段。
enum PairingPhase {
  /// 說明頁（事前揭露）。
  disclosure,

  /// 開發人員選項還沒開。
  needDevOptions,

  /// 通知權限還沒允許（配對碼要從通知輸入）。
  needNotifications,

  /// 可以前往無線偵錯開始配對。
  ready,

  /// 配對服務已啟動，等玩家在通知輸入配對碼。
  waitingCode,

  /// 正在配對與授權。
  pairing,

  /// 配對成功，但授權自己開關無線偵錯失敗（部分廠牌的安全性限制）。
  grantFailed,

  /// 設定完成（可以自動開關無線偵錯）。
  done,

  /// 設定完成，但每次更新要手動開啟無線偵錯（玩家略過授權）。
  doneManual,
}

/// 設定流程的狀態。
class AdbPairingState {
  /// 建立狀態。
  const AdbPairingState(this.phase, {this.notificationsDenied = false});

  /// 目前階段。
  final PairingPhase phase;

  /// 玩家拒絕過通知權限（畫面改為引導到 App 通知設定）。
  final bool notificationsDenied;

  /// 換階段，保留其他欄位。
  AdbPairingState to(PairingPhase next) =>
      AdbPairingState(next, notificationsDenied: notificationsDenied);
}

/// 無線偵錯設定流程：說明頁 → 開發人員選項 → 通知權限 → 配對 → 授權。
class AdbPairingController extends Notifier<AdbPairingState> {
  /// 本流程的 logger。
  static final _log = Logger('capture.pairing');

  /// 系統功能。
  LogAccessPlatform get _platform => ref.read(logAccessPlatformProvider);

  @override
  AdbPairingState build() {
    final platform = ref.read(logAccessPlatformProvider);
    platform.setPairingCodeHandler(handlePairingCode);
    ref.onDispose(() {
      platform.setPairingCodeHandler(null);
      unawaited(platform.stopPairingService());
    });
    return const AdbPairingState(PairingPhase.disclosure);
  }

  /// 玩家在說明頁按「開始設定」。
  Future<void> startSetup() async {
    _log.info('setup started');
    state = state.to(PairingPhase.needDevOptions);
    await refresh();
  }

  /// 從設定頁「重試授權」進入：直接到授權步驟。
  void startAtGrant() => state = state.to(PairingPhase.grantFailed);

  /// 依目前系統狀態更新階段（頁面回到前景時呼叫）；配對服務停了（逾時）就重新啟動。
  Future<void> refresh() async {
    final phase = state.phase;
    if (phase
        case PairingPhase.disclosure ||
            PairingPhase.pairing ||
            PairingPhase.grantFailed ||
            PairingPhase.done ||
            PairingPhase.doneManual) {
      return;
    }
    if (!await _platform.isDevelopmentSettingsEnabled()) {
      state = state.to(PairingPhase.needDevOptions);
      return;
    }
    if (!await _platform.areNotificationsEnabled()) {
      state = state.to(PairingPhase.needNotifications);
      return;
    }
    if (phase == PairingPhase.waitingCode) {
      if (!await _platform.isPairingServiceRunning()) {
        _log.info('pairing service not running, restarting');
        await _platform.startPairingService();
      }
      return;
    }
    state = state.to(PairingPhase.ready);
  }

  /// 請求通知權限；被拒絕時記下來，畫面改為引導到 App 通知設定。
  Future<void> requestNotifications() async {
    final granted = await _platform.requestNotificationPermission();
    _log.info('notification permission granted=$granted');
    if (!granted) {
      state = AdbPairingState(state.phase, notificationsDenied: true);
      return;
    }
    await refresh();
  }

  /// 啟動配對服務並跳到「無線偵錯」頁；約 3 分鐘的上限從這裡開始算。
  Future<void> openWirelessDebugging() async {
    await _platform.startPairingService();
    await _platform.openWirelessDebugging();
    state = state.to(PairingPhase.waitingCode);
  }

  /// 配對服務收到配對碼時呼叫：配對、連線並授權自己開關無線偵錯。回傳給通知顯示的結果（不含配對碼）。
  Future<({bool ok, String message})> handlePairingCode(
    int port,
    String code,
  ) async {
    state = state.to(PairingPhase.pairing);
    final ok = await ref.read(adbPairingOpsProvider).pair(port, code);
    _log.info('pairing ok=$ok');
    if (!ok) {
      state = state.to(PairingPhase.waitingCode);
      return (ok: false, message: 'pairing failed');
    }
    await _grant();
    return (ok: true, message: '');
  }

  /// 授權失敗後，玩家開了安全性選項再試一次。
  Future<void> retryGrant() async {
    state = state.to(PairingPhase.pairing);
    await _grant();
  }

  /// 玩家略過授權：之後每次更新手動開啟無線偵錯。
  void skipGrant() {
    _log.info('grant skipped, manual toggle mode');
    state = state.to(PairingPhase.doneManual);
  }

  /// 連上無線偵錯並授權自己 `WRITE_SECURE_SETTINGS`，依結果進入完成或授權失敗。
  Future<void> _grant() async {
    final platform = _platform;
    if (await platform.hasWriteSecureSettings()) {
      state = state.to(PairingPhase.done);
      return;
    }
    final ops = ref.read(adbPairingOpsProvider);
    final client = AdbShellClient(connect: ops.connect);
    try {
      final ports = await ref
          .read(logAccessResolverProvider)
          .discoverConnectPorts();
      if (await client.connectAny(ports)) {
        await client.exec(grantWriteSecureSettingsCommand);
      } else {
        _log.warning('grant: could not connect ports=${ports.length}');
      }
    } on AdbShellException catch (e) {
      _log.warning('grant command failed: ${e.message}');
    } finally {
      await client.close();
    }
    final granted = await platform.hasWriteSecureSettings();
    _log.info('write secure settings granted=$granted');
    state = state.to(granted ? PairingPhase.done : PairingPhase.grantFailed);
  }
}

/// 無線偵錯設定流程；離開設定頁時自動 dispose（停止配對服務）。
final adbPairingProvider =
    NotifierProvider.autoDispose<AdbPairingController, AdbPairingState>(
      AdbPairingController.new,
    );
