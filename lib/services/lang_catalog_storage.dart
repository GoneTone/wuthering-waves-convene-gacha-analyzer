import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';

/// 單一語言的物品目錄：`resourceId → (name, kind)`，並附 `name → id` 反查表
/// （供第三方匯入合成 ID 回查；跨 id 同名者剔除）。
class LangCatalog {
  /// 建立 [LangCatalog]；[idByName] 由 [byId] 推導。
  LangCatalog({required this.lang, required this.fetchedAt, required this.byId})
    : idByName = _idByNameFrom(byId);

  /// 語言代碼（encore 對齊）。
  final String lang;

  /// 抓取時間（UTC）。
  final DateTime fetchedAt;

  /// `resourceId → (name, kind)`。
  final Map<int, ({String name, String kind})> byId;

  /// `name → resourceId`；同名對到不同 id 者剔除（無法判定歸屬）。
  final Map<String, int> idByName;

  /// 由 [byId] 推導 `name → id`，剔除對到多個 id 的同名。
  static Map<String, int> _idByNameFrom(
    Map<int, ({String name, String kind})> byId,
  ) {
    final out = <String, int>{};
    final ambiguous = <String>{};
    byId.forEach((id, v) {
      if (ambiguous.contains(v.name)) return;
      final existing = out[v.name];
      if (existing == null) {
        out[v.name] = id;
      } else if (existing != id) {
        out.remove(v.name);
        ambiguous.add(v.name);
      }
    });
    return out;
  }

  /// 由 [EncoreCatalog] 的 `nameByKindId` 攤平建立。
  factory LangCatalog.fromEncore({
    required String lang,
    required DateTime fetchedAt,
    required EncoreCatalog catalog,
  }) {
    final byId = <int, ({String name, String kind})>{};
    catalog.nameByKindId.forEach((kind, m) {
      m.forEach((id, name) {
        byId.putIfAbsent(id, () => (name: name, kind: kind));
      });
    });
    return LangCatalog(lang: lang, fetchedAt: fetchedAt, byId: byId);
  }

  /// 由 storage JSON 還原。
  factory LangCatalog.fromJson(Map<String, dynamic> json) {
    final items = (json['items'] as Map<String, dynamic>?) ?? const {};
    final byId = <int, ({String name, String kind})>{};
    items.forEach((k, v) {
      final id = int.tryParse(k);
      if (id == null || v is! Map<String, dynamic>) return;
      final name = v['name'] as String?;
      final kind = v['kind'] as String?;
      if (name == null || kind == null) return;
      byId[id] = (name: name, kind: kind);
    });
    return LangCatalog(
      lang: json['lang'] as String,
      fetchedAt: DateTime.parse(json['fetched_at'] as String),
      byId: byId,
    );
  }

  /// 序列化為 storage JSON。
  Map<String, dynamic> toJson() => {
    'lang': lang,
    'fetched_at': fetchedAt.toUtc().toIso8601String(),
    'items': byId.map(
      (id, v) => MapEntry('$id', {'name': v.name, 'kind': v.kind}),
    ),
  };
}

/// 負責 `lang_catalog/<lang>.json` 的讀寫（atomic write）。
class LangCatalogStorage {
  /// 建立 [LangCatalogStorage]，需指定資料根目錄 [baseDir]。
  LangCatalogStorage(this.baseDir);

  /// Logger 實例。
  static final _log = Logger('wish.langconvert.catalog');

  /// 資料根目錄（語言目錄寫入其下的 `lang_catalog/` 子目錄）。
  final Directory baseDir;

  /// 回傳 [lang] 對應的目錄檔案路徑。
  File _file(String lang) => File('${baseDir.path}/lang_catalog/$lang.json');

  /// 讀取 [lang] 的目錄；不存在或解析失敗回 null。
  Future<LangCatalog?> load(String lang) async {
    final f = _file(lang);
    if (!await f.exists()) return null;
    try {
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return LangCatalog.fromJson(json);
    } catch (e, st) {
      _log.warning(
        'lang catalog load failed lang=$lang, treat as missing',
        e,
        st,
      );
      return null;
    }
  }

  /// 將 [catalog] 原子寫入（`.tmp` + rename）。
  Future<void> save(LangCatalog catalog) async {
    final f = _file(catalog.lang);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(catalog.toJson()));
    await tmp.rename(f.path);
    _log.fine(
      'lang catalog saved lang=${catalog.lang} items=${catalog.byId.length}',
    );
  }
}
