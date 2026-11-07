import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/play_update.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/play_update_download.dart';

/// 可控制下載結果並記錄呼叫次數的 Play 更新替身。
class _Gateway implements PlayUpdateGateway {
  /// 建立替身；[result] 為下載結果，[throwOnDownload] 為 true 時下載拋例外。
  _Gateway(this.result, {this.throwOnDownload = false});

  /// 下載要回傳的結果。
  final PlayDownloadResult result;

  /// 下載時是否拋例外。
  final bool throwOnDownload;

  /// 下載被呼叫的次數。
  int downloads = 0;

  /// 安裝被呼叫的次數。
  int completes = 0;

  /// 讓下載停住直到測試放行。
  final gate = Completer<void>();

  @override
  Future<PlayUpdateInfo> check() => throw UnimplementedError();

  @override
  Future<PlayDownloadResult> downloadFlexible() async {
    downloads++;
    await gate.future;
    if (throwOnDownload) throw StateError('boom');
    return result;
  }

  /// completeFlexible 是否拋例外。
  bool throwOnComplete = false;

  @override
  Future<void> completeFlexible() async {
    completes++;
    if (throwOnComplete) throw StateError('complete boom');
  }
}

/// 建立使用 [gateway] 的容器。
ProviderContainer _container(_Gateway gateway) {
  final c = ProviderContainer(
    overrides: [playUpdateGatewayProvider.overrideWithValue(gateway)],
  );
  addTearDown(c.dispose);
  return c;
}

/// 收集 [Logger.root] 的記錄訊息，測試結束自動取消監聽。
List<String> _collectLogs() {
  final logs = <String>[];
  final sub = Logger.root.onRecord.listen(
    (r) => logs.add('${r.level.name} ${r.message}'),
  );
  addTearDown(sub.cancel);
  return logs;
}

void main() {
  Logger.root.level = Level.ALL;

  test('download success → downloaded', () async {
    final g = _Gateway(PlayDownloadResult.downloaded)..gate.complete();
    final c = _container(g);
    await c.read(playUpdateDownloadProvider.notifier).start();
    expect(c.read(playUpdateDownloadProvider), PlayDownloadPhase.downloaded);
  });

  test('flexible update denied or failed → no restart prompt', () async {
    final logs = _collectLogs();
    final cases = {
      'denied': _Gateway(PlayDownloadResult.denied),
      'failed': _Gateway(PlayDownloadResult.failed),
      'throw': _Gateway(PlayDownloadResult.failed, throwOnDownload: true),
    };
    for (final e in cases.entries) {
      e.value.gate.complete();
      final c = _container(e.value);
      await c.read(playUpdateDownloadProvider.notifier).start();
      expect(c.read(playUpdateDownloadProvider), PlayDownloadPhase.idle);
      final want = e.key == 'throw' ? 'failed' : e.key;
      expect(logs, contains('INFO play flexible update result=$want'));
      logs.clear();
    }
  });

  test('start while downloading does not call the gateway twice', () async {
    final g = _Gateway(PlayDownloadResult.downloaded);
    final c = _container(g);
    final n = c.read(playUpdateDownloadProvider.notifier);
    final first = n.start();
    expect(c.read(playUpdateDownloadProvider), PlayDownloadPhase.downloading);
    await n.start();
    g.gate.complete();
    await first;
    await n.start();
    expect(g.downloads, 1);
  });

  test('install calls completeFlexible', () async {
    final g = _Gateway(PlayDownloadResult.downloaded);
    final c = _container(g);
    await c.read(playUpdateDownloadProvider.notifier).install();
    expect(g.completes, 1);
  });

  test('install failure logs a warning and keeps the state', () async {
    final logs = _collectLogs();
    final g = _Gateway(PlayDownloadResult.downloaded)
      ..gate.complete()
      ..throwOnComplete = true;
    final c = _container(g);
    final n = c.read(playUpdateDownloadProvider.notifier);
    await n.start();
    await n.install();
    expect(c.read(playUpdateDownloadProvider), PlayDownloadPhase.downloaded);
    expect(
      logs.any((m) => m.startsWith('WARNING play flexible update install')),
      isTrue,
    );
  });
}
