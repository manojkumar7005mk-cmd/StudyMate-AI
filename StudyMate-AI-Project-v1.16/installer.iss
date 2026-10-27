#define MyAppName "StudyMate AI"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Manoj Kumar"
#define MyAppExeName "studymate_ai.exe"
[Setup]
AppId={{C0CFFB17-2E56-4B5D-99A2-7A43C6F2C381}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\StudyMate AI
DefaultGroupName=StudyMate AI
OutputDir=.
OutputBaseFilename=StudyMate-AI-Setup
ArchitecturesInstallIn64BitMode=x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked
[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\StudyMate AI"; Filename: "{app}\studymate_ai.exe"
Name: "{autodesktop}\StudyMate AI"; Filename: "{app}\studymate_ai.exe"; Tasks: desktopicon
[Run]
Filename: "{app}\studymate_ai.exe"; Description: "Launch StudyMate AI"; Flags: postinstall nowait skipifsilent
