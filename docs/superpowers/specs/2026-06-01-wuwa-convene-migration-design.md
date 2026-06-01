# 原神祈願 → 鳴潮喚取 遷移設計 spec

- 狀態：草案（待使用者審核）
- 日期：2026-06-01
- 規格資料來源：[docs/鳴潮相關資料.md](../../鳴潮相關資料.md)、[docs/術語表.md](../../術語表.md)
- 範圍：把 fork 自原神祈願卡池分析的這個專案，改造為**鳴潮喚取卡池分析（僅國際服）**。
- 本 spec 由跨子系統並行分析（7 子系統 + 完整性審查）彙整，並已收斂跨領域矛盾與產品決策。

---

## 一、目標與非目標

### 目標
- 攔截鳴潮喚取記錄 API、抓取全部 8 種卡池記錄、本機保存、統計分析、分享圖、多帳號、多語系——對齊原神版既有功能集，但改用鳴潮的資料模型。
- 沿用原神版的桌面架構（Flutter + Rust FFI、本機代理 + 自簽根憑證、Riverpod、gen-l10n）。

### 非目標（YAGNI）
- 不支援國服（僅國際服 `aki-game2.net`）。
- 不遷移原神舊存檔（全新不相容 schema）。
- 不追蹤 50/50（UP/歪）——與原神版一致，本來就沒做。
- 不抓武器/道具圖片（官方只有角色圖）。

---

## 二、高層資料流變更

```
原神（現況）                                   鳴潮（目標）
────────────────────────────────             ────────────────────────────────
攔 GET *.hoyoverse.com/getGachaLog            攔 POST gmserver-api.aki-game2.net
  （參數在 URL query）                            /gacha/record/query（憑證在 body）
        │ 回傳 URL 字串                                │ 回傳 body JSON 字串
        ▼                                              ▼
GachaUrl.parse(url)                            GachaCredential.fromCapturedBody(json)
        │                                              │  { playerId, cardPoolId, serverId,
        │  逐 banner 逐頁 GET（end_id 分頁）              │    recordId, languageCode }
        │  retcode -100/-101/-110 分流                   │  迭代 cardPoolType [1,2,3,4,5,6,8,9]
        │  靠 id 比大小增量合併                            │  各發一次 POST（無分頁）
        │  probeUid 取 record.uid                        │  code!=0 → 中止 + 提示重開頁
        ▼                                              │  有序清單比對增量合併
BannerStorage{uid, banners:Map<gachaType>}            │  uid = body.playerId
        │  HoYoWiki 補圖（name+lang 反查）                ▼
        ▼                                       BannerStorage{playerId, languageCode,
表格/時間軸/統計/分享圖/物品詳情                          banners:Map<cardPoolType>}
                                                       │  僅角色補圖（guide-server，roleGbId=resourceId）
                                                       ▼
                                              表格/時間軸/統計/分享圖/物品詳情（武器·道具無圖）
```

---

## 三、跨領域設計決策（已收斂）

完整性審查指出多處「各子系統各自臆測」的矛盾，以下為**本 spec 的裁決**，實作一律以此為準。

