# Mestal.ps1 - Complete Windows 10/11 Setup and Optimization Script
# Launch with: irm "https://raw.githubusercontent.com/Mestalic/MestalWinBox/main/Mestal.ps1" | iex

# Hide console window immediately
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WindowHelper {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
[WindowHelper]::ShowWindow([WindowHelper]::GetConsoleWindow(), 0)

# Ensure running as Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs -WindowStyle Hidden
    exit
}

# Global variables
$Script:TempDir = "$env:TEMP\MestalTemp"
$Script:RegistryPath = "HKLM:\SOFTWARE\MestalWinBox"
$Script:Stage = 0

# Create temp directory
if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}

# Registry persistence functions
function Initialize-Persistence {
    if (-not (Test-Path $RegistryPath)) {
        New-Item -Path $RegistryPath -Force | Out-Null
    }
    $Script:Stage = (Get-ItemProperty -Path $RegistryPath -Name "Stage" -ErrorAction SilentlyContinue).Stage
    if ($null -eq $Script:Stage) {
        $Script:Stage = 0
        Set-ItemProperty -Path $RegistryPath -Name "Stage" -Value $Script:Stage
    }
}

function Update-Stage {
    param([int]$NewStage)
    $Script:Stage = $NewStage
    Set-ItemProperty -Path $RegistryPath -Name "Stage" -Value $Script:Stage
}

function Set-Persistent {
    $runKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    Set-ItemProperty -Path $runKey -Name "MestalWinBox" -Value "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"irm 'https://raw.githubusercontent.com/Mestalic/MestalWinBox/main/Mestal.ps1' | iex`""
}

function Remove-Persistence {
    $runKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    Remove-ItemProperty -Path $runKey -Name "MestalWinBox" -ErrorAction SilentlyContinue
    Remove-Item -Path $RegistryPath -Recurse -Force -ErrorAction SilentlyContinue
}

# Winget repair function
function Repair-Winget {
    try {
        $wingetTest = winget --version 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        
        # Re-register Appx package
        Add-AppxPackage -DisableDevelopmentMode -Register "$((Get-AppxPackage Microsoft.DesktopAppInstaller).InstallLocation)\AppxManifest.xml" -ErrorAction SilentlyContinue
        
        # Open Store updates multiple times
        for ($i = 1; $i -le 6; $i++) {
            Start-Process "ms-windows-store://downloadsandupdates"
            Start-Sleep -Seconds 10
            Stop-Process -Name "WinStore.App" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
        }
        
        # Check again
        winget --version 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

# Chris Titus WinUtil debloat functions
function Remove-BloatPackages {
    $packages = @(
        "Microsoft.BingNews", "Microsoft.BingWeather", "Microsoft.GetHelp",
        "Microsoft.Getstarted", "Microsoft.MicrosoftOfficeHub",
        "Microsoft.MicrosoftSolitaireCollection", "Microsoft.People",
        "Microsoft.SkypeApp", "Microsoft.WindowsFeedbackHub",
        "Microsoft.Xbox.TCUI", "Microsoft.XboxApp", "Microsoft.XboxGameOverlay",
        "Microsoft.XboxGamingOverlay", "Microsoft.XboxIdentityProvider",
        "Microsoft.XboxSpeechToTextOverlay", "Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo", "Microsoft.WindowsMaps", "Microsoft.MicrosoftStickyNotes",
        "Microsoft.MSPaint", "Microsoft.Windows.Photos", "Microsoft.WindowsCamera",
        "Microsoft.WindowsStore", "Microsoft.WindowsAlarms", "Microsoft.WindowsCalculator",
        "Microsoft.WindowsCommunicationsApps", "Microsoft.YourPhone", "Microsoft.MixedReality.Portal"
    )
    
    foreach ($pkg in $packages) {
        try {
            Get-AppxPackage -Name $pkg -AllUsers | Remove-AppxPackage -ErrorAction SilentlyContinue
            Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $pkg } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

function Remove-OneDrive {
    try {
        Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $oneDriveSetup = "${env:SystemRoot}\System32\OneDriveSetup.exe"
        if (Test-Path $oneDriveSetup) {
            Start-Process $oneDriveSetup -ArgumentList "/uninstall" -Wait -WindowStyle Hidden
        }
        $oneDriveSetupSysWOW64 = "${env:SystemRoot}\SysWOW64\OneDriveSetup.exe"
        if (Test-Path $oneDriveSetupSysWOW64) {
            Start-Process $oneDriveSetupSysWOW64 -ArgumentList "/uninstall" -Wait -WindowStyle Hidden
        }
        Remove-Item -Path "$env:UserProfile\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "${env:LocalAppData}\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "${env:ProgramData}\Microsoft OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {}
}

function Set-EssentialTweaks {
    # Disable mouse acceleration
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value 0 -Type String
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value 0 -Type String
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value 0 -Type String
    
    # Enable dark mode
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -Value 0
    
    # Disable sticky keys
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -Value 506
    
    # Disable Bing in start menu
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -Value 0
    
    # Disable telemetry
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowTelemetry" -Value 0
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 0
    
    # Disable activity history
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "PublishUserActivities" -Value 0
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "UploadUserActivities" -Value 0
    
    # Disable background apps
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsRunInBackground" -Value 2
    
    # Disable GameDVR
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0
    
    # Disable hibernation
    powercfg /hibernate off
    
    # Disable location tracking
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Value "Deny"
    
    # Disable Storage Sense
    Remove-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" -Recurse -Force -ErrorAction SilentlyContinue
    
    # Disable WiFi Sense
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting" -Name "Value" -Value 0
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots" -Name "Value" -Value 0
    
    # Disable advertising ID
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Value 0
    
    # Show hidden files and extensions
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Hidden" -Value 1
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowSuperHidden" -Value 1
}

function Disable-ScheduledTasks {
    $tasks = @(
        "MicrosoftCompatibilityAppraiser", "ProgramDataUpdater", "Consolidator",
        "KernelCeipTask", "UsbCeip", "DmClient", "DmClientOnScenarioDownload"
    )
    foreach ($task in $tasks) {
        try {
            Disable-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

function Disable-Services {
    $services = @(
        "DiagTrack", "SysMain", "WSearch", "XblAuthManager", "XblGameSave",
        "XboxNetApiSvc", "XboxGipSvc", "MapsBroker", "WpnService", "RetailDemo"
    )
    foreach ($service in $services) {
        try {
            Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
            Set-Service -Name $service -StartupType Disabled -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

# App installation functions
function Install-WingetApps {
    $apps = @(
        "Valve.Steam", "Discord.Discord", "Spotify.Spotify",
        "VideoLAN.VLC", "7zip.7zip", "Bitwarden.Bitwarden",
        "Python.Python.3", "Git.Git", "voidtools.Everything",
        "WizTree.WizTree", "EpicGames.EpicGamesLauncher",
        "Modrinth.ModrinthApp", "Logitech.GHUB",
        "NodeJS.NodeJS", "VSCodium.VSCodium"
    )
    
    foreach ($app in $apps) {
        try {
            winget install --id $app --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
        }
        catch {}
    }
}

function Install-ManualApps {
    try {
        # Thorium AVX2 mini installer
        $thoriumUrl = "https://github.com/Alex313031/Thorium-Win/releases/latest/download/Thorium_AVX2_MiniInstaller.exe"
        $thoriumPath = "$TempDir\Thorium.exe"
        Invoke-WebRequest -Uri $thoriumUrl -OutFile $thoriumPath -UseBasicParsing
        Start-Process $thoriumPath -ArgumentList "/S" -Wait -WindowStyle Hidden
        
        # Roblox
        $robloxUrl = "https://setup.rbxcdn.com/RobloxPlayerLauncher.exe"
        $robloxPath = "$TempDir\Roblox.exe"
        Invoke-WebRequest -Uri $robloxUrl -OutFile $robloxPath -UseBasicParsing
        Start-Process $robloxPath -ArgumentList "/S" -Wait -WindowStyle Hidden
        
        # Vencord
        Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -Command `"iwr https://vencord.dev/install.ps1 | iex`"" -Wait
        
        # TCNO Account Switcher
        $tcnoUrl = "https://github.com/TCNOco/TcNo-Acc-Switcher/releases/latest/download/TcNo.Account.Switcher.exe"
        $tcnoPath = "$TempDir\TcNo.exe"
        Invoke-WebRequest -Uri $tcnoUrl -OutFile $tcnoPath -UseBasicParsing
        Start-Process $tcnoPath -ArgumentList "/VERYSILENT" -Wait -WindowStyle Hidden
    }
    catch {}
}

