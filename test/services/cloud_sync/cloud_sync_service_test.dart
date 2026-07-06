import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_remote.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_sync_service.dart';

/// 記錄呼叫的 fake 遠端。
class _FakeRemote implements CloudSyncRemote {
  _FakeRemote({this.content});

  /// 目前雲端檔內容；null = 不存在。
  String? content;

  /// upload 被呼叫的次數。
  int uploads = 0;

  @override
  Future<String?> download() async => content;

  @override
  Future<void> upload(String json) async {
    uploads++;
    content = json;
  }
}

/// 產生單帳號的 bundle JSON（schema v2、正確 app id）。
String _bundleJson({List<String> uids = const ['100000001'], int? schema}) =>
    jsonEncode({
      'schema_version': schema ?? AccountsBundle.currentSchemaVersion,
      'app': accountsBundleAppId,
      'exported_at': '2026-07-04T00:00:00.000Z',
      'app_version': '1.5.0',
      'last_active_uid': uids.first,
      'accounts': [
        for (final uid in uids)
          {
            'player_id': uid,
            'language_code': 'zh-Hant',
            'last_updated': '2026-07-01T00:00:00.000Z',
            'banners': {'1': <Object>[]},
          },
      ],
    });

/// 本機匯出內容（固定字串即可，內容真實性由整合層測試保證）。
String _localJson() => _bundleJson(uids: ['200000002']);

void main() {
  group('syncFingerprint', () {
    test('僅 exported_at 不同 → 指紋相同', () {
      final a = jsonDecode(_bundleJson()) as Map<String, dynamic>;
      final b = jsonDecode(_bundleJson()) as Map<String, dynamic>;
      b['exported_at'] = '2030-01-01T00:00:00.000Z';
      expect(syncFingerprint(jsonEncode(a)), syncFingerprint(jsonEncode(b)));
    });

    test('帳號內容不同 → 指紋不同', () {
      expect(
        syncFingerprint(_bundleJson(uids: ['A'])),
        isNot(syncFingerprint(_bundleJson(uids: ['B']))),
      );
    });
  });

  group('runSyncRound', () {
    test('雲端無檔 → 不合併、直接上傳本機', () async {
      final remote = _FakeRemote();
      var applied = false;
      final outcome = await runSyncRound(
        remote: remote,
        pendingRemovals: const [],
        applyRemote: (_) async => applied = true,
        exportLocal: _localJson,
        clearPendingRemovals: (_) async {},
      );
      expect(applied, isFalse);
      expect(remote.uploads, 1);
      expect(remote.content, _localJson());
      expect(outcome, isA<CloudSyncSuccess>());
      expect(
        (outcome as CloudSyncSuccess).uploadedFingerprint,
        syncFingerprint(_localJson()),
      );
    });

    test('雲端有檔 → 合併後上傳、清 pendingRemovals', () async {
      final remote = _FakeRemote(content: _bundleJson(uids: ['100000001']));
      AccountsBundle? appliedBundle;
      List<String>? cleared;
      await runSyncRound(
        remote: remote,
        pendingRemovals: const ['999'],
        applyRemote: (b) async => appliedBundle = b,
        exportLocal: _localJson,
        clearPendingRemovals: (uids) async => cleared = uids,
      );
      expect(appliedBundle, isNotNull);
      expect(appliedBundle!.accounts.single.data.playerId, '100000001');
      expect(remote.uploads, 1);
      expect(cleared, ['999']);
    });

    test('pendingRemovals 剔除雲端帳號，避免剛刪的帳號復活', () async {
      final remote = _FakeRemote(
        content: _bundleJson(uids: ['100000001', '100000002']),
      );
      AccountsBundle? appliedBundle;
      await runSyncRound(
        remote: remote,
        pendingRemovals: const ['100000001'],
        applyRemote: (b) async => appliedBundle = b,
        exportLocal: _localJson,
        clearPendingRemovals: (_) async {},
      );
      expect(appliedBundle!.accounts.map((a) => a.data.playerId), [
        '100000002',
      ]);
    });

    test('剔除後帳號為空 → 跳過 applyRemote、仍上傳', () async {
      final remote = _FakeRemote(content: _bundleJson(uids: ['100000001']));
      var applied = false;
      await runSyncRound(
        remote: remote,
        pendingRemovals: const ['100000001'],
        applyRemote: (_) async => applied = true,
        exportLocal: _localJson,
        clearPendingRemovals: (_) async {},
      );
      expect(applied, isFalse);
      expect(remote.uploads, 1);
    });

    test('雲端 schema 過新 → 跳過整輪：不合併、不上傳、不清 pendingRemovals', () async {
      final remote = _FakeRemote(
        content: _bundleJson(schema: AccountsBundle.currentSchemaVersion + 1),
      );
      var applied = false;
      var cleared = false;
      final outcome = await runSyncRound(
        remote: remote,
        pendingRemovals: const ['999'],
        applyRemote: (_) async => applied = true,
        exportLocal: _localJson,
        clearPendingRemovals: (_) async => cleared = true,
      );
      expect(outcome, isA<CloudSyncSkippedSchemaTooNew>());
      expect(applied, isFalse);
      expect(remote.uploads, 0);
      expect(cleared, isFalse);
    });

    test('雲端檔損毀 → 視為無檔，上傳本機自癒', () async {
      final remote = _FakeRemote(content: 'not-json{{{');
      var applied = false;
      final outcome = await runSyncRound(
        remote: remote,
        pendingRemovals: const [],
        applyRemote: (_) async => applied = true,
        exportLocal: _localJson,
        clearPendingRemovals: (_) async {},
      );
      expect(applied, isFalse);
      expect(remote.uploads, 1);
      expect(outcome, isA<CloudSyncSuccess>());
    });
  });
}
