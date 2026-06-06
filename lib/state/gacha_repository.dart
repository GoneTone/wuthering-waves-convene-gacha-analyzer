import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/data/gacha_types.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/accounts_bundle.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/concurrent_pool.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_credential.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/record_merge.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/uid_ordering.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/update_progress.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';

export 'package:wuthering_waves_convene_gacha_analyzer/state/update_progress.dart';

/// 10 個卡池全部 `code==0` 且 `data` 全空（該帳號從未喚取）→ 轉成 [UpdateErrorNoRecords]。
class _NoRecordsException implements Exception {
  const _NoRecordsException();
}

/// recordId 疑似失效訊號，由 [_runUpdate] 接住後自動重攔一次；重攔後第二輪仍全失敗才轉成
/// [UpdateErrorGachaFailed]。兩個觸發來源：①第一輪首抓的角色活動（pool 0）失敗即早退
/// （recordId 為 10 池共用，pool 0 失敗 ≈ 全域失效）②第二輪跑滿 10 池且全部 `code != 0`。
class _AllPoolsFailedException implements Exception {
  /// 建立 [_AllPoolsFailedException]，[apiError] 為觸發訊號的失敗池 [GachaApiException]。
  const _AllPoolsFailedException(this.apiError);

  /// 觸發此訊號的失敗池資訊（早退時為 pool 0，全失敗時為最後一個失敗池；供 log 與錯誤文案）。
  final GachaApiException apiError;
}

/// 喚取資料整體狀態，包含帳號資料、更新進度與 bootstrap 旗標。
@immutable
class GachaState {
  /// 建立 [GachaState]。
  const GachaState({
    this.activeUid,
    this.byUid = const {},
    this.progress,
    this.isBootstrapping = true,
  });

  /// 目前作用中的帳號 UID；null 表示無帳號。
  final String? activeUid;

  /// UID → 該帳號存檔資料。
  final Map<String, BannerStorage> byUid;

  /// 目前更新進度；null 表示無進行中的更新。
  final UpdateProgress? progress;

  /// true 表示首次從本地存檔載入尚未完成。
  final bool isBootstrapping;

  /// 作用中帳號的存檔資料；無作用中帳號時為 null。
  BannerStorage? get activeData => activeUid == null ? null : byUid[activeUid];

  /// 所有已知 UID。
  Iterable<String> get knownUids => byUid.keys;

  /// 複製並選擇性覆蓋欄位；[clearActiveUid] / [clearProgress] 為 true 時強制清除對應欄位。
  GachaState copyWith({
    String? activeUid,
    bool clearActiveUid = false,
    Map<String, BannerStorage>? byUid,
    UpdateProgress? progress,
    bool clearProgress = false,
    bool? isBootstrapping,
  }) => GachaState(
    activeUid: clearActiveUid ? null : (activeUid ?? this.activeUid),
    byUid: byUid ?? this.byUid,
    progress: clearProgress ? null : (progress ?? this.progress),
    isBootstrapping: isBootstrapping ?? this.isBootstrapping,
  );
}

// ─── Providers ───

/// 必須在 main.dart 用 overrideWithValue 注入（baseDir 需要 async 取得）
final gachaStorageProvider = Provider<GachaStorage>((ref) {
  throw UnimplementedError('gachaStorageProvider must be overridden in main()');
});

/// [GachaCapture] 實作，預設為 [RustGachaCapture]。
final gachaCaptureProvider = Provider<GachaCapture>(
  (ref) => RustGachaCapture(),
);

/// [GachaFetcher] provider，負責從官方喚取 API 拉取喚取紀錄。
final gachaFetcherProvider = Provider<GachaFetcher>((ref) => GachaFetcher());

/// 每次 update 用一個獨立的 [CancellableHttpClient]（cancel 不會影響其他連線）。
final cancellableHttpClientFactoryProvider =
    Provider<CancellableHttpClientFactory>(
      (ref) => createIoCancellableHttpClient,
    );

/// [GachaRepository] 的 Riverpod provider。
final gachaRepositoryProvider = NotifierProvider<GachaRepository, GachaState>(
  GachaRepository.new,
);

// ─── Notifier ───

/// 喚取資料狀態管理，統一處理 bootstrap、更新、匯入與刪除。
class GachaRepository extends Notifier<GachaState> {
  static final _log = Logger('gacha.repo');

  /// Logger 實例（force-refetch 流程，獨立子樹以利日誌過濾）。
  static final _refetchLog = Logger('gacha.itemimage.refetch');

  /// Logger 實例（匯入流程，獨立子樹以利日誌過濾）。
  static final _importLog = Logger('gacha.import');

  /// build() 內 `_bootstrapLoad()` 完成的 future，供測試 await。
  Completer<void>? _bootstrapCompleter;

  /// 等待初次 bootstrap 完成（load 既有 UID 與 settings）。
  Future<void> waitForBootstrap() =>
      _bootstrapCompleter?.future ?? Future.value();

  @override
  GachaState build() {
    _bootstrapLoad();
    return const GachaState();
  }

