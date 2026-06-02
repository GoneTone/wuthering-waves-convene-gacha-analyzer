# 第一個卡池失敗即早退重攔 — 設計文件

- 日期：2026-06-05
- 範圍：`lib/state/gacha_repository.dart`、`test/state/gacha_repository_update_test.dart`
- 相關既有 spec：[`2026-06-03-convene-fetch-failure-flow-design.md`](./2026-06-03-convene-fetch-failure-flow-design.md)（本文修訂其中一條判據，務必對照）

## 一、背景與需求

更新喚取資料時，`_fetchAllBanners` 會對 8 個卡池逐一呼叫 API，每池間隔 `rateLimit`（約 600ms）。喚取查詢用的 `recordId` 為 **8 池共用的同一個 token**，過期時 8 池會一起回 `code != 0`。

目前的失敗判定建立在「**跑滿全部 8 池**之後，再比較失敗池數是否等於全部池數」：

- 失敗池數 `<` 全部 → 部分失敗 → 保留舊資料＋紅字，存檔。
- 失敗池數 `==` 全部 → 丟 `_AllPoolsFailedException` → `_runUpdate` 自動重攔一次。

痛點：當 `recordId` 過期（必然 8 池全失敗）時，程式仍會傻傻把 8 池都試完（約 4 秒以上的 rate-limit 間隔＋逐池逾時）才決定重攔，使用者得乾等一段注定全敗的抓取進度。

**需求**：第一個抓取的卡池（`gachaTypes[0]` = `cardPoolType 1` = 角色活動，下稱 **pool 0**）一失敗就立刻重新攔截 URL，不再續抓其餘 7 池；重攔成功後再完整抓一輪，這一輪「**全部**」又失敗時才算真的失敗。

**選定語意（使用者已確認）**：以 **pool 0** 作為「`recordId` 是否有效」的探針。

- pool 0 **失敗** → `recordId` 疑似失效 → 立刻早退重攔。
- pool 0 **成功** → 證明 `recordId` 有效（8 池共用同一 token，pool 0 過得了代表認證通過）→ 照常抓滿 8 池，後續卡池若個別失敗，維持現有「保留舊資料＋紅字」處理，**不重攔**。

## 二、與既有失敗流程 spec 的關係（沿用 vs 修訂）

[`2026-06-03`](./2026-06-03-convene-fetch-failure-flow-design.md) 的核心 invariant 是：**不可把多條失敗分流塌成「一律彈失敗框」一條**。本文的早退必須落在既有的「**全池失敗 → 重攔**」那條分流上（不彈失敗框、走 `WaitingForCapture(isFallback: true)`），**絕不可**退化成「pool 0 一失敗就 `UpdateFailed`」。

| 既有條款 | 處置 | 說明 |
|---|---|---|
| 結構性判據「跑滿全池後比失敗池數」 | **修訂** | pool 0 失敗時短路，不再跑完全池。理由：`recordId` 8 池共用，pool 0 已足以代表全域健康度（見一、選定語意）。此修訂**僅作用於第一輪的 pool 0**。 |
| 部分失敗「不 rethrow、繼續跑其他池」 | **沿用（pool 0 除外）** | pool 1–7 失敗仍走原邏輯（記 `failed`、continue）。只有「第一輪 pool 0」早退。第二輪完全不早退。 |
| 全池失敗 → 自動重攔、不彈失敗框 | **沿用並強化** | 早退複用同一個 `_AllPoolsFailedException` 與 `_runUpdate` 既有 catch，走同一條重攔路徑。 |
| fallback 提示用小灰字、紅字留給部分失敗 | **沿用** | 早退走 `WaitingForCapture(isFallback: true)`，UI 文案不變，不改用紅字。 |
| 進入 fallback 時不刪快取憑證 | **沿用** | 早退重攔同樣不刪 cred。 |
| `_NoRecordsException` 需 `failed` 為空 | **沿用** | 早退路徑在 pool 0 失敗時根本不會走到收尾的 NoRecords 判定，不受影響。 |
| 部分失敗測試需「跑滿 8 池（`poolHits == 8`）」 | **沿用** | 該驗收針對「pool 0 成功、後段池失敗」案例，本文不更動其行為（見八）。 |

