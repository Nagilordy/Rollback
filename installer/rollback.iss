; Rollback's Windows installer (Inno Setup). Built by .github/workflows/windows.yml.
; Installs for the current user only, so Windows doesn't ask for an administrator password,
; adds a Start menu entry (and a desktop icon if wanted), and an uninstaller.

#ifndef AppVersion
  #define AppVersion "0.1.1"
#endif

[Setup]
AppId={{6C1F2B7E-6A43-4C7E-9E3B-5F0E1C2A9D41}
AppName=Rollback
AppVersion={#AppVersion}
AppPublisher=Rollback
DefaultDirName={localappdata}\Programs\Rollback
DefaultGroupName=Rollback
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=RollbackSetup
Compression=lzma2
SolidCompression=yes
; Windows 11 look, drawn by Inno Setup itself at the screen's scale: with the plain style the
; checkboxes ("Add a desktop icon", "Open Rollback") came out cut off on high-DPI screens
; (200% scaling and up).
WizardStyle=modern windows11
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName=Rollback
; Rollback's icon on the installer itself and in Windows' list of installed apps.
SetupIconFile=..\packaging\app_icon.ico
UninstallDisplayIcon={app}\Rollback.ico
; Rollback's licence, shown before installing (accepting it is part of installing).
LicenseFile=..\LICENSE

[Tasks]
Name: "desktopicon"; Description: "Add a desktop icon"; GroupDescription: "Shortcuts:"

[Files]
; Everything Flutter built: the app, its DLLs (including the video player) and its data.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Rollback's icon, for the shortcuts and the list of installed apps.
Source: "..\packaging\app_icon.ico"; DestDir: "{app}"; DestName: "Rollback.ico"; Flags: ignoreversion
; Rollback's licence, the third-party notices and the licence texts of the LGPL video
; libraries (libmpv-2.dll: LGPL 3, which is built on the GPL 3 text).
Source: "..\LICENSE"; DestDir: "{app}\licenses"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}\licenses"; DestName: "THIRD_PARTY_NOTICES.txt"; Flags: ignoreversion
Source: "..\packaging\licenses\LGPL-3.0.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\packaging\licenses\GPL-3.0.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion

[InstallDelete]
; Older versions installed the program as player_test.exe: remove it so only Rollback.exe is left.
Type: files; Name: "{app}\player_test.exe"
; Before the rename the app was called Frame: its program, icon and shortcuts go. (An update
; keeps installing into the old folder, so settings and sign-in stay.)
Type: files; Name: "{app}\Frame.exe"
Type: files; Name: "{app}\Frame.ico"
Type: files; Name: "{autoprograms}\Frame.lnk"
Type: files; Name: "{autodesktop}\Frame.lnk"

[Icons]
; The shortcuts use Rollback's icon file directly, so they show it even if Windows has an old
; icon cached for the program.
Name: "{autoprograms}\Rollback"; Filename: "{app}\Rollback.exe"; IconFilename: "{app}\Rollback.ico"
Name: "{autodesktop}\Rollback"; Filename: "{app}\Rollback.exe"; IconFilename: "{app}\Rollback.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\Rollback.exe"; Description: "Open Rollback"; Flags: nowait postinstall skipifsilent
