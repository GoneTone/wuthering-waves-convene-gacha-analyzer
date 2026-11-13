import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/record_merge.dart';

/// 單一帳號（playerId）的全卡池喚取存檔。
///
/// [languageCode] 記錄最近一次擷取的語言，並作為載入舊存檔時缺逐筆
/// `language_code` 紀錄的回填來源；逐筆顯示語言以 [GachaRecord.languageCode] 為準。
class BannerStorage {
  /// 建立 [BannerStorage]。
  const BannerStorage({
    required this.playerId,
    required this.languageCode,
    required this.lastUpdated,
    required this.banners,
  });

  /// 玩家 UID（取代前身版本 uid）。
  final String playerId;

  /// 帳號級語言碼（如 `zh-Hant`）：最近一次擷取的語言；亦為載入舊存檔時對缺
  /// 逐筆 `language_code` 的紀錄回填的來源。逐筆顯示／分類一律以
  /// `GachaRecord.languageCode` 為準，本欄位不再作為顯示語言權威。
  final String languageCode;

  /// 最後更新時間（UTC）。
  final DateTime lastUpdated;

  /// cardPoolType 字串（`'1'..'13'`，無 `'7'`）→ 該卡池紀錄（由新到舊）。
  final Map<String, List<GachaRecord>> banners;

  /// 從本地存檔 JSON 還原 [BannerStorage]。
  factory BannerStorage.fromJson(Map<String, dynamic> json) {
    final bannersJson = json['banners'] as Map<String, dynamic>;
    final bannerLang = json['language_code'] as String;
    return BannerStorage(
      playerId: json['player_id'] as String,
      languageCode: bannerLang,
      lastUpdated: DateTime.parse(json['last_updated'] as String),
      banners: bannersJson.map(
        (k, v) => MapEntry(
          k,
          (v as List<dynamic>)
              .map(
                (e) => GachaRecord.fromStorageJson(
                  e as Map<String, dynamic>,
                  fallbackLanguageCode: bannerLang,
                ),
              )
              .toList(growable: false),
        ),
      ),
    );
  }

  /// 序列化為本地存檔 JSON。
  ///
  /// 不額外寫入 schema 版本欄位：舊版/新鳴潮檔的辨識（§C）依賴每筆 record 是否含
  /// `resource_id`（見 `GachaRecord.toStorageJson`），由 `GachaStorage.load` 解析時
  /// 判定，缺即視為舊檔跳過。
  Map<String, dynamic> toJson() => {
    'player_id': playerId,
    'language_code': languageCode,
    'last_updated': lastUpdated.toUtc().toIso8601String(),
    'banners': banners.map(
      (k, v) =>
          MapEntry(k, v.map((r) => r.toStorageJson()).toList(growable: false)),
    ),
  };

  /// 複製並選擇性覆蓋欄位（playerId 不可變）。
  BannerStorage copyWith({
    String? languageCode,
    DateTime? lastUpdated,
    Map<String, List<GachaRecord>>? banners,
  }) => BannerStorage(
    playerId: playerId,
    languageCode: languageCode ?? this.languageCode,
    lastUpdated: lastUpdated ?? this.lastUpdated,
    banners: banners ?? this.banners,
  );

  /// 將 [incoming]（同一 playerId 的另一份存檔）合併進本份，回傳新的 [BannerStorage]。
  ///
  /// 逐卡池以 [mergeBackupRecords] 對齊去重；本機既有紀錄一律保留（含重疊那筆保留
  /// 本機版本）。[lastUpdated] 與帳號級 [languageCode] 取較新者（[incoming] 的
  /// lastUpdated 較新時採用 incoming 的）。playerId 不變。
  BannerStorage mergeWith(BannerStorage incoming) {
    final keys = {...banners.keys, ...incoming.banners.keys};
    final mergedBanners = <String, List<GachaRecord>>{
      for (final key in keys)
        key: mergeBackupRecords(
          banners[key] ?? const [],
          incoming.banners[key] ?? const [],
        ),
    };
    final incomingNewer = incoming.lastUpdated.isAfter(lastUpdated);
    return copyWith(
      languageCode: incomingNewer ? incoming.languageCode : null,
      lastUpdated: incomingNewer ? incoming.lastUpdated : null,
      banners: mergedBanners,
    );
  }

  /// 與 [other] 的內容（語言、更新時間、各卡池每筆紀錄的所有欄位）是否完全相同。
  ///
  /// 合併後沒有任何變化時用來省掉寫檔與 state 替換；[GachaRecord] 刻意不定義 `==`。
  bool sameContentAs(BannerStorage other) {
    if (playerId != other.playerId ||
        languageCode != other.languageCode ||
        lastUpdated != other.lastUpdated ||
        banners.length != other.banners.length) {
      return false;
    }
    for (final MapEntry(:key, :value) in banners.entries) {
      final theirs = other.banners[key];
      if (theirs == null || theirs.length != value.length) return false;
      for (var i = 0; i < value.length; i++) {
        if (!_sameRecord(value[i], theirs[i])) return false;
      }
    }
    return true;
  }

  /// 全 banner 串成一條 list（OverviewPage 用）。
  List<GachaRecord> get allRecords =>
      banners.values.expand((l) => l).toList(growable: false);
}

/// 兩筆紀錄的所有欄位是否相同。
bool _sameRecord(GachaRecord a, GachaRecord b) =>
    a.resourceId == b.resourceId &&
    a.qualityLevel == b.qualityLevel &&
    a.resourceType == b.resourceType &&
    a.cardPoolType == b.cardPoolType &&
    a.name == b.name &&
    a.count == b.count &&
    a.time == b.time &&
    a.languageCode == b.languageCode;
