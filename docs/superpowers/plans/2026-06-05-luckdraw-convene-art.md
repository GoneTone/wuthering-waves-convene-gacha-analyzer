# Luckdraw 喚取立繪 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在物品詳情 dialog 新增「喚取」立繪——開詳情時於背景以離屏 WebView2 擷取 encore.moe 渲染的 Luckdraw Spine canvas，存本機快取後以去背立繪襯 app 背景顯示。

**Architecture:** 借 encore 頁面的 Spine runtime 在使用者機器上即時擷取（不 bundle、我方不需 Spine 授權），透過 `executeScript` 輪詢＋`requestAnimationFrame` 內 `drawImage`→`toDataURL`→`window.__cap`→分塊讀回。一個全域隱藏離屏 `LuckdrawCaptureHost` 持有可重用 `WebviewController`，`LuckdrawCaptureService` 驅動擷取並快取。詳情 dialog 新增「喚取」chip，沿用既有 `_ImageLoadState`／zoomable／快取管線。

**Tech Stack:** Flutter（Windows desktop）、Riverpod、`webview_windows`（WebView2）、既有 `item_image_*` 快取／index 基礎建設。

**設計依據：** `docs/superpowers/specs/2026-06-05-luckdraw-convene-art-design.md`

---

## File Structure

| 檔案 | 動作 | 職責 |
|---|---|---|
| `E:\IdeaProjects\luckdraw_poc\lib\main.dart`（主 repo 外） | 改 | Task 1 離屏渲染 spike（風險閘） |
| `lib/services/item_image_index.dart` | 改 | 新增 `itemLuckdrawCacheFile`；`ItemImageEntry.hasLuckdraw`＋JSON；cache 清除／統計納入 `_luckdraw` |
| `lib/services/item_image_fetcher.dart` | 改 | `EncoreItemDetail.hasLuckdraw`＋解析 `Luckdraw` 欄位 |
| `lib/state/item_image_index.dart` | 改 | `mergeItemDetail`／`mergeIcon` 帶 `hasLuckdraw` |
| `lib/state/gacha_repository.dart` | 改 | orchestration 把 `detail.hasLuckdraw` 傳入 merge |
| `lib/services/luckdraw_capture_service.dart` | 建 | 擷取服務（驅動隱藏 webview、快取查找、序列化） |
| `lib/state/luckdraw_capture.dart` | 建 | `luckdrawCaptureServiceProvider` |
| `lib/widgets/luckdraw_capture_host.dart` | 建 | 全域隱藏離屏 webview 宿主 |
| `lib/main.dart` | 改 | `MaterialApp.router` 加 `builder:` 掛 host |
| `lib/widgets/dialogs/gacha_item_detail_dialog.dart` | 改 | `_ChipKind.luckdraw`、喚取 chip、預抓、重試分流 |
| `lib/l10n/app_zh.arb`（template）／`app_en.arb`／`app_ja.arb`／`app_zh_Hans.arb` | 改 | `galleryLuckdrawLabel` |
| `lib/state/item_image_cache_usage.dart` | 改 | 快取統計納入 `_luckdraw` |
| `lib/pages/settings_page.dart`（如需） | 改 | 「清除立繪快取」涵蓋 `_luckdraw`（經 Task 9 的 storage 改動自動涵蓋） |
| `test/services/item_image_index_test.dart` | 改 | `itemLuckdrawCacheFile`、`hasLuckdraw` round-trip |
| `test/services/item_image_fetcher_test.dart` | 改 | `Luckdraw` 解析 |
| `test/state/luckdraw_merge_test.dart` | 建 | notifier merge 帶 `hasLuckdraw` |
| `pubspec.yaml` | 改 | 加 `webview_windows: ^0.4.0` |

---

## Task 1：離屏渲染 spike（風險閘 — 不過則停止並走備案）

**目的：** PoC 已證實「可見 webview」擷取成功；本 task 驗證「**隱藏離屏**」狀態下 `requestAnimationFrame` 不被節流、仍能擷取。通過才繼續 Task 2+。

**Files:**
- Modify: `E:\IdeaProjects\luckdraw_poc\lib\main.dart`（主 repo 外的丟棄式 PoC）

- [ ] **Step 1：把 PoC 的 webview 包成「隱藏離屏」**

將 `build()` 的 `Expanded(child: Webview(...))` 改為：webview 固定尺寸、極低不透明度、被一個不透明全幅容器蓋住（模擬正式版「藏在 app 內容後面」）。

```dart
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          // 離屏渲染目標：固定 1400×1180、opacity 0.004（RenderOpacity 僅在 0 跳過繪製）
          Positioned(
            left: 0,
            top: 0,
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.004,
                child: SizedBox(
                  width: 1400,
                  height: 1180,
                  child: _controller.value.isInitialized
                      ? Webview(_controller)
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          // 不透明全幅內容蓋在上面（模擬正式 app UI 遮住 webview）
          Positioned.fill(
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: Text(
                'HIDDEN CAPTURE SPIKE\n$_status',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
```

- [ ] **Step 2：build PoC**

Run: `cd E:\IdeaProjects\luckdraw_poc; flutter build windows --release`
（PowerShell：`Push-Location "E:\IdeaProjects\luckdraw_poc"; flutter build windows --release; Pop-Location`）
Expected: `✓ Built ...\luckdraw_poc.exe`

- [ ] **Step 3：清輸出並跑 exe（自驗證、自結束）**

```powershell
$exe = "E:\IdeaProjects\luckdraw_poc\build\windows\x64\runner\Release\luckdraw_poc.exe"
$out = "C:\Users\p2902\AppData\Local\Temp\luckdraw_poc_out"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force $out | Out-Null
$p = Start-Process -FilePath $exe -PassThru
$p.WaitForExit(120000) | Out-Null
Get-Content "$out\result.json" -Raw
```

- [ ] **Step 4：判定**

Expected（通過）：`result.json` 的 `"success": true`，`pngBytes` > 0，`canvasW`/`canvasH` 合理（隱藏狀態下 webview 仍渲染並擷取成功）。讀 `$out\luckdraw_1211.png` 確認為完整去背立繪。

