# Luckdraw 喚取立繪 — 設計文件

- 日期：2026-06-05
- 狀態：設計（待使用者覆核 → writing-plans）
- 範圍：物品詳情 dialog 新增「喚取」立繪（角色喚取 Spine 動態立繪的單幀），透過離屏 WebView2 即時擷取 encore.moe 已渲染的 canvas、存本機快取後顯示。

---

## 一、背景與目標

使用者希望在物品詳情 dialog 顯示 encore.moe 角色頁上的「Luckdraw（喚取）」立繪（如 `https://encore.moe/character/1211`）。目標是讓詳情頁能呈現與該網頁**視覺一致**的喚取立繪，且**不違反專案既有授權底線**（不 bundle／不重新散布 encore／遊戲美術）。

## 二、關鍵事實（已實測）

1. **Luckdraw 是 Spine 2D 骨架動畫**，非現成 GIF／影片。角色詳情 API（`api-v2.encore.moe/api/{lang}/character/{id}`）的 `Luckdraw` 物件只給 `LuckdrawSpineAtlas` 與 `LuckdrawSpineSkeletonData`（遊戲內資源路徑）。
2. Spine 素材可由 `https://api.encore.moe/resource/Data` + 路徑下載（`.atlas`／`.skel`／`.webp` 貼圖），`.skel` 版本為 **Spine 4.1.23**。
3. encore.moe 角色頁把該 Spine 渲染到 `#luckdraw-section .spine-container > canvas`（WebGL，去背）。
4. **不可能三角**：「與動畫完全一致」「我方不需 Spine 授權」「不重新散布美術」三者只能擇二。
   - 原生 `spine_flutter`（凍結幀／動畫）：一致＋不散布，但**需 Spine 編輯器授權**＋原生依賴。
   - canvas 離線預抓＋打包／自架：一致＋不需授權，但**重新散布美術**（牴觸「勿 bundle」底線）。
   - **本機即時擷取＋快取（本案）**：一致＋不需我方 Spine 授權＋不散布——渲染借 encore 頁面 runtime、在使用者機器上即時抓、快取於本機，與現行「線上抓 icon／立繪後快取本機」同類行為。
5. 取像素**必須在 `requestAnimationFrame` 內**：WebGL canvas 多為 `preserveDrawingBuffer=false`，直接 `toDataURL` 取到空白；於 rAF 內 `drawImage(canvas)` 到 2D canvas 再 `toDataURL` 才有像素（已實測：直取空白、rAF 內成功）。

## 三、PoC 結論（已驗證，見 §十一 剩餘風險）

獨立丟棄式 Flutter Windows 專案（主 repo 之外）以 `webview_windows` 實測通過：

| 驗證項 | 結果 |
|---|---|
| webview_windows 於實機 Windows 渲染 encore WebGL spine | ✅ |
| canvas 像素擷取（`executeScript` 輪詢 ＋ rAF 存 `window.__cap` ＋ 分塊讀回） | ✅ dataURL 944KB 完整取回 |
| 存出有效、與網頁一致之去背 PNG | ✅ |
| 首開延遲（loadUrl → 擷取完成） | ~4.5s（含行程＋WebView2 初始化 ~6.8s） |
| WebView2 runtime 偵測 | ✅ 已內建（`WebviewController.getWebViewVersion()`） |

**踩雷記錄**：`webMessage`／`addScriptToExecuteOnDocumentCreated` 那條路在實機完全無回應；改成 **`executeScript` 驅動**（輪詢狀態、rAF 內把 dataURL 存 `window.__cap`、再以 `executeScript('window.__cap.substr(i,n)')` 分塊讀回）才穩定。擷取解析度隨 webview viewport 寬度（PoC 視窗較窄得 852×710；放寬可得 ~1277×1064）。

## 四、設計決策（使用者已定）

- **觸發時機**：**開詳情即背景預抓**（cache miss 時）。使用者點到「喚取」chip 時通常已就緒，否則顯示 loading。
- **背景呈現**：**透明立繪配 app 背景**（不與 encore `UnderBgTexturePath` 合成；直接以去背 PNG 襯 app 主題背景）。
- **適用範圍**：**角色（kind == character）且該角色有 `Luckdraw` 欄位**才顯示「喚取」chip 並預抓；武器／道具不適用。

## 五、架構與元件

整體沿用既有「線上抓 → atomic 寫本機快取 → `Image.file` 顯示」管線；新增僅集中在「擷取來源是 WebView2 而非 HTTP」這一塊。

### 5.1 依賴

- 主專案 `pubspec.yaml` 新增 `webview_windows: ^0.4.0`。WebView2 runtime 於 Win10/11 內建；缺失時（`getWebViewVersion() == null`）功能優雅停用（不顯示喚取 chip）。

