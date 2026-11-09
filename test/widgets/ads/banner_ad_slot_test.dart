import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/ads/banner_ad_slot.dart';

/// 記錄請求寬度與 dispose 次數的假載入器。
class _FakeLoader {
  /// 建立假載入器；[fails] 為 true 時一律回 null。
  _FakeLoader({this.fails = false});

  /// 是否模擬載入失敗。
  final bool fails;

  /// 每次被呼叫時的寬度。
  final widths = <int>[];

  /// 已被 dispose 的廣告寬度。
  final disposed = <int>[];

  /// 非 null 時載入等它完成才回傳，用來模擬尚未載完。
  Completer<void>? gate;

  /// 依寬度回傳 50dp 高的假廣告。
  Future<LoadedBanner?> call(int width) async {
    widths.add(width);
    final pending = gate;
    if (pending != null) await pending.future;
    if (fails) return null;
    return (
      view: SizedBox(key: Key('fake-banner-$width'), height: 50),
      dispose: () => disposed.add(width),
    );
  }
}

/// 不碰原生 SDK、記錄 dispose 次數的假橫幅。
class _CountingAd extends BannerAd {
  /// 建立 320×50 的假橫幅。
  _CountingAd()
    : super(
        adUnitId: 'test',
        size: AdSize.banner,
        request: const AdRequest(),
        listener: const BannerAdListener(),
      );

  /// [dispose] 的呼叫次數。
  int disposes = 0;

  @override
  Future<void> dispose() async => disposes++;
}

void main() {
  group('bannerAdListener ignores auto-refresh callbacks', () {
    test('a second load does not complete twice', () async {
      final result = Completer<LoadedBanner?>();
      final listener = bannerAdListener(result, AdSize.banner);
      final ad = _CountingAd();
      listener.onAdLoaded!(ad);
      expect(() => listener.onAdLoaded!(ad), returnsNormally);
      expect(await result.future, isNotNull);
    });

    test('a failed refresh keeps the shown banner', () async {
      // refresh 失敗時 AdView 會繼續顯示上一則；釋放它會留下空白的 platform view。
      final result = Completer<LoadedBanner?>();
      final listener = bannerAdListener(result, AdSize.banner);
      final ad = _CountingAd();
      listener.onAdLoaded!(ad);
      listener.onAdFailedToLoad!(ad, LoadAdError(3, 'test', 'no fill', null));
      expect(ad.disposes, 0);
      expect(await result.future, isNotNull);
    });

    test('a failed first load releases the ad', () async {
      final result = Completer<LoadedBanner?>();
      final ad = _CountingAd();
      bannerAdListener(result, AdSize.banner).onAdFailedToLoad!(
        ad,
        LoadAdError(3, 'test', 'no fill', null),
      );
      expect(ad.disposes, 1);
      expect(await result.future, isNull);
    });
  });

  /// 以 [width] 寬的畫面呈現底部的 [BannerAdSlot]，[frame] 照傳給它。
  Future<void> pump(
    WidgetTester tester,
    _FakeLoader loader,
    double width, {
    Widget Function(Widget banner)? frame,
  }) async {
    tester.view.physicalSize = Size(width, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: BannerAdSlot(
            key: const Key('slot'),
            load: loader.call,
            frame: frame,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('collapses when loading fails', (tester) async {
    final loader = _FakeLoader(fails: true);
    await pump(tester, loader, 400);
    expect(loader.widths, [400]);
    expect(tester.getSize(find.byKey(const Key('slot'))).height, 0);
  });

  testWidgets('collapses when the loader throws', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: BannerAdSlot(
            key: const Key('slot'),
            load: (_) async => throw Exception('platform'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('slot'))).height, 0);
  });

  testWidgets('shows the loaded banner', (tester) async {
    final loader = _FakeLoader();
    await pump(tester, loader, 400);
    expect(find.byKey(const Key('fake-banner-400')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('slot'))).height, 50);
  });

  for (final fails in [false, true]) {
    testWidgets('frame wraps only a loaded banner (fails: $fails)', (
      tester,
    ) async {
      // 載入失敗時分隔線等裝飾也要一起收起，不留空線。
      await pump(
        tester,
        _FakeLoader(fails: fails),
        400,
        frame: (banner) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [const Divider(height: 1), banner],
        ),
      );
      expect(find.byType(Divider), fails ? findsNothing : findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('slot'))).height,
        fails ? 0 : 51,
      );
    });
  }

  testWidgets('reloads when the width changes and disposes the old banner', (
    tester,
  ) async {
    final loader = _FakeLoader();
    await pump(tester, loader, 400);
    tester.view.physicalSize = const Size(600, 600);
    await tester.pumpAndSettle();
    expect(loader.widths, [400, 600]);
    expect(loader.disposed, [400]);
    expect(find.byKey(const Key('fake-banner-600')), findsOneWidget);
  });

  testWidgets('disposes the banner when unmounted', (tester) async {
    final loader = _FakeLoader();
    await pump(tester, loader, 400);
    await tester.pumpWidget(const SizedBox());
    expect(loader.disposed, [400]);
  });

  testWidgets('disposes a banner that loads after a newer width request', (
    tester,
  ) async {
    // 舊寬度的廣告晚到時已經用不到，不釋放就會留下原生廣告。
    final loader = _FakeLoader()..gate = Completer<void>();
    await pump(tester, loader, 400);
    tester.view.physicalSize = const Size(600, 600);
    await tester.pump();
    loader.gate!.complete();
    await tester.pumpAndSettle();
    expect(loader.widths, [400, 600]);
    expect(loader.disposed, [400]);
    expect(find.byKey(const Key('fake-banner-400')), findsNothing);
    expect(find.byKey(const Key('fake-banner-600')), findsOneWidget);
  });

  testWidgets('disposes a banner that loads after unmount', (tester) async {
    final loader = _FakeLoader()..gate = Completer<void>();
    await pump(tester, loader, 400);
    await tester.pumpWidget(const SizedBox());
    loader.gate!.complete();
    await tester.pumpAndSettle();
    expect(loader.disposed, [400]);
  });
}
