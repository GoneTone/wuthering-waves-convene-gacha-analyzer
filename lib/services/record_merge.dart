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

/// 將兩份同 UID、同卡池的喚取紀錄（皆由新到舊）做非破壞性雙向合併，回傳合併後
/// 的完整有序清單（由新到舊）。
///
/// 先以 [_alignedMerge] 縫合（連續重疊走 O(n) 快路徑，對不齊則退回 gap-tolerant
/// 序列合併），再以 [_capMultiplicity] 對每個指紋封頂多重數。
///
/// 保證：(1) **不漏**——任一來源每個指紋的數量都保留（輸出數量 = max(local, incoming)）；
/// (2) **無條件不重複**——沒有任何指紋輸出超過 max(local, incoming) 次（含 Cases 1-2 在
/// 「同 time 順序不一」時可能產生的複本）；(3) `added`／`duplicate` 計數正確，不會
/// 「整批算新增」。重疊區共同筆取本機那份；當兩份對「同一十連內重複道具」的順序不一致
/// （只可能來自手改／第三方）時，以不重複為先、十連內順序不保證與本機完全一致（但不漏
/// 任何指紋的數量）。
///
/// 與 [mergeOrderedRecords]（更新流程的單向增量）刻意分開：匯入的備份可能比本機
/// 更舊（補回早期段），單向版對不到錨點會丟掉另一段。
List<GachaRecord> mergeBackupRecords(
  List<GachaRecord> local,
  List<GachaRecord> incoming,
) {
  if (local.isEmpty) return List<GachaRecord>.from(incoming);
  if (incoming.isEmpty) return List<GachaRecord>.from(local);
  return _capMultiplicity(_alignedMerge(local, incoming), local, incoming);
}

/// 縫合兩份紀錄（未封頂）：Cases 1-2 為連續重疊的 O(n) 對齊快路徑，對不到一致重疊
/// 則退回 [_mergeBySupersequence]。多重數封頂由呼叫端 [mergeBackupRecords] 統一處理。
List<GachaRecord> _alignedMerge(
  List<GachaRecord> local,
  List<GachaRecord> incoming,
) {
  // Case 1：local 的開頭出現在 incoming 中（incoming 較新或頭部對齊）。
  final maxAnchor1 = local.length < _anchorBase ? local.length : _anchorBase;
  for (var anchorLen = maxAnchor1; anchorLen >= 1; anchorLen--) {
    final j = _findAlignment(incoming, local, anchorLen);
    if (j != null) {
      final overlapLen = local.length < incoming.length - j
          ? local.length
          : incoming.length - j;
      if (_overlapEquals(incoming, j, local, overlapLen)) {
        final olderStart = j + local.length < incoming.length
            ? j + local.length
            : incoming.length;
        return [
          ...incoming.sublist(0, j),
          ...local,
          ...incoming.sublist(olderStart),
        ];
      }
    }
  }

  // Case 2：incoming 的開頭出現在 local 中（incoming 較舊或被 local 包含）。
  final maxAnchor2 = incoming.length < _anchorBase
      ? incoming.length
      : _anchorBase;
  for (var anchorLen = maxAnchor2; anchorLen >= 1; anchorLen--) {
    final i = _findAlignment(local, incoming, anchorLen);
    if (i != null) {
      final overlapLen = incoming.length < local.length - i
          ? incoming.length
          : local.length - i;
      if (_overlapEquals(local, i, incoming, overlapLen)) {
        final olderStart = local.length - i < incoming.length
            ? local.length - i
            : incoming.length;
        return [...local, ...incoming.sublist(olderStart)];
      }
    }
  }

  // Case 3：對不到「連續」重疊（不相交／重疊中段缺筆／非連續輸入）→ gap-tolerant
  // 序列合併。自家連續匯出檔走 Cases 1-2，不會到這裡；此路徑專防非連續（手改／第三方）輸入。
  _log.info(
    'mergeBackupRecords: no contiguous overlap; supersequence-merging '
    '(local=${local.length} incoming=${incoming.length})',
  );
  return _mergeBySupersequence(local, incoming);
}

