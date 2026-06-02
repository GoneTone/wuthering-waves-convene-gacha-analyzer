# 喚取資料更新失敗處理：還原原版三分流

- 日期：2026-06-03
- 範圍：`update()` /喚取資料更新流程的失敗處理（`gacha_repository.dart`、`update_progress.dart`、`update_progress_dialog.dart`、`lib/l10n/*.arb`）
- 類型：行為修正（還原 Genshin baseline 的失敗處理流程，套用鳴潮特有的判據）

## 一、背景與問題

從原神（Genshin）遷移到鳴潮（Wuthering Waves）時，喚取資料更新的失敗處理被改壞：**任一卡池回傳 `code != 0` 就立刻中止整次更新並彈出紅色「失敗」對話框**（「取得記錄失敗，請重開喚取記錄頁再試」）。

這把原版**三條不同的失敗分流塌成了一條**，與原神版的處理流程不一致——使用者反映「驗證過期之類的失敗應該和原版一樣的處理流程，而不是直接顯示失敗」。

本設計把三分流原樣接回去，並針對「鳴潮 `recordId` 為 8 池共用、`code != 0` 無法區分過期與其他錯誤」這個差異採用結構性判據（全掛 vs 部分掛）。

## 二、原版（Genshin baseline，commit `f3014e3`）的三分流（基準）

`_fetchAllBanners` 逐 banner 迴圈，搭配 `_runUpdate` 的外層 try/catch，依錯誤性質分三條：

1. **認證過期**（`gacha_fetcher` retcode `-100/-101` → `AuthExpiredException`）：迴圈內 `rethrow` →`_runUpdate` 接住後**不彈失敗框**，刪掉快取 URL、自動 `_runMitm(isFallback: true)`，畫面退回 `WaitingForCapture(isFallback: true)`（等待捕獲＋下方小字提示 `progressFallbackHint`），請玩家重開記錄頁。抓到新 URL → 重試一次 `_fetchAllBanners`。**只有重試仍過期**才顯示 `UpdateFailed(UpdateErrorAuthExpired)`；重攔被使用者取消 → 清 progress、不彈錯誤。
2. **單一 banner 的其他錯誤**（迴圈內 `catch (e)`，如 `ApiErrorException`）：**不中止**，該 banner 保留舊資料、記進 `failed` 清單後**繼續抓其他 banner**，最後照常 emit `UpdateCompleted`（標題仍是「完成」），只在**底部用紅字** `progressPartialFailed`（`tokens.stateDanger`）列出「部分失敗：X、Y」。
3. **網路／連線錯誤**（`http.ClientException`）：迴圈內 `rethrow` → `_runUpdate` 以 cancel-aware 方式處理 → 整體 `UpdateFailed`。

## 三、鳴潮版現況（被遷移改壞的地方）

- `_fetchAllBanners`：迴圈內**不 catch** `GachaApiException`，任一池失敗即往上拋；`UpdateCompleted` 永遠寫死 `failedBanners: const []`。
- `_runUpdate`：`on GachaApiException → 立刻 UpdateFailed(UpdateErrorGachaFailed)`，整個中止。
- `WaitingForCapture` 的 `isFallback` 欄位、`progressFallbackHint` 字串、自動重攔 fallback 整段**被移除**。
- 「部分失敗」紅字的 UI 其實**還留著**（`UpdateCompleted.failedBanners`、`progressPartialFailed`「⚠ 部分失敗：{names}」、dialog 紅字渲染），但因為 logic 被抽掉、`failedBanners` 永遠是空陣列，這套 UI 變成**永不觸發的死碼**。

換言之：UI 外殼還在，三分流的 logic 被掏空成「一律彈失敗框」。

## 四、目標設計

鳴潮 `recordId` 為 8 池**共用**，過期時 8 池會**一起** `code != 0`（不像原神過期是單一 retcode 可乾淨分流）。因此「過期(全域)」與「單池失敗(局部)」改用**結構性判據**區分：**`code != 0` 的池數是否等於全部池數**。

