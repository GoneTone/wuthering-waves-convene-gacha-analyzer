import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 手機排版的門檻（dp）：手機作業系統比較短邊、電腦作業系統比較寬度。
const double kCompactBreakpoint = 600;

/// 是否使用手機排版（抽屜導覽、精簡標題列、12dp 對話框邊距等）。
///
/// 手機作業系統看短邊，轉向不會改變結果；電腦作業系統只看寬度，
/// 寬而矮的筆電視窗仍維持側欄，只有把視窗拉窄才切換。
bool isCompactLayout(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final mobileOs = switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };
  return (mobileOs ? size.shortestSide : size.width) < kCompactBreakpoint;
}
