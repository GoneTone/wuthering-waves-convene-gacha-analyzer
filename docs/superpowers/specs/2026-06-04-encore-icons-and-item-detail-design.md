# 全物品 icon/圖片改用 encore.moe ＋ 加回物品詳情顯示 — Design

**日期**：2026-06-04
**分支**：`feat/encore-icons-item-detail`
**狀態**：待審閱（brainstorming 已完成，UI 經 visual companion 拍板）

---

## 1. 背景與動機

目前鳴潮版的物品圖片來自兩個來源、且詳情顯示在遷移時被砍到只剩圖片切換：

- **角色圖**：官方 `guide-server`（`https://guide-server.aki-game.net/introduction/list`，帶 `X-Language` header）取 `cardPictureUrl`（icon）＋ `illustrationPictureUrl`（立繪）。
- **武器 icon**：`encore.moe` fallback，但靠**猜檔名**（無底線 `T_IconWeapon{id}_UI` ／ 有底線 `T_IconWeapon_{id}_UI` 兩候選逐一探測），3.0「共生武裝」起檔名規則變動造成過缺圖（最近的 `3c6f2a6` 即為此補丁）。
- **詳情 dialog**（`gacha_item_detail_dialog.dart`）：遷移時 HoyoWiki 聯動被移除，只剩「立繪／Icon」圖片切換，沒有簡介、沒有 tag、沒有外部連結。

encore.moe 提供完整的官方 API（`https://api-v2.encore.moe`，文件 `https://api-v2.encore.moe/_docs/scalar`），單一來源即可取得角色／武器／道具的 icon、立繪、簡介、稀有度、元素、武器類型等。本案：

1. **把所有物品的 icon／圖片改成從 encore.moe 取得**，移除 guide-server 與「猜檔名」探測 —— 列表端點直接回傳正確 icon URL，徹底解決 3.0 武器底線檔名缺圖。
2. **加回原神版風格的物品詳情顯示**，版面忠實沿用原神版，資料改由 encore 提供。
3. **encore API 的 `lang` 參數帶入該物品的擷取語言**（帳號級 `BannerStorage.languageCode`），**不看應用程式 UI 語言** —— 與原神版、與現行 guide-server `X-Language` 行為一致。

---

## 2. 範圍 / 非目標

**做**：

- 改寫 `ItemImageFetcher`：以 encore **列表端點**解析格子 icon URL（取代 guide-server＋猜檔名探測），以 encore **詳情端點**取簡介／元素／武器類型／立繪 URL。
- 改寫 `gacha_repository._fetchItemImages`：**更新階段預抓** per-lang 詳情並存入索引（方案2），讓 dialog 開啟即顯示。
- 詳情 dialog 加回：名稱下方的**簡介**（`flutter_html` 渲染）與 **tag chips**、actions 區的「**在 encore.moe 查看**」外連按鈕；圖片切換改用 encore 立繪。
- 資料模型：`ItemImageEntry` 加 **per-lang 詳情**（`detailByLang`），storage v1→v2。
- lang 對應：帳號擷取的 `languageCode` → encore `{lang}` 路徑參數（白名單＋fallback）。
- 重新引入 `flutter_html`（簡介渲染）；對應的 model／parse、i18n、log、測試。

**不做（YAGNI / 維持「和原神版一樣」）**：

- **不**顯示技能、共鳴鏈、基礎屬性、武器效果數值等 encore 進階資料（超出原神版範圍）。
- **不**預先下載立繪大圖（立繪**圖片**仍 lazy，只在 dialog 開啟時下載；立繪 **URL** 已隨詳情預抓存入索引）。
- **不**為武器取立繪大圖（使用者決定武器切換列只放 Icon，見 §3）。
- **不**做 tag 點擊行為（過濾／跳轉）、不做 tag 分組／排序。
- **不**改 package 名、repo URL、app UI 語系清單。

---

## 3. 既決事項（UI 經 visual companion 拍板）