  /// 從本地存檔載入全部帳號資料，完成後設定 [GachaState.isBootstrapping] 為 false。
  Future<void> _bootstrapLoad() async {
    _bootstrapCompleter = Completer<void>();
    try {
      final storage = ref.read(gachaStorageProvider);
      final settingsNotifier = ref.read(settingsProvider.notifier);
      await settingsNotifier.waitForLoad();
      if (!ref.mounted) return;

      final uids = await storage.listKnownUids();
      if (!ref.mounted) return;

      final byUid = <String, BannerStorage>{};
      for (final uid in uids) {
        final data = await storage.load(uid);
        if (!ref.mounted) return;
        if (data != null) byUid[uid] = data;
      }

      if (byUid.isEmpty) {
        state = state.copyWith(byUid: byUid, isBootstrapping: false);
        return;
      }

      final settings = ref.read(settingsProvider);
      final ordered = mergeUidOrder(
        knownUids: byUid.keys,
        customOrder: settings.uidOrder,
        lastUpdatedOf: (u) => byUid[u]!.lastUpdated,
      );

      final saved = settings.lastActiveUid;
      final activeUid = (saved != null && byUid.containsKey(saved))
          ? saved
          : ordered.first;

      state = state.copyWith(
        byUid: byUid,
        activeUid: activeUid,
        isBootstrapping: false,
      );

      if (saved != activeUid) {
        await settingsNotifier.setLastActiveUid(activeUid);
        if (!ref.mounted) return;
      }
    } finally {
      _bootstrapCompleter?.complete();
    }
  }

  /// 切換作用中帳號並持久化 lastActiveUid。
  Future<void> setActiveUid(String uid) async {
    if (!state.byUid.containsKey(uid)) return;
    state = state.copyWith(activeUid: uid);
    await ref.read(settingsProvider.notifier).setLastActiveUid(uid);
  }

  /// 清除目前的更新進度狀態。
  void clearProgress() {
    state = state.copyWith(clearProgress: true);
  }

  /// 啟動喚取資料更新，優先使用快取 URL，無快取則觸發 MITM 捕獲。
  Future<void> update() async {
    await _runUpdate(forceRecapture: false);
  }

  /// 實際執行更新流程；[forceRecapture] 為 true 時強制重新 MITM 捕獲。
  Future<void> _runUpdate({required bool forceRecapture}) async {
    if (_isUpdating) return; // 防止重入
    _isUpdating = true;
    _cancelTriggered = false;
    _log.info('update start, forceRecapture=$forceRecapture');

    final cancellable = ref.read(cancellableHttpClientFactoryProvider)();
    _activeCancellable = cancellable;

    // 立刻 set Preparing → ref.listen 立刻觸發 dialog。
    state = state.copyWith(progress: const Preparing());

    try {
      final initialActiveUid = state.activeUid;
      final storage = ref.read(gachaStorageProvider);
      final fetcher = ref.read(gachaFetcherProvider);

      GachaCredential? cred;

      if (!forceRecapture && initialActiveUid != null) {
        final cachedJson = await storage.loadCapturedCredential(
          initialActiveUid,
        );
        if (!ref.mounted) return;
        if (cachedJson != null) {
          try {
            cred = GachaCredential.fromCapturedBody(cachedJson);
            _log.info(
              'using cached credential for playerId='
              '${sanitizeUid(initialActiveUid)}',
            );
          } catch (e) {
            _log.warning('cached credential malformed, recapturing: $e');
          }
        }
      }

      cred ??= await _runMitm(isFallback: false);
      if (!ref.mounted) return;
      if (cred == null) {
        _log.info('update aborted (user cancelled capture)');
        state = state.copyWith(clearProgress: true);
        return;
      }

      try {
        await _fetchAllBanners(
          cred: cred,
          fetcher: fetcher,
          storage: storage,
          client: cancellable.client,
          abortOnFirstPoolFailure: true,
        );
      } on _AllPoolsFailedException catch (e) {
        // 第一輪 pool 0 失敗（≈ recordId 失效）：沿用既有 recordId 失效流程自動重攔一次。
        if (!ref.mounted) return;
        _log.warning(
          'first pool failed (code=${e.apiError.code}), falling back to recapture',
        );
        final newCred = await _runMitm(isFallback: true);
        if (!ref.mounted) return;
        if (newCred == null) {
          _log.info('recapture cancelled by user');
          state = state.copyWith(clearProgress: true);
          return;
        }
        try {
          await _fetchAllBanners(
            cred: newCred,
            fetcher: fetcher,
            storage: storage,
            client: cancellable.client,
            abortOnFirstPoolFailure: false,
          );
        } on _AllPoolsFailedException catch (e2) {
          // 重攔後仍全失敗才放棄；文案已改為不再要求重開頁（errorGachaFailed）。
          if (!ref.mounted) return;
          _log.warning(
            'still all-failing after recapture, code=${e2.apiError.code}',
          );
          state = state.copyWith(
            progress: UpdateFailed(
              UpdateErrorGachaFailed(e2.apiError.code, e2.apiError.message),
            ),
          );
        } on _NoRecordsException {
          if (!ref.mounted) return;
          state = state.copyWith(
            progress: const UpdateFailed(UpdateErrorNoRecords()),
          );
        } on http.ClientException catch (e2) {
          if (!ref.mounted) return;
          if (_cancelTriggered) {
            state = state.copyWith(clearProgress: true);
          } else {
            _log.warning(
              'http client error (post-recapture): ${e2.message}'
              '${e2.uri != null ? " uri=${sanitizeUrl(e2.uri!.toString())}" : ""}',
            );
            state = state.copyWith(progress: UpdateFailed(_friendlyError(e2)));
          }
        } catch (e2, st) {
          if (!ref.mounted) return;
          _log.severe('update unexpected error (post-recapture)', e2, st);
          state = state.copyWith(progress: UpdateFailed(_friendlyError(e2)));
        }
      } on _NoRecordsException {
        if (!ref.mounted) return;
        state = state.copyWith(
          progress: const UpdateFailed(UpdateErrorNoRecords()),
        );
      } on http.ClientException catch (e) {
        if (!ref.mounted) return;
        if (_cancelTriggered) {
          _log.info('update cancelled (http client closed)');
          state = state.copyWith(clearProgress: true);
        } else {
          _log.warning(
            'http client error: ${e.message}'
            '${e.uri != null ? " uri=${sanitizeUrl(e.uri!.toString())}" : ""}',
          );
          state = state.copyWith(progress: UpdateFailed(_friendlyError(e)));
        }
      } catch (e, st) {
        if (!ref.mounted) return;
        _log.severe('update unexpected error', e, st);
        state = state.copyWith(progress: UpdateFailed(_friendlyError(e)));
      }
    } finally {
      _activeCancellable?.client.close();
      _activeCancellable = null;
      _cancelTriggered = false;
      _isUpdating = false;
    }
  }