| 編號 | 議題 | 裁決 |
|----|----|----|
| **D1** | 有序清單增量合併放哪、怎麼比 | 統一單一檔 `lib/services/record_merge.dart`，函式 `List<GachaRecord> mergeOrderedRecords(List<GachaRecord> fresh, List<GachaRecord> existing)`。比對不變式見〈四-C〉。**先寫測試（TDD）**。 |
| **D2** | 全新 schema 如何拒原神舊檔 | `AccountsBundle.currentSchemaVersion = 2`；`fromJson` 判斷改 `version != 2` → 丟 `FormatException` 並給友善訊息「此為原神版備份，無法匯入鳴潮版」。`GachaStorage.load` 遇舊原神 `<uid>.json`（缺 `resource_id`）**跳過該檔 + log warning，不可 rethrow**（否則 App 開不了）。 |
| **D3** | 存檔檔名規則 / playerId 字元集 | **不靠 `^\d+$` 數字 regex**。改用顯式副檔名：記錄檔 `<playerId>.records.json`、憑證檔 `<playerId>.cred.json`，metadata 檔（圖片索引等）用白名單排除。`playerId` 一律當不透明字串。 |
| **D4** | `cardPoolType` int vs string 轉換點 | `GachaType.cardPoolType` 持 **int**；對外 key/route/map 用 `String get key => cardPoolType.toString()`。請求 body 用 int、存檔 map key 與路由用 String，**轉換只發生在 `GachaType` 與 `GachaCredential.toRequestBody`**，禁止散落。 |
| **D5** | body 敏感資料脫敏 | 新增 `String sanitizeCredential(String bodyJson)` 到 `lib/services/log_sanitize.dart`（playerId 走 `sanitizeUid`，recordId/serverId/cardPoolId 前4後4遮罩）。**歸 dart-fetch-glue 實作**；改寫 `gacha_capture.dart` 既有 log 行（現傳 `sanitizeUrl` 對 JSON 會回 `<malformed url>`）。Rust 端只 log 命中事實 + status + body 長度。 |
| **D6** | orchestrator 重寫歸屬 | `gacha_repository.dart` 的 `_runUpdate` / `_runMitm` / `_fetchAllBanners` / `_fetchHoYoWiki` / `_friendlyError` / `_NoRecordsException` **全部歸 dart-fetch-glue 一人重寫**。移除自動 recapture fallback → 改純提示（recordId 過期需玩家手動重開遊戲頁，自動重打無效）。`NoRecords` 改判「8 池全 `code==0` 且 `data` 全空」。 |
| **D7** | 「是否有圖」判定權威 | **不可用 `resourceId` 位數或 `resourceType` 字串判定（兩者都不準）**。權威 = **圖片索引的實際抓取結果**：`bool hasItemImage(GachaRecord r)` ⇔ `imageIndex.lookupImage(r.resourceId)` 有成功下載的 icon。抓取階段對**所有** unique `resourceId` 嘗試打圖片 API，由 API 回應決定有無圖（有圖→正取；無圖→存帶 `fetchedAt` 的**負取標記**）。**負取非永久**（D11）：角色當下可能無圖、官方日後才上架，故更新時會重試「過期的負取」。所有 icon 消費點一律呼叫 `hasItemImage`；無圖（含負取/未抓）一律走 `_Placeholder`（依稀有度上色），**絕不回 `SizedBox.shrink`**。preload key 與 lookup key **都用 `resourceId`(int)**，立硬契約。 |
| **D11** | 負取快取的重試（避免漏掉官方後補的圖） | 負取**非永久**：預設**每次更新都重試所有負取**（最即時——新角色圖一上架，下次更新就補上）。正取（已有圖 URL）不再重抓（URL 穩定）。為免每次更新對「確定永遠無圖」的武器/道具白重打，搭配 §九 最佳化：一旦確認 API 能區分「非角色」回應，即把非角色標**永久負取**（不再重試），只有「角色但圖未上架」每次重試。未確認前先全部每次重試（無圖物數量有限、成本可接受）。「強制重抓」清掉全部重來。 |
| **D8** | `languageCode` 傳遞鏈 | 帳號級單一值，存於 `BannerStorage.languageCode`（取代每筆 `record.lang`）。`GachaCredential` 帶入 → 寫進 `BannerStorage` → 圖片抓取階段 **改為逐帳號（逐 BannerStorage）收集 `(resourceId, languageCode)`**，供 `fetchItemImages` 的 `X-Language`。 |
| **D9** | 卡池相關程式碼命名 | 卡池相關 class/method/變數一律沿用 **`Gacha`**（如 `GachaCredential`/`GachaApiException`/`gachaTypes`），**不引入鳴潮專有名詞**（不用 `Convene`、`Resonator` 等）作為識別子。「Convene」僅允許出現在專案/套件識別名（與 repo 目錄同名 `wuthering_waves_convene_gacha_analyzer`）與**使用者可見 UI 文案／術語表**，不進入程式碼識別子。 |
| **D10** | 清除所有原神名詞 | 程式碼與內容中**不得殘留任何原神／miHoYo 生態名詞**作為識別子或品牌字串，凡複用一律改名：Rust crate `genshin_capture_core` → `gacha_capture_core`、`hoyowiki_*` 整套 → `item_image_*`、自簽 CA 的 subject/CN/Org 字串、`genshin_gacha_share_*` 檔名、`actionViewOnHoYoWiki`、`*.hoyoverse.com`、`appName`/視窗標題等全部清除。改名須與其綁定處 lockstep（crate↔CMake↔FRB stem、CA↔已安裝憑證）。 |

