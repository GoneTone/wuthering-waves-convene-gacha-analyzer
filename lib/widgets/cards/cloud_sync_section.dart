import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/cloud_sync.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/confirm_dialog.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/relative_time_text.dart';

/// 設定頁「雲端同步」區塊：連結 Google 帳號、自動同步開關、立即同步與中斷連結。
class CloudSyncSection extends ConsumerWidget {
  /// 建立 [CloudSyncSection]。
  const CloudSyncSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context)!;
    final tokens = Theme.of(context).gacha;

    if (!isCloudSyncConfigured) {
      return Text(
        l.cloudSyncUnconfigured,
        style: TextStyle(color: tokens.textMuted),
      );
    }

    final email = ref.watch(
      settingsProvider.select((s) => s.cloudAccountEmail),
    );
    final sync = ref.watch(cloudSyncProvider);

    if (email == null) {
      return _UnlinkedView(l: l, phase: sync.phase);
    }
    return _LinkedView(l: l, email: email, sync: sync);
  }
}

/// 未連結狀態：說明文字＋連結按鈕（授權等待中顯示 spinner 與取消）。
class _UnlinkedView extends ConsumerWidget {
  /// 建立 [_UnlinkedView]。
  const _UnlinkedView({required this.l, required this.phase});

  /// 當前 i18n 字串實例。
  final AppLocalizations l;

  /// 當前同步階段。
  final CloudSyncPhase phase;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).gacha;
    final awaiting = phase == CloudSyncPhase.awaitingConsent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.cloudSyncIntro, style: TextStyle(color: tokens.textSecondary)),
        if (phase == CloudSyncPhase.error) ...[
          const SizedBox(height: AppSpacing.s),
          Text(
            l.cloudSyncErrorAuthFailed,
            style: TextStyle(color: tokens.stateDanger),
          ),
        ],
        const SizedBox(height: AppSpacing.m),
        if (awaiting)
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppSpacing.m),
              Expanded(
                child: Text(
                  l.cloudSyncAwaitingConsent,
                  style: TextStyle(color: tokens.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(cloudSyncProvider.notifier).cancelLink(),
                child: Text(l.actionCancel),
              ),
            ],
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => ref.read(cloudSyncProvider.notifier).link(),
              icon: const Icon(Icons.link, size: 18),
              label: Text(l.cloudSyncLink),
            ),
          ),
      ],
    );
  }
}

/// 已連結狀態：email、自動同步開關、同步狀態列、立即同步與中斷連結。
class _LinkedView extends ConsumerWidget {
  /// 建立 [_LinkedView]。
  const _LinkedView({required this.l, required this.email, required this.sync});

  /// 當前 i18n 字串實例。
  final AppLocalizations l;

  /// 已連結帳號 email。
  final String email;

  /// 當前同步狀態。
  final CloudSyncState sync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).gacha;
    final autoSync = ref.watch(
      settingsProvider.select((s) => s.cloudAutoSyncEnabled),
    );
    final lastSyncedAt = ref.watch(
      settingsProvider.select((s) => s.cloudLastSyncedAt),
    );
    final syncing = sync.phase == CloudSyncPhase.syncing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.cloudSyncLinkedAs(email)),
        const SizedBox(height: AppSpacing.s),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.cloudSyncAutoToggle),
          subtitle: Text(
            l.cloudSyncAutoToggleHint,
            style: TextStyle(color: tokens.textMuted, fontSize: 12),
          ),
          value: autoSync,
          onChanged: (v) => ref.read(cloudSyncProvider.notifier).setAutoSync(v),
        ),
        const SizedBox(height: AppSpacing.s),
        _StatusLine(l: l, sync: sync, lastSyncedAt: lastSyncedAt),
        const SizedBox(height: AppSpacing.m),
        Wrap(
          spacing: AppSpacing.m,
          runSpacing: AppSpacing.s,
          children: [
            FilledButton.icon(
              onPressed: syncing
                  ? null
                  : () => ref
                        .read(cloudSyncProvider.notifier)
                        .syncNow(manual: true),
              icon: syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_sync, size: 18),
              label: Text(l.cloudSyncNow),
            ),
            if (sync.phase == CloudSyncPhase.reauthRequired)
              FilledButton.icon(
                onPressed: () => ref.read(cloudSyncProvider.notifier).link(),
                icon: const Icon(Icons.link, size: 18),
                label: Text(l.cloudSyncLink),
              ),
            OutlinedButton.icon(
              onPressed: () => _confirmUnlink(context, ref),
              icon: const Icon(Icons.link_off, size: 18),
              label: Text(l.cloudSyncUnlink),
            ),
          ],
        ),
      ],
    );
  }

  /// 彈出中斷連結確認框，確認後執行 unlink。
  Future<void> _confirmUnlink(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context)!;
    final ok = await showConfirmDialog(
      context: context,
      title: l.cloudSyncUnlinkConfirmTitle,
      body: l.cloudSyncUnlinkConfirmBody,
      cancelLabel: l.actionCancel,
      confirmLabel: l.cloudSyncUnlink,
      confirmIcon: Icons.link_off,
    );
    if (ok != true) return;
    await ref.read(cloudSyncProvider.notifier).unlink();
  }
}

/// 同步狀態列：依 phase 顯示上次同步時間或錯誤原因。
class _StatusLine extends StatelessWidget {
  /// 建立 [_StatusLine]。
  const _StatusLine({
    required this.l,
    required this.sync,
    required this.lastSyncedAt,
  });

  /// 當前 i18n 字串實例。
  final AppLocalizations l;

  /// 當前同步狀態。
  final CloudSyncState sync;

  /// 上次同步成功時間。
  final DateTime? lastSyncedAt;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).gacha;
    switch (sync.phase) {
      case CloudSyncPhase.reauthRequired:
        return Text(
          l.cloudSyncReauthRequired,
          style: TextStyle(color: tokens.stateDanger),
        );
      case CloudSyncPhase.error:
        final text = switch (sync.errorToken) {
          'busy' => l.cloudSyncErrorBusy,
          'schemaTooNew' => l.cloudSyncErrorSchemaTooNew,
          'authFailed' => l.cloudSyncErrorAuthFailed,
          _ => l.cloudSyncErrorNetwork,
        };
        return Text(text, style: TextStyle(color: tokens.stateDanger));
      case CloudSyncPhase.idle:
      case CloudSyncPhase.syncing:
      case CloudSyncPhase.awaitingConsent:
        final at = lastSyncedAt;
        if (at == null) {
          return Text(
            l.cloudSyncNeverSynced,
            style: TextStyle(color: tokens.textMuted),
          );
        }
        return RelativeTimeText(
          time: at,
          templateBuilder: l.cloudSyncLastSynced,
          style: TextStyle(color: tokens.textMuted),
        );
    }
  }
}