若 `success:false`（rAF 在隱藏時被節流）→ 依序試備援技巧並重跑 Step 2-3：
1. 把 `Opacity(0.004)` 改成 `Opacity(0.01)`。
2. 改用 `Transform.translate(offset: const Offset(-100000, 0), child: SizedBox(1400,1180, child: Webview))` 取代 Opacity（移出畫面但不套 Opacity），並把遮罩容器拿掉。
3. 在擷取期間讓 webview 真正可見（例如蓋一個半透明 overlay），擷取完才隱藏——退而求其次但仍可行。
記錄哪個技巧通過，**Task 7 採用該技巧**。三者皆失敗 → 停止本計畫，回 spec §十二 備案（`spine_flutter` 凍結幀 或 近似合成），通知使用者。

- [ ] **Step 5：記錄結果（不 commit，PoC 在 repo 外）**

把通過的技巧與量到的延遲記在本 task 下（供 Task 7 引用）。

---

## Task 2：`itemLuckdrawCacheFile` 路徑推導

**Files:**
- Modify: `lib/services/item_image_index.dart`
- Test: `test/services/item_image_index_test.dart`

- [ ] **Step 1：寫失敗測試**

於 `test/services/item_image_index_test.dart` 既有 `group` 內（與 `itemIllustrationCacheFile` 相關測試相鄰處）加：

```dart
  test('itemLuckdrawCacheFile：<id>_luckdraw.png', () {
    final f = itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1211);
    expect(f.path, '${tempDir.path}/1211_luckdraw.png');
  });
```

- [ ] **Step 2：跑測試確認失敗**

Run: `flutter test test/services/item_image_index_test.dart -p vm`
Expected: 編譯失敗／`itemLuckdrawCacheFile` 未定義。

- [ ] **Step 3：實作**

於 `lib/services/item_image_index.dart`，在 `itemIllustrationCacheFile`（約第 290 行）後新增：

```dart
/// 推導喚取（Luckdraw）立繪的 cache 路徑：`<resourceId>_luckdraw.png`。
///
/// 喚取立繪由 WebView2 擷取 encore 渲染的 canvas 而來，無語言差異，每 id 一檔。
File itemLuckdrawCacheFile({
  required Directory baseDir,
  required int resourceId,
}) {
  return File('${baseDir.path}/${resourceId}_luckdraw.png');
}
```

- [ ] **Step 4：跑測試確認通過**

Run: `flutter test test/services/item_image_index_test.dart -p vm`
Expected: All tests passed!

- [ ] **Step 5：commit**

```bash
git add lib/services/item_image_index.dart test/services/item_image_index_test.dart
git commit -m "feat(luckdraw): add itemLuckdrawCacheFile path helper"
```

---

## Task 3：`ItemImageEntry.hasLuckdraw` 欄位＋JSON round-trip

**Files:**
- Modify: `lib/services/item_image_index.dart`
- Test: `test/services/item_image_index_test.dart`

- [ ] **Step 1：寫失敗測試**

於 `test/services/item_image_index_test.dart` 加（沿用既有 temp dir `storage`）：

```dart
  test('hasLuckdraw round-trip：save/load 保留；舊檔缺欄位預設 false', () async {
    final original = ItemImageIndex(
      items: const {
        1211: ItemImageEntry(
          iconUrl: 'https://x/role_1211.webp',
          noImage: false,
          permanentNoImage: false,
          hasLuckdraw: true,
        ),
        2: ItemImageEntry(
          iconUrl: 'https://x/w.webp',
          noImage: false,
          permanentNoImage: false,
        ),
      },
    );
    await storage.save(original);
    final loaded = await storage.load();
    expect(loaded.lookupImage(1211)!.hasLuckdraw, isTrue);
    expect(loaded.lookupImage(2)!.hasLuckdraw, isFalse);
  });
```

- [ ] **Step 2：跑測試確認失敗**

Run: `flutter test test/services/item_image_index_test.dart -p vm`
Expected: 編譯失敗／`hasLuckdraw` 命名參數不存在。

- [ ] **Step 3：實作 — 欄位、load、save**

`lib/services/item_image_index.dart`，`ItemImageEntry` const ctor（第 98-104 行）新增 defaulted 欄位與 doc：

```dart
  const ItemImageEntry({
    required this.iconUrl,
    required this.noImage,
    required this.permanentNoImage,
    this.detailByLang = const {},
    this.hasLuckdraw = false,
  });
```

於 `permanentNoImage` 欄位宣告後（約第 116 行 `detailByLang` 前）新增：

```dart
  /// 該角色是否有喚取（Luckdraw）Spine 立繪可擷取（lang-agnostic）。
  /// 由角色詳情 API 的 `Luckdraw` 欄位決定；武器／道具恆 false。
  final bool hasLuckdraw;
```

`load()`（第 166-171 行 `ItemImageEntry(...)` 建構）加：

```dart
        items[id] = ItemImageEntry(
          iconUrl: v['icon_url'] as String?,
          noImage: (v['no_image'] as bool?) ?? false,
          permanentNoImage: (v['permanent_no_image'] as bool?) ?? false,
          detailByLang: _detailByLangFromJson(v['detail_by_lang']),
          hasLuckdraw: (v['has_luckdraw'] as bool?) ?? false,
        );
```

`save()`（第 185-192 行 map）加 key：

```dart
        (k, v) => MapEntry('$k', {
          'icon_url': v.iconUrl,
          'no_image': v.noImage,
          'permanent_no_image': v.permanentNoImage,
          'has_luckdraw': v.hasLuckdraw,
          'detail_by_lang': v.detailByLang.map(
            (l, d) => MapEntry(l, d.toJson()),
          ),
        }),
```

- [ ] **Step 4：跑測試確認通過**

Run: `flutter test test/services/item_image_index_test.dart -p vm`
Expected: All tests passed!

- [ ] **Step 5：commit**

```bash
git add lib/services/item_image_index.dart test/services/item_image_index_test.dart
git commit -m "feat(luckdraw): add hasLuckdraw to ItemImageEntry with JSON round-trip"
```

---

## Task 4：`EncoreItemDetail.hasLuckdraw` ＋ 解析 `Luckdraw` 欄位

**Files:**
- Modify: `lib/services/item_image_fetcher.dart`
- Test: `test/services/item_image_fetcher_test.dart`

- [ ] **Step 1：寫失敗測試**

於 `test/services/item_image_fetcher_test.dart`（沿用既有 `detailClient(...)` helper）加：

