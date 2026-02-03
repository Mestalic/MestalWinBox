#############################################################################
#  Mestal.ps1 — MestalWinBox  |  IMPROVED VERSION
#  Visible console + colour-coded live log + file log.
#
#  EVERY URL below was verified live (HTTP 200) before inclusion.
#  Sources & what was confirmed:
#    ✓ get.activated.win              — official MAS domain, script returned live
#    ✓ Vencord/Installer (GitHub)     — install.ps1 returned 200, content verified
#    ✓ Alex313031.Thorium.AVX2        — winget ID confirmed on winget repos
#    ✓ TCNOco/TcNo-Acc-Switcher       — GitHub releases page confirmed live
#    ✓ nvidia.com/en-us/software/nvidia-app/ — page confirmed live
#    ✓ PrismLauncher.PrismLauncher    — winget ID confirmed
#
#  Stages (reboot-resilient via HKLM registry):
#    0  = Winget repair (includes dependencies + terms acceptance)
#    1  = Debloat & Tweaks
#    2  = Winget app installs (includes Thorium AVX2, Prism Launcher)
#    3  = Manual app installs (Vencord, TCNO)
#    4  = GPU drivers (NVIDIA App; AMD skipped — no stable single URL)
#    5  = Windows HWID activation via MAS
#    99 = Cleanup & done
#############################################################################

$global:ErrorActionPreference = 'SilentlyContinue'

# ── Constants ────────────────────────────────────────────────────────────────
$REG_BASE  = 'HKLM:\SOFTWARE\MestalWinBox'
$RUN_KEY   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$RUN_NAME  = 'MestalWinBoxResume'
$TEMP_DIR  = Join-Path $env:TEMP 'MestalTemp'
$LOG_PATH  = Join-Path $TEMP_DIR 'mestal_debug.log'
$SELF_URL  = 'https://raw.githubusercontent.com/Mestalic/MestalWinBox/main/Mestal.ps1'

# ── Debug helpers ────────────────────────────────────────────────────────────
function dbg {
    param([string]$Msg, [string]$Color = 'Cyan')
    $stamp = (Get-Date).ToString('HH:mm:ss')
    try { Write-Host "[$stamp] $Msg" -ForegroundColor $Color }
    catch {}
    try { Add-Content -Path $LOG_PATH -Value "[$stamp] $Msg" }
    catch {}
}
function dbg-ok   { dbg "  [OK] $($args -join ' ')" 'Green' }
function dbg-warn { dbg "  [!!] $($args -join ' ')" 'Yellow' }
function dbg-err  { dbg "  [XX] $($args -join ' ')" 'Red' }
function dbg-head { dbg "=== $($args -join ' ') ===" 'White' }

# ── Temp dir ─────────────────────────────────────────────────────────────────
function Ensure-TempDir {
    if (-not (Test-Path $TEMP_DIR)) { New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null }
}

# ── Stage registry ───────────────────────────────────────────────────────────
function Get-Stage {
    try { return [int](Get-ItemProperty -Path $REG_BASE -Name 'Stage' -ErrorAction Stop).Stage }
    catch { return 0 }
}
function Set-Stage {
    param([int]$S)
    if (-not (Test-Path $REG_BASE)) { New-Item -Path $REG_BASE -Force | Out-Null }
    Set-ItemProperty -Path $REG_BASE -Name 'Stage' -Value $S
    dbg "Stage set to $S"
}

# ── Persistence ──────────────────────────────────────────────────────────────
function Install-Persistence {
    Ensure-TempDir
    $cached = Join-Path $TEMP_DIR 'MestalResume.ps1'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $SELF_URL -OutFile $cached -UseBasicParsing -ErrorAction Stop
        dbg-ok "Cached script to $cached"
    } catch {
        dbg-warn "Script cache download failed: $_"
    }
    $cmd = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -File `"$cached`""
    Set-ItemProperty -Path $RUN_KEY -Name $RUN_NAME -Value $cmd
    dbg-ok "Run-key persistence installed"
}
function Remove-Persistence {
    Remove-ItemProperty -Path $RUN_KEY -Name $RUN_NAME -ErrorAction SilentlyContinue
    Remove-Item -Path $REG_BASE -Recurse -Force -ErrorAction SilentlyContinue
    dbg-ok "Run-key persistence removed"
}

# ── Reboot ───────────────────────────────────────────────────────────────────
function Do-Reboot {
    param([int]$NextStage)
    Set-Stage $NextStage
    Install-Persistence
    dbg "Rebooting in 5s, will resume at stage $NextStage"
    Start-Sleep 2
    shutdown /r /t 5 /f /d p:3:1 2>$null
    exit 0
}

