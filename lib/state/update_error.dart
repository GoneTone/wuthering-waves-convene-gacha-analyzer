/// 更新流程的錯誤類型，dialog 端用 i18n 解析顯示。
sealed class UpdateError {
  const UpdateError();
}

/// 喚取記錄 API 回傳 `code != 0`（整併前身版本 AuthExpired/RateLimited/ApiError）。
/// 由於無法區分 recordId 過期 vs 其他錯誤，UI 一律以通用措辭提示重開喚取記錄頁。
class UpdateErrorGachaFailed extends UpdateError {
  /// 建立 [UpdateErrorGachaFailed]，[code] / [message] 來自 API 回應。
  const UpdateErrorGachaFailed(this.code, this.message);

  /// API 回傳的 `code`（0 以外）。
  final int code;

  /// API 回傳的 `message`（簡體中文，僅供日誌；UI 不直接顯示）。
  final String message;
}

/// 帳號無任何喚取紀錄。
class UpdateErrorNoRecords extends UpdateError {
  /// 建立 [UpdateErrorNoRecords]。
  const UpdateErrorNoRecords();
}

/// fallback：訊息已是 user-readable（多半來自 FormatException 等），直接顯示。
class UpdateErrorOther extends UpdateError {
  /// 建立 [UpdateErrorOther]，[message] 為直接顯示給使用者的錯誤訊息。
  const UpdateErrorOther(this.message);

  /// 直接顯示給使用者的錯誤訊息。
  final String message;
}

/// 強制重抓物品圖片時，清空 index 或 cache 目錄階段失敗。
/// 通常是檔案被其他 process 鎖住（防毒掃描中等）。
class UpdateErrorWipeItemImageCache extends UpdateError {
  /// 建立 [UpdateErrorWipeItemImageCache]，[detail] 為例外訊息（已脫敏路徑）。
  const UpdateErrorWipeItemImageCache(this.detail);

  /// 例外訊息；絕對路徑應在外層 emit 前以 `sanitizeFsPath` 處理。
  final String detail;
}