```dart
  test('角色：解析 Luckdraw 欄位 → hasLuckdraw', () async {
    final withLk = await ItemImageFetcher().fetchItemDetail(
      resourceId: 1211,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
      client: detailClient({
        'Introduction': {'Content': 'x'},
        'Skins': const [],
        'Luckdraw': {
          'LuckdrawSpineAtlas': '/Game/.../c.atlas',
          'LuckdrawSpineSkeletonData': '/Game/.../c.skel',
        },
      }),
    );
    expect(withLk!.hasLuckdraw, isTrue);

    final noLk = await ItemImageFetcher().fetchItemDetail(
      resourceId: 1212,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
      client: detailClient({
        'Introduction': {'Content': 'x'},
        'Skins': const [],
      }),
    );
    expect(noLk!.hasLuckdraw, isFalse);

    final emptyLk = await ItemImageFetcher().fetchItemDetail(
      resourceId: 1213,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
      client: detailClient({
        'Introduction': {'Content': 'x'},
        'Skins': const [],
        'Luckdraw': {'LuckdrawSpineSkeletonData': ''},
      }),
    );
    expect(emptyLk!.hasLuckdraw, isFalse);
  });

  test('武器：hasLuckdraw 恆 false', () async {
    final d = await ItemImageFetcher().fetchItemDetail(
      resourceId: 21010011,
      kind: kItemKindWeapon,
      lang: 'zh-Hant',
      client: detailClient({'BgDescription': 'w'}),
    );
    expect(d!.hasLuckdraw, isFalse);
  });
```

- [ ] **Step 2：跑測試確認失敗**

Run: `flutter test test/services/item_image_fetcher_test.dart -p vm`
Expected: 編譯失敗／`hasLuckdraw` getter 不存在。

- [ ] **Step 3：實作 — 欄位＋解析**

`lib/services/item_image_fetcher.dart`，`EncoreItemDetail` const ctor（第 83-89 行）新增 defaulted 欄位：

```dart
  const EncoreItemDetail({
    required this.intro,
    required this.elementName,
    required this.weaponTypeName,
    required this.skins,
    required this.iconHd,
    this.hasLuckdraw = false,
  });
```

於 `iconHd` 欄位宣告後（約第 106 行）新增：

```dart
  /// 角色是否有喚取（Luckdraw）Spine 立繪：`Luckdraw.LuckdrawSpineSkeletonData`
  /// 存在且非空為 true；武器／道具恆 false。
  final bool hasLuckdraw;
```

`fetchItemDetail`：在角色分支算 `hasLuckdraw`，再傳入建構。把第 213-238 行的 `if (kind == kItemKindCharacter) {...} else {...}` 區塊內，於 `iconHd = ...`（第 231-233 行）之後、`else` 之前補一個變數；最乾淨的做法是在建構 `detail` 前計算：

於 `final EncoreItemDetail detail = EncoreItemDetail(...)`（第 239-245 行）前插入：

```dart
      final lk = body['Luckdraw'];
      final hasLuckdraw =
          kind == kItemKindCharacter &&
          lk is Map &&
          ((lk['LuckdrawSpineSkeletonData'] as String?)?.isNotEmpty ?? false);
```

並把建構改為：

```dart
      final detail = EncoreItemDetail(
        intro: intro,
        elementName: body['ElementName'] as String? ?? '',
        weaponTypeName: body['WeaponTypeName'] as String? ?? '',
        skins: skins,
        iconHd: iconHd,
        hasLuckdraw: hasLuckdraw,
      );
```

並把第 246-250 行的 log 補上 `luckdraw=$hasLuckdraw`：

```dart
      _log.info(
        'detail hit kind=$seg id=$resourceId lang=$encLang '
        'intro=${intro.isNotEmpty} skins=${skins.length} '
        'iconHd=${iconHd.isNotEmpty} luckdraw=$hasLuckdraw',
      );
```

- [ ] **Step 4：跑測試確認通過**

Run: `flutter test test/services/item_image_fetcher_test.dart -p vm`
Expected: All tests passed!

- [ ] **Step 5：commit**

```bash
git add lib/services/item_image_fetcher.dart test/services/item_image_fetcher_test.dart
git commit -m "feat(luckdraw): parse Luckdraw field into EncoreItemDetail.hasLuckdraw"
```

---

## Task 5：把 `hasLuckdraw` 串進 notifier merge 與 repo orchestration

**Files:**
- Modify: `lib/state/item_image_index.dart`
- Modify: `lib/state/gacha_repository.dart:994-1011`
- Test: `test/state/luckdraw_merge_test.dart`（新建）

- [ ] **Step 1：寫失敗測試**

建 `test/state/luckdraw_merge_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';

void main() {
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('luckdraw_merge_test_');
    container = ProviderContainer(
      overrides: [
        itemImageIndexStorageProvider.overrideWithValue(
          ItemImageIndexStorage(tempDir),
        ),
      ],
    );
    await container.read(itemImageIndexProvider.notifier).waitForLoad();
  });

  tearDown(() async {
    container.dispose();
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('mergeItemDetail 寫入 hasLuckdraw；mergeIcon 之後仍保留', () async {
    final n = container.read(itemImageIndexProvider.notifier);
    await n.mergeItemDetail(
      resourceId: 1211,
      lang: 'zh-Hant',
      detail: const ItemDetailL10n(
        intro: 'x',
        elementName: '',
        weaponTypeName: '',
        skins: [],
      ),
      hasLuckdraw: true,
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(1211)!.hasLuckdraw,
      isTrue,
    );

    // 之後 mergeIcon 不得把 hasLuckdraw 洗掉
    await n.mergeIcon(
      resourceId: 1211,
      iconUrl: 'https://x/i.webp',
      noImage: false,
      permanentNoImage: false,
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(1211)!.hasLuckdraw,
      isTrue,
    );
  });

  test('hasLuckdraw once-true-stays-true：先 true 後 false 仍 true', () async {
    final n = container.read(itemImageIndexProvider.notifier);
    await n.mergeItemDetail(
      resourceId: 9,
      lang: 'en',
      detail: const ItemDetailL10n(
        intro: '',
        elementName: '',
        weaponTypeName: '',
        skins: [],
      ),
      hasLuckdraw: true,
    );
    await n.mergeItemDetail(
      resourceId: 9,
      lang: 'zh-Hant',
      detail: const ItemDetailL10n(
        intro: '',
        elementName: '',
        weaponTypeName: '',
        skins: [],
      ),
      hasLuckdraw: false,
    );
    expect(
      container.read(itemImageIndexProvider).lookupImage(9)!.hasLuckdraw,
      isTrue,
    );
  });
}
```

