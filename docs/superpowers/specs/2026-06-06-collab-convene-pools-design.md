# 新增 角色聯動喚取／武器聯動喚取 卡池 — 設計文件

- 日期：2026-06-06
- 範圍：卡池註冊表、i18n、卡池圖示／配色、相關測試、背景資料文件
- 相關資料：[`docs/鳴潮相關資料.md`](../../鳴潮相關資料.md)（§三 卡池類型表已含 10／11）、[`docs/術語表.md`](../../術語表.md)（聯動譯名單一來源）

## 一、背景與需求

鳴潮新增兩個喚取卡池型別：**角色聯動喚取（`cardPoolType` 10）** 與 **武器聯動喚取（`cardPoolType` 11）**，保底為 5★ 80／4★ 10（與多數池相同）。`docs/術語表.md` 與 `docs/鳴潮相關資料.md` §三的卡池表已先行補上這兩列譯名與保底數。

本專案的卡池為**資料驅動**：單一 `gachaTypes` 清單（`lib/data/gacha_types.dart`）驅動擷取迭代、統計、側欄、分頁、配色等所有環節，各環節一律以 `cardPoolType` 字串或 `nameKey` 透過對照表分派。因此新增兩個型別屬**純加法擴充**——照既有 8 池的接法各補兩筆，不動任何架構或資料流。

**需求**：把 type 10／11 完整接進 App（擷取、儲存、統計、側欄、分頁、時間軸配色、四語系名稱），並把專案內殘留「8 種／8 個、迭代 `[1,2,3,4,5,6,8,9]`」的文件內文與程式碼註解同步成含 10／11，避免文件與程式碼互相矛盾。

## 二、設計決策（使用者已確認）

1. **側欄順序**：兩個聯動池接在清單尾端（type 9「武器新旅」之後），維持 `cardPoolType` 升序，亦對齊 §三 表格順序。
2. **保底**：兩池皆 `[_pityFive80, _pityFour10]`，重用既有常數，不新增 `PityRule`。
3. **圖示**：角色聯動 `diversity_3`（聯名陣容）、武器聯動 `handshake`（聯名合作）；皆有 outlined（未選中）與 filled（選中）變體。
4. **配色**：角色聯動洋紅／玫瑰、武器聯動靛藍（dark／light 各一組，見第三節第 4 點）；已比對與既有 8 色 + 稀有度金 5★／紫 4★／藍 3★ 皆可區分。
5. **文件一致性**：一併修正背景資料文件內文與 in-code 註解的「8」殘留。

### 範圍外（YAGNI，明確不做）

- **不動擷取／攔截流程**：`rust/src/mitm.rs`、`lib/services/gacha_credential.dart`（`toRequestBody(cardPoolType)`）、`lib/services/gacha_fetcher.dart` 與 `lib/state/gacha_repository.dart` 的迭代皆以 `gachaTypes` 為來源並對 `cardPoolType` 參數化，新增清單項目即自動涵蓋 10／11，無需改邏輯。
- **不做 50/50／歪保底**：與既有一致，喚取 API 不提供當期 UP，維持只顯示保底距離與平均出貨。
- **聯動池即使無紀錄仍顯示於側欄**：與新旅池同行為，維持一致（不為「可能常常為空」做特例隱藏）。

## 三、改動清單

### 1. 卡池註冊表 `lib/data/gacha_types.dart`

- `gachaTypes` 清單尾端（type 9 之後）加入兩筆：
  - `GachaType(cardPoolType: 10, nameKey: 'gachaTypeCollabCharacter', pities: [_pityFive80, _pityFour10])`
  - `GachaType(cardPoolType: 11, nameKey: 'gachaTypeCollabWeapon', pities: [_pityFive80, _pityFour10])`
- `resolveName` switch 加兩 case：`'gachaTypeCollabCharacter' => l.gachaTypeCollabCharacter`、`'gachaTypeCollabWeapon' => l.gachaTypeCollabWeapon`。
- `cardPoolType` 欄位的 dartdoc（現述「集合 [1,2,3,4,5,6,8,9]，無 7」）更新為 `[1,2,3,4,5,6,8,9,10,11]`。

### 2. i18n `lib/l10n/{app_zh,app_zh_Hans,app_en,app_ja}.arb`

每檔新增 4 個 key（`app_zh.arb` 為 template，需附 `@` description；其餘三檔僅值）。各語系 Short 一律沿用該語系「全名 → 短名」的既有刪法（zh 去「喚取」、zh_Hans 去「唤取」、en 去「 Convene」、ja 去「集音」並保留括號後綴）：

| key | zh_Hant | zh_Hans | en | ja |
|---|---|---|---|---|
| `gachaTypeCollabCharacter` | 角色聯動喚取 | 角色联动唤取 | Collab Resonator Convene | 共鳴者集音（コラボ） |
| `gachaTypeCollabWeapon` | 武器聯動喚取 | 武器联动唤取 | Collab Weapon Convene | 武器集音（コラボ） |
| `gachaTypeCollabCharacterShort` | 角色聯動 | 角色联动 | Collab Resonator | 共鳴者（コラボ） |
| `gachaTypeCollabWeaponShort` | 武器聯動 | 武器联动 | Collab Weapon | 武器（コラボ） |

