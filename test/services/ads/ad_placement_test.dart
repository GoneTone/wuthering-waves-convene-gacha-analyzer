import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/ads/ad_placement.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';

/// 建立指定卡池的測試紀錄。
GachaRecord _r(String cpt) => GachaRecord(
  resourceId: 1001,
  qualityLevel: 5,
  resourceType: '角色',
  cardPoolType: cpt,
  name: '卡卡羅',
  count: 1,
  time: DateTime.utc(2026, 1, 1),
);

/// 建立作用中帳號的測試狀態，[banners] 為各卡池紀錄。
GachaState _state({
  Map<String, List<GachaRecord>> banners = const {},
  bool bootstrapping = false,
  bool hasActive = true,
}) => GachaState(
  activeUid: hasActive ? '701000000' : null,
  byUid: {
    '701000000': BannerStorage(
      playerId: '701000000',
      languageCode: 'zh-Hant',
      lastUpdated: DateTime.utc(2026, 1, 1),
      banners: banners,
    ),
  },
  isBootstrapping: bootstrapping,
);

void main() {
  final withRecords = _state(
    banners: {
      '1': [_r('1')],
    },
  );
  final empty = _state(banners: {'1': const []});

  test('/settings 不論資料一律有廣告內容', () {
    expect(pageHasAdContent(path: '/settings', gacha: empty), isTrue);
    expect(
      pageHasAdContent(path: '/settings', gacha: _state(bootstrapping: true)),
      isTrue,
    );
  });

  test('/contributors 不論資料一律有廣告內容', () {
    expect(pageHasAdContent(path: '/contributors', gacha: empty), isTrue);
    expect(
      pageHasAdContent(path: '/contributors', gacha: _state(hasActive: false)),
      isTrue,
    );
  });

  test('/ 在 bootstrap 中沒有廣告內容', () {
    expect(
      pageHasAdContent(path: '/', gacha: _state(bootstrapping: true)),
      isFalse,
    );
  });

  test('/ 無作用中帳號時沒有廣告內容', () {
    expect(
      pageHasAdContent(path: '/', gacha: _state(hasActive: false)),
      isFalse,
    );
  });

  test('/ 所有卡池都空時沒有廣告內容', () {
    expect(pageHasAdContent(path: '/', gacha: empty), isFalse);
  });

  test('/ 任一卡池有紀錄時有廣告內容', () {
    expect(pageHasAdContent(path: '/', gacha: withRecords), isTrue);
  });

  test('/banner/<有紀錄的 key> 有廣告內容', () {
    expect(pageHasAdContent(path: '/banner/1', gacha: withRecords), isTrue);
  });

  test('/banner/<空的 key> 沒有廣告內容', () {
    expect(pageHasAdContent(path: '/banner/1', gacha: empty), isFalse);
    expect(pageHasAdContent(path: '/banner/9', gacha: withRecords), isFalse);
  });

  test('/banner/<有紀錄的 key> 在 bootstrap 中或無作用中帳號時沒有廣告內容', () {
    final bootstrapping = _state(
      banners: {
        '1': [_r('1')],
      },
      bootstrapping: true,
    );
    final noActive = _state(
      banners: {
        '1': [_r('1')],
      },
      hasActive: false,
    );
    expect(pageHasAdContent(path: '/banner/1', gacha: bootstrapping), isFalse);
    expect(pageHasAdContent(path: '/banner/1', gacha: noActive), isFalse);
  });

  test('格式不符的 banner 路徑沒有廣告內容', () {
    for (final path in ['/banner/', '/bannerx', '/banner/1/extra']) {
      expect(
        pageHasAdContent(path: path, gacha: withRecords),
        isFalse,
        reason: path,
      );
    }
  });

  test('banners 為空時 / 與 /banner/1 沒有廣告內容', () {
    final noBanners = _state();
    expect(pageHasAdContent(path: '/', gacha: noBanners), isFalse);
    expect(pageHasAdContent(path: '/banner/1', gacha: noBanners), isFalse);
  });

  test('未知路徑沒有廣告內容', () {
    expect(pageHasAdContent(path: '/foo', gacha: withRecords), isFalse);
  });
}