/// 逐筆比較 [a] 從 [aStart] 起與 [b] 從頭起連續 [len] 筆是否全部 [recordsEqual]。
bool _overlapEquals(
  List<GachaRecord> a,
  int aStart,
  List<GachaRecord> b,
  int len,
) {
  for (var k = 0; k < len; k++) {
    if (!recordsEqual(a[aStart + k], b[k])) return false;
  }
  return true;
}

/// 以「最短共同超序列」(SCS) 縫合兩份皆由新到舊、且同為某條真實歷史子序列的清單。
///
/// 供 [_alignedMerge] 在對不到「連續」重疊時使用（重疊中段缺筆／非連續輸入）：以
/// [recordsEqual] 跑 LCS、回溯產生 SCS（共同筆取本機那份、各自獨有的筆按子序列順序
/// 插入、LCS 平手點以 [GachaRecord.time] 較新者先、同 time 保留本機）。多重數封頂由
/// 呼叫端 [mergeBackupRecords] 的 [_capMultiplicity] 統一處理（此處不封頂）。
List<GachaRecord> _mergeBySupersequence(
  List<GachaRecord> local,
  List<GachaRecord> incoming,
) {
  final n = local.length;
  final m = incoming.length;

  // dp[i][j] = LCS(local[i..], incoming[j..]) 的長度。
  final dp = List<List<int>>.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
    growable: false,
  );
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = recordsEqual(local[i], incoming[j])
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }

  final merged = <GachaRecord>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (recordsEqual(local[i], incoming[j])) {
      merged.add(local[i]); // 共同筆，只取本機那份
      i++;
      j++;
    } else if (dp[i + 1][j] > dp[i][j + 1]) {
      merged.add(local[i++]);
    } else if (dp[i + 1][j] < dp[i][j + 1]) {
      merged.add(incoming[j++]);
    } else {
      // LCS 不偏好任一邊：取較新的 time 先（維持新到舊），同 time 保留本機。
      if (incoming[j].time.isAfter(local[i].time)) {
        merged.add(incoming[j++]);
      } else {
        merged.add(local[i++]);
      }
    }
  }
  while (i < n) {
    merged.add(local[i++]);
  }
  while (j < m) {
    merged.add(incoming[j++]);
  }
  return merged;
}

/// 指紋字串（對齊 [recordsEqual] 的四欄位：time/resourceId/qualityLevel/count），
/// 供多重數封頂統計用。
String _fingerprint(GachaRecord r) =>
    '${r.time.microsecondsSinceEpoch}|${r.time.isUtc}|${r.resourceId}'
    '|${r.qualityLevel}|${r.count}';

/// 將 [merged] 中每個指紋的出現次數封頂為 max(在 [local] 的次數, 在 [incoming] 的次數)，
/// 移除 SCS 為同時滿足兩序列順序而生的多餘複本。封頂值不低於任一來源的次數，故任何
/// 指紋的「數量」都不漏；超出上限的複本（僅在兩份對同十連內重複道具順序不一致時出現）
/// 被丟棄，達成無條件不重複。
List<GachaRecord> _capMultiplicity(
  List<GachaRecord> merged,
  List<GachaRecord> local,
  List<GachaRecord> incoming,
) {
  final localCount = <String, int>{};
  for (final r in local) {
    final k = _fingerprint(r);
    localCount[k] = (localCount[k] ?? 0) + 1;
  }
  final incomingCount = <String, int>{};
  for (final r in incoming) {
    final k = _fingerprint(r);
    incomingCount[k] = (incomingCount[k] ?? 0) + 1;
  }

  final emitted = <String, int>{};
  final capped = <GachaRecord>[];
  for (final r in merged) {
    final k = _fingerprint(r);
    final lc = localCount[k] ?? 0;
    final ic = incomingCount[k] ?? 0;
    final limit = lc > ic ? lc : ic;
    final used = emitted[k] ?? 0;
    if (used < limit) {
      capped.add(r);
      emitted[k] = used + 1;
    }
  }
  return capped;
}