| 情境 | 判據 | 行為 | UI |
|---|---|---|---|
| **部分池失敗** | 失敗池數 `<` 全部池數（至少一池成功） | 失敗池保留舊資料、記進 `failed`，**繼續跑其他池**，存檔 | `UpdateCompleted`（標題「完成」）＋底部**紅字**「⚠ 部分失敗：{names}」 |
| **全池失敗**（≈ recordId 失效或後端整體異常） | 失敗池數 `==` 全部池數 | 拋內部訊號 `_AllPoolsFailedException` → `_runUpdate` **自動重攔一次** | `WaitingForCapture(isFallback: true)`：等待捕獲＋下方小字提示。**不彈失敗框** |
| └ 重攔後仍全掛 | 重試又全池失敗 | 才放棄 | `UpdateFailed(UpdateErrorGachaFailed)`：見「六、文案」新文案 |
| └ 重攔被取消 | 使用者按取消（`_runMitm` 回 null） | 靜默結束 | 清 progress，**不彈任何錯誤** |
| **網路／連線錯誤** | `http.ClientException` | 不在迴圈內 catch，往上拋 | 沿用現有 cancel-aware 處理 → `UpdateFailed`（`_friendlyError`） |
| **全空無紀錄** | 8 池全 `code == 0`、全空、且無既有資料、且 `failed` 為空 | 維持現狀 | `UpdateFailed(UpdateErrorNoRecords)` |

## 五、逐檔改動

### 5.1 `lib/state/gacha_repository.dart`

新增 private 訊號例外（攜帶最後一個 `GachaApiException` 供 log 與最終文案）：

```dart
/// 8 個卡池**全部** `code != 0`（≈ recordId 失效或後端整體異常）→ 由 [_runUpdate]
/// 接住後自動重攔一次；重攔後仍全掛才轉成 [UpdateErrorGachaFailed]。
class _AllPoolsFailedException implements Exception {
  const _AllPoolsFailedException(this.apiError);
  final GachaApiException apiError;
}
```

`_fetchAllBanners` 迴圈與收尾改為（節錄關鍵邏輯）：

```dart
final failed = <String>[];        // 失敗池的 nameKey
GachaApiException? lastApiError;
// ...逐池迴圈...
  try {
    final result = await fetcher.fetchPool(...);
    // ...merge、累計 totalNew、anyNonEmpty...
  } on GachaApiException catch (e) {
    _log.warning('pool ${t.key} failed code=${e.code} msg=${e.message}');
    lastApiError = e;
    mergedBanners[t.key] = existing.banners[t.key] ?? const [];   // 保留舊資料
    failed.add(t.nameKey);
    // 不 rethrow，繼續下一池
  }
  // http.ClientException 不在此 catch → 往上拋給 _runUpdate（網路層失敗）
// 迴圈結束後：
if (failed.length == gachaTypes.length) {
  throw _AllPoolsFailedException(lastApiError!);            // 全掛 → 觸發重攔
}
if (failed.isEmpty &&
    !anyNonEmpty &&
    existing.banners.values.every((l) => l.isEmpty)) {
  throw const _NoRecordsException();                        // 真的沒紀錄
}
// ...存檔、補圖、emit UpdateCompleted(failedBanners: failed)...
```

注意：

- `UpdateCompleted` 的 `failedBanners` 由寫死的 `const []` 改為實際的 `failed`（接回既有 UI，不新增元件）。
- `_NoRecordsException` 條件收緊，加上 **`failed` 為空**——只要有任何池失敗就不能斷定「無紀錄」，應走存檔＋部分失敗。

`_runUpdate` 把現在的 `on GachaApiException → 立刻 UpdateFailed` 換成 `on _AllPoolsFailedException → 巢狀重攔`（結構比照 baseline）：