### 產品決策（使用者已拍板）
- **P1**：新手喚取（type 5）**移除「已結束」狀態**——拿掉 `isEndedPool`、`pity_card` 的 `_Phase.ended`、`pityBeginnerEnded` 整套。
- **P2**：側欄與 Overview **平鋪單段，但保留一個「喚取」`_SectionLabel`**；移除頌願段與 `_resolveRailSelection` 的 odes 分支與 `_RailSelection.odesIndex`。
- **P3**：物品詳情 **武器/道具（無圖）不可點**（passthrough）；僅角色可點開 illustration 大圖。`hasHoYoWikiContent`（將改名）回 false 即不包 `GachaItemTapTarget`。

---

## 四、逐子系統設計

### A. Rust 攔截（`rust/`）

**現況**：`mitm.rs::is_target` 過濾 `*.hoyoverse.com` + `/getGachaLog`|`/getBeyondGachaLog`，`handle_request` 只讀 method/uri/host（**不碰 body**），組 `CapturedRequest{method,url,host,timestamp_ms}` 經 frb sink 回 Dart。自簽 CA 為萬用 root CA，對任何 host 動態簽 leaf，**換 host 不需改憑證機制**。

**改動**：
1. `is_target`：改為 `host == "gmserver-api.aki-game2.net" && path == "/gacha/record/query"`（精確等值），並驗 `method == POST`。抽常數 `TARGET_HOST` / `TARGET_PATH`（YAGNI：不預留國服參數）。
2. `handle_request` 命中分支讀 body：新增 `async fn read_body_string(body) -> Result<(String, Body)>`，用 `http_body_util::BodyExt::collect().await?.to_bytes()` → `String::from_utf8_lossy`，**讀完用 bytes 重建 `Body` 並 `Request::from_parts` 放行**（否則上游收空 body，遊戲端載入失敗）。非命中分支維持零拷貝。collect 失敗 → 放行原請求、不送 `CapturedRequest`（不可 panic）。先不對 request 套 decode（假設純文字 JSON）。
3. `CapturedRequest` 新增 `body: String`（保留 method/url/host/timestamp 以沿用既有 log 流程）。
4. `Cargo.toml` 視需要加 `http-body-util` / `bytes`（**優先用 hudsucker re-export 的型別**避免 hyper 版本不合）。
5. Rust log 只印命中事實 + status + body 長度，**不印 body 原文**（含 playerId）。
6. 改完 `CapturedRequest` → 重跑 frb codegen（`flutter_rust_bridge_codegen generate`），`lib/src/rust/api/capture.dart` 自動更新。
7. `handle_response` 的延遲 500ms 自動 stop、`fired` 一次性命中**維持不變**。
8. **CA 去原神化（D10）**：`ca.rs` 的 `EXPECTED_CN`/`EXPECTED_ORG` 與產生憑證的 subject/CN/Org 字串改中性品牌（不得含原神字樣）。改 CN/Org 等同產生**新的 root CA**——這正好讓鳴潮版與原神版安裝各自獨立的憑證、互不干擾（符合「不覆蓋」需求）；既有 SHA-1 去重邏輯沿用。
9. **Rust crate 改名（D10）**：`genshin_capture_core` → `gacha_capture_core`。必須 **lockstep** 同步：`rust/Cargo.toml` 的 `name`、`windows/CMakeLists.txt` 的 crate/DLL 參照、`flutter_rust_bridge.yaml`、`lib/src/rust/frb_generated.dart` 的 `ExternalLibraryLoaderConfig.stem`（FRB 載入 DLL 用，名稱不一致會載入失敗）。改完重跑 frb codegen。

**不動**：`cert_store.rs`、`sys_proxy.rs`（host/品牌無關）。

### B. Dart 抓取串接

**改動**：
1. **新增 `lib/services/gacha_credential.dart`**（取代 `gacha_url.dart` 的 `GachaUrl`/`GachaEndpoint`）：`GachaCredential{playerId,cardPoolId,serverId,recordId,languageCode}`，`fromCapturedBody(String json)`、`toRequestBody(int cardPoolType) → Map`（共用五欄位、只換 cardPoolType→int）。
2. `gacha_capture.dart`：`CaptureSession.result` 由 `Future<String?>` 改 `Future<GachaCredential?>`；解析 `event.body`(JSON)，失敗 log 並視為未命中；維持 `onDone` 才 complete（等系統代理還原）。log 行改用 `sanitizeCredential`（D5）。
3. `gacha_fetcher.dart`：
   - `fetchPage` 重寫為 **POST**：`client.post(endpoint, headers:{content-type:application/json}, body:jsonEncode(cred.toRequestBody(type)))`；解析 `{code,message,data[]}`，`code==0` 取 data，`code!=0` 丟 `GachaApiException(code,message)`。
   - **空池為成功非失敗**：從未抽過的卡池回 `{code:0, message:success, data:[]}`（已實證）。`code==0` 且 `data` 為空＝該池 0 筆的正常結果，**不可**當錯誤；只有 `code!=0` 才中止。
   - **移除** `end_id` 分頁迴圈、`_idGreater`/`existingMaxId`、retcode `-110` 退避、`probeUid`/`primerPages`、odes 的 lang 回填。
   - 保留 `rateLimit` 夾在 8 個 cardPoolType 之間（避免短時間多打被擋）；序列發送（不併發，較安全）。
   - 合併改呼叫 `record_merge.dart`（見 C）。
   - `FetchedPage` → 視情況改名 `FetchedPoolResult`（語意：整池全歷史，非 page）。