  /// 啟動 MITM 捕獲會話並等候 [GachaCredential]；[isFallback] true 表示此為 recordId 全池失效後觸發的補救（fallback）捕獲。
  Future<GachaCredential?> _runMitm({required bool isFallback}) async {
    state = state.copyWith(progress: WaitingForCapture(isFallback: isFallback));
    final session = ref.read(gachaCaptureProvider).start();
    _activeCancel = session.cancel;
    _log.info('MITM ${isFallback ? "fallback" : "primary"} session started');
    try {
      final result = await session.result;
      _log.info('MITM session done, hasCredential=${result != null}');
      return result;
    } finally {
      _activeCancel = null;
    }
  }

  /// 依序拉取 10 個 cardPoolType 的整池全歷史，合併存檔。
  ///
  /// 逐池容錯：單池 `code!=0` 保留舊資料、記入 `failed` 後繼續（最終以
  /// `UpdateCompleted.failedBanners` 顯示部分失敗紅字）；**10 池全失敗** → 丟
  /// [_AllPoolsFailedException]（由 [_runUpdate] 自動重攔一次）；全部成功但每池皆空且
  /// 無既有資料 → 丟 [_NoRecordsException]。網路層 [http.ClientException] 不在此攔截。
  ///
  /// [abortOnFirstPoolFailure] 為 true（第一輪）時，首抓的角色活動（pool 0，`i == 0`）一
  /// 失敗就立刻丟 [_AllPoolsFailedException] 早退、不再續抓其餘 9 池（recordId 為 10 池共用，
  /// pool 0 失敗 ≈ 全域失效）；為 false（重攔後第二輪）時維持「跑滿全池、全失敗才判定」的容錯。
  Future<void> _fetchAllBanners({
    required GachaCredential cred,
    required GachaFetcher fetcher,
    required GachaStorage storage,
    required http.Client client,
    required bool abortOnFirstPoolFailure,
  }) async {
    final endpoint = Uri.parse(
      'https://gmserver-api.aki-game2.net/gacha/record/query',
    );
    final playerId = cred.playerId;

    final existing =
        state.byUid[playerId] ??
        BannerStorage(
          playerId: playerId,
          languageCode: cred.languageCode,
          lastUpdated: DateTime.utc(1970),
          banners: {for (final t in gachaTypes) t.key: <GachaRecord>[]},
        );

    final mergedBanners = <String, List<GachaRecord>>{};
    final failed = <String>[];
    GachaApiException? lastApiError;
    var totalNew = 0;
    var anyNonEmpty = false;

    for (var i = 0; i < gachaTypes.length; i++) {
      final t = gachaTypes[i];
      if (i > 0) {
        await Future<void>.delayed(fetcher.rateLimit);
        if (!ref.mounted) return;
      }
      state = state.copyWith(
        progress: FetchingBanner(
          displayName: t.nameKey,
          poolIndex: i + 1,
          poolCount: gachaTypes.length,
          newRecordsSoFar: totalNew,
        ),
      );

      try {
        final result = await fetcher.fetchPool(
          endpoint: endpoint,
          cred: cred,
          cardPoolType: t.cardPoolType,
          client: client,
        );
        if (!ref.mounted) return;

        final existingForPool =
            existing.banners[t.key] ?? const <GachaRecord>[];
        final merged = mergeOrderedRecords(result.records, existingForPool);
        mergedBanners[t.key] = merged;
        if (merged.isNotEmpty) anyNonEmpty = true;
        totalNew += merged.length - existingForPool.length;
      } on GachaApiException catch (e) {
        // 第一輪：首抓的角色活動（pool 0）失敗 ≈ 10 池共用的 recordId 失效。不續抓其餘 9
        // 池，直接丟全池失效訊號交由 _runUpdate 自動重攔。
        if (abortOnFirstPoolFailure && i == 0) {
          _log.warning(
            'first pool ${t.key} failed code=${e.code} msg=${e.message}, '
            'aborting to recapture',
          );
          throw _AllPoolsFailedException(e);
        }
        // 單池 code!=0：保留舊資料、記入 failed，繼續抓其他池；全池皆失敗時於迴圈後
        // 轉成 _AllPoolsFailedException 觸發自動重攔。http.ClientException 不在此攔截，
        // 往上拋給 _runUpdate 當作網路層失敗。
        _log.warning('pool ${t.key} failed code=${e.code} msg=${e.message}');
        lastApiError = e;
        mergedBanners[t.key] = existing.banners[t.key] ?? const <GachaRecord>[];
        failed.add(t.nameKey);
      }
    }

    if (failed.length == gachaTypes.length) {
      _log.warning(
        'all ${gachaTypes.length} pools failed, code=${lastApiError!.code}',
      );
      throw _AllPoolsFailedException(lastApiError);
    }
    // 僅在「無任何池失敗」時才能斷定帳號從未喚取；有池失敗時失敗池可能其實有紀錄，
    // 不可誤判為 NoRecords，應走存檔＋部分失敗紅字。
    if (failed.isEmpty &&
        !anyNonEmpty &&
        existing.banners.values.every((l) => l.isEmpty)) {
      throw const _NoRecordsException();
    }

    final updatedAt = DateTime.now().toUtc();
    final newData = BannerStorage(
      playerId: playerId,
      languageCode: cred.languageCode,
      lastUpdated: updatedAt,
      banners: mergedBanners,
    );
    await storage.save(newData);
    if (!ref.mounted) return;
    await storage.saveCapturedCredential(playerId, cred.toJsonString());
    if (!ref.mounted) return;

    final newByUid = Map<String, BannerStorage>.from(state.byUid)
      ..[playerId] = newData;
    _log.info(
      'update completed: playerId=${sanitizeUid(playerId)} totalNew=$totalNew',
    );
    state = state.copyWith(byUid: newByUid, activeUid: playerId);
    if (!ref.mounted) return;
    await ref.read(settingsProvider.notifier).setLastActiveUid(playerId);
    if (!ref.mounted) return;

    // 圖片補抓階段（best-effort，不影響 UpdateCompleted）。
    var itemImagesDownloaded = 0;
    try {
      itemImagesDownloaded = await _fetchItemImages(client);
    } catch (e, st) {
      _log.warning('image stage threw (ignored)', e, st);
    }
    if (!ref.mounted) return;
    if (_cancelTriggered) {
      state = state.copyWith(clearProgress: true);
      return;
    }
    state = state.copyWith(
      progress: UpdateCompleted(
        totalNewRecords: totalNew,
        failedBanners: failed,
        updatedAt: updatedAt,
        itemImagesDownloaded: itemImagesDownloaded,
      ),
    );
  }

