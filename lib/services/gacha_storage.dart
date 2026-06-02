import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 負責喚取資料與已擷取憑證（credential body）的本地 JSON 讀寫。
///
/// 檔名規則改用顯式副檔名（spec D3）：記錄檔 `<playerId>.records.json`、憑證檔
/// `<playerId>.cred.json`，playerId 一律當不透明字串（不靠數字 regex 篩選）。
class GachaStorage {
  /// 建立 [GachaStorage]，需指定資料根目錄 [baseDir]。
  GachaStorage(this.baseDir);

  /// Logger 實例（gacha 儲存）。
  static final _log = Logger('gacha.storage');

  /// 記錄檔副檔名。
  static const _recordsSuffix = '.records.json';

  /// 憑證檔副檔名。
  static const _credSuffix = '.cred.json';

  /// `<applicationSupportDirectory>/gacha_data/`，main.dart 創建後傳入。
  final Directory baseDir;

  /// 回傳 [playerId] 對應的記錄檔路徑。
  File _recordsFile(String playerId) =>
      File('${baseDir.path}/$playerId$_recordsSuffix');

  /// 回傳 [playerId] 對應的憑證檔路徑。
  File _credFile(String playerId) =>
      File('${baseDir.path}/$playerId$_credSuffix');

  /// 讀取 [playerId] 的喚取資料；不存在回 null。
  ///
  /// 舊檔辨識標記（§C）：鳴潮新 schema 每筆 record 必含 `resource_id`（整數），不相容
  /// 的舊版 schema 則無（其鍵為 `id`/`gacha_type`/`item_type`/`rank_type`/`lang`）。
  /// 因此本 `load` 以「`GachaRecord.fromStorageJson` 解析時缺 `resource_id` 而拋例外」
  /// 作為舊檔偵測依據——不另在 `BannerStorage.toJson` 加版本欄位，缺 `resource_id`
  /// 即足以區分。遇此情形時跳過該檔並 log warning、回 null，**不可 rethrow**（否則
  /// 殘留舊檔會讓整個 App 開不起來，spec D2）。
  Future<BannerStorage?> load(String playerId) async {
    final f = _recordsFile(playerId);
    if (!await f.exists()) return null;
    try {
      final text = await f.readAsString();
      final json = jsonDecode(text) as Map<String, dynamic>;
      return BannerStorage.fromJson(json);
    } catch (e, st) {
      _log.warning(
        'skip unparseable records file (legacy/incompatible schema) for '
        'playerId=${sanitizeUid(playerId)}',
        e,
        st,
      );
      return null;
    }
  }

  /// 將 [data] 寫回磁碟。
  Future<void> save(BannerStorage data) async {
    try {
      await _atomicWrite(
        _recordsFile(data.playerId),
        jsonEncode(data.toJson()),
      );
      final total = data.banners.values.fold<int>(0, (a, b) => a + b.length);
      _log.fine('saved playerId=${sanitizeUid(data.playerId)} records=$total');
    } catch (e, st) {
      _log.severe(
        'save failed for playerId=${sanitizeUid(data.playerId)}',
        e,
        st,
      );
      rethrow;
    }
  }

  /// 回傳 [baseDir] 中所有已有記錄檔的 playerId 列表。
  ///
  /// 以 `.records.json` 副檔名辨識（spec D3），metadata（如 item_image 索引）與
  /// 憑證檔因副檔名不同而自然排除，不需數字 regex。
  Future<List<String>> listKnownUids() async {
    if (!await baseDir.exists()) return const [];
    final entries = await baseDir.list().toList();
    return entries
        .whereType<File>()
        .map((e) => e.uri.pathSegments.last)
        .where((name) => name.endsWith(_recordsSuffix))
        .map((name) => name.substring(0, name.length - _recordsSuffix.length))
        .toList();
  }

  /// 讀取 [playerId] 的已擷取憑證 body（整份 JSON 字串）；不存在回 null。
  Future<String?> loadCapturedCredential(String playerId) async {
    final f = _credFile(playerId);
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  /// 將攔到的憑證 [bodyJson]（整份 body）寫入 [playerId] 的憑證檔。
  Future<void> saveCapturedCredential(String playerId, String bodyJson) async {
    await _atomicWrite(_credFile(playerId), bodyJson);
    _log.fine(
      'saved captured credential for playerId=${sanitizeUid(playerId)}',
    );
  }

  /// 刪除 [playerId] 的憑證檔（若存在）。
  Future<void> deleteCapturedCredential(String playerId) async {
    final f = _credFile(playerId);
    if (await f.exists()) {
      await f.delete();
      _log.fine(
        'deleted captured credential for playerId=${sanitizeUid(playerId)}',
      );
    }
  }

  /// 刪除 [playerId] 的所有本地資料（記錄檔 + 憑證檔）。
  Future<void> delete(String playerId) async {
    final f = _recordsFile(playerId);
    if (await f.exists()) await f.delete();
    await deleteCapturedCredential(playerId);
    _log.info('delete playerId=${sanitizeUid(playerId)}');
  }

  /// 清除 [baseDir] 內所有 `.json` 檔案。
  Future<void> clearAll() async {
    if (!await baseDir.exists()) return;
    final entries = await baseDir.list().toList();
    for (final e in entries) {
      if (e is File && e.path.endsWith('.json')) {
        await e.delete();
      }
    }
    _log.info('clear all gacha data');
  }

  /// 先寫入 `.tmp` 再 rename，確保寫入的原子性。
  Future<void> _atomicWrite(File target, String content) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content);
    await tmp.rename(target.path); // atomic on same volume
  }
}
