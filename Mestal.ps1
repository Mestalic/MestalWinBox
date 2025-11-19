# Mestal.ps1 - Complete Windows 10/11 Setup and Optimization Script
# Launch with: irm "https://raw.githubusercontent.com/Mestalic/MestalWinBox/main/Mestal.ps1" | iex

# CONFIGURATION SECTION - Easy to modify apps list
$Script:WingetApps = @(
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
    "Logitech.GHUB",
    "NodeJS.NodeJS",
    "VSCodium.VSCodium"
    # Add more winget apps here - just put the exact winget ID in quotes
)

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
$Script:LogFile = "$TempDir\Mestal.log"

# Create temp directory and log
if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}

# Logging function
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $Script:LogFile -Append -ErrorAction SilentlyContinue
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
    Write-Log "Updated to stage $NewStage"
}

function Set-Persistent {
    $runKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    Set-ItemProperty -Path $runKey -Name "MestalWinBox" -Value "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"irm 'https://raw.githubusercontent.com/Mestalic/MestalWinBox/main/Mestal.ps1' | iex`""
    Write-Log "Persistence set"
}

function Remove-Persistence {
    $runKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    Remove-ItemProperty -Path $runKey -Name "MestalWinBox" -ErrorAction SilentlyContinue
    Remove-Item -Path $RegistryPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Persistence removed"
}

# Bulletproof registry function
function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [string]$Type = "DWORD"
    )
    try {
        if (-not (Test-Path $Path)) {
            $parentPath = Split-Path $Path -Parent
            $leaf = Split-Path $Path -Leaf
            if (-not (Test-Path $parentPath)) {
                New-Item -Path $parentPath -Force | Out-Null
            }
            New-Item -Path $parentPath -Name $leaf -Force | Out-Null
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction SilentlyContinue
        Write-Log "Set registry: $Path\$Name = $Value"
    }
    catch {
        Write-Log "Failed to set registry $Path\$Name : $($_.Exception.Message)"
    }
}

# Enhanced winget repair with multiple detection methods
function Repair-Winget {
    try {
        Write-Log "Checking winget..."
        
        # Method 1: Try winget --version
        try {
            $wingetVersion = winget --version 2>$null
            if ($LASTEXITCODE -eq 0 -and $wingetVersion) {
                Write-Log "Winget working: $wingetVersion"
                return $true
            }
        }
        catch {}
        
        # Method 2: Check if winget executable exists
        $wingetPaths = @(
            "${env:LOCALAPPDATA}\Microsoft\WindowsApps\winget.exe",
            "${env:ProgramFiles}\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe"
        )
        
        $wingetFound = $false
        foreach ($path in $wingetPaths) {
            if (Test-Path $path) {
                $wingetFound = $true
                Write-Log "Winget found at: $path"
                break
            }
        }
        
        if (-not $wingetFound) {
            Write-Log "Winget not found, attempting repair..."
        }
        
        # Method 3: Re-register Appx package
        try {
            $appInstaller = Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
            if ($appInstaller) {
                Add-AppxPackage -DisableDevelopmentMode -Register "$($appInstaller.InstallLocation)\AppxManifest.xml" -ErrorAction SilentlyContinue
                Write-Log "Re-registered DesktopAppInstaller"
            }
        }
        catch {
            Write-Log "Failed to re-register DesktopAppInstaller: $($_.Exception.Message)"
        }
        
        # Method 4: Try to install from Microsoft Store
        try {
            Write-Log "Attempting Store installation..."
            for ($i = 1; $i -le 3; $i++) {
                Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1" -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 15
                
                # Check if winget now works
                $wingetVersion = winget --version 2>$null
                if ($LASTEXITCODE -eq 0 -and $wingetVersion) {
                    Write-Log "Winget now working after Store attempt: $wingetVersion"
                    return $true
                }
                
                Stop-Process -Name "WinStore.App" -ErrorAction SilentlyContinue
                Stop-Process -Name "WindowsStore" -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
            }
        }
        catch {
            Write-Log "Store installation attempt failed: $($_.Exception.Message)"
        }
        
        # Final check
        $wingetVersion = winget --version 2>$null
        $working = ($LASTEXITCODE -eq 0 -and $wingetVersion)
        Write-Log "Final winget check result: $working"
        return $working
    }
    catch {
        Write-Log "Winget repair exception: $($_.Exception.Message)"
        return $false
    }
}

# Chris Titus WinUtil debloat functions - bulletproof version
function Remove-BloatPackages {
    Write-Log "Starting bloat package removal..."
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
            Write-Log "Removed package: $pkg"
        }
        catch {
            Write-Log "Failed to remove package $pkg : $($_.Exception.Message)"
        }
    }
    Write-Log "Bloat package removal completed"
}

function Remove-OneDrive {
    Write-Log "Starting OneDrive removal..."
    try {
        Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        
        $oneDriveSetup = "${env:SystemRoot}\System32\OneDriveSetup.exe"
        if (Test-Path $oneDriveSetup) {
            Start-Process $oneDriveSetup -ArgumentList "/uninstall" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
            Write-Log "Ran OneDrive uninstall from System32"
        }
        
        $oneDriveSetupSysWOW64 = "${env:SystemRoot}\SysWOW64\OneDriveSetup.exe"
        if (Test-Path $oneDriveSetupSysWOW64) {
            Start-Process $oneDriveSetupSysWOW64 -ArgumentList "/uninstall" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
            Write-Log "Ran OneDrive uninstall from SysWOW64"
        }
        
        Remove-Item -Path "$env:UserProfile\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "${env:LocalAppData}\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "${env:ProgramData}\Microsoft OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "OneDrive removal completed"
    }
    catch {
        Write-Log "OneDrive removal error: $($_.Exception.Message)"
    }
}

function Set-EssentialTweaks {
    Write-Log "Applying essential tweaks..."
    
    # Disable mouse acceleration
    Set-RegistryValue -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "0" -Type "String"
    Set-RegistryValue -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "0" -Type "String"
    Set-RegistryValue -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "0" -Type "String"
    
    # Enable dark mode
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -Value 0
    
    # Disable sticky keys
    Set-RegistryValue -Path "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -Value "506" -Type "String"
    
    # Disable Bing in start menu
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -Value 0
    
    # Disable telemetry
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowTelemetry" -Value 0
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 0
    
    # Disable activity history
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "PublishUserActivities" -Value 0
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "UploadUserActivities" -Value 0
    
    # Disable background apps
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsRunInBackground" -Value 2
    
    # Disable GameDVR
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0
    
    # Disable hibernation
    try { 
        powercfg /hibernate off 
        Write-Log "Disabled hibernation"
    } catch {
        Write-Log "Failed to disable hibernation: $($_.Exception.Message)"
    }
    
    # Disable location tracking
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Value "Deny" -Type "String"
    
    # Disable Storage Sense
    Remove-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" -Recurse -Force -ErrorAction SilentlyContinue
    
    # Disable WiFi Sense
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting" -Name "Value" -Value 0
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots" -Name "Value" -Value 0
    
    # Disable advertising ID
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Value 0
    
    # Show hidden files and extensions
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Hidden" -Value 1
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowSuperHidden" -Value 1
    
    Write-Log "Essential tweaks applied"
}

function Disable-ScheduledTasks {
    Write-Log "Disabling scheduled tasks..."
    $tasks = @(
        "MicrosoftCompatibilityAppraiser", "ProgramDataUpdater", "Consolidator",
        "KernelCeipTask", "UsbCeip", "DmClient", "DmClientOnScenarioDownload"
    )
    foreach ($task in $tasks) {
        try {
            Disable-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
            Write-Log "Disabled task: $task"
        }
        catch {
            Write-Log "Failed to disable task $task : $($_.Exception.Message)"
        }
    }
    Write-Log "Scheduled tasks disabled"
}

function Disable-Services {
    Write-Log "Disabling services..."
    $services = @(
        "DiagTrack", "SysMain", "WSearch", "XblAuthManager", "XblGameSave",
        "XboxNetApiSvc", "XboxGipSvc", "MapsBroker", "WpnService", "RetailDemo"
    )
    foreach ($service in $services) {
        try {
            Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
            Set-Service -Name $service -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Log "Disabled service: $service"
        }
        catch {
            Write-Log "Failed to disable service $service : $($_.Exception.Message)"
        }
    }
    Write-Log "Services disabled"
}

# App installation functions
function Install-WingetApps {
    Write-Log "Starting winget app installation..."
    Write-Log "Apps to install: $($Script:WingetApps -join ', ')"
    
    foreach ($app in $Script:WingetApps) {
        try {
            Write-Log "Installing $app..."
            $result = winget install --id $app --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
            Write-Log "Winget install result for $app : $result"
            Start-Sleep -Seconds 5
        }
        catch {
            Write-Log "Failed to install $app : $($_.Exception.Message)"
        }
    }
    Write-Log "Winget app installation completed"
}

function Install-ManualApps {
    Write-Log "Starting manual app installation..."
    try {
        # Thorium AVX2 mini installer
        Write-Log "Installing Thorium..."
        $thoriumUrl = "https://github.com/Alex313031/Thorium-Win/releases/latest/download/Thorium_AVX2_MiniInstaller.exe"
        $thoriumPath = "$TempDir\Thorium.exe"
        Invoke-WebRequest -Uri $thoriumUrl -OutFile $thoriumPath -UseBasicParsing
        Start-Process $thoriumPath -ArgumentList "/S" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
        Write-Log "Thorium installation completed"
        
        # Roblox
        Write-Log "Installing Roblox..."
        $robloxUrl = "https://setup.rbxcdn.com/RobloxPlayerLauncher.exe"
        $robloxPath = "$TempDir\Roblox.exe"
        Invoke-WebRequest -Uri $robloxUrl -OutFile $robloxPath -UseBasicParsing
        Start-Process $robloxPath -ArgumentList "/S" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
        Write-Log "Roblox installation completed"
        
        # Vencord
        Write-Log "Installing Vencord..."
        Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -Command `"iwr https://vencord.dev/install.ps1 | iex`"" -Wait -ErrorAction SilentlyContinue
        Write-Log "Vencord installation completed"
        
        # TCNO Account Switcher
        Write-Log "Installing TCNO Account Switcher..."
        $tcnoUrl = "https://github.com/TCNOco/TcNo-Acc-Switcher/releases/latest/download/TcNo.Account.Switcher.exe"
        $tcnoPath = "$TempDir\TcNo.exe"
        Invoke-WebRequest -Uri $tcnoUrl -OutFile $tcnoPath -UseBasicParsing
        Start-Process $tcnoPath -ArgumentList "/VERYSILENT" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
        Write-Log "TCNO Account Switcher installation completed"
        
    }
    catch {
        Write-Log "Manual app installation error: $($_.Exception.Message)"
    }
    Write-Log "Manual app installation completed"
}

