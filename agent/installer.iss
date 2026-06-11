; Inno Setup script — compile with Inno Setup 6 to produce setup.exe
; https://jrsoftware.org/isinfo.php

#define MyAppName "RemoteScreen Agent"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "RemoteScreen"
#define MyAppExeName "RemoteScreenAgent.exe"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={localappdata}\RemoteScreenAgent
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=RemoteScreenAgent-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "dist\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 Agent"; Flags: postinstall nowait skipifsilent

[Code]
var
  ServerPage: TInputQueryWizardPage;
  TokenPage: TInputQueryWizardPage;

procedure InitializeWizard;
begin
  ServerPage := CreateInputQueryPage(wpSelectDir,
    '服务器配置', '填写信令服务器地址和设备 ID',
    '请确认以下信息:');
  ServerPage.Add('服务器 (wss://域名 或 ws://IP:端口):', False);
  ServerPage.Add('设备 ID:', False);
  ServerPage.Values[0] := 'wss://olxp.cc';
  ServerPage.Values[1] := GetComputerNameString;

  TokenPage := CreateInputQueryPage(ServerPage.ID,
    '访问令牌', '与服务器 ACCESS_TOKEN 一致', '');
  TokenPage.Add('ACCESS_TOKEN:', True);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  SettingsPath: String;
  SettingsDir: String;
  ConfigContent: String;
begin
  if CurStep = ssPostInstall then
  begin
    SettingsDir := ExpandConstant('{localappdata}\RemoteScreenAgent');
    SettingsPath := SettingsDir + '\settings.json';
    ForceDirectories(SettingsDir);
    ConfigContent :=
      '{' + #13#10 +
      '  "server": "' + ServerPage.Values[0] + '",' + #13#10 +
      '  "deviceId": "' + ServerPage.Values[1] + '",' + #13#10 +
      '  "token": "' + TokenPage.Values[0] + '",' + #13#10 +
      '  "monitor": 1,' + #13#10 +
      '  "fps": 12,' + #13#10 +
      '  "quality": 55,' + #13#10 +
      '  "streamWidth": 0' + #13#10 +
      '}';
    SaveStringToFile(SettingsPath, ConfigContent, False);
  end;
end;

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "RemoteScreenAgent"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue
