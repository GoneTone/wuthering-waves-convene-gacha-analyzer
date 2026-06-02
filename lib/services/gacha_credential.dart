import 'dart:convert';

/// 封裝攔到的喚取記錄 POST body 五個查詢憑證欄位，並負責迭代各 cardPoolType
/// 時組出請求 body。取代前身版本以 URL query 攜帶憑證的 `GachaUrl`。
class GachaCredential {
  /// 建立 [GachaCredential]。
  const GachaCredential({
    required this.playerId,
    required this.cardPoolId,
    required this.serverId,
    required this.recordId,
    required this.languageCode,
  });

  /// 玩家 UID（遊戲內顯示的特徵碼），亦作為存檔身分。
  final String playerId;

  /// 卡池資源版本 hash，所有 cardPoolType 共用同一值，迭代時不更動。
  final String cardPoolId;

  /// 伺服器 ID hash，逐帳號不同，由攔到的 body 取得。
  final String serverId;

  /// 查詢 token hash，會過期；過期後需請玩家重開喚取記錄頁重新攔取。
  final String recordId;

  /// 語言碼（如 `zh-Hant`），決定回應內名稱/類型字串語言與 encore 圖片/詳情 API 的 `{lang}` 參數。
  final String languageCode;

  /// 從攔到的 POST body（JSON 字串）解析；缺必要欄位或非 JSON 物件時丟
  /// [FormatException]（呼叫端視為未命中）。
  factory GachaCredential.fromCapturedBody(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      throw const FormatException('captured body is not valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('captured body is not a JSON object');
    }
    final map = decoded;
    String require(String key) {
      final v = map[key];
      if (v is! String || v.isEmpty) {
        throw FormatException('captured body missing field "$key"');
      }
      return v;
    }

    return GachaCredential(
      playerId: require('playerId'),
      cardPoolId: require('cardPoolId'),
      serverId: require('serverId'),
      recordId: require('recordId'),
      languageCode: require('languageCode'),
    );
  }

  /// 組出查詢指定 [cardPoolType]（int）的請求 body，共用五個憑證欄位。
  ///
  /// 這是 int → 請求 body 的唯一轉換點（對應 spec D4）：除此處與
  /// `GachaType.key` 外，cardPoolType 不應在程式他處重新做 int/String 轉換。
  Map<String, dynamic> toRequestBody(int cardPoolType) => {
    ..._credentialFields(),
    'cardPoolType': cardPoolType,
  };

  /// 序列化為五欄位憑證 JSON 字串（存檔用），與 [fromCapturedBody] 互為往返：
  /// `GachaCredential.fromCapturedBody(cred.toJsonString())` 可完整還原。
  ///
  /// 僅輸出五個憑證欄位（不含 cardPoolType，後者由迭代時 [toRequestBody] 動態帶入），
  /// 供 `gacha_storage` 以 `saveCapturedCredential` 存檔、`fromCapturedBody` 讀回。
  String toJsonString() => jsonEncode(_credentialFields());

  /// 五個查詢憑證欄位（存檔與請求 body 共用，避免兩處各自列舉欄位易漏改）。
  /// JSON 物件鍵序對 HTTP body 與存檔讀回均無語意影響。
  Map<String, dynamic> _credentialFields() => {
    'playerId': playerId,
    'cardPoolId': cardPoolId,
    'serverId': serverId,
    'recordId': recordId,
    'languageCode': languageCode,
  };
}
