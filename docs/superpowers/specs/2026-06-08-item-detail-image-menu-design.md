# 物品詳情圖片右上角選單設計

## 背景與目標

物品詳情 dialog（`lib/widgets/dialogs/gacha_item_detail_dialog.dart`）的圖片區（`_buildCurrentImageArea`）目前只支援「點圖放大」（`showZoomableImageOverlay`）。本次在圖片區右上角新增一個溢出選單，提供三個動作：

1. **儲存圖片** -- 把目前顯示的圖另存到使用者選的位置。
2. **複製圖片** -- 把目前顯示的圖複製到系統剪貼簿。
3. **重抓圖片** -- 重新抓取目前顯示的圖（覆蓋既有快取）。

目標是讓使用者能輕鬆取得喜歡的造型立繪、喚取立繪或 icon，並在某張圖抓壞／想換時手動重抓，而不必清整個快取資料夾。

## 範圍

- **涵蓋**：詳情 dialog 圖片區三種 chip 類型（造型 `skin`、喚取 `luckdraw`、`icon`）的選單。
- **不涵蓋**：全螢幕 lightbox（`zoomable_image_overlay.dart`，已有自己的 X 鈕，本次不加選單）。

## 既有可重用資產

| 資產 | 位置 | 用途 |
|---|---|---|
| `_fetchAndCache` | dialog state | 造型圖 HTTP 下載並寫快取 |
| `_captureLuckdraw` | dialog state | 喚取立繪 WebView 擷取 |
| `_retryEntry` | dialog state | 失敗重試（重抓會沿用其切 loading 的模式） |
| `getSaveLocation` | `file_selector` | 系統存檔對話框（`share_image_export.dart` 已用） |
| `Formats.png` / `super_clipboard` | `share_image_export.dart` | 寫 PNG 到剪貼簿 |
| `ui.instantiateImageCodec` + `toByteData(png)` | `share_image_renderer.dart`、`preloaded_item_images.dart` | 解碼快取檔並編碼成 PNG |
| `itemIconCacheFile` / `itemIllustrationCacheFile` / `itemLuckdrawCacheFile` | `services/item_image_index.dart` | 推導各類圖的快取路徑 |
| `sanitizeFsPath` / `sanitizeUrl` | `services/log_sanitize.dart` | log 脫敏 |

## UI/UX 設計

### 選單按鈕

- 位置：圖片區右上角，沿用 `zoomable_image_overlay.dart` X 鈕的視覺風格 -- 半透明黑底（`Colors.black.withValues(alpha: 0.4)`）圓形 `Material` 包 `PopupMenuButton`，icon 為 `Icons.more_vert`（白色）。
- 顯示時機：**一直顯示**（不採 hover 浮現，與觸控裝置一致）。
- 只在 `_ImageReady` 狀態渲染：`_ImageLoading` 只有 spinner、`_ImageFailed` 維持既有「重試」按鈕（語意與重抓重疊，不另加選單）。
- 實作：把 `_ImageReady` 分支的可縮放圖包進 `Stack`，選單按鈕以 `Positioned(top, right)` 疊在 zoom 用的 `GestureDetector` 之上，確保點按鈕不會誤觸放大。

### 選單項目

| 項目 | icon | 行為 |
|---|---|---|
| 儲存圖片 | `Icons.save_alt` | 解碼快取檔成 PNG -> `getSaveLocation`（建議檔名 `<物品名>_<chip 標籤>.png`）-> 寫檔。取消則無動作。 |
| 複製圖片 | `Icons.copy` | 解碼快取檔成 PNG -> 寫入系統剪貼簿（`Formats.png`）。 |
| 重抓圖片 | `Icons.refresh` | 依 chip 類別重抓，過程切回 loading spinner（見下節）。 |

「儲存圖片」與「複製圖片」共用同一條「快取檔解碼 -> PNG bytes」路徑（webp/jpg 自動轉 PNG，輸出格式統一）。

## 重抓邏輯

### 各類型機制

| 類型 | 重抓動作 |
|---|---|
| `skin` | `imageCache` evict 後設 loading，呼叫 `_fetchAndCache(url, file)`（覆蓋同路徑快取）。 |
| `luckdraw` | evict 後設 loading，呼叫 `_captureLuckdraw(file, lang)`。 |
| `icon` | evict 後設 loading，重新下載 `entry.iconUrl` 並 `writeImageFileAtomic` 覆蓋；額外刷新標題縮圖與記錄列表（見下）。 |

### 快取失效（關鍵技術點）