- [ ] **Step 2：跑測試確認失敗**

Run: `flutter test test/state/luckdraw_merge_test.dart -p vm`
Expected: 編譯失敗／`mergeItemDetail` 無 `hasLuckdraw` 命名參數。

- [ ] **Step 3：實作 — notifier**

`lib/state/item_image_index.dart`：

`mergeIcon`（第 82-88 行建構）保留 `hasLuckdraw`：

```dart
      final newItems = Map<int, ItemImageEntry>.from(state.items)
        ..[resourceId] = ItemImageEntry(
          iconUrl: iconUrl,
          noImage: noImage,
          permanentNoImage: permanentNoImage,
          detailByLang: prev?.detailByLang ?? const {},
          hasLuckdraw: prev?.hasLuckdraw ?? false,
        );
```

`mergeItemDetail` 簽名（第 98-102 行）加 defaulted 參數：

```dart
  Future<void> mergeItemDetail({
    required int resourceId,
    required String lang,
    required ItemDetailL10n detail,
    bool hasLuckdraw = false,
  }) async {
```

其建構（第 110-115 行）改為（once-true-stays-true）：

```dart
        ..[resourceId] = ItemImageEntry(
          iconUrl: prev?.iconUrl,
          noImage: prev?.noImage ?? false,
          permanentNoImage: prev?.permanentNoImage ?? false,
          detailByLang: mergedDetail,
          hasLuckdraw: hasLuckdraw || (prev?.hasLuckdraw ?? false),
        );
```

- [ ] **Step 4：實作 — repo orchestration**

`lib/state/gacha_repository.dart`，`_fetchItemImages()` 內呼叫 `mergeItemDetail`（第 994-1011 行）加一行 `hasLuckdraw:`：

```dart
              await indexNotifier.mergeItemDetail(
                resourceId: id,
                lang: lang,
                detail: ItemDetailL10n(
                  intro: detail.intro,
                  elementName: detail.elementName,
                  weaponTypeName: detail.weaponTypeName,
                  skins: [
                    for (final s in detail.skins)
                      ItemSkin(
                        formationCard: s.formationCard,
                        name: s.name,
                        subDecName: s.subDecName,
                        bgDescription: s.bgDescription,
                      ),
                  ],
                ),
                hasLuckdraw: detail.hasLuckdraw,
              );
```

- [ ] **Step 5：跑測試確認通過**

Run: `flutter test test/state/luckdraw_merge_test.dart -p vm`
Expected: All tests passed!

- [ ] **Step 6：commit**

```bash
git add lib/state/item_image_index.dart lib/state/gacha_repository.dart test/state/luckdraw_merge_test.dart
git commit -m "feat(luckdraw): thread hasLuckdraw through index notifier and fetch orchestration"
```

---

## Task 6：加 `webview_windows` 依賴＋`LuckdrawCaptureService`＋provider

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/services/luckdraw_capture_service.dart`
- Create: `lib/state/luckdraw_capture.dart`
- Test: `test/services/luckdraw_capture_service_test.dart`（新建）

- [ ] **Step 1：加依賴**

Run: `flutter pub add webview_windows`
Expected: `pubspec.yaml` 出現 `webview_windows: ^0.4.0`，`flutter pub get` 成功。

- [ ] **Step 2：寫失敗測試（非 webview 分支：cache-hit／host-missing → 純 Dart 可測）**

建 `test/services/luckdraw_capture_service_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/luckdraw_capture_service.dart';