  /// 防 re-entrancy 旗標，update 進行中為 true。
  bool _isUpdating = false;

  /// 使用者觸發取消時設為 true，避免將 ClientException 誤判為錯誤。
  bool _cancelTriggered = false;

  /// 目前 MITM 會話的取消函式。
  Future<void> Function()? _activeCancel;

  /// 目前 HTTP 請求的可取消 client，取消後關閉所有連線。
  CancellableHttpClient? _activeCancellable;

  /// 取消 Preparing 階段的 HTTP 請求。
  void cancelPreparing() {
    _cancelTriggered = true;
    _activeCancellable?.cancel();
  }

  /// 取消正在進行的 MITM 捕獲會話。
  Future<void> cancelCapture() async {
    final cancel = _activeCancel;
    if (cancel != null) {
      await cancel();
    }
  }

  /// 強制重新 MITM 捕獲並更新（忽略快取 URL）。
  Future<void> forceRecaptureAndUpdate() async {
    await _runUpdate(forceRecapture: true);
  }

  /// 強制重抓所有帳號物品的角色圖片。
  ///
  /// 流程：
  ///   1. 互斥檢查：`state.progress != null` 直接 no-op（UI 應已 disable 按鈕）。
  ///   2. emit `Preparing`、建 cancellable client。
  ///   3. `itemImageIndexProvider.notifier.resetAll()` 清 index + 刪 cache 目錄。
  ///   4. 呼叫 [_fetchItemImages] 跑單階段補圖管線。
  ///   5. 結束依取消狀態 emit `UpdateCompleted` 或清 progress。
  ///   6. 清檔失敗時 emit `UpdateFailed(UpdateErrorWipeItemImageCache)`。
  Future<void> forceRefetchAllItemImages() async {
    if (state.progress != null) {
      _refetchLog.info('skip: another progress in-flight');
      return;
    }
    if (_isUpdating) return;
    _isUpdating = true;
    _cancelTriggered = false;

    final totalUids = state.byUid.length;
    _refetchLog.info('start, totalUids=$totalUids');

    final cancellable = ref.read(cancellableHttpClientFactoryProvider)();
    _activeCancellable = cancellable;
    state = state.copyWith(progress: const Preparing());

    try {
      try {
        await ref.read(itemImageIndexProvider.notifier).resetAll();
        if (!ref.mounted) return;
        _refetchLog.info('wiped (index+cache cleared)');
      } catch (e, st) {
        _refetchLog.severe('wipeFailed', e, st);
        if (!ref.mounted) return;
        state = state.copyWith(
          progress: UpdateFailed(
            UpdateErrorWipeItemImageCache(sanitizeFsPath(e.toString())),
          ),
        );
        return;
      }

      var itemImagesDownloaded = 0;
      try {
        itemImagesDownloaded = await _fetchItemImages(cancellable.client);
      } catch (e, st) {
        _refetchLog.warning('item image stage threw (ignored)', e, st);
      }
      if (!ref.mounted) return;

      if (_cancelTriggered) {
        _refetchLog.warning('cancelled');
        state = state.copyWith(clearProgress: true);
        return;
      }

      _refetchLog.info('done');
      state = state.copyWith(
        progress: UpdateCompleted(
          totalNewRecords: 0,
          failedBanners: const [],
          updatedAt: DateTime.now().toUtc(),
          itemImagesDownloaded: itemImagesDownloaded,
        ),
      );
    } finally {
      _activeCancellable?.client.close();
      _activeCancellable = null;
      _cancelTriggered = false;
      _isUpdating = false;
    }
  }

