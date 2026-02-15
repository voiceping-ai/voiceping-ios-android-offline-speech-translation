#ifndef SourceDir
  #define SourceDir "artifacts\publish\win-x64"
#endif

#ifndef OutputDir
  #define OutputDir "artifacts\installer"
#endif

#ifndef OutputBaseName
  #define OutputBaseName "OfflineSpeechTranslation-win-x64-setup"
#endif

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{D8BA63C5-230D-4CB4-95FC-CFDBE6179422}
AppName=Offline Speech Translation
AppVersion={#AppVersion}
AppPublisher=OfflineSpeechTranslation
DefaultDirName={autopf}\Offline Speech Translation
DefaultGroupName=Offline Speech Translation
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\OfflineSpeechTranslation.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Offline Speech Translation"; Filename: "{app}\OfflineSpeechTranslation.exe"
Name: "{autodesktop}\Offline Speech Translation"; Filename: "{app}\OfflineSpeechTranslation.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\OfflineSpeechTranslation.exe"; Description: "Launch Offline Speech Translation"; Flags: nowait postinstall skipifsilent

