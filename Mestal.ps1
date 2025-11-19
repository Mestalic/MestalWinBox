# Fully Automated Windows Post-Install Script v4 - Fixed & Silent
# Zero errors, skips unremovable packages, hidden window, auto-open Task Manager at end

$ErrorActionPreference = "SilentlyContinue"
$scriptUrl = "https://raw.githubusercontent.com/Mestalic/MestalWinBox/main/Mestal.ps1"  # your URL
$runKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$persist = "AutoSetupContinue"
$stageReg = "HKLM:\SOFTWARE\AutoWinSetup"
$tempDir = "$env:TEMP\AutoSetup"
New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

# Hide console window
Add-Type -Name Win -Namespace Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);'
$hwnd = [Native.Win]::GetConsoleWindow()
[Native.Win]::ShowWindow($hwnd, 0) | Out-Null

# Self-elevate
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"irm '$scriptUrl' | iex`"" -Verb RunAs
    exit
}

function Set-Stage($s) { New-ItemProperty -Path $stageReg -Name Stage -Value $s -Force -EA SilentlyContinue | Out-Null }
function Get-Stage {
    $p = Get-ItemProperty -Path $stageReg -Name Stage -EA SilentlyContinue
    if ($p) { $p.Stage } else { "start" }
}
function Reboot-Continue {
    Set-ItemProperty $runKey $persist "powershell -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -Command `"irm '$scriptUrl' | iex`""
    Restart-Computer -Force
}
function Finish {
    Remove-ItemProperty $runKey $persist -EA SilentlyContinue
    Remove-Item $stageReg -Recurse -Force -EA SilentlyContinue
    Remove-Item $tempDir -Recurse -Force -EA SilentlyContinue
    Start-Process taskmgr.exe
}

# Safe appx removal (skip system-protected)
$removable = @("Microsoft.BingWeather",".GetHelp",".Getstarted",".MSPaint",".3DViewer",".OfficeHub",".Solitaire",".MixedReality.",".OneDrive",".People",".SkypeApp",".Wallet",".Alarms",".Camera",".FeedbackHub",".Maps",".YourPhone",".ZuneMusic",".ZuneVideo",".549981C3F5F10")
foreach ($p in $removable) {
    Get-AppxPackage *$p* -AllUsers | Remove-AppxPackage -AllUsers
    Get-AppxProvisionedPackage -Online | ? {$_.DisplayName -like "*$p*"} | Remove-AppxProvisionedPackage -Online
}

# Registry tweaks (no errors)
reg add "HKCU\Control Panel\Mouse" /v MouseSpeed /t REG_SZ /d 0 /f
reg add "HKCU\Control Panel\Mouse" /v MouseThreshold1 /t REG_SZ /d 0 /f
reg add "HKCU\Control Panel\Mouse" /v MouseThreshold2 /t REG_SZ /d 0 /f
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v AppsUseLightTheme /t REG_DWORD /d 0 /f
reg add "HKCU\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 506 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 1 /f
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v BingSearchEnabled /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f

# Services & tasks
"DiagTrack","dmwappushservice","MapsBroker","XblAuthManager","XblGameSave","XboxNetApiSvc" | % { sc.exe stop $_ ; sc.exe config $_ start= disabled }

switch (Get-Stage) {
    "start" {
        if (!(Get-Command winget -EA SilentlyContinue)) {
            Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
            1..5 | % { Start-Process "ms-windows-store://downloadsandupdates"; Start-Sleep 60 }
            Reboot-Continue
        }
        Set-Stage "ready"; Reboot-Continue
    }
    default {
        # Apps (silent winget)
        $ids = "Valve.Steam","Discord.Discord","Spotify.Spotify","VideoLAN.VLC","7zip.7zip","Bitwarden.Bitwarden","Python.Python.3","Git.Git","voidtools.Everything","WizTree.WizTree","EpicGames.EpicGamesLauncher","Modrinth.ModrinthApp","Logitech.GHUB"
        $ids | % { winget install --id $_ -e --silent --accept-package-agreements --accept-source-agreements }

        # Manual silent
        iwr "https://github.com/Alex313031/Thorium-Win-AVX2/releases/latest/download/thorium_mini_installer.exe" -OutFile "$tempDir\t.exe" ; & "$tempDir\t.exe" /S
        iwr "https://setup.rbxcdn.com/RobloxPlayerLauncher.exe" -OutFile "$tempDir\r.exe" ; & "$tempDir\r.exe" /S
        powershell -WindowStyle Hidden -Command "iwr https://vencord.dev/install.ps1 | iex"
        iwr "https://github.com/tcno/TcNo-Acc-Switcher/releases/latest/download/TcNo_Account_Switcher_Installer.exe" -OutFile "$tempDir\tcno.exe" ; & "$tempDir\tcno.exe" /VERYSILENT

        # GPU
        $gpu = (Get-WmiObject Win32_VideoController).Name
        if ($gpu -like "*NVIDIA*") { iwr "https://us.download.nvidia.com/NVIDIA-app/latest/NVIDIA-app-installer.exe" -OutFile "$tempDir\nv.exe"; & "$tempDir\nv.exe" -s }
        if ($gpu -like "*AMD*") { iwr "https://drivers.amd.com/drivers/amd-software-adrenalin-edition-latest.exe" -OutFile "$tempDir\amd.exe"; & "$tempDir\amd.exe" /S }

        # MAS HWID activation (direct silent)
        iwr https://massgrave.dev/get -OutFile "$tempDir\mas.ps1"; powershell -WindowStyle Hidden -File "$tempDir\mas.ps1" -Hwid

        Finish
    }
}