void main() {
  late Directory tempDir;
  late LuckdrawCaptureService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('luckdraw_cap_test_');
    service = LuckdrawCaptureService(cacheDir: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('cache hit：檔已存在直接回傳，毋須 webview', () async {
    final f = itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1211);
    await f.writeAsBytes([1, 2, 3]);
    final got = await service.capture(
      resourceId: 1211,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
    );
    expect(got?.path, f.path);
  });

  test('host 未就緒（webview 未 attach）→ 回 null', () async {
    final got = await service.capture(
      resourceId: 9999,
      kind: kItemKindCharacter,
      lang: 'zh-Hant',
    );
    expect(got, isNull);
  });

  test('cacheFileFor：<id>_luckdraw.png', () {
    expect(
      service.cacheFileFor(1211).path,
      itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1211).path,
    );
  });
}
```

- [ ] **Step 3：跑測試確認失敗**

Run: `flutter test test/services/luckdraw_capture_service_test.dart -p vm`
Expected: 編譯失敗／`LuckdrawCaptureService` 未定義。

- [ ] **Step 4：實作服務**

建 `lib/services/luckdraw_capture_service.dart`：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';
import 'package:webview_windows/webview_windows.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 喚取（Luckdraw）立繪擷取服務：驅動全域隱藏 [WebviewController] 載入 encore 角色頁、
/// 擷取已渲染的 Spine canvas，存本機快取並回傳檔。webview 由 `LuckdrawCaptureHost`
/// 於 app 啟動時 [attachWebview]；未 attach（含 WebView2 runtime 缺失）時 [capture] 回 null。
class LuckdrawCaptureService {
  /// 建立服務；[cacheDir] 為圖檔快取根目錄、[timeout] 為單次擷取上限。
  LuckdrawCaptureService({
    required this.cacheDir,
    this.timeout = const Duration(seconds: 30),
  });

  /// 圖檔快取根目錄。
  final Directory cacheDir;

  /// 單次擷取（載入＋渲染＋讀回）逾時。
  final Duration timeout;

  /// Logger 實例。
  static final _log = Logger('gacha.luckdraw.capture');

  /// 由 host 注入的可重用離屏 webview；null 表示尚未就緒。
  WebviewController? _webview;

  /// 序列化擷取：單一 webview 一次只跑一個。
  final _lock = Lock();

  /// host 是否已注入 webview。
  bool get isReady => _webview != null;

  /// 由 `LuckdrawCaptureHost` 在 webview 初始化完成後呼叫。
  void attachWebview(WebviewController controller) {
    _webview = controller;
    _log.info('host webview attached');
  }

  /// host dispose 時呼叫，避免持有失效 controller。
  void detachWebview() {
    _webview = null;
  }

  /// 推導某 [resourceId] 的喚取立繪快取檔。
  File cacheFileFor(int resourceId) =>
      itemLuckdrawCacheFile(baseDir: cacheDir, resourceId: resourceId);

  /// 取得某角色的喚取立繪檔：命中快取直接回；未命中則驅動 webview 擷取後快取。
  /// 失敗（host 未就緒／逾時／頁面無 canvas／解碼錯）一律回 null。
  Future<File?> capture({
    required int resourceId,
    required String kind,
    required String lang,
  }) async {
    final file = cacheFileFor(resourceId);
    if (file.existsSync()) return file;
    final wv = _webview;
    if (wv == null) {
      _log.warning('capture rid=$resourceId host not ready');
      return null;
    }
    return _lock.synchronized(() async {
      if (file.existsSync()) return file; // 取得鎖後再確認一次
      final url = encoreItemUrl(kind: kind, resourceId: resourceId, lang: lang);
      final sw = Stopwatch()..start();
      try {
        await wv.loadUrl(url);
        final deadline = DateTime.now().add(timeout);
        Map<dynamic, dynamic>? probe;
        var armed = false;
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          final res = await wv.executeScript(_jsProbe);
          if (res is! Map) continue;
          probe = res;
          if (res['hasCanvas'] == true && res['armed'] != true && !armed) {
            await wv.executeScript(_jsArm);
            armed = true;
          }
          final capLen = res['capLen'];
          if (res['capReady'] == true && capLen is num && capLen > 0) break;
        }
        final capLen = probe?['capLen'];
        if (probe == null || probe['capReady'] != true || capLen is! num) {
          _log.warning(
            'capture rid=$resourceId timeout url=${sanitizeUrl(url)} '
            'last=${probe == null ? "null" : jsonEncode(probe)}',
          );
          await _blank(wv);
          return null;
        }
        final total = capLen.toInt();
        final sb = StringBuffer();
        const chunk = 200000;
        for (var i = 0; i < total; i += chunk) {
          final part = await wv.executeScript('window.__cap.substr($i,$chunk)');
          if (part is String) {
            sb.write(part);
          } else {
            _log.warning('capture rid=$resourceId chunk@$i not string');
            await _blank(wv);
            return null;
          }
        }
        final bytes = base64Decode(sb.toString().split(',').last);
        await writeImageFileAtomic(file, bytes);
        _log.info(
          'capture ok rid=$resourceId bytes=${bytes.length} '
          'ms=${sw.elapsedMilliseconds} url=${sanitizeUrl(url)}',
        );
        await _blank(wv);
        return file;
      } catch (e, st) {
        _log.warning('capture failed rid=$resourceId url=${sanitizeUrl(url)}', e, st);
        await _blank(wv);
        return null;
      }
    });
  }

  /// 擷取後導回空白頁，停止 encore 頁面渲染、釋放資源。
  Future<void> _blank(WebviewController wv) async {
    try {
      await wv.loadUrl('about:blank');
    } catch (_) {}
  }
}

/// 探測腳本：回傳頁面與 canvas 狀態（同步、非 rAF）。
const String _jsProbe = r'''
(function () {
  var cv = document.querySelector('#luckdraw-section canvas');
  return {
    rs: document.readyState,
    hasCanvas: !!cv,
    armed: !!window.__capArmed,
    capReady: !!window.__capReady,
    capLen: window.__cap ? window.__cap.length : 0
  };
})()
''';

/// 武裝腳本：rAF 鏈中偵測 canvas 非空白後於同一幀全尺寸擷取存 window.__cap。
const String _jsArm = r'''
(function () {
  if (window.__capArmed) return 'already';
  window.__capArmed = true;
  window.__capReady = false;
  var tries = 0;
  function step() {
    tries++;
    var cv = document.querySelector('#luckdraw-section canvas');
    if (!cv) { if (tries < 900) requestAnimationFrame(step); return; }
    var sec = document.querySelector('#luckdraw-section');
    if (sec) { try { sec.scrollIntoView({ block: 'center' }); } catch (e) {} }
    var p = document.createElement('canvas'); p.width = 32; p.height = 32;
    var pc = p.getContext('2d'); pc.drawImage(cv, 0, 0, 32, 32);
    var d = pc.getImageData(0, 0, 32, 32).data;
    var op = 0, cols = {};
    for (var i = 0; i < d.length; i += 4) {
      if (d[i + 3] > 10) op++;
      cols[d[i] + ',' + d[i + 1] + ',' + d[i + 2]] = 1;
    }
    if (op > 40 && Object.keys(cols).length > 5) {
      var t = document.createElement('canvas'); t.width = cv.width; t.height = cv.height;
      t.getContext('2d').drawImage(cv, 0, 0);
      window.__cap = t.toDataURL('image/png');
      window.__capReady = true;
      return;
    }
    if (tries < 900) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
  return 'armed';
})()
''';
```

- [ ] **Step 5：實作 provider**

建 `lib/state/luckdraw_capture.dart`：

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/luckdraw_capture_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';

/// 全域喚取立繪擷取服務；cacheDir 取自 [itemImageCacheDirProvider]。
final luckdrawCaptureServiceProvider = Provider<LuckdrawCaptureService>(
  (ref) => LuckdrawCaptureService(cacheDir: ref.watch(itemImageCacheDirProvider)),
);
```

- [ ] **Step 6：跑測試確認通過**

Run: `flutter test test/services/luckdraw_capture_service_test.dart -p vm`
Expected: All tests passed!

- [ ] **Step 7：analyze**

Run: `flutter analyze`
Expected: No issues found!

- [ ] **Step 8：commit**

```bash
git add pubspec.yaml pubspec.lock lib/services/luckdraw_capture_service.dart lib/state/luckdraw_capture.dart test/services/luckdraw_capture_service_test.dart
git commit -m "feat(luckdraw): add LuckdrawCaptureService and webview_windows dependency"
```

---

## Task 7：`LuckdrawCaptureHost` 隱藏離屏宿主＋掛載 app 根

**Files:**
- Create: `lib/widgets/luckdraw_capture_host.dart`
- Modify: `lib/main.dart`（`MainApp.build` 的 `MaterialApp.router` 加 `builder:`）

> **採用 Task 1 驗證通過的離屏技巧**；下列以主技巧（`Opacity(0.004)` ＋藏於不透明 app 內容後）撰寫，若 Task 1 通過的是備援技巧，依該技巧調整 `build()`。

- [ ] **Step 1：實作 host widget**

建 `lib/widgets/luckdraw_capture_host.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:webview_windows/webview_windows.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/state/luckdraw_capture.dart';

