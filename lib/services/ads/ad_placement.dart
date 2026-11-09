import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';

/// 比對 `/banner/:type` 路由並擷取卡池 key。
final RegExp _bannerPathPattern = RegExp(r'^/banner/([^/]+)$');

/// 判斷路由 [path] 的頁面是否有內容可放底部廣告；資料未就緒、無紀錄或未知路由時回傳 false。
bool pageHasAdContent({required String path, required GachaState gacha}) {
  if (path == '/settings' || path == '/contributors') return true;
  if (gacha.isBootstrapping) return false;
  final data = gacha.activeData;
  if (data == null) return false;
  if (path == '/') {
    return data.banners.values.any((records) => records.isNotEmpty);
  }
  final match = _bannerPathPattern.firstMatch(path);
  if (match != null) {
    return (data.banners[match.group(1)!] ?? const []).isNotEmpty;
  }
  return false;
}