4. `gacha_repository.dart`（D6 全包）：`_fetchAllBanners` 移除 `GachaUrl.parse`；`uid = cred.playerId`；迭代 8 種 cardPoolType 各一次 POST；任一池 `code!=0` → 立即中止整個 update + emit `UpdateError`（「取得記錄失敗，請重開喚取記錄頁再試」）。移除自動 recapture fallback。
5. `update_progress.dart`：`FetchingBanner.pageIndex` 改義為「第幾個 cardPoolType / 共 8」；錯誤分支 `RateLimited`/`AuthExpired`/`ApiError` 整併為 `GachaApiException`。
6. **大 payload**：單池全歷史可能上千筆，`jsonDecode` 考慮用 `compute`/isolate 避免卡 UI（原神逐頁 20 筆無此問題）。

### C. 資料模型與存檔

**`GachaRecord` 重寫**（`lib/models/gacha_record.dart`）：
- 移除 `id`（無唯一 id）、`uid`（身分移到 BannerStorage 層）、`lang`（移到帳號級 languageCode）。
- 新增 `resourceId(int)`、`qualityLevel(int 3/4/5)`、`resourceType(String 角色/武器/道具)`、`cardPoolType(String)`、`name`、`count(int)`、`time(DateTime)`。
- 內部欄位**直接命名 `qualityLevel`**（下游 `rankType` 全改名，不留 getter alias；CLAUDE.md 重維護性）。
- `fromApiJson` 讀 data[] 元素；`toStorageJson`/`fromStorageJson` key 改 `resource_id`/`quality_level`/`resource_type`/`card_pool_type`/`name`/`count`/`time`。
- 抽共用 `parseGachaTime`/`formatGachaTime`（消除 fromApiJson/from/toStorageJson 內重複的 `YYYY-MM-DD HH:mm:ss` ⇄ DateTime）。移除 `copyWith`（原為回填 lang 而存在）。

**`BannerStorage` 改造**（`lib/models/banner_storage.dart`）：`uid` 語意改 `playerId`；**新增帳號級 `languageCode`**（toJson key `language_code`）；`banners` map key 由 7 個 gacha_type 改 8 個 cardPoolType 字串 `'1','2','3','4','5','6','8','9'`（無 `'7'`）。建議 toJson 寫 `player_id` 並落辨識標記。

**`record_merge.dart`（新，D1）**：`mergeOrderedRecords(fresh全量desc, existing)`。不變式：
- `recordsEqual(a,b)` = `(time, resourceId, qualityLevel, name, count)` 全等。
- 用 existing **開頭連續 N 筆**（`N = min(3, existing.length)` 起，必要時放大）作 anchor，在 fresh 找**連續子序列**對齊；不可用單筆 key。
- fallback（皆需測試）：existing 空→回 fresh；fresh 空→回 existing；anchor 在 fresh **找不到**（換服/清號/recordId 指向別帳號）→**以 fresh 為準完整取代 + log warning**（不靜默拼接）；多個匹配→取最靠頂端（最新）。
- fixture 必涵蓋：同十連同道具重複兩筆、新一期第一筆恰等於舊頂端、existing 被回應從中間切斷。

**`AccountsBundle`**（D2）：`currentSchemaVersion=2`、`fromJson` 改 `version != 2` + 友善訊息、`seen` 去重 key 改 `playerId`。

**`GachaStorage`**（D3）：檔名改 `<playerId>.records.json` / `<playerId>.cred.json`；`save/loadCapturedUrl` → `save/loadCapturedCredential`（存整份 cred JSON）；`listKnownUids` 改用副檔名 + metadata 白名單，棄 `_uidPattern`；`load` 遇舊原神格式跳過 + warning。

