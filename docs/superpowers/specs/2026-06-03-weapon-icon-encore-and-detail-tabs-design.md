# 武器 icon 來源（encore.moe）+ 還原詳情頁籤切換器 — Design

**Date**: 2026-06-03
**Branch**: `feat/weapon-icon-and-detail-tabs`
**Status**: Approved（pending implementation plan）

## 背景

鳴潮喚取記錄只給 `resourceId` / `name` / `qualityLevel` / `resourceType`，**沒有任何圖片 URL**，圖片需自行依 `resourceId` 對應。現況：

- **圖片管線**為兩階段（`gacha_repository.dart._fetchItemImages`：checking 查圖寫 index → downloading 下載 icon），所有顯示點都走 `ItemImageIndex` + `GachaItemIcon`，已能容忍無圖→placeholder（D7）。
- `item_image_fetcher.dart.fetchItemImages()` **只打官方 guide-server**（`guide-server.aki-game.net/introduction/list?roleGbId={resourceId}`），而 guide-server **只涵蓋角色**（`cardPictureUrl` / `illustrationPictureUrl`）。因此 8 碼**武器/道具一律無圖**（見 `docs/鳴潮相關資料.md:233`），且武器每次更新都白打一次 guide-server →負取→下次重抓。
- 研究（`memory/wuwa-icon-sources.md`）確認 **encore.moe** 可補武器：武器 icon 檔名內嵌 8 碼 `resourceId`，可由紀錄直接組 URL，本機實測 200 webp；hakush.in 目前 NXDOMAIN 不可用。

同時，遷移時把詳情 dialog 從**原版原神的 chip 頁籤切換器**（多圖可切換、icon 永遠最後一個、單圖時自動隱藏 chip 列）砍成「單張立繪」，引入一個 **bug**：對「有 icon 但 `illustrationUrl` 空」的物品，`_scheduled` 區不執行 → `_state` 永遠停在 `_IllustrationLoading` → **永久 spinner**。武器補圖後（無立繪）必然踩到。

## 範圍

**做**：
- **A. 武器 icon 來源**：`fetchItemImages()` 在 guide-server 回 null 後，以 encore.moe 武器 URL 做順序 fallback。
- **B. 還原詳情 chip 頁籤切換器**：移植原版 chip 切換器骨架，餵入鳴潮現有兩張圖（立繪 + icon，icon 最後）；剝除鳴潮無資料源的部分（gallery 多圖、HTML 描述、tags、wiki 連結）。修掉永久 spinner bug。
- **C.** `.gitignore` 排除 `/.playwright-mcp/`。

**不做**：
- **不做角色 fallback**：guide-server 角色已足夠；不引入 encore 角色路徑、不需 Arikatsu `roleinfo.json` 對照表（YAGNI）。
- **不還原**描述 / tags / wiki 連結 / gallery 多圖，**不重新引入 `flutter_html`**：guide-server 無此資料源，硬加只會顯示空資料。
- **不加第二武器圖源備援**（hakush.in / wuwatracker）：YAGNI，掛掉就 placeholder。
- **不改** `gacha_repository.dart` 兩階段流程與 D7 worklist 邏輯（`fetchItemImages` 仍為「是否有圖」唯一裁決者）。
- **不 bundle** 任何官方/社群素材進 release（授權：素材皆 Kuro Games 版權，僅執行期抓取＋本機快取）。

## 既決事項（已確認）

| 主題 | 決定 |
|---|---|
| 圖源路由 | **先官方後 encore 順序 fallback**；不靠 `resourceType`/位數預判是否有圖（D7 保留），由實際抓取結果決定 |
| 武器來源 | **只用 encore.moe**；URL 由 `resourceId` 直接組，免對照表 |
| 存在性探測 | encore 分支以**輕量 HEAD** 探測 2xx 才算有圖；維持兩階段「checking 確認 → downloading 下載」契約，repository 不動。**HEAD 若 encore 不支援（405/非 2xx）改用 ranged GET（`Range: bytes=0-0`）；實作前先 curl 驗一次** |
| 武器詳情 | **可點、放大顯示 icon**；`illustrationUrl` 維持空、**不另存 illustration 檔** |
| 角色詳情 | **還原 chip 頁籤切換**：`[立繪, Icon]`，**Icon 永遠最後**；可切換、各自可縮放 |
| 單圖處理 | `chipEntries.length == 1`（如武器只有 Icon）→ **自動隱藏 chip 列**、直接放大顯示該圖（沿用原版行為） |
| spinner bug | Icon chip 永遠 ready（已快取）→ 還原 chip 切換器即天然修掉永久 spinner |
| 可點性 | `hasItemDetailContent` = icon 已快取（沿用原版判準）；武器有 encore icon 後即可點 |
| 立繪 chip 標籤 | 新增 l10n `galleryIllustrationLabel`（立繪 / Illustration / イラスト / 立绘）；Icon 沿用既有 `galleryIconLabel` |
| 描述/tags/wiki | 一律不還原（無資料源）；標題維持 `icon(64) + 名稱` |

## Part A — 武器 icon 來源（encore.moe 順序 fallback）

### `item_image_fetcher.dart`

- 新增 encore 常數與武器 URL builder：
  ```
  https://api-v2.encore.moe/resource/Data/Game/Aki/UI/UIResources/Common/Image/IconWeapon/T_IconWeapon{resourceId}_UI.webp
  ```
- `fetchItemImages()` 流程改為：
  1. 打 guide-server（現邏輯不變）；命中角色 → 回 `(iconUrl, illustrationUrl)`。
  2. guide-server 回 null（含 data 空 / role 缺 / cardPictureUrl 空 / 非 2xx）→ **encore 武器 fallback**：組 URL → HEAD 探測。
     - 2xx → 回 `(iconUrl: encoreUrl, illustrationUrl: '')`。
     - 非 2xx / 例外 → 回 `null`（負取，與現狀一致）。
- **不靠 `resourceType`/位數預判**：所有 guide-server miss 的 id 都走 encore 探測；角色若 guide-server 漏抓，encore 武器 URL 會 404 → 自然回 placeholder（不誤判）。
- 帶禮貌 `User-Agent` header 打 encore。
- log（`Logger('item_image.fetcher')`）：encore 分支記 `resourceId`、`source=encore`、HTTP status、`sanitizeUrl(url)`，命中/未命中各一條。

### `gacha_repository.dart`

- **完全不動**。`fetchItemImages` 回非 null 即正取（武器 icon 進 `toDownload` 下載寫檔、轉正取後不再重抓），回 null 即負取。順帶消除「武器每次更新白打」的浪費。

## Part B — 還原詳情 chip 頁籤切換器

### `gacha_item_detail_dialog.dart`

移植原版（baseline `f3014e3`）chip 切換器骨架，**剝除鳴潮無資料源的部分**：

- **chipEntries 組法**（取代現「單張立繪」邏輯）：
  - 若 `illustrationUrl` 非空 → 加 `立繪` chip（lazy 下載）。
  - **永遠最後**加 `Icon` chip（已快取、永遠 ready）。
- **顯示**：
  - 角色（立繪+icon）→ 2 chips，`ChoiceChip` 列可切換；選中 chip 顯示 `Image.file(..., BoxFit.contain)`，可點開 `zoomable_image_overlay`。
  - 武器（僅 icon）→ 1 chip → **chip 列隱藏**（`chipEntries.length > 1` 才繪）→ 放大顯示 icon。
- **保留**原版機制：per-image lazy 下載（立繪）、`_GalleryLoading/Ready/Failed` 三態、失敗 `actionRetry`、`precacheImage`、`gaplessPlayback`。Icon chip 直接 `_GalleryReady`。
- **剝除**：`gallery.list` / `gallery.picUrl` 多圖、`desc`(HTML)、`tags`、`actionViewOnHoYoWiki` wiki 連結、`flutter_html` import、`hoyowiki_*` 殘留。標題維持 `icon(64) + 名稱`。
- **可點性**：`hasItemDetailContent` 維持「icon 已快取」判準（武器有 encore icon 後即可點）。現版已無頌願 `_odesGachaTypes` gate（鳴潮無頌願），維持不加回。

### l10n

- 新增 `galleryIllustrationLabel`：`立繪`（zh）/ `Illustration`（en）/ `イラスト`（ja）/ `立绘`（zh-Hans）。
- 沿用既有 `galleryIconLabel`、`galleryLazyLoadFailed`、`actionRetry`。

## Part C — `.gitignore`

新增一行 `/.playwright-mcp/`（研究期 Playwright MCP 產生的未追蹤目錄）。

## 測試

- **`item_image_fetcher_test.dart`**：
  - guide-server hit → 回角色 `(icon, illustration)`，**不打 encore**。
  - guide-server miss + encore HEAD 2xx → 回 `(encoreUrl, '')`。
  - guide-server miss + encore 非 2xx → null。
  - encore URL builder：`21010011` → 預期路徑。
- **`gacha_item_detail_dialog_test.dart`**：
  - 武器（僅 icon）→ 單 chip、chip 列不顯示、放大 icon、可點、**無永久 spinner**。
  - 角色（立繪+icon）→ 2 chips、Icon 在最後、可切換。
  - 無 icon → 不可點（`hasItemDetailContent` false）。
- **`gacha_repository_item_image_test.dart`**：武器 resourceId 經 encore 轉正取、寫檔。

## 驗收條件

- `dart format lib/ test/` 無變更殘留。
- `flutter analyze` → `No issues found!`。
- `flutter test` → `All tests passed!`。
- **本機實跑**：確認 encore 在使用者網路可達、武器 icon 真的顯示於表格/時間軸/分享圖，且武器詳情可點、放大顯示 icon、角色詳情可在立繪/Icon 間切換。

## 風險與已知限制

- **encore.moe 可達性**：第三方 CDN，本機需先確認 live 200；掛掉/404 → placeholder（同現有無圖行為），不影響其他功能。
- **武器 icon 放大略糊**：encore 武器 icon 為小方圖，`BoxFit.contain` 放大到大圖區會偏糊，已知可接受。
- **「道具」型（8 碼非武器，如 4★ 塵雲旋臂）**：encore 武器端點無此類 → 404 → placeholder（與現狀一致），本期不另尋來源。
- **授權**：encore/官方素材皆 Kuro Games 版權、無第三方散布授權；僅執行期抓取＋本機快取，不 bundle 進 release（見 `memory/wuwa-icon-sources.md`）。
