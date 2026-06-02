import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/utils/encore_entry_text.dart';

void main() {
  group('stripEntryLinkTags', () {
    test('剝除 <te href=id> 詞條標籤、保留內文（角色 1104 範例）', () {
      const raw =
          '<te href=850091>今州</te><te href=850130>瑞獅團</te>成員，善良靈性的異族來客。'
          '熱情開朗，勇敢正直，對人類抱有強烈的興趣。擁有極強的體能與力量，'
          '始終在以自己的方式詮釋著「<te href=850131>獅子舞</te>」的含義。';
      const expected =
          '今州瑞獅團成員，善良靈性的異族來客。'
          '熱情開朗，勇敢正直，對人類抱有強烈的興趣。擁有極強的體能與力量，'
          '始終在以自己的方式詮釋著「獅子舞」的含義。';
      expect(stripEntryLinkTags(raw), expected);
    });

    test('href 無引號也能剝', () {
      expect(stripEntryLinkTags('<te href=850091>今州</te>'), '今州');
    });

    test('href 帶雙引號也能剝', () {
      expect(stripEntryLinkTags('<te href="850091">今州</te>'), '今州');
    });

    test('<te> 無任何屬性也能剝', () {
      expect(stripEntryLinkTags('<te>今州</te>'), '今州');
    });

    test('無 <te> 標籤時原樣返回（其他合法 HTML 不動）', () {
      const raw = '<p>角色簡介<br>第二行<i>斜體</i></p>';
      expect(stripEntryLinkTags(raw), raw);
    });

    test('<te> 與合法 HTML 共存：只剝 <te>、保留 <p>', () {
      expect(
        stripEntryLinkTags('<p>前往<te href=1>沙鷗</te>據點</p>'),
        '<p>前往沙鷗據點</p>',
      );
    });

    test('不誤剝 te 前綴的其他標籤（<text>/<te-link>/<te:link>/<te.foo>）', () {
      // te 後接 word char（<text>）或接 - : .（<te-link> 等）都不是 <te> 詞條標籤，
      // 不應被剝；唯有 te 後緊跟空白／/／> 才算詞條標籤。
      for (final raw in const [
        '<text>保留</text>',
        '<te-link>保留</te-link>',
        '<te:link>保留</te:link>',
        '<te.foo>保留</te.foo>',
      ]) {
        expect(stripEntryLinkTags(raw), raw, reason: raw);
      }
    });

    test('屬性跨行／自閉合／相鄰／巢狀／非 href 屬性仍正確剝（行為防護網）', () {
      expect(stripEntryLinkTags('<te\n href=850091>今州</te>'), '今州');
      expect(stripEntryLinkTags('<te href=1/>今州'), '今州');
      expect(stripEntryLinkTags('<te href=1>甲</te><te href=2>乙</te>'), '甲乙');
      expect(stripEntryLinkTags('<te><te>x</te></te>'), 'x');
      expect(stripEntryLinkTags('<te lang=zh>今州</te>'), '今州');
    });

    test('空字串 → 空字串', () {
      expect(stripEntryLinkTags(''), '');
    });

    test('大小寫不敏感（<TE>/</TE>）', () {
      expect(stripEntryLinkTags('<TE href=1>今州</TE>'), '今州');
    });

    test('畸形：只有開標籤或只有閉標籤也剝該標籤', () {
      expect(stripEntryLinkTags('前<te href=1>後'), '前後');
      expect(stripEntryLinkTags('前</te>後'), '前後');
    });
  });
}
