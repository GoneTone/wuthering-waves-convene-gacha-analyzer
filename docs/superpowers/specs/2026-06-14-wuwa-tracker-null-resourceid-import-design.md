# WuWa Tracker 匯入：`resourceId` 為 null 的紀錄不再整檔失敗

- 日期：2026-06-14
- 狀態：設計待審
- 範圍：`lib/services/importers/wuwa_tracker_importer.dart`、`lib/models/gacha_record.dart`（合成 id 工具）、`lib/services/item_image_fetcher.dart`（`EncoreCatalog` 擴充）、`lib/services/platform_import.dart`（介面）、`lib/pages/settings_page.dart`（匯入接線）、`lib/services/record_merge.dart`（跨來源去重防護）、對應測試

## 問題

使用者匯入 WuWa Tracker（wuwatracker.com）的 `wuwatracker-pulls` 匯出檔時整檔無法匯入。軟體 log：

```
[wish.import.platform] wuwa_tracker import: parse error
  error: type 'Null' is not a subtype of type 'num' in type cast
  #0  WuwaTrackerImporter.parse (...wuwa_tracker_importer.dart:90)
```

## 根因

`wuwa_tracker_importer.dart:90` 對 `entry['resourceId']` 做無防護轉型：

```dart
final resourceId = (entry['resourceId'] as num).toInt();
```

但 WuWa Tracker 早期版本紀錄的 `resourceId` 為 `null`（當時只存 `name`），轉型丟例外、被外層 catch 包成 `FormatException`，導致**整份檔解析中止、完全無法匯入**。

## 資料盤點（使用者提供的實檔，9606 筆）

- `resourceId == null`：**2154 筆（約 22%）**，皆為 2024 早期歷史（`time` 用 `Z` 後綴，非新紀錄的 `+00:00`，但 `DateTime.parse` 兩者皆正常，非崩潰主因）。
- 其餘欄位（`name`／`qualityLevel`／`cardPoolType`／`time`）在 null 紀錄上**皆齊全**，唯獨缺 `resourceId`。
- 同檔內較新紀錄同時帶 `name` 與 `resourceId`，且 **name→resourceId 為完美 1:1（0 衝突）**。以同檔 name→id 回填可解 **2131 筆（98.9%）**。
- 殘餘 **23 筆無法以同檔回填，全是限定五星角色**（Camellya、Changli、Jinhsi、Shorekeeper、Yinlin、Zhezhi）——使用者 2024 抽到後未再抽，同檔無帶 id 的同名紀錄。這幾筆是最不該遺失的五星（影響五星總數與保底重置點）。

## 設計：三層 name→id 解析 + 防護式讀取

核心原則：**讓缺 id 的紀錄盡量取得真實 `resourceId`**（下游 icon／encore 分類／五星合併皆以 `resourceId` 為鍵），取不到時也**零資料遺失**。解析由「廉價可靠」到「需網路」分三層。

### 第 0 層：修崩潰（防護式讀取）

`entry['resourceId']` 改為先判型再取值：非 `num` 時不轉型、進入解析流程，而不是整檔中止。`qualityLevel`／`name`／`cardPoolType` 維持現狀（實檔皆齊全；若未來缺漏由既有 `FormatException` 分支處理）。

### 第 1 層：同檔 name→id 回填（純同步、離線、精準）

`parse()` 改為兩階段：

1. 先掃一遍 `pulls`，由**所有 `resourceId` 非 null 的紀錄**建 `Map<String, int> inFileNameToId`（name→真實 id）。
2. 再掃一遍建立 `GachaRecord`；遇 `resourceId == null` 時優先以 `inFileNameToId[name]` 回填。

回填後 `resourceType` 沿用現行位數推測（≤4 碼角色、否則武器）——下游 `_fetchItemImages` 仍會以真實 id 向 encore 重新分類校正，本欄位僅為 fallback，維持既有行為。

### 第 2 層：encore 清單 name→(id, kind)（網路）

同檔解不掉的殘餘，改查 encore 角色／武器／道具清單。已驗證 encore 清單每個 item 帶 `"Id"` 與 `"Name"`（如 `{"Id":1503,"Name":"Verina",...}`）。

