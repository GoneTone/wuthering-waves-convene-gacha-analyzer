import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_resolver.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
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

/// [AndroidLogWaitBody] 的狀態：遊戲是否安裝、切回前景時重新判斷讀取方式。
class _AndroidLogWaitBodyState extends ConsumerState<AndroidLogWaitBody> {
  /// 是否安裝了鳴潮（決定要不要顯示「開啟鳴潮」）。
  late final Future<bool> _installed;

  /// 切回前景時觸發重新判斷（玩家可能剛打開無線偵錯或授權）。
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _installed = ref.read(logAccessPlatformProvider).isGameInstalled();
    _lifecycle = AppLifecycleListener(onResume: _retryIfBlocked);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// 沒有自動讀取方式時請 repository 重新判斷。
  void _retryIfBlocked() {
    if (widget.progress.logAccessUnavailable == null) return;
    unawaited(ref.read(gachaRepositoryProvider.notifier).retryLogAccess());
  }

  /// 重新請求儲存權限，再請 repository 重新判斷。
  Future<void> _regrantStorage() async {
    await ref.read(logAccessPlatformProvider).requestStoragePermission();
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

    if (reason != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_reasonText(reason, l), textAlign: TextAlign.center),
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
            _ => null,
          },
          manualLink,
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
        FutureBuilder<bool>(
          future: _installed,
          builder: (context, snap) => snap.data == true
              ? Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s),
                  child: FilledButton.icon(
                    onPressed: platform.launchGame,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text(l.actionOpenGame),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: AppSpacing.s),
        manualLink,
      ],
    );
  }

  /// 各原因對應的說明文字。
  static String _reasonText(LogAccessUnavailable reason, AppLocalizations l) =>
      switch (reason) {
        LogAccessUnavailable.notPaired => l.logUnavailableNotPaired,
        LogAccessUnavailable.noWifi => l.logUnavailableNoWifi,
        LogAccessUnavailable.adbConnectFailed => l.logUnavailableAdbFailed,
        LogAccessUnavailable.wirelessDebuggingOff =>
          l.logUnavailableWirelessOff,
        LogAccessUnavailable.storagePermissionDenied => l.logUnavailableStorage,
        LogAccessUnavailable.unsupported => l.logUnavailableUnsupported,
      };
}
