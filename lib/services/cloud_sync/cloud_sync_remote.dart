import 'dart:convert';
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_config.dart';

/// 雲端同步檔的遠端存取介面；抽象化以便測試注入 fake。
abstract class CloudSyncRemote {
  /// 下載同步檔內容；檔案不存在回 null。
  Future<String?> download();

  /// 上傳（覆蓋）同步檔內容。
  Future<void> upload(String json);
}

/// 以 Google Drive v3 appDataFolder 實作的 [CloudSyncRemote]，單一檔案
/// [cloudSyncFileName]。
class DriveSyncRemote implements CloudSyncRemote {
  /// 建立 [DriveSyncRemote]，[client] 需為已授權的 HTTP client。
  DriveSyncRemote(http.Client client) : _api = drive.DriveApi(client);

  /// Drive v3 API 入口。
  final drive.DriveApi _api;

  /// Logger 實例（同步遠端存取）。
  static final _log = Logger('cloudsync.sync');

  /// 查找 appDataFolder 內同步檔的 file id；不存在回 null。
  Future<String?> _findFileId() async {
    final list = await _api.files.list(
      spaces: 'appDataFolder',
      q: "name = '$cloudSyncFileName'",
      $fields: 'files(id)',
    );
    final files = list.files;
    if (files == null || files.isEmpty) return null;
    return files.first.id;
  }

  @override
  Future<String?> download() async {
    final id = await _findFileId();
    if (id == null) {
      _log.info('download: no remote file');
      return null;
    }
    final media =
        await _api.files.get(
              id,
              downloadOptions: drive.DownloadOptions.fullMedia,
            )
            as drive.Media;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in media.stream) {
      bytes.add(chunk);
    }
    _log.info('download: ${bytes.length} bytes');
    return utf8.decode(bytes.takeBytes());
  }

  @override
  Future<void> upload(String json) async {
    final data = utf8.encode(json);
    final media = drive.Media(Stream.value(data), data.length);
    final id = await _findFileId();
    if (id == null) {
      await _api.files.create(
        drive.File()
          ..name = cloudSyncFileName
          ..parents = ['appDataFolder'],
        uploadMedia: media,
      );
      _log.info('upload: created, ${data.length} bytes');
    } else {
      await _api.files.update(drive.File(), id, uploadMedia: media);
      _log.info('upload: updated, ${data.length} bytes');
    }
  }
}