- key 位置接在既有 `gachaTypeNewVoyageWeapon` / `gachaTypeNewVoyageWeaponShort` 之後，維持與 `gachaTypes` 一致的順序。
- 改完跑 `fvm flutter gen-l10n` 重產 `app_localizations*.dart`，確認四個新 getter（`gachaTypeCollabCharacter` 等）存在。

### 3. 圖示

- `lib/widgets/gacha_type_icons.dart`（outlined，分頁標題 + 側欄未選中共用）加兩 case：
  - `'gachaTypeCollabCharacter' => Icons.diversity_3_outlined`
  - `'gachaTypeCollabWeapon' => Icons.handshake_outlined`
- `lib/pages/app_shell.dart`：
  - `_railIconActive`（側欄選中，filled）加 `'gachaTypeCollabCharacter' => Icons.diversity_3`、`'gachaTypeCollabWeapon' => Icons.handshake`。
  - `_railLabel`（側欄短標籤）加 `'gachaTypeCollabCharacter' => l.gachaTypeCollabCharacterShort`、`'gachaTypeCollabWeapon' => l.gachaTypeCollabWeaponShort`。

### 4. 時間軸配色 `lib/widgets/banner_colors.dart`

- `BannerColors` constructor 加兩個必填欄位 `collabCharacter`、`collabWeapon`（含 dartdoc，標註對應 `cardPoolType 10`／`11`）。
- `_dark`、`_light` 兩組 palette 各補一筆。
- `colorFor` switch 加 `'10' => collabCharacter`、`'11' => collabWeapon`。

| 卡池 | dark | light |
|---|---|---|
| 角色聯動（洋紅／玫瑰 magenta） | `0xFFE5689E` | `0xFFC23E7E` |
| 武器聯動（靛藍 indigo） | `0xFF6F6BE0` | `0xFF4A46C2` |

### 5. 測試

**會紅、必改：**

- `test/data/gacha_types_test.dart`：
  - `gachaTypes.length` 期望 8 → 10。
  - cardPoolType 清單期望尾端加 `10, 11`。
  - 「5★80／4★10」case 的 `for (final cpt in [1, 2, 3, 4, 6, 8, 9])` 加入 `10, 11`。
  - nameKey 清單期望尾端加 `'gachaTypeCollabCharacter', 'gachaTypeCollabWeapon'`。
  - 測試描述字串內「8 個」更新為「10 個」。
- `test/services/overview_sections_test.dart`：`types` 期望清單尾端加 `10, 11`；描述「8 個卡池」→「10 個」。
- `test/state/gacha_repository_update_test.dart`：`expect(hitTypes, …)` 期望尾端加 `10, 11`。**實作時須確認**該檔 MockClient 對 `cardPoolType` 10／11 也回 `code: 0`（多半是不分型別回同一 `_ok`，但需核對，避免新池被 mock 當失敗）。

**不會因新增而紅、但一併補齊覆蓋（維持「8」殘留一致性）：**

- `test/widgets/banner_colors_test.dart`：`keys` 加 `'10', '11'`；`hasLength(8)` → `hasLength(10)`；描述「8 個」→「10 個」。
- `test/models/banner_storage_test.dart`：toJson 測試的 banners map 與期望 key set 加 `'10', '11'`；描述「8 個」→「10 個」。

> 註：`test/widgets/cards/banner_top_rarity_bars_test.dart` 以 `gachaTypes.length` 斷言，會隨清單自動適配，無需改動。

### 6. 文件與註解一致性

- `docs/鳴潮相關資料.md`：
  - §二 line 71（迭代固定集合 `[1, 2, 3, 4, 5, 6, 8, 9]`）。
  - §三 line 178（「以下 8 種型別…」與「合法集合為 `[1, 2, 3, 4, 5, 6, 8, 9]`，沒有 7」）。
  - §七 line 265（`cardPoolType` 值列舉 `[1,2,3,4,5,6,8,9]`）。
  - 上述三處 prose 改為含 10、11（型別數改 10，集合改 `[1,2,3,4,5,6,8,9,10,11]`，仍註明「無 7」）。
- in-code 註解：
  - `lib/state/gacha_repository.dart` line 31、370「8 個卡池」→「10 個卡池」。
  - `lib/services/gacha_fetcher.dart` line 42「夾在 8 個 cardPoolType 之間」→「10 個」。

## 四、驗收條件

1. `fvm flutter gen-l10n` 成功，四個新 i18n getter 存在。
2. `fvm dart format lib/ test/` 無變動殘留、`fvm flutter analyze` 輸出 `No issues found!`。
3. `fvm flutter test` 輸出 `All tests passed!`（含上述更新後的測試）。
4. App 側欄在「新旅」之後出現「角色聯動／武器聯動」兩列，圖示與配色正確；切到該分頁標題顯示完整名（如「角色聯動喚取」）。
5. 專案內不再有與「10／11 兩聯動池」矛盾的「8 種／8 個／`[1,2,3,4,5,6,8,9]`（不含 10/11）」殘留（測試斷言、文件內文、in-code 註解）。