重抓 ready 圖時快取路徑不變（skin 由 URL 推導、luckdraw 固定 `<id>_luckdraw.png`、icon 同 URL），但 Flutter `ImageCache` 以 path 為 key，`Image.file` 的 `ValueKey(file.path)` 也不變 -- 不處理會繼續顯示舊圖。既有 `_retryEntry` 只從 `_ImageFailed` 觸發（當時無檔／壞檔），故未踩到此坑；本次重抓 ready 圖必須處理：

1. 新增 `Map<String, int> _imageVersion`（path -> 版本號），重抓時對該 path `++`。
2. 重抓前 `imageCache.evict(FileImage(file))`，並從 `_precachedPaths` 移除該 path（讓 precache 重排）。
3. 圖片區的 `Image.file` key 改為 `ValueKey('${file.path}#${version}')`，強制重建並重新解碼。

### Icon 重抓的連動刷新

icon 快取檔同時用於 dialog 標題縮圖（`title` 區 `Image.file(iconFile)`）與記錄列表縮圖。icon 重抓成功後：

- `imageCache.evict(FileImage(iconFile))`（標題與列表共用同一 `FileImage` key）。
- `ref.invalidate(itemImageIndexProvider)`，讓 watch 此 provider 的列表項重建。
- 標題縮圖的 `Image.file` 同樣納入版本化 key，確保 dialog 內即時更新。

## 新增服務

新增 `lib/services/item_image_save.dart`，仿 `share_image_export.dart` 的可測試結構：

- `Future<Uint8List?> encodeImageFileToPng(File file)` -- 讀檔、`instantiateImageCodec`、`toByteData(png)`；失敗回 null（呼叫端記 log 並提示）。
- `Future<bool> saveImagePng(Uint8List png, {required String suggestedName})` -- `getSaveLocation` -> 寫檔；使用者取消回 false（不視為錯誤），寫檔失敗 rethrow。
- `Future<bool> copyImagePngToClipboard(Uint8List png)` -- 寫 `Formats.png`；平台不支援回 false。
- 測試 seam（`@visibleForTesting`）：save location picker、file writer、clipboard writer，並提供 `reset...Seams()`，讓 `flutter test` 不開真實對話框／不碰真實剪貼簿（沿用 `share_image_export.dart` 既有手法）。

dialog 端只負責：取目前 chip 的 `file` -> 呼叫上述函式 -> 依結果顯示提示與 log。

## 錯誤處理與提示

採 `SnackBar`（沿用 app 既有風格；若 dialog context 無 `ScaffoldMessenger`，改用既有提示元件，實作時對齊現況）：

| 情境 | 提示 | log |
|---|---|---|
| 存檔成功 | 「已儲存圖片」+ 路徑 | `info`，脫敏路徑 |
| 存檔取消 | 無 | `info` |
| 存檔失敗 | 「儲存失敗」 | `warning`，脫敏路徑 + 例外 |
| 複製成功 | 「已複製圖片」 | `info` |
| 複製失敗 | 「複製失敗」 | `warning` |
| 重抓 | 沿用 `_fetchAndCache` / `_captureLuckdraw` / icon 下載既有 log | -- |

logger 沿用 `Logger('gacha.itemimage.detail')`；服務層用 `Logger('gacha.itemimage.save')`。

## i18n

新增 ARB 字串（4 語：`app_zh.arb` / `app_zh_Hans.arb` / `app_en.arb` / `app_ja.arb`），對齊既有命名（如 `gallery*` / `action*`）：

- 選單三項：儲存圖片 / 複製圖片 / 重抓圖片。
- 提示：已儲存圖片（含路徑佔位）/ 儲存失敗 / 已複製圖片 / 複製失敗。

CJK 文案用全形標點；省略號（若有）用 ASCII `...`。

## 測試

- `item_image_save.dart`：以 seam 注入 fake picker / writer / clipboard，驗證
  - PNG 編碼成功路徑與失敗（不可解碼檔）回 null；
  - 存檔成功 / 取消（picker 回 null）/ 寫檔失敗 rethrow；
  - 複製成功 / 平台不支援回 false。
- `gacha_item_detail_dialog`：
  - `_ImageReady` 時選單按鈕存在、`_ImageLoading` / `_ImageFailed` 時不存在；
  - 重抓造型／喚取會把對應 chip 切回 loading 並觸發既有取圖路徑（以既有 fetcher / capture seam 驗證）；
  - icon 重抓會 evict 並 invalidate index（驗證標題縮圖 key 版本更新）。

## 驗收條件

- `fvm dart format lib/ test/` 無變動殘留。
- `fvm flutter analyze` 輸出 `No issues found!`。
- `fvm flutter test` 輸出 `All tests passed!`。
- 手動：三種 chip 各能存檔（PNG）、複製、重抓；重抓後立即顯示新圖（非舊快取）；icon 重抓後標題縮圖同步更新。