## 三、目標設計（方案）

**唯一更動的實作檔**：`lib/state/gacha_repository.dart`。`_runUpdate` 的 catch／重攔／第二輪呼叫骨架**不動**，只在 `_fetchAllBanners` 加一個旗標、在迴圈 catch 加一個早退分支，並修正會「說謊」的 log 與 dartdoc。

### 3.1 `_fetchAllBanners` 簽名加旗標

```dart
Future<void> _fetchAllBanners({
  required GachaCredential cred,
  required GachaFetcher fetcher,
  required GachaStorage storage,
  required http.Client client,
  required bool abortOnFirstPoolFailure, // 新增
}) async { ... }
```

採 `required`（而非預設值）：`_fetchAllBanners` 為 private、僅 2 個呼叫點，`required` 可強迫未來新增呼叫點時明確決定語意，避免漏傳而靜默退回某個預設行為。

### 3.2 迴圈 catch 加早退分支（只對第一輪的 pool 0）

```dart
} on GachaApiException catch (e) {
  if (abortOnFirstPoolFailure && i == 0) {
    // 第一輪：首抓的角色活動（pool 0）失敗 ≈ 8 池共用的 recordId 失效。
    // 不續抓其餘 7 池，直接丟全池失效訊號交由 _runUpdate 自動重攔。
    _log.warning(
      'first pool ${t.key} failed code=${e.code} msg=${e.message}, '
      'aborting to recapture',
    );
    throw _AllPoolsFailedException(e);
  }
  _log.warning('pool ${t.key} failed code=${e.code} msg=${e.message}');
  lastApiError = e;
  mergedBanners[t.key] = existing.banners[t.key] ?? const <GachaRecord>[];
  failed.add(t.nameKey);
}
```

### 3.3 兩個呼叫點各傳旗標

- 第一輪（`_runUpdate` 內，現約 264 行）：`abortOnFirstPoolFailure: true`
- 重攔後第二輪（`_AllPoolsFailedException` catch 內，現約 284 行）：`abortOnFirstPoolFailure: false`

### 3.4 修正會「說謊」的 log 與文件（對抗式審查發現）

早退複用 `_AllPoolsFailedException` 後，多處寫死「8 池全部失敗」的訊息／註解在「只有 pool 0 失敗」時會誤導，必須一併修正：

1. **第一輪 catch 的 log**（現約 273 行）：改寫前為 `'all pools failed (code=...)...'`。改動後第一輪的 `_AllPoolsFailedException` **必然**來自 pool 0 早退（pool 0 成功就不會早退，而 pool 0 成功時收尾的 `failed.length == 8` 不可能成立），故改寫為不再宣稱「all」，例如：
   ```dart
   _log.warning(
     'first pool failed (code=${e.apiError.code}), falling back to recapture',
   );
   ```
   第二輪 catch 的 log（現約 290 行 `'still all-failing after recapture'`）語意仍正確，**不動**。
2. **`_AllPoolsFailedException` 的 dartdoc**（現約 36–37 行）：補上兩個觸發來源 — ①第一輪 pool 0 早退 ②第二輪 8 池全失敗。
3. **`apiError` 欄位 dartdoc**（現約 42 行）：由「最後一個失敗池」改為「觸發訊號的失敗池（早退時為 pool 0，全失敗時為最後一個失敗池）」。
4. **`_fetchAllBanners` dartdoc**（現約 367–372 行）：說明 `abortOnFirstPoolFailure` 參數語意。
5. **迴圈 catch 的段落註解**（現約 430–432 行）：補上早退分支。

