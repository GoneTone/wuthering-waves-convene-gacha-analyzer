import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';

/// 將出率（0.0–1.0）格式化為固定兩位小數的百分比「數字」字串（不含 % 符號）。
String formatPercent(double rate) => (rate * 100).toStringAsFixed(2);

/// 組裝「佔比 · 平均間隔」副標題。
///
/// [rate] 為出率（0.0–1.0），[avg] 為平均間隔抽數；[avg] 為 null 時只回傳佔比，
/// 不接「· 平均間隔」段。
String formatRateWithAvg(AppLocalizations l, double rate, double? avg) {
  final pct = l.statsShareOfTotal(formatPercent(rate));
  if (avg == null) return pct;
  return '$pct · ${l.pityAverageInterval(avg.toStringAsFixed(2))}';
}
