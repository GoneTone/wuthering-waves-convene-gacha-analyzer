/// 國際服鳴潮各版本共用的套件名稱開頭（國服 `com.kurogame.mingchao` 不在內）。
const wuwaPackagePrefix = 'com.kurogame.wutheringwaves';

/// Google Play、官網 APK 等版本的套件名稱。
const wuwaGlobalPackage = '$wuwaPackagePrefix.global';

/// Galaxy Store 版的套件名稱。
const wuwaSamsungPackage = '$wuwaPackagePrefix.samsung';

/// 已知版本，manifest 的 `<queries>` 也逐一宣告；排序時排在前面。
const knownWuwaPackages = [wuwaGlobalPackage, wuwaSamsungPackage];

/// 套件名稱會組進 shell 指令的路徑，只接受開頭相符且只有英數、底線、點的名稱。
final _wuwaPackagePattern = RegExp(
  r'^com\.kurogame\.wutheringwaves(\.[A-Za-z0-9_]+)*$',
);

/// [package] 是否為國際服鳴潮的套件名稱。
bool isWuwaPackage(String package) => _wuwaPackagePattern.hasMatch(package);

/// [package] 版本的 `Client.log` 路徑；不是鳴潮套件時丟 [ArgumentError]。
String androidClientLogPathFor(String package) {
  if (!isWuwaPackage(package)) {
    throw ArgumentError.value(package, 'package');
  }
  return '/sdcard/Android/data/$package/files/UE4Game/'
      'Client/Client/Saved/Logs/Client.log';
}

/// 只留鳴潮套件並去重，已知版本依 [knownWuwaPackages] 順序排前面，其餘依字母排。
List<String> sortWuwaPackages(Iterable<String> packages) {
  int rank(String p) {
    final i = knownWuwaPackages.indexOf(p);
    return i < 0 ? knownWuwaPackages.length : i;
  }

  return packages.where(isWuwaPackage).toSet().toList()..sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : a.compareTo(b);
  });
}
