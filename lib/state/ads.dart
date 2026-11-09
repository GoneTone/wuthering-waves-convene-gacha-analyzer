import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../services/ads/ads_platform.dart';

/// UMP／MobileAds 的平台包裝，測試以 override 換成假實作。
final adsPlatformProvider = Provider<AdsPlatform>((ref) => AdsPlatform());

/// 廣告狀態：是否可請求廣告、是否需提供隱私權選項入口。
class AdsState {
  /// 建立狀態，預設皆為 false。
  const AdsState({
    this.canRequestAds = false,
    this.privacyOptionsRequired = false,
  });

  /// 同意流程完成後是否可以請求廣告。
  final bool canRequestAds;

  /// 是否必須提供隱私權選項入口。
  final bool privacyOptionsRequired;
}

/// 負責同意流程與 SDK 初始化的控制器。
class AdsController extends Notifier<AdsState> {
  static final _log = Logger('ads');

  bool _started = false;

  @override
  AdsState build() => const AdsState();

  /// 依序更新同意資訊、必要時顯示表單、初始化 SDK；只會執行一次。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final platform = ref.read(adsPlatformProvider);
    try {
      await platform.requestConsentUpdate();
      try {
        await platform.loadAndShowConsentFormIfRequired();
      } on AdsConsentException catch (e) {
        _log.warning('consent form error code=${e.code} message=${e.message}');
      }
    } on AdsConsentException catch (e) {
      // 更新失敗仍沿用上次同意結果（UMP 官方建議），所以不 return。
      _log.warning('consent update failed code=${e.code} message=${e.message}');
    } catch (e, st) {
      _log.severe('ads consent failed: $e', e, st);
      return;
    }
    try {
      final canRequest = await platform.canRequestAds();
      if (canRequest) await platform.initializeSdk();
      final optionsRequired = await platform.isPrivacyOptionsRequired();
      if (!ref.mounted) return;
      state = AdsState(
        canRequestAds: canRequest,
        privacyOptionsRequired: optionsRequired,
      );
      _log.info(
        'ads enabled canRequestAds=$canRequest privacyOptionsRequired=$optionsRequired',
      );
    } catch (e, st) {
      // 非同意例外（如 PlatformException）不能變成未處理錯誤；狀態維持預設＝廣告關閉。
      _log.severe('ads start failed: $e', e, st);
    }
  }

  /// 顯示隱私權選項表單，關閉後重讀兩個旗標。
  Future<void> showPrivacyOptions() async {
    final platform = ref.read(adsPlatformProvider);
    try {
      await platform.showPrivacyOptionsForm();
    } on AdsConsentException catch (e) {
      _log.warning(
        'privacy options form error code=${e.code} message=${e.message}',
      );
    }
    final canRequest = await platform.canRequestAds();
    final optionsRequired = await platform.isPrivacyOptionsRequired();
    if (!ref.mounted) return;
    state = AdsState(
      canRequestAds: canRequest,
      privacyOptionsRequired: optionsRequired,
    );
  }
}

/// 廣告同意與初始化狀態。
final adsProvider = NotifierProvider<AdsController, AdsState>(
  AdsController.new,
);
