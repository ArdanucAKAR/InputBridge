; Build after windows/scripts/publish-windows.ps1. Requires Inno Setup 6.
#ifndef MyAppVersion
  #define MyAppVersion "0.2.0"
#endif
#define MyAppName "InputBridge"
#define MyAppExeName "InputBridge.exe"

[Setup]
AppId={{A9E43467-1D4F-4B8A-B6ED-6610E4D590D2}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\InputBridge
DefaultGroupName={#MyAppName}
OutputDir=..\dist\installer
OutputBaseFilename=InputBridge-Windows-Setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64
DisableProgramGroupPage=yes
WizardStyle=modern

[Files]
Source: "..\dist\publish\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked
Name: "autostart"; Description: "Start InputBridge when I sign in"; GroupDescription: "Startup:"; Flags: checkedonce

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "InputBridge"; ValueData: """{app}\{#MyAppExeName}"" --background"; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""InputBridge Controller TCP"" dir=in action=allow protocol=TCP localport=41715 profile=private"; Flags: runhidden
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""InputBridge Discovery UDP"" dir=in action=allow protocol=UDP localport=41716 profile=private"; Flags: runhidden
Filename: "{app}\{#MyAppExeName}"; Description: "Launch InputBridge"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""InputBridge Controller TCP"""; Flags: runhidden
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""InputBridge Discovery UDP"""; Flags: runhidden
