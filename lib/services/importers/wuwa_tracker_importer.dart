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

/// WuWa Tracker（wuwatracker.com）的 `wuwatracker-pulls` 匯出檔匯入器。
class WuwaTrackerImporter implements PlatformImporter {
  /// 建立 [WuwaTrackerImporter]。
  const WuwaTrackerImporter();

  @override
  String get id => 'wuwa_tracker';

  @override
  String displayName(AppLocalizations l) => l.platformWuwaTracker;

  @override
  String? subtitle(AppLocalizations l) => l.platformWuwaTrackerSubtitle;

  @override
  IconData get icon => Icons.cloud_sync_outlined;

  @override
  List<String> get fileExtensions => const ['json'];

  @override
  AccountsBundle parse(String content) {
    Object? raw;
    try {
      raw = jsonDecode(content);
    } catch (e) {
      _log.warning('wuwa_tracker import: invalid JSON ($e)');
      throw const FormatException('Invalid JSON');
    }
    if (raw is! Map<String, dynamic>) {
      throw const ForeignBundleException();
    }
    final playerId = raw['playerId'];
    final pulls = raw['pulls'];
    if (playerId is! String || playerId.isEmpty || pulls is! List) {
      // 缺頂層 playerId / pulls：不是 WuWa Tracker 的 pulls 匯出。
      throw const ForeignBundleException();
    }

    try {
      final known = <String>{for (final t in gachaTypes) t.key};
      final banners = <String, List<GachaRecord>>{};
      var skipped = 0;
      for (final entry in pulls) {
        if (entry is! Map<String, dynamic>) {
          throw const FormatException('pulls[] entry must be an object');
        }
        final cardPoolType = (entry['cardPoolType'] as num).toInt().toString();
        if (!known.contains(cardPoolType)) {
          skipped++;
          continue;
        }
        final resourceId = (entry['resourceId'] as num).toInt();
        banners.putIfAbsent(cardPoolType, () => <GachaRecord>[]).add(
          GachaRecord(
            resourceId: resourceId,
            qualityLevel: (entry['qualityLevel'] as num).toInt(),
            // resourceType 缺：存 canonical kind 鍵（4 碼角色、8 碼武器）。匯入後
            // encore 分類接手，少數 8 碼道具會被修正為 kItemKindItem。見 spec §3。
            resourceType: resourceId.toString().length <= 4
                ? kItemKindCharacter
                : kItemKindWeapon,
            cardPoolType: cardPoolType,
            name: entry['name'] as String,
            count: 1,
            // WHY：WuWa Tracker 的 time 是 UTC instant，鳴潮全球統一 CST(+8)。
            // toUtc() 先取絕對 instant（與裝置時區無關）→ +8 → format 成牆鐘字串
            // → parse 回 local-kind DateTime，與官方擷取的 time 表示法（local-kind、
            // 相同欄位）完全一致；recordsEqual 依 DateTime==（含 isUtc 旗標）比對，
            // 唯有同表示法才對得齊。
            time: parseGachaTime(
              formatGachaTime(
                DateTime.parse(entry['time'] as String)
                    .toUtc()
                    .add(kWuwaServerUtcOffset),
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
}