| 主題 | 決定 |
|---|---|
| 整體範圍 | 忠實重現原神版詳情 dialog，內容到「icon＋名稱＋簡介＋tag＋圖片切換＋外連」為止，不加進階資料 |
| dialog 版面 | 頂部 `Row(icon 64, Column(name, 簡介, tags))`；中段圖片切換 chip＋可點開放大的大圖；底部外連＋關閉（與原神版同構） |
| 名稱顏色 | 依 `qualityLevel`：5★ `tokens.fiveStar`、4★ `tokens.fourStar`、其餘 `textPrimary`（沿用現行） |
| 角色圖片切換 | **立繪（`PreviewRoleCard`）＋ 頭像/Icon（`RoleHeadIcon`，即格子用 icon）** 兩項 |
| 武器圖片切換 | **僅 Icon**（單張 → 自動隱藏 chip 列、直接放大顯示，沿用現行單 chip 行為） |
| tag 內容 | 角色 `★＋元素＋武器類型`；武器 `★＋武器類型`；道具 `★＋類型` |
| 簡介渲染 | **`flutter_html`**（武器 `BgDescription` 含 HTML 標籤；角色 `Introduction` 純文字會自然退化為純文字） |
| 外部連結 | 保留「在 encore.moe 查看」，連該物品的 encore.moe 頁；確切路由實作時驗證（見 §14） |
| 圖片來源 | 全物品 icon／立繪一律 encore.moe，移除 guide-server 與猜檔名探測 |
| 詳情抓取策略 | **方案2：更新階段預抓 per-lang 詳情索引，dialog 開啟即顯示**（與原神版 `pageByLang` 同模式） |

---

## 4. encore.moe API 對應

**API base**：`https://api-v2.encore.moe/api/{lang}`（圖片 CDN URL 由回應直接給出，host 為 `api.encore.moe` / `api-v2.encore.moe`，**一律照回應原樣使用、不自行改寫**）。

### 4-1 id 對應（已用真實資料驗證）

| 類型 | 喚取 `resourceId` | encore 端點 | encore id 欄位 | 範例 |
|---|---|---|---|---|
| 角色 | 4 碼 | `GET /{lang}/character`、`/character/{id}` | `Id` | 1503＝維里奈、1402＝秧秧 |
| 武器 | 8 碼 | `GET /{lang}/weapon`、`/weapon/{id}` | `Id`／`ItemId` | 21010074＝紋秋 |
| 道具 | — | `GET /{lang}/item`、`/item/{id}` | `Id` | 1＝聯覺經驗、3＝星聲 |

> **道具注意**：`/item` 的 `Id` 是 1／2／3 這種小序號，與喚取記錄的 `resourceId` 體系**不一致**；實務上喚取記錄只有角色／武器，道具查無 → 降級 placeholder（見 §8）。故 `/item` 端點屬 best-effort，且只在 worklist 真有 `kind:item` 項目時才打。

### 4-2 列表端點欄位（供格子 icon）

| 類型 | icon 欄位（完整 URL） |
|---|---|
| 角色 `roleList[]` | `RoleHeadIcon` |
| 武器 `weapons[]` | `Icon`（**直接給正確 URL，免猜底線檔名**） |
| 道具 `itemList[]` | `Icon` |

格子 icon 流程**只取 icon URL**；icon 為 lang-agnostic（同物品各 lang icon URL 相同）。

### 4-3 詳情端點欄位（供 dialog，更新階段預抓、per-lang）

| 用途 | 角色 `/character/{id}` | 武器 `/weapon/{id}` |
|---|---|---|
| 簡介 | `Introduction.Content`（純文字） | `BgDescription`（背景故事，**含 HTML 標籤**；對應原神 flavor desc） |
| 元素 tag | `ElementName`（如「衍射」） | — |
| 武器類型 tag | `WeaponTypeName`（如「音感儀」） | `WeaponTypeName`（如「長刃」） |
| 立繪 URL | `Skins[0].PreviewRoleCard`（全身大圖 URL，lang-agnostic） | —（武器不取立繪） |

★ tag 一律由喚取記錄的 `qualityLevel` 取得（不需詳情）。簡介／元素／武器類型為**語言相依**，故詳情**逐語言**儲存（§6-3）。

