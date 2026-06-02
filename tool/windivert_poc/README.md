# WinDivert 可行性 PoC

驗證 WinDivert（透過 Rust `windivert` crate）能否在你本機**看到鳴潮對喚取記錄 API 的連線**。
**sniff 模式、非侵入**——只複製封包給我們看，不修改/不丟棄/不重導向，對遊戲與系統零影響。
跑成功（看到 `✅ HIT`）就代表正式版的「鎖行程 + 重導向進 MITM」路線可行。

> ⚠️ 此 PoC 與主專案完全獨立，純驗證用。請在**一般 / 管理員 PowerShell** 視窗手動跑下列指令，**不要**用 Claude 對話框的 `! ` 前綴（那是 bash，不是 PowerShell）。

## 1. 下載 WinDivert 函式庫檔

到官方 releases 下載 WinDivert 2.2.x（x64）：
<https://github.com/basil00/WinDivert/releases>（或 <https://windivert.com/>）

解壓後，`x64\` 資料夾內會有這三個檔（建置與執行都需要）：
- `WinDivert.dll`
- `WinDivert.lib`
- `WinDivert64.sys`（官方簽章的核心驅動）

## 2. 設環境變數並建置

在 PowerShell（一般權限即可建置）：

```powershell
# 指向上面那個含 dll/lib/sys 的 x64 資料夾（換成你的實際路徑）
$env:WINDIVERT_PATH = "C:\path\to\WinDivert-2.2.2-A\x64"

cd E:\IdeaProjects\wuthering-waves-convene-gacha-analyzer\tool\windivert_poc
cargo build --release
```

> 若 `cargo build` 因 `windivert` crate API 版本差異報錯（方法名不同），把錯誤訊息貼給我，我立即修。

## 3. 把 dll 與 sys 放到 exe 旁

WinDivert.dll 執行時會在**同目錄**找 WinDivert64.sys，所以兩個都要複製到 exe 旁：

```powershell
Copy-Item "$env:WINDIVERT_PATH\WinDivert.dll"   ".\target\release\"
Copy-Item "$env:WINDIVERT_PATH\WinDivert64.sys" ".\target\release\"
```

## 4. 以**系統管理員**執行（WinDivert 載驅動需要 admin）

最簡單：用「以系統管理員身分執行」開一個 PowerShell，然後：

```powershell
cd E:\IdeaProjects\wuthering-waves-convene-gacha-analyzer\tool\windivert_poc
.\target\release\windivert_poc.exe
```

看到：
```
WinDivert 已開啟（sniff 模式，零影響）。請到鳴潮內開啟「喚取 → 喚取記錄」頁。Ctrl-C 結束。
```
就**切到鳴潮、開「喚取 → 喚取記錄」頁**。

## 5. 觀察結果

- 出現 **`✅ HIT ... gmserver-api ...`** → **可行**，WinDivert 看得到遊戲的喚取請求，正式版路線成立。
- 只看到一堆「（其他 :443 目的）」但**沒有 HIT**：可能是 (a) gmserver 走的 IP 不在我們解析到的清單（CDN 多 IP）；(b) 遊戲喚取資料被快取沒重發。把終端輸出（含那些「其他 :443 目的」的 IP）貼給我，我判斷。
- 開 WinDivert 就失敗：確認「以系統管理員執行」+「dll/sys 在 exe 旁」。

把結果貼給我，就能定案要不要往下做完整實作（helper + shim + 整合 + 打包）。