# GPU driver installation
function Install-GPUDrivers {
    try {
        $gpu = Get-WmiObject -Class Win32_VideoController | Where-Object { $_.Name -notlike "*Basic*" } | Select-Object -First 1
        if ($gpu.Name -like "*NVIDIA*") {
            $nvidiaUrl = "https://us.download.nvidia.com/GFE/GFEClient/NVIDIA_Experience.exe"
            $nvidiaPath = "$TempDir\NVIDIA.exe"
            Invoke-WebRequest -Uri $nvidiaUrl -OutFile $nvidiaPath -UseBasicParsing
            Start-Process $nvidiaPath -ArgumentList "-s" -Wait -WindowStyle Hidden
        }
        elseif ($gpu.Name -like "*AMD*" -or $gpu.Name -like "*Radeon*") {
            $amdUrl = "https://drivers.amd.com/drivers/installer/22.40/beta/amd-software-adrenalin-edition-22.40.03.01-minimalsetup.exe"
            $amdPath = "$TempDir\AMD.exe"
            Invoke-WebRequest -Uri $amdUrl -OutFile $amdPath -UseBasicParsing
            Start-Process $amdPath -ArgumentList "/S" -Wait -WindowStyle Hidden
        }
    }
    catch {}
}

# Windows activation
function Activate-Windows {
    try {
        $masScript = @"
irm https://massgrave.dev/get | iex
"@
        Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -Command `"$masScript`"" -Wait
    }
    catch {}
}

# Main execution flow
Initialize-Persistence
Set-Persistent

switch ($Script:Stage) {
    0 {
        # Stage 0: Winget repair
        Update-Stage 1
        if (-not (Repair-Winget)) {
            Restart-Computer -Force
            exit
        }
        # Fall through to continue immediately if winget works
    }
    
    1 {
        # Stage 1: Debloat and tweaks
        Update-Stage 2
        Remove-BloatPackages
        Remove-OneDrive
        Set-EssentialTweaks
        Disable-ScheduledTasks
        Disable-Services
    }
    
    2 {
        # Stage 2: App installation
        Update-Stage 3
        Install-WingetApps
        Install-ManualApps
    }
    
    3 {
        # Stage 3: GPU drivers
        Update-Stage 4
        Install-GPUDrivers
    }
    
    4 {
        # Stage 4: Windows activation
        Update-Stage 5
        Activate-Windows
    }
}

# Cleanup
if ($Script:Stage -ge 5) {
    Remove-Persistence
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process taskmgr.exe
    exit
}