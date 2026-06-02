/// 把 API/存檔的 `YYYY-MM-DD HH:mm:ss` 字串解析為本地語意 [DateTime]。
DateTime parseGachaTime(String raw) =>
    DateTime.parse(raw.replaceFirst(' ', 'T'));

/// 把 [DateTime] 格式化為 `YYYY-MM-DD HH:mm:ss`（各欄位補零），供 API/存檔對齊。
String formatGachaTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// 單筆喚取紀錄，支援 API 與本地存檔兩種來源。
///
/// 鳴潮喚取記錄無唯一 id、無逐筆 uid（身分移至 [BannerStorage] 的 playerId）、
/// 無逐筆 lang（移至帳號級 languageCode）。同一十連的多筆 [time] 完全相同，
/// 故任何單筆比對都不可作唯一鍵，增量合併改用 `record_merge.dart` 的有序清單對齊。
class GachaRecord {
  /// 建立 [GachaRecord]。
  const GachaRecord({
    required this.resourceId,
    required this.qualityLevel,
    required this.resourceType,
    required this.cardPoolType,
    required this.name,
    required this.count,
    required this.time,
  });

  /// 道具資源 ID（角色 4 碼、武器/道具 8 碼），亦作為圖片 API 的 roleGbId。
  final int resourceId;

  /// 稀有度（觀測值 5 / 4 / 3，鳴潮喚取無 1★/2★）。
  final int qualityLevel;

  /// 道具類型字串（`角色` / `武器` / `道具`，隨 languageCode 變化）。
  final String resourceType;

  /// 所屬卡池類型（字串，如 `'1'`），對應 [GachaType.key]。
  final String cardPoolType;

  /// 道具名稱。
  final String name;

  /// 數量（通常為 1）。
  final int count;

  /// 抽取時間（伺服器在地時間語意）。
  final DateTime time;

  /// 從喚取記錄 API 回應的 data[] 元素解析。
  ///
  /// 回應內每筆雖自帶 `cardPoolType` 字串，但一律以呼叫端迭代用的 [cardPoolType]
  /// 為準，確保存檔 map key 與查詢一致。
  factory GachaRecord.fromApiJson(
    Map<String, dynamic> json, {
    required String cardPoolType,
  }) {
    return GachaRecord(
      resourceId: json['resourceId'] as int,
      qualityLevel: json['qualityLevel'] as int,
      resourceType: json['resourceType'] as String,
      cardPoolType: cardPoolType,
      name: json['name'] as String,
      count: json['count'] as int,
      time: parseGachaTime(json['time'] as String),
    );
  }

  /// 從本地存檔的 JSON 還原。
  factory GachaRecord.fromStorageJson(Map<String, dynamic> json) {
    return GachaRecord(
      resourceId: json['resource_id'] as int,
      qualityLevel: json['quality_level'] as int,
      resourceType: json['resource_type'] as String,
      cardPoolType: json['card_pool_type'] as String,
      name: json['name'] as String,
      count: json['count'] as int,
      time: parseGachaTime(json['time'] as String),
    );
  }

  /// 寫入本地存檔（鳴潮 snake_case schema）。
  Map<String, dynamic> toStorageJson() => {
    'resource_id': resourceId,
    'quality_level': qualityLevel,
    'resource_type': resourceType,
    'card_pool_type': cardPoolType,
    'name': name,
    'count': count,
    'time': formatGachaTime(time),
  };
}