---

## 5. lang 對應（核心需求）

- encore `{lang}` 路徑參數一律帶**該帳號擷取到的 `languageCode`**（`BannerStorage.languageCode`，如 `zh-Hant`），**不看 app UI 語言**。
- 更新階段：逐帳號用各自 `languageCode` 預抓詳情（同物品出現在多語言帳號 → 各語言各抓一份，見 §6-2）。
- dialog 顯示：用**作用中帳號**語言（`gachaRepositoryProvider` 的 `state.activeData?.languageCode`）查 `detailByLang`；各顯示點（表格／時間軸／五星總覽）渲染的都是作用中帳號的 record，故此語言即該 record 的擷取語言。
- encore 支援語系白名單：`en, zh-Hans, zh-Hant, ja, ko, de, es, fr, id, pt, ru, th, vi`。
- 新增純函式 `String encoreLang(String languageCode)`：命中白名單 → 原樣回傳；未命中 → fallback `'en'`（並 warning log）。遊戲實測送 BCP-47 形式（`zh-Hant` 已由 `docs/鳴潮相關資料.md` 佐證），正常情境皆直接命中。

---

## 6. 資料來源架構

### 6-1 格子 icon（更新階段，catalog 查表）

`ItemImageFetcher` 新增「列表 catalog」：

```dart
/// 單一 lang 的 encore 列表查表結果：kind → (resourceId → icon URL)。
class EncoreCatalog {
  const EncoreCatalog({required this.iconByKindId});
  final Map<String, Map<int, String>> iconByKindId; // kItemKind* → {id → iconUrl}
  String? iconFor({required String kind, required int id}) =>
      iconByKindId[kind]?[id];
}
```

- `Future<EncoreCatalog> fetchCatalog({required String lang, required Set<String> kinds, required http.Client client})`：對 `kinds` 內出現的每個 kind 打對應列表端點（`/character`／`/weapon`／`/item`）一次，解析成 `{id → iconUrl}`。單一 kind 端點失敗（非 2xx／逾時／解析爛）→ 該 kind 回空 map（不 throw）。
- icon 為 lang-agnostic，故每個 id 只需用任一出現的 lang 解析一次 icon URL。

### 6-2 詳情預抓（更新階段，per-lang，方案2）

- 新增 `Future<EncoreItemDetail?> fetchItemDetail({required int resourceId, required String kind, required String lang, required http.Client client})`：依 kind 打 `/character/{id}` 或 `/weapon/{id}`（`kind:item` 不打、直接回 null），解析 `intro`／`elementName`／`weaponTypeName`／`illustrationUrl`（武器後兩者為空）。任何防呆失敗回 null（不 throw）。

```dart
/// dialog 用的單一 lang 詳情（只取原神版版面所需欄位）。
class EncoreItemDetail {
  const EncoreItemDetail({
    required this.intro, required this.elementName,
    required this.weaponTypeName, required this.illustrationUrl,
  });
  final String intro;            // 角色 Introduction / 武器 BgDescription（可能含 HTML）
  final String elementName;      // 角色 ElementName；武器/道具空
  final String weaponTypeName;   // 角色/武器 WeaponTypeName；道具空
  final String illustrationUrl;  // 角色 PreviewRoleCard；武器/道具空
}
```

`gacha_repository._fetchItemImages` 改造：

1. **收集**：跨所有帳號收集 `(resourceId, kind, lang)` 三元組（去重）。`kind = itemTypeKeyOf(r)`（重用 `item_type_kind.dart`）。icon 取一個代表 lang 即可；詳情需逐 (id, lang)。
2. **worklist**：`(id, kind, lang)` 需要做事的條件 ——（a）該 id 的 **icon 未就緒**（沿用 `needsItemImageFetch`：無紀錄／負取非永久／icon 快取檔遺失），或（b）該 id 的 **`detailByLang[lang]` 不存在**。
3. **取得物品資料階段**（emit `phase: checking`，並行）：依 worklist 出現的 lang 分組，每 lang 呼叫 `fetchCatalog(lang, kinds)` 一次。對每筆 `(id, kind, lang)`：
   - **icon**：若該 id icon 未就緒 → `iconUrl = catalog.iconFor(kind, id)`；非 null → 正取（`mergeIcon`）＋ 入 `toDownload`；null → 負取（`mergeIcon(noImage: true)`）。
   - **詳情**：若該 id icon 為正取、`kind != kItemKindItem`、且 `detailByLang[lang]` 不存在 → `fetchItemDetail(id, kind, lang)` → `mergeItemDetail(id, lang, detail)`。
