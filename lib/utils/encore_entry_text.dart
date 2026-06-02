/// 比對鳴潮／encore 詞條連結標籤 `<te …>` 開標籤與 `</te>` 閉標籤（屬性可有可無、
/// 引號可省、大小寫不敏感）。
///
/// `(?=[\s/>])` 要求 `te` 後須緊跟空白、`/` 或 `>` 才算標籤名結束，故只命中真正的
/// `<te>` 詞條標籤，不誤傷 `te` 為前綴的其他標籤——無論其後接 word char（`<text>`、
/// `<teleport>`）或 `-`／`:`／`.`（`<te-link>`、`<te:link>`）。
final RegExp _entryLinkTagRe = RegExp(
  r'</?te(?=[\s/>])[^>]*>',
  caseSensitive: false,
);

/// 剝除 encore 詳情文字裡的詞條連結標籤 `<te href=詞條id>…</te>`，只移除開／閉標籤
/// 本身、保留內文。
///
/// encore API 回傳的角色簡介與造型背景故事會用 `<te>` 標記遊戲內詞條（`href` 為詞條
/// id）。`<te>` 非標準 HTML 標籤，直接丟給 `flutter_html` 會被連同內文一起丟棄而缺
/// 字，故呈現前先過此函式還原成純文字；其餘合法 HTML（`<p>`、`<br>` 等）原樣保留交給
/// flutter_html。
String stripEntryLinkTags(String html) => html.replaceAll(_entryLinkTagRe, '');
