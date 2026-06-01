# Data Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 把資料層（模型、合併、存檔、脫敏）從原神祈願 schema 改造為鳴潮喚取 schema，並以 TDD 先行交付核心高風險的有序清單增量合併。

**Architecture:** `GachaCredential` 封裝攔到的 POST body 五欄位；`GachaRecord` 改為鳴潮資源模型（resourceId/qualityLevel/resourceType/cardPoolType/name/count/time）並抽共用時間轉換；`record_merge.dart` 以「有序清單 anchor 對齊」取代原神靠唯一 id 比大小的增量合併；`BannerStorage` 升為帳號級（playerId + languageCode + 8 個 cardPoolType key）；`GachaStorage` 改顯式副檔名檔名規則；`AccountsBundle` 升 schemaVersion=2 拒原神舊檔。

**Tech Stack:** Dart / Flutter，`logging` 套件，`flutter_test`，本機 JSON 檔案存取。

---

> **前置依賴與整體狀態說明**
>
> - 本 plan 屬整個遷移系列的「03-資料層」階段，假設 **plan01-Package 改名** 已完成：全庫 import 前綴已是 `package:wuthering_waves_convene_gacha_analyzer/`。本 plan 所有程式碼一律用新前綴。
> - 型別替換期間整體 compile 可能短暫紅燈（下游 `gacha_fetcher.dart` / `gacha_repository.dart` / 各 stats 仍引用舊欄位，屬後續 plan 重寫範圍）。**純新增檔**（`gacha_credential.dart`、`record_merge.dart`）可獨立 TDD 全綠；**重寫既有檔**（`gacha_record.dart` 等）的單元測試亦可獨立全綠，但 `flutter analyze` 全庫可能仍有下游紅燈，至全部 plan 完成才全綠。
> - 各 Task 的「驗收」以**該 Task 的測試檔可單獨跑綠**為準（指令 `flutter test test/<path>`）；`flutter analyze` 全庫綠燈不列入本 plan 的逐 Task 驗收，留待系列末端。
> - 本專案目錄非 git repo。commit 步驟照寫；若執行時尚未 `git init`，commit 步驟略過不影響後續。
> - 提交前品質檢查依 CLAUDE.md：`dart format lib/ test/` → `flutter analyze` →（本階段允許下游紅燈）→ 對應測試綠。commit message 英文 conventional commits。不 git push。

---

## Task 1：`GachaCredential`（新檔，TDD）

封裝攔到的 POST body 五欄位，提供 `fromCapturedBody` 與 `toRequestBody`。取代舊 `lib/services/gacha_url.dart` 的 `GachaUrl`。純新增檔，可獨立 TDD 全綠。

**Files:**
- Test: `test/services/gacha_credential_test.dart`（Create）
- Create: `lib/services/gacha_credential.dart`

- [ ] 建立失敗測試 `test/services/gacha_credential_test.dart`，內容如下：

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';

