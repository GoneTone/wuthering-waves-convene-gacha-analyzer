import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/log_access_setup_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_resolver.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/wuwa_game_package.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/app_link.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/manual_credential_dialog.dart';

/// Android 等待喚取記錄時的對話框內容：可以自動讀取時顯示進度與「開啟鳴潮」，
/// 沒有自動讀取方式時顯示原因與對應操作；兩種都提供手動輸入。
class AndroidLogWaitBody extends ConsumerStatefulWidget {
  /// 建立 [AndroidLogWaitBody]。
  const AndroidLogWaitBody({super.key, required this.progress});

  /// 目前的等待狀態。
  final WaitingForCapture progress;

  @override
  ConsumerState<AndroidLogWaitBody> createState() => _AndroidLogWaitBodyState();
}

/// [AndroidLogWaitBody] 的狀態：切回前景時重新判斷讀取方式。
class _AndroidLogWaitBodyState extends ConsumerState<AndroidLogWaitBody> {
  /// 切回前景時觸發重新判斷（玩家可能剛打開無線偵錯、授權或裝好遊戲）。
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_retryIfBlocked()),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// 沒有自動讀取方式時請 repository 重新判斷。
  ///
  /// Wi‑Fi 還沒允許無線偵錯時，玩家在系統視窗按「取消」也會回到本 App；這時重試會再跳一次詢問，
  /// 變成關不掉的迴圈，所以只有系統已經打開無線偵錯（玩家按了允許）才重試。
  Future<void> _retryIfBlocked() async {
    final reason = widget.progress.logAccessUnavailable;
    // 選版本要等玩家點，重新判斷只會讓畫面閃一下。
    if (reason == null || reason == LogAccessUnavailable.chooseGame) return;
    if (reason == LogAccessUnavailable.networkNotAllowed &&
        !await _wirelessTurnedOn()) {
      return;
    }
    if (!mounted) return;
    await ref.read(gachaRepositoryProvider.notifier).retryLogAccess();
  }

  /// 等系統打開無線偵錯（按「允許」後開關會晚一點才變），最多約 2 秒。
  Future<bool> _wirelessTurnedOn() async {
    final platform = ref.read(logAccessPlatformProvider);
    for (var i = 0; i < 5; i++) {
      if (await platform.isAdbWifiEnabled()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  /// 結束這次更新（等待對話框關閉）後開啟「讀取遊戲 log 檔」設定頁；配對完成後設定頁會重新開始更新。
  Future<void> _openSetup() async {
    final nav = Navigator.of(context, rootNavigator: true);
    final container = ProviderScope.containerOf(context);
    await ref.read(gachaRepositoryProvider.notifier).cancelCapture();
    await _untilIdle(container);
    // 等待對話框是在 progress 變成 null 時由它自己的 listener 關閉，晚一個事件迴圈再推頁面，
    // 以免被它的 popUntil 一起關掉。
    await Future<void>.delayed(Duration.zero);
    if (nav.mounted) unawaited(openLogAccessSetup(nav.context));
  }

  /// 等到沒有進行中的更新（最多 5 秒）。
  static Future<void> _untilIdle(ProviderContainer container) async {
    if (container.read(gachaRepositoryProvider).progress == null) return;
    final idle = Completer<void>();
    final sub = container.listen(
      gachaRepositoryProvider.select((s) => s.progress),
      (_, next) {
        if (next == null && !idle.isCompleted) idle.complete();
      },
    );
    try {
      await idle.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    } finally {
      sub.close();
    }
  }

  /// 重新請求儲存權限，再請 repository 重新判斷。
  Future<void> _regrantStorage() async {
    await ref
        .read(logAccessPlatformProvider)
        .requestStoragePermission(openSettingsIfBlocked: true);
    await ref.read(gachaRepositoryProvider.notifier).retryLogAccess();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final warning = theme.textTheme.bodySmall?.copyWith(
      color: theme.gacha.stateWarning,
    );
    final p = widget.progress;
    final reason = p.logAccessUnavailable;
    final platform = ref.read(logAccessPlatformProvider);

    final manualLink = TextButton(
      onPressed: () => showManualCredentialDialog(context),
      child: Text(l.progressManualInputLink, textAlign: TextAlign.center),
    );

    if (reason == LogAccessUnavailable.chooseGame) {
      final repo = ref.read(gachaRepositoryProvider.notifier);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.logChooseGameVersion, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.s),
          // 並排、太窄時換行：橫向時直排會把手動輸入擠出可見範圍。
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpacing.s,
            runSpacing: AppSpacing.s,
            children: [
              for (final game in p.installedGames)
                OutlinedButton(
                  onPressed: () => repo.selectGame(game),
                  child: Text(
                    gameVersionName(game, l),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s),
          manualLink,
        ],
      );
    }

    if (reason != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_reasonText(reason, l), textAlign: TextAlign.center),
          if (p.rootDenied) ...[
            const SizedBox(height: AppSpacing.s),
            Text(
              l.logRootDeniedHint,
              textAlign: TextAlign.center,
              style: warning,
            ),
          ],
          const SizedBox(height: AppSpacing.s),
          ?switch (reason) {
            LogAccessUnavailable.wirelessDebuggingOff => FilledButton(
              onPressed: platform.openWirelessDebugging,
              child: Text(l.actionOpenWirelessDebugging),
            ),
            LogAccessUnavailable.storagePermissionDenied => FilledButton(
              onPressed: _regrantStorage,
              child: Text(l.actionRegrantStorage),
            ),
            LogAccessUnavailable.notPaired => FilledButton(
              onPressed: _openSetup,
              child: Text(l.actionSetupLogAccess),
            ),
            LogAccessUnavailable.adbConnectFailed => FilledButton(
              onPressed: _openSetup,
              child: Text(l.actionRepair),
            ),
            LogAccessUnavailable.networkNotAllowed => FilledButton(
              onPressed: ref
                  .read(gachaRepositoryProvider.notifier)
                  .retryLogAccess,
              child: Text(l.actionRetry),
            ),
            // 兩顆並排，橫向時才不會把手動輸入擠出可見範圍；太窄時自動換行。
            LogAccessUnavailable.gameNotInstalled => Wrap(
              alignment: WrapAlignment.center,
              spacing: AppSpacing.s,
              runSpacing: AppSpacing.s,
              children: [
                FilledButton(
                  onPressed: ref
                      .read(gachaRepositoryProvider.notifier)
                      .retryLogAccess,
                  child: Text(l.actionRedetectGame),
                ),
                OutlinedButton(
                  onPressed: () => openExternalUrl(_playStoreGameUri),
                  child: Text(
                    l.updateOpenPlayStore,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
            _ => null,
          },
          manualLink,
        ],
      );
    }

    // 還不知道能不能自動讀取：不給「開啟鳴潮」與手動輸入，判斷完會換成其中一種畫面。
    if (p.checkingLogAccess) return const LinearProgressIndicator();

    if (p.credentialReady) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LinearProgressIndicator(),
          const SizedBox(height: AppSpacing.l),
          Text(l.progressCredentialReady, textAlign: TextAlign.center),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const LinearProgressIndicator(),
        const SizedBox(height: AppSpacing.l),
        Text(l.progressOpenGameHint, textAlign: TextAlign.center),
        if (p.isFallback) ...[
          const SizedBox(height: AppSpacing.s),
          Text(l.progressFallbackHint, style: theme.textTheme.bodySmall),
        ],
        if (p.logConnectionLost) ...[
          const SizedBox(height: AppSpacing.s),
          Text(
            l.progressLogConnectionLost,
            textAlign: TextAlign.center,
            style: warning,
          ),
        ],
        // 版本做成按鈕放在「開啟鳴潮」旁邊，點了就切換；不多佔一行，橫向時手動輸入才不會被擠出可見範圍。
        if (p.gamePackage case final game?)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s),
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppSpacing.s,
              runSpacing: AppSpacing.xs,
              children: [
                FilledButton.icon(
                  onPressed: () => platform.launchGame(game),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(l.actionOpenGame),
                ),
                if (p.installedGames.length > 1)
                  Tooltip(
                    message: l.actionSwitchGameVersion,
                    child: TextButton.icon(
                      onPressed: ref
                          .read(gachaRepositoryProvider.notifier)
                          .switchGameVersion,
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: Text(
                        l.progressGameVersion(gameVersionName(game, l)),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.s),
        manualLink,
      ],
    );
  }

  /// 各原因對應的說明文字。
  static String _reasonText(
    LogAccessUnavailable reason,
    AppLocalizations l,
  ) => switch (reason) {
    LogAccessUnavailable.notPaired => l.logUnavailableNotPaired,
    LogAccessUnavailable.noWifi => l.logUnavailableNoWifi,
    LogAccessUnavailable.adbConnectFailed => l.logUnavailableAdbFailed,
    LogAccessUnavailable.wirelessDebuggingOff => l.logUnavailableWirelessOff,
    LogAccessUnavailable.storagePermissionDenied => l.logUnavailableStorage,
    LogAccessUnavailable.unsupported => l.logUnavailableUnsupported,
    LogAccessUnavailable.networkNotAllowed => l.logUnavailableNetworkNotAllowed,
    LogAccessUnavailable.gameNotInstalled => l.logUnavailableGameNotInstalled,
    LogAccessUnavailable.chooseGame => l.logChooseGameVersion,
  };
}

/// 鳴潮在 Google Play 的頁面（找不到遊戲時的「前往 Google Play」）。
final _playStoreGameUri = Uri.parse(
  'https://play.google.com/store/apps/details?id=$wuwaGlobalPackage',
);

/// [package] 版本的顯示名稱；沒見過的版本直接顯示套件名稱。
String gameVersionName(String package, AppLocalizations l) => switch (package) {
  wuwaGlobalPackage => l.gameVersionGooglePlay,
  wuwaSamsungPackage => l.gameVersionGalaxyStore,
  _ => package,
};