### D. 卡池定義 / 保底 / 統計

**`gacha_types.dart` 重寫**：8 筆 `GachaType`，`cardPoolType` int（1,2,3,4,5,6,8,9）。保底常數 `_pityFive80`/`_pityFive50`/`_pityFour10`（刪 90/70/20/four70/three5）。type 1/2/3/4/6/8/9 → `[5★80,4★10]`；type 5 → `[5★50,4★10]`。**移除 `GachaCategory` enum** 與所有 `category` 分支。`resolveName` switch 對齊 8 個新 nameKey（見 G）。

- **`gacha_pity.dart`**：語意（per-pool 跨 banner 連續累計）天然符合鳴潮，**幾乎不改**；道具的 qualityLevel 已寫入記錄，天然計入保底。
- **`gacha_stats.dart`**：刪 `twoStarCount`/`twoStarRate` 與 `case 2`；移除 `index: HoYoWikiIndex` 參數（類型改靠 resourceType）。
- **`item_type_kind.dart`**：`itemTypeKeyOf` 改用 record 自帶的 `resourceType`（角色/武器/道具，是 API 給的**類型**欄位、屬權威來源）直接映射 canonical kind，**不再呼叫 HoYoWiki `lookupMenuId`**。注意：此處用 `resourceType` 是做**類型分類**（與 D7「是否有圖」判定無關，兩者是不同問題）；因 `resourceType` 字串隨 `languageCode` 變，映射表需涵蓋各語系文案、fallback 原字串。新增 `kItemKindItem='kind:item'`（道具）。
- **`five_star_collection.dart`**：移除 `_odesGachaTypes` 排除；`_mergeKey` 改 `resourceId`（語言無關）。
- **`overview_sections.dart`**：刪 `OdesSectionData`、`eventFiveCount`/`standardFourCount`/odes 段；改單段、8 池皆套 `fiveStarAvg`/`fourStarAvg`、`timelineRank=5`。
- **`timeline_entries.dart`**：`pullsSinceLastRankedAcrossBanners` 改用**清單索引**定位（不可用 `r.id`）；跨池排序同秒需穩定 tie-break。

### E. 物品圖片服務（去 HoYoWiki 化，D10）

整套 `hoyowiki_*` 重構為中性命名的物品圖片服務（檔名/類別/provider/logger/cache 目錄/index 檔皆去 HoYoWiki，如 `item_image_fetcher.dart`/`item_image_index.dart`/`item_image_cache/`）。`roleGbId`、`data[0].role.*` 是 guide-server 的**回應/查詢欄位名**，照 API 原樣使用、不算違反 D10。

**fetcher**（原 `hoyowiki_fetcher.dart`）：刪 `searchEntryId`/`fetchEntryPage`/`_parseTags`/`_parseGalleryCharacterModule`；新增 `fetchItemImages({resourceId, languageCode, client})` → GET `https://guide-server.aki-game.net/introduction/list?roleGbId=$resourceId`，header `X-Language: $languageCode`，回 `{iconUrl, illustrationUrl}`（取 `data[0].role.cardPictureUrl`/`illustrationPictureUrl`）或 **`null`（無此物的圖／非角色）**。防呆：data 可能空、role 可能缺欄位、包裝格式待實證。保留 `downloadImage`。

**index**（原 `hoyowiki_index.dart`）：三表縮成單表 `items: resourceId → ItemImageEntry{iconUrl, illustrationUrl, noImage:bool, permanentNoImage:bool}`（`noImage=true` 為**負取**、**非永久**每次更新重試；`permanentNoImage=true` 為確認非角色的**永久負取**、不再重試，見 D11 與 §九最佳化）；`lookupId`/`lookupMenuId` → `lookupImage(resourceId)`；icon 檔名推導改吃 resourceId、新增 `itemIllustrationCacheFile`、刪 gallery 檔；storage 全新 schema（移除舊遷移）。

**抓取編排單階段化**（D6/D8/D11，取代 `_fetchHoYoWiki`）：逐 BannerStorage，對該帳號**所有** unique `resourceId` 中符合下列者進 worklist——(a) 未抓過（index 無此 key）、(b) **負取且非永久**（`noImage && !permanentNoImage`，即每次更新都重試）。正取（已有圖 URL）跳過。用該帳號 `languageCode` 呼叫 `fetchItemImages`；回 `{urls}`→`mergeItemImage` 正取 + `downloadImage` 寫 icon（illustration 視需要）；回 `null`→`mergeItemImage` 寫負取（若能確認「非角色」則標 `permanentNoImage`）。**不預先用 resourceId/resourceType 篩角色**（D7：由 API 結果決定）。進度縮為單一下載階段。三個呼叫點（`_fetchAllBanners`/`forceRefetch...`/`importAccounts...`）一併調整：`forceRefetch` 清掉全部（含永久負取）重來；**匯入舊原神 bundle 被拒時不可觸發補圖**。

