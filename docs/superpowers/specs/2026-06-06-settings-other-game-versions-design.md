# 設定頁「其他遊戲版本」區塊設計

**日期**：2026-06-06
**目標**：在設定頁「關於」區塊內，新增一段呈現「支援其他遊戲的版本」連結的內容，目前先放原神祈願分析器（姊妹專案），並以資料驅動清單為未來新增更多遊戲版本預留低成本擴充點。

## 背景

README（繁／簡／英三份）已新增「也有支援其他遊戲的版本」區段，連到原神版專案 `https://github.com/GoneTone/genshin-impact-wish-gacha-analyzer`。本案是把同樣的資訊搬進 App 內的設定頁，讓使用者在程式裡也找得到姊妹專案。

`lib/pages/settings_page.dart` 的 `_AboutContent` 目前由上而下顯示：版本號 + 「查看更新內容 / 檢查更新」按鈕 → `Developed by GoneTone`（`AppLink` 文字連結）→ GoneTone banner（`BannerLink`）。本案在這個 `Column` 末端接續新內容，不另開 `SectionCard`。

## 範圍與決策

| 項目 | 決定 | 備註 |
|---|---|---|
| 位置 | 併入「關於」區塊，接在 GoneTone banner 之後 | 不新增 `SectionCard`；姊妹專案連結屬 meta 資訊 |
| 呈現樣式 | 文字連結（`AppLink`）+ 靜態 `open_in_new` 小圖示 | 與既有「Developed by GoneTone」一致，最輕量 |
| 小標 | 「其他遊戲版本」（`titleSmall` / `textSecondary`） | 與上方開發者資訊作視覺區隔 |
| 未來說明 | 保留「未來可能新增更多遊戲...」次要色說明 | 對齊 README 的「未來可能新增支援更多遊戲...」 |
| URL 常數 | 新增 `lib/data/related_projects.dart` | 風格對齊既有 `AppRepo` / `TeamInfo`；只放外部專案 URL |
| 清單抽象 | 抽出 `OtherGameVersions` widget + `kOtherGameVersions` 資料清單 | 未來新增遊戲只改清單一筆 + 對應 ARB，免動 widget／`_AboutContent` |
| i18n | 4 份 ARB 同步新增 3 個 key | 遊戲名也在地化（原神 / Genshin Impact） |
| log | 不另埋 | 點擊走既有 `openExternalUrlString`，失敗時已 `Logger('ui.link').warning` |
| 遊戲 icon／logo | 不做 | 需打包外部品牌 asset，有授權顧慮；YAGNI |

## URL 常數：`RelatedProjects`

新增 `lib/data/related_projects.dart`，只放外部專案 URL，風格對齊 `app_repo.dart` / `team_info.dart`：

```dart
class RelatedProjects {
  const RelatedProjects._();

  /// 原神祈願分析器專案 GitHub 頁面。
  static const String genshinImpactAnalyzer =
      'https://github.com/GoneTone/genshin-impact-wish-gacha-analyzer';
}
```

**為何不 inline 在 `settings_page.dart`**：URL 屬「外部專案座標」，與既有 `AppRepo`（本專案座標）、`TeamInfo`（團隊連結）同性質，集中在 `data/` 才好維護、避免散落 magic string。

## 清單與 widget：`OtherGameVersions`

新增 `lib/widgets/other_game_versions.dart`，把資料模型、清單、widget 收在同一檔，讓「加一個遊戲」只需改這裡 + 補 ARB：

- `OtherGameVersion`：單一項目模型，欄位為 `String Function(AppLocalizations l) label`（在地化遊戲名 resolver）與 `String url`。用 function resolver 而非寫死字串，才能讓清單保持 `const` 又取得在地化名稱。
- `_genshinLabel`：top-level function（`const` tear-off 需要 top-level function，closure 非 `const`），回傳 `l.settingsOtherGamesGenshin`。
- `kOtherGameVersions`：`const List<OtherGameVersion>`，目前單筆（原神）。新增遊戲在此補一筆。
- `OtherGameVersions`：`StatelessWidget`，渲染小標 → 對 `kOtherGameVersions` 逐筆輸出一列（`AppLink` 文字連結 + 靜態 `open_in_new` 圖示）→ 未來說明。

```dart
String _genshinLabel(AppLocalizations l) => l.settingsOtherGamesGenshin;

const List<OtherGameVersion> kOtherGameVersions = [
  OtherGameVersion(
    label: _genshinLabel,
    url: RelatedProjects.genshinImpactAnalyzer,
  ),
];
```