4. **下載階段**（emit `phase: downloading`）：對 `toDownload` 下載 icon 寫檔（沿用 `itemIconCacheFile`＋`writeImageFileAtomic`＋`bumpCacheRevision`）。立繪**圖片不在此下載**（dialog lazy）。

> **成本**：詳情 API 為 **per (id, lang)**，但只對 worklist 內「該 lang 尚未抓過」的物品打 —— 與 icon 一樣**每個新 (id, lang) 只打一次**，之後快取。單語言使用者＝每物品一次（與原神版同量級）。每 lang 另有最多 3 次列表 HTTP。guide-server 與 `encoreWeaponIconUrl*` 猜檔名整段移除。

### 6-3 資料模型變更（`item_image_index.dart`）

```dart
/// 單一 lang 的 dialog 詳情（持久化）。
class ItemDetailL10n {
  const ItemDetailL10n({
    required this.intro, required this.elementName,
    required this.weaponTypeName, required this.illustrationUrl,
  });
  final String intro;
  final String elementName;
  final String weaponTypeName;
  final String illustrationUrl;
}

class ItemImageEntry {
  const ItemImageEntry({
    required this.iconUrl,
    required this.noImage,
    required this.permanentNoImage,
    this.detailByLang = const {},
  });
  final String? iconUrl;                         // lang-agnostic（移除舊 illustrationUrl）
  final bool noImage;
  final bool permanentNoImage;
  final Map<String, ItemDetailL10n> detailByLang; // 新增：per-lang 詳情
  bool get hasIcon => !noImage && iconUrl != null && iconUrl!.isNotEmpty;
}
```

- **移除** `ItemImageEntry.illustrationUrl`（立繪 URL 改存 `detailByLang[lang].illustrationUrl`）。
- **storage v1 → v2**：`items[id]` 加 `detail_by_lang: {lang: {intro, element_name, weapon_type_name, illustration_url}}`；`save` 不再寫頂層 `illustration_url`。`load` 對 `version < 2`（或缺欄）忽略舊 `illustration_url`、`detailByLang` 設 `{}` → 下次更新自然重抓詳情補齊。index 為可重生快取（已有 `clearAll`／`resetAll`），遷移風險低。
- **Notifier**（`state/item_image_index.dart`）：`mergeItemImage` → 拆 `mergeIcon({resourceId, iconUrl, noImage, permanentNoImage})`（移除 `illustrationUrl` 參數、保留既有 `detailByLang`）＋新增 `mergeItemDetail({resourceId, lang, detail})`（read-modify-write 加 `detailByLang[lang]`、保留 icon 欄位）。兩者皆走既有 `_lock` + `_saveAndEmit`。
- `itemDetailCacheFile` 不需要（詳情存 index JSON，不另存檔）；立繪圖片沿用 `itemIllustrationCacheFile`＋`deleteIllustrationCacheFiles`。

---

## 7. Dialog UI（`gacha_item_detail_dialog.dart`）

版面忠實沿用原神版（見 `f3014e3` 的 593 行版本），改用 encore 資料；詳情已預抓 → **文字即時顯示**，只有立繪**圖片** lazy 下載。

### 7-1 版型

