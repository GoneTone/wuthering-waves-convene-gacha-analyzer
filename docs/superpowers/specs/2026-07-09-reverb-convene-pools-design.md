# 新增 角色憶旅喚取／武器憶旅喚取 卡池 — 設計文件

- 日期：2026-07-09
- 範圍：卡池註冊表、i18n、卡池圖示／配色、相關測試、背景資料文件、README ×4
- 相關資料：[`docs/鳴潮相關資料.md`](../../鳴潮相關資料.md)（§三 卡池類型表需補 12／13）、[`docs/術語表.md`](../../術語表.md)（憶旅譯名單一來源，已含四語對照）
- 前例：[`2026-06-06-collab-convene-pools-design.md`](2026-06-06-collab-convene-pools-design.md)（聯動池 type 10／11，本次改動面與其同構）

## 一、背景與需求

鳴潮新增兩個喚取卡池型別：**角色憶旅喚取（`cardPoolType` 12）** 與 **武器憶旅喚取（`cardPoolType` 13）**，保底為 5★ 80／4★ 10（使用者已確認，與多數池相同）。`docs/術語表.md` 已先行補上兩列譯名（en「Reverb」、ja「追憶」）。

本專案的卡池為**資料驅動**：單一 `gachaTypes` 清單（`lib/data/gacha_types.dart`）驅動擷取迭代、統計、側欄、分頁、配色等所有環節，各環節一律以 `cardPoolType` 字串或 `nameKey` 透過對照表分派。因此新增兩個型別屬**純加法擴充**——照聯動池前例各補兩筆，不動任何架構或資料流。`update_progress_dialog` 已於聯動池時改用 `GachaType.resolveName` 動態解析（commit `f2704cc`），本次自動涵蓋、無需再改。

**需求**：把 type 12／13 完整接進 App（擷取、儲存、統計、側欄、分頁、時間軸配色、四語系名稱），並同步專案內所有「10 種／10 個、迭代 `[1,…,11]`」的敘述（背景資料文件、in-code 註解、四份 README），避免文件與程式碼互相矛盾。

## 二、設計決策（使用者已確認）

1. **保底**：兩池皆 `[_pityFive80, _pityFour10]`，重用既有常數，不新增 `PityRule`。
2. **側欄順序**：兩個憶旅池接在清單尾端（type 11「武器聯動」之後），維持 `cardPoolType` 升序。
3. **圖示**：角色憶旅 `auto_stories`（翻開的回憶之書）、武器憶旅 `history_edu`（羽筆書寫歷史）；皆有 outlined（未選中）與 filled（選中）變體。呼應「憶旅／追憶」的回憶主題。
4. **配色**：角色憶旅洋紅（fuchsia）、武器憶旅灰紫（mauve），dark／light 各一組（見第三節第 4 點）；洋紅落在蘭紫與桃紅間的色相空隙，灰紫沿用「灰藍 vs 天藍」以飽和度區分的既有前例。
5. **文件一致性**：一併修正背景資料文件、in-code 註解與四份 README 的「10」殘留。

### 範圍外（YAGNI，明確不做）

- **不動擷取／攔截流程**：`rust/src/mitm.rs`、`gacha_credential.dart`、`gacha_fetcher.dart` 與 `gacha_repository.dart` 的迭代皆以 `gachaTypes` 為來源並對 `cardPoolType` 參數化，新增清單項目即自動涵蓋 12／13。
- **不做 50/50／歪保底**：與既有一致，喚取 API 不提供當期 UP。
- **憶旅池即使無紀錄仍顯示於側欄**：與新旅／聯動池同行為，不做特例隱藏。

## 三、改動清單

### 1. 卡池註冊表 `lib/data/gacha_types.dart`

- `gachaTypes` 清單尾端（type 11 之後）加入兩筆：
  - `GachaType(cardPoolType: 12, nameKey: 'gachaTypeReverbCharacter', pities: [_pityFive80, _pityFour10])`
  - `GachaType(cardPoolType: 13, nameKey: 'gachaTypeReverbWeapon', pities: [_pityFive80, _pityFour10])`
- `resolveName` switch 加兩 case：`'gachaTypeReverbCharacter' => l.gachaTypeReverbCharacter`、`'gachaTypeReverbWeapon' => l.gachaTypeReverbWeapon`。
- `cardPoolType` 欄位的 dartdoc（現述「集合 [1,2,3,4,5,6,8,9,10,11]，無 7」）更新為 `[1,2,3,4,5,6,8,9,10,11,12,13]`。

### 2. i18n `lib/l10n/{app_zh,app_zh_Hans,app_en,app_ja}.arb`

每檔新增 4 個 key（`app_zh.arb` 為 template，需附 `@` description；其餘三檔僅值）。譯名以 `docs/術語表.md` 為單一來源；各語系 Short 沿用該語系「全名 → 短名」的既有刪法（zh 去「喚取」、zh_Hans 去「唤取」、en 去「 Convene」、ja 去「集音」並保留括號後綴）：

| key | zh_Hant | zh_Hans | en | ja |
|---|---|---|---|---|
| `gachaTypeReverbCharacter` | 角色憶旅喚取 | 角色忆旅唤取 | Reverb Resonator Convene | 共鳴者集音（追憶） |
| `gachaTypeReverbWeapon` | 武器憶旅喚取 | 武器忆旅唤取 | Reverb Weapon Convene | 武器集音（追憶） |
| `gachaTypeReverbCharacterShort` | 角色憶旅 | 角色忆旅 | Reverb Resonator | 共鳴者（追憶） |
| `gachaTypeReverbWeaponShort` | 武器憶旅 | 武器忆旅 | Reverb Weapon | 武器（追憶） |

