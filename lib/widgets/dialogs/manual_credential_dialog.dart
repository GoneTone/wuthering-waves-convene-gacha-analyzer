import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/client_log_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/app_dialog.dart';

/// 本對話框的 logger。
final _log = Logger('capture.manual');

/// 顯示「手動輸入喚取記錄」對話框：貼上網址（或含網址的整段文字）或選 Client.log 檔案。
///
/// [pickClientLog] 僅供測試注入；預設開系統選檔視窗並讀出整份檔案。
Future<void> showManualCredentialDialog(
  BuildContext context, {
  Future<Uint8List?> Function()? pickClientLog,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ManualCredentialDialog(pickClientLog: pickClientLog),
);

/// 用系統選檔視窗選一個檔案並讀出內容；使用者取消時回 null。
Future<Uint8List?> _pickFileBytes() async {
  final file = await openFile();
  return file?.readAsBytes();
}

/// 手動輸入對話框實作。
class _ManualCredentialDialog extends ConsumerStatefulWidget {
  /// 建立 [_ManualCredentialDialog]。
  const _ManualCredentialDialog({this.pickClientLog});

  /// 選 Client.log 的函式；null 時用系統選檔視窗。
  final Future<Uint8List?> Function()? pickClientLog;

  @override
  ConsumerState<_ManualCredentialDialog> createState() =>
      _ManualCredentialDialogState();
}

/// [_ManualCredentialDialog] 的狀態：輸入內容與錯誤訊息。
class _ManualCredentialDialogState
    extends ConsumerState<_ManualCredentialDialog> {
  /// 網址輸入框的 controller。
  final _controller = TextEditingController();

  /// 目前顯示的錯誤訊息；沒有錯誤時為 null。
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 把剪貼簿文字填進輸入框。
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    setState(() {
      _controller.text = text;
      _error = null;
    });
  }

  /// 從輸入框文字找憑證，找到就送出並關閉。
  void _submitText() {
    final cred = latestCredentialIn(_controller.text);
    if (cred == null) {
      _log.info('manual input rejected: no convene url in pasted text');
      setState(
        () => _error = AppLocalizations.of(context)!.manualCredentialNotFound,
      );
      return;
    }
    _submit(cred);
  }

  /// 選 Client.log 檔案並從中找憑證，找到就送出並關閉。
  Future<void> _pickLog() async {
    final l = AppLocalizations.of(context)!;
    final Uint8List? bytes;
    try {
      bytes = await (widget.pickClientLog ?? _pickFileBytes)();
    } catch (e) {
      _log.warning('manual input file read failed error=${e.runtimeType}');
      if (mounted) setState(() => _error = l.manualCredentialNotFoundInLog);
      return;
    }
    if (bytes == null || !mounted) return;
    final cred = credentialFromClientLogBytes(bytes);
    if (cred == null) {
      _log.info(
        'manual input rejected: no convene url in file bytes=${bytes.length}',
      );
      setState(() => _error = l.manualCredentialNotFoundInLog);
      return;
    }
    _submit(cred);
  }

  /// 關閉對話框並把憑證交給 repository（等待中就完成等待，否則開始一次更新）。
  void _submit(GachaCredential cred) {
    Navigator.of(context).pop();
    unawaited(
      ref.read(gachaRepositoryProvider.notifier).submitManualCredential(cred),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final android = ref.watch(isAndroidProvider);

    return AppDialog(
      size: AppDialogSize.md,
      scrollable: true,
      title: Text(l.manualCredentialTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.manualCredentialHint),
          const SizedBox(height: AppSpacing.s),
          TextField(
            controller: _controller,
            minLines: 2,
            maxLines: 4,
            // 輸入法的自動校正會改掉網址參數名稱的大小寫（`lang` → `Lang`）。
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: l.manualCredentialFieldHint,
              errorText: _error,
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: AppSpacing.s),
          Wrap(
            spacing: AppSpacing.s,
            runSpacing: AppSpacing.s,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _paste,
                icon: const Icon(Icons.content_paste, size: 18),
                label: Text(l.manualCredentialPaste),
              ),
              OutlinedButton.icon(
                onPressed: _pickLog,
                icon: const Icon(Icons.description_outlined, size: 18),
                label: Text(l.manualCredentialPickLog),
              ),
            ],
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(l.manualCredentialHowTo),
            childrenPadding: const EdgeInsets.only(bottom: AppSpacing.s),
            expandedAlignment: AlignmentDirectional.centerStart,
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                android
                    ? l.manualCredentialHelpAndroid
                    : l.manualCredentialHelpWindows,
              ),
              const SizedBox(height: AppSpacing.s),
              Text(
                l.manualCredentialWarning,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.gacha.stateWarning,
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: _submitText,
          child: Text(l.manualCredentialSubmit),
        ),
      ],
    );
  }
}
