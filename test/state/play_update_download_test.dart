import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

  @override
  Future<void> completeFlexible() async => completes++;
}

/// 建立使用 [gateway] 的容器。
ProviderContainer _container(_Gateway gateway) {
  final c = ProviderContainer(
    overrides: [playUpdateGatewayProvider.overrideWithValue(gateway)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('download success → downloaded', () async {
    final g = _Gateway(PlayDownloadResult.downloaded)..gate.complete();
    final c = _container(g);
    await c.read(playUpdateDownloadProvider.notifier).start();
    expect(c.read(playUpdateDownloadProvider), PlayDownloadPhase.downloaded);
  });

  test('flexible update denied or failed → no restart prompt', () async {
    for (final r in [PlayDownloadResult.denied, PlayDownloadResult.failed]) {
      final g = _Gateway(r)..gate.complete();
      final c = _container(g);
      await c.read(playUpdateDownloadProvider.notifier).start();
      expect(c.read(playUpdateDownloadProvider), PlayDownloadPhase.idle);
    }
    final g = _Gateway(PlayDownloadResult.failed, throwOnDownload: true)
      ..gate.complete();
    final c = _container(g);
    await c.read(playUpdateDownloadProvider.notifier).start();
    expect(c.read(playUpdateDownloadProvider), PlayDownloadPhase.idle);
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
}