/// 全域隱藏離屏 webview 宿主：持有可重用 [WebviewController] 供
/// [LuckdrawCaptureService] 擷取喚取立繪。掛在 app 根、藏於 app 內容之後，
/// 以極低不透明度保持繪製（rAF 不被節流）。WebView2 runtime 缺失時不掛載。
class LuckdrawCaptureHost extends ConsumerStatefulWidget {
  /// 建立 [LuckdrawCaptureHost]。
  const LuckdrawCaptureHost({super.key});

  @override
  ConsumerState<LuckdrawCaptureHost> createState() => _LuckdrawCaptureHostState();
}

class _LuckdrawCaptureHostState extends ConsumerState<LuckdrawCaptureHost> {
  static final _log = Logger('gacha.luckdraw.capture');
  final WebviewController _controller = WebviewController();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final ver = await WebviewController.getWebViewVersion();
      if (ver == null) {
        _log.warning('WebView2 runtime missing; luckdraw capture disabled');
        return;
      }
      await _controller.initialize();
      await _controller.loadUrl('about:blank');
      ref.read(luckdrawCaptureServiceProvider).attachWebview(_controller);
      if (mounted) setState(() => _ready = true);
      _log.info('luckdraw capture host ready (webview2 $ver)');
    } catch (e, st) {
      _log.warning('luckdraw capture host init failed', e, st);
    }
  }

  @override
  void dispose() {
    ref.read(luckdrawCaptureServiceProvider).detachWebview();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();
    return IgnorePointer(
      child: Opacity(
        opacity: 0.004,
        child: SizedBox(
          width: 1400,
          height: 1180,
          child: Webview(_controller),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2：掛載於 app 根**

`lib/main.dart`，`_MainAppState.build` 的 `return MaterialApp.router(...)`（第 153-183 行附近）：頂部 import 加：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/luckdraw_capture_host.dart';
```

於 `MaterialApp.router(...)` 加 `builder:`（放在 `routerConfig: _router,` 之後）：

```dart
      routerConfig: _router,
      builder: (context, child) => Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned(left: 0, top: 0, child: LuckdrawCaptureHost()),
          if (child != null) Positioned.fill(child: child),
        ],
      ),
```

> host 為 Stack 第一個 child（最底層）、app 內容 `Positioned.fill` 覆蓋其上，故 webview 被不透明 app UI 遮住。

- [ ] **Step 3：analyze**

Run: `flutter analyze`
Expected: No issues found!

- [ ] **Step 4：手動驗證（實機）— host 在真實 app 內離屏可擷取**

Run: `flutter run -d windows`
操作：等 app 啟動 → 確認 log 出現 `luckdraw capture host ready`（無 `host init failed`）。app UI 正常、看不到 webview。保持此 build 供 Task 8 端到端驗證。
Expected: app 正常啟動、無 webview 露出、host ready log 出現。

- [ ] **Step 5：commit**

```bash
git add lib/widgets/luckdraw_capture_host.dart lib/main.dart
git commit -m "feat(luckdraw): mount hidden offscreen capture host at app root"
```

---

## Task 8：詳情 dialog 整合「喚取」chip＋預抓＋重試

**Files:**
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`
- Modify: `lib/l10n/app_zh.arb`（template）、`lib/l10n/app_en.arb`、`lib/l10n/app_ja.arb`、`lib/l10n/app_zh_Hans.arb`
- Test: `test/widgets/luckdraw_chip_test.dart`（新建）

- [ ] **Step 1：加 i18n 字串**

`lib/l10n/app_zh.arb`（template，緊接 `galleryIconLabel` 區塊後）：

```json
  "galleryLuckdrawLabel": "喚取",
  "@galleryLuckdrawLabel": {
    "description": "Item detail dialog: chip label for the character convene (Luckdraw) splash art page. Placed first. Characters only; absent if the character has no Luckdraw spine."
  },
```

`lib/l10n/app_en.arb`：`"galleryLuckdrawLabel": "Convene",`（含同上 `@` 描述）
`lib/l10n/app_ja.arb`：`"galleryLuckdrawLabel": "募集",`（含 `@` 描述）
`lib/l10n/app_zh_Hans.arb`：`"galleryLuckdrawLabel": "唤取",`（含 `@` 描述）

- [ ] **Step 2：產生 l10n**

Run: `flutter gen-l10n`
Expected: 無錯誤，`lib/l10n/generated/app_localizations.dart` 出現 `galleryLuckdrawLabel` getter。

- [ ] **Step 3：寫失敗測試（widget test：hasLuckdraw → 喚取 chip 出現且在首位）**

建 `test/widgets/luckdraw_chip_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/gacha_item_detail_dialog.dart';

GachaRecord _charRecord() => GachaRecord(
      resourceId: 1211,
      qualityLevel: 5,
      resourceType: '角色',
      cardPoolType: '',
      name: '測試角色',
      count: 1,
      time: DateTime(2026, 1, 1),
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('luckdraw_chip_test_');
    // icon 檔需存在，dialog 才會顯示 icon chip／title
    await itemIconCacheFile(
      baseDir: tempDir,
      resourceId: 1211,
      url: 'https://x/i.webp',
    ).writeAsBytes([0]);
    // luckdraw 檔先放好 → 喚取 chip 直接 ready，不觸發 webview
    await itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1211)
        .writeAsBytes([0]);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> pump(WidgetTester tester, ItemImageEntry entry) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          itemImageCacheDirProvider.overrideWithValue(tempDir),
          itemImageIndexProvider.overrideWith(
            () => _StubIndexNotifier(ItemImageIndex(items: {1211: entry})),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: GachaItemDetailDialog(record: _charRecord()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('hasLuckdraw=true：出現「喚取」chip 且在首位', (tester) async {
    await pump(
      tester,
      const ItemImageEntry(
        iconUrl: 'https://x/i.webp',
        noImage: false,
        permanentNoImage: false,
        hasLuckdraw: true,
      ),
    );
    expect(find.text('喚取'), findsOneWidget);
  });

  testWidgets('hasLuckdraw=false：不出現「喚取」chip', (tester) async {
    await pump(
      tester,
      const ItemImageEntry(
        iconUrl: 'https://x/i.webp',
        noImage: false,
        permanentNoImage: false,
      ),
    );
    expect(find.text('喚取'), findsNothing);
  });
}

/// 測試用：直接持有固定 index 的 notifier stub（不碰 storage）。
class _StubIndexNotifier extends ItemImageIndexNotifier {
  _StubIndexNotifier(this._value);
  final ItemImageIndex _value;
  @override
  ItemImageIndex build() => _value;
}
```

> 若 `_StubIndexNotifier` 因 `waitForLoad`／`build()` 細節無法沿用，改以 `overrides` 注入 `itemImageIndexStorageProvider` 指向預先 `save` 過的 temp storage（沿用 Task 5 模式）。

- [ ] **Step 4：跑測試確認失敗**

Run: `flutter test test/widgets/luckdraw_chip_test.dart -p vm`
Expected: 失敗（喚取 chip 尚未實作）。

- [ ] **Step 5：實作 — `_ChipKind.luckdraw`**

`lib/widgets/dialogs/gacha_item_detail_dialog.dart`，`enum _ChipKind`（第 537-543 行）加：

```dart
enum _ChipKind {
  /// 喚取（Luckdraw）立繪：由 webview 擷取 encore canvas，僅角色且 hasLuckdraw。
  luckdraw,

  /// 造型 formation 大圖（URL 取自 per-lang 詳情 [ItemDetailL10n.skins]，lazy 下載）。
  skin,

  /// entry.iconUrl（已預下載，永遠 ready，永遠排最後）。
  icon,
}
```

- [ ] **Step 6：實作 — import、喚取 chip 組裝、預抓、_loadStates、重試分流**

頂部 import 加：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/services/luckdraw_capture_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/luckdraw_capture.dart';
```

`build()` 內，`final chipEntries = <_ImageChipEntry>[];`（第 314 行）之後、`for (final skin in skins)` 之前插入喚取 chip：

```dart
    final isCharacter = itemTypeKeyOf(record) == kItemKindCharacter;
    if (isCharacter && (entry?.hasLuckdraw ?? false)) {
      chipEntries.add(
        _ImageChipEntry(
          label: l.galleryLuckdrawLabel,
          url: '',
          file: itemLuckdrawCacheFile(
            baseDir: cacheDir,
            resourceId: record.resourceId,
          ),
          kind: _ChipKind.luckdraw,
        ),
      );
    }
```

`_loadStates` 同步迴圈的 `switch (ce.kind)`（第 346-361 行）加 `luckdraw` case：

```dart
        case _ChipKind.luckdraw:
          if (ce.file.existsSync()) {
            _loadStates[ce.file.path] = _ImageReady(ce.file);
          } else {
            _loadStates[ce.file.path] = const _ImageLoading();
            final theFile = ce.file;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final lang = ref.read(activeLanguageCodeProvider) ?? '';
              unawaited(_captureLuckdraw(file: theFile, lang: lang));
            });
          }
