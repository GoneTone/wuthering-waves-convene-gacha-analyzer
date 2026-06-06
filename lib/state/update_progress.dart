import 'package:wuthering_waves_convene_gacha_analyzer/state/update_error.dart';

export 'package:wuthering_waves_convene_gacha_analyzer/state/update_error.dart';

/// 更新進度狀態：準備中、等待捕獲、拉取中、完成、失敗。
sealed class UpdateProgress {
  const UpdateProgress();
}

/// 準備階段（啟動更新、檢查快取 URL 前）。
class Preparing extends UpdateProgress {
  /// 建立 [Preparing]。
  const Preparing();
}

/// 等待 MITM 捕獲喚取憑證。
class WaitingForCapture extends UpdateProgress {
  /// 建立 [WaitingForCapture]；[isFallback] 表示 recordId 全池失效後的二次（fallback）捕獲。
  const WaitingForCapture({this.isFallback = false});

  /// true 表示 recordId 全池失效後的二次捕獲（UI 顯示重新攔取提示）。
  final bool isFallback;
}

/// 正在拉取指定卡池的完整歷史。
class FetchingBanner extends UpdateProgress {
  /// 建立 [FetchingBanner]。
  const FetchingBanner({
    required this.displayName,
    required this.poolIndex,
    required this.poolCount,
    required this.newRecordsSoFar,
  });

  /// 顯示用的卡池名稱 i18n key。
  final String displayName;

  /// 目前正在抓第幾個 cardPoolType（1-based，共 [poolCount] 個）。
  final int poolIndex;

  /// 本次更新需迭代的 cardPoolType 總數（固定 10）。
  final int poolCount;

  /// 到目前為止累積的新紀錄數。
  final int newRecordsSoFar;
}

/// 帳號批次匯入的結果摘要。
class ImportResult {
  /// 建立 [ImportResult]。
  const ImportResult({
    required this.successAccounts,
    required this.totalRecords,
    required this.failedUids,
  });

  /// 成功匯入的帳號數。
  final int successAccounts;

  /// 成功匯入的總紀錄數。
  final int totalRecords;

  /// 匯入失敗的 UID 列表。
  final List<String> failedUids;
}

/// 更新完成。
class UpdateCompleted extends UpdateProgress {
  /// 建立 [UpdateCompleted]。
  const UpdateCompleted({
    required this.totalNewRecords,
    required this.failedBanners,
    required this.updatedAt,
    required this.itemImagesDownloaded,
    this.importSummary,
  });

  /// 本次更新新增的總紀錄數（update 流程用；import 流程為 0）。
  final int totalNewRecords;

  /// 拉取失敗的 banner 名稱 key 列表。
  final List<String> failedBanners;

  /// 更新完成時間（UTC）。
  final DateTime updatedAt;

  /// 本次補抓物品角色圖片成功寫入磁碟的 icon 張數。既有圖檔已存在不重抓的不算；
  /// 只計入本次新下載成功的張數。
  final int itemImagesDownloaded;

  /// 匯入流程的結果摘要；非 import 入口為 null。
  final ImportResult? importSummary;
}

/// 更新失敗。
class UpdateFailed extends UpdateProgress {
  /// 建立 [UpdateFailed]，[error] 為對應的錯誤類型。
  const UpdateFailed(this.error);

  /// 更新失敗的錯誤類型。
  final UpdateError error;
}

/// 物品圖片補抓的子步驟。
enum ItemImagePhase {
  /// 查詢各物品在官方是否有圖、寫入 index（取得物品資料階段）。
  checking,

  /// 下載已確認有圖的 icon 檔（下載階段）。
  downloading,
}

/// 主資料抓取完成後，正在補齊各物品的角色圖片。
class FetchingItemImages extends UpdateProgress {
  /// 建立 [FetchingItemImages]。
  const FetchingItemImages({
    required this.phase,
    required this.doneCount,
    required this.totalCount,
  });

  /// 目前所在的子步驟。
  final ItemImagePhase phase;

  /// 目前已完成的工作項數。
  final int doneCount;

  /// 本次需補圖的總工作項數。
  final int totalCount;
}