**`EncoreCatalog` 擴充**（`item_image_fetcher.dart`，additive、不影響既有 `_fetchItemImages`）：
- `_fetchCatalogKind` 既有迴圈已逐筆讀 `e['Id']`／`e[iconKey]`，順手再讀 `e['Name']`，建 `nameToId`。
- `EncoreCatalog` 新增欄位 `Map<String, ({int id, String kind})> idByName`（跨 kind union；同名以首個命中為準）。
- 新增便捷查詢 `({int id, String kind})? resolveByName(String name)`。

**接線（`settings_page.dart` 的 `_importFromPlatform`）**：在 `platform.parse(text)` 前，best-effort 抓一次 encore 清單（lang `en`，WuWa Tracker 名稱為英文；三 kind），建 name→(id,kind) 解析器後注入 `parse()`。抓取失敗（離線／非 2xx）→ 解析器為空 → 落第 3 層，**不影響匯入成功**。

**介面變更（`platform_import.dart`）**：

```dart
/// 以物品名稱解析回真實 resourceId 與 kind；查無回 null。供 importer 回填缺 id 紀錄。
typedef ItemNameResolver = ({int id, String kind})? Function(String name);

abstract interface class PlatformImporter {
  // ...
  /// [nameResolver]：缺 id 紀錄的名稱解析器（如 encore 清單），null＝不解析。
  AccountsBundle parse(String content, {ItemNameResolver? nameResolver});
}
```

`parse` 維持**純函式、不自己連網**（網路由呼叫端負責），既有單元測試以單參數呼叫仍相容（新參數 optional）。encore 解析命中時，`resourceType` 直接採其 `kind`（比位數推測更準）。

### 第 3 層：name 穩定合成 id（fallback，零資料遺失）

兩層都解不掉（離線匯入、或 encore 名稱對不上）時，**保留該筆**，給一個依 name 決定性產生的合成 id：

- 以決定性雜湊（FNV-1a 32-bit over UTF-8 name）映射到**負數空間**，確保：
  1. 不與 encore 真實 id（正整數）碰撞；
  2. 同名→同 id（跨次匯入、跨平台穩定——**不可用 Dart `String.hashCode`，其每次執行 seed 隨機**）；
  3. 不同名→不同 id（合併不誤併；殘餘規模數十筆，31-bit 空間碰撞機率可忽略）。
- 兩個純函式收斂於 `lib/models/gacha_record.dart`（模型層中立，讓 importer 與 `record_merge` 都只依賴模型，不互相依賴）：
  - `int syntheticResourceIdForName(String name)`：FNV-1a 32-bit over UTF-8，映射到負數空間 `-(hash & 0x7fffffff) - 1`（恆為負、永不為 0、不與真實正 id 碰撞）。
  - `bool isSyntheticResourceId(int id) => id < 0`：判定是否為合成 id（真實遊戲／encore id 皆正）。供去重防護辨識。
- 此類紀錄 `resourceType` 存空字串 `''`（下游 `itemTypeKeyLabel('')` 顯示「未知」）——誠實標示，不臆測角色／武器。合成負 id 不會命中 encore 清單，故 icon 落佔位圖（符合「離線無法取圖」的事實）。

### 解析優先序

每筆 `resourceId == null` 的紀錄：同檔回填 → encore 解析 → 合成 id。同檔 id 為該檔自身權威值，優先於 encore（兩者正常情況一致）。

## 跨來源去重防護（name 清理）

合成負 id 與真實正 id 不相等，故「同一筆古老紀錄在一次匯入取得合成 id、另一次取得真實 id」（情境：同檔先離線、後線上各匯一次）會被 `record_merge` 視為兩筆而重複。加一道 name 清理防護根治之。

- 在 `mergeBackupRecords`（匯入合併路徑）的最後一步、`_capMultiplicity` 之後，加 `_dropSupersededSynthetic(merged)`：
  - 以 `(time.microsecondsSinceEpoch, time.isUtc, qualityLevel, count, name)` 為 heal 鍵。
  - 收集所有**真實 id**（`!isSyntheticResourceId`）紀錄的 heal 鍵集合。
  - 移除「合成 id 且 heal 鍵命中該集合」的紀錄——真實 id 那份取代之。
