; CamNexo for Windows installer (Inno Setup 6). Build with build.ps1.
#define AppName "CamNexo"
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef Stage
  #define Stage "stage"
#endif

[Setup]
AppId={{D0500931-1900-43CE-B78C-855D092F9365}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Yantrix Labs
AppPublisherURL=https://camnexo.yantrixlab.com
AppSupportURL=https://camnexo.yantrixlab.com/support.html
DefaultDirName={autopf}\CamNexo
DefaultGroupName=CamNexo
DisableProgramGroupPage=yes
OutputDir=output
OutputBaseFilename=CamNexo-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
WizardStyle=modern
SetupIconFile=..\..\apps\desktop\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\camnexo_desktop.exe
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#Stage}\app\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#Stage}\helpers\*"; DestDir: "{app}\helpers"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\CamNexo"; Filename: "{app}\camnexo_desktop.exe"
Name: "{group}\Uninstall CamNexo"; Filename: "{uninstallexe}"
Name: "{autodesktop}\CamNexo"; Filename: "{app}\camnexo_desktop.exe"; Tasks: desktopicon

[Run]
; The virtual camera lives inside Windows' camera service, which holds the old file open: stop it, replace and register the camera component, start it again.
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Stop-Service FrameServer -Force -ErrorAction SilentlyContinue"""; Flags: runhidden waituntilterminated; StatusMsg: "Preparing the camera service..."
Filename: "{app}\helpers\camnexo_vcam.exe"; Parameters: "register"; Flags: runhidden waituntilterminated; StatusMsg: "Setting up the CamNexo virtual camera..."
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Start-Service FrameServer -ErrorAction SilentlyContinue"""; Flags: runhidden waituntilterminated
; Let phones on your private (home or office) network reach the receiver. Public networks stay blocked.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""CamNexo receiver"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""CamNexo receiver"" dir=in action=allow program=""{app}\helpers\camnexo_receiver.exe"" protocol=TCP localport=7878 profile=private"; Flags: runhidden waituntilterminated; StatusMsg: "Allowing phones on your private network..."
Filename: "{app}\camnexo_desktop.exe"; Description: "Open CamNexo"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Stop-Service FrameServer -Force -ErrorAction SilentlyContinue"""; Flags: runhidden waituntilterminated; RunOnceId: "StopFrameServer"
Filename: "{app}\helpers\camnexo_vcam.exe"; Parameters: "unregister"; Flags: runhidden waituntilterminated; RunOnceId: "UnregisterCamera"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""CamNexo receiver"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveFirewallRule"

[UninstallDelete]
Type: filesandordirs; Name: "{commonappdata}\CamNexo"
