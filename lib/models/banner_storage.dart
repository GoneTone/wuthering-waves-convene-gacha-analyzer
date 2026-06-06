import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

/// 單一帳號（playerId）的全卡池喚取存檔。
///
/// languageCode 為帳號級單一值（取代前身版本逐筆 record.lang），決定回應內名稱/類型
/// 字串語言，並供 encore 圖片/詳情 API 的 `{lang}` 路徑參數使用。
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

  /// 帳號級語言碼（如 `zh-Hant`）。
  final String languageCode;

  /// 最後更新時間（UTC）。
  final DateTime lastUpdated;

  /// cardPoolType 字串（`'1'..'11'`，無 `'7'`）→ 該卡池紀錄（由新到舊）。
  final Map<String, List<GachaRecord>> banners;

  /// 從本地存檔 JSON 還原 [BannerStorage]。
  factory BannerStorage.fromJson(Map<String, dynamic> json) {
    final bannersJson = json['banners'] as Map<String, dynamic>;
    return BannerStorage(
      playerId: json['player_id'] as String,
      languageCode: json['language_code'] as String,
      lastUpdated: DateTime.parse(json['last_updated'] as String),
      banners: bannersJson.map(
        (k, v) => MapEntry(
          k,
          (v as List<dynamic>)
              .map(
                (e) => GachaRecord.fromStorageJson(e as Map<String, dynamic>),
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

  /// 全 banner 串成一條 list（OverviewPage 用）。
  List<GachaRecord> get allRecords =>
      banners.values.expand((l) => l).toList(growable: false);
}