  /// 匯入帳號 bundle，並接續以增量方式補抓物品角色圖片。
  ///
  /// 流程：
  ///   1. 互斥檢查：`state.progress != null` 直接 no-op。
  ///   2. emit `Preparing`、建 cancellable client。
  ///   3. 跑 [_runImport] 寫入 storage 與更新 settings。
  ///   4. 跑 [_fetchItemImages] 單階段（best-effort，例外 warn-log）。
  ///   5. 結束一律 emit `UpdateCompleted(importSummary: ...)`，不論取消與否。
  ///      取消時 import 已寫入 storage 無法回滾，仍透過 dialog 告知使用者
  ///      「資料已匯入、圖片下載被略過」。
  Future<ImportResult> importAccountsAndFetchItemImages(
    String bundleJson,
  ) async {
    const emptyResult = ImportResult(
      successAccounts: 0,
      totalRecords: 0,
      failedUids: [],
    );
    if (state.progress != null) {
      _importLog.info('skip: another progress in-flight');
      return emptyResult;
    }
    if (_isUpdating) {
      return emptyResult;
    }
    _isUpdating = true;
    _cancelTriggered = false;

    AccountsBundle bundle;
    try {
      final decoded = jsonDecode(bundleJson) as Map<String, dynamic>;
      bundle = AccountsBundle.fromJson(decoded);
    } catch (e) {
      _importLog.warning('bundle parse failed: $e');
      _isUpdating = false;
      return emptyResult;
    }

    _importLog.info('start, accounts=${bundle.accounts.length}');

    final cancellable = ref.read(cancellableHttpClientFactoryProvider)();
    _activeCancellable = cancellable;
    state = state.copyWith(progress: const Preparing());

    try {
      final result = await _runImport(bundle);
      if (!ref.mounted) return result;
      _importLog.info(
        'import done: success=${result.successAccounts} '
        'failed=[${result.failedUids.map(sanitizeUid).join(",")}] '
        'records=${result.totalRecords}',
      );

      if (result.successAccounts == 0) {
        // 無帳號匯入成功（拒絕路徑），不觸發補圖。
        state = state.copyWith(
          progress: UpdateCompleted(
            totalNewRecords: 0,
            failedBanners: const [],
            updatedAt: DateTime.now().toUtc(),
            itemImagesDownloaded: 0,
            importSummary: result,
          ),
        );
        return result;
      }

      var itemImagesDownloaded = 0;
      try {
        itemImagesDownloaded = await _fetchItemImages(cancellable.client);
      } catch (e, st) {
        _importLog.warning('item image stage threw (ignored)', e, st);
      }
      if (!ref.mounted) return result;

      if (_cancelTriggered) {
        _importLog.info(
          'cancelled during item image fetch, still emitting completed',
        );
      }
      state = state.copyWith(
        progress: UpdateCompleted(
          totalNewRecords: 0,
          failedBanners: const [],
          updatedAt: DateTime.now().toUtc(),
          itemImagesDownloaded: itemImagesDownloaded,
          importSummary: result,
        ),
      );
      _importLog.info('done, images=$itemImagesDownloaded');
      return result;
    } finally {
      _activeCancellable?.client.close();
      _activeCancellable = null;
      _cancelTriggered = false;
      _isUpdating = false;
    }
  }

  /// 刪除目前作用中帳號的所有資料。
  Future<void> clearActive() async {
    final uid = state.activeUid;
    if (uid == null) return;
    await removeUid(uid);
  }

  /// 刪除所有帳號資料並重置設定。
  Future<void> clearAll() async {
    final storage = ref.read(gachaStorageProvider);
    await storage.clearAll();
    if (!ref.mounted) return;
    await ref.read(settingsProvider.notifier).clearAllUidPreferences();
    if (!ref.mounted) return;
    state = const GachaState(isBootstrapping: false);
    _log.info('cleared all gacha data');
  }

