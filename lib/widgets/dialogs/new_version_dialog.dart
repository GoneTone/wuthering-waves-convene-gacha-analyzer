import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/app_release.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/play_update_download.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/app_link.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/app_dialog.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/release_notes_content.dart';

/// 新版本通知 dialog，列出自上次版本以來的所有 release notes。
class NewVersionDialog extends ConsumerWidget {
  /// 建立 [NewVersionDialog]，需傳入要顯示的 release 列表。
  const NewVersionDialog({super.key, required this.releases, this.playTag});

  /// 需要顯示的 release 列表（最新版在前）。
  final List<AppRelease> releases;

  /// Android 由 Play 換算出的新版 tag；有值時優先於 [releases] 作為版本號。
  final String? playTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final tokens = theme.gacha;
    final tag = playTag ?? releases.first.tagName;
    final isAndroid = ref.watch(isAndroidProvider);

    return AppDialog(
      size: AppDialogSize.lg,
      scrollable: true,
      title: Row(
        children: [
          Icon(Icons.system_update, color: tokens.stateSuccess),
          const SizedBox(width: AppSpacing.s),
          Expanded(child: Text(l.updateTitle(tag))),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (releases.isEmpty) Text(l.updateNotesUnavailable),
          for (int i = 0; i < releases.length; i++) ...[
            ReleaseNotesContent(release: releases[i]),
            if (i < releases.length - 1) const SizedBox(height: AppSpacing.m),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await ref.read(appReleaseProvider.notifier).skipVersion(tag);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(l.updateButtonSkip),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.updateButtonLater),
        ),
        FilledButton.icon(
          icon: Icon(isAndroid ? Icons.system_update_alt : Icons.download),
          label: Text(
            isAndroid ? l.updateButtonUpdate : l.updateButtonDownload,
          ),
          onPressed: () async {
            if (isAndroid) {
              unawaited(ref.read(playUpdateDownloadProvider.notifier).start());
            } else {
              await openExternalUrl(Uri.parse(releases.first.htmlUrl));
            }
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}
