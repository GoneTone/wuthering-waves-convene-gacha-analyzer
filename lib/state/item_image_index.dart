import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';

/// 物品圖片 index 儲存層，main.dart 用 `overrideWithValue` 注入。
final itemImageIndexStorageProvider = Provider<ItemImageIndexStorage>((ref) {
  throw UnimplementedError(
    'itemImageIndexStorageProvider must be overridden in main()',
  );
});

/// 物品圖檔快取目錄，main.dart 用 `overrideWithValue` 注入。
final itemImageCacheDirProvider = Provider<Directory>((ref) {
  throw UnimplementedError(
    'itemImageCacheDirProvider must be overridden in main()',
  );
});

/// 物品圖片 API fetcher；預設值即可，無需 override。
final itemImageFetcherProvider = Provider<ItemImageFetcher>(
  (ref) => ItemImageFetcher(),
);

/// 當前載入的 [ItemImageIndex]；透過 [ItemImageIndexNotifier] 變更。
final itemImageIndexProvider =
    NotifierProvider<ItemImageIndexNotifier, ItemImageIndex>(
      ItemImageIndexNotifier.new,
    );

/// 包裝 [ItemImageIndexStorage] 的 Riverpod Notifier；mutation 後同步 persist。
class ItemImageIndexNotifier extends Notifier<ItemImageIndex> {
  /// Logger 實例（item_image.notifier 命名空間）。
  static final _log = Logger('item_image.notifier');

  Completer<void>? _loadCompleter;

  /// 保護所有 merge*（mergeIcon／mergeItemDetail）的 read-modify-write，
  /// 避免並發互相覆蓋。
  final _lock = Lock();

  @override
  ItemImageIndex build() {
    _loadCompleter = Completer<void>();
    unawaited(_load());
    return const ItemImageIndex.empty();
  }

  /// 從 storage 載入並 emit 給 state。
  Future<void> _load() async {
    try {
      final storage = ref.read(itemImageIndexStorageProvider);
      final loaded = await storage.load();
      if (!ref.mounted) return;
      state = loaded;
    } catch (e, st) {
      _log.warning('load failed', e, st);
    } finally {
      _loadCompleter?.complete();
    }
  }

  /// 等待初始 load 結束。
  Future<void> waitForLoad() => _loadCompleter?.future ?? Future.value();

  /// 寫入單一 resourceId 的 icon 抓取結果並 persist（保留既有 detailByLang 與 kind）。
  ///
  /// 正取：傳 `iconUrl` 非 null + `noImage:false`；負取：`noImage:true` + url 傳 null。
  /// [kind] 為可選，不傳時保留既有 kind（避免二次 mergeIcon 清空已分類的 kind）。
  Future<void> mergeIcon({
    required int resourceId,
    required String? iconUrl,
    required bool noImage,
    required bool permanentNoImage,
    String? kind,
  }) async {
    await _lock.synchronized(() async {
      final prev = state.items[resourceId];
      final newItems = Map<int, ItemImageEntry>.from(state.items)
        ..[resourceId] = ItemImageEntry(
          iconUrl: iconUrl,
          noImage: noImage,
          permanentNoImage: permanentNoImage,
          detailByLang: prev?.detailByLang ?? const {},
          hasLuckdraw: prev?.hasLuckdraw,
          kind: kind ?? prev?.kind,
        );
      await _saveAndEmit(ItemImageIndex(items: newItems));
      _log.fine(
        'mergeIcon resourceId=$resourceId noImage=$noImage '
        'hasIcon=${iconUrl?.isNotEmpty == true} kind=${kind ?? prev?.kind}',
      );
    });
  }

  /// 寫入單一 (resourceId, lang) 的 dialog 詳情並 persist（保留既有 icon）。
  ///
  /// [hasLuckdraw] 遵循「一旦為 true，永遠為 true」語意，跨 lang 多次呼叫均適用。
  /// 每次詳情抓取必然帶來確定值（非 null），可消除「尚未評估」狀態。
  Future<void> mergeItemDetail({
    required int resourceId,
    required String lang,
    required ItemDetailL10n detail,
    bool hasLuckdraw = false,
  }) async {
    await _lock.synchronized(() async {
      final prev = state.items[resourceId];
      final mergedDetail = <String, ItemDetailL10n>{
        if (prev != null) ...prev.detailByLang,
        lang: detail,
      };
      final newItems = Map<int, ItemImageEntry>.from(state.items)
        ..[resourceId] = ItemImageEntry(
          iconUrl: prev?.iconUrl,
          noImage: prev?.noImage ?? false,
          permanentNoImage: prev?.permanentNoImage ?? false,
          detailByLang: mergedDetail,
          hasLuckdraw: hasLuckdraw || (prev?.hasLuckdraw ?? false),
          kind: prev?.kind,
        );
      await _saveAndEmit(ItemImageIndex(items: newItems));
      _log.fine(
        'merge detail id=$resourceId lang=$lang intro=${detail.intro.isNotEmpty}',
      );
    });
  }

  /// 在 cache 檔案下載完成後呼叫；state 內容不變但 identity 換新，
  /// 觸發 watch itemImageIndexProvider 的 widget 重新 build 以挑到新檔。
  void bumpCacheRevision() {
    state = ItemImageIndex(items: state.items);
  }

  /// 強制重抓圖片用：清空整個 index 與 cache 目錄。
  Future<void> resetAll() async {
    final storage = ref.read(itemImageIndexStorageProvider);
    await storage.clearAll();
    await storage.wipeCacheDirectory();
    if (!ref.mounted) return;
    state = const ItemImageIndex.empty();
    _log.info('resetAll: index+cache wiped');
  }

  /// 內部 helper：寫檔 + emit。
  Future<void> _saveAndEmit(ItemImageIndex next) async {
    final storage = ref.read(itemImageIndexStorageProvider);
    await storage.save(next);
    if (!ref.mounted) return;
    state = next;
  }
}
