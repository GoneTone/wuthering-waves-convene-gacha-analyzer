# 物品詳情純文字 URL 自動可點擊（linkify）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 物品詳情 dialog 內純文字 `http(s)` 網址自動轉成可點擊連結，以系統瀏覽器開啟。

**Architecture:** 新增純函式 `linkifyHtml`（`html` 套件 DOM parser 只走 text node、跳過既有 `<a>`、只認 `http(s)://`、尾端標點不吃進、失敗 fallback 原字串）與共用元件 `AppHtml`（包裝 `flutter_html` 的 `Html`，內部套 `linkifyHtml`、接 `onLinkTap` → 既有 `openExternalUrlString`、預設 `'a'` 連結樣式可被呼叫端覆蓋）。物品詳情 dialog 的唯一渲染入口 `_detailHtml` 由 `Html` 換成 `AppHtml`，一處涵蓋 intro 與 bgDescription。對齊姐妹專案 PR #123。

**Tech Stack:** Flutter / Dart、`flutter_html ^3.0.0`、`html ^0.15.6`、`url_launcher`（既有）、`logging`。

## Global Constraints

- 指令一律優先用 `fvm`（`fvm flutter ...`／`fvm dart ...`），找不到再退回 `flutter`／`dart`。
- 提交前依序通過：`fvm dart format lib/ test/`、`fvm flutter analyze`（須 `No issues found!`）、`fvm flutter test`（須 `All tests passed!`）。不得 `--no-verify`。
- 不主動 `git push`。
- 省略號用 ASCII `...`，繁中標點用全形（程式碼／commit message 除外）。commit message 用英文、conventional commits。
- 只比對 `http://`／`https://` 開頭完整 URL；不處理 `www.`／裸網域。
- 共用優先、不造輪子：`openExternalUrlString`、`linkBaseColor` 皆既有，直接重用。
- 方法寫一行 `///` dartdoc（簽名自明的 Flutter override 除外）。

---

### Task 1: `linkifyHtml` 純函式 + `html` 顯式依賴

**Files:**
- Modify: `pubspec.yaml`（`dependencies:` 區段加 `html`）
- Create: `lib/utils/html_linkify.dart`
- Test: `test/utils/html_linkify_test.dart`

**Interfaces:**
- Consumes: `package:html/dom.dart`（`Node`、`Element`、`Text`）、`package:html/parser.dart`（`parseFragment`）、`package:logging`。
- Produces: `String linkifyHtml(String html)` — 把純文字 `http(s)` 裸網址包成 `<a href>`，回傳改寫後 HTML；空字串原樣回傳；解析失敗回傳原字串。

- [ ] **Step 1: 加入 `html` 顯式依賴**

在 `pubspec.yaml` 的 `dependencies:` 區段、`flutter_html: ^3.0.0` 之後加一行（版本對齊 `pubspec.lock` 既有的 `0.15.6`）：

```yaml
  flutter_html: ^3.0.0
  html: ^0.15.6
  webview_windows: ^0.4.0
```

Run: `fvm flutter pub get`
Expected: 成功，無版本衝突（`html` 本就是 `flutter_html` 的傳遞依賴，僅提升為顯式）。

- [ ] **Step 2: 寫失敗測試**