```
┌─ AppDialog(size: md = 640, maxHeight: 880) ─────────────────┐
│ Title:                                                       │
│   Row(crossAxis: start)                                      │
│     ├ if(iconFile) ClipRRect(Image.file(icon 64×64)) + gap   │
│     └ Expanded(Column(crossAxis: start, min){                │
│          Text(name, headlineSmall, nameColor, max2 ellipsis) │
│          if(intro 非空) SizedBox(8) +                        │
│            ConstrainedBox(maxH 120, SingleChildScrollView(   │
│              Html(data: intro)))                             │
│          if(tags 非空) SizedBox(8) +                         │
│            Wrap(spacing6, runSpacing6, tags.map(Chip))       │
│       })                                                     │
├──────────────────────────────────────────────────────────── │
│ Content:                                                     │
│   if(chipEntries.length > 1) Wrap(ChoiceChip…) + gap         │
│   if(current != null) Expanded(圖區：ready→可點放大 /         │
│     loading→spinner / failed→重試)                          │
├──────────────────────────────────────────────────────────── │
│ Actions:  [↗ 在 encore.moe 查看]   [關閉]                    │
└──────────────────────────────────────────────────────────── ┘
```

### 7-2 詳情資料來源（即時）

```dart
final activeLang = ref.watch(
  gachaRepositoryProvider.select((s) => s.activeData?.languageCode),
);
final entry = index.lookupImage(record.resourceId);
final detail = (activeLang == null ? null : entry?.detailByLang[activeLang])
    ?? entry?.detailByLang.values.firstOrNull; // active lang 未抓到時退任一已抓語言
final intro = detail?.intro ?? '';
final elementName = detail?.elementName ?? '';
final weaponTypeName = detail?.weaponTypeName ?? '';
final illustrationUrl = detail?.illustrationUrl ?? '';
```

### 7-3 圖片切換（沿用現行 chip 狀態機，改資料來源）

- **角色**：chip = 立繪（`illustrationUrl`，**圖片** lazy 下載至 `itemIllustrationCacheFile`）＋ 頭像/Icon（`entry.iconUrl`，更新階段已下載、永遠 ready、永遠排最後）。
- **武器**：chip 只有 Icon → 現行邏輯自動隱藏 chip 列、直接放大顯示。
- 立繪載入 / 成功 / 失敗（重試）三態沿用現行 `_buildCurrentImageArea`；點圖開 `showZoomableImageOverlay`（既有）。

### 7-4 簡介與 tag

- **簡介**：`flutter_html` 的 `Html(data: intro)`，`ConstrainedBox(maxHeight: 120) + SingleChildScrollView` 限高；`intro.trim().isEmpty` 整塊不繪。樣式沿用原神版（`body` margin/padding 歸零、`p` margin 收緊）。encore 自訂標籤（如武器的 `<te>`）flutter_html 不識別者忽略、不 crash。
- **tag**：`Wrap` ＋半透明 `Chip`（沿用原神版樣式：`tokens.textPrimary.withValues(alpha: 0.15)` 底、`RoundedRectangleBorder(AppRadius.sm)`、`VisualDensity.compact`、`MaterialTapTargetSize.shrinkWrap`，不可點）。組裝：
  - ★：`l.rarityStar(record.qualityLevel)`（app UI 語系的稀有度星標，與全 app 一致）。
  - 元素／武器類型：`detail.elementName`／`detail.weaponTypeName`（encore 在地化、跟擷取語系）；空字串略過。
  - **刻意的語系組合**：★ 跟 app UI 語系（純星標指示、非抓取文字），元素／類型跟擷取語系（抓取文字，同原神版 desc/tags 行為）。`tags` 全空則整塊不繪。
- **可點性 `hasItemDetailContent`**：維持「icon 快取檔在即可點」（不要求詳情已抓）。詳情若該 lang 尚未抓到 → 簡介／tag/立繪不繪，仍可看 icon＋名稱（同原神版「icon 在即可點」放寬）。

### 7-5 外部連結

- actions 區左側 `TextButton.icon(Icons.open_in_new, label: l.actionViewOnEncore)`，右側 `FilledButton(關閉)`（dismiss 在右）。
- 共用 `openExternalUrl(uri)`（`lib/widgets/app_link.dart`，已含 `canLaunchUrl`＋warning＋靜默）。
- URL 由單一 helper `encoreItemUrl({kind, resourceId, name, lang})` 組裝；確切路由實作時用瀏覽器導航 encore.moe 驗證後釘死（見 §14）。