- count 不漏：合成與真實源自**同一份實體抽卡**（同檔不同連線狀態），同 heal 鍵的數量本就相等，丟合成、留真實即等量取代。這是全流程**唯一一次刻意丟棄**，僅作用於「已有真實 id 雙胞」的合成筆，故安全。
- heal 鍵刻意比 `recordsEqual` 多帶 `name`、少帶 `resourceId`：跨「合成↔真實」配對需用 `name`（id 本就不同），而 `name` 僅用於此清理、不污染通用 `recordsEqual`（後者仍排除 `name` 以保跨語言對齊）。
- 只掛在 `mergeBackupRecords`（匯入）；`mergeOrderedRecords`（官方擷取更新）全為真實 id、不產生合成筆，無需處理。

## 已知限制

- **同檔離線↔線上各匯一次的重複**：由上節 name 清理防護根治（合成筆被真實 id 雙胞取代）。
- **與官方軟體內擷取（`mergeOrderedRecords`）的跨來源去重**：合成負 id 與官方擷取真實正 id 不相等。但這些殘餘為官方喚取歷史視窗外的早期紀錄，官方擷取通常抓不回，實務上無重疊、不重複；不另為此路徑加防護（YAGNI）。
- 第 2 層名稱比對為精確比對（必要時 `trim`）；encore 與 WuWa Tracker 皆採官方英文名，角色／武器命中率高，道具理論上可能有命名差異而落第 3 層。

## 記錄（log）

`parse()` 結束時於既有 `wish.import.platform` logger 記一行解析統計，便於使用者匯出 log 定位：

```
wuwa_tracker null-resourceId resolution: inFile=2131 encore=23 synthetic=0 (total null=2154)
```

encore 預抓失敗於 `_importFromPlatform` 記 warning（脫敏 URL）。沿用既有命名樹，敏感資料經 `sanitizeUrl`／`sanitizeUid`。

## 測試

**`test/services/importers/wuwa_tracker_importer_test.dart`（延伸）**

1. 同檔回填：fixture 含一筆 `resourceId:null` 且同檔另有同名帶 id 紀錄 → 回填為該真實 id。
2. encore 解析：注入假 `ItemNameResolver`（如 `{'Jinhsi': (id: 1304, kind: kItemKindCharacter)}`），null 紀錄名稱僅靠 resolver 命中 → 取真實 id 與 `resourceType == kind`。
3. 合成 fallback：不注入 resolver、且同檔無同名帶 id → 取負 id；同名兩筆解析兩次得**相同** id；不同名得**不同** id；`buildFiveStarCollection` 對兩個不同名五星正確分成兩格、同名合一格。
4. 回歸：既有 8 個測試（含「skips unknown pools」「CST +8」「stable order」）維持綠燈。

**`test/models/gacha_record_test.dart`（合成 id 工具）**

5. 決定性：`syntheticResourceIdForName('Camellya')` 兩次呼叫相等且為負；不同 name 不相等；`isSyntheticResourceId` 對其回 true、對正 id 回 false。

**`test/services/record_merge_test.dart`（去重防護）**

6. 同 `(time, quality, count, name)` 同時有合成負 id 與真實正 id → `mergeBackupRecords` 後只留真實那份（數量不漏、不重複）。
7. 合成筆無真實雙胞 → 原樣保留（防護不誤刪離線匯入的單純殘餘）。

## 範圍外（YAGNI）

- 不為 WuWa Tracker 以外平台預建解析器使用（介面新增 optional 參數即可，未來平台按需採用）。
- 不處理「WuWa Tracker 改用非英文 name」的假想變體（現行檔皆英文，`parse` 既已硬編 `languageCode:'en'`）。
- 不引入 encore 名稱模糊比對／別名表（正是先前刻意移除的脆弱猜測來源）；精確比對對不上者一律落第 3 層。
- 第 1 層既已離線解 98.9%，不為「只剩需 encore 的殘餘才抓清單」做額外最佳化（匯入為一次性動作，清單小，always 預抓較單純）。

## 次要修正

`wuwa_tracker_importer.dart:105-111` 的 dartdoc 宣稱「全檔 `+00:00` 後綴」，本實檔早期紀錄為 `Z` 後綴而否證之；行為仍正確（`Z` 亦為時區標示，`toUtc()` 等價）。一併更新該段註解，標明 `Z` 變體亦受支援。
