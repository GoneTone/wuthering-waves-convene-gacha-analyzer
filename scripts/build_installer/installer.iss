; scripts/build_installer/installer.iss
;
; Wuthering Waves Convene Gacha Analyzer — Inno Setup 安裝檔
;
; 編譯方式：
;   ISCC.exe /DMyAppVersion=1.0.0 scripts\build_installer\installer.iss
;
; AppId 為本產品專屬的固定 GUID，任何情況下不得變更（會破壞升級路徑）；與前身版本不同 GUID 以避免被當成升級而覆蓋安裝。

#define MyAppId       "{27F3CD23-7E15-4570-8EBB-79D2801C9C85}"
#define MyAppName     "Wuthering Waves Convene Gacha Analyzer"
#define MyAppExeName  "wuthering_waves_convene_gacha_analyzer.exe"
#define MyAppPublisher "GoneTone"
#define MyAppURL      "https://github.com/GoneTone"

; MyAppVersion 透過 ISCC /DMyAppVersion=... 從外面傳入
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

[Setup]
AppId={{#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
VersionInfoVersion={#MyAppVersion}
VersionInfoProductVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppCopyright=Copyright (C) 2020-{#GetDateTimeString('yyyy','','')} {#MyAppPublisher}
DefaultDirName={commonpf}\Wuthering_Waves_Convene_Gacha_Analyzer
DefaultGroupName={#MyAppName}
DisableDirPage=no
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
OutputDir=..\..\build\installer
OutputBaseFilename=Wuthering_Waves_Convene_Gacha_Analyzer-Setup-{#MyAppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "arabic"; MessagesFile: "compiler:Languages\Arabic.isl"
Name: "armenian"; MessagesFile: "compiler:Languages\Armenian.isl"
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "bulgarian"; MessagesFile: "compiler:Languages\Bulgarian.isl"
Name: "catalan"; MessagesFile: "compiler:Languages\Catalan.isl"
Name: "corsican"; MessagesFile: "compiler:Languages\Corsican.isl"
Name: "czech"; MessagesFile: "compiler:Languages\Czech.isl"
Name: "danish"; MessagesFile: "compiler:Languages\Danish.isl"
Name: "dutch"; MessagesFile: "compiler:Languages\Dutch.isl"
Name: "finnish"; MessagesFile: "compiler:Languages\Finnish.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "hebrew"; MessagesFile: "compiler:Languages\Hebrew.isl"
Name: "hungarian"; MessagesFile: "compiler:Languages\Hungarian.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "norwegian"; MessagesFile: "compiler:Languages\Norwegian.isl"
Name: "polish"; MessagesFile: "compiler:Languages\Polish.isl"
Name: "portuguese"; MessagesFile: "compiler:Languages\Portuguese.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "slovak"; MessagesFile: "compiler:Languages\Slovak.isl"
Name: "slovenian"; MessagesFile: "compiler:Languages\Slovenian.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "swedish"; MessagesFile: "compiler:Languages\Swedish.isl"
Name: "tamil"; MessagesFile: "compiler:Languages\Tamil.isl"
Name: "thai"; MessagesFile: "compiler:Languages\Thai.isl"
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"
Name: "ukrainian"; MessagesFile: "compiler:Languages\Ukrainian.isl"
Name: "simpchinese"; MessagesFile: "ChineseSimplified.isl"
Name: "tradchinese"; MessagesFile: "ChineseTraditional.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; \
    Flags: recursesubdirs createallsubdirs ignoreversion
; WebView2 Evergreen Bootstrapper（喚取立繪功能所需）。由 build_release.ps1 於建置時
; 下載到本目錄；缺檔時整段以 #if 略過，不影響手動編譯。僅在系統無 WebView2 Runtime
; 時才解壓並於 [Run] 靜默安裝。
#if FileExists(AddBackslash(SourcePath) + "MicrosoftEdgeWebview2Setup.exe")
Source: "MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; \
    Flags: deleteafterinstall; Check: WebView2NotInstalled
#endif

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
#if FileExists(AddBackslash(SourcePath) + "MicrosoftEdgeWebview2Setup.exe")
; 系統缺 WebView2 Runtime 時靜默安裝（等它裝完再繼續），保證喚取立繪功能可用。
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; \
    StatusMsg: "{cm:InstallingWebView2}"; Check: WebView2NotInstalled; \
    Flags: waituntilterminated
#endif
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; \
    Flags: nowait postinstall skipifsilent

[CustomMessages]
InstallingWebView2=Installing Microsoft Edge WebView2 Runtime...
tradchinese.InstallingWebView2=正在安裝 Microsoft Edge WebView2 執行階段...
simpchinese.InstallingWebView2=正在安装 Microsoft Edge WebView2 运行时...
UninstallRemoveDataBody=Also remove user data?%n%nThis will permanently delete the contents of:%n%1%n%nincluding banner records, settings, caches and logs. This cannot be undone.
tradchinese.UninstallRemoveDataBody=是否要同時移除使用者資料？%n%n將永久刪除位於以下目錄的所有內容：%n%1%n%n包含卡池記錄、設定、快取與 log。此操作無法復原。
simpchinese.UninstallRemoveDataBody=是否要同时移除用户数据？%n%n将永久删除位于以下目录的所有内容：%n%1%n%n包含卡池记录、设定、缓存与 log。此操作无法复原。

[Code]
var
  // 解除安裝期間記錄使用者是否選擇連同移除 %APPDATA% 內的使用者資料。
  // usUninstall 階段由 MsgBox 設定，usPostUninstall 階段讀取以決定是否 DelTree。
  // Inno Setup 啟動 uninstaller process 時 Pascal Boolean 預設為 False，符合「預設不刪」語意。
  ShouldRemoveUserData: Boolean;

// 偵測系統是否已安裝 WebView2 Evergreen Runtime（per-machine x64 或 per-user）。
// 回傳 True＝未安裝，供 [Files]/[Run] 的 Check 決定是否解壓並靜默安裝隨附 Bootstrapper。
// 以巢狀 if 判斷（不依賴布林短路）；GUID 為 WebView2 Runtime 的 EdgeUpdate client id。
function WebView2NotInstalled: Boolean;
var
  pv: String;
begin
  Result := True;
  if RegQueryStringValue(HKLM,
      'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
      'pv', pv) then
    if (pv <> '') and (pv <> '0.0.0.0') then
      Result := False;
  if Result then
    if RegQueryStringValue(HKCU,
        'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'pv', pv) then
      if (pv <> '') and (pv <> '0.0.0.0') then
        Result := False;
end;

// 解除安裝流程：usUninstall 階段詢問使用者是否同時移除使用者資料，
// usPostUninstall 階段依旗標執行 DelTree（主程式檔已被卸載，避免 file lock）。
// silent 模式（/VERYSILENT、/SILENT）下 MsgBox 自動回傳預設按鈕值 = IDNO，
// 結果與「預設不勾」一致。
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  UserDataDir: String;
begin
  UserDataDir := ExpandConstant('{userappdata}\tw.reh\wuthering_waves_convene_gacha_analyzer');
  case CurUninstallStep of
    usUninstall:
      begin
        ShouldRemoveUserData :=
          MsgBox(
            FmtMessage(CustomMessage('UninstallRemoveDataBody'), [UserDataDir]),
            mbConfirmation,
            MB_YESNO or MB_DEFBUTTON2
          ) = IDYES;
      end;
    usPostUninstall:
      begin
        if ShouldRemoveUserData then
        begin
          if not DelTree(UserDataDir, True, True, True) then
            Log('uninstall: DelTree failed for ' + UserDataDir);
        end;
      end;
  end;
end;