  /// 批次匯入 [AccountsBundle]，合併現有帳號資料與偏好設定。
  ///
  /// 純資料層操作，**不**啟動 progress 或物品圖片抓取。
  /// 對外入口請用 [importAccountsAndFetchItemImages]。
  Future<ImportResult> _runImport(AccountsBundle bundle) async {
    final storage = ref.read(gachaStorageProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);

    final newByUid = Map<String, BannerStorage>.from(state.byUid);
    final failed = <String>[];
    var totalRecords = 0;
    var successCount = 0;

    for (final account in bundle.accounts) {
      try {
        await storage.save(account.data);
        if (!ref.mounted) {
          return ImportResult(
            successAccounts: successCount,
            totalRecords: totalRecords,
            failedUids: failed,
          );
        }
        newByUid[account.data.playerId] = account.data;
        successCount++;
        for (final list in account.data.banners.values) {
          totalRecords += list.length;
        }
      } catch (_) {
        failed.add(account.data.playerId);
      }
    }

    final currentSettings = ref.read(settingsProvider);
    final mergedAliases = Map<String, String>.from(currentSettings.uidAliases);
    for (final account in bundle.accounts) {
      if (failed.contains(account.data.playerId)) continue;
      final a = account.alias?.trim();
      if (a == null || a.isEmpty) {
        mergedAliases.remove(account.data.playerId);
      } else {
        mergedAliases[account.data.playerId] = a;
      }
    }

    final exportedOrder = bundle.accounts
        .where((a) => !failed.contains(a.data.playerId))
        .map((a) => a.data.playerId)
        .toList();
    final exportedSet = exportedOrder.toSet();
    final remaining = currentSettings.uidOrder
        .where((u) => !exportedSet.contains(u))
        .toList();
    final newOrder = [...exportedOrder, ...remaining];

    final desiredActive = bundle.lastActiveUid;
    final fallback =
        state.activeUid != null && newByUid.containsKey(state.activeUid)
        ? state.activeUid
        : (newByUid.isEmpty
              ? null
              : (newOrder.isEmpty ? newByUid.keys.first : newOrder.first));
    final newActive =
        (desiredActive != null && newByUid.containsKey(desiredActive))
        ? desiredActive
        : fallback;

    await settingsNotifier.applyImportedPreferences(
      aliases: mergedAliases,
      uidOrder: newOrder,
      lastActiveUid: newActive,
    );
    if (!ref.mounted) {
      return ImportResult(
        successAccounts: successCount,
        totalRecords: totalRecords,
        failedUids: failed,
      );
    }

    state = state.copyWith(
      byUid: newByUid,
      activeUid: newActive,
      clearActiveUid: newActive == null,
    );

    _log.info(
      'import: success=$successCount '
      'failed=[${failed.join(",")}] '
      'records=$totalRecords',
    );
    return ImportResult(
      successAccounts: successCount,
      totalRecords: totalRecords,
      failedUids: failed,
    );
  }

  /// 測試用：暴露 [_runImport] 給單元測試（驗證純 import 邏輯，
  /// 不必 mock 物品圖片 fetcher）。生產勿用。
  @visibleForTesting
  Future<ImportResult> debugImportOnly(AccountsBundle bundle) =>
      _runImport(bundle);

  /// 依 uidOrder 與最後更新時間挑選 fallback 作用中 UID。
  String? _pickFallbackActive(Map<String, BannerStorage> byUid) {
    if (byUid.isEmpty) return null;
    final order = ref.read(settingsProvider).uidOrder;
    return mergeUidOrder(
      knownUids: byUid.keys,
      customOrder: order,
      lastUpdatedOf: (u) => byUid[u]!.lastUpdated,
    ).first;
  }

  /// 刪除指定 UID 的帳號資料並更新設定。
  Future<void> removeUid(String uid) async {
    final storage = ref.read(gachaStorageProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);

    await storage.delete(uid);
    if (!ref.mounted) return;
    await settingsNotifier.removeUidFromSettings(uid);
    if (!ref.mounted) return;

    final newByUid = Map<String, BannerStorage>.from(state.byUid)..remove(uid);
    if (state.activeUid == uid) {
      final next = _pickFallbackActive(newByUid);
      state = next == null
          ? state.copyWith(byUid: newByUid, clearActiveUid: true)
          : state.copyWith(byUid: newByUid, activeUid: next);
      if (!ref.mounted) return;
      await settingsNotifier.setLastActiveUid(next);
    } else {
      state = state.copyWith(byUid: newByUid);
    }
    _log.info('cleared uid=${sanitizeUid(uid)}');
  }