> 不新增 `_AllPoolsFailedException` 的布林欄位來區分早退／全失敗：第一輪 catch 已恆為早退、第二輪 catch 已恆為全失敗，靠呼叫點即可區分，加欄位屬多餘（YAGNI）。

## 四、各情境行為對照

| 情境 | 改動前 | 改動後 |
|---|---|---|
| `recordId` 過期（8 池都會敗） | 跑滿 8 池（約 4s＋）才重攔 | **pool 0 一敗就立刻重攔** ✅ |
| pool 0 成功、某後段池暫時失敗 | 保留舊資料＋紅字，不重攔 | **完全不變**（保留舊資料＋紅字，不重攔） |
| 重攔後第二輪 8 池又全敗 | `UpdateFailed`（真失敗） | **完全不變** |
| 重攔後第二輪部分失敗 | 存檔＋紅字 | **完全不變** |
| 重攔時使用者取消 | 清除進度、不彈錯誤 | **完全不變** |
| 全空無紀錄（8 池 `code==0` 且全空） | `UpdateErrorNoRecords` | **完全不變** |

第二輪（`abortOnFirstPoolFailure: false`）的**邏輯路徑與現況逐字相同**；唯一新增的只有第一輪 pool 0 失敗的早退。UI 不需新狀態，沿用現有 `FetchingBanner → WaitingForCapture(isFallback: true)` 轉場（pool 0 失敗瞬間進度短暫停在「1/8 角色活動」即跳「等待重新擷取」，非 bug）。

## 五、已知取捨與假設

1. **pool 0 代表性假設**：本設計把「`recordId` 是否有效」整個押在 pool 0 上。前提是 8 池共用同一 `recordId`、認證為全有或全無。極端後端 bug（pool 0 回 `code!=0` 但其他池正常）下會誤判，機率極低。
2. **暫時性失敗 → 當次新資料及時性退化**：`code != 0` 不保證真為過期，也可能是後端暫時異常。若 pool 0 偶發暫時性失敗（`recordId` 其實有效）：
   - 舊行為：pool 0 記入 `failed`、pool 1–7 正常抓並**存檔**，`UpdateCompleted` 帶 1 個紅字。
   - 新行為：pool 0 早退 → 重攔。若使用者在重攔對話框**按下取消** → `clearProgress` → 這次 update 不存任何東西，本可拿到的 7 池新紀錄當次落空（**舊存檔仍在、不永久遺失**，下次成功 update 即補回）。

   此為使用者已確認之取捨：以「`recordId` 過期時省去全 8 池乾等」換取「pool 0 罕見暫時性失敗時，當次更新可能整輪重來」。

## 六、逐檔改動清單

### `lib/state/gacha_repository.dart`

- `_fetchAllBanners` 簽名加 `required bool abortOnFirstPoolFailure`（3.1）＋更新其 dartdoc（3.4-4）。
- 迴圈 `on GachaApiException catch (e)` 加早退分支（3.2）＋更新段落註解（3.4-5）。
- 第一輪呼叫傳 `true`、第二輪呼叫傳 `false`（3.3）。
- 第一輪 catch 的 log 改寫為不宣稱「all」（3.4-1）。
- `_AllPoolsFailedException` 與其 `apiError` 的 dartdoc 更新（3.4-2、3.4-3）。

### `test/state/gacha_repository_update_test.dart`

見七。

## 七、測試衝擊與計畫

測試 harness：fake capture class（`_FakeCapture implements GachaCapture`）＋ `http/testing` 的 `MockClient` ＋ Riverpod provider override，`GachaFetcher(rateLimit: Duration.zero)` 讓 8 池間無延遲。重攔分支需先 `saveCapturedCredential` ＋空 `BannerStorage` 才會走 cached cred（`captureCalls` 才會等於 1 = 僅 fallback 那次）。

### 7.1 必改（否則 `flutter test` 不綠）

