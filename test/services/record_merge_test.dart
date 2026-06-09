import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/record_merge.dart';

/// 測試輔助：以最少欄位造一筆記錄，time 由秒位帶入便於閱讀。
GachaRecord r(
  int resourceId, {
  int quality = 4,
  String type = '角色',
  String name = 'x',
  int count = 1,
  int sec = 0,
  String lang = 'zh-Hant',
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: quality,
  resourceType: type,
  cardPoolType: '1',
  name: name,
  count: count,
  time: DateTime(2026, 5, 21, 11, 0, sec),
  languageCode: lang,
);

void main() {
  group('recordsEqual', () {
    test('四欄位全等 → true', () {
      expect(
        recordsEqual(r(1, name: 'a', sec: 3), r(1, name: 'a', sec: 3)),
        isTrue,
      );
    });
    test('resourceId 不同 → false', () {
      expect(recordsEqual(r(1, sec: 3), r(2, sec: 3)), isFalse);
    });
    test('name 不同（換語言）→ true（語言無關對齊指紋）', () {
      expect(recordsEqual(r(1, name: 'a'), r(1, name: 'b')), isTrue);
    });
    test('time 不同 → false', () {
      expect(recordsEqual(r(1, sec: 3), r(1, sec: 4)), isFalse);
    });
    test('qualityLevel 不同 → false', () {
      expect(recordsEqual(r(1, quality: 5), r(1, quality: 4)), isFalse);
    });
    test('count 不同 → false', () {
      expect(recordsEqual(r(1, count: 1), r(1, count: 2)), isFalse);
    });
  });

  group('mergeOrderedRecords 邊界', () {
    test('existing 空 → 回 fresh', () {
      final fresh = [r(3, sec: 3), r(2, sec: 2), r(1, sec: 1)];
      final merged = mergeOrderedRecords(fresh, const []);
      expect(merged.map((e) => e.resourceId), [3, 2, 1]);
    });

    test('fresh 空 → 回 existing', () {
      final existing = [r(2, sec: 2), r(1, sec: 1)];
      final merged = mergeOrderedRecords(const [], existing);
      expect(merged.map((e) => e.resourceId), [2, 1]);
    });

    test('兩者皆空 → 空', () {
      expect(mergeOrderedRecords(const [], const []), isEmpty);
    });
  });

  group('mergeOrderedRecords 增量', () {
    test('fresh 比 existing 多出新頂端 → 只接上新筆', () {
      // existing = 舊三筆；fresh = 新兩筆 + 同樣舊三筆
      final old3 = [r(30, sec: 30), r(20, sec: 20), r(10, sec: 10)];
      final fresh = [r(50, sec: 50), r(40, sec: 40), ...old3];
      final merged = mergeOrderedRecords(fresh, old3);
      expect(merged.map((e) => e.resourceId), [50, 40, 30, 20, 10]);
    });

    test('fresh == existing（無新增）→ 回原序、不重複', () {
      final list = [r(30, sec: 30), r(20, sec: 20), r(10, sec: 10)];
      final merged = mergeOrderedRecords(List.of(list), list);
      expect(merged.map((e) => e.resourceId), [30, 20, 10]);
    });

    test('新一期第一筆恰等於舊頂端（無新增）→ 不重複既有', () {
      final old3 = [r(30, sec: 30), r(20, sec: 20), r(10, sec: 10)];
      final fresh = [r(30, sec: 30), r(20, sec: 20), r(10, sec: 10)];
      final merged = mergeOrderedRecords(fresh, old3);
      expect(merged.map((e) => e.resourceId), [30, 20, 10]);
    });

    test('同十連同道具重複兩筆，anchor 仍正確對齊', () {
      // 同 time 同道具重複兩筆（sec 皆 20），不可用單筆 key
      final dupA = r(99, name: '塵雲旋臂', sec: 20);
      final dupB = r(99, name: '塵雲旋臂', sec: 20);
      final old4 = [dupA, dupB, r(10, sec: 10), r(5, sec: 5)];
      final fresh = [
        r(60, sec: 60),
        r(50, sec: 50),
        dupA,
        dupB,
        r(10, sec: 10),
        r(5, sec: 5),
      ];
      final merged = mergeOrderedRecords(fresh, old4);
      expect(merged.map((e) => e.resourceId), [60, 50, 99, 99, 10, 5]);
      expect(merged.length, 6);
    });

    test('existing 被回應從中間切斷（fresh 不含 existing 最舊段）仍以 anchor 接舊', () {
      // fresh 只回到 sec=10 為止（更舊的 sec=5 被 API 截斷未回），
      // existing 仍保有 sec=5；合併後保留 existing 尾段
      final old3 = [r(20, sec: 20), r(10, sec: 10), r(5, sec: 5)];
      final fresh = [r(40, sec: 40), r(20, sec: 20), r(10, sec: 10)];
      final merged = mergeOrderedRecords(fresh, old3);
      expect(merged.map((e) => e.resourceId), [40, 20, 10, 5]);
    });

    test('anchor 在 fresh 找不到（換服/清號）→ 以 fresh 完整取代', () {
      final old3 = [r(30, sec: 30), r(20, sec: 20), r(10, sec: 10)];
      final fresh = [r(900, sec: 9), r(800, sec: 8)];
      final merged = mergeOrderedRecords(fresh, old3);
      expect(merged.map((e) => e.resourceId), [900, 800]);
    });

    test('existing 僅一筆、anchor 帶內同批重複，新頂端正確接上且重複不重算', () {
      // existing 只有 anchor 那一筆（A@20），maxAnchor 退為 1。fresh 在 A 之上
      // 多了兩筆更新（time 較大），且 A 所在十連在 fresh 內出現兩份相同的 A@20。
      // 對齊應落在 fresh 內第一個 A@20（band 起點），把上方兩筆當新筆接上 existing，
      // band 內第二份 A@20 屬重疊區、不可被當新筆重複前插。
      final a = r(100, name: 'A', sec: 20);
      final existing = [a];
      final fresh = [
        r(200, name: 'N2', sec: 32),
        r(150, name: 'N1', sec: 31),
        a,
        a,
      ];
      final merged = mergeOrderedRecords(fresh, existing);
      expect(merged.map((e) => e.resourceId), [200, 150, 100]);
      expect(merged.length, 3);
    });

    test('同道具更新十連（resourceId 相同但 time 較新）不被誤認成舊 anchor band', () {
      // existing anchor band 為 t=30 的 [A,A,B]（同十連，A 重複兩筆）。fresh 頂端
      // 是 t=31 的新十連，內含同一支 A（resourceId/name 相同但 time=31），這些新 A
      // 與舊 anchor 的 A@30 因 time 不同而不相等，anchor3 必須跳過新 band、落在真正的
      // 舊 band，否則會把新十連誤併入舊資料而錯接。
      final a = r(100, name: 'A', sec: 30);
      final b = r(200, name: 'B', sec: 30);
      final existing = [a, a, b, r(10, sec: 10)];
      final newA = r(100, name: 'A', sec: 31);
      final fresh = [
        r(300, name: 'C', sec: 31),
        newA,
        newA,
        a,
        a,
        b,
        r(10, sec: 10),
      ];
      final merged = mergeOrderedRecords(fresh, existing);
      expect(merged.map((e) => e.resourceId), [
        300,
        100,
        100,
        100,
        100,
        200,
        10,
      ]);
      expect(merged.length, 7);
    });

    test('fresh 比 existing 長且重疊落在 fresh 中段，重疊區不被重複計入', () {
      // existing 只保有頂端兩筆（其餘較舊段未存），fresh 較長：頂端三筆為新、之後
      // 接上 existing 兩筆、再往下還有更舊的兩筆（這兩筆 existing 沒存到）。對齊應落在
      // fresh 中段（index 3），只取上方三筆為新並接 existing 全部，fresh 中段以下不重算。
      final existing = [r(40, sec: 40), r(30, sec: 30)];
      final fresh = [
        r(80, sec: 80),
        r(70, sec: 70),
        r(60, sec: 60),
        r(40, sec: 40),
        r(30, sec: 30),
        r(20, sec: 20),
        r(10, sec: 10),
      ];
      final merged = mergeOrderedRecords(fresh, existing);
      expect(merged.map((e) => e.resourceId), [80, 70, 60, 40, 30]);
      expect(merged.length, 5);
    });

    test('換語言重抓：existing 語言保留、只前插新筆（新語言）', () {
      final existing = [
        r(30, name: '維里奈', sec: 30, lang: 'zh-Hant'),
        r(20, name: '安可', sec: 20, lang: 'zh-Hant'),
        r(10, name: '今汐', sec: 10, lang: 'zh-Hant'),
      ];
      final fresh = [
        r(40, name: 'Carlotta', sec: 40, lang: 'en'),
        r(30, name: 'Verina', sec: 30, lang: 'en'),
        r(20, name: 'Encore', sec: 20, lang: 'en'),
        r(10, name: 'Jinhsi', sec: 10, lang: 'en'),
      ];
      final merged = mergeOrderedRecords(fresh, existing);
      expect(merged.map((e) => e.resourceId), [40, 30, 20, 10]);
      expect(merged[0].languageCode, 'en');
      expect(merged[1].languageCode, 'zh-Hant');
      expect(merged[1].name, '維里奈');
      expect(merged[3].name, '今汐');
    });
  });

  group('mergeBackupRecords', () {
    /// 斷言 [sub] 為 [full] 的子序列（保序、可不連續）。
    bool isSubseq(List<GachaRecord> sub, List<GachaRecord> full) {
      var i = 0;
      for (final f in full) {
        if (i < sub.length && recordsEqual(sub[i], f)) i++;
      }
      return i == sub.length;
    }

    test('incoming 較新且完全重疊 → 接上新頭、保留本機', () {
      final local = [r(30, sec: 30), r(20, sec: 20), r(10, sec: 10)];
      final incoming = [
        r(50, sec: 50),
        r(40, sec: 40),
        r(30, sec: 30),
        r(20, sec: 20),
        r(10, sec: 10),
      ];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [50, 40, 30, 20, 10]);
    });

    test('incoming 較舊（補回更舊尾段）→ 保留本機、接上舊尾', () {
      final local = [r(30, sec: 30), r(20, sec: 20)];
      final incoming = [r(20, sec: 20), r(10, sec: 10), r(5, sec: 5)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [30, 20, 10, 5]);
    });

    test('incoming 完全包住 local（兩端都更長）→ 縫成完整聯集', () {
      final local = [r(4, sec: 4), r(3, sec: 3)];
      final incoming = [
        r(6, sec: 6),
        r(5, sec: 5),
        r(4, sec: 4),
        r(3, sec: 3),
        r(2, sec: 2),
        r(1, sec: 1),
      ];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [6, 5, 4, 3, 2, 1]);
    });

    test('local 完全包住 incoming → 回 local、不漏不重', () {
      final local = [
        r(5, sec: 5),
        r(4, sec: 4),
        r(3, sec: 3),
        r(2, sec: 2),
        r(1, sec: 1),
      ];
      final incoming = [r(4, sec: 4), r(3, sec: 3), r(2, sec: 2)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [5, 4, 3, 2, 1]);
    });

    test('完全不相交（incoming 較舊）→ 全部保留、較新在前', () {
      final local = [r(30, sec: 30), r(20, sec: 20)];
      final incoming = [r(10, sec: 10), r(5, sec: 5)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [30, 20, 10, 5]);
    });

    test('完全不相交（incoming 較新）→ 全部保留、incoming 在前', () {
      final local = [r(10, sec: 10), r(5, sec: 5)];
      final incoming = [r(30, sec: 30), r(20, sec: 20)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [30, 20, 10, 5]);
    });

    test('重疊落在同十連同 time 連續段 → 段內順序不被打亂', () {
      // t=30 的十連有兩筆（resourceId 31/32，sec 皆 30）
      final local = [r(40, sec: 40), r(31, sec: 30), r(32, sec: 30), r(20, sec: 20)];
      final incoming = [r(50, sec: 50), r(40, sec: 40), r(31, sec: 30), r(32, sec: 30)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [50, 40, 31, 32, 20]);
    });

    test('同十連同道具重複兩筆 → 多重數保留、不誤併', () {
      final local = [r(99, name: 'A', sec: 20), r(99, name: 'A', sec: 20)];
      final incoming = [r(99, name: 'A', sec: 20), r(99, name: 'A', sec: 20)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.map((e) => e.resourceId), [99, 99]);
      expect(merged.length, 2);
    });

    test('空 local → 回 incoming；空 incoming → 回 local', () {
      final incoming = [r(2, sec: 2), r(1, sec: 1)];
      expect(
        mergeBackupRecords(const [], incoming).map((e) => e.resourceId),
        [2, 1],
      );
      final local = [r(3, sec: 3)];
      expect(
        mergeBackupRecords(local, const []).map((e) => e.resourceId),
        [3],
      );
    });

    test('不漏資料：local 與 incoming 皆為輸出子序列', () {
      final local = [r(30, sec: 30), r(20, sec: 20)];
      final incoming = [r(20, sec: 20), r(10, sec: 10), r(5, sec: 5)];
      final merged = mergeBackupRecords(local, incoming);
      expect(isSubseq(local, merged), isTrue);
      expect(isSubseq(incoming, merged), isTrue);
    });

    test('錨點命中但整段重疊驗證失敗 → 退回 Case 3、兩段全保留', () {
      // 前 3 筆對齊（錨點命中），但第 4 筆不一致（模擬損毀／非同源備份），
      // 整段重疊驗證失敗，不可誤縫 → 退回 Case 3 保留兩段、不漏資料。
      final local = [r(10, sec: 10), r(9, sec: 9), r(8, sec: 8), r(7, sec: 7)];
      final incoming = [r(10, sec: 10), r(9, sec: 9), r(8, sec: 8), r(99, sec: 7)];
      final merged = mergeBackupRecords(local, incoming);
      expect(merged.length, local.length + incoming.length);
      expect(isSubseq(local, merged), isTrue);
      expect(isSubseq(incoming, merged), isTrue);
    });
  });
}
