

$ErrorActionPreference = "Stop"
$scriptUrl = "https://raw.githubusercontent.com/Mestalic/MestalWinBox/refs/heads/main/Mestal.ps1"
$runKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$persist = "AutoSetupContinue"
$stageReg = "HKLM:\SOFTWARE\AutoWinSetup"
$tempDir = "$env:TEMP\AutoSetup"
New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

# Self-elevate
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -Command `"irm '$scriptUrl' | iex`"" -Verb RunAs
    exit
}

# Persistence
function Set-Stage($s) { New-ItemProperty -Path $stageReg -Name Stage -Value $s -Force -ErrorAction SilentlyContinue }
function Get-Stage {
    $prop = Get-ItemProperty -Path $stageReg -Name Stage -ErrorAction SilentlyContinue
    if ($prop) { $prop.Stage } else { "start" }
}
function Reboot-Continue {
    Set-ItemProperty -Path $runKey -Name $persist -Value "powershell -NoProfile -ExecutionPolicy Bypass -Command `"irm '$scriptUrl' | iex`""
    Restart-Computer -Force
}
function Finish {
    Remove-ItemProperty -Path $runKey -Name $persist -EA SilentlyContinue
    Remove-Item -Path $stageReg -Recurse -Force -EA SilentlyContinue
    Remove-Item -Path $tempDir -Recurse -Force -EA SilentlyContinue
    Write-Host "Setup complete!" -ForegroundColor Green
}

# === PORTED DEBLOAT & TWEAKS FROM ChrisTitusTech/winutil main (2025-11) ===
$packagesToRemove = @(
    "Microsoft.549981C3F5F10", #Cortana
    "Microsoft.BingWeather","Microsoft.GetHelp","Microsoft.Getstarted","Microsoft.MSPaint",
    "Microsoft.Microsoft3DViewer","Microsoft.MicrosoftOfficeHub","Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.MixedReality.Portal","Microsoft.OneDrive","Microsoft.People","Microsoft.SkypeApp",
    "Microsoft.Wallet","Microsoft.WindowsAlarms","Microsoft.WindowsCamera","Microsoft.WindowsFeedbackHub",
    "Microsoft.WindowsMaps","Microsoft.Xbox*","Microsoft.YourPhone","Microsoft.ZuneMusic","Microsoft.ZuneVideo"
)
foreach ($pkg in $packagesToRemove) { Get-AppxPackage $pkg -AllUsers | Remove-AppxPackage -AllUsers -EA SilentlyContinue; Get-AppxProvisionedPackage -Online | Where DisplayName -like $pkg | Remove-AppxProvisionedPackage -Online -EA SilentlyContinue }

# Registry tweaks
Set-ItemProperty "HKCU:\Control Panel\Mouse" MouseSpeed 0
Set-ItemProperty "HKCU:\Control Panel\Mouse" MouseThreshold1 0
Set-ItemProperty "HKCU:\Control Panel\Mouse" MouseThreshold2 0
Set-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" AppsUseLightTheme 0
Set-ItemProperty "HKCU:\Control Panel\Accessibility\StickyKeys" Flags "506"
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" DisableFileSyncNGSC 1
Set-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" BingSearchEnabled 0
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" AllowTelemetry 0

# Services
"DiagTrack","dmwappushservice","lfsvc","MapsBroker","WMPNetworkSvc","XblAuthManager","XblGameSave","XboxNetApiSvc" | % { Stop-Service $_ -Force -EA SilentlyContinue; Set-Service $_ -StartupType Disabled }

# Scheduled tasks disable
Get-ScheduledTask | ? {$_.TaskPath -like "*\Microsoft\Windows\Application Experience*"} | Disable-ScheduledTask
Get-ScheduledTask | ? {$_.TaskPath -like "*\Microsoft\Windows\Customer Experience Improvement Program*"} | Disable-ScheduledTask

# === STAGES ===
switch (Get-Stage) {
    "start" {
        # Repair winget
        if (!(Get-Command winget -EA SilentlyContinue)) {
            Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -EA SilentlyContinue
            1..5 | % { Start-Process "ms-windows-store://downloadsandupdates"; Start-Sleep 60 }
            if (!(Get-Command winget -EA SilentlyContinue)) { Reboot-Continue }
        }
        Set-Stage "winget"; Reboot-Continue
    }
    "winget" {
        # Debloating & tweaks already embedded above
        Set-Stage "tweaks"
    }
    "tweaks" {
        winget install --id Valve.Steam --silent --accept-package-agreements --accept-source-agreements
        winget install --id Discord.Discord --silent --accept...
        winget install --id Spotify.Spotify --silent --accept...
        winget install --id VideoLAN.VLC --silent...
        winget install --id 7zip.7zip --silent...
        winget install --id Bitwarden.Bitwarden --silent...
        winget install --id Python.Python.3 --silent...
        winget install --id Git.Git --silent...
        winget install --id voidtools.Everything --silent...
        winget install --id WizTree.WizTree --silent...
        winget install --id EpicGames.EpicGamesLauncher --silent...
        winget install --id Modrinth.ModrinthApp --silent...
        winget install --id Logitech.GHUB --silent...

        # Manual installs
        iwr "https://github.com/Alex313031/thorium/releases/latest/download/thorium_mini_installer.exe" -OutFile "$tempDir\thorium.exe"; & "$tempDir\thorium.exe" /S
        iwr "https://setup.rbxcdn.com/RobloxPlayerLauncher.exe" -OutFile "$tempDir\roblox.exe"; & "$tempDir\roblox.exe" /S
        powershell -Command "iwr https://vencord.dev/install.ps1 | iex"
        iwr "https://github.com/tcno/TcNo-Acc-Switcher/releases/latest/download/TcNo_Account_Switcher_Installer.exe" -OutFile "$tempDir\tcno.exe"; & "$tempDir\tcno.exe" /VERYSILENT

        Set-Stage "apps"
    }
    "apps" {
        $gpu = (Get-WmiObject Win32_VideoController).Name
        if ($gpu -like "*NVIDIA*") {
            iwr "https://us.download.nvidia.com/NVIDIA-app/latest/NVIDIA-app-installer.exe" -OutFile "$tempDir\nvidia.exe"; & "$tempDir\nvidia.exe" -s
        } elseif ($gpu -like "*AMD*") {
            iwr "https://drivers.amd.com/drivers/amd-software-adrenalin-edition-latest.exe" -OutFile "$tempDir\amd.exe"; & "$tempDir\amd.exe" /S
        }
        Set-Stage "gpu"
    }
    "gpu" {
        # PORTED MAS HWID ACTIVATION (direct code from Massgravel/Microsoft-Activation-Scripts)
        $url = "https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/master/MAS/All-In-One-Version/MAS_AIO.cmd"
        $mas = (Invoke-WebRequest $url -UseBasicParsing).Content
        $mas = $mas -replace "@echo off","" -replace "pause","" -replace "exit /b",""
        Invoke-Expression $mas
        # Auto select HWID for Windows 10/11 Pro
        Start-Process "powershell" "-Command `"echo 2 | & '$env:TEMP\MAS_AIO.cmd'`""
        Set-Stage "done"
        Reboot-Continue
    }
    "done" { Finish }
}