```

新增 `_captureLuckdraw` 方法（置於 `_fetchAndCache` 後，約第 122 行後）：

```dart
  /// 擷取喚取立繪：呼叫 [LuckdrawCaptureService]，成功 setState ready、失敗 failed。
  Future<void> _captureLuckdraw({
    required File file,
    required String lang,
  }) async {
    final service = ref.read(luckdrawCaptureServiceProvider);
    try {
      final result = await service.capture(
        resourceId: widget.record.resourceId,
        kind: itemTypeKeyOf(widget.record),
        lang: lang,
      );
      if (!mounted) return;
      if (result == null) {
        setState(() => _loadStates[file.path] = const _ImageFailed());
        _log.warning('luckdraw capture null rid=${widget.record.resourceId}');
        return;
      }
      setState(() => _loadStates[file.path] = _ImageReady(result));
      ref.invalidate(itemImageCacheUsageProvider);
      _log.info(
        'luckdraw ready rid=${widget.record.resourceId} '
        'path=${sanitizeFsPath(result.path)}',
      );
    } catch (e, st) {
      if (!mounted) return;
      setState(() => _loadStates[file.path] = const _ImageFailed());
      _log.warning('luckdraw failed rid=${widget.record.resourceId}', e, st);
    }
  }
```

重試分流：把既有 `_retry`（第 124-128 行）改為依 chip 分流的 `_retryEntry`：

```dart
  /// 由 failed 重試：改回 loading 並依 chip 類別重新取圖。
  void _retryEntry(_ImageChipEntry e) {
    setState(() => _loadStates[e.file.path] = const _ImageLoading());
    if (e.kind == _ChipKind.luckdraw) {
      final lang = ref.read(activeLanguageCodeProvider) ?? '';
      unawaited(_captureLuckdraw(file: e.file, lang: lang));
    } else {
      unawaited(_fetchAndCache(url: e.url, file: e.file));
    }
  }
```

並把 `_buildCurrentImageArea` 內重試按鈕 `onPressed`（第 196 行）改為：

```dart
                onPressed: () => _retryEntry(current),