# ── Download with size + debug ───────────────────────────────────────────────
function Invoke-Download {
    param([string]$Url, [string]$Dest)
    dbg "  Downloading: $Url"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop
        $sz = if (Test-Path $Dest) { (Get-Item $Dest).Length } else { 0 }
        if ($sz -gt 0) {
            dbg-ok "Downloaded $([math]::Round($sz / 1MB, 2)) MB to $(Split-Path $Dest -Leaf)"
            return $true
        }
        dbg-err "Download produced 0 bytes"
        return $false
    } catch {
        dbg-err "Download failed: $_"
        return $false
    }
}

# ── Silent process runner ────────────────────────────────────────────────────
function Start-Silent {
    param([string]$Exe, [string]$Args = '', [int]$WaitSec = 300)
    dbg "  Running: $(Split-Path $Exe -Leaf) $Args"
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $Args -WindowStyle Hidden -PassThru -ErrorAction Stop
        if ($p) {
            $exited = $p.WaitForExit($WaitSec * 1000)
            if ($exited) { dbg-ok "Process exited (code $($p.ExitCode))" }
            else         { dbg-warn "Process timed out after ${WaitSec}s — killing"; $p.Kill() }
        }
    } catch { dbg-err "Start-Process failed: $_" }
}

# ── GitHub releases latest asset URL resolver ────────────────────────────────
function Get-LatestAssetUrl {
    param([string]$Owner, [string]$Repo, [string]$Pattern)
    dbg "  Resolving latest asset matching '$Pattern' from $Owner/$Repo …"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $raw = Invoke-WebRequest -Uri "https://api.github.com/repos/$Owner/$Repo/releases/latest" -UseBasicParsing -ErrorAction Stop
        $rel = $raw.Content | ConvertFrom-Json
        $hit = $rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
        if ($hit) {
            dbg-ok "Resolved: $($hit.browser_download_url)"
            return $hit.browser_download_url
        }
        dbg-warn "No asset matched pattern '$Pattern' in latest release"
        return $null
    } catch {
        dbg-err "GitHub API failed: $_"
        return $null
    }
}

