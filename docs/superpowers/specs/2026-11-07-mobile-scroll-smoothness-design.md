# 手機滑動流暢度優化設計

## 為什麼

使用者在手機（ROG Phone 9，165Hz）上覺得滑動「頓頓的」，打開 app 時尤其明顯。先前用 debug 版測試會 JIT 卡頓，換成 profile 版後順很多，但仍有不規律的「晚一拍」節奏。

## 量測結果（2026-11-07，profile 版實機）

量法：用 SurfaceFlinger `--latency` 量 app 圖層的實際上屏間隔，只統計放手後慣性滑動的幀，避開 adb 注入觸控取樣造成的假象。165Hz 下每幀預算約 6.06ms，間隔 ≤ 9.1ms 算準時。

| 頁面 | 慣性滑動準時率 | 靜止時出幀 |
|---|---|---|
| 綜合（啟動首頁） | 43%（冷啟動後 41～44%） | 0 |
| 角色活動 | 92% | 持續約 165fps |
| 武器活動 | 97% | 持續約 165fps |
| 其他有紀錄的卡池頁（6 頁） | 98.6～99.2% | 持續約 165fps |
| 設定、貢獻者 | 99～100% | 0 |
| 無紀錄的卡池頁 | 無法捲動 | 0 |

Flutter timeline（綜合頁滑動）：UI 執行緒每幀 p50 8.1ms，其中 SEMANTICS 4.4ms、PAINT 3.3ms、LAYOUT/BUILD 約 0。raster 執行緒 p50 2.2ms。SEMANTICS 會跑，是因為手機開著無障礙服務（ASUS GlideX）。密碼管理器、投放、讀屏等服務都會觸發，所以實際使用者也常遇到。

根因：
1. 綜合頁、卡池頁的外層是 `SingleChildScrollView` + `Column`，整頁一次建好。每捲一點，整頁（包含畫面外的區塊）的繪製與語意樹都要重算。橫向五星時間軸（`TimelineHorizontal`）同樣是 `SingleChildScrollView` + `Row`，上百個帶圖示的欄位全部常駐。
2. `PityCard` 的呼吸動畫在 `initState` 就無條件 `repeat()`。只有「快保底」才真的套用動畫，但計時器一直在跑，每個 vsync 都排一幀，導致卡池頁靜止時也以 165fps 重畫（主要是耗電，不是頓的主因）。

## 目標

- 綜合頁與所有可捲動頁面，慣性滑動準時率 ≥ 95%（同一支手機、同樣開著無障礙服務、同樣量法）。
- 卡池頁靜止時不出幀；「快保底」時呼吸動畫照常運作。
- 外觀、互動、桌面版行為不變。

## 非目標

- 啟動流程本身（冷啟動後綜合頁的數據與熱啟動相同，問題在頁面而不在啟動）。
- 物品圖示解碼尺寸、`build()` 內的 `existsSync`：raster 只有約 2ms，不是瓶頸。
- 鎖定刷新率、關閉語意樹等迴避手段。

## 反目標

- 捲出畫面再捲回來時遺失狀態：紀錄表頁碼、搜尋框文字、篩選狀態、時間軸的橫向捲動位置。
- 版面在任何寬度下跑掉（桌面三欄、中寬、手機），或 RWD 斷點行為改變。
- 無障礙退步：語意內容只改成按需產生，不刪除。

## 做法

考慮過的方案：
- **A. 只隔離重繪區塊（RepaintBoundary）＋修動畫**：省得掉 PAINT，省不掉 SEMANTICS 的 4.4ms，綜合頁仍會超過預算。被量測結果否決。
- **B. 全面改寫成 slivers（CustomScrollView）**：效果最好，但改動面大，桌面版多欄佈局要重做。
- **C. 鎖刷新率**：只是把問題藏起來。

採用的是 A 的動畫修正，加上 B 的最小版本（使用者 2026-11-07 同意）：

1. **頁面外層改成按需建構的清單**：`overview_page.dart`、`banner_page.dart` 的 `SingleChildScrollView(child: Column(...))` 改為 `ListView(children: [...])`（同樣的 padding 與子區塊）。畫面外的區塊不建構、不繪製、不產生語意，`ListView` 也會自動替每個子項加上 RepaintBoundary。區塊內部的 `LayoutBuilder`／`IntrinsicHeight` 等佈局維持原樣。
2. **保留畫面外區塊的狀態**：會因捲出畫面而被回收、且帶有本地狀態的區塊（至少 `SortableTable` 的頁碼、`SearchFilterBar` 的輸入、`TimelineHorizontal` 的捲動位置），必須在捲回來時維持原狀。做法交給實作者（例如 keep-alive，或把狀態移到既有 provider），但要有測試涵蓋「捲出再捲回，頁碼不變」。
3. **五星時間軸按需建構**：`TimelineHorizontal` 的橫向 `SingleChildScrollView` + `Row` 改成橫向 `ListView.builder`。「現在」欄、月份分隔線、左右漸層、箭頭、捲動指示（`_updateAffordance`）、滑鼠拖曳都維持現狀。
4. **呼吸動畫只在快保底時跑**：`PityCard` 只在 phase 為 `close` 且未要求減少動態時才 `repeat()`，其他時候停止；pity 資料更新而進入或離開 `close` 時要跟著啟停（`didUpdateWidget`）。動畫的進度條用 `RepaintBoundary` 隔離，只重畫那條。

## 驗收

- 在同一支手機上用 profile 版，以同一支量測腳本重量全部頁面，達成上述目標，並把前後數據記進 `docs/Android移植筆記.md`。
- `fvm flutter analyze` 無問題、`fvm flutter test` 全綠。新增的測試至少涵蓋：
  - 非快保底時 PityCard 不排程畫面。
  - 快保底時動畫在跑。
  - 紀錄表捲出再捲回，頁碼保留。

## 留給實作者決定

- 狀態保留用 keep-alive 還是把狀態移到 provider。
- `ListView` 的 `cacheExtent` 是否需要調整（預設即可，除非量測顯示捲入時出現建構尖峰）。
- 綜合頁、卡池頁之外，設定頁與貢獻者頁已達標，不必改。