建立 `test/utils/html_linkify_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/utils/html_linkify.dart';

/// 計算 [out] 內 `<a ` 出現次數，用來驗證沒有產生多餘／巢狀連結。
int _anchorCount(String out) => '<a '.allMatches(out).length;

void main() {
  group('linkifyHtml', () {
    test('純文字 https 網址 → 包成 <a href>', () {
      final out = linkifyHtml('visit https://example.com now');
      expect(
        out,
        contains('<a href="https://example.com">https://example.com</a>'),
      );
      expect(_anchorCount(out), 1);
    });

    test('http 也會被連結化', () {
      final out = linkifyHtml('go http://foo.com');
      expect(out, contains('<a href="http://foo.com">http://foo.com</a>'));
    });

    test('ftp / www / 裸網域不被連結化', () {
      expect(_anchorCount(linkifyHtml('x ftp://foo.com y')), 0);
      expect(_anchorCount(linkifyHtml('visit www.foo.com')), 0);
      expect(_anchorCount(linkifyHtml('go to foo.com now')), 0);
    });

    test('尾端半形句點不吃進連結', () {
      final out = linkifyHtml('see https://foo.com.');
      expect(out, contains('<a href="https://foo.com">https://foo.com</a>'));
      expect(out, contains('</a>.'));
    });

    test('尾端全形句號不吃進連結', () {
      final out = linkifyHtml('詳見 https://foo.com。');
      expect(out, contains('<a href="https://foo.com">https://foo.com</a>'));
      expect(out, contains('</a>。'));
    });

    test('連續尾端標點全部剝除', () {
      final out = linkifyHtml('see https://foo.com).');
      expect(out, contains('<a href="https://foo.com">https://foo.com</a>'));
      expect(out, contains('</a>).'));
    });

    test('既有 <a href> 不被改、不雙重包覆', () {
      final out = linkifyHtml('<a href="https://x.com">link</a>');
      expect(out, contains('<a href="https://x.com">link</a>'));
      expect(_anchorCount(out), 1);
    });

    test('既有 <a> 內文是網址也不產生巢狀 <a>', () {
      final out = linkifyHtml('<a href="x">https://foo.com</a>');
      expect(_anchorCount(out), 1);
    });

    test('屬性值內的網址不被當文字連結化', () {
      final out = linkifyHtml('<img src="https://img.com/a.png">');
      expect(out, isNot(contains('<a')));
    });

    test('同段多個網址各自連結化', () {
      final out = linkifyHtml('a https://1.com b https://2.com');
      expect(_anchorCount(out), 2);
    });

    test('無網址純文字語意不變', () {
      expect(linkifyHtml('hello world'), 'hello world');
    });

    test('空字串回空字串', () {
      expect(linkifyHtml(''), '');
    });
  });
}
```

- [ ] **Step 3: 跑測試確認失敗**

Run: `fvm flutter test test/utils/html_linkify_test.dart`
Expected: 編譯失敗／FAIL — `html_linkify.dart` 尚未建立、`linkifyHtml` 未定義。

- [ ] **Step 4: 實作 `linkifyHtml`**

建立 `lib/utils/html_linkify.dart`：

```dart
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:logging/logging.dart';

/// [linkifyHtml] 的 logger。
final Logger _log = Logger('ui.linkify');

/// 比對 `http://` 或 `https://` 開頭的裸網址（延伸到空白或 `<` 為止）。
final RegExp _urlRe = RegExp(r'https?://[^\s<]+');

/// 連結尾端要剝除的標點（半形 + 全形），避免把句末標點吃進網址。
const String _trailingPunct = '.,;:!?)]}。，！？；：）」』】';

/// 把 [html] 內的純文字 `http(s)` 裸網址包成 `<a href>`，回傳改寫後的 HTML。
///
/// 用 DOM parser 只走訪 text node：既有 `<a>` 子樹整棵略過（不產生巢狀 `<a>`），
/// 屬性值（如 `href="..."`）因非 text node 也不會被誤改。解析或序列化意外失敗時
/// 回傳原字串（裸網址維持純文字、描述區不致渲染中斷）並記 warning。純函式、無副作用。
String linkifyHtml(String html) {
  if (html.isEmpty) return html;
  try {
    final fragment = html_parser.parseFragment(html);
    _linkifyNode(fragment);
    return fragment.outerHtml;
  } catch (e, st) {
    _log.warning(
      'linkifyHtml failed (len=${html.length}); returning original',
      e,
      st,
    );
    return html;
  }
}

/// 遞迴改寫 [node] 子節點：text node 內裸網址換成 `<a>`，`<a>` 子樹略過，其餘遞迴。
void _linkifyNode(Node node) {
  for (final child in List<Node>.from(node.nodes)) {
    if (child is Text) {
      final replacements = _linkifyText(child.data);
      if (replacements == null) continue;
      final idx = node.nodes.indexOf(child);
      node.nodes.removeAt(idx);
      node.nodes.insertAll(idx, replacements);
    } else if (child is Element) {
      if (child.localName == 'a') continue;
      _linkifyNode(child);
    }
  }
}