### 5.2 `LuckdrawCaptureHost`（隱藏離屏擷取宿主，新增 widget）

- 於 app 根掛載一次（如 root `MaterialApp` 的 `builder` 內以 `Stack`／`Overlay` 疊一個離屏層）。
- 持有一個**可重用**的 `WebviewController`，以固定尺寸（約 1400×1180 logical px）**離屏但仍 layout／paint**（用 `Opacity(0)` 或 `Transform.translate` 移出畫面，**不可用 `Offstage`**——不 paint 會讓 rAF 停擺，見 §十一）。
- 不直接被 dialog 引用；透過 5.3 服務操作。

### 5.3 `LuckdrawCaptureService`（擷取服務，新增；以 Riverpod provider 提供）

單一職責：給定角色，回傳本機快取的喚取立繪檔。

- API：`Future<File?> captureLuckdraw({required int resourceId, required String kind, required String lang})`
- 流程：
  1. 算快取檔路徑 `<resourceId>_luckdraw.png`；命中即直接回傳。
  2. 未命中 → 透過 `LuckdrawCaptureHost` 的 controller：`loadUrl(encoreItemUrl(...))` →（**重用既有 `encoreItemUrl()`**）→ 注入武裝腳本（rAF 偵測非空白後同幀全尺寸 `drawImage`→`toDataURL` 存 `window.__cap`）→ 輪詢 `executeScript` 取狀態 → 就緒後分塊讀回 dataURL → `base64Decode` →（**重用 `writeImageFileAtomic()`**）寫 `<id>_luckdraw.png` → 回傳檔。
  3. 失敗（逾時／無 `#luckdraw-section canvas`／解碼失敗）→ 回 null。
- **序列化**：單一隱藏 webview，一次只跑一個擷取（內部 queue／mutex）。dialog 為 modal、同時間最多一個，衝突機率低，仍以 queue 保險。
- 逾時：與既有 HTTP 一致量級（建議 30s，涵蓋 SPA 載入＋渲染）。

### 5.4 資料模型擴充

- `ItemImageEntry` 新增 `bool hasLuckdraw`（**lang-agnostic**，存 entry 層非 per-lang）；storage JSON key `has_luckdraw`，預設 false，向後相容。
- 喚取立繪 art 無語言差異 → **每 resourceId 抓一次**（快取不分 lang）。
- 快取檔命名 `<resourceId>_luckdraw.png`（新增推導函式 `itemLuckdrawCacheFile(...)`，對齊既有 `itemIconCacheFile`／`itemIllustrationCacheFile`）。

### 5.5 詳情擷取擴充（記錄 `hasLuckdraw`）

- `EncoreItemDetail` 新增 `bool hasLuckdraw`；`ItemImageFetcher.fetchItemDetail` 解析角色 body 的 `Luckdraw` 物件是否存在且含非空 `LuckdrawSpineSkeletonData` → 設 `hasLuckdraw`。
- 寫 index 的 orchestration（既有 repo）把 `hasLuckdraw` 落到 `ItemImageEntry.hasLuckdraw`（任一 lang 的 detail fetch 即可決定，值跨 lang 相同）。

### 5.6 詳情 dialog 整合（`gacha_item_detail_dialog.dart`）

- `_ChipKind` 新增 `luckdraw`。
- chip 順序：**「喚取」排最前**（最醒目）→ 造型（依序）→ Icon。僅 `kind == character && entry.hasLuckdraw == true` 時加入喚取 chip。
- 喚取 chip 對應的 `_ImageChipEntry.file` = `itemLuckdrawCacheFile(...)`；`url` 留空（來源非單一 URL）。
- `_loadStates` 同步：喚取 chip 若快取檔存在 → `_ImageReady`；否則 `_ImageLoading` + 於 `addPostFrameCallback` 呼叫 `LuckdrawCaptureService.captureLuckdraw(...)`（即「開詳情即背景預抓」），成功 `setState` 為 `_ImageReady(file)`，失敗 `_ImageFailed()`。
- 顯示與重試：**完全沿用** `_buildCurrentImageArea`（`_ImageReady`→可縮放 `Image.file`／`_ImageLoading`→spinner／`_ImageFailed`→重試）；重試呼叫服務而非 HTTP 下載（`_retry` 需依 chip kind 分流：skin 走 `_fetchAndCache`、luckdraw 走 capture 服務）。
- 去背立繪襯 app 背景：`_buildCurrentImageArea` 既有 `ClipRRect` 容器即可；如需底色，於該容器加 app token 背景色（不與 encore 背景合成）。

## 六、資料流（時序）