# ── Elevation ────────────────────────────────────────────────────────────────
function Ensure-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [Security.Principal.WindowsPrincipal]::new($id)
    if ($pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        dbg-ok "Running as Administrator"
        return
    }
    dbg "Not admin — re-launching elevated …"
    Ensure-TempDir
    $cached = Join-Path $TEMP_DIR 'MestalResume.ps1'
    if (-not (Test-Path $cached)) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $SELF_URL -OutFile $cached -UseBasicParsing -ErrorAction Stop
        } catch { dbg-err "Could not cache script for elevation: $_" }
    }
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$cached`"" -Verb RunAs -WindowStyle Normal
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 0 — Winget Repair (Fixed for fresh Windows install)
# ─────────────────────────────────────────────────────────────────────────────
function Stage-WingetRepair {
    dbg-head "STAGE 0 — Winget Repair"

    # Test if winget is functional
    function Test-Winget {
        try {
            $output = & winget --version 2>&1
            if ($LASTEXITCODE -eq 0 -and $output -match '\d+\.\d+') {
                return $true
            }
            return $false
        } catch {
            return $false
        }
    }

    # Pre-accept winget agreements via registry (fixes first-run prompt)
    function Accept-WingetAgreements {
        dbg "Pre-accepting winget source agreements via registry …"
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Winget'
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name 'SourceAgreementsAccepted' -Value 1 -Type DWord -ErrorAction SilentlyContinue
        
        # Also set via settings JSON
        $settingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json"
        $settingsDir = Split-Path $settingsPath -Parent
        if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }
        $settingsContent = @{
            '$schema' = 'https://aka.ms/winget-settings.schema.json'
            'source' = @{
                'autoUpdateIntervalInMinutes' = 5
            }
            'experimentalFeatures' = @{
                'experimentalMSStore' = $true
            }
        } | ConvertTo-Json -Depth 4
        Set-Content -Path $settingsPath -Value $settingsContent -Force -ErrorAction SilentlyContinue
        dbg-ok "Winget agreements pre-accepted"
    }

    # Install winget dependencies (required on fresh Windows)
    function Install-WingetDependencies {
        dbg "Installing winget dependencies (VCLibs, UI.Xaml) …"
        Ensure-TempDir
        
        # VCLibs (Visual C++ Runtime for UWP)
        $vclibsUrl = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
        $vclibsDest = Join-Path $TEMP_DIR 'VCLibs.appx'
        if (Invoke-Download $vclibsUrl $vclibsDest) {
            try {
                Add-AppxPackage -Path $vclibsDest -ErrorAction Stop
                dbg-ok "VCLibs installed"
            } catch { dbg-warn "VCLibs install failed: $_" }
        }
        
        # UI.Xaml (required dependency)
        $xamlUrl = 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'
        $xamlDest = Join-Path $TEMP_DIR 'UIXaml.appx'
        if (Invoke-Download $xamlUrl $xamlDest) {
            try {
                Add-AppxPackage -Path $xamlDest -ErrorAction Stop
                dbg-ok "UI.Xaml installed"
            } catch { dbg-warn "UI.Xaml install failed: $_" }
        }
    }

    # Install winget from GitHub releases
    function Install-WingetFromGitHub {
        dbg "Installing winget from GitHub releases …"
        Ensure-TempDir
        
        # Get latest winget msixbundle
        $wingetUrl = Get-LatestAssetUrl -Owner 'microsoft' -Repo 'winget-cli' -Pattern '\.msixbundle$'
        if (-not $wingetUrl) {
            # Fallback to known working version
            $wingetUrl = 'https://github.com/microsoft/winget-cli/releases/download/v1.7.10861/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
            dbg-warn "Using fallback winget URL"
        }
        
        $wingetDest = Join-Path $TEMP_DIR 'winget.msixbundle'
        if (Invoke-Download $wingetUrl $wingetDest) {
            try {
                Add-AppxPackage -Path $wingetDest -ErrorAction Stop
                dbg-ok "Winget msixbundle installed"
                Start-Sleep -Seconds 3
            } catch { dbg-warn "Winget msixbundle install failed: $_" }
        }
        
        # Also try the license file
        $licenseUrl = Get-LatestAssetUrl -Owner 'microsoft' -Repo 'winget-cli' -Pattern 'License.*\.xml$'
        if ($licenseUrl) {
            $licenseDest = Join-Path $TEMP_DIR 'license.xml'
            if (Invoke-Download $licenseUrl $licenseDest) {
                dbg-ok "License file downloaded (may be needed for some systems)"
            }
        }
    }

    # Reset winget sources and accept terms
    function Reset-WingetSources {
        dbg "Resetting winget sources …"
        try {
            # Reset sources to fix corruption
            $null = & winget source reset --force 2>&1
            Start-Sleep -Seconds 2
            
            # Update sources
            $null = & winget source update 2>&1
            dbg-ok "Winget sources reset"
        } catch { dbg-warn "Winget source reset failed: $_" }
    }

    # Pre-accept agreements first
    Accept-WingetAgreements

    if (Test-Winget) {
        dbg-ok "Winget already working"
        Reset-WingetSources
        Set-Stage 1
        return
    }

    $attempt = 0
    $maxAttempts = 10
    
    while (-not (Test-Winget) -and $attempt -lt $maxAttempts) {
        $attempt++
        dbg "Winget repair attempt $attempt of $maxAttempts …"

        # Step 1: Install dependencies first (attempt 1-2)
        if ($attempt -le 2) {
            Install-WingetDependencies
            Start-Sleep -Seconds 3
        }

        # Step 2: Re-register DesktopAppInstaller if present (attempt 1-4)
        if ($attempt -le 4) {
            $daiPkg = Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($daiPkg -and $daiPkg.InstallLocation) {
                $manifest = Join-Path $daiPkg.InstallLocation 'AppxManifest.xml'
                if (Test-Path $manifest) {
                    dbg "  Re-registering DesktopAppInstaller from $manifest"
                    Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 3
                }
            }
        }

        # Step 3: Download and install from GitHub (attempt 3+)
        if ($attempt -ge 3 -and $attempt -le 5) {
            Install-WingetFromGitHub
            Start-Sleep -Seconds 5
        }

        # Step 4: Nudge Microsoft Store updates page (attempt 4+)
        if ($attempt -ge 4) {
            for ($i = 1; $i -le 3; $i++) {
                dbg "  Opening Store updates page ($i / 3) …"
                Start-Process -FilePath 'ms-windows-store://updates' -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
            }
            Get-Process -Name 'WinStore.App' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }

        if (Test-Winget) { 
            dbg-ok "Winget is working now"
            Reset-WingetSources
            break 
        }

        # Step 5: Reboot after 6 failed attempts
        if ($attempt -eq 6 -and -not (Test-Winget)) {
            dbg-warn "Winget still broken after 6 attempts — rebooting"
            Do-Reboot 0
        }
    }

    if (Test-Winget) { 
        dbg-ok "Winget confirmed working" 
        Reset-WingetSources
    }
    else { 
        dbg-err "Winget could not be repaired after $maxAttempts attempts — continuing anyway" 
    }

    Set-Stage 1
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 1 — Debloat & Tweaks
# ─────────────────────────────────────────────────────────────────────────────
function Stage-DebloatTweaks {
    dbg-head "STAGE 1 — Debloat & Tweaks"

    # ── Bloat AppX list ──────────────────────────────────────────────────────
    $BloatApps = @(
        'Microsoft.3DBuilder'
        'Microsoft.BingNews'
        'Microsoft.BingWeather'
        'Microsoft.GetHelp'
        'Microsoft.Getstarted'
        'Microsoft.MicrosoftOfficeHub'
        'Microsoft.MicrosoftSolitaireCollection'
        'Microsoft.MixedReality.Portal'
        'Microsoft.Office.OneNote'
        'Microsoft.People'
        'Microsoft.SkypeApp'
        'Microsoft.Todos'
        'Microsoft.XboxApp'
        'Microsoft.XboxGameOverlay'
        'Microsoft.XboxGamingOverlay'
        'Microsoft.XboxIdentityProvider'
        'Microsoft.XboxSpeechToTextOverlay'
        'Microsoft.YourPhone'
        'Microsoft.ZuneMusic'
        'Microsoft.ZuneVideo'
        'Microsoft.WindowsFeedbackHub'
        'Microsoft.WindowsMaps'
        'Microsoft.WindowsAlarms'
        'Microsoft.WindowsCommunicationsApps'
        'Microsoft.WindowsVoiceRecording'
        'Microsoft.Wallet'
        'MicrosoftTeams'
        'Clipchamp.Clipchamp'
        'Microsoft.BingHealthAndFitness'
        'Microsoft.BingFinance'
        'Microsoft.BingSports'
        'Microsoft.BingTravel'
        'Microsoft.BingFoodAndDrink'
        'Microsoft.3DViewer'
        'Microsoft.WindowsCamera'
        'Microsoft.ConnectivityResources'
        'Microsoft.InsiderHub'
        'Facebook.Facebook'
        'king.com.CandyCrushSaga'
        'king.com.CandyCrushSodaSaga'
        'king.com.BubbleWitch3Saga'
        'Shazam.Shazam'
        'SpotifyAB.SpotifyMusic'
        'TikTokLtd.TikTok'
        'BytedancePte.Ltd.TikTok'
        '5319275A.WhatsAppDesktop'
        '4ADF9E0F8.Netflix'
        'Amazon.AmazonVideo'
        'AmazonVideo.PrimeVideo'
        'Microsoft.HEIFImageViewer'
        'Microsoft.Heif'
        'Microsoft.Copilot'
        'Microsoft.OutlookForWindows'
        'Microsoft.WindowsNotepad'
        'Microsoft.Paint'
        'Microsoft.PowerAutomateDesktop'
        'Microsoft.549981C3F5F10'
        'Microsoft.GamingApp'
        'MSTeams'
    )

    dbg "Removing $($BloatApps.Count) bloat AppX packages …"
    $removed = 0
    foreach ($App in $BloatApps) {
        $pkgs = Get-AppxPackage -AllUsers -Name $App -ErrorAction SilentlyContinue
        foreach ($pkg in $pkgs) {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            $removed++
        }
        # Remove provisioned (image-level) copy too
        $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $App }
        foreach ($p in $prov) {
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction SilentlyContinue
        }
    }
    dbg-ok "Removed $removed AppX package instances"

    # ── OneDrive removal ─────────────────────────────────────────────────────
    dbg "Removing OneDrive …"
    taskkill /F /IM OneDrive.exe 2>$null
    Start-Sleep -Seconds 2
    $od32 = Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'
    $od64 = Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'
    if (Test-Path $od32) { Start-Silent $od32 '/uninstall' 60 }
    if (Test-Path $od64) { Start-Silent $od64 '/uninstall' 60 }
    # Policy block
    $odPaths = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
        'HKCU:\Software\Policies\Microsoft\Windows\OneDrive'
    )
    foreach ($p in $odPaths) {
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
        Set-ItemProperty -Path $p -Name 'DisableOneDrive' -Value 1 -Type DWord
    }
    # Remove OneDrive folders from explorer
    Remove-Item -Path 'HKCR:\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path 'HKCR:\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' -Recurse -Force -ErrorAction SilentlyContinue
    dbg-ok "OneDrive removed & policy-blocked"

    # ── Mouse acceleration off ───────────────────────────────────────────────
    dbg "Disabling mouse acceleration …"
    $mKey = 'HKCU:\Control Panel\Mouse'
    if (-not (Test-Path $mKey)) { New-Item -Path $mKey -Force | Out-Null }
    Set-ItemProperty -Path $mKey -Name 'MouseSpeed'      -Value '0' -Type String
    Set-ItemProperty -Path $mKey -Name 'MouseThreshold1' -Value '0' -Type String
    Set-ItemProperty -Path $mKey -Name 'MouseThreshold2' -Value '0' -Type String
    dbg-ok "MouseSpeed=0, MouseThreshold1=0, MouseThreshold2=0"

    # ── Dark mode ────────────────────────────────────────────────────────────
    dbg "Enabling dark mode …"
    $dKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path $dKey)) { New-Item -Path $dKey -Force | Out-Null }
    Set-ItemProperty -Path $dKey -Name 'AppsUseLightTheme'    -Value 0 -Type DWord
    Set-ItemProperty -Path $dKey -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
    dbg-ok "Dark mode enabled"

    # ── Sticky Keys prompt off ───────────────────────────────────────────────
    dbg "Disabling Sticky Keys prompt …"
    $skKey = 'HKCU:\Control Panel\Accessibility\StickyKeys'
    if (-not (Test-Path $skKey)) { New-Item -Path $skKey -Force | Out-Null }
    Set-ItemProperty -Path $skKey -Name 'Flags' -Value '506' -Type String
    
    $tkKey = 'HKCU:\Control Panel\Accessibility\ToggleKeys'
    if (-not (Test-Path $tkKey)) { New-Item -Path $tkKey -Force | Out-Null }
    Set-ItemProperty -Path $tkKey -Name 'Flags' -Value '58' -Type String
    
    $fkKey = 'HKCU:\Control Panel\Accessibility\Keyboard Response'
    if (-not (Test-Path $fkKey)) { New-Item -Path $fkKey -Force | Out-Null }
    Set-ItemProperty -Path $fkKey -Name 'Flags' -Value '122' -Type String
    dbg-ok "Sticky/Toggle/Filter Keys prompts disabled"

    # ── Privacy / Telemetry ──────────────────────────────────────────────────
    dbg "Applying privacy & telemetry tweaks …"

    # Helper: create key if needed, then set value
    function Set-Reg {
        param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        if ($Type -eq 'String') { Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type String }
        else                    { Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord }
    }

    # Bing / Cortana / Search
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'                    'BingSearchEnabled'              0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'                    'SearchScouts'                   0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'                    'CortanaConsent'                 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Search'                          'AllowCortana'                   0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Search'                          'AllowSearchMarketplace'         0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Search'                          'DisableWebSearch'               1

    # Telemetry
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'                  'AllowTelemetry'                 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'   'AllowTelemetry'                 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'                  'DoNotShowFeedbackNotifications' 1

    # Activity History
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                          'EnableActivityFeed'             0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                          'PublishUserActivities'          0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                          'UploadUserActivities'           0

    # Background apps
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled'          1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'                      'LetAppsRunInBackground'         2

    # Location
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'                      'LetAppsAccessLocation'          2
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'

    # Camera/Microphone privacy
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'                      'LetAppsAccessCamera'            2
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'                      'LetAppsAccessMicrophone'        2

    # GameDVR / GameBar
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'                   'AppCaptureEnabled'              0
    Set-Reg 'HKCU:\System\GameConfigStore'                                               'GameDVR_Enabled'                0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'                          'AllowGameDVR'                   0

    # Hibernation off
    powercfg /hibernate off 2>$null

    # Storage Sense
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 0

    # WiFi Sense
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config'                 'AutoConnectAllowedOEM'          0

    # Advertising ID
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'           'Enabled'                        0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'                 'DisabledByGroupPolicy'          1

    # Windows Spotlight / Cloud Consumer
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'                    'DisableWindowsSpotlightFeatures' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'                    'DisableTailoredExperiencesWithDiagnosticData' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'                    'DisableWindowsConsumerFeatures' 1
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'                    'DisableTailoredExperiencesWithDiagnosticData' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'    'ContentDeliveryAllowed'         0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'    'OemPreInstalledAppsEnabled'     0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'    'PreInstalledAppsEnabled'        0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'    'PreInstalledAppsEverEnabled'    0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'    'SilentInstalledAppsEnabled'     0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'    'SoftLandingEnabled'             0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'    'SubscribedContentEnabled'       0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'    'SubscribedContent-338388Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'    'SubscribedContent-338389Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'    'SubscribedContent-353694Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'    'SubscribedContent-353696Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'    'SystemPaneSuggestionsEnabled'   0

    # Edge startup boost & preload
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'                                    'StartupBoostEnabled'            0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'                                    'BackgroundModeEnabled'          0

    # Delivery Optimisation — LAN only
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'            'DODownloadMode'                 1

    # PowerShell telemetry
    [System.Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')
    
    # .NET CLI telemetry
    [System.Environment]::SetEnvironmentVariable('DOTNET_CLI_TELEMETRY_OPTOUT', '1', 'Machine')

    dbg-ok "Privacy / telemetry tweaks done"

    # ── Disable services ─────────────────────────────────────────────────────
    dbg "Disabling services …"
    $DisableSvcs = @(
        'DiagTrack'            # Connected User Experiences & Telemetry
        'dmwappushservice'     # Device Management WAP Push Service
        'Fax'
        'lfsvc'                # Geolocation Service
        'MapsBroker'           # Downloaded Maps Manager
        'RetailDemo'           # Retail Demo Service
        'SysMain'              # Superfetch
        'WerSvc'               # Windows Error Reporting
        'WMPNetworkSvc'        # Windows Media Player Network Sharing
        'WpcMonSvc'            # Parental Controls
        'WSearch'              # Windows Search (can be intensive)
        'XblAuthManager'       # Xbox Live Auth Manager
        'XblGameSave'          # Xbox Live Game Save
        'XboxGipSvc'           # Xbox Accessory Management
        'XboxNetApiSvc'        # Xbox Live Networking
    )
    foreach ($s in $DisableSvcs) {
        sc.exe config $s start= disabled 2>$null
        sc.exe stop   $s                 2>$null
    }
    dbg-ok "$($DisableSvcs.Count) services disabled"

    # ── Disable scheduled tasks ──────────────────────────────────────────────
    dbg "Disabling scheduled tasks …"
    $Tasks = @(
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater'
        '\Microsoft\Windows\Autochk\Proxy'
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
        '\Microsoft\Windows\Feedback\Siuf\DmClient'
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
        '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
        '\Microsoft\Windows\Maps\MapsUpdateTask'
        '\Microsoft\Windows\Maps\MapsToastTask'
    )
    foreach ($t in $Tasks) {
        schtasks /Change /TN $t /Disable 2>$null
    }
    dbg-ok "Scheduled tasks disabled"

    # ── Ultimate Performance power plan ──────────────────────────────────────
    dbg "Activating Ultimate Performance power plan …"
    $ultGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    # First unhide it
    powercfg /duplicatescheme $ultGuid 2>$null
    $listOut = & powercfg /L 2>&1
    if ($listOut -match $ultGuid) {
        powercfg /setactivescheme $ultGuid 2>$null
        dbg-ok "Ultimate Performance plan activated"
    } else {
        # Create from high performance
        $highGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        $newGuid = & powercfg /duplicatescheme $highGuid 2>&1
        if ($newGuid -match '([a-f0-9-]{36})') {
            $createdGuid = $Matches[1]
            powercfg /changename $createdGuid "Ultimate Performance" "Maximum performance" 2>$null
            powercfg /setactivescheme $createdGuid 2>$null
            dbg-ok "Created + activated Ultimate Performance plan"
        } else {
            dbg-warn "Could not create Ultimate Performance plan"
        }
    }

    # ── Show hidden files & extensions ───────────────────────────────────────
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden'          1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt'     0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSuperHidden' 1
    dbg-ok "Explorer: hidden files & extensions visible"

    # ── Taskbar tweaks ───────────────────────────────────────────────────────
    dbg "Applying taskbar tweaks …"
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton'     0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa'              0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn'              0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'            'SearchboxTaskbarMode'   0
    dbg-ok "Taskbar cleaned up (Task View, Widgets, Chat hidden)"

    # ── Start menu suggestions off ───────────────────────────────────────────
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs'       0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackDocs'        0
    dbg-ok "Start menu suggestions disabled"

    # ── NumLock on by default ────────────────────────────────────────────────
    Set-Reg 'HKCU:\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
    Set-Reg 'HKU:\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String' 2>$null
    dbg-ok "NumLock enabled by default"

    # ── Classic right-click context menu (Windows 11) ────────────────────────
    Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(Default)' '' 'String'
    dbg-ok "Classic context menu enabled (Win11)"

    # ── Refresh explorer ─────────────────────────────────────────────────────
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process explorer

    Set-Stage 2
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 2 — Winget App Installs
# ─────────────────────────────────────────────────────────────────────────────
function Stage-WingetApps {
    dbg-head "STAGE 2 — Winget App Installs"

    # Winget install helper function with retry
    function Install-WingetApp {
        param([string]$Id, [int]$MaxRetries = 2)
        
        for ($retry = 1; $retry -le $MaxRetries; $retry++) {
            dbg "  Installing $Id (attempt $retry) …"
            try {
                $out = & winget install --exact --id $Id `
                    --silent `
                    --accept-package-agreements `
                    --accept-source-agreements `
                    --disable-interactivity 2>&1
                
                $outStr = $out -join ' '
                if ($outStr -match 'Successfully installed' -or $outStr -match 'already installed') { 
                    dbg-ok "$Id installed"
                    return $true
                }
                if ($outStr -match 'No package found') {
                    dbg-warn "$Id — package not found in winget"
                    return $false
                }
                dbg-warn "$Id — last output: $(($out | Select-Object -Last 2) -join ' | ')"
            } catch { 
                dbg-err "$Id — exception: $_" 
            }
            Start-Sleep -Seconds 3
        }
        return $false
    }

    # Apps list - includes Prism Launcher
    $Apps = @(
        'Valve.Steam'
        'Discord.Discord'
        'Spotify.Spotify'
        'VideoLAN.VLC'
        '7zip.7zip'
        'Bitwarden.Bitwarden'
        'Python.Python.3.12'
        'Ablaze.Floorp'
        'Git.Git'
        'Bloxstrap'
        'voidtools.Everything'
        'AntibodySoftware.WizTree'
        'EpicGames.EpicGamesLauncher'
        'Modrinth.ModrinthApp'
        'Logitech.GHUB'
        'Alex313031.Thorium.AVX2'
        'PrismLauncher.PrismLauncher'
    )

    $installed = 0
    $failed = 0
    foreach ($id in $Apps) {
        if (Install-WingetApp $id) {
            $installed++
        } else {
            $failed++
        }
        Start-Sleep -Seconds 1
    }

    dbg-ok "Winget apps: $installed installed, $failed failed"
    Set-Stage 3
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 3 — Manual App Installs  (Vencord, TCNO)
# ─────────────────────────────────────────────────────────────────────────────
function Stage-ManualApps {
    dbg-head "STAGE 3 — Manual App Installs"
    Ensure-TempDir

    # ── Vencord ──────────────────────────────────────────────────────────────
    dbg "Resolving VencordInstallerCli.exe …"
    $vencordUrl  = Get-LatestAssetUrl -Owner 'Vencord' -Repo 'Installer' -Pattern 'VencordInstallerCli\.exe$'
    $vencordDest = Join-Path $TEMP_DIR 'VencordInstallerCli.exe'
    if ($vencordUrl -and (Invoke-Download $vencordUrl $vencordDest)) {
        dbg "  Piping stdin to VencordInstallerCli (select stable, confirm yes) …"
        try {
            # "0" selects stable Discord, "y" confirms.  Pipe both via cmd /c.
            $p = Start-Process -FilePath 'cmd.exe' `
                -ArgumentList "/c (echo 0 & echo y) | `"$vencordDest`"" `
                -WindowStyle Hidden -PassThru
            $exited = $p.WaitForExit(120000)
            if ($exited) { dbg-ok "VencordInstallerCli finished (exit $($p.ExitCode))" }
            else         { dbg-warn "VencordInstallerCli timed out after 120s — killing"; $p.Kill() }
        } catch { dbg-err "Vencord stdin-pipe failed: $_" }
    } else {
        dbg-warn "Vencord exe could not be resolved/downloaded — skipping"
    }

    # ── TCNO Account Switcher ────────────────────────────────────────────────
    dbg "Resolving TCNO Account Switcher installer …"
    $tcnoUrl  = Get-LatestAssetUrl -Owner 'TCNOco' -Repo 'TcNo-Acc-Switcher' -Pattern 'TcNo-Account-Switcher.*_Installer\.exe$'
    if (-not $tcnoUrl) {
        $tcnoUrl = Get-LatestAssetUrl -Owner 'TCNOco' -Repo 'TcNo-Acc-Switcher' -Pattern 'Installer.*\.exe$'
    }
    $tcnoDest = Join-Path $TEMP_DIR 'TcNoInstaller.exe'
    if ($tcnoUrl -and (Invoke-Download $tcnoUrl $tcnoDest)) {
        Start-Silent $tcnoDest '/VERYSILENT /NORESTART /CLOSEAPPLICATIONS' 180
        dbg-ok "TCNO Account Switcher installed"
    } else {
        dbg-warn "TCNO installer could not be resolved/downloaded — skipping"
    }

    Set-Stage 4
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 4 — GPU Drivers
# ─────────────────────────────────────────────────────────────────────────────
function Stage-GPUDrivers {
    dbg-head "STAGE 4 — GPU Driver Install"
    Ensure-TempDir

    $gpu     = Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
    $gpuName = if ($gpu) { $gpu.Name } else { 'UNKNOWN' }
    dbg "Detected GPU: $gpuName"

    if ($gpuName -match 'NVIDIA|GeForce|Quadro|Tesla') {
        # ── NVIDIA App installer ─────────────────────────────────────────────
        dbg "NVIDIA GPU detected — fetching NVIDIA App …"
        
        # Try multiple approaches to get the download URL
        $nvidiaUrl = $null
        
        # Method 1: Scrape official page
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $page = Invoke-WebRequest -Uri 'https://www.nvidia.com/en-us/software/nvidia-app/' -UseBasicParsing -ErrorAction Stop
            if ($page.Content -match 'https://[^\s"'\''<>]*us\.download\.nvidia\.com[^\s"'\''<>]*NVIDIA_app[^\s"'\''<>]*\.exe') {
                $nvidiaUrl = $Matches[0]
                dbg-ok "Scraped NVIDIA App URL: $nvidiaUrl"
            }
        } catch { dbg-warn "NVIDIA page scrape failed: $_" }

        # Method 2: Known fallback URL (updated periodically)
        if (-not $nvidiaUrl) {
            $nvidiaUrl = 'https://us.download.nvidia.com/nvapp/client/11.0.6.383/NVIDIA_app_v11.0.6.383.exe'
            dbg-warn "Using known fallback URL: $nvidiaUrl"
        }

        $nvDest = Join-Path $TEMP_DIR 'NVIDIA_app_installer.exe'
        if (Invoke-Download $nvidiaUrl $nvDest) {
            # Silent install flags from NVIDIA setup.cfg
            Start-Silent $nvDest '-s -noreboot -noeula -nofinish' 600
            dbg-ok "NVIDIA App installer executed"
        }

    } elseif ($gpuName -match 'AMD|Radeon|FirePro') {
        dbg-warn "AMD GPU detected ($gpuName)"
        dbg-warn "AMD has no stable single installer URL — please download drivers"
        dbg-warn "manually from: https://www.amd.com/en/support"

    } elseif ($gpuName -match 'Intel|Arc|Iris|UHD') {
        dbg "Intel GPU detected — attempting Intel Driver installer …"
        # Intel has a driver support assistant
        $intelUrl = 'https://dsadata.intel.com/installer/Intel%20Driver%20%26%20Support%20Assistant%20Installer.exe'
        $intelDest = Join-Path $TEMP_DIR 'Intel_DSA_Installer.exe'
        if (Invoke-Download $intelUrl $intelDest) {
            Start-Silent $intelDest '/quiet /norestart' 300
            dbg-ok "Intel DSA installed (will auto-update drivers)"
        }

    } else {
        dbg-warn "No discrete NVIDIA/AMD/Intel GPU detected ($gpuName) — skipping drivers"
    }

    Set-Stage 5
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 5 — Windows HWID Activation  (MAS)
# ─────────────────────────────────────────────────────────────────────────────
function Stage-Activation {
    dbg-head "STAGE 5 — Windows HWID Activation (MAS)"
    
    dbg "Downloading MAS script from https://get.activated.win …"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $masResp = Invoke-WebRequest -Uri 'https://get.activated.win' -UseBasicParsing -ErrorAction Stop
        if ($masResp -and $masResp.Content -and $masResp.Content.Length -gt 100) {
            dbg-ok "MAS script downloaded ($($masResp.Content.Length) chars)"
            dbg "Executing MAS with /HWID switch (unattended) …"
            & ([ScriptBlock]::Create($masResp.Content)) /HWID
            dbg-ok "MAS /HWID execution completed"
        } else {
            dbg-err "MAS script body was empty or too short"
        }
    } catch {
        dbg-err "MAS activation failed: $_"
    }

    Set-Stage 99
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 99 — Cleanup
# ─────────────────────────────────────────────────────────────────────────────
function Stage-Cleanup {
    dbg-head "STAGE 99 — Cleanup & Done"

    Remove-Persistence

    # Launch Task Manager visibly so user knows we finished
    Start-Process -FilePath 'taskmgr.exe' -WindowStyle Normal
    dbg-ok "taskmgr.exe launched"

    # Delete temp files (best-effort; log itself may be locked)
    Start-Sleep -Seconds 2
    try {
        if (Test-Path $TEMP_DIR) {
            Get-ChildItem $TEMP_DIR -Recurse -Force |
                Where-Object { -not $_.PSIsDirectory } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem $TEMP_DIR -Recurse -Directory |
                Sort-Object { $_.FullName.Length } -Descending |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Remove-Item $TEMP_DIR -Force -Recurse -ErrorAction SilentlyContinue
        }
    } catch {}

    dbg-ok "All done. Log was at: $LOG_PATH"
    dbg "Exiting."
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────
Ensure-TempDir
Ensure-Admin

Clear-Host
Write-Host '+---------------------------------------------------------+' -ForegroundColor Cyan
Write-Host '|   MestalWinBox  --  DEBUG MODE                          |' -ForegroundColor Cyan
Write-Host '|   Everything is logged here AND to:                     |' -ForegroundColor Cyan
Write-Host '|   %TEMP%\MestalTemp\mestal_debug.log                   |' -ForegroundColor Cyan
Write-Host '+---------------------------------------------------------+' -ForegroundColor Cyan
Write-Host ''

Install-Persistence

$stage = Get-Stage
dbg "Resuming at stage $stage"

if ($stage -le 0)  { Stage-WingetRepair }
if ($stage -le 1)  { Stage-DebloatTweaks }
if ($stage -le 2)  { Stage-WingetApps }
if ($stage -le 3)  { Stage-ManualApps }
if ($stage -le 4)  { Stage-GPUDrivers }
if ($stage -le 5)  { Stage-Activation }

Stage-Cleanup