> D7/D11 一致性：UI 的 `hasItemImage(r)` = `index.lookupImage(r.resourceId)` 有 icon（非負取、非缺）。負取/未抓一律 `_Placeholder`；官方後補的角色圖會在**下次更新**自動補上。

**Notifier**（原 `HoYoWikiIndexNotifier`）：`setSearch`/`mergeEntry` → `mergeItemImage`（含負取）；保留 `bumpCacheRevision`/`resetAll`/`waitForLoad`/`_lock`。

### F. UI 頁面 / 元件

- **側欄 `app_shell.dart`**（P2）：單一 `_SectionLabel`（「喚取」）下平鋪 8 個 tile；移除 odes 段；`_railLabel`/`_railIcon*` switch 改 8 個新 nameKey（新旅另選 icon）；`_resolveRailSelection` 移除 odes 分支與 `_RailSelection.odesIndex`。
- **路由 `app_router.dart`**：`/banner/:type` 的 type 改 cardPoolType 字串，結構不變。
- **`overview_page.dart`**：移除 odes 段，改單段聚合 8 池。
- **`banner_page.dart`**：`_resolveType` fallback pity 90→80；`_iconForGachaType` 8 nameKey；分享檔名去 genshin；**移除 `isEndedPool`**（P1）；雙保底 PityCard（5★+4★）沿用。
- **2★ 移除**：`gacha_stats.dart`、`rarity_pie.dart`（entry + section）、`banner_page._countAtRank`、`rank_palette.dart` 精簡為 3/4/5★。
- **類型加道具**：`item_type_kind.dart` 新增「道具」鍵與譯名；`search_filter_bar` 類型 dropdown 與 `sortable_table` 類型欄能顯示道具；`item_type_pie` 6 色已夠。
- **無圖 placeholder `gacha_item_icon.dart`**（D7）：用 `hasItemImage` 判定；角色查角色圖 cache，武器/道具一律 `_Placeholder`（依稀有度上色）；移除 odes `shrink` 特例。
- **詳情 `gacha_item_detail_dialog.dart`**（P3）：移除 gallery/desc(HTML)/tags/「在 HoYoWiki 開啟」外連/`flutter_html`；角色→icon 小圖 + illustration 大圖（沿用 `showZoomableImageOverlay`）；**武器/道具不可點**（`hasHoYoWikiContent`→改名→回 false，不包 `GachaItemTapTarget`）。
- **分享圖**：`share_card.dart` 移除 odes 段與 2★；`preloaded_hoyowiki_images.dart` key 改 resourceId、只預載角色 icon（illustration 不進 preload，體積大）；`share_image_helper.dart` 檔名 `genshin_gacha_share_*` → 鳴潮命名。
- **`banner_colors.dart`**：7 色（含 odes 2 色）→ 8 色（cardPoolType 1..9 無 7），新旅/新手自選新增配色，dark/light 對比測試。

### G. i18n / 改名 / 品牌

**Package 改名（最高風險、純機械）**：`pubspec.yaml` name → `wuthering_waves_convene_gacha_analyzer`（與 repo 目錄同名；`convene` 僅作專案識別名，符合 D9）；全庫 `package:genshin_impact_wish_gacha_analyzer/` → 新前綴（**1721 處 / 240 檔**），改完立即 `flutter pub get` + `flutter analyze`。此機械步驟**只替換 import 前綴字串**，避免誤傷其他字面值；Rust crate `genshin_capture_core` 改名（→ `gacha_capture_core`）與 installer `AppId` 換新 GUID 屬 D10／§G 的**專門改動**，不混進這個 find-replace。