- key 位置接在既有 `gachaTypeCollabWeapon` / `gachaTypeCollabWeaponShort` 之後，維持與 `gachaTypes` 一致的順序。
- 改完跑 `fvm flutter gen-l10n` 重產 `app_localizations*.dart`，確認四個新 getter 存在。

### 3. 圖示

- `lib/widgets/gacha_type_icons.dart`（outlined，分頁標題 + 側欄未選中共用）加兩 case：
  - `'gachaTypeReverbCharacter' => Icons.auto_stories_outlined`
  - `'gachaTypeReverbWeapon' => Icons.history_edu_outlined`
- `lib/pages/app_shell.dart`：
  - `_railIconActive`（側欄選中，filled）加 `'gachaTypeReverbCharacter' => Icons.auto_stories`、`'gachaTypeReverbWeapon' => Icons.history_edu`。
  - `_railLabel`（側欄短標籤）加 `'gachaTypeReverbCharacter' => l.gachaTypeReverbCharacterShort`、`'gachaTypeReverbWeapon' => l.gachaTypeReverbWeaponShort`。

### 4. 時間軸配色 `lib/widgets/banner_colors.dart`

- `BannerColors` constructor 加兩個必填欄位 `reverbCharacter`、`reverbWeapon`（含 dartdoc，標註對應 `cardPoolType 12`／`13`）。
- `_dark`、`_light` 兩組 palette 各補一筆。
- `colorFor` switch 加 `'12' => reverbCharacter`、`'13' => reverbWeapon`。

| 卡池 | dark | light | 說明 |
|---|---|---|---|
| 角色憶旅（洋紅 fuchsia） | `0xFFE66EC6` | `0xFFB93A96` | 落在蘭紫（新旅武器）與桃紅（聯動角色）間的色相空隙 |
| 武器憶旅（灰紫 mauve） | `0xFFA08BC0` | `0xFF71589A` | 低飽和紫，沿用「灰藍 vs 天藍」以飽和度區分的前例 |

- 實作時在深淺兩模式下與既有 10 色及稀有度金 5★／紫 4★／藍 3★ 並排目視確認可區分。

### 5. 測試

**會紅、必改：**

- `test/data/gacha_types_test.dart`：
  - `gachaTypes.length` 期望 10 → 12。
  - cardPoolType 清單期望尾端加 `12, 13`。
  - 「5★80／4★10」case 的 `for (final cpt in [1, 2, 3, 4, 6, 8, 9, 10, 11])` 加入 `12, 13`。
  - nameKey 清單期望尾端加 `'gachaTypeReverbCharacter', 'gachaTypeReverbWeapon'`。
  - 測試描述字串內「10 個」更新為「12 個」。
- `test/services/overview_sections_test.dart`：`types` 期望清單尾端加 `12, 13`；描述「10 個卡池」→「12 個」。
- `test/state/gacha_repository_update_test.dart`：`expect(hitTypes, …)` 期望尾端加 `12, 13`。**實作時須確認**該檔 MockClient 對 `cardPoolType` 12／13 也回 `code: 0`。

**不會因新增而紅、但一併補齊覆蓋：**

- `test/widgets/banner_colors_test.dart`：`keys` 加 `'12', '13'`；`hasLength(10)` → `hasLength(12)`；描述「10 個」→「12 個」。
- `test/models/banner_storage_test.dart`：toJson 測試的 banners map 與期望 key set 加 `'12', '13'`；描述「10 個」→「12 個」。

> 註：`test/widgets/cards/banner_top_rarity_bars_test.dart` 以 `gachaTypes.length` 斷言，會隨清單自動適配，無需改動。

### 6. 文件與註解一致性

- `docs/鳴潮相關資料.md`：
  - §二「迭代固定集合 `[1, 2, 3, 4, 5, 6, 8, 9, 10, 11]`」改為含 12、13。
  - §三「以下 10 種型別…」「合法集合…沒有 7」改為 12 種、集合含 12、13（仍註明「無 7」），表格加兩列（12 角色憶旅喚取 80/10、13 武器憶旅喚取 80/10）。
  - §七 `cardPoolType` 值列舉同步。
- in-code 註解：`lib/state/gacha_repository.dart`、`lib/services/gacha_fetcher.dart` 的「10 個卡池」殘留（若有）→「12 個」。
- README ×4（`README.md`、`README_ZH-HANS.md`、`README_EN.md`、`README_JA-JP.md`）：各自 line 46 的「涵蓋 10 種卡池：…」清單改為 12 種，依該語系術語表譯名於尾端補上兩個憶旅池名。
- `docs/術語表.md` 已含憶旅兩列，無需再改。

## 四、驗收條件

1. `fvm flutter gen-l10n` 成功，四個新 i18n getter（`gachaTypeReverbCharacter` 等）存在。
2. `fvm dart format lib/ test/` 無變動殘留、`fvm flutter analyze` 輸出 `No issues found!`。
3. `fvm flutter test` 輸出 `All tests passed!`（含上述更新後的測試）。
4. App 側欄在「武器聯動」之後出現「角色憶旅／武器憶旅」兩列，圖示與配色正確；切到該分頁標題顯示完整名（如「角色憶旅喚取」）。
5. 專案內不再有與「12／13 兩憶旅池」矛盾的「10 種／10 個／`[1,…,11]`（不含 12/13）」殘留（測試斷言、文件內文、in-code 註解、README ×4）。
