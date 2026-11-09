import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/ads/ad_config.dart';

/// 載入好的橫幅：可顯示的 [view] 與釋放原生廣告的 [dispose]。
typedef LoadedBanner = ({Widget view, VoidCallback dispose});

/// 依可用寬度（dp）載入橫幅；失敗回傳 null。
typedef BannerLoader = Future<LoadedBanner?> Function(int width);

/// 廣告相關 log。
final _log = Logger('ads');

/// 第一次載入結果寫進 [result] 的橫幅 listener；之後自動 refresh 的回呼一律不理。
///
/// AdMob 橫幅預設會自動 refresh，外掛每次都會再轉發 onAdLoaded／onAdFailedToLoad：
/// 不擋的話第二次 complete 會丟 StateError，refresh 失敗還會釋放正在顯示的廣告。
/// 已載入的廣告由 [BannerAdSlot] 負責釋放；refresh 失敗時 AdView 會繼續顯示上一則。
@visibleForTesting
BannerAdListener bannerAdListener(
  Completer<LoadedBanner?> result,
  AdSize size,
) => BannerAdListener(
  onAdLoaded: (ad) {
    if (result.isCompleted) return;
    _log.info('banner loaded width=${size.width} height=${size.height}');
    result.complete((
      view: SizedBox(
        width: size.width.toDouble(),
        height: size.height.toDouble(),
        child: AdWidget(ad: ad as AdWithView),
      ),
      dispose: ad.dispose,
    ));
  },
  onAdFailedToLoad: (ad, error) {
    if (result.isCompleted) return;
    _log.warning('banner failed code=${error.code} message=${error.message}');
    ad.dispose();
    result.complete(null);
  },
);

/// 正式的橫幅載入器：以 AdMob 自適應尺寸載入，測試以 override 換成假實作。
final bannerLoaderProvider = Provider<BannerLoader>(
  (ref) => (width) async {
    // 刻意用標準錨定自適應（約 50–90dp）：官方說明大型自適應可達螢幕高 20%（50–150dp、為影片最佳化），違反「不打擾使用者」；
    // 之後外掛大版本若移除此方法，改用 getInlineAdaptiveBannerAdSize(width, maxHeight)。
    // ignore: deprecated_member_use
    final size = await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
      width,
    );
    if (size == null) {
      _log.warning('banner size unavailable width=$width');
      return null;
    }
    final result = Completer<LoadedBanner?>();
    final ad = BannerAd(
      adUnitId: admobBannerUnitId,
      size: size,
      request: const AdRequest(),
      listener: bannerAdListener(result, size),
    );
    try {
      await ad.load();
    } catch (_) {
      unawaited(ad.dispose());
      rethrow;
    }
    return result.future;
  },
);

/// 底部橫幅位：依自身寬度載入廣告，寬度變了就換一則；沒有廣告時高度為 0。
class BannerAdSlot extends StatefulWidget {
  /// 建立橫幅位；[frame] 只包住已載入的廣告，讓分隔線等裝飾隨廣告一起收起。
  const BannerAdSlot({super.key, required this.load, this.frame});

  /// 依寬度載入廣告。
  final BannerLoader load;

  /// 包住已載入廣告的外框；不能改變寬度，否則量到的寬度與廣告不符。
  final Widget Function(Widget banner)? frame;

  @override
  State<BannerAdSlot> createState() => _BannerAdSlotState();
}

/// [BannerAdSlot] 的 State，持有目前的廣告與請求序號。
class _BannerAdSlotState extends State<BannerAdSlot> {
  /// 最近一次請求的寬度。
  int? _width;

  /// 目前顯示的廣告。
  LoadedBanner? _banner;

  /// 請求序號；晚到的舊請求結果以此辨識後直接釋放。
  int _request = 0;

  /// 換成 [width] 的新廣告：先釋放舊的，再載入。
  Future<void> _reload(int width) async {
    final request = ++_request;
    final old = _banner;
    if (old != null) {
      setState(() => _banner = null);
      // 等舊廣告的 AdWidget 從畫面拿掉後再釋放。
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    LoadedBanner? banner;
    try {
      banner = await widget.load(width);
    } catch (e, st) {
      // 平台例外不能變成未處理錯誤；當成載入失敗、橫幅位收起。
      _log.severe('banner load threw width=$width: $e', e, st);
    }
    if (!mounted || request != _request) {
      banner?.dispose();
      return;
    }
    setState(() => _banner = banner);
  }

  @override
  void dispose() {
    _request++;
    _banner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.truncate();
        if (width != _width) {
          _width = width;
          // 版面建構中不能 setState，也不能先釋放還掛在畫面上的廣告，留到這一幀之後。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && width == _width) unawaited(_reload(width));
          });
        }
        final banner = _banner;
        if (banner == null) return const SizedBox.shrink();
        return widget.frame?.call(banner.view) ?? banner.view;
      },
    );
  }
}
