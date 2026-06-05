# 設定頁「其他遊戲版本」區塊設計

**日期**：2026-06-06
**目標**：在設定頁「關於」區塊內，新增一段呈現「支援其他遊戲的版本」連結的內容，目前先放原神祈願分析器（姊妹專案），並保留未來擴充其他遊戲的空間。

## 背景

README（繁／簡／英三份）已新增「也有支援其他遊戲的版本」區段，連到原神版專案 `https://github.com/GoneTone/genshin-impact-wish-gacha-analyzer`。本案是把同樣的資訊搬進 App 內的設定頁，讓使用者在程式裡也找得到姊妹專案。

`lib/pages/settings_page.dart` 的 `_AboutContent` 目前由上而下顯示：版本號 + 「查看更新內容 / 檢查更新」按鈕 → `Developed by GoneTone`（`AppLink` 文字連結）→ GoneTone banner（`BannerLink`）。本案在這個 `Column` 末端接續新內容，不另開 `SectionCard`。

## 範圍與決策

| 項目 | 決定 | 備註 |
|---|---|---|
| 位置 | 併入「關於」區塊，接在 GoneTone banner 之後 | 不新增 `SectionCard`；姊妹專案連結屬 meta 資訊 |
| 呈現樣式 | 文字連結（`AppLink`）+ 靜態 `open_in_new` 小圖示 | 與既有「Developed by GoneTone」一致，最輕量 |
| 小標 | 「其他遊戲版本」（`titleSmall` / `textSecondary`） | 與上方開發者資訊作視覺區隔 |
| 未來說明 | 保留「未來可能新增更多遊戲…」次要色說明 | 對齊 README 的「未來可能新增支援更多遊戲…」 |
| 資料來源 | 新增 `lib/data/related_projects.dart` 具名常數 | 風格對齊既有 `AppRepo` / `TeamInfo`；未來加遊戲在此擴充 |
| i18n | 4 份 ARB 同步新增 3 個 key | 遊戲名也在地化（原神 / Genshin Impact） |
| log | 不另埋 | 點擊走既有 `openExternalUrlString`，失敗時已 `Logger('ui.link').warning` |
| 遊戲 icon／logo | 不做 | 需打包外部品牌 asset，有授權顧慮；YAGNI |

## 資料常數：`RelatedProjects`

新增 `lib/data/related_projects.dart`，風格對齊 `app_repo.dart` / `team_info.dart`：

```dart
/// 相關遊戲專案（姊妹專案）的外部連結常數。
///
/// 本 App 之外、由同作者維護的其他遊戲版本祈願／喚取分析器。未來新增其他
/// 遊戲時在此擴充一個常數，並在設定頁「關於」區塊與對應 ARB 各補一筆。
class RelatedProjects {
  /// 防止外部實例化。
  const RelatedProjects._();

  /// 原神祈願分析器專案 GitHub 頁面。
  static const String genshinImpactAnalyzer =
      'https://github.com/GoneTone/genshin-impact-wish-gacha-analyzer';
}
```

**為何不 inline 在 `settings_page.dart`**：URL 屬「外部專案座標」，與既有 `AppRepo`（本專案座標）、`TeamInfo`（團隊連結）同性質，集中在 `data/` 才好維護、避免散落 magic string。

## `_AboutContent` 修改

在 `lib/pages/settings_page.dart` 的 `_AboutContent.build` 最外層 `Column` 末端，接續現有 banner `Wrap` 之後新增（示意，實作以 `AppSpacing` token 為準）：

```dart
const SizedBox(height: AppSpacing.l),
Text(
  l.settingsOtherGamesTitle,
  style: theme.textTheme.titleSmall?.copyWith(
    color: theme.gacha.textSecondary,
  ),
),
const SizedBox(height: AppSpacing.xs),
Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    AppLink(
      url: RelatedProjects.genshinImpactAnalyzer,
      child: Text(l.settingsOtherGamesGenshin),
    ),
    const SizedBox(width: AppSpacing.xs),
    Icon(Icons.open_in_new, size: 14, color: theme.gacha.textSecondary),
  ],
),
const SizedBox(height: AppSpacing.xs),
Text(
  l.settingsOtherGamesFuture,
  style: theme.textTheme.bodySmall?.copyWith(
    color: theme.gacha.textSecondary,
  ),
),
```