```dart
try {
  await _fetchAllBanners(cred: cred, ...);
} on _AllPoolsFailedException catch (e) {
  if (!ref.mounted) return;
  _log.warning('all pools failed (code=${e.apiError.code}), falling back to recapture');
  final newCred = await _runMitm(isFallback: true);
  if (!ref.mounted) return;
  if (newCred == null) {
    _log.info('recapture cancelled by user');
    state = state.copyWith(clearProgress: true);            // 取消 → 不彈錯誤
    return;
  }
  try {
    await _fetchAllBanners(cred: newCred, ...);
  } on _AllPoolsFailedException catch (e2) {
    if (!ref.mounted) return;
    _log.warning('still all-failing after recapture, code=${e2.apiError.code}');
    state = state.copyWith(
      progress: UpdateFailed(
        UpdateErrorGachaFailed(e2.apiError.code, e2.apiError.message),
      ),
    );
  } on _NoRecordsException {
    if (!ref.mounted) return;
    state = state.copyWith(progress: const UpdateFailed(UpdateErrorNoRecords()));
  } on http.ClientException catch (e2) {
    if (!ref.mounted) return;
    if (_cancelTriggered) {
      state = state.copyWith(clearProgress: true);
    } else {
      _log.warning('http client error (post-recapture): ${e2.message}');
      state = state.copyWith(progress: UpdateFailed(_friendlyError(e2)));
    }
  } catch (e2, st) {
    if (!ref.mounted) return;
    _log.severe('update unexpected error (post-recapture)', e2, st);
    state = state.copyWith(progress: UpdateFailed(_friendlyError(e2)));
  }
} on _NoRecordsException {
  if (!ref.mounted) return;
  state = state.copyWith(progress: const UpdateFailed(UpdateErrorNoRecords()));
} on http.ClientException catch (e) {
  // ...沿用現有 cancel-aware 處理...
} catch (e, st) {
  // ...沿用現有 unexpected 處理...
}
```

`_runMitm` 還原 `isFallback` 參數，primary 呼叫帶 `isFallback: false`：

```dart
Future<GachaCredential?> _runMitm({required bool isFallback}) async {
  state = state.copyWith(progress: WaitingForCapture(isFallback: isFallback));
  // ...其餘不變...
}
// primary 呼叫：cred ??= await _runMitm(isFallback: false);
```

### 5.2 `lib/state/update_progress.dart`

`WaitingForCapture` 還原 `isFallback` 欄位：

```dart
class WaitingForCapture extends UpdateProgress {
  const WaitingForCapture({this.isFallback = false});
  /// true 表示 recordId 全池失效後的二次（fallback）捕獲。
  final bool isFallback;
}
```

### 5.3 `lib/widgets/update_progress_dialog.dart`

`WaitingForCapture` 的 `_Body` 還原 fallback 小字提示（partial 紅字渲染已存在、免動）：

```dart
WaitingForCapture(:final isFallback) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    const LinearProgressIndicator(),
    const SizedBox(height: AppSpacing.l),
    Text(l.progressOpenGameHint),
    if (isFallback) ...[
      const SizedBox(height: AppSpacing.s),
      Text(l.progressFallbackHint, style: theme.textTheme.bodySmall),
    ],
  ],
),
```

`_actions` / `_Title` 內的 `WaitingForCapture()` pattern 無需改（不解構欄位即可匹配）。

## 六、文案（`lib/l10n/app_zh.arb`、`app_zh_Hans.arb`、`app_en.arb`、`app_ja.arb`）

### 6.1 新增 `progressFallbackHint`（含 `@` metadata）

全池失敗後自動重攔時，於等待捕獲畫面下方顯示的小字提示：

- zh-Hant：`（先前的擷取已失效，請重新開啟喚取記錄頁攔取）`
- zh-Hans：`（先前的拦截已失效，请重新开启唤取记录页拦取）`
- en：`(The previous capture expired. Please reopen the Convene History page.)`
- ja：`（前回の取得が失効しました。集音履歴ページを開き直してください）`

### 6.2 改寫 `errorGachaFailed`

此字串在新流程**只**在「自動重攔之後仍全池失敗」時顯示。舊文案「請重開喚取記錄頁再試」與流程矛盾（使用者剛因自動重攔而重開過記錄頁），會誤導，故改寫為「已重試但仍失敗、多半是伺服器暫時異常」語意，不再要求重開頁：

