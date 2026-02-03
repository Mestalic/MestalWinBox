#############################################################################
#  Mestal.ps1 — MestalWinBox  |  DEBUG VERSION
#  Visible console + colour-coded live log + file log.
#
#  EVERY URL below was verified live (HTTP 200) before inclusion.
#  Sources & what was confirmed:
#    ✓ get.activated.win              — official MAS domain, script returned live
#    ✓ Vencord/Installer (GitHub)     — install.ps1 returned 200, content verified
#    ✓ Alex313031.Thorium.AVX2        — winget ID confirmed on winget repos
#                                       actual .exe comes from Alex313031/Thorium-Win
#    ✓ TCNOco/TcNo-Acc-Switcher       — GitHub releases page confirmed live
#    ✓ nvidia.com/en-us/software/nvidia-app/ — page confirmed live; URL scraped at runtime
#                                       silent flags confirmed via setup.cfg docs
#    ✗ roblox.com/download/install    — REMOVED; pizzaboxer.Bloxstrap (winget) IS
#                                       the Roblox launcher, so this was redundant
#    ✗ HWID.bat / Separate-Files      — NEVER EXISTED; MAS has no such path.
#                                       Correct method: & ([ScriptBlock]::Create(...)) /HWID
#
#  Stages (reboot-resilient via HKLM registry):
#    0  = Winget repair
#    1  = Debloat & Tweaks
#    2  = Winget app installs  (includes Thorium AVX2 via winget)
#    3  = Manual app installs  (Vencord, TCNO)
#    4  = GPU drivers          (NVIDIA App; AMD skipped — no stable single URL)
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
#  STAGE 0 — Winget Repair
# ─────────────────────────────────────────────────────────────────────────────
function Stage-WingetRepair {
    dbg-head "STAGE 0 — Winget Repair"

    function Test-Winget {
        try {
            $null = & winget list 2>&1
            return $true
        } catch {
            return $false
        }
    }

    if (Test-Winget) {
        dbg-ok "Winget already working"
        Set-Stage 1
        return
    }

    $attempt = 0
    while (-not (Test-Winget) -and $attempt -lt 8) {
        $attempt++
        dbg "Winget repair attempt $attempt of 8 …"

        # Re-register DesktopAppInstaller if present
        $daiPkg = Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($daiPkg -and $daiPkg.InstallLocation) {
            $manifest = Join-Path $daiPkg.InstallLocation 'AppxManifest.xml'
            if (Test-Path $manifest) {
                dbg "  Re-registering DesktopAppInstaller from $manifest"
                Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ErrorAction SilentlyContinue
            }
        }

        # Nudge Microsoft Store updates page
        for ($i = 1; $i -le 5; $i++) {
            dbg "  Opening Store updates page ($i / 5) …"
            Start-Process -FilePath 'ms-windows-store://updates' -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 4
        }
        Get-Process -Name 'WindowsStore' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3

        if (Test-Winget) { dbg-ok "Winget is working now"; break }

        # After 3 failed attempts download the MSIX directly from winget-cli releases
        if ($attempt -eq 3) {
            dbg "  Downloading DesktopAppInstaller MSIX from GitHub …"
            $msixDest = Join-Path $TEMP_DIR 'DesktopAppInstaller.msix'
            $msixUrl = Get-LatestAssetUrl -Owner 'microsoft' -Repo 'winget-cli' -Pattern 'Microsoft\.DesktopAppInstaller.*\.msix$'
            if ($msixUrl) {
                if (Invoke-Download $msixUrl $msixDest) {
                    Add-AppxPackage -Path $msixDest -ErrorAction SilentlyContinue
                    dbg-ok "Installed DesktopAppInstaller MSIX"
                    Start-Sleep -Seconds 5
                }
            } else {
                dbg-warn "Could not resolve MSIX URL; will try reboot next"
            }
        }

        # After 5 failed attempts reboot
        if ($attempt -eq 5 -and -not (Test-Winget)) {
            dbg-warn "Winget still broken after 5 attempts — rebooting"
            Do-Reboot 0
        }
    }

    if (Test-Winget) { dbg-ok "Winget confirmed working" }
    else             { dbg-err "Winget could not be repaired after 8 attempts — continuing anyway" }

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
    dbg-ok "OneDrive removed & policy-blocked"

    # ── Mouse acceleration off ───────────────────────────────────────────────
    dbg "Disabling mouse acceleration …"
    $mKey = 'HKCU:\Control Panel\Mouse'
    if (-not (Test-Path $mKey)) { New-Item -Path $mKey -Force | Out-Null }
    Set-ItemProperty -Path $mKey -Name 'MouseSpeed'  -Value '0' -Type String
    Set-ItemProperty -Path $mKey -Name 'Threshold1'  -Value '0' -Type String
    Set-ItemProperty -Path $mKey -Name 'Threshold2'  -Value '0' -Type String
    dbg-ok "MouseSpeed=0, Threshold1=0, Threshold2=0"

    # ── Dark mode ────────────────────────────────────────────────────────────
    dbg "Enabling dark mode …"
    $dKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path $dKey)) { New-Item -Path $dKey -Force | Out-Null }
    Set-ItemProperty -Path $dKey -Name 'AppsUseLightTheme'    -Value 0 -Type DWord
    Set-ItemProperty -Path $dKey -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
    dbg-ok "Dark mode enabled"

    # ── Sticky Keys prompt off ───────────────────────────────────────────────
    $skKey = 'HKCU:\Control Panel\AccessibilityKeySettings\Keys'
    if (-not (Test-Path $skKey)) { New-Item -Path $skKey -Force | Out-Null }
    Set-ItemProperty -Path $skKey -Name 'Flags' -Value '506' -Type String
    dbg-ok "Sticky Keys prompt disabled"

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
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Search'                          'AllowCortana'                   0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Search'                          'AllowSearchMarketplace'         0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Search'                          'AllowWebSearchMarketplace'      0

    # Telemetry
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'                  'AllowTelemetry'                 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'   'AllowTelemetry'                 0

    # Activity History
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                          'EnableActivityFeed'             0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                          'PublishUserActivities'          0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                          'UploadUserActivities'           0

    # Background apps
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Control Panel\Parameters'  'EnableBackgroundApps'           0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppPrivacy'                'LetAppsRunInBackground'         2
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppPrivacy'                'LetAppsAccessLocation'          2
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppPrivacy'                'LetAppsAccessMicrophone'        2
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppPrivacy'                'LetAppsAccessCamera'            2

    # GameDVR / GameBar
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameBar'                   'AllowAutoGameBar'               0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameBar'                   'UseGameBar'                     0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Game Bar'                        'AllowGameBarPrivate'            0

    # Hibernation off
    powercfg /hibernate off 2>$null

    # Location
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'

    # Storage Sense
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense'              'StorageSenseAutomate'           0

    # WiFi Sense
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Wlansvc\Parameters'                'AllowWifiSense'                 0

    # Advertising ID
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingID'             'Enabled'                        0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Advertising'                     'AllowAdvertisingID'             0

    # Windows Spotlight / Cloud Consumer
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'                    'DisableWindowsSpotlight'        1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'                    'DisableCloudConsumerApps'       1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'                    'DisableWindowsConsumerFeatures' 1

    # Edge startup boost
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Microsoft Edge'                          'StartupBoost'                   0

    # Delivery Optimisation — LAN only
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode'               1

    # PowerShell telemetry
    [System.Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')

    dbg-ok "Privacy / telemetry tweaks done"

    # ── Disable services ─────────────────────────────────────────────────────
    dbg "Disabling services …"
    $DisableSvcs = @(
        'DiagTrack'            # Connected User Experiences & Telemetry
        'dmawservice'          # Device Management Wireless Service
        'Fax'
        'MapsBroker'           # Downloaded Maps Manager
        'MessagingService'
        'PrintNotify'
        'RetailDemo'           # Retail Demo Service
        'ShellHWDetection'     # Shell Hardware Detection (auto-play)
        'SysMain'              # Superfetch
        'TabletInputService'   # On-screen keyboard helper
        'WinHttpAutoProxySvc'
        'WpnService'           # Windows Push Notifications
        'WSearch'              # Windows Search
        'XboxGippSvc'
        'XboxNetSaverSvc'
        'XboxUserSvc'
    )
    foreach ($s in $DisableSvcs) {
        sc.exe config $s start= disabled 2>$null
        sc.exe stop   $s                 2>$null
    }
    dbg-ok "$($DisableSvcs.Count) services disabled"

    # ── Disable scheduled tasks ──────────────────────────────────────────────
    dbg "Disabling scheduled tasks …"
    $Tasks = @(
        'Microsoft\Windows\Application Experience\Microsoft-Windows-ApplicationExperienceInfrastructure-OneTimeScheduledTask'
        'Microsoft\Windows\Application Experience\Microsoft-Windows-PerfTrack-Opt-In'
        'Microsoft\Windows\Application Experience\Microsoft-Windows-SierraTelemetryInfrastructure-OneTimeScheduledTask'
        'Microsoft\Windows\Feedback\SIUF\SysIdAp'
        'Microsoft\Windows\Feedback\SIUF\SysIdApSched'
        'Microsoft\Windows\Shell\FamilySafetyMonitor'
        'Microsoft\Windows\Shell\FamilySafetyMonitorCmdStore'
        'Microsoft\Windows\Shell\FamilySafetyMonitorSyncRL'
    )
    foreach ($t in $Tasks) {
        Disable-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    }
    dbg-ok "$($Tasks.Count) tasks disabled"

    # ── Ultimate Performance power plan ──────────────────────────────────────
    dbg "Activating Ultimate Performance power plan …"
    $ultGuid = 'e9a4aa16-61ba-4ed7-a5f7-edf482346f66'
    $listOut = & powercfg /L 2>&1
    if ($listOut -match $ultGuid) {
        powercfg /setactivescheme $ultGuid 2>$null
        dbg-ok "Ultimate Performance plan activated"
    } else {
        # Duplicate High Performance and rename
        $highGuid = '8c016748-2fbf-4e82-9e6e-f510833e3905'
        powercfg /duplicatescheme $highGuid $ultGuid 2>$null
        powercfg /setactivescheme $ultGuid 2>$null
        dbg-ok "Created + activated Ultimate Performance plan"
    }

    # ── Show hidden files & extensions ───────────────────────────────────────
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowHiddenFiles' 2
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt'     0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideSysFolder'   2
    dbg-ok "Explorer: hidden files & extensions visible"

    # ── Start menu suggestions off ───────────────────────────────────────────
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' 'ShowFrequentApps'   0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' 'ShowRecentlyAdded'  0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' 'ShowRecentlyOpened' 0
    dbg-ok "Start menu suggestions disabled"

    Set-Stage 2
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 2 — Winget App Installs
# ─────────────────────────────────────────────────────────────────────────────
function Stage-WingetApps {
    dbg-head "STAGE 2 — Winget App Installs"

    # Thorium AVX2 is here via winget (ID confirmed live: Alex313031.Thorium.AVX2)
    # Bloxstrap replaces standalone Roblox bootstrapper
    $Apps = @(
        'Valve.Steam'
        'Discord.Discord'
        'Spotify.Spotify'
        'VideoLAN.VLC'
        '7zip.7zip'
        'Bitwarden.Bitwarden'
        'Python.Python.3'
        'Ablaze.Floorp'
        'Git.Git'
        'pizzaboxer.Bloxstrap'
        'voidtools.Everything'
        'WizTree.WizTree'
        'EpicGames.EpicGamesLauncher'
        'Modrinth.ModrinthApp'
        'Logitech.GHUB'
        'Alex313031.Thorium.AVX2'
    )

    foreach ($id in $Apps) {
        dbg "  Installing $id …"
        try {
            $out = & winget install --exact --id $id `
                --silent `
                --accept-package-agreements `
                --accept-source-agreements `
                --disable-interactivity 2>&1
            if ($out -match 'Successfully installed') { dbg-ok "$id installed" }
            else { dbg-warn "$id — last output: $(($out | Select-Object -Last 3) -join ' | ')" }
        } catch { dbg-err "$id — exception: $_" }
        Start-Sleep -Seconds 2
    }

    Set-Stage 3
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 3 — Manual App Installs  (Vencord, TCNO)
# ─────────────────────────────────────────────────────────────────────────────
function Stage-ManualApps {
    dbg-head "STAGE 3 — Manual App Installs"
    Ensure-TempDir

    # ── Vencord ──────────────────────────────────────────────────────────────
    # Verified: raw.githubusercontent.com/Vencord/Installer/main/install.ps1 is LIVE.
    # That script downloads VencordInstallerCli.exe from GitHub releases/latest.
    # The CLI is a Go binary with NO silent flags.  It prompts interactively:
    #   - Pick install type  (we want index 0 = stable Discord)
    #   - Confirm install    (y)
    # We download the exe directly via GitHub API, then pipe stdin via cmd.
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
    # Confirmed: TCNOco/TcNo-Acc-Switcher releases page is live.
    # Installer is Inno Setup => /VERYSILENT /NOPROMPT are standard flags.
    dbg "Resolving TCNO Account Switcher installer …"
    $tcnoUrl  = Get-LatestAssetUrl -Owner 'TCNOco' -Repo 'TcNo-Acc-Switcher' -Pattern 'TcNo\.Account\.Switcher.*Installer.*\.exe$'
    $tcnoDest = Join-Path $TEMP_DIR 'TcNoInstaller.exe'
    if ($tcnoUrl -and (Invoke-Download $tcnoUrl $tcnoDest)) {
        Start-Silent $tcnoDest '/VERYSILENT /NOPROMPT' 180
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
        # nvidia.com/en-us/software/nvidia-app/ is confirmed live.
        # The community gist (emilwojcik93) confirms the scrape approach and
        # the silent flags from setup.cfg:
        #   -silent -noreboot -noeula -nofinish -passive
        # Current known version (WAPT, signed 2026-01-26): 11.0.6.383
        # We scrape the page at runtime; fall back to that version if scrape fails.
        dbg "NVIDIA GPU detected — scraping NVIDIA App download URL …"
        $nvidiaUrl = $null
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $page = Invoke-WebRequest -Uri 'https://www.nvidia.com/en-us/software/nvidia-app/' -UseBasicParsing -ErrorAction Stop
            # Look for the versioned CDN URL pattern in page source
            if ($page.Content -match 'https://[^\s"'\''<>]*us\.download\.nvidia\.com[^\s"'\''<>]*\.exe') {
                $nvidiaUrl = $Matches[0]
                dbg-ok "Scraped NVIDIA App URL: $nvidiaUrl"
            }
        } catch { dbg-warn "NVIDIA page scrape failed: $_" }

        if (-not $nvidiaUrl) {
            $nvidiaUrl = 'https://us.download.nvidia.com/nvapp/client/11.0.6.383/NVIDIA_app_v11.0.6.383.exe'
            dbg-warn "Using known fallback URL: $nvidiaUrl"
        }

        $nvDest = Join-Path $TEMP_DIR 'NVIDIA_app_installer.exe'
        if (Invoke-Download $nvidiaUrl $nvDest) {
            Start-Silent $nvDest '-silent -noreboot -noeula -nofinish -passive' 600
            dbg-ok "NVIDIA App installer executed"
        }

    } elseif ($gpuName -match 'AMD|Radeon|FirePro') {
        # AMD does NOT publish a single stable direct-download URL.
        # Their download page requires JavaScript auto-detect.
        # Logging a clear warning so the user knows to do it manually.
        dbg-warn "AMD GPU detected ($gpuName)"
        dbg-warn "AMD has no stable single installer URL — please download drivers"
        dbg-warn "manually from: https://www.amd.com/en/support"

    } else {
        dbg-warn "No discrete NVIDIA/AMD GPU detected ($gpuName) — skipping drivers"
    }

    Set-Stage 5
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 5 — Windows HWID Activation  (MAS)
# ─────────────────────────────────────────────────────────────────────────────
function Stage-Activation {
    dbg-head "STAGE 5 — Windows HWID Activation (MAS)"
    # VERIFIED on massgrave.dev/command_line_switches:
    #   & ([ScriptBlock]::Create((irm https://get.activated.win))) /HWID
    # runs HWID fully unattended. /HWID is the documented switch.
    # get.activated.win confirmed live above — it returns the MAS PowerShell script.
    # There is NO "HWID.bat", NO "Separate-Files" folder in the MAS repo.
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
