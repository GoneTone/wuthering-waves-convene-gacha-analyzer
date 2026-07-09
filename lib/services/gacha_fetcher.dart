import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';

/// 喚取記錄 API 回傳 `code != 0` 的失敗（已知 `-1`，語意待累積樣本）。
/// 取代前身版本的 [AuthExpiredException] / [RateLimitedException] / [ApiErrorException]。
class GachaApiException implements Exception {
  /// 建立 [GachaApiException]，需提供 API 的 [code] 與 [message]。
  const GachaApiException(this.code, this.message);

  /// API 回傳的 `code`（0 以外即失敗）。
  final int code;

  /// API 回傳的 `message` 字串（簡體中文，不可用於語言判斷）。
  final String message;

  @override
  String toString() => 'GachaApiException(code=$code, $message)';
}

/// 單一 cardPoolType 的整池全歷史回應（鳴潮 API 無分頁，一次回傳整池）。
class FetchedPoolResult {
  /// 建立 [FetchedPoolResult]，[records] 為該池由新到舊的全歷史。
  const FetchedPoolResult(this.records);

  /// 該池全歷史紀錄（依 API 回傳順序：由新到舊）。
  final List<GachaRecord> records;
}

/// 負責呼叫鳴潮喚取記錄 API（POST `/gacha/record/query`），逐 cardPoolType 各一次。
class GachaFetcher {
  /// 建立 [GachaFetcher]，可調整速率限制與逾時設定。
  GachaFetcher({
    this.rateLimit = const Duration(milliseconds: 600),
    this.timeout = const Duration(seconds: 15),
  });

  /// 兩次 API 呼叫之間的最短間隔（夾在 12 個 cardPoolType 之間，避免被擋）。
  final Duration rateLimit;

  /// 單次 HTTP 請求超時。
  final Duration timeout;

  /// Logger 實例（gacha 抓取）。
  static final _log = Logger('gacha.fetcher');

  /// 單池全歷史可能上千筆，超過此長度改用 [compute] 在 isolate 解析避免卡 UI。
  static const _isolateDecodeThreshold = 50 * 1024;

  /// 抓單一 [cardPoolType] 的整池全歷史。
  ///
  /// 對 [endpoint] 發 POST，body 為 `cred.toRequestBody(cardPoolType)` 的 JSON。
  /// 回應 `{code,message,data[]}`：`code==0` → 取 `data`（空 = 空池，正常）；
  /// `code!=0` → 丟 [GachaApiException]（任一池失敗由呼叫端中止整次更新）。
  Future<FetchedPoolResult> fetchPool({
    required Uri endpoint,
    required GachaCredential cred,
    required int cardPoolType,
    required http.Client client,
  }) async {
    _log.fine(
      'fetchPool cardPoolType=$cardPoolType '
      'playerId=${_maskTail(cred.playerId)}',
    );
    final res = await client
        .post(
          endpoint,
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(cred.toRequestBody(cardPoolType)),
        )
        .timeout(timeout);

    final body = await _decodeJson(res.body);
    final code = (body['code'] as num?)?.toInt() ?? -999;
    final message = body['message'] as String? ?? '';
    if (code != 0) {
      _log.severe(
        'fetchPool failed cardPoolType=$cardPoolType code=$code msg=$message',
      );
      throw GachaApiException(code, message);
    }
    final data = (body['data'] as List<dynamic>?) ?? const [];
    final cardPoolTypeKey = cardPoolType.toString();
    final records = data
        .map(
          (e) => GachaRecord.fromApiJson(
            e as Map<String, dynamic>,
            cardPoolType: cardPoolTypeKey,
            languageCode: cred.languageCode,
          ),
        )
        .toList(growable: false);
    _log.info(
      'fetchPool ok cardPoolType=$cardPoolType records=${records.length}',
    );
    return FetchedPoolResult(records);
  }

  /// 大 payload 在 isolate 解析避免卡 UI；小 payload 直接 [jsonDecode]。
  Future<Map<String, dynamic>> _decodeJson(String raw) async {
    if (raw.length >= _isolateDecodeThreshold) {
      return compute(_jsonDecodeMap, raw);
    }
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// playerId 末段遮罩（僅供 fine log；正式脫敏在 [sanitizeUid]）。
  String _maskTail(String s) =>
      s.length <= 4 ? '***' : '***${s.substring(s.length - 4)}';
}

/// 頂層函式：供 [compute] 在 isolate 內解析 JSON Map。
Map<String, dynamic> _jsonDecodeMap(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;