- zh-Hant：`重新擷取後仍無法取得記錄，伺服器可能暫時異常，請稍後再試`
- zh-Hans：`重新拦取后仍无法获取记录，服务器可能暂时异常，请稍后再试`
- en：`Still couldn't fetch records after re-capturing. The server may be temporarily unavailable — please try again later.`
- ja：`再取得しても記録を取得できませんでした。サーバーが一時的に不安定な可能性があります。しばらくしてから再試行してください。`

`progressPartialFailed`「⚠ 部分失敗：{names}」**維持不變**——它只列出失敗的卡池、不要求重開頁，無誤導問題。

## 七、測試（`test/state/gacha_repository_update_test.dart`）

- **改寫**現有 `any pool code!=0 aborts with UpdateErrorGachaFailed (no recapture)`（它驗收的是舊行為）→ 改為「**部分池失敗**」：某些池成功、某些池 `code != 0` → 跑滿全部池（`poolHits == 8`）→ `UpdateCompleted` 且 `failedBanners` 非空、成功池資料已存檔、capture 只 1 次（無重攔）。
- **新增**「全掛 → 重攔 → 成功」：stateful MockClient（前 8 個 hit 全 `_fail`、之後 `_ok`）＋既有快取 cred → 第一輪全掛觸發 fallback `_runMitm(isFallback: true)`（capture 1 次）→ 第二輪成功 → `UpdateCompleted`。
- **新增**「全掛 → 重攔 → 仍全掛」：MockClient 永遠 `_fail` → 第二輪仍全掛 → `UpdateFailed(UpdateErrorGachaFailed)`（code = -1）。
- **新增**「全掛 → 重攔取消」：既有快取 cred、MockClient 全 `_fail`、fallback 的 `_FakeCapture(null)` → 清 progress、無 `UpdateFailed`、既有快取 cred 仍保留（見微決策 1）。
- 既有 happy path、`all 8 pools empty → NoRecords`、`cached credential reused`、`forceRecapture cancelled` 等測試應維持綠燈（必要時微調）。

## 八、微決策與理由

1. **進入 fallback 時不刪除快取憑證**（原版 `deleteCapturedUrl` 有刪）。理由：鳴潮 `code != 0` 無法確定真為過期（可能是後端暫時異常），保留 cred 讓後端恢復後下次「更新」能直接重用；成功重攔時 `_fetchAllBanners` 本來就會以新 cred 覆寫。
2. **fallback 提示維持小灰字**（原版即 `bodySmall`，非紅字）；真正的紅字保留給「部分失敗」那條，語意層級清楚。
3. **重攔後仍失敗沿用 `UpdateErrorGachaFailed` 型別**（不新增 `UpdateErrorAuthExpired`），但**改寫其顯示文案**（見 6.2）——鳴潮無法斷定為認證問題，用通用「伺服器暫時異常」措辭，且不再要求重開頁。

## 九、非目標（範圍界線 / YAGNI）

- 不細分 `code` 語意（限流、伺服器忙碌等）——目前樣本不足，沿用「`code != 0` 即失敗」。
- 不新增重試次數設定、不做指數退避——比照原版「重攔一次」。
- 不改 `gacha_fetcher.dart` 的 `fetchPool` 對外行為（仍丟 `GachaApiException`）。
- 不動 import / forceRefetch / 物品圖片等其他流程。

## 十、驗收條件

- `dart format lib/ test/`、`flutter analyze`（`No issues found!`）、`flutter test`（`All tests passed!`）全綠。
- 部分池失敗 → 不彈失敗框，顯示「完成」＋紅字「部分失敗」。
- 全池失敗 → 自動退回等待捕獲（下方小字提示），重開記錄頁取得新 recordId 後可成功；重攔仍全掛才彈失敗框，且文案不再要求重開頁。
- 重攔被取消 → 不彈任何錯誤、不破壞既有快取 cred。
