; Spinform for Windows installer (Inno Setup 6.3 or later). Spinform used to be called Transmute.
; Build with: ISCC /DArch=x64|arm64|universal /DVersion=1.0.0 /DSourceRoot=<publish folder> Spinform.iss
; SourceRoot holds one folder per architecture: x64\ and arm64\, each a published copy of the app.

#ifndef Arch
  #define Arch "universal"
#endif
#ifndef Version
  #define Version "1.0.0"
#endif
#ifndef SourceRoot
  #define SourceRoot "..\out\publish"
#endif
#ifndef OutputName
  #define OutputName "Spinform-Setup"
#endif

[Setup]
; The AppId is the one Transmute had, so installing Spinform updates an existing Transmute in place
; (one entry in Installed apps, settings kept) instead of adding a second app. Never change it.
AppId={{6C1C2A53-1F8E-4C4B-9D0B-3E7A1B5F2D90}
AppName=Spinform
AppVersion={#Version}
AppVerName=Spinform {#Version} beta
AppPublisher=Spinform
AppPublisherURL=https://github.com/ruiahriday/transmute
AppSupportURL=https://github.com/ruiahriday/transmute/issues
; New installs go to ...\Spinform. An update of Transmute moves from ...\Transmute to ...\Spinform next to it
; (see DefaultDir below); any other folder someone picked stays as it is.
DefaultDirName={code:DefaultDir}
UsePreviousAppDir=no
DefaultGroupName=Spinform
DisableProgramGroupPage=yes
DisableDirPage=auto
; No administrator password needed: installs for the current user (Windows asks only if they pick "all users").
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
MinVersion=10.0.17763
#if Arch == "x64"
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#elif Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=x64compatible or arm64
#endif
OutputDir=..\out\installers
OutputBaseFilename={#OutputName}
SetupIconFile=..\src\Transmute\Assets\app.ico
UninstallDisplayIcon={app}\Spinform.exe
UninstallDisplayName=Spinform
Compression=lzma2/max
LZMANumBlockThreads=4
LZMAUseSeparateProcess=yes
SolidCompression=yes
WizardStyle=modern
; Brand pictures, made by windows/branding/make_windows_icon.py.
WizardImageFile=wizard-164.bmp,wizard-328.bmp
WizardSmallImageFile=wizard-small-55.bmp,wizard-small-83.bmp,wizard-small-110.bmp
; SpinformRunning is made by Spinform, TransmuteRunning by Transmute before the rename.
AppMutex=SpinformRunning,TransmuteRunning
CloseApplications=yes
RestartApplications=no
ChangesAssociations=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Put a Spinform icon on the desktop"; Flags: unchecked
Name: "contextmenu"; Description: "Add ""Convert with Spinform"" when you right-click files and folders"
Name: "startup"; Description: "Start Spinform when I sign in (for the drag wheel and floating files)"

[InstallDelete]
; Left over from Transmute, the app's old name: its program files (Transmute.Core.dll is still used) and shortcuts.
Type: files; Name: "{app}\Transmute.exe"
Type: files; Name: "{app}\Transmute.dll"
Type: files; Name: "{app}\Transmute.pdb"
Type: files; Name: "{app}\Transmute.deps.json"
Type: files; Name: "{app}\Transmute.runtimeconfig.json"
Type: files; Name: "{autoprograms}\Transmute.lnk"
Type: files; Name: "{autodesktop}\Transmute.lnk"
Type: files; Name: "{userdesktop}\Transmute.lnk"
Type: files; Name: "{usersendto}\Transmute.lnk"

[Files]
#if Arch == "x64" || Arch == "universal"
Source: "{#SourceRoot}\x64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: not IsArm64
#endif
#if Arch == "arm64" || Arch == "universal"
Source: "{#SourceRoot}\arm64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsArm64
#endif

[Icons]
Name: "{autoprograms}\Spinform"; Filename: "{app}\Spinform.exe"
Name: "{autodesktop}\Spinform"; Filename: "{app}\Spinform.exe"; Tasks: desktopicon
; Right-click › Send to › Spinform works on many files at once.
Name: "{usersendto}\Spinform"; Filename: "{app}\Spinform.exe"

[Registry]
; Transmute's right-click entries go; Spinform's own come back below if that task is ticked.
Root: HKA; Subkey: "Software\Classes\*\shell\Transmute"; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\Transmute"; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\*\shell\Spinform"; ValueType: string; ValueName: ""; ValueData: "Convert with Spinform"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\*\shell\Spinform"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\Spinform.exe"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\*\shell\Spinform"; ValueType: string; ValueName: "MultiSelectModel"; ValueData: "Player"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\*\shell\Spinform\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Spinform.exe"" ""%1"""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Spinform"; ValueType: string; ValueName: ""; ValueData: "Convert with Spinform"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Spinform"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\Spinform.exe"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Spinform\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Spinform.exe"" ""%1"""; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Spinform"; ValueData: """{app}\Spinform.exe"" --background"; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\Spinform.exe"; Description: "Open Spinform now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im Spinform.exe"; Flags: runhidden; RunOnceId: "StopSpinform"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
const
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{6C1C2A53-1F8E-4C4B-9D0B-3E7A1B5F2D90}_is1';
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';

var
  PreviousDir: String;

// Where the app is installed now (Transmute or an earlier Spinform), or '' for a new install.
function InstalledDir(): String;
var
  Root: Integer;
begin
  Result := '';
  if IsAdminInstallMode then Root := HKLM else Root := HKCU;
  if not RegQueryStringValue(Root, UninstallKey, 'Inno Setup: App Path', Result) then Result := '';
  Result := RemoveBackslashUnlessRoot(Result);
end;

// True when Dir is Transmute's own install folder, which Spinform moves away from.
function IsOldTransmuteDir(Dir: String): Boolean;
begin
  Result := (Dir <> '') and SameText(ExtractFileName(Dir), 'Transmute') and FileExists(AddBackslash(Dir) + 'Transmute.exe');
end;

function InitializeSetup(): Boolean;
begin
  PreviousDir := InstalledDir();
  Result := True;
end;

function DefaultDir(Param: String): String;
begin
  if IsOldTransmuteDir(PreviousDir) then
    Result := AddBackslash(ExtractFileDir(PreviousDir)) + 'Spinform'
  else if PreviousDir <> '' then
    Result := PreviousDir
  else
    Result := ExpandConstant('{autopf}\Spinform');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  // Transmute, if it's still running (a silent update skips the "please close it" question).
  if PreviousDir <> '' then
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im Transmute.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Value: String;
begin
  if CurStep <> ssPostInstall then Exit;
  // "Start when I sign in", if Transmute had it on (from Settings or its installer), now starts Spinform.
  if RegQueryStringValue(HKEY_CURRENT_USER, RunKey, 'Transmute', Value) then
  begin
    RegDeleteValue(HKEY_CURRENT_USER, RunKey, 'Transmute');
    RegWriteStringValue(HKEY_CURRENT_USER, RunKey, 'Spinform', '"' + ExpandConstant('{app}\Spinform.exe') + '" --background');
  end;
  // Transmute's old folder, now that everything lives in the Spinform folder.
  if IsOldTransmuteDir(PreviousDir) and not SameText(PreviousDir, RemoveBackslashUnlessRoot(ExpandConstant('{app}'))) then
    DelTree(PreviousDir, True, True, True);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  // "Start when I sign in" can also be turned on in Settings, outside the installer.
  if CurUninstallStep = usPostUninstall then
  begin
    RegDeleteValue(HKEY_CURRENT_USER, RunKey, 'Spinform');
    RegDeleteValue(HKEY_CURRENT_USER, RunKey, 'Transmute');
  end;
end;