void main() {
  const sampleBody = '''
{
  "playerId": "701000000",
  "cardPoolId": "2e2300000000000000000000002768",
  "cardPoolType": 1,
  "serverId": "86d500000000000000000000009650",
  "languageCode": "zh-Hant",
  "recordId": "0632000000000000000000008550"
}
''';

  group('GachaCredential.fromCapturedBody', () {
    test('解析典型 body 五欄位', () {
      final cred = GachaCredential.fromCapturedBody(sampleBody);
      expect(cred.playerId, '701000000');
      expect(cred.cardPoolId, '2e2300000000000000000000002768');
      expect(cred.serverId, '86d500000000000000000000009650');
      expect(cred.languageCode, 'zh-Hant');
      expect(cred.recordId, '0632000000000000000000008550');
    });

    test('cardPoolType 為數字時不影響五欄位解析（迭代時自行替換）', () {
      final cred = GachaCredential.fromCapturedBody(sampleBody);
      expect(cred.playerId, isNotEmpty);
    });

    test('缺必要欄位時丟 FormatException', () {
      const missing = '{"playerId":"701","cardPoolId":"x"}';
      expect(
        () => GachaCredential.fromCapturedBody(missing),
        throwsA(isA<FormatException>()),
      );
    });

    test('非 JSON 字串丟 FormatException', () {
      expect(
        () => GachaCredential.fromCapturedBody('not json at all'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('GachaCredential.toRequestBody', () {
    test('共用五欄位、只換 cardPoolType（int）', () {
      final cred = GachaCredential.fromCapturedBody(sampleBody);
      final body = cred.toRequestBody(8);
      expect(body['playerId'], '701000000');
      expect(body['cardPoolId'], '2e2300000000000000000000002768');
      expect(body['serverId'], '86d500000000000000000000009650');
      expect(body['languageCode'], 'zh-Hant');
      expect(body['recordId'], '0632000000000000000000008550');
      expect(body['cardPoolType'], 8);
      expect(body['cardPoolType'], isA<int>());
    });

    test('toRequestBody 可被 jsonEncode 序列化', () {
      final cred = GachaCredential.fromCapturedBody(sampleBody);
      final encoded = jsonEncode(cred.toRequestBody(2));
      expect(jsonDecode(encoded), isA<Map<String, dynamic>>());
    });
  });

  group('GachaCredential.toJsonString 往返', () {
    test('輸出五欄位 JSON，可被 fromCapturedBody 還原（roundtrip）', () {
      final cred = GachaCredential.fromCapturedBody(sampleBody);
      final restored = GachaCredential.fromCapturedBody(cred.toJsonString());
      expect(restored.playerId, cred.playerId);
      expect(restored.cardPoolId, cred.cardPoolId);
      expect(restored.serverId, cred.serverId);
      expect(restored.recordId, cred.recordId);
      expect(restored.languageCode, cred.languageCode);
    });

    test('toJsonString 含全部五欄位 key', () {
      final cred = GachaCredential.fromCapturedBody(sampleBody);
      final json = jsonDecode(cred.toJsonString()) as Map<String, dynamic>;
      expect(json.keys.toSet(), {
        'playerId',
        'cardPoolId',
        'serverId',
        'recordId',
        'languageCode',
      });
      expect(json['playerId'], '701000000');
      expect(json['languageCode'], 'zh-Hant');
    });
  });
}
```

- [ ] 跑驗證失敗：`flutter test test/services/gacha_credential_test.dart` → 預期編譯失敗（`Error: Couldn't resolve the package 'wuthering_waves_convene_gacha_analyzer'` 已解析，但 `gacha_credential.dart` 不存在 → `Target of URI doesn't exist`）。
- [ ] 建立 `lib/services/gacha_credential.dart`：

```dart
import 'dart:convert';

/// 封裝攔到的喚取記錄 POST body 五個查詢憑證欄位，並負責迭代各 cardPoolType
/// 時組出請求 body。取代原神版以 URL query 攜帶憑證的 `GachaUrl`。
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

  /// 語言碼（如 `zh-Hant`），決定回應內名稱/類型字串語言與圖片 API 的 X-Language。
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
    String require(String key) {
      final v = decoded[key];
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
    'playerId': playerId,
    'cardPoolId': cardPoolId,
    'cardPoolType': cardPoolType,
    'serverId': serverId,
    'languageCode': languageCode,
    'recordId': recordId,
  };

  /// 序列化為五欄位憑證 JSON 字串（存檔用），與 [fromCapturedBody] 互為往返：
  /// `GachaCredential.fromCapturedBody(cred.toJsonString())` 可完整還原。
  ///
  /// 僅輸出五個憑證欄位（不含 cardPoolType，後者由迭代時 [toRequestBody] 動態帶入），
  /// 供 `gacha_storage` 以 `saveCapturedCredential` 存檔、`fromCapturedBody` 讀回。
  String toJsonString() => jsonEncode({
    'playerId': playerId,
    'cardPoolId': cardPoolId,
    'serverId': serverId,
    'recordId': recordId,
    'languageCode': languageCode,
  });
}
```

- [ ] 跑驗證通過：`flutter test test/services/gacha_credential_test.dart` → 預期 `All tests passed!`。
- [ ] 刪除被取代的舊檔與其測試：刪 `lib/services/gacha_url.dart`、刪 `test/services/gacha_url_test.dart`。
  - 指令（PowerShell）：`Remove-Item lib\services\gacha_url.dart, test\services\gacha_url_test.dart`
  - 註：`gacha_fetcher.dart` 仍 import `gacha_url.dart`，此處刪檔會讓該檔短暫紅燈，屬後續抓取串接 plan（plan04）修正範圍，本 Task 不處理。
- [ ] `dart format lib/services/gacha_credential.dart test/services/gacha_credential_test.dart`。
- [ ] commit：`feat(data): add GachaCredential and remove legacy GachaUrl`

---

## Task 2：`GachaRecord` 重寫（TDD）

改為鳴潮資源模型，抽共用 `parseGachaTime`/`formatGachaTime`。可獨立 TDD 全綠（不依賴下游）。

**Files:**
- Test: `test/models/gacha_record_test.dart`（Modify，整檔重寫）
- Modify: `lib/models/gacha_record.dart`（整檔重寫，原 1–111 行）

- [ ] 整檔重寫 `test/models/gacha_record_test.dart` 為：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

void main() {
  group('parseGachaTime / formatGachaTime', () {
    test('parse "YYYY-MM-DD HH:mm:ss" → DateTime（本地時間語意）', () {
      final t = parseGachaTime('2026-05-21 11:03:18');
      expect(t, DateTime(2026, 5, 21, 11, 3, 18));
    });

    test('format DateTime → "YYYY-MM-DD HH:mm:ss" 補零', () {
      final s = formatGachaTime(DateTime(2026, 2, 7, 16, 19, 41));
      expect(s, '2026-02-07 16:19:41');
    });

    test('format 個位數月日時分秒皆補零', () {
      final s = formatGachaTime(DateTime(2026, 1, 2, 3, 4, 5));
      expect(s, '2026-01-02 03:04:05');
    });

    test('parse → format roundtrip', () {
      const raw = '2026-05-21 10:39:03';
      expect(formatGachaTime(parseGachaTime(raw)), raw);
    });
  });

  group('GachaRecord.fromApiJson', () {
    test('解析角色 5★ 記錄', () {
      final json = {
        'cardPoolType': '1',
        'resourceId': 1211,
        'qualityLevel': 5,
        'resourceType': '角色',
        'name': '達妮婭',
        'count': 1,
        'time': '2026-05-21 10:39:03',
      };
      final r = GachaRecord.fromApiJson(json, cardPoolType: '1');
      expect(r.resourceId, 1211);
      expect(r.qualityLevel, 5);
      expect(r.resourceType, '角色');
      expect(r.cardPoolType, '1');
      expect(r.name, '達妮婭');
      expect(r.count, 1);
      expect(r.time, DateTime(2026, 5, 21, 10, 39, 3));
    });

    test('解析道具 4★ 記錄（同卡池可混入道具）', () {
      final json = {
        'cardPoolType': '1',
        'resourceId': 21040084,
        'qualityLevel': 4,
        'resourceType': '道具',
        'name': '塵雲旋臂',
        'count': 1,
        'time': '2026-02-07 16:19:41',
      };
      final r = GachaRecord.fromApiJson(json, cardPoolType: '1');
      expect(r.resourceType, '道具');
      expect(r.qualityLevel, 4);
      expect(r.resourceId, 21040084);
    });

    test('cardPoolType 以呼叫端傳入值為準（回應內字串一致時不衝突）', () {
      final json = {
        'cardPoolType': '1',
        'resourceId': 1601,
        'qualityLevel': 4,
        'resourceType': '角色',
        'name': '桃祈',
        'count': 1,
        'time': '2026-05-21 11:03:18',
      };
      final r = GachaRecord.fromApiJson(json, cardPoolType: '8');
      expect(r.cardPoolType, '8');
    });
  });

  group('GachaRecord 存檔序列化', () {
    test('toStorageJson key 為鳴潮 snake_case', () {
      final r = GachaRecord(
        resourceId: 1211,
        qualityLevel: 5,
        resourceType: '角色',
        cardPoolType: '1',
        name: '達妮婭',
        count: 1,
        time: DateTime(2026, 5, 21, 10, 39, 3),
      );
      final json = r.toStorageJson();
      expect(json['resource_id'], 1211);
      expect(json['quality_level'], 5);
      expect(json['resource_type'], '角色');
      expect(json['card_pool_type'], '1');
      expect(json['name'], '達妮婭');
      expect(json['count'], 1);
      expect(json['time'], '2026-05-21 10:39:03');
    });

    test('toStorageJson / fromStorageJson roundtrip', () {
      final original = GachaRecord(
        resourceId: 21020023,
        qualityLevel: 3,
        resourceType: '武器',
        cardPoolType: '1',
        name: '源能迅刀·測貳',
        count: 1,
        time: DateTime(2026, 5, 21, 11, 3, 18),
      );
      final restored = GachaRecord.fromStorageJson(original.toStorageJson());
      expect(restored.resourceId, original.resourceId);
      expect(restored.qualityLevel, original.qualityLevel);
      expect(restored.resourceType, original.resourceType);
      expect(restored.cardPoolType, original.cardPoolType);
      expect(restored.name, original.name);
      expect(restored.count, original.count);
      expect(restored.time, original.time);
    });
  });
}
```

- [ ] 跑驗證失敗：`flutter test test/models/gacha_record_test.dart` → 預期編譯失敗（`parseGachaTime` 未定義、`GachaRecord` 缺新欄位 / 仍要求 `id`/`uid`/`lang`）。
- [ ] 整檔重寫 `lib/models/gacha_record.dart` 為：

```dart
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
```

- [ ] 跑驗證通過：`flutter test test/models/gacha_record_test.dart` → 預期 `All tests passed!`。
- [ ] `dart format lib/models/gacha_record.dart test/models/gacha_record_test.dart`。
- [ ] commit：`feat(data): rewrite GachaRecord for Wuthering Waves resource schema`

---

## Task 3：`record_merge.dart`（新檔，核心高風險，TDD 先行）

有序清單增量合併 + 逐筆相等比較。fixture 必含：同十連同道具重複兩筆、新期首筆＝舊頂端、existing 被中切、空集、anchor 找不到→以 fresh 取代+warn。純新增檔，可獨立 TDD 全綠。

**Files:**
- Test: `test/services/record_merge_test.dart`（Create）
- Create: `lib/services/record_merge.dart`

- [ ] 建立失敗測試 `test/services/record_merge_test.dart`：

```dart
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
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: quality,
  resourceType: type,
  cardPoolType: '1',
  name: name,
  count: count,
  time: DateTime(2026, 5, 21, 11, 0, sec),
);

void main() {
  group('recordsEqual', () {
    test('五欄位全等 → true', () {
      expect(recordsEqual(r(1, name: 'a', sec: 3), r(1, name: 'a', sec: 3)),
          isTrue);
    });
    test('resourceId 不同 → false', () {
      expect(recordsEqual(r(1, sec: 3), r(2, sec: 3)), isFalse);
    });
    test('name 不同 → false', () {
      expect(recordsEqual(r(1, name: 'a'), r(1, name: 'b')), isFalse);
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
  });
}
```

- [ ] 跑驗證失敗：`flutter test test/services/record_merge_test.dart` → 預期編譯失敗（`record_merge.dart` 不存在）。
- [ ] 建立 `lib/services/record_merge.dart`：

```dart
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

/// Logger 實例（喚取記錄合併）。
final _log = Logger('wish.merge');

/// anchor 長度：取 existing 開頭連續 N 筆作為對齊指紋。
const _anchorBase = 3;

/// 判斷兩筆喚取紀錄是否為同一筆。
///
/// 比對 (time, resourceId, qualityLevel, name, count) 全等。鳴潮無唯一 id 且同
/// 十連 time 相同，單欄位皆不足以辨識，故用此五欄位複合比較；仍可能與同批同道具
/// 碰撞，因此只用於序列對齊輔助，不可單獨當主鍵。
bool recordsEqual(GachaRecord a, GachaRecord b) =>
    a.time == b.time &&
    a.resourceId == b.resourceId &&
    a.qualityLevel == b.qualityLevel &&
    a.name == b.name &&
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

  // anchor 長度從 _anchorBase 起，必要時放大到 existing 全長以提高辨識度。
  var anchorLen = existing.length < _anchorBase ? existing.length : _anchorBase;

  while (true) {
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
    // 對齊失敗時放大 anchor 再試（同批重複可能讓短 anchor 多義）。
    if (anchorLen >= existing.length) break;
    anchorLen = (anchorLen * 2).clamp(1, existing.length);
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
```

- [ ] 跑驗證通過：`flutter test test/services/record_merge_test.dart` → 預期 `All tests passed!`。
- [ ] `dart format lib/services/record_merge.dart test/services/record_merge_test.dart`。
- [ ] commit：`feat(data): add ordered-list incremental merge (record_merge)`

---

## Task 4：`BannerStorage` 改造（playerId / languageCode / 8 cardPoolType key）

`uid` 語意改 `playerId`；新增帳號級 `languageCode`；toJson 落 `player_id`/`language_code`。

**Files:**
- Modify: `lib/models/banner_storage.dart`（整檔重寫，原 1–63 行）
- Test: `test/models/gacha_record_test.dart` 內的 `BannerStorage roundtrip` group 已在 Task 2 移除；本 Task 新增獨立測試 `test/models/banner_storage_test.dart`（Create）

- [ ] 建立失敗測試 `test/models/banner_storage_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

GachaRecord _r(int id) => GachaRecord(
  resourceId: id,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: '1',
  name: '達妮婭',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, 3),
);

void main() {
  test('toJson 落 player_id / language_code / 8 個 cardPoolType key', () {
    final storage = BannerStorage(
      playerId: '701000000',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 5, 21, 3, 30),
      banners: {
        '1': [_r(1211)],
        '2': [],
        '3': [],
        '4': [],
        '5': [],
        '6': [],
        '8': [],
        '9': [],
      },
    );
    final json = storage.toJson();
    expect(json['player_id'], '701000000');
    expect(json['language_code'], 'zh-Hant');
    expect(json['last_updated'], '2026-05-21T03:30:00.000Z');
    expect((json['banners'] as Map).keys.toSet(),
        {'1', '2', '3', '4', '5', '6', '8', '9'});
    expect((json['banners'] as Map)['1'], hasLength(1));
  });

  test('fromJson roundtrip 保留 playerId / languageCode / banners', () {
    final original = BannerStorage(
      playerId: '701000000',
      languageCode: 'en',
      lastUpdated: DateTime.utc(2026, 5, 21, 3, 30),
      banners: {
        '1': [_r(1211)],
        '8': [],
      },
    );
    final restored = BannerStorage.fromJson(original.toJson());
    expect(restored.playerId, '701000000');
    expect(restored.languageCode, 'en');
    expect(restored.lastUpdated, original.lastUpdated);
    expect(restored.banners['1']!.single.resourceId, 1211);
    expect(restored.banners['8'], isEmpty);
  });

  test('allRecords 串接所有 banner', () {
    final storage = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026),
      banners: {
        '1': [_r(1), _r(2)],
        '8': [_r(3)],
      },
    );
    expect(storage.allRecords.map((e) => e.resourceId).toSet(), {1, 2, 3});
  });

  test('copyWith 可覆寫 languageCode / lastUpdated / banners，playerId 不變', () {
    final original = BannerStorage(
      playerId: 'p',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: const {'1': []},
    );
    final updated = original.copyWith(
      languageCode: 'ja',
      lastUpdated: DateTime.utc(2026, 2, 2),
    );
    expect(updated.playerId, 'p');
    expect(updated.languageCode, 'ja');
    expect(updated.lastUpdated, DateTime.utc(2026, 2, 2));
  });
}
```

- [ ] 跑驗證失敗：`flutter test test/models/banner_storage_test.dart` → 預期編譯失敗（`BannerStorage` 仍要求 `uid`、無 `playerId`/`languageCode`）。
- [ ] 整檔重寫 `lib/models/banner_storage.dart`：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

/// 單一帳號（playerId）的全卡池喚取存檔。
///
/// languageCode 為帳號級單一值（取代原神逐筆 record.lang），決定回應內名稱/類型
/// 字串語言，並供圖片 API 的 X-Language 使用。
class BannerStorage {
  /// 建立 [BannerStorage]。
  const BannerStorage({
    required this.playerId,
    required this.languageCode,
    required this.lastUpdated,
    required this.banners,
  });

  /// 玩家 UID（取代原神版 uid）。
  final String playerId;

  /// 帳號級語言碼（如 `zh-Hant`）。
  final String languageCode;

  /// 最後更新時間（UTC）。
  final DateTime lastUpdated;

  /// cardPoolType 字串（`'1'..'9'`，無 `'7'`）→ 該卡池紀錄（由新到舊）。
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
  /// 不額外寫入 schema 版本欄位：舊原神/新鳴潮檔的辨識（§C）依賴每筆 record 是否含
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
```

- [ ] 跑驗證通過：`flutter test test/models/banner_storage_test.dart` → 預期 `All tests passed!`。
- [ ] `dart format lib/models/banner_storage.dart test/models/banner_storage_test.dart`。
- [ ] commit：`feat(data): make BannerStorage account-level (playerId + languageCode + 8 pools)`

---

## Task 5：`AccountsBundle`（schemaVersion=2、拒原神舊檔、seen 改 playerId）

**Files:**
- Modify: `lib/models/accounts_bundle.dart`（`currentSchemaVersion` 第 41 行、`fromJson` 第 68–127 行、`seen` 第 85/97 行）
- Test: `test/models/accounts_bundle_test.dart`（Modify，整檔重寫）

- [ ] 整檔重寫 `test/models/accounts_bundle_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';

GachaRecord _r(int id) => GachaRecord(
  resourceId: id,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: '1',
  name: '達妮婭',
  count: 1,
  time: DateTime(2026, 5, 21, 10, 39, 3),
);

BannerStorage _bs(String playerId) => BannerStorage(
  playerId: playerId,
  languageCode: 'zh-Hant',
  lastUpdated: DateTime.utc(2026, 5, 21),
  banners: {'1': [_r(1211)]},
);

void main() {
  test('schemaVersion 為 2', () {
    expect(AccountsBundle.currentSchemaVersion, 2);
  });

  test('toJson / fromJson roundtrip 保留順序、alias、last_active_uid', () {
    final bundle = AccountsBundle(
      exportedAt: DateTime.utc(2026, 5, 21, 8, 30),
      appVersion: '2.0.0',
      lastActiveUid: 'A',
      accounts: [
        ExportedAccount(alias: '主號', data: _bs('A')),
        ExportedAccount(data: _bs('B')),
      ],
    );
    final back = AccountsBundle.fromJson(bundle.toJson());
    expect(back.schemaVersion, 2);
    expect(back.lastActiveUid, 'A');
    expect(back.accounts.map((a) => a.data.playerId).toList(), ['A', 'B']);
    expect(back.accounts[0].alias, '主號');
    expect(back.accounts[1].alias, isNull);
  });

  test('schema_version != 2（原神舊備份 version=1）→ 友善訊息', () {
    final json = {
      'schema_version': 1,
      'exported_at': '2026-05-21T00:00:00.000Z',
      'app_version': '1.0.0',
      'accounts': <Map<String, dynamic>>[],
    };
    expect(
      () => AccountsBundle.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('原神'),
        ),
      ),
    );
  });

  test('schema_version 為較新版本（999）→ 同樣拒絕', () {
    final json = {
      'schema_version': 999,
      'exported_at': '2026-05-21T00:00:00.000Z',
      'accounts': <Map<String, dynamic>>[],
    };
    expect(
      () => AccountsBundle.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });

  test('缺 schema_version → 拋例外', () {
    expect(
      () => AccountsBundle.fromJson({'accounts': []}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('schema_version'),
        ),
      ),
    );
  });

  test('accounts 非陣列 → 拋例外', () {
    expect(
      () => AccountsBundle.fromJson({'schema_version': 2, 'accounts': 'nope'}),
      throwsA(isA<FormatException>()),
    );
  });

  test('重複 playerId → 拋例外', () {
    final accountJson = _bs('X').toJson();
    expect(
      () => AccountsBundle.fromJson({
        'schema_version': 2,
        'accounts': [accountJson, accountJson],
      }),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Duplicate'),
        ),
      ),
    );
  });

  test('alias 空白字串讀回為 null', () {
    final bundle = AccountsBundle.fromJson({
      'schema_version': 2,
      'accounts': [
        {..._bs('A').toJson(), 'alias': '   '},
      ],
    });
    expect(bundle.accounts.single.alias, isNull);
  });
}
```

- [ ] 跑驗證失敗：`flutter test test/models/accounts_bundle_test.dart` → 預期失敗（`currentSchemaVersion` 仍為 1；version=1 目前不被拒）。
- [ ] 改 `lib/models/accounts_bundle.dart` 第 41 行：

```dart
  static const int currentSchemaVersion = 2;
```

- [ ] 改 `lib/models/accounts_bundle.dart` 的 `fromJson` 版本檢查段（原第 69–77 行），把「`version is! int` / `version > currentSchemaVersion`」整段替換為「`version != currentSchemaVersion` + 友善訊息」：

  原段落：
```dart
    final version = json['schema_version'];
    if (version is! int) {
      throw const FormatException('Missing or invalid "schema_version"');
    }
    if (version > currentSchemaVersion) {
      throw FormatException(
        'Unsupported schema version: $version. Please update the app.',
      );
    }
```
  替換為：
```dart
    final version = json['schema_version'];
    if (version is! int) {
      throw const FormatException('Missing or invalid "schema_version"');
    }
    if (version != currentSchemaVersion) {
      throw FormatException(
        'schema_version=$version 與本版（$currentSchemaVersion）不相容：'
        '此為原神版備份，無法匯入鳴潮版。',
      );
    }
```

- [ ] 改 `seen` 去重 key 由 `uid` 改 `playerId`（原第 97–99 行）：

  原段落：
```dart
      if (!seen.add(account.data.uid)) {
        throw FormatException('Duplicate UID in accounts: ${account.data.uid}');
      }
```
  替換為：
```dart
      if (!seen.add(account.data.playerId)) {
        throw FormatException(
          'Duplicate playerId in accounts: ${account.data.playerId}',
        );
      }
```

- [ ] 跑驗證通過：`flutter test test/models/accounts_bundle_test.dart` → 預期 `All tests passed!`。
- [ ] `dart format lib/models/accounts_bundle.dart test/models/accounts_bundle_test.dart`。
- [ ] commit：`feat(data): bump AccountsBundle schema to v2 and reject Genshin backups`

---

## Task 6：`sanitizeCredential`（log_sanitize.dart 新增，TDD）

body JSON 脫敏：playerId 走 `sanitizeUid`，recordId/serverId/cardPoolId 前 4 後 4 遮罩。純新增函式，可獨立 TDD 全綠。

**Files:**
- Modify: `lib/services/log_sanitize.dart`（檔尾新增函式）
- Test: `test/services/log_sanitize_test.dart`（Modify，新增 group）

- [ ] 在 `test/services/log_sanitize_test.dart` 檔尾的 `main()` 內新增以下 group（先讀檔取得 `main()` 結尾 `}` 位置，於其前插入）：

```dart
  group('sanitizeCredential', () {
    const body = '{"playerId":"701000000",'
        '"cardPoolId":"2e2300000000000000000000002768",'
        '"cardPoolType":1,'
        '"serverId":"86d500000000000000000000009650",'
        '"languageCode":"zh-Hant",'
        '"recordId":"0632000000000000000000008550"}';

    test('playerId 走 sanitizeUid、hash 欄位前4後4遮罩、languageCode 保留', () {
      final out = sanitizeCredential(body);
      expect(out, isNot(contains('701000000')));
      expect(out, contains(sanitizeUid('701000000')));
      // cardPoolId 前4後4：2e23...2768
      expect(out, contains('2e23'));
      expect(out, contains('2768'));
      expect(out, isNot(contains('2e2300000000000000000000002768')));
      // recordId / serverId 中段遮罩
      expect(out, isNot(contains('0632000000000000000000008550')));
      expect(out, isNot(contains('86d500000000000000000000009650')));
      // languageCode 非敏感、保留
      expect(out, contains('zh-Hant'));
      // cardPoolType 非敏感、保留
      expect(out, contains('1'));
    });

    test('非 JSON 字串 → 回退標記，不洩漏原文', () {
      final out = sanitizeCredential('not a json body');
      expect(out, '<malformed credential>');
    });

    test('輸出為可解析 JSON', () {
      final out = sanitizeCredential(body);
      expect(() => out, returnsNormally);
      expect(out, contains('"playerId"'));
    });
  });
```

- [ ] 確認測試檔頂端已 import `dart:convert`（`sanitizeCredential` 測試本身不需，但若無其它 import 變動可略）；`sanitizeUid`/`sanitizeCredential` 由既有 `import '...log_sanitize.dart'` 提供。
- [ ] 跑驗證失敗：`flutter test test/services/log_sanitize_test.dart` → 預期編譯失敗（`sanitizeCredential` 未定義）。
- [ ] 在 `lib/services/log_sanitize.dart` 檔尾（第 61 行 `}` 之後）新增：

```dart

