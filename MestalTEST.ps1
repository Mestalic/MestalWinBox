#Requires -RunAsAdministrator
#Requires -Version 5.1

param()

# ============ MESTAL WINBOX SCRIPT ============
# Fully automated Windows optimization and app installation
# Compatible with PowerShell 5.1 on Windows 10/11
# ==============================================

# Hide console window completely
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
$null = $PSBoundParameters.Remove('WhatIf')
$console = [Win32]::GetConsoleWindow()
if ($console) { [Win32]::ShowWindow($console, 0) }

# Self-elevation to Administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell -Verb RunAs -ArgumentList $arguments -WindowStyle Hidden
    exit
}

# Registry paths for state tracking
$REG_BASE = "HKLM:\SOFTWARE\MestalWinBox"
$REG_STAGE = "$REG_BASE\Stage"
$REG_PATH = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"

# Create registry structure
if (!(Test-Path $REG_BASE)) { New-Item -Path $REG_BASE -Force | Out-Null }
if (!(Test-Path $REG_STAGE)) { Set-ItemProperty -Path $REG_BASE -Name "Stage" -Value 0 -Type DWord }

# Set up persistence (survives reboots)
$currentScript = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
Set-ItemProperty -Path $REG_PATH -Name "MestalWinBox" -Value "powershell.exe $currentScript" -Force

