import 'dart:convert';

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
/// 鳴潮喚取記錄無唯一 id、無逐筆 uid（身分移至 [BannerStorage] 的 playerId）。
/// 同一十連的多筆 [time] 完全相同，故任何單筆比對都不可作唯一鍵，
/// 增量合併改用 `record_merge.dart` 的有序清單對齊。
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
    this.languageCode = '',
  });

  /// 道具資源 ID（角色 4 碼、武器/道具 8 碼），亦作為圖片 API 的 roleGbId。
  final int resourceId;

  /// 稀有度（觀測值 5 / 4 / 3，鳴潮喚取無 1★/2★）。
  final int qualityLevel;

  /// 道具類型字串（官方 API 來源為 `角色` / `武器` / `道具`，隨 languageCode 變化）。
  ///
  /// 第三方平台匯入（缺此欄）改存 canonical kind 鍵（見 `item_type_kind.dart`）；
  /// 唯一消費點 `itemTypeKeyOf` / `itemTypeKeyLabel` 本就以 canonical 鍵為主分支。
  final String resourceType;

  /// 所屬卡池類型（字串，如 `'1'`），對應 [GachaType.key]。
  final String cardPoolType;

  /// 道具名稱。
  final String name;

  /// 數量（通常為 1）。
  final int count;

  /// 抽取時間（伺服器在地時間語意）。
  final DateTime time;

  /// 該筆紀錄的擷取語言碼（如 `zh-Hant`）。決定 `name`／`resourceType` 字串語言，
  /// 並供 encore 詳情查詢挑 `detailByLang`。舊存檔無此欄位時由
  /// [GachaRecord.fromStorageJson] 的 fallback 回填（見 `BannerStorage.fromJson`）。
  final String languageCode;

  /// 從喚取記錄 API 回應的 data[] 元素解析。
  ///
  /// 回應內每筆雖自帶 `cardPoolType` 字串，但一律以呼叫端迭代用的 [cardPoolType]
  /// 為準，確保存檔 map key 與查詢一致。[languageCode] 由呼叫端傳入擷取語言。
  factory GachaRecord.fromApiJson(
    Map<String, dynamic> json, {
    required String cardPoolType,
    required String languageCode,
  }) {
    return GachaRecord(
      resourceId: json['resourceId'] as int,
      qualityLevel: json['qualityLevel'] as int,
      resourceType: json['resourceType'] as String,
      cardPoolType: cardPoolType,
      name: json['name'] as String,
      count: json['count'] as int,
      time: parseGachaTime(json['time'] as String),
      languageCode: languageCode,
    );
  }

  /// 從本地存檔的 JSON 還原。
  ///
  /// 舊鳴潮存檔每筆無 `language_code`，由 [fallbackLanguageCode]（呼叫端帶帳號級
  /// `BannerStorage.languageCode`）回填，達成透明遷移。
  factory GachaRecord.fromStorageJson(
    Map<String, dynamic> json, {
    String fallbackLanguageCode = '',
  }) {
    final lang = json['language_code'] as String?;
    return GachaRecord(
      resourceId: json['resource_id'] as int,
      qualityLevel: json['quality_level'] as int,
      resourceType: json['resource_type'] as String,
      cardPoolType: json['card_pool_type'] as String,
      name: json['name'] as String,
      count: json['count'] as int,
      time: parseGachaTime(json['time'] as String),
      languageCode: (lang == null || lang.isEmpty)
          ? fallbackLanguageCode
          : lang,
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
    'language_code': languageCode,
  };

  /// 複製並選擇性覆蓋欄位（資料語言轉換用：改 name／resourceId／languageCode）。
  GachaRecord copyWith({
    int? resourceId,
    int? qualityLevel,
    String? resourceType,
    String? cardPoolType,
    String? name,
    int? count,
    DateTime? time,
    String? languageCode,
  }) => GachaRecord(
    resourceId: resourceId ?? this.resourceId,
    qualityLevel: qualityLevel ?? this.qualityLevel,
    resourceType: resourceType ?? this.resourceType,
    cardPoolType: cardPoolType ?? this.cardPoolType,
    name: name ?? this.name,
    count: count ?? this.count,
    time: time ?? this.time,
    languageCode: languageCode ?? this.languageCode,
  );
}

/// 第三方匯入缺 `resourceId` 時，依物品名稱決定性產生的「合成」資源 id。
///
/// 一律為負（真實遊戲／encore id 皆正），確保不與真實 id 碰撞；同 name 必得同 id
/// （跨次匯入穩定）。**不可改用 Dart `String.hashCode`** —— 其每次程式執行 seed
/// 隨機，會破壞跨次匯入穩定性。採 FNV-1a 32-bit（over UTF-8）後映射到負數空間。
int syntheticResourceIdForName(String name) {
  var hash = 0x811c9dc5; // FNV-1a 32-bit offset basis
  for (final byte in utf8.encode(name)) {
    hash = (hash ^ byte) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff; // FNV prime
  }
  return -(hash & 0x7fffffff) - 1; // [-2^31, -1]，恆負、永不為 0
}

/// 判斷 [resourceId] 是否為 [syntheticResourceIdForName] 產生的合成 id（負值）。
bool isSyntheticResourceId(int resourceId) => resourceId < 0;