/// 把攔到的喚取 body JSON 脫敏後輸出，供 log 使用。
///
/// playerId 走 [sanitizeUid]；recordId / serverId / cardPoolId 等 hash 走前 4 後 4
/// 遮罩；languageCode / cardPoolType 等非敏感欄位原樣保留。非 JSON 物件時回
/// `<malformed credential>`，避免原文（含 playerId）漏進 log。
String sanitizeCredential(String bodyJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(bodyJson);
  } catch (_) {
    return '<malformed credential>';
  }
  if (decoded is! Map<String, dynamic>) {
    return '<malformed credential>';
  }
  const hashKeys = {'recordId', 'serverId', 'cardPoolId'};
  final out = <String, dynamic>{};
  decoded.forEach((key, value) {
    if (key == 'playerId' && value is String) {
      out[key] = sanitizeUid(value);
    } else if (hashKeys.contains(key) && value is String) {
      out[key] = _maskHash(value);
    } else {
      out[key] = value;
    }
  });
  return jsonEncode(out);
}

/// hash 字串遮罩：保留前 4 後 4，中段以 `****` 取代；長度 < 9 全遮 `***`。
String _maskHash(String raw) {
  if (raw.length < 9) return '***';
  return '${raw.substring(0, 4)}****${raw.substring(raw.length - 4)}';
}
```

- [ ] 在 `lib/services/log_sanitize.dart` 檔頂新增 `import 'dart:convert';`（目前該檔無 import；加在第 1 行）：

```dart
import 'dart:convert';
```

- [ ] 跑驗證通過：`flutter test test/services/log_sanitize_test.dart` → 預期 `All tests passed!`。
- [ ] `dart format lib/services/log_sanitize.dart test/services/log_sanitize_test.dart`。
- [ ] commit：`feat(data): add sanitizeCredential for capture body redaction`

---

## Task 7：`GachaStorage` 改造（顯式副檔名、cred 檔、副檔名白名單）

檔名 `<playerId>.records.json` / `<playerId>.cred.json`；`save/loadCapturedCredential`；`listKnownUids` 改用 `.records.json` 副檔名（棄 `_uidPattern`，metadata 自然排除）；`load` 遇舊原神格式跳過 + warning。

**Files:**
- Modify: `lib/services/gacha_storage.dart`（整檔重寫，原 1–129 行）
- Test: `test/services/gacha_storage_test.dart`（Modify，整檔重寫）

- [ ] 整檔重寫 `test/services/gacha_storage_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';

