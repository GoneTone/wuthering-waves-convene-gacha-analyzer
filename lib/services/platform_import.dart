import 'package:flutter/widgets.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/importers/wuwa_tracker_importer.dart';

/// 以物品名稱解析回真實 resourceId 與 kind；查無回 null。
/// 供 importer 回填缺 id 的紀錄（如以 encore 清單建立）。
typedef ItemNameResolver = ({int id, String kind})? Function(String name);

/// 第三方平台匯入器：把該平台的匯出檔轉成本軟體的 [AccountsBundle]，之後接回
/// 既有匯入下游（帳號挑選 → 確認 → 合併寫入＋補圖）。新增平台＝加一個實作類別
/// 並在 [kPlatformImporters] 註冊一行。
abstract interface class PlatformImporter {
  /// 穩定識別鍵（如 `'wuwa_tracker'`）。
  String get id;

  /// 平台顯示名（在地化）。
  String displayName(AppLocalizations l);

  /// 平台清單列的副標（在地化）；null 表示不顯示。
  String? subtitle(AppLocalizations l);

  /// 平台清單列的前置 icon。
  IconData get icon;

  /// 可接受的副檔名（如 `['json']`）。
  List<String> get fileExtensions;

  /// 解析檔案內容為 [AccountsBundle]。
  ///
  /// 非此平台格式丟 `ForeignBundleException`；結構／型別不符丟 [FormatException]。
  /// [nameResolver]：缺 id 紀錄的名稱解析器（如 encore 清單），null＝不解析。
  AccountsBundle parse(String content, {ItemNameResolver? nameResolver});
}

/// 已支援的第三方平台清單。新增平台時在此追加。
const List<PlatformImporter> kPlatformImporters = [WuwaTrackerImporter()];