/// 把 [text] 拆成「文字／`<a>` 連結」節點序列；若無可連結網址回 null（呼叫端略過替換）。
List<Node>? _linkifyText(String text) {
  if (!_urlRe.hasMatch(text)) return null;
  final nodes = <Node>[];
  var last = 0;
  for (final m in _urlRe.allMatches(text)) {
    var url = m.group(0)!;
    var end = m.end;
    while (url.isNotEmpty && _trailingPunct.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
      end--;
    }
    if (url.isEmpty) {
      last = m.end;
      continue;
    }
    if (m.start > last) nodes.add(Text(text.substring(last, m.start)));
    nodes.add(
      Element.tag('a')
        ..attributes['href'] = url
        ..append(Text(url)),
    );
    last = end;
  }
  if (nodes.isEmpty) return null;
  if (last < text.length) nodes.add(Text(text.substring(last)));
  return nodes;
}
```

- [ ] **Step 5: 跑測試確認通過**

Run: `fvm flutter test test/utils/html_linkify_test.dart`
Expected: All tests passed!（12 tests）

- [ ] **Step 6: 格式化、分析、提交**

Run:
```bash
fvm dart format lib/ test/
fvm flutter analyze
```
Expected: `No issues found!`

```bash
git add pubspec.yaml pubspec.lock lib/utils/html_linkify.dart test/utils/html_linkify_test.dart
git commit -m "feat(utils): add linkifyHtml to wrap plain-text http(s) URLs in <a>"
```

---

### Task 2: `AppHtml` 共用元件

**Files:**
- Create: `lib/widgets/app_html.dart`
- Test: `test/widgets/app_html_test.dart`

**Interfaces:**
- Consumes: `linkifyHtml`（Task 1）、`openExternalUrlString(String url, {String context})` 與 `linkBaseColor(ThemeData)`（既有 `lib/widgets/app_link.dart`）、`flutter_html` 的 `Html`／`Style`。
- Produces: `class AppHtml extends StatelessWidget`，建構子 `AppHtml({required String data, Map<String, Style> style = const {}})`。

> 注意：本專案 `openExternalUrlString` 參數為非空 `String`，`onLinkTap` 傳入的 `url` 為 `String?`，故以 `url ?? ''` 帶入並指定 `context: 'AppHtml'`。

- [ ] **Step 1: 寫失敗測試**

建立 `test/widgets/app_html_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/app_html.dart';

void main() {
  testWidgets('純文字網址被渲染成連結文字', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AppHtml(data: 'visit https://example.com now')),
      ),
    );
    expect(find.byType(Html), findsOneWidget);
    expect(
      find.textContaining('https://example.com', findRichText: true),
      findsWidgets,
    );
  });

  testWidgets('onLinkTap 已接上（callback 非 null）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AppHtml(data: 'see https://example.com')),
      ),
    );
    final html = tester.widget<Html>(find.byType(Html));
    expect(html.onLinkTap, isNotNull);
  });

  testWidgets('呼叫端 style 覆蓋預設 a 樣式', (tester) async {
    final overrideAnchor = Style(color: Colors.red);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppHtml(
            data: 'see https://example.com',
            style: {'a': overrideAnchor},
          ),
        ),
      ),
    );
    final html = tester.widget<Html>(find.byType(Html));
    expect(identical(html.style['a'], overrideAnchor), isTrue);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/widgets/app_html_test.dart`
Expected: 編譯失敗／FAIL — `app_html.dart`／`AppHtml` 未定義。

- [ ] **Step 3: 實作 `AppHtml`**

建立 `lib/widgets/app_html.dart`：

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/utils/html_linkify.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/app_link.dart';

/// 渲染 HTML 的共用元件：自動把純文字 `http(s)` 網址轉成可點連結（含內容既有的
/// `<a href>`），點擊以系統瀏覽器開啟。
///
/// 連結採全應用統一的靜態 primary 連結色（[linkBaseColor]）+ 底線，對齊既有行內
/// 連結風格；不做 per-link hover。呼叫端可透過 [style] 覆蓋 `body`／`p` 等標籤樣式
/// （疊在預設 `a` 樣式之後）。
class AppHtml extends StatelessWidget {
  /// 建立 [AppHtml]。[data] 為 HTML 字串；[style] 為額外的 flutter_html 標籤樣式。
  const AppHtml({super.key, required this.data, this.style = const {}});

  /// 要渲染的 HTML 內容。
  final String data;

  /// 額外的標籤樣式覆寫（疊在預設 `a` 樣式之後）。
  final Map<String, Style> style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Html(
      data: linkifyHtml(data),
      onLinkTap: (url, _, _) =>
          unawaited(openExternalUrlString(url ?? '', context: 'AppHtml')),
      style: {
        'a': Style(
          color: linkBaseColor(theme),
          textDecoration: TextDecoration.underline,
        ),
        ...style,
      },
    );
  }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `fvm flutter test test/widgets/app_html_test.dart`
Expected: All tests passed!（3 tests）

- [ ] **Step 5: 格式化、分析、提交**

Run:
```bash
fvm dart format lib/ test/
fvm flutter analyze
```
Expected: `No issues found!`

```bash
git add lib/widgets/app_html.dart test/widgets/app_html_test.dart
git commit -m "feat(widgets): add AppHtml shared component with linkify + external link tap"
```

---

### Task 3: 物品詳情 dialog 改用 `AppHtml`

**Files:**
- Modify: `lib/widgets/dialogs/gacha_item_detail_dialog.dart`（`_detailHtml`，約第 479-482 行）

**Interfaces:**
- Consumes: `AppHtml`（Task 2）、既有 `stripEntryLinkTags`、`_detailHtmlStyle`。
- Produces: 無新對外介面；`_detailHtml` 內部 `Html` → `AppHtml`，intro 與 bgDescription 兩呼叫點同時受惠。

- [ ] **Step 1: 加入 `AppHtml` import**

在 `gacha_item_detail_dialog.dart` 既有 import 區，依字母序加入：

```dart
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/app_html.dart';
```

> 若檔內已直接 `import 'package:flutter_html/flutter_html.dart';` 僅為了 `Html`，改用 `AppHtml` 後該 import 可能僅剩 `Style` 仍需要（`_detailHtmlStyle` 回傳 `Map<String, Style>`），故**保留** `flutter_html` import；`fvm flutter analyze` 會回報是否有未使用 import，依其結果決定移除。

- [ ] **Step 2: 把 `_detailHtml` 內 `Html` 換成 `AppHtml`**

將：

```dart
  Widget _detailHtml(ThemeData theme, String data) => DefaultTextStyle(
    style: theme.textTheme.bodyMedium ?? const TextStyle(),
    child: Html(data: stripEntryLinkTags(data), style: _detailHtmlStyle(theme)),
  );
