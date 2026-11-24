; Установщик iPod Converter для Windows (Inno Setup 6). Собирает build_windows.ps1 -Installer:
;   ISCC.exe /DAppVersion=1.5 /DArch=x64 /DSourceDir=...\build-windows\x64\iPod Converter /DOutputDir=...\build-windows windows\installer.iss
; Ставит в Program Files (или только для текущего пользователя — выбор в начале), ярлык в «Пуск», по желанию на рабочий стол,
; пункт удаления в «Приложения». Настройки и журнал пользователя (%LOCALAPPDATA%\iPod Converter) при удалении не трогает.

#ifndef AppVersion
  #define AppVersion "0.0"
#endif
#ifndef Arch
  #define Arch "x64"
#endif

[Setup]
AppId={{6F1C2B7E-3A54-4E2B-9C1D-8A7F0B5E2D41}
AppName=iPod Converter
AppVersion={#AppVersion}
AppVerName=iPod Converter {#AppVersion}
AppPublisher=Julian Ivanov
AppPublisherURL=https://github.com/JulianIvanov125/Ipod-Converter
AppSupportURL=https://github.com/JulianIvanov125/Ipod-Converter/issues
AppUpdatesURL=https://github.com/JulianIvanov125/Ipod-Converter/releases/latest
DefaultDirName={autopf}\iPod Converter
DefaultGroupName=iPod Converter
DisableProgramGroupPage=yes
LicenseFile={#SourceDir}\LICENSE
OutputDir={#OutputDir}
OutputBaseFilename=iPod-Converter-{#AppVersion}-Windows-{#Arch}-Setup
SetupIconFile=WinUI\Assets\AppIcon.ico
UninstallDisplayIcon={app}\iPod Converter.exe
UninstallDisplayName=iPod Converter
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Установить для всех (нужны права администратора) или только для себя — спрашивается в начале.
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
MinVersion=10.0.19041
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
; x64 работает и на ARM-ноутбуках через эмуляцию, но там лучше arm64-установщик.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
; Запущенное окно закрывается перед обновлением/удалением.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "uk"; MessagesFile: "compiler:Languages\Ukrainian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\iPod Converter"; Filename: "{app}\iPod Converter.exe"
Name: "{autodesktop}\iPod Converter"; Filename: "{app}\iPod Converter.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\iPod Converter.exe"; Description: "{cm:LaunchProgram,iPod Converter}"; Flags: nowait postinstall skipifsilent

[Code]
// Удаление само окно не закрывает: открытая программа держит DLL, и папка в Program Files оставалась.
// Закрываем окно и движок (с ffmpeg) и ждём, пока процессы действительно выйдут, — только потом удаляются файлы.
function IsRunning(const Exe: String): Boolean;
var Code: Integer;
begin
  Exec(ExpandConstant('{cmd}'), '/C tasklist /FI "IMAGENAME eq ' + Exe + '" /NH | find /I "' + Exe + '"', '',
       SW_HIDE, ewWaitUntilTerminated, Code);
  Result := Code = 0;
end;

procedure CloseApp;
var Code, I: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM "iPod Converter.exe"', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM iPodConverter.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  for I := 1 to 40 do
  begin
    if not IsRunning('iPod Converter.exe') and not IsRunning('iPodConverter.exe') then Break;
    Sleep(250);
  end;
  Sleep(500);  // Windows ещё отпускает загруженные DLL
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then CloseApp;
end;