- **`test('all pools fail → recapture → success → UpdateCompleted')`（現約 172 行）**：mock 以 `hits <= 8` 代表「第一輪 = 8 池」。改動後第一輪只打 pool 0（1 次）即早退，門檻需改為 `hits <= 1`：第一次請求（pool 0）失敗觸發早退重攔，第二次起（重攔後完整 8 池）全部成功。建議補 `expect(hits, 9)`（1 次早退＋8 次第二輪）鎖住新行為。

### 7.2 不需改但請求數改變

- `test('all pools fail → recapture → still all fail → UpdateFailed')`（現約 243 行）、`test('all pools fail → recapture cancelled → clears progress')`（現約 300 行）：mock 無條件回 `_fail`，不依賴 hit 數，斷言仍成立。實際 HTTP 請求數由 16 降為 9（或更少）。**不動。**

### 7.3 不受影響（pool 0 成功，第一輪不早退）

- happy path（8 池全成功，現約 77 行）、**partial failure（pool 0 成功、type 2 失敗，現約 112 行）**、all-empty NoRecords（現約 345 行）、cached credential reused（現約 370 行）、forceRecapture cancelled（現約 427 行）。其中 partial failure 一案正是「pool 0 成功 → 不重攔、跑滿 8 池」的既有守門，**必須維持綠燈**。

### 7.4 新增測試（覆蓋早退新行為）

- **C1 — pool 0 失敗 → 第一輪只抓 1 次即觸發重攔**（最核心、現無覆蓋）：mock 讓 `hits == 1`（pool 0）回 `_fail`、其後全成功；斷言只記錄到第一輪請求型別為 `[1]`、`captureCalls == 1`、`hits == 9`、`UpdateCompleted` 且 `totalNewRecords == 1`、`failedBanners` 為空。
- **C3 — 重攔後第二輪 pool 0 又失敗但他池成功 → 存檔、不再重攔**（驗證第二輪 `abortOnFirstPoolFailure: false`，pool 0 失敗只記 `failed` 不早退、不會無限重攔）：第一輪 pool 0 失敗早退；第二輪 pool 0 仍失敗、type 2 給一筆、其餘空；斷言 `captureCalls == 1`、`UpdateCompleted` 且 `failedBanners` 長度 1、`totalNewRecords == 1`。
- C4（重攔後第二輪全失敗 → `UpdateFailed`）已由 7.2 的現有測試覆蓋，**不另新增**。
- C2（pool 0 成功、後段池失敗 → 不重攔）語意已由 7.3 的 partial-failure（現約 112 行）覆蓋，**不另新增**（YAGNI）。

## 八、驗收條件

1. `dart format lib/ test/` 無變更殘留。
2. `flutter analyze` → `No issues found!`。
3. `flutter test` → `All tests passed!`（含 7.1 必改與 7.4 新增）。
4. 行為驗收（由測試覆蓋）：
   - pool 0 失敗時，第一輪僅對 pool 0 發 1 次請求即進入 `WaitingForCapture(isFallback: true)`。
   - pool 0 成功時，照常抓滿 8 池；後段池失敗走部分失敗存檔＋紅字、不重攔。
   - 重攔後第二輪：全失敗 → `UpdateFailed`；部分失敗 → 存檔＋紅字；皆不再觸發第三輪。
   - log 可區分「pool 0 早退」與「第二輪全失敗」兩種情形。

## 九、非目標（YAGNI）

- 不區分 `code != 0` 的細分錯誤型別（沿用既有「無法乾淨區分」的前提）。
- 不泛化成「可重攔 N 次」的迴圈（目前固定就是攔→抓→全敗才再攔一次）。
- 不為早退新增 UI 狀態或文案、不動 `update_progress.dart` 與 dialog。
- 不為 `_AllPoolsFailedException` 新增區分早退／全失敗的欄位（靠呼叫點即可區分）。