  /// 補齊所有帳號喚取記錄聯集物品的 icon 與 dialog 詳情（catalog + prefetch）。
  ///
  /// 流程：
  ///   1. 逐筆收集 `id → 出現過的擷取語言集合`（per-record lang）。
  ///   2. 工作閘：icon 未就緒、kind 未分類（含既有快取 icon 的升級回填）、某 lang
  ///      詳情未抓、或角色 hasLuckdraw 尚未評估（legacy backfill）→ 需處理。
  ///      全無 → early return（不打 catalog）。
  ///   3. 對每個出現過的語言抓三清單（角色／武器／道具），union 成歸屬表（kind + icon）；
  ///      icon 語言無關，union 容忍個別語系缺漏。kind 由 catalog 歸屬決定，不依
  ///      `resourceType` 語言對應表。
  ///   4. 分類 + icon 正負取：catalog 命中 → [mergeIcon] 正取（含 kind）加入
  ///      toDownload；既有 icon 但 kind==null → 只補 kind 不重下載；三清單皆無 →
  ///      負取（kind 維持 null）。
  ///   5. **取得物品資料階段**：並行逐 `(id, lang)` 預抓詳情（icon 正取、非道具、
  ///      該 lang 未抓或 luckdraw 尚未評估）寫 [mergeItemDetail]；對所有
  ///      `id × lang` 計數 emit `phase: checking`（含負取／道具）。
  ///   6. 角色 icon 升級為詳情提供的 256px HD 版。
  ///   7. **下載階段**：只下載 toDownload 的 icon（立繪走 dialog lazy）；emit
  ///      `phase: downloading`。toDownload 為空則直接 return。
  ///
  /// 每筆獨立 try/catch，單筆失敗不終止整段。取消（`_cancelTriggered` 或
  /// `!ref.mounted`）早退。回傳本次成功寫入磁碟的 icon 張數。
  Future<int> _fetchItemImages(http.Client client) async {
    var downloaded = 0;
    final fetcher = ref.read(itemImageFetcherProvider);
    final indexNotifier = ref.read(itemImageIndexProvider.notifier);
    final cacheDir = ref.read(itemImageCacheDirProvider);
    await indexNotifier.waitForLoad();

    // (1) 逐筆收集 id → 出現過的擷取語言集合（per-record lang）。
    final langsById = <int, Set<String>>{};
    for (final data in state.byUid.values) {
      for (final list in data.banners.values) {
        for (final r in list) {
          final lang = r.languageCode;
          if (lang.isEmpty) continue;
          langsById.putIfAbsent(r.resourceId, () => {}).add(lang);
        }
      }
    }
    if (langsById.isEmpty) return downloaded;

    // (2) gate：icon 未就緒、kind 未分類（含既有快取 icon 的升級回填）、某 lang
    //     詳情未抓、或角色 hasLuckdraw 尚未評估（legacy backfill）→ 需處理。
    //     全無 → early return（不打 catalog）。
    final idx0 = ref.read(itemImageIndexProvider);
    bool needsWork(int id) {
      final existing = idx0.lookupImage(id);
      if (needsItemImageFetch(
        existing: existing,
        cacheDir: cacheDir,
        resourceId: id,
      )) {
        return true;
      }
      if (existing?.kind == null) return true;
      // 既有使用者升級 backfill：角色 kind 已知但 luckdraw 尚未評估（hasLuckdraw==null）
      // 時，即使詳情已抓也要重新處理一次以評估 hasLuckdraw（評估後為定值，之後不再重抓）。
      if (existing!.kind == kItemKindCharacter &&
          existing.hasLuckdraw == null) {
        return true;
      }
      if (existing.kind != kItemKindItem) {
        for (final lang in langsById[id]!) {
          if (!existing.detailByLang.containsKey(lang)) return true;
        }
      }
      return false;
    }

    final workIds = langsById.keys.where(needsWork).toSet();
    if (workIds.isEmpty) return downloaded;

    bool isAborted() => !ref.mounted || _cancelTriggered;

    // (3) 抓 catalog：對每個出現過的語言抓三清單，union 成歸屬表（kind + icon）。
    //     icon／歸屬語言無關，union 容忍個別語系缺漏；首個命中語言為準。
    const allKinds = {kItemKindCharacter, kItemKindWeapon, kItemKindItem};
    final iconById = <int, String>{};
    final kindById = <int, String>{};
    final allLangs = {for (final id in workIds) ...langsById[id]!};
    for (final lang in allLangs) {
      if (isAborted()) return downloaded;
      final catalog = await fetcher.fetchCatalog(
        lang: lang,
        kinds: allKinds,
        client: client,
      );
      for (final kind in allKinds) {
        final m = catalog.iconByKindId[kind];
        if (m == null) continue;
        m.forEach((id, url) {
          if (url.isEmpty) return;
          iconById.putIfAbsent(id, () => url);
          kindById.putIfAbsent(id, () => kind);
        });
      }
    }

    // (4) 分類 + icon 正負取。
    final toDownload = <(int id, String iconUrl)>[];
    final positiveIds = <int>{};
    final hdIconById = <int, String>{};
    for (final id in workIds) {
      if (isAborted()) return downloaded;
      final existing = ref.read(itemImageIndexProvider).lookupImage(id);
      final iconNeeded = needsItemImageFetch(
        existing: existing,
        cacheDir: cacheDir,
        resourceId: id,
      );
      final catKind = kindById[id];
      final catIcon = iconById[id];
      if (catKind != null && catIcon != null) {
        positiveIds.add(id);
        if (iconNeeded) {
          await indexNotifier.mergeIcon(
            resourceId: id,
            iconUrl: catIcon,
            kind: catKind,
            noImage: false,
            permanentNoImage: false,
          );
          toDownload.add((id, catIcon));
        } else if (existing?.kind == null) {
          // 升級回填：icon 已快取但 kind 未分類 → 只補 kind、不重下載。
          await indexNotifier.mergeIcon(
            resourceId: id,
            iconUrl: existing!.iconUrl,
            kind: catKind,
            noImage: existing.noImage,
            permanentNoImage: existing.permanentNoImage,
          );
        }
      } else if (iconNeeded) {
        // 三清單皆無 → 負取（保留既有 kind=null；itemTypeKeyOf 退原始字串）。
        await indexNotifier.mergeIcon(
          resourceId: id,
          iconUrl: null,
          kind: null,
          noImage: true,
          permanentNoImage: false,
        );
      }
    }

    // (5) 取得物品資料階段：對「每個 (id, lang)」計 checking 進度（保留既有語意：
    //     total = 待查 id×lang 數，含負取／道具）。正取角色／武器且該 lang 詳情未抓
    //     （或 luckdraw 尚未評估）時抓詳情；其餘只計進度不抓。
    final checkWorklist = <(int id, String lang)>[
      for (final id in workIds)
        for (final lang in langsById[id]!) (id, lang),
    ];
    var checkedDone = 0;
    await runConcurrent<(int, String)>(
      items: checkWorklist,
      concurrency: fetcher.downloadConcurrency,
      shouldAbort: isAborted,
      worker: (item) async {
        final (id, lang) = item;
        final kind = kindById[id];
        try {
          if (kind != null &&
              kind != kItemKindItem &&
              positiveIds.contains(id)) {
            final existing = ref.read(itemImageIndexProvider).lookupImage(id);
            final detailAlready =
                existing?.detailByLang.containsKey(lang) ?? false;
            final luckdrawUnevaluated =
                kind == kItemKindCharacter && existing?.hasLuckdraw == null;
            if (!detailAlready || luckdrawUnevaluated) {
              final detail = await fetcher.fetchItemDetail(
                resourceId: id,
                kind: kind,
                lang: lang,
                client: client,
              );
              if (detail != null) {
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
                if (kind == kItemKindCharacter && detail.iconHd.isNotEmpty) {
                  hdIconById[id] = detail.iconHd;
                }
              }
            }
          }
        } catch (e) {
          _log.warning('item detail fetch failed id=$id lang=$lang err=$e');
        }
        if (!ref.mounted) return;
        checkedDone++;
        state = state.copyWith(
          progress: FetchingItemImages(
            phase: ItemImagePhase.checking,
            doneCount: checkedDone,
            totalCount: checkWorklist.length,
          ),
        );
      },
    );

    // (6) 角色 icon 升級為詳情提供的 256px HD 版。序列、在並行 5 之後 → 無 race。
    for (var i = 0; i < toDownload.length; i++) {
      final hd = hdIconById[toDownload[i].$1];
      if (hd == null) continue;
      await indexNotifier.mergeIcon(
        resourceId: toDownload[i].$1,
        iconUrl: hd,
        kind: kItemKindCharacter,
        noImage: false,
        permanentNoImage: false,
      );
      toDownload[i] = (toDownload[i].$1, hd);
    }

    // (7) 下載階段：只下載 icon（立繪走 dialog lazy）。
    if (toDownload.isEmpty || isAborted()) return downloaded;
    var downloadedDone = 0;
    await runConcurrent<(int, String)>(
      items: toDownload,
      concurrency: fetcher.downloadConcurrency,
      shouldAbort: isAborted,
      worker: (item) async {
        final (id, iconUrl) = item;
        try {
          final iconBytes = await fetcher.downloadImage(iconUrl, client);
          if (iconBytes != null) {
            final file = itemIconCacheFile(
              baseDir: cacheDir,
              resourceId: id,
              url: iconUrl,
            );
            await writeImageFileAtomic(file, iconBytes);
            indexNotifier.bumpCacheRevision();
            downloaded++;
          }
        } catch (e) {
          _log.warning('item icon download failed id=$id err=$e');
        }
        if (!ref.mounted) return;
        downloadedDone++;
        state = state.copyWith(
          progress: FetchingItemImages(
            phase: ItemImagePhase.downloading,
            doneCount: downloadedDone,
            totalCount: toDownload.length,
          ),
        );
      },
    );
    return downloaded;
  }