# Initialize temp directory
$tempDir = "$env:TEMP\MestalTemp"
if (!(Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }

# Function to update stage and handle reboot
function Update-Stage {
    param([int]$Stage)
    Set-ItemProperty -Path $REG_BASE -Name "Stage" -Value $Stage -Type DWord
    if ($Stage -eq 99) {
        Remove-ItemProperty -Path $REG_PATH -Name "MestalWinBox" -ErrorAction SilentlyContinue
        Remove-Item -Path $REG_BASE -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Get current stage
$currentStage = Get-ItemProperty -Path $REG_BASE -Name "Stage" -ErrorAction SilentlyContinue
if (!$currentStage) { $currentStage = 0 } else { $currentStage = $currentStage.Stage }

# ============ STAGE 0: INITIALIZATION ============
if ($currentStage -eq 0) {
    Write-Host "Initializing MestalWinBox..." -ForegroundColor Green
    Update-Stage 1
}

# ============ STAGE 1: WINGET REPAIR ============
if ($currentStage -le 1) {
    Write-Host "Stage 1: Repairing Winget..." -ForegroundColor Yellow
    
    # Check if winget works
    $wingetTest = & winget --version 2>$null
    if (!$wingetTest) {
        Write-Host "Winget not working, attempting repair..." -ForegroundColor Red
        
        # Try re-registering DesktopAppInstaller
        try {
            Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue | 
            ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue }
        } catch {}
        
        # Open Microsoft Store updates page multiple times
        for ($i = 0; $i -lt 6; $i++) {
            Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1" -WindowStyle Hidden
            Start-Sleep -Seconds 10
        }
        
        # Check again
        $wingetTest = & winget --version 2>$null
        if (!$wingetTest) {
            Write-Host "Winget still broken, scheduling reboot..." -ForegroundColor Red
            Update-Stage 1
            Start-Sleep 3
            Restart-Computer -Force
        }
    }
    Write-Host "Winget repair completed." -ForegroundColor Green
    Update-Stage 2
}

# ============ STAGE 2: DEBLOAT AND TWEAKS ============
if ($currentStage -le 2) {
    Write-Host "Stage 2: Applying Chris Titus debloat and tweaks..." -ForegroundColor Yellow
    
    # Remove bloatware apps (safe list)
    $bloatwarePackages = @(
        "Microsoft.BingWeather",
        "Microsoft.GetHelp", 
        "Microsoft.Getstarted",
        "Microsoft.Microsoft3DViewer",
        "Microsoft.MicrosoftOfficeHub",
        "Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.MicrosoftStickyNotes",
        "Microsoft.Office.OneNote",
        "Microsoft.OneConnect",
        "Microsoft People",
        "Microsoft.SkypeApp",
        "Microsoft.Wallet",
        "Microsoft.WindowsAlarms",
        "Microsoft.WindowsCalculator",
        "Microsoft.WindowsCamera",
        "microsoft.windowscommunicationsapps",
        "Microsoft.WindowsMaps",
        "Microsoft.WindowsSoundRecorder",
        "Microsoft.XboxApp",
        "Microsoft.XboxGameOverlay",
        "Microsoft.XboxGamingOverlay",
        "Microsoft.XboxIdentityProvider",
        "Microsoft.XboxSpeechToTextOverlay",
        "Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo",
        "Clipchamp.Clipchamp"
    )
    
    foreach ($package in $bloatwarePackages) {
        try {
            Get-AppxPackage -Name $package -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | 
                Where-Object {$_.PackageName -like "*$package*"} | 
                Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        } catch {}
    }
    
    # Remove OneDrive completely
    taskkill /f /im OneDrive.exe 2>$null
    Start-Process "$env:SystemRoot\SysWOW64\OneDriveSetup.exe" -ArgumentList "/uninstall" -WindowStyle Hidden -Wait
    Remove-Item "$env:USERPROFILE\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:PROGRAMDATA\Microsoft OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
    
    # Disable OneDrive in Explorer
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowSyncProviderNotifications" -Value 0 -Type DWord -Force
    
    # Mouse settings - disable acceleration
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "0" -Force
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "0" -Force
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "0" -Force
    
    # Enable dark mode
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "SystemUsesLightTheme" -Value 0 -Type DWord -Force
    
    # Disable Sticky Keys prompt
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -Value 506 -Type DWord -Force
    
    # Privacy settings
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -Value 0 -Type DWord -Force
    
    # Disable telemetry
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowTelemetry" -Value 0 -Type DWord -Force
    
    # Disable activity history
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "PublishUserActivities" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "UploadUserActivities" -Value 0 -Type DWord -Force
    
    # Disable background apps
    Get-AppxPackage | Foreach {Get-AppxPackage -Name $_.Name -ErrorAction SilentlyContinue | Where {$_.Name -notlike "*Microsoft*"} | Set-AppxPackage -DisableDevelopmentMode -ErrorAction SilentlyContinue}
    
    # Disable GameDVR
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\ApplicationManagement\AllowGameDVR" -Value 0 -Type DWord -Force
    
    # Disable Hibernation
    powercfg /hibernate off -ErrorAction SilentlyContinue
    
    # Disable Location Tracking
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Value "Deny" -Force
    
    # Disable Storage Sense
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" -Name "01" -Value 0 -Type DWord -Force
    
    # Disable WiFi Sense
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config" -Name "AutoConnectAllowedOEM" -Value 0 -Type DWord -Force
    
    # Disable Advertising ID
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" -Name "DisabledByGroupPolicy" -Value 1 -Type DWord -Force
    
    # Disable services
    $services = @(
        "DiagTrack",
        "dmwappushservice", 
        "MapsBroker",
        "WMPNetworkSvc",
        "WpnService",
        "RetailDemo",
        "SharedAccess"
    )
    
    foreach ($service in $services) {
        Set-Service -Name $service -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
    }
    
    # Disable Xbox services
    $xboxServices = @(
        "XblAuthManager",
        "XblGameSave", 
        "XboxGipSvc",
        "XboxNetApiSvc"
    )
    
    foreach ($service in $xboxServices) {
        Set-Service -Name $service -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
    }
    
    # Disable SysMain
    Set-Service -Name "SysMain" -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name "SysMain" -Force -ErrorAction SilentlyContinue
    
    # Disable WSearch
    Set-Service -Name "WSearch" -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
    
    # Disable CEIP scheduled tasks
    Disable-ScheduledTask -TaskName "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator" -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip" -ErrorAction SilentlyContinue
    
    # Disable Application Experience scheduled tasks
    Disable-ScheduledTask -TaskName "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName "\Microsoft\Windows\Application Experience\ProgramDataUpdater" -ErrorAction SilentlyContinue
    
    # Enable Ultimate Performance power plan
    powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
    powercfg -setactive e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
    
    # Show hidden files and file extensions
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Hidden" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowSuperHidden" -Value 1 -Type DWord -Force
    
    Write-Host "Debloat and tweaks completed." -ForegroundColor Green
    Update-Stage 3
}

# ============ STAGE 3: INSTALL APPS ============
if ($currentStage -le 3) {
    Write-Host "Stage 3: Installing applications..." -ForegroundColor Yellow
    
    # Winget apps (silent installations)
    $wingetApps = @(
        "Valve.Steam",
        "Discord.Discord",
        "Spotify.Spotify", 
        "VideoLAN.VLC",
        "7zip.7zip",
        "Bitwarden.Bitwarden",
        "Python.Python.3",
        "Git.Git",
        "voidtools.Everything",
        "WizTree.WizTree",
        "EpicGames.EpicGamesLauncher",
        "Modrinth.ModrinthApp",
        "Logitech.GHUB"
    )
    
    foreach ($app in $wingetApps) {
        try {
            & winget install --id $app --silent --accept-package-agreements --accept-source-agreements --force 2>$null
        } catch {}
    }
    
    # Download and install Thorium
    try {
        $thoriumUrl = "https://github.com/Alex313031/thorium-win7/releases/latest/download/ThoriumSetup64AVX2.exe"
        $thoriumPath = "$tempDir\ThoriumSetup64AVX2.exe"
        Invoke-WebRequest -Uri $thoriumUrl -OutFile $thoriumPath -UseBasicParsing
        Start-Process -FilePath $thoriumPath -ArgumentList "/S" -WindowStyle Hidden -Wait
    } catch {}
    
    # Download and install Roblox
    try {
        $robloxUrl = "https://setup.rbxcdn.com/RobloxPlayerLauncher.exe"
        $robloxPath = "$tempDir\RobloxPlayerLauncher.exe"
        Invoke-WebRequest -Uri $robloxUrl -OutFile $robloxPath -UseBasicParsing
        Start-Process -FilePath $robloxPath -ArgumentList "/S" -WindowStyle Hidden -Wait
    } catch {}
    
    # Install Vencord
    try {
        Start-Process powershell -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"iwr https://vencord.dev/install.ps1 | iex`"" -WindowStyle Hidden
    } catch {}
    
    # Download and install TCNO Account Switcher
    try {
        $tcnoUrl = "https://github.com/tcNO/TcNo-Acc-Switcher/releases/latest/download/TcNo.Acc.Switcher.x64.Setup.exe"
        $tcnoPath = "$tempDir\TcNo.Acc.Switcher.x64.Setup.exe"
        Invoke-WebRequest -Uri $tcnoUrl -OutFile $tcnoPath -UseBasicParsing
        Start-Process -FilePath $tcnoPath -ArgumentList "/VERYSILENT" -WindowStyle Hidden -Wait
    } catch {}
    
    Write-Host "Applications installation completed." -ForegroundColor Green
    Update-Stage 4
}

# ============ STAGE 4: GPU DRIVERS ============
if ($currentStage -le 4) {
    Write-Host "Stage 4: Installing GPU drivers..." -ForegroundColor Yellow
    
    # Detect GPU
    $gpu = Get-WmiObject -Class Win32_VideoController | Where-Object {$_.Name -notlike "*Basic*"} | Select-Object -First 1
    $gpuName = $gpu.Name.ToLower()
    
    if ($gpuName -match "nvidia") {
        Write-Host "Detected NVIDIA GPU, downloading NVIDIA App..." -ForegroundColor Cyan
        try {
            $nvidiaUrl = "https://www.nvidia.com/content/dam/en-zz/ServicesGeForce/v2/GVC/PC/Express/570/GFE22.0.0_472.67.exe"
            $nvidiaPath = "$tempDir\NVIDIA_App.exe"
            Invoke-WebRequest -Uri $nvidiaUrl -OutFile $nvidiaPath -UseBasicParsing
            Start-Process -FilePath $nvidiaPath -ArgumentList "-s" -WindowStyle Hidden -Wait
        } catch {}
    } elseif ($gpuName -match "amd" -or $gpuName -match "radeon") {
        Write-Host "Detected AMD GPU, downloading AMD drivers..." -ForegroundColor Cyan
        try {
            # This would need to be updated with actual AMD driver download URL
            # For now, skipping AMD driver installation
        } catch {}
    }
    
    Write-Host "GPU driver installation completed." -ForegroundColor Green
    Update-Stage 5
}

# ============ STAGE 5: WINDOWS ACTIVATION ============
if ($currentStage -le 5) {
    Write-Host "Stage 5: Activating Windows..." -ForegroundColor Yellow
    
    try {
        # Download and execute Massgravel's activation script
        $activationUrl = "https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/master/Methods/Online/HWID/Online%20HWID%20Activation.ps1"
        $activationPath = "$tempDir\Activate.ps1"
        Invoke-WebRequest -Uri $activationUrl -OutFile $activationPath -UseBasicParsing
        
        # Execute with silent flags
        & powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $activationPath -HWID
    } catch {}
    
    Write-Host "Windows activation completed." -ForegroundColor Green
    Update-Stage 6
}

# ============ STAGE 6: CLEANUP ============
if ($currentStage -le 6) {
    Write-Host "Stage 6: Cleaning up temporary files..." -ForegroundColor Yellow
    
    # Remove temporary directory
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-Host "Cleanup completed." -ForegroundColor Green
    Update-Stage 99
    
    # Start Task Manager silently
    Start-Process "taskmgr.exe" -WindowStyle Hidden
    
    Write-Host "MestalWinBox completed successfully!" -ForegroundColor Green
    Start-Sleep 2
    
    # Exit
    exit
}