# GPU driver installation
function Install-GPUDrivers {
    Write-Log "Starting GPU driver installation..."
    try {
        $gpu = Get-WmiObject -Class Win32_VideoController | Where-Object { $_.Name -notlike "*Basic*" } | Select-Object -First 1
        Write-Log "Detected GPU: $($gpu.Name)"
        
        if ($gpu.Name -like "*NVIDIA*") {
            Write-Log "Installing NVIDIA drivers..."
            $nvidiaUrl = "https://us.download.nvidia.com/GFE/GFEClient/NVIDIA_Experience.exe"
            $nvidiaPath = "$TempDir\NVIDIA.exe"
            Invoke-WebRequest -Uri $nvidiaUrl -OutFile $nvidiaPath -UseBasicParsing
            Start-Process $nvidiaPath -ArgumentList "-s" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
            Write-Log "NVIDIA drivers installation completed"
        }
        elseif ($gpu.Name -like "*AMD*" -or $gpu.Name -like "*Radeon*") {
            Write-Log "Installing AMD drivers..."
            $amdUrl = "https://drivers.amd.com/drivers/installer/22.40/beta/amd-software-adrenalin-edition-22.40.03.01-minimalsetup.exe"
            $amdPath = "$TempDir\AMD.exe"
            Invoke-WebRequest -Uri $amdUrl -OutFile $amdPath -UseBasicParsing
            Start-Process $amdPath -ArgumentList "/S" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
            Write-Log "AMD drivers installation completed"
        }
        else {
            Write-Log "No supported GPU detected for driver installation"
        }
    }
    catch {
        Write-Log "GPU driver installation error: $($_.Exception.Message)"
    }
    Write-Log "GPU driver installation completed"
}

