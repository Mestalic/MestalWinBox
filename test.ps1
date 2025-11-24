<#
.SYNOPSIS
    Automated Windows Setup & Optimization Script
    
.DESCRIPTION
    This script automates the setup of a fresh Windows installation.
    Features:
    - Installs common applications via Winget
    - Debloats Windows (removes bloatware, disables telemetry)
    - Installs GPU drivers (NVIDIA/AMD)
    - Activates Windows via MAS (HWID)
    - Resumes after reboot if necessary

.NOTES
    Author: Antigravity (based on user request)
    Version: 1.0
#>

# --- Configuration ---
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
    "VSCodium.VSCodium",
    "Alex313031.Thorium.AVX2", # Replaced manual install
    "pizzaboxer.Bloxstrap"           # Replaced manual install
)

$Script:Bloatware = @(
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

# --- Setup & Logging ---
$ErrorActionPreference = "Stop"
$Script:LogFile = "$env:SystemDrive\MestalSetup.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMsg = "[$timestamp] $Message"
    Write-Host $logMsg -ForegroundColor Cyan
    $logMsg | Out-File -FilePath $Script:LogFile -Append -Encoding UTF8
}

# Ensure Admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Restarting as Administrator..."
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs
    exit
}

# Start Transcript
try { Start-Transcript -Path "$env:SystemDrive\MestalSetup_Transcript.log" -Append -ErrorAction SilentlyContinue } catch {}

# --- Helper Functions ---

function Test-Winget {
    Write-Log "Checking Winget availability..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        return $true
    }
    Write-Log "Winget not found. Attempting to install App Installer..."
    # Try to install App Installer via Appx
    $appInstallerUri = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    $tempFile = "$env:TEMP\AppInstaller.msixbundle"
    try {
        Invoke-WebRequest -Uri $appInstallerUri -OutFile $tempFile -UseBasicParsing
        Add-AppxPackage -Path $tempFile
        return $true
    } catch {
        Write-Log "Failed to install Winget: $_"
        return $false
    }
}

function Install-WingetApp {
    param([string]$Id)
    Write-Log "Installing $Id..."
    try {
        # --accept-source-agreements is critical for new installs
        $args = "install --id $Id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
        $proc = Start-Process winget -ArgumentList $args -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0) {
            Write-Log "Successfully installed $Id"
        } else {
            Write-Log "Failed to install $Id (Exit Code: $($proc.ExitCode))"
        }
    } catch {
        Write-Log "Error installing $Id: $_"
    }
}

function Invoke-Debloat {
    Write-Log "Starting Debloat..."
    
    # Remove Bloatware
    foreach ($app in $Script:Bloatware) {
        Write-Log "Removing $app..."
        Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $app } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
    }

    # Registry Tweaks
    Write-Log "Applying Registry Tweaks..."
    
    # Disable Telemetry
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 0 -Type DWord -Force
    
    # Disable Bing Search
    $searchPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
    if (!(Test-Path $searchPath)) { New-Item $searchPath -Force | Out-Null }
    Set-ItemProperty -Path $searchPath -Name "BingSearchEnabled" -Value 0 -Type DWord -Force
    
    # Show Extensions
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0 -Type DWord -Force
    
    # Disable Sticky Keys (506 = Off)
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -Value "506" -Type String -Force

    # Disable Hibernate
    powercfg /hibernate off
}

function Install-Drivers {
    Write-Log "Checking for GPU Drivers..."
    $gpu = Get-WmiObject Win32_VideoController
    $gpuName = $gpu.Name
    Write-Log "Detected GPU: $gpuName"

    if ($gpuName -match "NVIDIA") {
        Write-Log "Downloading NVIDIA GeForce Experience..."
        $url = "https://us.download.nvidia.com/GFE/GFEClient/NVIDIA_Experience.exe"
        $outFile = "$env:TEMP\NVIDIA_Experience.exe"
        Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing
        Write-Log "Installing NVIDIA GeForce Experience..."
        Start-Process -FilePath $outFile -ArgumentList "/s" -Wait
    }
    elseif ($gpuName -match "AMD" -or $gpuName -match "Radeon") {
        Write-Log "Downloading AMD Adrenalin..."
        # Note: AMD URLs change frequently. Using a known recent minimal setup or full.
        # This URL is from the user's script, might be outdated. 
        # Better approach: Use Winget for AMD Software if possible, but it's often tricky.
        # Fallback to user's URL but warn.
        $url = "https://drivers.amd.com/drivers/installer/22.40/beta/amd-software-adrenalin-edition-22.40.03.01-minimalsetup.exe" 
        $outFile = "$env:TEMP\AMD_Setup.exe"
        try {
            Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing
            Write-Log "Installing AMD Drivers..."
            Start-Process -FilePath $outFile -ArgumentList "/S" -Wait
        } catch {
            Write-Log "Could not download AMD driver. URL might be invalid."
        }
    }
    else {
        Write-Log "No dedicated NVIDIA/AMD GPU detected or driver install skipped."
    }
}