**設計理由**：
- 遊戲名用既有 `AppLink`，與「Developed by GoneTone」同款（primary 色、hover 加深、共用 `openExternalUrlString`），不引入新連結模式。
- `open_in_new` 圖示**放在 `AppLink` 之外**且為靜態 `textSecondary` 色：`AppLink` 的 hover 只透過 `DefaultTextStyle.merge` 染文字、不影響 `Icon`（`Icon` 取 `IconTheme` 非 `DefaultTextStyle`），放進去顏色會對不上。此處圖示僅作「會開外部瀏覽器」的提示，不需隨 hover 變色。
- `Row(mainAxisSize: MainAxisSize.min)`：讓「文字 + 圖示」整體靠左、寬度只佔內容。

## `_AboutContent` 修改

在 `lib/pages/settings_page.dart` 的 `_AboutContent.build` 最外層 `Column` 末端（現有 banner `Wrap` 之後）接續，並於檔頭 import `widgets/other_game_versions.dart`：

```dart
const SizedBox(height: AppSpacing.l),
const OtherGameVersions(),
```

`_AboutContent` 本身只負責擺位，內容與資料都封裝在 `OtherGameVersions`，未來擴充不動此檔。

## 在地化（4 份 ARB 同步）

於 `app_zh` / `app_zh_Hans` / `app_en` / `app_ja` 各新增 3 個 key（緊接 `settingsAbout` 之後，維持各語系相同鍵序）：

| key | app_zh | app_zh_Hans | app_en | app_ja |
|---|---|---|---|---|
| `settingsOtherGamesTitle` | 其他遊戲版本 | 其他游戏版本 | Versions for Other Games | 他のゲーム向けバージョン |
| `settingsOtherGamesGenshin` | 原神 | 原神 | Genshin Impact | 原神 |
| `settingsOtherGamesFuture` | 未來可能新增更多遊戲... | 未来可能新增更多游戏... | More games may be supported in the future... | 今後、対応ゲームが増える可能性があります... |

- 省略號用 ASCII `...`，與 README 既有文案一致（本專案約定：省略號一律 `...`，不用全形 `…`）。
- 新增後跑 `flutter gen-l10n` 重新產生 `lib/l10n/generated/app_localizations.dart`（gitignore，不入版控）。

## 測試

新增 `test/widgets/other_game_versions_test.dart`，輕量 widget 測試（不需 provider container），harness 對齊既有 widget 測試（`buildDarkTheme()` 提供 `theme.gacha`、英文語系）：

1. 小標 `Versions for Other Games`、`Genshin Impact` 連結文字、未來說明 `More games may be supported in the future...` 皆 render。
2. `Genshin Impact` 位於一個 `AppLink` 內（`find.ancestor`），且其 `url` 等於 `RelatedProjects.genshinImpactAnalyzer`。

實際 URL 開啟屬 `url_launcher` 平台行為，與既有 `app_link` / `banner_link` 測試策略一致，不在 widget test 內驗證。

## 不做的事（YAGNI）

- 不打包原神 logo／icon asset — 純文字連結，避免外部品牌 asset 授權顧慮。
- 不另開 `SectionCard` — 姊妹專案屬「關於」meta 資訊，併入即可。
- 不為點擊埋新 log — 既有 `openExternalUrlString` 已覆蓋失敗路徑。
- 清單目前單筆，不預先做排序／分組／圖示欄位 — 有需求再加。

## 檔案清單

| 動作 | 路徑 |
|---|---|
| 新增 | `lib/data/related_projects.dart` |
| 新增 | `lib/widgets/other_game_versions.dart` |
| 修改 | `lib/pages/settings_page.dart`（import + `_AboutContent` 末端加 `OtherGameVersions`） |
| 修改 | `lib/l10n/app_zh.arb`（+3 key） |
| 修改 | `lib/l10n/app_zh_Hans.arb`（+3 key） |
| 修改 | `lib/l10n/app_en.arb`（+3 key） |
| 修改 | `lib/l10n/app_ja.arb`（+3 key） |
| 新增 | `test/widgets/other_game_versions_test.dart` |

## 完成條件

- `flutter gen-l10n` 成功產生 localizations。
- `dart format lib/ test/` 無變更。
- `flutter analyze` 輸出 `No issues found!`。
- `flutter test` 輸出 `All tests passed!`。
- 實機：設定頁「關於」區塊在開發者 banner 下方可看到「其他遊戲版本」小標、「原神 ↗」文字連結與未來說明；hover 變色、點擊開啟原神專案頁面；切換繁／簡／英／日語系時三段文字正確在地化、省略號顯示為 `...`。