void main() {
  late Directory tempDir;
  late GachaStorage storage;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gacha_test_');
    storage = GachaStorage(tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  GachaRecord makeRecord(int id) => GachaRecord(
    resourceId: id,
    qualityLevel: 5,
    resourceType: '角色',
    cardPoolType: '1',
    name: '達妮婭',
    count: 1,
    time: DateTime(2026, 5, 21, 10, 39, 3),
  );

  BannerStorage makeStorage(String playerId) => BannerStorage(
    playerId: playerId,
    languageCode: 'zh-Hant',
    lastUpdated: DateTime.utc(2026, 5, 21),
    banners: {
      '1': [makeRecord(1211)],
      '8': [],
    },
  );

  test('save → 檔名為 <playerId>.records.json', () async {
    await storage.save(makeStorage('701000000'));
    expect(
      await File('${tempDir.path}/701000000.records.json').exists(),
      isTrue,
    );
  });

  test('save → load roundtrip', () async {
    await storage.save(makeStorage('701000000'));
    final loaded = await storage.load('701000000');
    expect(loaded, isNotNull);
    expect(loaded!.playerId, '701000000');
    expect(loaded.languageCode, 'zh-Hant');
    expect(loaded.banners['1']!.single.resourceId, 1211);
  });

  test('load 不存在的 playerId → null', () async {
    expect(await storage.load('not_exist'), isNull);
  });

  test('load 遇舊原神格式（缺 resource_id）→ 跳過回 null + 不 rethrow', () async {
    // 模擬殘留的原神 schema 檔（手動以 .records.json 命名）
    await File('${tempDir.path}/legacy.records.json').writeAsString(
      '{"player_id":"legacy","language_code":"zh-tw",'
      '"last_updated":"2026-01-01T00:00:00.000Z",'
      '"banners":{"301":[{"id":"1","uid":"legacy","gacha_type":"301",'
      '"name":"x","item_type":"角色","rank_type":5,'
      '"time":"2025-01-01 00:00:00","lang":"zh-tw"}]}}',
    );
    final loaded = await storage.load('legacy');
    expect(loaded, isNull);
  });

  test('listKnownUids 只列 <playerId>.records.json，忽略 cred 與 metadata', () async {
    await File('${tempDir.path}/701.records.json').writeAsString('{}');
    await File('${tempDir.path}/abc.records.json').writeAsString('{}');
    await File('${tempDir.path}/701.cred.json').writeAsString('{}');
    await File('${tempDir.path}/item_image_index.json').writeAsString('{}');
    await File('${tempDir.path}/garbage.txt').writeAsString('');

    final uids = await storage.listKnownUids();
    expect(uids.toSet(), {'701', 'abc'});
  });

  test('saveCapturedCredential / loadCapturedCredential / deleteCapturedCredential',
      () async {
    const body = '{"playerId":"701","cardPoolId":"x","serverId":"y",'
        '"languageCode":"zh-Hant","recordId":"z"}';
    await storage.saveCapturedCredential('701', body);
    expect(await storage.loadCapturedCredential('701'), body);

    await storage.deleteCapturedCredential('701');
    expect(await storage.loadCapturedCredential('701'), isNull);
  });

  test('cred 檔名為 <playerId>.cred.json', () async {
    await storage.saveCapturedCredential('701', '{"playerId":"701"}');
    expect(await File('${tempDir.path}/701.cred.json').exists(), isTrue);
  });

  test('save 用 atomic rename：.tmp 不殘留', () async {
    await storage.save(makeStorage('1'));
    expect(
      await File('${tempDir.path}/1.records.json.tmp').exists(),
      isFalse,
    );
  });

  test('save 同一 playerId 兩次 → 第二份覆蓋第一份', () async {
    await storage.save(makeStorage('999'));
    final v2 = makeStorage('999').copyWith(
      lastUpdated: DateTime.utc(2026, 6, 1),
      banners: {
        '1': [makeRecord(9999)],
        '8': [],
      },
    );
    await storage.save(v2);
    final loaded = await storage.load('999');
    expect(loaded!.banners['1']!.single.resourceId, 9999);
    expect(loaded.lastUpdated, DateTime.utc(2026, 6, 1));
  });

  test('delete 移除 records 與 cred 檔', () async {
    await storage.save(makeStorage('701'));
    await storage.saveCapturedCredential('701', '{"playerId":"701"}');
    await storage.delete('701');
    expect(await File('${tempDir.path}/701.records.json').exists(), isFalse);
    expect(await File('${tempDir.path}/701.cred.json').exists(), isFalse);
  });
}
```

- [ ] 跑驗證失敗：`flutter test test/services/gacha_storage_test.dart` → 預期編譯失敗（`saveCapturedCredential` 等不存在、`BannerStorage` 簽名不符）。
- [ ] 整檔重寫 `lib/services/gacha_storage.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 負責喚取資料與已擷取憑證（credential body）的本地 JSON 讀寫。
///
/// 檔名規則改用顯式副檔名（spec D3）：記錄檔 `<playerId>.records.json`、憑證檔
/// `<playerId>.cred.json`，playerId 一律當不透明字串（不靠數字 regex 篩選）。
class GachaStorage {
  /// 建立 [GachaStorage]，需指定資料根目錄 [baseDir]。
  GachaStorage(this.baseDir);

  /// Logger 實例（gacha 儲存）。
  static final _log = Logger('gacha.storage');

  /// 記錄檔副檔名。
  static const _recordsSuffix = '.records.json';

  /// 憑證檔副檔名。
  static const _credSuffix = '.cred.json';

  /// `<applicationSupportDirectory>/gacha_data/`，main.dart 創建後傳入。
  final Directory baseDir;

  /// 回傳 [playerId] 對應的記錄檔路徑。
  File _recordsFile(String playerId) =>
      File('${baseDir.path}/$playerId$_recordsSuffix');

  /// 回傳 [playerId] 對應的憑證檔路徑。
  File _credFile(String playerId) =>
      File('${baseDir.path}/$playerId$_credSuffix');

  /// 讀取 [playerId] 的喚取資料；不存在回 null。
  ///
  /// 舊檔辨識標記（§C）：鳴潮新 schema 每筆 record 必含 `resource_id`（整數），舊
  /// 原神 schema 則無（其鍵為 `id`/`gacha_type`/`item_type`/`rank_type`/`lang`）。
  /// 因此本 `load` 以「`GachaRecord.fromStorageJson` 解析時缺 `resource_id` 而拋例外」
  /// 作為舊檔偵測依據——不另在 `BannerStorage.toJson` 加版本欄位，缺 `resource_id`
  /// 即足以區分。遇此情形時跳過該檔並 log warning、回 null，**不可 rethrow**（否則
  /// 殘留舊檔會讓整個 App 開不起來，spec D2）。
  Future<BannerStorage?> load(String playerId) async {
    final f = _recordsFile(playerId);
    if (!await f.exists()) return null;
    try {
      final text = await f.readAsString();
      final json = jsonDecode(text) as Map<String, dynamic>;
      return BannerStorage.fromJson(json);
    } catch (e, st) {
      _log.warning(
        'skip unparseable records file (likely legacy Genshin schema) for '
        'playerId=${sanitizeUid(playerId)}',
        e,
        st,
      );
      return null;
    }
  }

  /// 將 [data] 寫回磁碟。
  Future<void> save(BannerStorage data) async {
    try {
      await _atomicWrite(
        _recordsFile(data.playerId),
        jsonEncode(data.toJson()),
      );
      final total = data.banners.values.fold<int>(0, (a, b) => a + b.length);
      _log.fine('saved playerId=${sanitizeUid(data.playerId)} records=$total');
    } catch (e, st) {
      _log.severe('save failed for playerId=${sanitizeUid(data.playerId)}', e, st);
      rethrow;
    }
  }

  /// 回傳 [baseDir] 中所有已有記錄檔的 playerId 列表。
  ///
  /// 以 `.records.json` 副檔名辨識（spec D3），metadata（如 item_image 索引）與
  /// 憑證檔因副檔名不同而自然排除，不需數字 regex。
  Future<List<String>> listKnownUids() async {
    if (!await baseDir.exists()) return const [];
    final entries = await baseDir.list().toList();
    final ids = <String>[];
    for (final e in entries) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!name.endsWith(_recordsSuffix)) continue;
      ids.add(name.substring(0, name.length - _recordsSuffix.length));
    }
    return ids;
  }

  /// 讀取 [playerId] 的已擷取憑證 body（整份 JSON 字串）；不存在回 null。
  Future<String?> loadCapturedCredential(String playerId) async {
    final f = _credFile(playerId);
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  /// 將攔到的憑證 [bodyJson]（整份 body）寫入 [playerId] 的憑證檔。
  Future<void> saveCapturedCredential(String playerId, String bodyJson) async {
    await _atomicWrite(_credFile(playerId), bodyJson);
    _log.fine('saved captured credential for playerId=${sanitizeUid(playerId)}');
  }

  /// 刪除 [playerId] 的憑證檔（若存在）。
  Future<void> deleteCapturedCredential(String playerId) async {
    final f = _credFile(playerId);
    if (await f.exists()) {
      await f.delete();
      _log.fine('deleted captured credential for playerId=${sanitizeUid(playerId)}');
    }
  }

  /// 刪除 [playerId] 的所有本地資料（記錄檔 + 憑證檔）。
  Future<void> delete(String playerId) async {
    final f = _recordsFile(playerId);
    if (await f.exists()) await f.delete();
    await deleteCapturedCredential(playerId);
    _log.info('delete playerId=${sanitizeUid(playerId)}');
  }

  /// 清除 [baseDir] 內所有 `.json` 檔案。
  Future<void> clearAll() async {
    if (!await baseDir.exists()) return;
    final entries = await baseDir.list().toList();
    for (final e in entries) {
      if (e is File && e.path.endsWith('.json')) {
        await e.delete();
      }
    }
    _log.info('clear all gacha data');
  }

  /// 先寫入 `.tmp` 再 rename，確保寫入的原子性。
  Future<void> _atomicWrite(File target, String content) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content);
    await tmp.rename(target.path); // atomic on same volume
  }
}
```

- [ ] 跑驗證通過：`flutter test test/services/gacha_storage_test.dart` → 預期 `All tests passed!`。
  - 註：`lib/state/gacha_repository.dart` 第 222 行 `loadCapturedUrl`、第 401 行 `saveCapturedUrl` 此時會紅燈（方法已改名），屬後續抓取串接 plan（plan04，orchestrator 重寫）範圍，本 Task 不處理。
- [ ] `dart format lib/services/gacha_storage.dart test/services/gacha_storage_test.dart`。
- [ ] commit：`feat(data): switch GachaStorage to explicit-suffix filenames and credential files`

---

## Task 8：資料層整體自我驗收

確認本 plan 範圍內所有新增/重寫檔的單元測試一次跑綠（不含尚待後續 plan 修的下游紅燈）。

**Files:**
- 無新增檔；僅執行驗收指令。

- [ ] `dart format lib/ test/` → 預期無格式變更殘留（或自動格式化後乾淨）。
- [ ] 跑本 plan 範圍測試集合（一次）：
  - 指令：`flutter test test/services/gacha_credential_test.dart test/models/gacha_record_test.dart test/services/record_merge_test.dart test/models/banner_storage_test.dart test/models/accounts_bundle_test.dart test/services/log_sanitize_test.dart test/services/gacha_storage_test.dart`
  - 預期：`All tests passed!`
- [ ] 執行 `flutter analyze`，**僅檢視本 plan 觸及的 7 個 lib 檔**（`gacha_credential.dart`、`gacha_record.dart`、`record_merge.dart`、`banner_storage.dart`、`accounts_bundle.dart`、`log_sanitize.dart`、`gacha_storage.dart`）無自身錯誤；其餘下游檔（`gacha_fetcher.dart`、`gacha_repository.dart`、各 stats）允許紅燈，留待後續 plan。
  - 驗證方式：analyze 輸出中本 7 檔不得出現 error（warning/info 視 lint 而定，需為 0 error）。
- [ ] commit（若前述任一步有格式化變更）：`style(data): apply dart format to data layer`
- [ ] 不執行 `git push`。

---

## 完成定義（本 plan）

- [ ] `lib/services/gacha_credential.dart` 存在且 `gacha_credential_test.dart` 全綠（含 `toJsonString()` 與 `fromCapturedBody` 往返）；舊 `gacha_url.dart` / `gacha_url_test.dart` 已刪除。
- [ ] `lib/models/gacha_record.dart` 為鳴潮 schema（`resourceId`/`qualityLevel`/`resourceType`/`cardPoolType`/`name`/`count`/`time`），共用 `parseGachaTime`/`formatGachaTime` 已抽出，`gacha_record_test.dart` 全綠。
- [ ] `lib/services/record_merge.dart` 提供 `mergeOrderedRecords` + `recordsEqual`，涵蓋同十連重複、新期首筆＝舊頂端、existing 中切、空集、anchor 找不到取代等 fixture，全綠。
- [ ] `lib/models/banner_storage.dart` 為帳號級（`playerId` + `languageCode` + 8 個 cardPoolType key），`banner_storage_test.dart` 全綠。
- [ ] `lib/models/accounts_bundle.dart` `currentSchemaVersion=2`、`fromJson` `version != 2` 友善拒絕、`seen` 改 `playerId`，`accounts_bundle_test.dart` 全綠。
- [ ] `lib/services/gacha_storage.dart` 採 `<playerId>.records.json`/`<playerId>.cred.json`、`save/loadCapturedCredential`、副檔名白名單 `listKnownUids`、`load` 遇舊格式跳過 + warning，`gacha_storage_test.dart` 全綠。
- [ ] `lib/services/log_sanitize.dart` 新增 `sanitizeCredential`，`log_sanitize_test.dart` 全綠。
- [ ] 全庫 `flutter analyze` 全綠**不在本 plan 驗收範圍**（下游型別替換跨多個 plan，至系列末端才全綠）。

---

**附註：跨 plan 介面契約對齊確認（本 plan 已遵守）**
- `GachaCredential{playerId,cardPoolId,serverId,recordId,languageCode}` + `fromCapturedBody(String)` + `toRequestBody(int)` + `toJsonString()`（與 `fromCapturedBody` 往返；plan04/gacha_storage 存檔用 `cred.toJsonString()`、讀檔用 `GachaCredential.fromCapturedBody(jsonString)`）✓
- `GachaRecord{resourceId,qualityLevel,resourceType,cardPoolType,name,count,time}` + `fromApiJson(Map,{required String cardPoolType})` + storage keys `resource_id/quality_level/resource_type/card_pool_type/name/count/time` + `parseGachaTime`/`formatGachaTime` ✓
- `BannerStorage{playerId,languageCode,lastUpdated,banners}`，banners key = cardPoolType 字串 `'1','2','3','4','5','6','8','9'` ✓
- `mergeOrderedRecords(List<GachaRecord> fresh, List<GachaRecord> existing)` + `recordsEqual`（比 time,resourceId,qualityLevel,name,count）✓
- `sanitizeCredential(String bodyJson)` ✓
- import 前綴一律 `package:wuthering_waves_convene_gacha_analyzer/`（假設 plan01-Package 改名先行）✓

**未涉入本 plan（屬其他 plan，本 plan 不動）**：`gacha_types.dart`（GachaType/PityRule/8 卡池，plan05）、`gacha_fetcher.dart`（`GachaApiException`、POST 重寫，plan04）、`gacha_repository.dart`（orchestrator，plan04）、`item_image_*` 服務（plan06）、`item_type_kind.dart` 的 `kItemKindItem`（plan05）、ARB、Rust crate。本 plan 完成後 `gacha_repository.dart`（`loadCapturedUrl`/`saveCapturedUrl` 改名）與 `gacha_fetcher.dart`（import 已刪的 `gacha_url.dart`）會短暫紅燈，由抓取串接 plan（plan04）修正。

---

**本 plan 涉及的真實檔案路徑（已 Read 確認現況）**
- `E:\IdeaProjects\wuthering-waves-convene-gacha-analyzer\lib\models\gacha_record.dart`（現 1–111 行，含 `id`/`uid`/`lang`/`copyWith`，待重寫）
- `E:\IdeaProjects\wuthering-waves-convene-gacha-analyzer\lib\models\banner_storage.dart`（現 1–63 行，`uid` 語意）
- `E:\IdeaProjects\wuthering-waves-convene-gacha-analyzer\lib\models\accounts_bundle.dart`（`currentSchemaVersion` 第 41 行、`fromJson` 第 68–127 行、`seen` 第 85/97 行）
- `E:\IdeaProjects\wuthering-waves-convene-gacha-analyzer\lib\services\gacha_storage.dart`（現 1–129 行，`_uidPattern` 第 17 行、`loadCapturedUrl`/`saveCapturedUrl` 第 76/84 行）
- `E:\IdeaProjects\wuthering-waves-convene-gacha-analyzer\lib\services\log_sanitize.dart`（現 1–61 行，無 import，於檔尾新增 `sanitizeCredential`）
- `E:\IdeaProjects\wuthering-waves-convene-gacha-analyzer\lib\services\gacha_url.dart`（待刪）
- 新增：`lib\services\gacha_credential.dart`、`lib\services\record_merge.dart`
- 測試：`test\services\gacha_credential_test.dart`（新）、`test\models\gacha_record_test.dart`（重寫，現 1–216 行）、`test\services\record_merge_test.dart`（新）、`test\models\banner_storage_test.dart`（新）、`test\models\accounts_bundle_test.dart`（重寫，現 1–135 行）、`test\services\log_sanitize_test.dart`（新增 group）、`test\services\gacha_storage_test.dart`（重寫，現 1–124 行）、刪 `test\services\gacha_url_test.dart`