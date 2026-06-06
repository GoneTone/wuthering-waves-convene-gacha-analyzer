import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

/// Logger 實例（喚取記錄合併）。
final _log = Logger('gacha.merge');

/// anchor 長度：取 existing 開頭連續 N 筆作為對齊指紋。
const _anchorBase = 3;

/// 判斷兩筆喚取紀錄在「同一抽」意義上是否對齊（語言無關對齊指紋）。
///
/// 比對 `(time, resourceId, qualityLevel, count)` 全等，刻意排除 `name`／
/// `resourceType`／`languageCode` —— 換遊戲語言重抓時這些在地化欄位會變，唯有
/// 排除它們，舊紀錄才能被辨識為同一抽而保留原語言。`cardPoolType` 由呼叫端分池後
/// 已隱式保證一致，不需再比。鳴潮無唯一 id 且同十連 time 相同，故只用於序列對齊
/// 輔助、不可單獨當主鍵。
bool recordsEqual(GachaRecord a, GachaRecord b) =>
    a.time == b.time &&
    a.resourceId == b.resourceId &&
    a.qualityLevel == b.qualityLevel &&
    a.count == b.count;

/// 比較 [fresh]（API 回的整池全歷史，由新到舊）與 [existing]（舊存檔，由新到舊），
/// 回傳合併後的完整有序清單。
///
/// 演算法：以 existing 開頭連續 N 筆作 anchor，在 fresh 找到對齊的連續子序列起點，
/// 取「fresh 對齊點之前的新筆」拼上「existing 全部」。
/// 邊界（皆有測試）：
/// - existing 空 → 回 fresh；fresh 空 → 回 existing。
/// - anchor 在 fresh 找不到（換服/清號/recordId 指向別帳號）→ 以 fresh 完整取代並
///   log warning（不靜默拼接，避免污染存檔）。
/// - 多個匹配 → 取最靠頂端（最新）的對齊點。
/// - anchor 同批重複（同十連同道具）→ 因用「連續子序列」比對而非單筆，能正確對齊。
List<GachaRecord> mergeOrderedRecords(
  List<GachaRecord> fresh,
  List<GachaRecord> existing,
) {
  if (existing.isEmpty) return List<GachaRecord>.from(fresh);
  if (fresh.isEmpty) return List<GachaRecord>.from(existing);

  // anchor 長度從 _anchorBase 起，必要時縮短到 existing 全長以避免 anchor 含被
  // API 截斷的最舊段（fresh 不回傳那段時長 anchor 會對不上）。
  final maxAnchor = existing.length < _anchorBase
      ? existing.length
      : _anchorBase;

  for (var anchorLen = maxAnchor; anchorLen >= 1; anchorLen--) {
    final alignIndex = _findAlignment(fresh, existing, anchorLen);
    if (alignIndex != null) {
      // fresh[0 .. alignIndex-1] 為 existing 頂端之上的新筆；其後接 existing 全部。
      final newOnes = fresh.sublist(0, alignIndex);
      _log.info(
        'merge aligned: anchorLen=$anchorLen at fresh[$alignIndex], '
        'new=${newOnes.length} existing=${existing.length}',
      );
      return [...newOnes, ...existing];
    }
  }

  _log.warning(
    'merge anchor not found (existing top not in fresh); '
    'replacing with fresh (fresh=${fresh.length} existing=${existing.length})',
  );
  return List<GachaRecord>.from(fresh);
}

/// 在 [fresh] 中尋找與 [existing] 開頭連續 [anchorLen] 筆對齊的子序列起點。
///
/// 回傳最靠頂端（index 最小）的對齊點；找不到回 null。
int? _findAlignment(
  List<GachaRecord> fresh,
  List<GachaRecord> existing,
  int anchorLen,
) {
  final maxStart = fresh.length - anchorLen;
  for (var start = 0; start <= maxStart; start++) {
    var matched = true;
    for (var k = 0; k < anchorLen; k++) {
      if (!recordsEqual(fresh[start + k], existing[k])) {
        matched = false;
        break;
      }
    }
    if (matched) return start;
  }
  return null;
}
