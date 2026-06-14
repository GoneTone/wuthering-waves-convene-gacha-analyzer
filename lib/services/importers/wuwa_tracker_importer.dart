import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/data/gacha_types.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/accounts_import.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/platform_import.dart';

/// Logger 實例（第三方平台匯入）。
final _log = Logger('wish.import.platform');

/// 鳴潮全球統一伺服器時間相對 UTC 的固定偏移（中國標準時間 CST = UTC+8）。
///
/// WuWa Tracker 匯出檔的 `time` 為 UTC instant；鳴潮五服共用 CST 伺服器時間，故
/// 一律加回 +8 還原成官方喚取 API 的伺服器在地牆鐘，對所有區服皆正確。詳見
/// 設計 spec §3 與 memory/wuwa-unified-cst-server-time.md。
const Duration kWuwaServerUtcOffset = Duration(hours: 8);

/// 鳴潮已知卡池代碼集合（字串鍵），用於濾掉非鳴潮卡池的紀錄。
final Set<String> _knownPoolKeys = {for (final t in gachaTypes) t.key};

/// WuWa Tracker（wuwatracker.com）的 `wuwatracker-pulls` 匯出檔匯入器。
class WuwaTrackerImporter implements PlatformImporter {
  /// 建立 [WuwaTrackerImporter]。
  const WuwaTrackerImporter();

  /// 平台穩定識別鍵。
  @override
  String get id => 'wuwa_tracker';

  /// 平台顯示名（WuWa Tracker 品牌名，不在地化）。
  @override
  String displayName(AppLocalizations l) => l.platformWuwaTracker;

  /// 平台清單列副標（來源網域與格式提示）。
  @override
  String? subtitle(AppLocalizations l) => l.platformWuwaTrackerSubtitle;

  /// 平台清單列前置 icon。
  @override
  IconData get icon => Icons.cloud_sync_outlined;

  /// 可接受副檔名（WuWa Tracker 匯出為 .json）。
  @override
  List<String> get fileExtensions => const ['json'];

