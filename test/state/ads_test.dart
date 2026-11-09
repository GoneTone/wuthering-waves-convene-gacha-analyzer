import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/ads/ads_platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/ads.dart';

/// 記錄呼叫並可調整回傳值的假 [AdsPlatform]。
class _FakeAdsPlatform extends AdsPlatform {
  /// 建立假平台，[consentFails] 為 true 時 [requestConsentUpdate] 丟例外。
  _FakeAdsPlatform({
    this.consentFails = false,
    this.canRequest = false,
    this.optionsRequired = false,
  });

  /// 同意資訊更新是否失敗。
  final bool consentFails;

  /// [canRequestAds] 的回傳值。
  bool canRequest;

  /// [isPrivacyOptionsRequired] 的回傳值。
  bool optionsRequired;

  /// 非 null 時 [requestConsentUpdate] 會丟出它。
  Object? consentError;

  /// 非 null 時 [initializeSdk] 會丟出它。
  Object? initError;

  /// 非 null 時 [showPrivacyOptionsForm] 會等它完成。
  Completer<void>? formGate;

  /// [requestConsentUpdate] 的呼叫次數。
  int consentUpdates = 0;

  /// [initializeSdk] 的呼叫次數。
  int initCalls = 0;

  @override
  Future<void> requestConsentUpdate() async {
    consentUpdates++;
    if (consentError != null) throw consentError!;
    if (consentFails) throw AdsConsentException('1', 'boom');
  }

  @override
  Future<void> loadAndShowConsentFormIfRequired() async {}

  @override
  Future<bool> canRequestAds() async => canRequest;

  @override
  Future<bool> isPrivacyOptionsRequired() async => optionsRequired;

  @override
  Future<void> showPrivacyOptionsForm() async => formGate?.future;

  @override
  Future<void> initializeSdk() async {
    initCalls++;
    if (initError != null) throw initError!;
  }
}

/// 以 [fake] 建立容器。
ProviderContainer _container(_FakeAdsPlatform fake) {
  final c = ProviderContainer(
    overrides: [adsPlatformProvider.overrideWithValue(fake)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('start enables ads after consent', () async {
    final fake = _FakeAdsPlatform(canRequest: true);
    final c = _container(fake);
    await c.read(adsProvider.notifier).start();
    expect(c.read(adsProvider).canRequestAds, isTrue);
    expect(fake.initCalls, 1);
  });

  test('consent error leaves ads disabled', () async {
    final fake = _FakeAdsPlatform(consentFails: true);
    final c = _container(fake);
    await c.read(adsProvider.notifier).start();
    expect(c.read(adsProvider).canRequestAds, isFalse);
    expect(fake.initCalls, 0);
  });

  test('consent error still uses previous consent', () async {
    final fake = _FakeAdsPlatform(consentFails: true, canRequest: true);
    final c = _container(fake);
    await c.read(adsProvider.notifier).start();
    expect(c.read(adsProvider).canRequestAds, isTrue);
    expect(fake.initCalls, 1);
  });

  test('start runs once', () async {
    final fake = _FakeAdsPlatform();
    final c = _container(fake);
    await c.read(adsProvider.notifier).start();
    await c.read(adsProvider.notifier).start();
    expect(fake.consentUpdates, 1);
  });

  test('privacy options flag follows the platform', () async {
    final fake = _FakeAdsPlatform(optionsRequired: true);
    final c = _container(fake);
    await c.read(adsProvider.notifier).start();
    expect(c.read(adsProvider).privacyOptionsRequired, isTrue);
    fake.optionsRequired = false;
    await c.read(adsProvider.notifier).showPrivacyOptions();
    expect(c.read(adsProvider).privacyOptionsRequired, isFalse);
  });

  test(
    'unexpected platform error is contained and ads stay disabled',
    () async {
      final fake = _FakeAdsPlatform(canRequest: true)
        ..initError = StateError('plugin');
      final c = _container(fake);
      await c.read(adsProvider.notifier).start();
      expect(c.read(adsProvider).canRequestAds, isFalse);
    },
  );

  test('disposing while the privacy form is open does not throw', () async {
    final fake = _FakeAdsPlatform()..formGate = Completer<void>();
    final c = ProviderContainer(
      overrides: [adsPlatformProvider.overrideWithValue(fake)],
    );
    final pending = c.read(adsProvider.notifier).showPrivacyOptions();
    c.dispose();
    fake.formGate!.complete();
    await pending;
  });

  test('unexpected consent error is contained and ads stay disabled', () async {
    final fake = _FakeAdsPlatform(canRequest: true)
      ..consentError = StateError('plugin');
    final c = _container(fake);
    await c.read(adsProvider.notifier).start();
    expect(c.read(adsProvider).canRequestAds, isFalse);
    expect(fake.initCalls, 0);
  });
}