**ARB（4 檔同步：zh/zh_Hans/en/ja）**：
- 移除 odes/集錄 key：`gachaTypeOdesEvent`/`gachaTypeOdesStandard`/`gachaTypeChronicled`/`navSectionOdes`/`navOdesEvent`/`navOdesStandard`/`emptyNoOdesRecords`/`pageOverviewOdesSection`。
- 8 卡池 key（對齊術語表四語）：`gachaTypeCharacter`(角色活動喚取)、`gachaTypeWeapon`(武器活動喚取)、`gachaTypeStandardCharacter`(角色常駐喚取)、`gachaTypeStandardWeapon`(武器常駐喚取)、`gachaTypeBeginner`(新手喚取)、`gachaTypeBeginnerChoice`(新手自選喚取)、`gachaTypeNewVoyageCharacter`(角色新旅喚取)、`gachaTypeNewVoyageWeapon`(武器新旅喚取)。
- `appName` 改鳴潮品牌（繁「鳴潮喚取卡池分析」/簡「鸣潮唤取卡池分析」/en「Wuthering Waves Convene Gacha Analyzer」/ja 對齊）；`navSectionGacha`「祈願」→「喚取」；`progressOpenGameHint` 改「請開啟鳴潮 → 喚取 → 喚取記錄」；新增 `kindItem`（道具）；移除 `actionViewOnHoYoWiki` 等 HoYoWiki 字串；移除 `pityBeginnerEnded`（P1）。
- 改完跑 `flutter gen-l10n`。

**其他品牌**：`main.cpp:30` splash 硬字串、`Runner.rc` 版本資源、`windows/CMakeLists.txt` `project()`/`BINARY_NAME`（改 exe 名，注意與 Rust crate `gacha_capture_core` 改名 lockstep）、`app_repo.dart` owner/repo（不改更新檢查 404）、`contributors.dart` URL、README ×3、`build_release.ps1`、`.github/release-footer.md`、`.github/FUNDING.yml`、`AGENTS.md`。新 Crowdin 專案 slug。

**安裝檔（與原神版並存、不覆蓋）**：`scripts/build_installer/installer.iss`
- **`AppId` 改成全新 GUID**（原本「不動以保升級」的考量不適用——這是**不同產品**，必須用新 GUID 才不會被當成原神版的升級而覆蓋安裝；沿用舊 GUID 反而會覆蓋）。
- `MyAppName`/`MyAppExeName`/`DefaultDirName`/`OutputBaseFilename`/`UserDataDir` 全改鳴潮品牌與新 exe 名，與原神版**完全不同路徑**，確保兩版可同機並存、各自獨立資料夾。
- `main.dart` 的 `getApplicationSupportDirectory` 衍生資料夾名隨 package 改名而不同，天然與原神版分離（符合全新 schema 不遷移）；確認卸載清資料指向新路徑。

---

## 五、新增元件清單

| 檔案 / 元件 | 用途 |
|----|----|
| `lib/services/gacha_credential.dart`：`GachaCredential` | 封裝攔到的 body 五欄位、`toRequestBody(cardPoolType)`；取代 `GachaUrl` |
| `lib/services/record_merge.dart`：`mergeOrderedRecords` + `recordsEqual` | 有序清單增量合併（D1，核心高風險，TDD） |
| `lib/services/log_sanitize.dart`：`sanitizeCredential` | body JSON 脫敏（D5） |
| `gacha_fetcher.dart`：`GachaApiException(code,message)` | 取代 AuthExpired/RateLimited/ApiError 三例外 |
| `update_error.dart`：`UpdateErrorGachaFailed` | code!=0 通用失敗 → UI 顯示 |
| `item_image` 服務：`ItemImageEntry`/`ItemImageIndex`/`lookupImage`/`mergeItemImage`/`fetchItemImages`/`itemIllustrationCacheFile` | 取代 HoYoWiki 整套 |
| `item_type_kind.dart`：`kItemKindItem` + 道具分支 | 第三類型 |
| 共用：`hasItemImage(GachaRecord)`、`parseGachaTime`/`formatGachaTime` | 角色判定（D7）、時間轉換去重 |
| Rust：`CapturedRequest.body`、`read_body_string` | 攔截 POST body |
| ARB：4 個新卡池 key getter + `kindItem`（gen-l10n 自動產生） | 武器常駐/新手自選/角色新旅/武器新旅/道具 |

---

## 六、測試策略

- **TDD 先行**：`record_merge.dart`（D1）——fixture 涵蓋同十連同道具重複、新期首筆＝舊頂端、existing 被中切、空集、anchor 找不到取代。此為全專案最高風險點。
- **需重寫的測試**：`gacha_record_test`、`gacha_types_test`（8 型別/保底 80/50/10/無 odes）、`gacha_stats_test`（無 2★）、`item_type_kind_test`（resourceType→kind）、`five_star_collection_test`（無 odes/resourceId 鍵）、`overview_sections_test`（無 odes）、`gacha_repository_*_test`（4 檔：capture 回傳型別/merge/補圖/import 拒舊 schema）、`hoyowiki_*_test`（→ item_image）、`gacha_item_icon_test`、`gacha_item_detail_dialog_*_test`、`share_card_test`、`timeline_*_test`。
- **刪除**：`gacha_url_test`（檔被 convene_credential 取代）。
- **驗收**：`dart format lib/ test/` → `flutter analyze`（No issues found!）→ `flutter test`（All tests passed!）→ `cargo test --manifest-path rust/Cargo.toml`。