  /// 解析 WuWa Tracker 的 wuwatracker-pulls JSON 匯出為 [AccountsBundle]。
  ///
  /// 缺 `resourceId` 的紀錄（早期版本）依序回填：同檔 name→id 表 → [nameResolver]
  /// （如 encore 清單）→ 決定性合成負 id（[syntheticResourceIdForName]），零資料遺失。
  @override
  AccountsBundle parse(String content, {ItemNameResolver? nameResolver}) {
    Object? raw;
    try {
      raw = jsonDecode(content);
    } catch (e) {
      _log.warning('wuwa_tracker import: invalid JSON ($e)');
      throw const FormatException('Invalid JSON');
    }
    if (raw is! Map<String, dynamic>) {
      _log.warning('wuwa_tracker import: top-level not an object');
      throw const ForeignBundleException();
    }
    final playerId = raw['playerId'];
    final pulls = raw['pulls'];
    if (playerId is! String || playerId.isEmpty || pulls is! List) {
      _log.warning(
        'wuwa_tracker import: missing playerId/pulls (foreign file)',
      );
      throw const ForeignBundleException();
    }

    try {
      // 第 1 層基礎：以同檔所有帶真實 id 的紀錄建 name→id 表（回填缺 id 用）。
      final inFileNameToId = <String, int>{};
      for (final entry in pulls) {
        if (entry is! Map<String, dynamic>) continue;
        final rid = entry['resourceId'];
        final name = entry['name'];
        if (rid is num && name is String) {
          inFileNameToId.putIfAbsent(name, () => rid.toInt());
        }
      }

      final banners = <String, List<GachaRecord>>{};
      var skipped = 0;
      var fromInFile = 0;
      var fromEncore = 0;
      var fromSynthetic = 0;
      for (final entry in pulls) {
        if (entry is! Map<String, dynamic>) {
          throw const FormatException('pulls[] entry must be an object');
        }
        final cardPoolType = (entry['cardPoolType'] as num).toInt().toString();
        if (!_knownPoolKeys.contains(cardPoolType)) {
          skipped++;
          continue;
        }
        final name = entry['name'] as String;

        // resourceId 解析：直接帶 → 同檔回填 → encore 解析器 → 合成負 id。
        // resourceType：有真實 id 時用位數推測（下游 encore 分類再校正）；encore
        // 命中用其 kind；合成 fallback 存空字串（顯示「未知」，不臆測類型）。
        final int resourceId;
        final String resourceType;
        final rawId = entry['resourceId'];
        if (rawId is num) {
          resourceId = rawId.toInt();
          resourceType = _kindByIdLength(resourceId);
        } else if (inFileNameToId.containsKey(name)) {
          resourceId = inFileNameToId[name]!;
          resourceType = _kindByIdLength(resourceId);
          fromInFile++;
        } else if (nameResolver?.call(name) case final r?) {
          resourceId = r.id;
          resourceType = r.kind;
          fromEncore++;
        } else {
          resourceId = syntheticResourceIdForName(name);
          resourceType = '';
          fromSynthetic++;
        }

        banners
            .putIfAbsent(cardPoolType, () => <GachaRecord>[])
            .add(
              GachaRecord(
                resourceId: resourceId,
                qualityLevel: (entry['qualityLevel'] as num).toInt(),
                resourceType: resourceType,
                cardPoolType: cardPoolType,
                name: name,
                count: 1,
                // WHY：WuWa Tracker 的 time 帶時區後綴（新紀錄 `+00:00`、舊紀錄
                // `Z`，皆 UTC instant），鳴潮全球統一 CST(+8)。toUtc() 規範化後 +8
                // → format 成牆鐘字串 → parse 回 local-kind DateTime，與官方擷取的
                // time 表示法完全一致；recordsEqual 依 DateTime==（含 isUtc）比對，
                // 唯同表示法才對齊。若未來變體改給 naive 字串，toUtc() 會改用裝置
                // 時區轉換，屆時需另行處理。
                time: parseGachaTime(
                  formatGachaTime(
                    DateTime.parse(
                      entry['time'] as String,
                    ).toUtc().add(kWuwaServerUtcOffset),
                  ),
                ),
                languageCode: 'en',
              ),
            );
      }

      // 每池由新到舊；同 time 以原陣列順序穩定 tiebreak（decorate-sort 保決定性）。
      for (final list in banners.values) {
        final indexed = list.indexed.toList();
        indexed.sort((a, b) {
          final byTime = b.$2.time.compareTo(a.$2.time);
          return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
        });
        list
          ..clear()
          ..addAll([for (final e in indexed) e.$2]);
      }

      final rawDate = raw['date'];
      final exportedAt =
          (rawDate is String ? DateTime.tryParse(rawDate)?.toUtc() : null) ??
          DateTime.now().toUtc();

      final total = banners.values.fold<int>(0, (a, b) => a + b.length);
      _log.info(
        'wuwa_tracker import parsed: player=${sanitizeUid(playerId)} '
        'pools=${banners.length} records=$total skipped=$skipped',
      );
      final nullResolved = fromInFile + fromEncore + fromSynthetic;
      if (nullResolved > 0) {
        _log.info(
          'wuwa_tracker null-resourceId resolution: inFile=$fromInFile '
          'encore=$fromEncore synthetic=$fromSynthetic (total null=$nullResolved)',
        );
      }

      final storage = BannerStorage(
        playerId: playerId,
        languageCode: 'en',
        lastUpdated: exportedAt,
        banners: banners,
      );
      return AccountsBundle(
        exportedAt: exportedAt,
        appVersion: '',
        lastActiveUid: playerId,
        accounts: [ExportedAccount(data: storage)],
      );
    } on FormatException {
      rethrow;
    } catch (e, st) {
      _log.warning('wuwa_tracker import: parse error', e, st);
      throw FormatException('Failed to parse WuWa Tracker file: $e');
    }
  }

  /// 依 resourceId 位數推測 canonical kind：≤4 碼角色、否則武器。第三方匯入缺
  /// `resourceType` 欄位時的暫定值，匯入後 encore 分類會以真實 id 校正（見 spec §3）。
  String _kindByIdLength(int resourceId) =>
      resourceId.toString().length <= 4 ? kItemKindCharacter : kItemKindWeapon;
}