---

## 8. 錯誤處理 / 邊界

| 場景 | 處理 |
|---|---|
| 列表端點某 kind 非 2xx／逾時／解析爛 | 該 kind catalog 回空 map → 該 kind 物品落負取，下次更新重試 |
| `catalog.iconFor` 查無（新角色未上 encore／道具 id 不匹配） | 負取 placeholder（沿用現行 `noImage` 流程） |
| 詳情端點 null（404／逾時／道具不打／某 lang 抓失敗） | 該 (id, lang) `detailByLang` 不寫入；dialog 退任一已抓語言或只顯示 icon＋名稱 |
| dialog active lang 尚無詳情、其他 lang 有 | 退 `detailByLang.values.firstOrNull`（至少有東西可看） |
| 立繪**圖片**下載失敗 | 立繪 chip 顯示失敗＋重試（現行狀態機）；其餘照常 |
| 簡介含未知 HTML 標籤 | flutter_html 忽略未知標籤、渲染其餘內容 |
| `encoreLang` 未知碼 | fallback `'en'`＋warning |
| 點圖前快取檔被刪/壞 | `Image.file.errorBuilder` 讓位（現行） |
| 外連 `canLaunchUrl` 失敗 | `openExternalUrl` 內部 warning＋靜默 |

所有 I/O 與降級分支埋 `Logger('item_image.*')`，URL 經 `sanitizeUrl`、UID 經 `sanitizeUid` 後才寫 log。

---

## 9. i18n

依專案慣例：先寫繁中、以中文為基準翻其他語系；只加在已有實體翻譯的 ARB；`description` metadata 用英文；翻譯前查 `docs/術語表.md`。

| key | zh（繁中） | 用途 |
|---|---|---|
| `actionViewOnEncore` | `在 encore.moe 查看` | dialog actions 外連按鈕（「encore.moe」為品牌名不翻譯） |

- 圖片切換 chip 標籤 `galleryIllustrationLabel`（立繪）／`galleryIconLabel`（頭像/Icon）**已存在**，重用。
- ★／元素／武器類型 tag **不需新 key**：★ 用既有 `l.rarityStar(qualityLevel)`（app UI 語系）；元素／武器類型為 encore 在地化字串（跟擷取語系）。
- 新 key 只加在 `app_zh.arb`／`app_zh_Hans.arb`／`app_en.arb`／`app_ja.arb`（本專案僅這 4 個 ARB 有實體翻譯；其餘空殼由 Crowdin pipeline 補）。
- 簡介／tag 區無 section heading（無「介紹：」「標籤：」前綴）。

---

## 10. Logging（對齊既有 `item_image.*` 樹）

| Logger | 等級 | 內容範例 |
|---|---|---|
| `item_image.fetcher` | info | `'catalog lang=zh-Hant kinds=[character,weapon] chars=84 weapons=120'` |
| `item_image.fetcher` | warning | `'catalog kind=weapon non-2xx status=503 lang=zh-Hant'`／`'encoreLang unknown code=xx → en'` |
| `item_image.fetcher` | info | `'detail hit kind=character id=1503 lang=zh-Hant illustration=true'` |
| `item_image.fetcher` | warning | `'detail null kind=character id=1503 lang=zh-Hant'` |
| `item_image.notifier` | fine | `'merge detail id=1503 lang=zh-Hant intro=true tags=2'` |
| `gacha.itemimage.detail` | info | `'open encore kind=character id=1503'`（外連按鈕點擊） |

URL 一律 `sanitizeUrl(...)`；id／lang／status 非敏感原樣記錄。

---

## 11. 測試

### 11-1 Unit

