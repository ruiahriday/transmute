; Transmute for Windows installer (Inno Setup 6.3 or later).
; Build with: ISCC /DArch=x64|arm64|universal /DVersion=1.0.0 /DSourceRoot=<publish folder> Transmute.iss
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
  #define OutputName "Transmute-Setup"
#endif

[Setup]
AppId={{6C1C2A53-1F8E-4C4B-9D0B-3E7A1B5F2D90}
AppName=Transmute
AppVersion={#Version}
AppVerName=Transmute {#Version} beta
AppPublisher=Transmute
AppPublisherURL=https://github.com/ruiahriday/transmute
AppSupportURL=https://github.com/ruiahriday/transmute/issues
DefaultDirName={autopf}\Transmute
DefaultGroupName=Transmute
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
UninstallDisplayIcon={app}\Transmute.exe
UninstallDisplayName=Transmute
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
AppMutex=TransmuteRunning
CloseApplications=yes
RestartApplications=no
ChangesAssociations=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Put a Transmute icon on the desktop"; Flags: unchecked
Name: "contextmenu"; Description: "Add ""Convert with Transmute"" when you right-click files and folders"
Name: "startup"; Description: "Start Transmute when I sign in (for the drag wheel and floating files)"

[Files]
#if Arch == "x64" || Arch == "universal"
Source: "{#SourceRoot}\x64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: not IsArm64
#endif
#if Arch == "arm64" || Arch == "universal"
Source: "{#SourceRoot}\arm64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsArm64
#endif

[Icons]
Name: "{autoprograms}\Transmute"; Filename: "{app}\Transmute.exe"
Name: "{autodesktop}\Transmute"; Filename: "{app}\Transmute.exe"; Tasks: desktopicon
; Right-click › Send to › Transmute works on many files at once.
Name: "{usersendto}\Transmute"; Filename: "{app}\Transmute.exe"

[Registry]
Root: HKA; Subkey: "Software\Classes\*\shell\Transmute"; ValueType: string; ValueName: ""; ValueData: "Convert with Transmute"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\*\shell\Transmute"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\Transmute.exe"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\*\shell\Transmute"; ValueType: string; ValueName: "MultiSelectModel"; ValueData: "Player"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\*\shell\Transmute\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Transmute.exe"" ""%1"""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Transmute"; ValueType: string; ValueName: ""; ValueData: "Convert with Transmute"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Transmute"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\Transmute.exe"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Transmute\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Transmute.exe"" ""%1"""; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Transmute"; ValueData: """{app}\Transmute.exe"" --background"; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\Transmute.exe"; Description: "Open Transmute now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im Transmute.exe"; Flags: runhidden; RunOnceId: "StopTransmute"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  // "Start when I sign in" can also be turned on in Settings, outside the installer.
  if CurUninstallStep = usPostUninstall then
    RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Transmute');
end;