**設計理由**：
- 遊戲名用既有 `AppLink`，與「Developed by GoneTone」同款（primary 色、hover 加深、共用 `openExternalUrlString`），不引入新連結模式。
- `open_in_new` 圖示**放在 `AppLink` 之外**且為靜態 `textSecondary` 色：`AppLink` 的 hover 只透過 `DefaultTextStyle.merge` 染文字、不影響 `Icon`（`Icon` 取 `IconTheme` 非 `DefaultTextStyle`），放進去顏色會對不上。此處圖示僅作「會開外部瀏覽器」的提示，不需隨 hover 變色。
- `Row(mainAxisSize: MainAxisSize.min)`：讓「文字 + 圖示」整體靠左、寬度只佔內容，避免圖示被推到卡片最右。
- 多個遊戲時這段可改為對清單 `map`；目前單筆，YAGNI，先直接寫一列。

## 在地化（4 份 ARB 同步）

於 `app_zh` / `app_zh_Hans` / `app_en` / `app_ja` 各新增 3 個 key：

| key | app_zh | app_zh_Hans | app_en | app_ja |
|---|---|---|---|---|
| `settingsOtherGamesTitle` | 其他遊戲版本 | 其他游戏版本 | Versions for Other Games | 他のゲーム向けバージョン |
| `settingsOtherGamesGenshin` | 原神 | 原神 | Genshin Impact | 原神 |
| `settingsOtherGamesFuture` | 未來可能新增更多遊戲… | 未来可能新增更多游戏… | More games may be supported in the future… | 今後、対応ゲームが増える可能性があります… |

- 省略號用單一 `…`（U+2026），不用 ASCII `...`（對齊 CLAUDE.md 標點規則）。
- key 命名沿用既有 `settingsXxx` 前綴；放在 `app_zh.arb` 的 `settingsAbout*` 一帶，其餘語系維持相同鍵序。
- 新增後跑 `flutter gen-l10n` 重新產生 `lib/l10n/generated/app_localizations.dart`。

## 測試

新增 `test/pages/settings_other_games_section_test.dart`，沿用 `settings_privacy_section_test.dart` 的 harness（英文語系 pump `SettingsPage`）：

1. **小標渲染**：找得到 `Versions for Other Games`。
2. **連結渲染**：找得到 `Genshin Impact` 文字，且其位於一個 `AppLink` 內（`find.ancestor` 驗證），`AppLink.url` 等於 `RelatedProjects.genshinImpactAnalyzer`。
3. **未來說明渲染**：找得到 `More games may be supported in the future…`。

實際 URL 開啟屬 `url_launcher` 平台行為，與既有 `app_link` / `banner_link` 測試策略一致，不在 widget test 內驗證實際開啟。

## 不做的事（YAGNI）

- 不抽「其他遊戲清單」widget／資料模型 — 目前單筆，直接寫一列即可。
- 不打包原神 logo／icon asset — 純文字連結，避免外部品牌 asset 授權顧慮。
- 不另開 `SectionCard` — 姊妹專案屬「關於」meta 資訊，併入即可。
- 不為點擊埋新 log — 既有 `openExternalUrlString` 已覆蓋失敗路徑。

## 檔案清單

| 動作 | 路徑 |
|---|---|
| 新增 | `lib/data/related_projects.dart` |
| 修改 | `lib/pages/settings_page.dart`（`_AboutContent` 末端新增小標 + 連結列 + 說明） |
| 修改 | `lib/l10n/app_zh.arb`（+3 key） |
| 修改 | `lib/l10n/app_zh_Hans.arb`（+3 key） |
| 修改 | `lib/l10n/app_en.arb`（+3 key） |
| 修改 | `lib/l10n/app_ja.arb`（+3 key） |
| 新增 | `test/pages/settings_other_games_section_test.dart` |

（`flutter gen-l10n` 重新產生的 `lib/l10n/generated/app_localizations.dart` 屬 build 產物，隨之更新。）

## 完成條件

- `flutter gen-l10n` 成功產生 localizations。
- `dart format lib/ test/` 無變更。
- `flutter analyze` 輸出 `No issues found!`。
- `flutter test` 輸出 `All tests passed!`。
- 實機：設定頁「關於」區塊在開發者 banner 下方可看到「其他遊戲版本」小標、「原神 ↗」文字連結與未來說明；hover 變色、點擊開啟原神專案頁面；切換語系時三段文字正確在地化。