```

改為：

```dart
  Widget _detailHtml(ThemeData theme, String data) => DefaultTextStyle(
    style: theme.textTheme.bodyMedium ?? const TextStyle(),
    child: AppHtml(
      data: stripEntryLinkTags(data),
      style: _detailHtmlStyle(theme),
    ),
  );
```

> `stripEntryLinkTags` 維持在外層先跑：先還原 `<te>` 詞條標籤為純文字，URL 才會以可被 `linkifyHtml` 偵測的裸字串出現。

- [ ] **Step 3: 格式化、分析、全套測試**

Run:
```bash
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
```
Expected: `No issues found!` 與 `All tests passed!`（既有物品詳情 dialog 測試無回歸；新增 15 tests 全綠）。

- [ ] **Step 4: 提交**

```bash
git add lib/widgets/dialogs/gacha_item_detail_dialog.dart
git commit -m "feat(item-detail): auto-linkify plain-text URLs via AppHtml"
```

---

## 完成後

- 全套 `fvm flutter test` 綠、`fvm flutter analyze` 無 issue。
- 手動驗收（建議）：開啟某含外部網址簡介／造型背景說明的物品詳情，確認純文字 `http(s)` 網址呈現底線連結色、點擊以系統瀏覽器開啟；既有 `<a>` 連結行為一致；版本號／檔名等含點字串未被誤判成連結。
- 不主動 `git push`；整合方式（merge／PR）依 `superpowers:finishing-a-development-branch` 流程與使用者確認。

## Self-Review

- **Spec coverage**：linkifyHtml（Task 1）、AppHtml（Task 2）、dialog 接線（Task 3）、`html` 顯式依賴（Task 1 Step 1）、單元+widget 測試（Task 1/2）、回歸（Task 3 Step 3）、保守偵測與尾端標點（Task 1 測試）、連結樣式可覆蓋（Task 2 測試）。spec 各項皆有對應任務。
- **Placeholder scan**：無 TBD／TODO；所有步驟含可直接落地的完整程式碼與指令。
- **Type consistency**：`linkifyHtml(String) → String`、`openExternalUrlString(String, {String context})`、`AppHtml({required String data, Map<String, Style> style})`、`linkBaseColor(ThemeData) → Color` 跨任務一致；`onLinkTap` 對齊 `flutter_html 3.0` 的 `OnTap = void Function(String?, Map<String, String>, Element?)`。
