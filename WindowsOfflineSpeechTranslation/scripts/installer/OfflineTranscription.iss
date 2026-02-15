#ifndef SourceDir
  #define SourceDir "artifacts\publish\win-x64"
#endif

#ifndef OutputDir
  #define OutputDir "artifacts\installer"
#endif

#ifndef OutputBaseName
  #define OutputBaseName "OfflineTranscription-win-x64-setup"
#endif

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{D8BA63C5-230D-4CB4-95FC-CFDBE6179422}
AppName=Offline Transcription
AppVersion={#AppVersion}
AppPublisher=OfflineTranscription
DefaultDirName={autopf}\Offline Transcription
DefaultGroupName=Offline Transcription
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\OfflineTranscription.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Offline Transcription"; Filename: "{app}\OfflineTranscription.exe"
Name: "{autodesktop}\Offline Transcription"; Filename: "{app}\OfflineTranscription.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\OfflineTranscription.exe"; Description: "Launch Offline Transcription"; Flags: nowait postinstall skipifsilent

