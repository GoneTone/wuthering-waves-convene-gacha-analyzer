# 物品詳情純文字 URL 自動可點擊（linkify）設計

- 日期：2026-06-19
- 狀態：設計定稿，待實作
- 對齊：姐妹專案 PR [genshin-impact-wish-gacha-analyzer#123](https://github.com/GoneTone/genshin-impact-wish-gacha-analyzer/pull/123)

## 目標

物品詳情 dialog 內的簡介／造型背景說明若含**純文字網址**（非可點擊），自動轉成可點擊連結並以系統瀏覽器開啟。內容裡本來就寫成 `<a href>` 的連結也維持可點，點擊行為一致。

涵蓋兩處內容，皆走同一渲染入口 `_detailHtml()`：

- 角色簡介（`ItemDetailL10n.intro`，來自 encore Introduction／BgDescription）。
- 造型背景故事（`ItemSkin.bgDescription`）。

## 非目標（YAGNI）

- 不處理 `www.` 開頭與裸網域（如 `foo.com`）：避免把版本號、檔名、句中含點字串誤判成網址。只比對 `http://`／`https://` 開頭的完整 URL。
- 不做 per-link hover 變色：行內 HTML 連結採靜態色 + 底線即可，與既有行內連結風格一致。
- 這次只接物品詳情 dialog 一處；`AppHtml` 雖設計為通用共用元件，但不主動改寫其他畫面的 HTML 渲染。

## 現況

- 物品簡介與造型說明集中由 `lib/widgets/dialogs/gacha_item_detail_dialog.dart` 的 `_detailHtml()`（約第 479 行）渲染：
  ```dart
  Widget _detailHtml(ThemeData theme, String data) => DefaultTextStyle(
    style: theme.textTheme.bodyMedium ?? const TextStyle(),
    child: Html(data: stripEntryLinkTags(data), style: _detailHtmlStyle(theme)),
  );
  ```
  改這一處即同時涵蓋 intro 與 bgDescription 兩個呼叫點。
- `stripEntryLinkTags()`（`lib/utils/encore_entry_text.dart`）先移除 encore 詞條標籤 `<te>`，純文字 URL 在此之後才以裸字串形式露出。
- `openExternalUrlString(String url, {String context})`（`lib/widgets/app_link.dart`）已存在：`tryParse → 無效記 warning → openExternalUrl`，是全應用程式統一的外部連結入口。本專案此 helper 已抽出，無需再抽。
- `linkBaseColor(ThemeData)`（`app_link.dart`）回傳 `colorScheme.primary`，為統一連結色。
- `flutter_html: ^3.0.0`、`url_launcher: ^6.3.2` 已在 `pubspec.yaml`；`html` 套件目前由 `flutter_html` 傳遞帶入，**未顯式宣告**。

## 資料流

```
encore raw HTML（含 <te> 詞條標籤）
  ↓ stripEntryLinkTags()        既有：移除 <te>，純文字 URL 露出為裸字串
  ↓ linkifyHtml()      [新增]   DOM parser 走訪 text node，把 http(s):// URL 包成 <a>
  ↓ AppHtml → flutter_html Html  onLinkTap 委派 openExternalUrlString（既有）
```

`stripEntryLinkTags` 維持在 `linkifyHtml` 之前：先還原 `<te>` 內文，URL 才會以可被 linkify 的純文字出現。

## 元件設計

### `lib/utils/html_linkify.dart`（新增，純函式）

```dart
/// 將 [html] 內純文字的 http(s):// 網址包成可點擊的 `<a>`，回傳新 HTML 字串。
String linkifyHtml(String html);
```

- 用 `package:html` 的 `parseFragment` 解析為 DOM，深度走訪節點：
  - **只處理 text node**：在文字內容上用 RegExp 比對完整 URL，命中處切片、改寫為 `<a href="url">url</a>` 的混合節點序列。
  - **既有 `<a>` 子樹整棵略過**：不向下走訪 `<a>` 內部，避免產生巢狀 `<a>`。
  - **屬性值不碰**：只改文字節點，`href="…"` 等屬性值不受影響。
- URL 比對：以 `https?://` 起頭的連續非空白字元；**尾端標點不吃進連結**——半形（`. , ; : ! ? ) ] }` 與 `"` `'`）與全形（`。，、；：！？）」』】`）結尾標點排除在 URL 之外，且連續尾端標點皆正確剝除。
- 失敗保護：整段 `try/catch`，解析或改寫拋例外時回傳**原字串**，確保描述區不致渲染中斷。

### `lib/widgets/app_html.dart`（新增，共用元件）

```dart
/// 套用 linkify + 統一連結色／onLinkTap 的 HTML 區塊；包裝 flutter_html 的 [Html]。
class AppHtml extends StatelessWidget {
  const AppHtml({super.key, required this.data, this.style});
  final String data;
  final Map<String, Style>? style;
}
```

- `build`：
  ```dart
  Html(
    data: linkifyHtml(data),
    onLinkTap: (url, _, _) =>
        openExternalUrlString(url ?? '', context: 'AppHtml'),
    style: {
      'a': Style(
        color: linkBaseColor(theme),
        textDecoration: TextDecoration.underline,
      ),
      ...?style,
    },
  )
  ```
- 預設 `'a'` 連結樣式（primary 色 + 底線）置於 map 前段，呼叫端傳入的 `style` 後展開，**呼叫端可覆蓋**任何鍵（含 `'a'`）。

### `gacha_item_detail_dialog.dart`（改動）

`_detailHtml` 內 `Html(...)` → `AppHtml(...)`，`stripEntryLinkTags(data)` 仍在外層先跑：

```dart
Widget _detailHtml(ThemeData theme, String data) => DefaultTextStyle(
  style: theme.textTheme.bodyMedium ?? const TextStyle(),
  child: AppHtml(data: stripEntryLinkTags(data), style: _detailHtmlStyle(theme)),
);
```

### `pubspec.yaml`（改動）

`html` 由傳遞依賴提升為顯式依賴（因 `html_linkify.dart` 直接 import）。

## 錯誤處理

- `linkifyHtml` 解析失敗 → 回傳原字串，描述照常渲染（只是不 linkify）。
- 點擊連結：沿用 `openExternalUrlString` 既有行為——URL 無效或無法啟動時記 `Logger('ui.link').warning`，靜默返回，不彈錯。
- linkify 為純函式、無 I/O，不額外埋 log。

## 測試

### `test/utils/html_linkify_test.dart`

- `http://` 與 `https://` 命中、包成 `<a>`。
- `ftp://`、`www.foo.com`、裸網域 `foo.com` **不**命中。
- 半形尾端標點（`http://a.com.`）與全形尾端標點（`http://a.com。`）不吃進連結。
- 連續尾端標點（`http://a.com).` 等）正確剝除。
- 既有 `<a>` 不被雙包（無巢狀 `<a>`）。
- 屬性值（`<a href="http://x">`）不被改。
- 同段落多個網址皆命中。
- 解析失敗 → fallback 回原字串。

### `test/widgets/app_html_test.dart`

- 基本 render（含一段純文字 URL 會出現可點擊連結）。
- `onLinkTap` 已接上（點擊觸發外部開啟路徑）。
- 呼叫端 `style` 可覆蓋預設 `'a'` 樣式。

### 回歸

- 既有物品詳情 dialog 測試全綠。
- `fvm dart format lib/ test/`、`fvm flutter analyze`（`No issues found!`）、`fvm flutter test`（`All tests passed!`）三項全過。

## 影響檔案總覽

| 檔案 | 動作 |
| --- | --- |
| `lib/utils/html_linkify.dart` | 新增（純函式 `linkifyHtml`） |
| `lib/widgets/app_html.dart` | 新增（`AppHtml` 共用元件） |
| `lib/widgets/dialogs/gacha_item_detail_dialog.dart` | 改 `_detailHtml`：`Html` → `AppHtml` |
| `pubspec.yaml` | `html` 提升為顯式依賴 |
| `test/utils/html_linkify_test.dart` | 新增 |
| `test/widgets/app_html_test.dart` | 新增 |