# Windows activation using Massgravel MAS
function Activate-Windows {
    Write-Log "Starting Windows activation..."
    try {
        # Download and run MAS HWID activation silently
        $masCommand = @"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
`$ProgressPreference = 'SilentlyContinue'
try {
    `$response = Invoke-WebRequest -Uri 'https://massgrave.dev/get' -UseBasicParsing
    if (`$response) {
        `$script = `$response.Content
        Invoke-Expression `$script
        HWID
    }
} catch {
    Write-Host 'MAS activation failed: ' + `$_.Exception.Message
}
"@
        
        $masPath = "$TempDir\MAS.ps1"
        $masCommand | Out-File -FilePath $masPath -Encoding UTF8
        
        Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -File `"$masPath`"" -Wait -ErrorAction SilentlyContinue
        Write-Log "Windows activation completed"
    }
    catch {
        Write-Log "Windows activation error: $($_.Exception.Message)"
    }
}

# Main execution flow with error handling
Write-Log "=== MESTAL SCRIPT STARTED ==="

try {
    Initialize-Persistence
    Set-Persistent
    
    Write-Log "Current stage: $Script:Stage"
    
    switch ($Script:Stage) {
        0 {
            # Stage 0: Winget repair
            Write-Log "Entering stage 0 - Winget repair"
            Update-Stage 1
            if (-not (Repair-Winget)) {
                Write-Log "Winget repair failed, restarting..."
                Restart-Computer -Force
                exit
            }
            Write-Log "Winget repair successful, continuing..."
            # Fall through to next stage
        }
        
        1 {
            # Stage 1: Debloat and tweaks
            Write-Log "Entering stage 1 - Debloat and tweaks"
            Update-Stage 2
            Remove-BloatPackages
            Remove-OneDrive
            Set-EssentialTweaks
            Disable-ScheduledTasks
            Disable-Services
            Write-Log "Stage 1 completed"
        }
        
        2 {
            # Stage 2: App installation
            Write-Log "Entering stage 2 - App installation"
            Update-Stage 3
            Install-WingetApps
            Install-ManualApps
            Write-Log "Stage 2 completed"
        }
        
        3 {
            # Stage 3: GPU drivers
            Write-Log "Entering stage 3 - GPU drivers"
            Update-Stage 4
            Install-GPUDrivers
            Write-Log "Stage 3 completed"
        }
        
        4 {
            # Stage 4: Windows activation
            Write-Log "Entering stage 4 - Windows activation"
            Update-Stage 5
            Activate-Windows
            Write-Log "Stage 4 completed"
        }
    }
    
    # Cleanup and finish
    if ($Script:Stage -ge 5) {
        Write-Log "Script completed successfully, cleaning up..."
        Remove-Persistence
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        Start-Process taskmgr.exe
        Write-Log "=== MESTAL SCRIPT COMPLETED ==="
        exit
    }
}
catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)"
    Write-Log "Stack trace: $($_.ScriptStackTrace)"
}

Write-Log "Script execution completed for this run"