| 對象 | 案例 |
|---|---|
| `encoreLang` | 白名單各碼原樣回傳／未知碼 → `en`／空字串 → `en` |
| `EncoreCatalog` 解析 | character 取 `RoleHeadIcon`／weapon 取 `Icon`／item 取 `Icon`／缺欄位 skip／空 list |
| `EncoreCatalog.iconFor` | kind＋id 命中／kind 不存在 → null／id 不存在 → null |
| `fetchCatalog` | 只打 worklist 出現的 kinds／某 kind 非 2xx → 該 kind 空 map、其餘正常／逾時不 throw |
| `fetchItemDetail` 解析 | 角色 Introduction＋ElementName＋WeaponTypeName＋PreviewRoleCard／武器 BgDescription（含 HTML 原樣保留）＋WeaponTypeName、其餘空／`kind:item` 回 null／404 回 null |
| `ItemImageIndexStorage` | v2 round trip（含 `detail_by_lang` 多語言序列化）／v1 載入忽略舊 `illustration_url`、`detailByLang` 設空、其餘欄位保留 |
| `ItemImageEntry` | 移除 illustrationUrl 後 `hasIcon` 行為不變 |

### 11-2 Notifier / Repository

| 案例 | 驗證點 |
|---|---|
| `mergeIcon` | 寫 icon 不動既有 `detailByLang`；負取／正取覆蓋 |
| `mergeItemDetail` | 寫 `detailByLang[lang]` 不動 icon；跨 lang 不互蓋；同 lang 重抓覆蓋 |
| `_fetchItemImages` catalog 查表 | 多 lang 各抓一次 catalog；icon 命中 → 正取＋下載；查無 → 負取 |
| `_fetchItemImages` 詳情預抓 | 正取物品逐 (id, lang) 打詳情、寫 `detailByLang`；`kind:item` 不打詳情；icon 負取者不打詳情 |
| kind 選端點 | `kind:character` 查 character、`kind:weapon` 查 weapon（fake catalog 驗不混表） |
| 同物品多語言帳號 | (id, langA)、(id, langB) 各抓一份詳情 |
| 取消 / 部分失敗 | 單筆失敗不終止、`isAborted` 早退（沿用現行） |

### 11-3 Widget（`GachaItemDetailDialog`）

`ProviderScope.overrides` 注入 fake index（預置 `detailByLang`）＋ fake repository（給 `activeData.languageCode`）＋ temp dir（預製假 icon／立繪）：

| 案例 | 驗證點 |
|---|---|
| 角色：詳情已預抓 | 名稱＋簡介 `Html`＋tag `Chip`（★/元素/武器類型）即時；chip 列 立繪＋頭像兩項 |
| 角色：active lang 無詳情、他 lang 有 | 退 firstOrNull 顯示 |
| 武器：簡介含 HTML | `Html` 渲染；tag 為 ★＋武器類型（無元素） |
| 武器：只有 Icon | chip 列隱藏、直接放大 icon |
| 詳情全無（icon-only） | 只剩 icon＋名稱＋關閉，無簡介/tag/立繪、不 crash |
| 立繪圖片下載失敗 | 立繪 chip 顯示失敗＋重試 |
| 外連按鈕點擊 | `openExternalUrl` 被呼叫、URL 為 encore item URL（DI/mock helper） |
| 不 vertical overflow | `setSurfaceSize(640×480)`，`takeException()` 為 null |
| tearDown | `imageCache.clear()`＋`clearLiveImages()`（跨測試 race 防護） |

### 11-4 提交前品質檢查（CLAUDE.md 強制）

1. `dart format lib/ test/`
2. `flutter analyze` → `No issues found!`
3. `flutter test` → `All tests passed!`

任一失敗先修，禁用 `--no-verify`。

---

## 12. 依賴與影響檔案

### 12-1 套件

- **重新引入 `flutter_html`**（遷移前 baseline `f3014e3` 為 `^3.0.0`）：實作時加回 `pubspec.yaml`，確認與當前 Flutter SDK 相容（必要時依 context7 查 `flutter_html` 最新相容版）。
- `url_launcher`（`^6.3.2`）已在，`openExternalUrl` 共用。不新增其他套件。

### 12-2 檔案