  /// 測試用：略過 banner fetch 直接跑 item image 階段（用既有 state.byUid）。
  @visibleForTesting
  Future<void> debugRunItemImagesOnly() async {
    _cancelTriggered = false;
    final cancellable = ref.read(cancellableHttpClientFactoryProvider)();
    try {
      await _fetchItemImages(cancellable.client);
    } finally {
      cancellable.client.close();
    }
  }

  /// 測試用：直接塞一筆帳號到 state.byUid（不走 bootstrap/storage）。生產勿用。
  @visibleForTesting
  void debugSeedAccount(BannerStorage data) {
    final next = Map<String, BannerStorage>.from(state.byUid)
      ..[data.playerId] = data;
    state = state.copyWith(byUid: next, activeUid: data.playerId);
  }

  /// 將各種 exception 轉換成對應的 [UpdateError] 子類，供 UI 顯示。
  UpdateError _friendlyError(Object e) => switch (e) {
    _NoRecordsException() => const UpdateErrorNoRecords(),
    GachaApiException(:final code, :final message) => UpdateErrorGachaFailed(
      code,
      message,
    ),
    FormatException(:final message) => UpdateErrorOther(message),
    http.ClientException(:final message, :final uri) => UpdateErrorOther(
      uri != null ? '$message ($uri)' : message,
    ),
    _ => UpdateErrorOther(e.toString()),
  };

  /// 強制覆寫 progress 狀態，僅供測試使用。
  @visibleForTesting
  void debugSetProgress(UpdateProgress p) {
    state = state.copyWith(progress: p);
  }
}