---

## 七、風險與前置驗證（PoC gate）

**最高優先——動 code 前先排除致命不確定性：**
1. **MITM 可行性**：鳴潮喚取記錄頁的 HTTP stack 是否信任 Windows `CurrentUser\Root` 自簽 CA、有無 cert pinning。若 pinning，整套 MITM 失效。
   - *減輕證據*：使用者已提供**真實攔到的 body + 各卡池回應**，代表 POST 結構已確認、且很可能已能攔截；但仍建議用本軟體實際代理路徑跑一次端到端 PoC 確認。
2. **樣本補齊**：各 cardPoolType 回應（尤其「該帳號從未抽過某池」回 `code==0 data:[]` 還是 `code!=0`，決定「一池失敗即中止」是否過嚴）、`resourceType` 在 en/ja 的實際字串、`guide-server` 圖片 API 是否同樣 `{code,message,data}` 包裝、body 是否純 JSON 無壓縮。

**其他高風險**：
- 有序清單合併正確性（D1）——已用 TDD + fallback 設計減輕。
- Rust 讀 body 後**務必重建 body 放行**（漏了＝遊戲端載入失敗）。
- Package 改名 1721 處——分離成獨立 commit、只替換 import 前綴、編譯為唯一驗證。改名須含 Rust crate `gacha_capture_core`（lockstep CMake↔FRB stem）、CA subject、`item_image` 服務、installer，不得殘留原神字眼（D10）。
- `languageCode` 跨 capture→storage→image 傳遞鏈（D8）——逐 BannerStorage 收集。
- **安裝並存**：`AppId` 必須換新 GUID + 全新安裝/資料路徑，否則會覆蓋既有原神版安裝（D10／§G）。

---

## 八、建議實作順序（commit 分期）

1. **PoC**（前置）：端到端攔截 + 各卡池/錯誤/圖片 API 樣本。
2. **Package 改名**：純機械 import 前綴替換，編譯驗證。
3. **Rust 攔截**：mitm POST body + CapturedRequest.body + frb codegen。
4. **資料層**：`GachaRecord`/`BannerStorage`/`record_merge`(TDD)/`GachaCredential`/`gacha_storage` schema。
5. **抓取串接**：`gacha_fetcher` POST + 迭代 + 合併、`gacha_repository` orchestrator(D6)、錯誤/進度。
6. **卡池/保底/統計**：`gacha_types`/stats/pity/item_type_kind/overview/timeline/five_star（含移除 odes/2★）。
7. **圖片服務**：HoYoWiki → item_image（guide-server）。
8. **UI**：側欄/overview/banner_page/icon/detail dialog/share（含 P1/P2/P3、無圖 placeholder）。
9. **i18n / 品牌**：ARB 8 卡池 + 術語、README、installer、視窗標題、GitHub/Crowdin。
10. **全綠驗收** + 文件更新。

---

## 九、待釐清（剩餘 open items，不阻擋開工）

- `resourceType` 在 en/ja 的實際字串（**類型分類**映射用；圖片判定不靠它，見 D7）。
- `guide-server` 圖片 API 的完整包裝與錯誤形態（`{code,message,data}`？非角色 / data 空時的確切回應，用以實作 fetchItemImages 的正取/負取判斷）。
- **負取重試最佳化（D11 之上）**：若 API 能區分「是角色但圖未上架」（如 `data[0].role` 存在但 `cardPictureUrl` 空）vs「根本非角色」（`data` 全空），則可只對前者做 TTL 重試、後者標永久負取，免得武器/道具每個 TTL 被無謂重打。需實際樣本確認 API 是否提供此區分；未確認前一律走 D11 的 TTL 重試（成本可接受）。
- `recordId` 過期的確切時效（是否需記 `captured_at` 主動判定）。
- code!=0 是否只有 -1（限流/伺服器忙是否有別的碼）。

> 已實證並寫入設計：從未抽過的卡池回 `{code:0, data:[]}`（空池＝成功非失敗，§四-B）。