| 檔案 | 變更 |
|---|---|
| `pubspec.yaml` | 加回 `flutter_html` |
| `lib/services/item_image_fetcher.dart` | 移除 guide-server＋`encoreWeaponIconUrl*` 猜檔名；新增 `EncoreCatalog`／`fetchCatalog`／`EncoreItemDetail`／`fetchItemDetail`／`encoreLang` |
| `lib/services/item_image_index.dart` | `ItemImageEntry` 移除 `illustrationUrl`、加 `detailByLang`；新增 `ItemDetailL10n`；storage v1→v2 |
| `lib/state/item_image_index.dart` | `mergeItemImage` → `mergeIcon`；新增 `mergeItemDetail` |
| `lib/state/gacha_repository.dart` | `_fetchItemImages`：worklist 帶 kind＋lang；per-lang catalog 查 icon＋per-(id,lang) 預抓詳情 |
| `lib/widgets/dialogs/gacha_item_detail_dialog.dart` | 加回簡介（`Html`）＋tag＋外連；詳情由 index `detailByLang[activeLang]` 即時取；立繪 URL 來自詳情、圖片 lazy |
| `lib/l10n/app_{zh,zh_Hans,en,ja}.arb` | 新增 `actionViewOnEncore` |
| `test/services/item_image_fetcher_test.dart` | catalog／detail／encoreLang 案例 |
| `test/services/item_image_index_test.dart` | v2 round trip／v1 載入／detailByLang |
| `test/state/item_image_index_test.dart` | mergeIcon／mergeItemDetail 案例 |
| `test/state/gacha_repository_*_test.dart` | catalog 查表＋詳情預抓案例 |
| `test/widgets/dialogs/gacha_item_detail_dialog_test.dart` | 簡介（Html）／tag／武器單圖／外連／多語言退 fallback 案例 |

重用：`item_type_kind.dart`（kind 判定）、`app_link.dart`（`openExternalUrl`）、`zoomable_image_overlay.dart`、`log_sanitize.dart`、`l.rarityStar`、`gachaRepositoryProvider`（active lang）。

---

## 13. 風險與緩解

| 風險 | 緩解 |
|---|---|
| 詳情預抓使更新階段多打 per-(id,lang) API | 只對新 (id, lang) 打一次、之後快取（與 icon 同量級）；單語言使用者每物品一次 |
| index v1→v2 後首次更新重抓詳情 | icon 圖檔不刪、下載階段自動 skip；成本是詳情 API（每新物品一次） |
| 多帳號多語言 → 同物品多份詳情 | 預期行為（per-lang 忠於原神版）；儲存量小（純文字） |
| encore 列表未涵蓋最新角色/武器 | 查無 → 負取 placeholder、下次重試（同現行 fallback） |
| `flutter_html` 重新引入的相容性／體積 | baseline 已用過 `^3.0.0`；實作時 analyze/test 驗證；簡介短文字、render 成本低 |
| encore 簡介含自訂標籤（`<te>` 等） | flutter_html 忽略未知標籤、不 crash |
| encore.moe SPA 路由未來改版 | 外連 URL 單點 helper、一處可改；點擊失敗已 warning |
| `languageCode` 出現白名單外值 | `encoreLang` fallback `en`＋warning，不 throw |
| 道具 id 與 `/item` 不匹配 | 已知限制：道具降級 placeholder；不阻塞角色/武器主流程 |

---

## 14. 待實作期間決定

- **encore.moe 外連確切路由**：encore.moe 為純前端 SPA（WebFetch 無法判定路由有效性）。實作時用瀏覽器（playwright）導航 `encore.moe`，點進角色／武器頁觀察最終 URL，據此釘死 `encoreItemUrl` 組裝（id-based / name-based、是否帶 `?lang=`）。優先 id-based（最穩），不支援則退 name-based＋`?lang={encoreLang}`（name 取自喚取記錄、與 lang 同語系）。
- **encore API base host**：實作時確認 `api-v2.encore.moe/api` 與圖片 CDN host（`api.encore.moe`）皆可用；圖片一律照回應原樣 URL 下載。
- **`flutter_html` 確切版本**：實作時依 context7 查當前與 Flutter SDK 相容的版本（baseline `^3.0.0` 為起點）。
