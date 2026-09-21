#define MyAppName "Aether study"
#define MyAppVersion "2026.9.21.4"
#define MyAppPublisher "AetherMED"
#define MyAppExeName "AetherStudy.exe"
#ifndef ClientPayloadDir
#define ClientPayloadDir "package\client"
#endif
#ifndef InstallerNamePrefix
#define InstallerNamePrefix "AetherStudy-Setup"
#endif

[Setup]
AppId={{0BCB7B54-241B-4B2E-A13A-A77E21522197}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\AetherStudy
UsePreviousAppDir=yes
DefaultGroupName=Aether study
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\outputs
OutputBaseFilename={#InstallerNamePrefix}-{#MyAppVersion}-x64
#ifdef FastPackage
Compression=lzma2/fast
SolidCompression=no
#else
Compression=lzma2/ultra64
SolidCompression=yes
#endif
LZMAUseSeparateProcess=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\client\{#MyAppExeName}
SetupLogging=yes

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："; Flags: unchecked

[Files]
Source: "{#ClientPayloadDir}\*"; DestDir: "{app}\client"; Excludes: "MedClaw.exe,Aether_ClawDESK.exe,*.candidate.exe"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "E:\openclaw\MedClaw\dist\prod\medbuddy\*"; DestDir: "{app}\runtime\backend-payload"; Excludes: "*.test.*,*.spec.*"; Flags: ignoreversion recursesubdirs createallsubdirs restartreplace
Source: "package\tools\bootstrap.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "package\tools\install-kb-tools.mjs"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "package\tools\uninstall-backend.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "package\tools\start-backend.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "package\tools\Start-AetherStudy-Backend.cmd"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "package\tools\stop-running-apps.ps1"; Flags: dontcopy

[Dirs]
Name: "{code:GetDataRoot}"
Name: "{code:GetDataRoot}\logs"

[Icons]
Name: "{group}\Aether study"; Filename: "{app}\client\{#MyAppExeName}"; WorkingDir: "{code:GetDataRoot}"
Name: "{group}\Start OpenClaw Backend"; Filename: "{app}\tools\Start-AetherStudy-Backend.cmd"; WorkingDir: "{app}\tools"
Name: "{autodesktop}\Aether study"; Filename: "{app}\client\{#MyAppExeName}"; WorkingDir: "{code:GetDataRoot}"; Tasks: desktopicon

[Run]
; Qt 6 MSVC builds require the VC++ runtime even when backend installation is skipped.
; Always run the redistributable installer; it is idempotent and remains silent.
Filename: "{app}\client\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "正在安装 Microsoft Visual C++ 运行库..."; Flags: waituntilterminated runhidden
Filename: "{app}\client\{#MyAppExeName}"; Description: "启动 Aether study"; WorkingDir: "{code:GetDataRoot}"; Flags: nowait postinstall runasoriginaluser skipifsilent
; postinstall runs after ssPostInstall deployment and is skipped if a reboot is needed.
Filename: "{app}\client\{#MyAppExeName}"; WorkingDir: "{code:GetDataRoot}"; Flags: nowait postinstall runasoriginaluser; Check: ShouldAutoStartApplication

[InstallDelete]
Type: filesandordirs; Name: "{localappdata}\Programs\AetherStudy"
; Clear the previous client payload on upgrades so obsolete Qt5 DLLs,
; plugins, and WebEngine resources cannot remain beside the Qt6 build.
Type: filesandordirs; Name: "{app}\client"
Type: files; Name: "{app}\.purge-choice.txt"
Type: files; Name: "{app}\client\config\office.json"
Type: files; Name: "{app}\client\Aether_ClawDESK.exe"
Type: files; Name: "{app}\client\Aether_ClawDESK.candidate.exe"
; Remove Qt5 runtime files left by upgrades from pre-Qt6 installers.
Type: files; Name: "{app}\client\Qt5*.dll"
Type: files; Name: "{app}\client\MedClaw.exe"
Type: files; Name: "{userdesktop}\Aether_ClawDESK.lnk"
Type: filesandordirs; Name: "{userprograms}\Aether_ClawDESK"

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\uninstall-backend.ps1"" -InstallRoot ""{app}"" -DataRoot ""{localappdata}\AetherStudy"" -PurgeMarker ""{app}\.purge-choice.txt"""; Flags: runhidden waituntilterminated; RunOnceId: "CleanupAetherStudyData"

[UninstallDelete]
Type: files; Name: "{app}\.skip-backend"
Type: files; Name: "{app}\.purge-choice.txt"
Type: files; Name: "{app}\runtime\backend\medclaw.deploy.json"
Type: filesandordirs; Name: "{app}\runtime\backend"
Type: filesandordirs; Name: "{app}\runtime\backend-payload"
Type: filesandordirs; Name: "{%USERPROFILE}\.openclaw"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{%USERPROFILE}\.openclaw-dev"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{%USERPROFILE}\.openclaw-medbuddy"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{%USERPROFILE}\.openclaw-aetherstudy"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{localappdata}\AetherStudy"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{localappdata}\Aether_ClawDESK"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{localappdata}\AetherMED\Aether study"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{localappdata}\AetherMED"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{localappdata}\AETHERMIND"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{localappdata}\MedClaw"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{userappdata}\AetherStudy"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{userappdata}\Aether_ClawDESK"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{userappdata}\AetherMED\Aether study"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{userappdata}\AetherMED"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{userappdata}\AETHERMIND"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{userappdata}\MedClaw"; Check: ShouldPurgeAllUserData
Type: filesandordirs; Name: "{app}"; Check: ShouldPurgeAllUserData

[Code]
var
  PurgeAllUserData: Boolean;
  DeploymentCompleted: Boolean;

function GetDataRoot(Param: String): String;
var
  PreferredRoot: String;
begin
  Result := ExpandConstant('{param:DATAROOT|}');
  if Result = '' then
  begin
    PreferredRoot := ExpandConstant('{localappdata}\AetherStudy');
    Result := PreferredRoot;
  end;
end;

function ShouldRunBackend: Boolean;
begin
  Result := CompareText(ExpandConstant('{param:SKIPBACKEND|0}'), '1') <> 0;
end;

function ShouldAutoStartApplication: Boolean;
begin
  Result := DeploymentCompleted and WizardSilent and
    (CompareText(ExpandConstant('{param:AUTOSTART|0}'), '1') = 0);
end;

function ShouldUninstallBackend: Boolean;
begin
  Result := (not PurgeAllUserData) and
    (not FileExists(ExpandConstant('{app}\.skip-backend')));
end;

function ShouldPurgeAllUserData: Boolean;
begin
  Result := PurgeAllUserData;
end;

function ShowUninstallDataOptions(): Boolean;
var
  OptionsForm: TSetupForm;
  PromptLabel: TNewStaticText;
  KeepDataRadio: TNewRadioButton;
  PurgeDataRadio: TNewRadioButton;
  ContinueButton: TNewButton;
  CancelButton: TNewButton;
  ButtonWidth: Integer;
begin
  OptionsForm := CreateCustomForm();
  try
    OptionsForm.Caption := '卸载 Aether study';
    OptionsForm.ClientWidth := ScaleX(380);
    OptionsForm.ClientHeight := ScaleY(175);

    PromptLabel := TNewStaticText.Create(OptionsForm);
    PromptLabel.Parent := OptionsForm;
    PromptLabel.Left := ScaleX(20);
    PromptLabel.Top := ScaleY(18);
    PromptLabel.Caption := '请选择卸载方式：';
    PromptLabel.AutoSize := True;

    KeepDataRadio := TNewRadioButton.Create(OptionsForm);
    KeepDataRadio.Parent := OptionsForm;
    KeepDataRadio.Left := ScaleX(30);
    KeepDataRadio.Top := ScaleY(52);
    KeepDataRadio.Width := ScaleX(320);
    KeepDataRadio.Caption := '保留用户数据';
    KeepDataRadio.Checked := True;

    PurgeDataRadio := TNewRadioButton.Create(OptionsForm);
    PurgeDataRadio.Parent := OptionsForm;
    PurgeDataRadio.Left := KeepDataRadio.Left;
    PurgeDataRadio.Top := ScaleY(82);
    PurgeDataRadio.Width := KeepDataRadio.Width;
    PurgeDataRadio.Caption := '删除所有用户数据';

    ContinueButton := TNewButton.Create(OptionsForm);
    ContinueButton.Parent := OptionsForm;
    ContinueButton.Caption := '继续卸载';
    ContinueButton.Top := OptionsForm.ClientHeight - ScaleY(35);
    ContinueButton.Height := ScaleY(25);
    ContinueButton.ModalResult := mrOk;
    ContinueButton.Default := True;

    CancelButton := TNewButton.Create(OptionsForm);
    CancelButton.Parent := OptionsForm;
    CancelButton.Caption := '取消';
    CancelButton.Top := ContinueButton.Top;
    CancelButton.Height := ContinueButton.Height;
    CancelButton.ModalResult := mrCancel;
    CancelButton.Cancel := True;

    ButtonWidth := OptionsForm.CalculateButtonWidth([
      ContinueButton.Caption,
      CancelButton.Caption
    ]);
    ContinueButton.Width := ButtonWidth;
    CancelButton.Width := ButtonWidth;
    CancelButton.Left := OptionsForm.ClientWidth - CancelButton.Width - ScaleX(12);
    ContinueButton.Left := CancelButton.Left - ContinueButton.Width - ScaleX(8);

    OptionsForm.ActiveControl := KeepDataRadio;
    Result := OptionsForm.ShowModal() = mrOk;
    if Result then
      PurgeAllUserData := PurgeDataRadio.Checked;
  finally
    OptionsForm.Free();
  end;
end;

function InitializeUninstall(): Boolean;
var
  PurgeParameter: String;
  PurgeMarker: String;
begin
  Result := True;
  PurgeParameter := ExpandConstant('{param:PURGEUSERDATA|}');
  { Store the choice under the install directory; the temporary directory can
    change when the uninstaller restarts elevated, which used to lose the marker. }
  PurgeMarker := ExpandConstant('{app}\.purge-choice.txt');
  DeleteFile(PurgeMarker);

  if CompareText(PurgeParameter, '1') = 0 then
  begin
    PurgeAllUserData := True;
    SaveStringToFile(PurgeMarker, 'all', False);
    Exit;
  end;

  if CompareText(PurgeParameter, '0') = 0 then
  begin
    PurgeAllUserData := False;
    SaveStringToFile(PurgeMarker, 'keep', False);
    Exit;
  end;

  if UninstallSilent then
  begin
    PurgeAllUserData := False;
    SaveStringToFile(PurgeMarker, 'keep', False);
    Exit;
  end;

  Result := ShowUninstallDataOptions();
  if Result then
  begin
    if PurgeAllUserData then
      SaveStringToFile(PurgeMarker, 'all', False)
    else
      SaveStringToFile(PurgeMarker, 'keep', False);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  CleanupScript: String;
  CleanupContent: String;
  ResultCode: Integer;
begin
  if (CurUninstallStep = usPostUninstall) and PurgeAllUserData then
  begin
    { The uninstaller can keep the empty install directory open until it exits.
      Run the final directory removal from the temporary directory after a delay. }
    CleanupScript := ExpandConstant('{tmp}\AetherStudy-final-cleanup.cmd');
    CleanupContent :=
      '@echo off' + #13#10 +
      'ping 127.0.0.1 -n 4 >nul' + #13#10 +
      'rmdir /s /q "' + ExpandConstant('{app}') + '"' + #13#10 +
      'del /f /q "%~f0"' + #13#10;
    SaveStringToFile(CleanupScript, CleanupContent, False);
    Exec(
      ExpandConstant('{cmd}'),
      '/d /c ""' + CleanupScript + '""',
      ExpandConstant('{tmp}'),
      SW_HIDE,
      ewNoWait,
      ResultCode
    );
  end;
end;

procedure MirrorBackendPayload;
var
  ResultCode: Integer;
  PayloadRoot: String;
  BackendRoot: String;
  RoboCopyArgs: String;
begin
  PayloadRoot := ExpandConstant('{app}\runtime\backend-payload');
  BackendRoot := ExpandConstant('{app}\runtime\backend');
  ForceDirectories(BackendRoot);
  WizardForm.StatusLabel.Caption := 'Synchronizing the OpenClaw backend runtime...';
  RoboCopyArgs :=
    '"' + PayloadRoot + '" "' + BackendRoot +
    '" /MIR /R:10 /W:1 /NFL /NDL /NJH /NJS /NP';

  if not Exec(
    ExpandConstant('{sys}\robocopy.exe'),
    RoboCopyArgs,
    ExpandConstant('{app}'),
    SW_HIDE,
    ewWaitUntilTerminated,
    ResultCode
  ) then
    RaiseException('Unable to start the backend mirror operation.');

  if ResultCode > 7 then
    RaiseException(
      'Backend mirror failed with robocopy exit code ' + IntToStr(ResultCode) + '.'
    );

  DelTree(PayloadRoot, True, True, True);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  PowerShellArgs: String;
  StopLogPath: String;
begin
  Result := '';
  StopLogPath := AddBackslash(GetDataRoot('')) + 'logs\upgrade-stop.log';

  ExtractTemporaryFile('stop-running-apps.ps1');
  PowerShellArgs :=
    '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{tmp}\stop-running-apps.ps1') + '" -InstallRoot "' +
    ExpandConstant('{app}') + '" -LogPath "' + StopLogPath + '"';

  if not Exec(
    ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    PowerShellArgs,
    ExpandConstant('{tmp}'),
    SW_HIDE,
    ewWaitUntilTerminated,
    ResultCode
  ) then
  begin
    Result := '无法启动升级前的后台服务停止程序。';
    Exit;
  end;

  if ResultCode <> 0 then
    Result :=
      '无法停止正在运行的 Aether study 后台服务。' + #13#10 +
      '请查看日志：' + StopLogPath;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  PowerShellArgs: String;
begin
  if CurStep = ssPostInstall then
  begin
    DeploymentCompleted := False;
    Log('Starting backend deployment; client launch is deferred until installation finishes.');
    MirrorBackendPayload;

    if not ShouldRunBackend then
    begin
      SaveStringToFile(ExpandConstant('{app}\.skip-backend'), 'test-only', False);
      DeploymentCompleted := True;
      Exit;
    end;

    DeleteFile(ExpandConstant('{app}\.skip-backend'));
    WizardForm.StatusLabel.Caption := '正在部署 MedBuddy 预构建服务（零 build、包内 Node）...';
    PowerShellArgs :=
      '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' +
      ExpandConstant('{app}\tools\bootstrap.ps1') + '" -InstallRoot "' +
      ExpandConstant('{app}') + '" -DataRoot "' +
      GetDataRoot('') + '"';

    if not Exec(
      ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      PowerShellArgs,
      ExpandConstant('{app}'),
      SW_HIDE,
      ewWaitUntilTerminated,
      ResultCode
    ) then
      RaiseException('无法启动 OpenClaw 自动部署脚本。');

    if ResultCode <> 0 then
      RaiseException(
        'OpenClaw 自动部署失败。请查看日志：' +
        AddBackslash(GetDataRoot('')) + 'logs\install.log'
      );
    DeploymentCompleted := True;
    Log('Backend deployment completed successfully.');
  end;
end;