```
開啟角色詳情（entry.hasLuckdraw == true）
  build() 加入「喚取」chip，cache miss → _ImageLoading
  postFrame → LuckdrawCaptureService.captureLuckdraw(rid)
     ├─ cache hit → 直接回檔（即時）
     └─ cache miss →
          LuckdrawCaptureHost.controller.loadUrl(encore 角色頁)
          注入武裝腳本（rAF 內擷取存 window.__cap）
          輪詢 executeScript 取狀態 → 就緒 → 分塊讀回 dataURL
          writeImageFileAtomic(<id>_luckdraw.png)
          回傳檔 → setState(_ImageReady)
使用者點「喚取」chip → 顯示 Image.file（就緒）或 spinner（擷取中）
點圖 → showZoomableImageOverlay（沿用）
```

## 七、失敗處理與 logging（依 CLAUDE.md）

- 三分流忠實保留：**就緒／擷取中／失敗（+重試）**，不得塌成單一狀態。
- 失敗情形：WebView2 缺失、頁面逾時、`#luckdraw-section canvas` 不存在（encore 改版）、像素解碼失敗。一律回 null → `_ImageFailed`（可重試），不永久停用。
- Logger 命名對齊既有樹，建議 `gacha.luckdraw.capture`／`item_image.luckdraw`。關鍵節點記 log：載入 URL（經 `sanitizeUrl`）、rid、各階段（armed／capReady／capLen）、擷取耗時 ms、bytes、失敗原因。敏感資料經 `sanitizeUrl`／`sanitizeFsPath`／`sanitizeUid`。

## 八、快取與清除

- 快取檔 `<id>_luckdraw.png` 納入 cache usage 統計與清除：擴充既有清除邏輯（`deleteIllustrationCacheFiles` 或新增對 `_luckdraw` 的處理），並更新 `item_image_cache_usage`。
- 「強制重抓」：刪除 `_luckdraw.png` 後下次開詳情自動重新擷取（沿用 lazy 行為）。

## 九、授權與 etiquette

- 不 bundle、不自架散布 encore／遊戲美術；擷取在**使用者機器上即時進行、快取於本機**，與現行 icon／立繪快取同性質。
- 降低對 encore 的負載：每 resourceId 僅擷取一次（永久快取），僅於使用者開啟該角色詳情時觸發。
- 來源依賴 encore 頁面結構（`#luckdraw-section canvas`）；改版時優雅失敗（隱藏／重試），不影響其他功能。

## 十、測試策略

- 單元測試（純 Dart，可在 CI 跑）：
  - `itemLuckdrawCacheFile` 路徑推導。
  - `ItemImageEntry` 的 `has_luckdraw` JSON round-trip（load/save 向後相容、缺欄位預設 false）。
  - `fetchItemDetail` 解析 `Luckdraw` 欄位 → `hasLuckdraw`（以 fixture JSON：有／無 Luckdraw、空字串）。
  - dialog chip 組裝：`hasLuckdraw` 為真時喚取 chip 出現且排最前；為假時不出現。
- WebView2 擷取本身屬平台整合，無法在純 `flutter test` 覆蓋；以實機驗證（Phase 1 spike）＋ 服務層對「缺 host／逾時」回 null 的單元測試補強。
- `flutter analyze` 全綠、`flutter test` 全綠、`dart format lib/ test/`。

## 十一、待驗風險與實作階段建議

- **唯一待驗硬風險：離屏渲染**。PoC 的 webview 為可見狀態；正式版需隱藏離屏。瀏覽器對不可見內容會節流／停止 rAF。緩解：離屏但保持 paint（`Opacity(0)`／移出畫面，非 `Offstage`），必要時保留極小可見區。
- **實作計畫第一步（Phase 1 spike）**：把 PoC 改成「隱藏離屏」模式，確認 rAF 仍跑、能穩定擷取、量測延遲；通過後再做完整整合。未過則退回備案（§十二）。
- 解析度調校：離屏 webview 固定 ~1400px 寬以取 ~1277×1064 全解析。

## 十二、備案（若 Phase 1 離屏渲染不可行）

- 退回本對話評估過的其他角：原生 `spine_flutter` 凍結幀／動畫（需 Spine 授權）、或近似合成（encore `UnderBgTexturePath` 背景＋去背立繪，零授權但非完全一致）。屆時重啟對應設計分支。

## 十三、YAGNI／非目標

- 不做動畫播放（本案僅單幀靜態，符合使用者「不會動」取向；日後若要動再評估 `spine_flutter`）。
- 不與 encore 背景合成（使用者選透明立繪配 app 背景）。
- 不為武器／道具做喚取立繪。
- 不預先抽象多來源擷取框架；僅實作當前需要的 Luckdraw 單一路徑。
