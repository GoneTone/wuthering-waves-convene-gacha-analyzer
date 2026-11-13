/// Android 讀取遊戲 Client.log 的方式。
enum LogAccessMethod {
  /// 以 root 讀取：整次更新只開一個常駐 `su`，指令從 stdin 送入（見 `RootShell`）。
  root,

  /// Android 10 以下取得儲存權限後直接讀檔。
  legacyDirect,

  /// 透過自我配對的無線偵錯 shell 讀取。
  wirelessDebugging;

  /// 由保存的名稱還原；不認得時回 null。
  static LogAccessMethod? fromName(String? name) {
    for (final m in values) {
      if (m.name == name) return m;
    }
    return null;
  }
}