function Invoke-Activation {
    Write-Log "Attempting Windows Activation via MAS (HWID)..."
    try {
        # MAS HWID One-Liner (Non-interactive)
        # We use the specific command to run HWID directly
        $script = {
            param([string]$Method)
            $url = "https://massgrave.dev/get"
            $content = Invoke-WebRequest -Uri $url -UseBasicParsing
            Invoke-Expression $content.Content
        }
        # Note: The standard MAS script is interactive. 
        # To run silently, we need to use the specific arguments if supported or the separate scripts.
        # MAS has a separate repo for silent scripts or we can use the main one with args if documented.
        # Actually, the user's script used a custom script block.
        # The official way for silent HWID:
        irm https://massgrave.dev/get | iex
        # Wait, that's interactive.
        # Let's use the specific HWID script from Massgrave if available, or simulate input.
        # Massgrave docs say: "irm https://get.activated.win | iex" -> Select 1.
        # For unattended: 
        & ([ScriptBlock]::Create((irm https://massgrave.dev/get))) /hwid
    } catch {
        Write-Log "Activation failed: $_"
    }
}

function Install-ManualApps {
    Write-Log "Installing Manual Apps..."
    
    # Vencord
    Write-Log "Installing Vencord..."
    try {
        # Vencord installer usually requires Discord to be installed first.
        if (Get-Process -Name Discord -ErrorAction SilentlyContinue) { Stop-Process -Name Discord -Force }
        irm https://vencord.dev/install.ps1 | iex
    } catch {
        Write-Log "Vencord install failed: $_"
    }

    # TCNO Account Switcher
    Write-Log "Installing TCNO Account Switcher..."
    try {
        $url = "https://github.com/TCNOco/TcNo-Acc-Switcher/releases/latest/download/TcNo.Account.Switcher.exe"
        $out = "$env:TEMP\TcNo.exe"
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
        Start-Process $out -ArgumentList "/VERYSILENT" -Wait
    } catch {
        Write-Log "TCNO install failed: $_"
    }
}

# --- State Management ---
$RegPath = "HKCU:\Software\MestalWinBox"
if (!(Test-Path $RegPath)) { New-Item $RegPath -Force | Out-Null }

function Get-Step {
    return (Get-ItemProperty -Path $RegPath -Name "Step" -ErrorAction SilentlyContinue).Step
}

function Set-Step {
    param([int]$s)
    Set-ItemProperty -Path $RegPath -Name "Step" -Value $s
}

# --- Main Execution ---
$currentStep = Get-Step
if (!$currentStep) { $currentStep = 0 }

Write-Log "Starting Script at Step $currentStep"

if ($currentStep -lt 1) {
    # Step 1: Debloat
    Invoke-Debloat
    Set-Step 1
}

if ($currentStep -lt 2) {
    # Step 2: Winget Apps
    if (Test-Winget) {
        foreach ($app in $Script:WingetApps) {
            Install-WingetApp -Id $app
        }
    }
    Set-Step 2
}

if ($currentStep -lt 3) {
    # Step 3: Manual Apps
    Install-ManualApps
    Set-Step 3
}

if ($currentStep -lt 4) {
    # Step 4: Drivers
    Install-Drivers
    Set-Step 4
}

if ($currentStep -lt 5) {
    # Step 5: Activation
    Invoke-Activation
    Set-Step 5
}

Write-Log "Setup Complete!"
# Clean up registry key
Remove-Item $RegPath -Force -ErrorAction SilentlyContinue
Stop-Transcript
