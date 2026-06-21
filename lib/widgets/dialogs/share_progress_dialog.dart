import 'package:flutter/material.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/app_dialog.dart';

/// 顯示分享圖「生成中」進度視窗（不可關閉）。回傳的 Future 於視窗被 pop 時完成；
/// 呼叫端應在渲染完成或失敗時自行 pop 關閉，使用者無法手動關閉。
Future<void> showShareProgressDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const ShareProgressDialog(),
  );
}

/// 分享圖離屏渲染期間顯示的不可關閉進度視窗：圖示 + 文字標題 + [LinearProgressIndicator]，
/// 風格對齊 [UpdateProgressDialog]。
class ShareProgressDialog extends StatelessWidget {
  /// 建立 [ShareProgressDialog]。
  const ShareProgressDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final tokens = Theme.of(context).gacha;
    // canPop: false 讓使用者無法以返回鍵 / ESC 關閉，僅由渲染流程結束時程式化 pop。
    return PopScope(
      canPop: false,
      child: AppDialog(
        title: Row(
          children: [
            Icon(Icons.image_outlined, color: tokens.textPrimary),
            const SizedBox(width: AppSpacing.s),
            Expanded(child: Text(l.shareImageGenerating)),
          ],
        ),
        content: const LinearProgressIndicator(),
      ),
    );
  }
}