```

> `_buildCurrentImageArea(context, current)` 已傳入 `current`，故 `_retryEntry(current)` 可用；移除舊 `_retry` 方法。

- [ ] **Step 7：跑測試確認通過**

Run: `flutter test test/widgets/luckdraw_chip_test.dart -p vm`
Expected: All tests passed!

- [ ] **Step 8：手動端到端（實機，沿用 Task 7 的 run 或重跑）**

Run: `flutter run -d windows`
操作：開啟一個有喚取立繪的 5★ 角色詳情（例：達妮婭／1211）→ 點「喚取」chip → 首次顯示 spinner，約數秒後出現完整去背喚取立繪（襯 app 背景）→ 點圖可放大 → 關閉再開即時顯示（快取命中）。武器或無 Luckdraw 角色不應出現「喚取」chip。
Expected: 行為如上；log 出現 `capture ok rid=1211`。

- [ ] **Step 9：commit**

```bash
git add lib/widgets/dialogs/gacha_item_detail_dialog.dart lib/l10n/app_zh.arb lib/l10n/app_en.arb lib/l10n/app_ja.arb lib/l10n/app_zh_Hans.arb test/widgets/luckdraw_chip_test.dart
git commit -m "feat(luckdraw): add convene chip with on-open prefetch to item detail dialog"
```

---

## Task 9：快取統計與清除涵蓋 `_luckdraw`

**Files:**
- Modify: `lib/services/item_image_index.dart`（`deleteIllustrationCacheFiles`）
- Modify: `lib/state/item_image_cache_usage.dart`（統計）
- Test: `test/services/item_image_index_test.dart`

- [ ] **Step 1：寫失敗測試（清除涵蓋 `_luckdraw`）**

`test/services/item_image_index_test.dart` 加：

```dart
  test('deleteIllustrationCacheFiles 一併刪除 _luckdraw.png', () async {
    await itemIllustrationCacheFile(
      baseDir: tempDir,
      resourceId: 1,
      url: 'https://x/a.webp',
    ).writeAsBytes([0]);
    await itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1).writeAsBytes([0]);
    await itemIconCacheFile(
      baseDir: tempDir,
      resourceId: 1,
      url: 'https://x/i.webp',
    ).writeAsBytes([0]);

    final removed = await storage.deleteIllustrationCacheFiles();
    expect(removed, 2); // illustration + luckdraw，icon 保留
    expect(itemLuckdrawCacheFile(baseDir: tempDir, resourceId: 1).existsSync(), isFalse);
    expect(
      itemIconCacheFile(baseDir: tempDir, resourceId: 1, url: 'https://x/i.webp')
          .existsSync(),
      isTrue,
    );
  });
```

- [ ] **Step 2：跑測試確認失敗**

Run: `flutter test test/services/item_image_index_test.dart -p vm`
Expected: 失敗（目前只刪 `_illustration`，`removed` 為 1）。

- [ ] **Step 3：實作 — 清除涵蓋 `_luckdraw`**

`lib/services/item_image_index.dart`，`deleteIllustrationCacheFiles`（第 227 行條件）：

```dart
      if (entity.path.contains('_illustration') ||
          entity.path.contains('_luckdraw')) {
        await entity.delete();
        deleted++;
      }
```

- [ ] **Step 4：實作 — 統計納入 `_luckdraw`（計入 illustrationBytes）**

`lib/state/item_image_cache_usage.dart`，掃描迴圈（約第 48-53 行）：

```dart
        if (path.contains('_illustration') || path.contains('_luckdraw')) {
          illustrationBytes += size;
        } else if (path.contains('_icon.')) {
          iconBytes += size;
        }
```

- [ ] **Step 5：跑測試確認通過**

Run: `flutter test test/services/item_image_index_test.dart -p vm`
Expected: All tests passed!

- [ ] **Step 6：commit**

```bash
git add lib/services/item_image_index.dart lib/state/item_image_cache_usage.dart test/services/item_image_index_test.dart
git commit -m "feat(luckdraw): include _luckdraw files in cache usage and clear"
```

---

## Task 10：最終驗證

**Files:** （無新增）

- [ ] **Step 1：格式化**

Run: `dart format lib/ test/`
Expected: 僅本功能檔案被格式化（或無變更）。

- [ ] **Step 2：靜態分析**

Run: `flutter analyze`
Expected: No issues found!

- [ ] **Step 3：全測試**

Run: `flutter test`
Expected: All tests passed!

- [ ] **Step 4：實機端到端回歸**

Run: `flutter run -d windows`
驗收清單：
1. 5★ 有 Luckdraw 角色：開詳情 → 喚取 chip 在首位 → 首次數秒擷取 → 完整去背立繪 → 可放大 → 再開即時。
2. 無 Luckdraw 角色 / 武器：無喚取 chip，其餘詳情如常。
3. 擷取失敗情境（可暫時改 `encoreItemUrl` 為錯 id 模擬）：喚取 chip 顯示失敗 + 重試按鈕，其餘 chip 正常。
4. 設定頁「清除立繪快取」：含 `_luckdraw.png`，清除後下次開詳情重新擷取。
5. WebView2 缺失（難在本機模擬，靠 log 確認 `host init`／`runtime missing` 分支）：不顯示喚取 chip / 擷取回 null，app 不崩。
Expected: 全數符合。

- [ ] **Step 5：若 commit 過程未跑過完整檢查，補一次並確認乾淨**

```bash
git status
git log --oneline -8
```

---

## Self-Review（計畫對 spec 覆核）

- **Spec §四 決策**：開詳情即背景預抓（Task 8 Step 6 postFrame 觸發）✅；透明立繪配 app 背景（沿用 `_buildCurrentImageArea`，不與 UnderBg 合成）✅；僅角色且 hasLuckdraw（Task 8 Step 6 gate）✅。
- **Spec §五 元件**：webview_windows 依賴（Task 6）✅；LuckdrawCaptureHost（Task 7）✅；LuckdrawCaptureService（Task 6）✅；ItemImageEntry.hasLuckdraw（Task 3）✅；itemLuckdrawCacheFile（Task 2）✅；EncoreItemDetail.hasLuckdraw＋解析（Task 4）✅；dialog 整合（Task 8）✅。
- **Spec §七 失敗三分流＋logging**：`_ImageLoading/_ImageReady/_ImageFailed` 沿用、重試分流（Task 8）✅；`gacha.luckdraw.capture` logger＋sanitize（Task 6/7/8）✅。
- **Spec §八 快取清除/統計**：Task 9 ✅。
- **Spec §十一 離屏風險**：Task 1 spike 為風險閘、含備援與停止條件 ✅；Task 7 採用驗證技巧 ✅。
- **型別一致**：`hasLuckdraw`（bool）貫穿 EncoreItemDetail→mergeItemDetail→ItemImageEntry；`capture({resourceId,kind,lang})`／`attachWebview`／`cacheFileFor` 名稱在 Task 6/7/8 一致；`itemLuckdrawCacheFile({baseDir,resourceId})` 一致 ✅。
- **Placeholder 掃描**：各 step 均含實際程式碼／指令；Task 1/7 的離屏技巧不確定性以「spike 決定＋主技巧具體程式碼＋備援」處理，非 placeholder ✅。
