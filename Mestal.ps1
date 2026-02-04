
$global:ErrorActionPreference = 'SilentlyContinue'

# ── Constants ────────────────────────────────────────────────────────────────
$REG_BASE  = 'HKLM:\SOFTWARE\MestalWinBox'
$RUN_KEY   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$RUN_NAME  = 'MestalWinBoxResume'
$TEMP_DIR  = Join-Path $env:TEMP 'MestalTemp'
$LOG_PATH  = Join-Path $TEMP_DIR 'mestal_debug.log'
$SELF_URL  = 'https://mestalic.zip/winbox'

# ── Debug helpers ────────────────────────────────────────────────────────────
function dbg {
    param([string]$Msg, [string]$Color = 'Cyan')
    $stamp = (Get-Date).ToString('HH:mm:ss')
    try { Write-Host "[$stamp] $Msg" -ForegroundColor $Color } catch {}
    try { Add-Content -Path $LOG_PATH -Value "[$stamp] $Msg" } catch {}
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
    dbg "Stage → $S"
}

# ── Persistence ──────────────────────────────────────────────────────────────
function Install-Persistence {
    Ensure-TempDir
    $cached = Join-Path $TEMP_DIR 'MestalResume.ps1'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $SELF_URL -OutFile $cached -UseBasicParsing -ErrorAction Stop
        dbg-ok "Cached script"
    } catch { dbg-warn "Script cache failed: $_" }
    $cmd = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -File `"$cached`""
    Set-ItemProperty -Path $RUN_KEY -Name $RUN_NAME -Value $cmd
    dbg-ok "Persistence installed"
}
function Remove-Persistence {
    Remove-ItemProperty -Path $RUN_KEY -Name $RUN_NAME -ErrorAction SilentlyContinue
    Remove-Item -Path $REG_BASE -Recurse -Force -ErrorAction SilentlyContinue
    dbg-ok "Persistence removed"
}

# ── Reboot ───────────────────────────────────────────────────────────────────
function Do-Reboot {
    param([int]$NextStage)
    Set-Stage $NextStage
    Install-Persistence
    dbg "Rebooting in 5s → stage $NextStage"
    Start-Sleep 2
    shutdown /r /t 5 /f /d p:3:1 2>$null
    exit 0
}

# ── Download ─────────────────────────────────────────────────────────────────
function Invoke-Download {
    param([string]$Url, [string]$Dest)
    dbg "  ↓ $Url"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop
        $sz = if (Test-Path $Dest) { (Get-Item $Dest).Length } else { 0 }
        if ($sz -gt 0) {
            dbg-ok "$([math]::Round($sz/1MB,2)) MB → $(Split-Path $Dest -Leaf)"
            return $true
        }
        dbg-err "0 bytes downloaded"
        return $false
    } catch {
        dbg-err "Download failed: $_"
        return $false
    }
}

# ── Silent process ───────────────────────────────────────────────────────────
function Start-Silent {
    param([string]$Exe, [string]$Args = '', [int]$WaitSec = 300)
    dbg "  ▶ $(Split-Path $Exe -Leaf) $Args"
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $Args -WindowStyle Hidden -PassThru -ErrorAction Stop
        if ($p) {
            $exited = $p.WaitForExit($WaitSec * 1000)
            if ($exited) { dbg-ok "Exit code $($p.ExitCode)" }
            else         { dbg-warn "Timeout ${WaitSec}s — killing"; $p.Kill() }
        }
    } catch { dbg-err "Start-Process failed: $_" }
}

# ── GitHub resolver ──────────────────────────────────────────────────────────
function Get-LatestAssetUrl {
    param([string]$Owner, [string]$Repo, [string]$Pattern)
    dbg "  Resolving $Owner/$Repo asset: $Pattern"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $raw = Invoke-WebRequest -Uri "https://api.github.com/repos/$Owner/$Repo/releases/latest" -UseBasicParsing -ErrorAction Stop
        $rel = $raw.Content | ConvertFrom-Json
        $hit = $rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
        if ($hit) {
            dbg-ok "→ $($hit.browser_download_url)"
            return $hit.browser_download_url
        }
        dbg-warn "No match for '$Pattern'"
        return $null
    } catch {
        dbg-err "GitHub API: $_"
        return $null
    }
}

# ── Elevation (FIXED) ────────────────────────────────────────────────────────
function Ensure-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator
    
    if ($pr.IsInRole($adminRole)) {
        dbg-ok "Running as Administrator"
        return
    }
    
    dbg "Not admin — re-launching elevated …"
    Ensure-TempDir
    $scriptPath = $MyInvocation.PSCommandPath
    if (-not $scriptPath) {
        # If invoked via IEX, download to temp
        $scriptPath = Join-Path $TEMP_DIR 'MestalResume.ps1'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $SELF_URL -OutFile $scriptPath -UseBasicParsing -ErrorAction Stop
        } catch {
            dbg-err "Could not download script for elevation: $_"
            Read-Host "Press Enter to exit"
            exit 1
        }
    }
    
    try {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs
        exit 0
    } catch {
        dbg-err "Elevation failed: $_"
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# ── Windows Defender Control ────────────────────────────────────────────────
function Disable-Defender {
    dbg "Disabling Windows Defender …"
    try {
        # Disable real-time protection
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        dbg-ok "Real-time protection disabled"
    } catch { dbg-warn "Real-time disable failed (may require manual disable): $_" }
    
    # Registry-based disable (more aggressive)
    $defenderKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    if (-not (Test-Path $defenderKey)) { New-Item -Path $defenderKey -Force | Out-Null }
    Set-ItemProperty -Path $defenderKey -Name 'DisableAntiSpyware' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    
    $rtKey = "$defenderKey\Real-Time Protection"
    if (-not (Test-Path $rtKey)) { New-Item -Path $rtKey -Force | Out-Null }
    Set-ItemProperty -Path $rtKey -Name 'DisableRealtimeMonitoring' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $rtKey -Name 'DisableBehaviorMonitoring' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $rtKey -Name 'DisableOnAccessProtection' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $rtKey -Name 'DisableScanOnRealtimeEnable' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    
    dbg-ok "Defender disabled via registry"
}

function Enable-Defender {
    dbg "Re-enabling Windows Defender …"
    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        dbg-ok "Real-time protection enabled"
    } catch { dbg-warn "Real-time enable failed: $_" }
    
    # Remove registry blocks
    $defenderKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    Remove-ItemProperty -Path $defenderKey -Name 'DisableAntiSpyware' -ErrorAction SilentlyContinue
    
    $rtKey = "$defenderKey\Real-Time Protection"
    Remove-ItemProperty -Path $rtKey -Name 'DisableRealtimeMonitoring' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $rtKey -Name 'DisableBehaviorMonitoring' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $rtKey -Name 'DisableOnAccessProtection' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $rtKey -Name 'DisableScanOnRealtimeEnable' -ErrorAction SilentlyContinue
    
    dbg-ok "Defender re-enabled"
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 0 — Winget Repair + Windows Update
# ─────────────────────────────────────────────────────────────────────────────
function Stage-WingetRepair {
    dbg-head "STAGE 0 — Winget Repair + Windows Update"

    function Test-Winget {
        try {
            $output = & winget --version 2>&1
            if ($LASTEXITCODE -eq 0 -and $output -match '\d+\.\d+') { return $true }
            return $false
        } catch { return $false }
    }

    function Accept-WingetAgreements {
        dbg "Pre-accepting winget ToS …"
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Winget'
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name 'SourceAgreementsAccepted' -Value 1 -Type DWord -ErrorAction SilentlyContinue
        
        $settingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json"
        $settingsDir = Split-Path $settingsPath -Parent
        if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }
        $settings = @{
            '$schema' = 'https://aka.ms/winget-settings.schema.json'
            'source' = @{ 'autoUpdateIntervalInMinutes' = 5 }
            'experimentalFeatures' = @{ 'experimentalMSStore' = $true }
        } | ConvertTo-Json -Depth 4
        Set-Content -Path $settingsPath -Value $settings -Force -ErrorAction SilentlyContinue
        dbg-ok "ToS pre-accepted"
    }

    function Install-Chocolatey {
        $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
        if (Test-Path $chocoExe) {
            dbg-ok "Chocolatey already present"
            return $true
        }
        dbg "Installing Chocolatey …"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $script = (Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -UseBasicParsing).Content
            & ([ScriptBlock]::Create($script))
            $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
            if (Test-Path $chocoExe) {
                dbg-ok "Chocolatey installed"
                return $true
            }
            dbg-err "Chocolatey exe not found"
            return $false
        } catch {
            dbg-err "Chocolatey install failed: $_"
            return $false
        }
    }

    function Install-WingetViaChoco {
        dbg "Installing winget via choco (180s timeout) …"
        try {
            $job = Start-Job -ScriptBlock {
                & choco install winget -y --force --ignore-checksums 2>&1 | Out-Null
            }
            $done = Wait-Job -Job $job -Timeout 180
            if (-not $done) {
                dbg-warn "Choco install timed out"
                Remove-Job -Job $job -Force
                return $false
            }
            Receive-Job -Job $job | Out-Null
            Remove-Job -Job $job
            Start-Sleep 5
            $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
            if (Test-Winget) {
                dbg-ok "Winget installed via choco"
                return $true
            }
            dbg-warn "Choco completed but winget not working"
            return $false
        } catch {
            dbg-err "Choco install exception: $_"
            return $false
        }
    }

    function Install-WingetDependencies {
        dbg "Installing VCLibs + UI.Xaml …"
        Ensure-TempDir
        
        $vclibsUrl = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
        $vclibsDest = Join-Path $TEMP_DIR 'VCLibs.appx'
        if (Invoke-Download $vclibsUrl $vclibsDest) {
            try {
                Add-AppxPackage -Path $vclibsDest -ErrorAction Stop
                dbg-ok "VCLibs installed"
            } catch { dbg-warn "VCLibs failed: $_" }
        }
        
        $xamlUrl = 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'
        $xamlDest = Join-Path $TEMP_DIR 'UIXaml.appx'
        if (Invoke-Download $xamlUrl $xamlDest) {
            try {
                Add-AppxPackage -Path $xamlDest -ErrorAction Stop
                dbg-ok "UI.Xaml installed"
            } catch { dbg-warn "UI.Xaml failed: $_" }
        }
    }

    function Reset-WingetSources {
        dbg "Resetting winget sources …"
        try {
            & winget source reset --force 2>&1 | Out-Null
            Start-Sleep 2
            & winget source update 2>&1 | Out-Null
            dbg-ok "Sources reset"
        } catch { dbg-warn "Source reset failed" }
    }

    # WINDOWS UPDATE
    function Install-WindowsUpdates {
        dbg "Checking for Windows Updates …"
        try {
            $updateSession = New-Object -ComObject Microsoft.Update.Session
            $updateSearcher = $updateSession.CreateUpdateSearcher()
            
            dbg "  Searching for updates …"
            $searchResult = $updateSearcher.Search("IsInstalled=0 and Type='Software'")
            
            if ($searchResult.Updates.Count -eq 0) {
                dbg-ok "No updates available"
                return
            }
            
            dbg "  Found $($searchResult.Updates.Count) updates"
            
            $updatesToDownload = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($update in $searchResult.Updates) {
                if (-not $update.IsDownloaded) {
                    $updatesToDownload.Add($update) | Out-Null
                }
            }
            
            if ($updatesToDownload.Count -gt 0) {
                dbg "  Downloading $($updatesToDownload.Count) updates …"
                $downloader = $updateSession.CreateUpdateDownloader()
                $downloader.Updates = $updatesToDownload
                $downloader.Download() | Out-Null
                dbg-ok "Updates downloaded"
            }
            
            dbg "  Installing updates …"
            $updatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($update in $searchResult.Updates) {
                if ($update.IsDownloaded) {
                    $updatesToInstall.Add($update) | Out-Null
                }
            }
            
            if ($updatesToInstall.Count -gt 0) {
                $installer = $updateSession.CreateUpdateInstaller()
                $installer.Updates = $updatesToInstall
                $installResult = $installer.Install()
                
                if ($installResult.RebootRequired) {
                    dbg-warn "Updates installed — reboot required"
                } else {
                    dbg-ok "$($updatesToInstall.Count) updates installed"
                }
            }
        } catch {
            dbg-warn "Windows Update failed: $_"
        }
    }

    # === MAIN LOGIC ===
    Accept-WingetAgreements

    if (Test-Winget) {
        dbg-ok "Winget already working"
        Reset-WingetSources
    } else {
        $attempt = 0
        $maxAttempts = 10
        
        while (-not (Test-Winget) -and $attempt -lt $maxAttempts) {
            $attempt++
            dbg "Repair attempt $attempt / $maxAttempts"

            if ($attempt -le 2) { Install-Chocolatey }
            if ($attempt -ge 2 -and $attempt -le 4) {
                if (Install-WingetViaChoco) { break }
            }
            if ($attempt -ge 3 -and $attempt -le 5) { Install-WingetDependencies }
            if ($attempt -ge 4 -and $attempt -le 7) {
                $dai = Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($dai -and $dai.InstallLocation) {
                    $manifest = Join-Path $dai.InstallLocation 'AppxManifest.xml'
                    if (Test-Path $manifest) {
                        dbg "  Re-registering DAI"
                        Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ErrorAction SilentlyContinue
                        Start-Sleep 3
                    }
                }
            }
            if ($attempt -ge 6) {
                dbg "  Nudging Store"
                for ($i=1; $i -le 3; $i++) {
                    Start-Process 'ms-windows-store://updates' -ErrorAction SilentlyContinue
                    Start-Sleep 5
                }
                Get-Process 'WinStore.App' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep 3
            }

            if (Test-Winget) {
                dbg-ok "Winget now working"
                Reset-WingetSources
                break
            }

            if ($attempt -eq 7) {
                dbg-warn "Still broken — rebooting"
                Do-Reboot 0
            }
        }

        if (Test-Winget) {
            dbg-ok "Winget confirmed working"
            Reset-WingetSources
        } else {
            dbg-err "Winget failed after $maxAttempts attempts"
        }
    }

    # Install Windows Updates
    Install-WindowsUpdates

    Set-Stage 1
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 1 — Debloat & Tweaks
# ─────────────────────────────────────────────────────────────────────────────
function Stage-DebloatTweaks {
    dbg-head "STAGE 1 — Debloat & Tweaks"

    $BloatApps = @(
        'Microsoft.549981C3F5F10','Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GamingApp'
        'Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.MicrosoftOfficeHub','Microsoft.MicrosoftSolitaireCollection'
        'Microsoft.People','Microsoft.PowerAutomateDesktop','Microsoft.Todos','Microsoft.WindowsAlarms'
        'Microsoft.WindowsCamera','Microsoft.WindowsCommunicationsApps','Microsoft.WindowsFeedbackHub'
        'Microsoft.WindowsMaps','Microsoft.WindowsSoundRecorder','Microsoft.Xbox.TCUI','Microsoft.XboxApp'
        'Microsoft.XboxGameOverlay','Microsoft.XboxGamingOverlay','Microsoft.XboxIdentityProvider'
        'Microsoft.XboxSpeechToTextOverlay','Microsoft.YourPhone','Microsoft.ZuneMusic','Microsoft.ZuneVideo'
        'MicrosoftCorporationII.QuickAssist','MicrosoftTeams','MSTeams','Microsoft.Copilot'
        'Clipchamp.Clipchamp','Microsoft.OutlookForWindows','ACGMediaPlayer','ActiproSoftwareLLC'
        'AdobeSystemsIncorporated.AdobePhotoshopExpress','Amazon.com.Amazon','AmazonVideo.PrimeVideo'
        'Asphalt8Airborne','AutodeskSketchBook','CaesarsSlotsFreeCasino','COOKINGFEVER'
        'CyberLinkMediaSuiteEssentials','DisneyMagicKingdoms','Dolby','DrawboardPDF'
        'Duolingo-LearnLanguagesforFree','EclipseManager','Facebook','FarmVille2CountryEscape'
        'fitbit','Flipboard','GAMELOFTSA','HiddenCityMysteryofShadows','HULULLC.HULUPLUS'
        'iHeartRadio','Instagram','king.com.BubbleWitch3Saga','king.com.CandyCrushFriends'
        'king.com.CandyCrushSaga','king.com.CandyCrushSodaSaga','LinkedInforWindows'
        'MarchofEmpires','Netflix','NYTCrossword','OneCalendar','PandoraMediaInc'
        'PhototasticCollage','PicsArt-PhotoStudio','Plex','PolarrPhotoEditorAcademicEdition'
        'Royal Revolt','RoyalRevolt2','Shazam','Sidia.LiveWallpaper','SlingTV','Speed Test'
        'Spotify','TikTok','TuneInRadio','Twitter','Viber','WinZipUniversal','Wunderlist'
        'XING','2414FC7A.Viber','41038Axilesoft.ACGMediaPlayer','46928bounde.EclipseManager'
        '4DF9E0F8.Netflix','5A894077.McAfeeSecurity','613EBCEA.PolarrPhotoEditorAcademicEdition'
        '6Wunderkinder.Wunderlist','7EE7776C.LinkedInforWindows','89006A2E.AutodeskSketchBook'
        '9E2F88E3.Twitter','A278AB0D.DisneyMagicKingdoms','A278AB0D.MarchofEmpires'
        'ActiproSoftwareLLC.562882FEEB491','CAF9E577.Plex','ClearChannelRadioDigital.iHeartRadio'
        'D52A8D61.FarmVille2CountryEscape','D5EA27B7.Duolingo-LearnLanguagesforFree'
        'DB6EA5DB.CyberLinkMediaSuiteEssentials','DolbyLaboratories.DolbyAccess'
        'Drawboard.DrawboardPDF','Facebook.Facebook','Fitbit.FitbitCoach','flaregamesGmbH.RoyalRevolt2'
        'GAMELOFTSA.Asphalt8Airborne','KeeperSecurityInc.Keeper','PandoraMediaInc.29680B314EFC2'
        'SpotifyAB.SpotifyMusic','ThumbmunkeysLtd.PhototasticCollage','WinZipComputing.WinZipUniversal'
        'XINGAG.XING','5319275A.WhatsAppDesktop','BytedancePte.Ltd.TikTok','TikTokLtd.TikTok'
    )

    dbg "Removing $($BloatApps.Count) bloat packages …"
    $removed = 0
    foreach ($App in $BloatApps) {
        $pkgs = Get-AppxPackage -AllUsers -Name $App -ErrorAction SilentlyContinue
        foreach ($pkg in $pkgs) {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            $removed++
        }
        $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $App }
        foreach ($p in $prov) {
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction SilentlyContinue
        }
    }
    dbg-ok "$removed packages removed"

    # DOUBLE-CHECK
    dbg "Verifying debloat …"
    $remaining = 0
    foreach ($App in $BloatApps) {
        $pkgs = Get-AppxPackage -AllUsers -Name $App -ErrorAction SilentlyContinue
        if ($pkgs) {
            $remaining += $pkgs.Count
            foreach ($pkg in $pkgs) {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            }
        }
    }
    if ($remaining -eq 0) { dbg-ok "Debloat verified" }
    else                  { dbg-warn "$remaining still present (re-removed)" }

    # OneDrive
    dbg "Removing OneDrive …"
    taskkill /F /IM OneDrive.exe 2>$null
    Start-Sleep 2
    $od32 = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    $od64 = "$env:SystemRoot\System32\OneDriveSetup.exe"
    if (Test-Path $od32) { Start-Silent $od32 '/uninstall' 60 }
    if (Test-Path $od64) { Start-Silent $od64 '/uninstall' 60 }
    foreach ($p in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive','HKCU:\Software\Policies\Microsoft\Windows\OneDrive')) {
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
        Set-ItemProperty -Path $p -Name 'DisableOneDrive' -Value 1 -Type DWord
    }
    dbg-ok "OneDrive removed"

    # Mouse accel off
    $mKey = 'HKCU:\Control Panel\Mouse'
    if (-not (Test-Path $mKey)) { New-Item -Path $mKey -Force | Out-Null }
    Set-ItemProperty -Path $mKey -Name 'MouseSpeed' -Value '0' -Type String
    Set-ItemProperty -Path $mKey -Name 'MouseThreshold1' -Value '0' -Type String
    Set-ItemProperty -Path $mKey -Name 'MouseThreshold2' -Value '0' -Type String
    dbg-ok "Mouse accel off"

    # Dark mode
    $dKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path $dKey)) { New-Item -Path $dKey -Force | Out-Null }
    Set-ItemProperty -Path $dKey -Name 'AppsUseLightTheme' -Value 0 -Type DWord
    Set-ItemProperty -Path $dKey -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
    dbg-ok "Dark mode on"

    # Accessibility keys off
    $skKey = 'HKCU:\Control Panel\Accessibility\StickyKeys'
    if (-not (Test-Path $skKey)) { New-Item -Path $skKey -Force | Out-Null }
    Set-ItemProperty -Path $skKey -Name 'Flags' -Value '506' -Type String
    dbg-ok "Accessibility prompts off"

    # Privacy / Telemetry
    dbg "Applying privacy tweaks …"
    function Set-Reg {
        param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        if ($Type -eq 'String') { Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type String }
        else                    { Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord }
    }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Search' 'AllowCortana' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessLocation' 2
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessCamera' 2
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 1
    powercfg /hibernate off 2>$null
    [System.Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')
    [System.Environment]::SetEnvironmentVariable('DOTNET_CLI_TELEMETRY_OPTOUT', '1', 'Machine')
    dbg-ok "Privacy applied"

    # Disable services
    $svcs = @('DiagTrack','dmwappushservice','Fax','lfsvc','MapsBroker','RetailDemo','SysMain','WSearch','XblAuthManager','XboxGipSvc')
    foreach ($s in $svcs) {
        sc.exe config $s start= disabled 2>$null
        sc.exe stop $s 2>$null
    }
    dbg-ok "Services disabled"

    # Disable tasks
    $tasks = @(
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
        '\Microsoft\Windows\Feedback\Siuf\DmClient'
    )
    foreach ($t in $tasks) { schtasks /Change /TN $t /Disable 2>$null }
    dbg-ok "Tasks disabled"

    # Ultimate Performance
    $ultGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    powercfg /duplicatescheme $ultGuid 2>$null
    powercfg /setactivescheme $ultGuid 2>$null
    dbg-ok "Power plan set"

    # Explorer
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0
    Set-Reg 'HKCU:\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
    Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(Default)' '' 'String'
    dbg-ok "Explorer tweaks applied"

    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    Start-Process explorer

    Set-Stage 2
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 2 — Winget Apps (Spotify runs as non-admin user)
# ─────────────────────────────────────────────────────────────────────────────
function Stage-WingetApps {
    dbg-head "STAGE 2 — Winget Apps"

    function Install-WingetApp {
        param([string]$Id, [bool]$AsUser = $false)
        
        if ($AsUser) {
            # Spotify needs to run as non-admin user
            dbg "  $Id (non-admin user)"
            try {
                # Get current user SID
                $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                # Run winget as user via scheduled task
                $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command `"& winget install --exact --id $Id --silent --accept-package-agreements --accept-source-agreements --disable-interactivity`""
                $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
                $task = Register-ScheduledTask -TaskName "MestalSpotifyInstall" -Action $action -Principal $principal -Force
                Start-ScheduledTask -TaskName "MestalSpotifyInstall"
                Start-Sleep 30  # Wait for install
                Unregister-ScheduledTask -TaskName "MestalSpotifyInstall" -Confirm:$false
                dbg-ok "$Id installed (non-admin)"
                return $true
            } catch {
                dbg-warn "$Id non-admin install failed: $_"
                return $false
            }
        }
        
        dbg "  $Id"
        try {
            $out = & winget install --exact --id $Id --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
            $outStr = $out -join ' '
            if ($outStr -match 'Successfully installed|already installed') { 
                dbg-ok "$Id OK"
                return $true
            }
            dbg-warn "$Id — $(($out | Select-Object -Last 1))"
            return $false
        } catch { dbg-err "$Id — $_"; return $false }
    }

    $normalApps = @(
        'Valve.Steam','Discord.Discord','VideoLAN.VLC','7zip.7zip','Bitwarden.Bitwarden',
        'Python.Python.3.12','Ablaze.Floorp','Git.Git','pizzaboxer.Bloxstrap','voidtools.Everything',
        'AntibodySoftware.WizTree','EpicGames.EpicGamesLauncher',
        'Logitech.GHUB','Alex313031.Thorium.AVX2','PrismLauncher.PrismLauncher'
    )

    $ok = 0; $fail = 0
    
    # Install normal apps
    foreach ($id in $normalApps) {
        if (Install-WingetApp $id) { $ok++ } else { $fail++ }
        Start-Sleep 1
    }
    
    # Install Spotify as non-admin user
    if (Install-WingetApp 'Spotify.Spotify' $true) { $ok++ } else { $fail++ }
    Start-Process powershell -ArgumentList "-NoProfile -Command","Invoke-WebRequest -Uri 'https://download.scdn.co/SpotifySetup.exe' -OutFile '$env:TEMP\SpotifySetup.exe'; & '$env:TEMP\SpotifySetup.exe'" -Verb RunAsUser
    Start-Process powershell -ArgumentList "-NoProfile -Command","Invoke-WebRequest -Uri 'https://download01.logi.com/web/ftp/pub/techsupport/gaming/lghub_installer.exe' -OutFile '$env:TEMP\LogiHubSetup.exe'; & '$env:TEMP\LogiHubSetup.exe'" -Verb RunAsUser
    dbg-ok "$ok installed, $fail failed"
    Set-Stage 3
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 3 — Manual Apps
# ─────────────────────────────────────────────────────────────────────────────
function Stage-ManualApps {
    dbg-head "STAGE 3 — Manual Apps"
    Ensure-TempDir

    # Vencord
    $vUrl = Get-LatestAssetUrl -Owner 'Vencord' -Repo 'Installer' -Pattern 'VencordInstallerCli\.exe$'
    $vDest = Join-Path $TEMP_DIR 'VencordInstallerCli.exe'
    if ($vUrl -and (Invoke-Download $vUrl $vDest)) {
        dbg "Piping stdin to Vencord CLI"
        try {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c (echo 0 & echo y) | `"$vDest`"" -WindowStyle Hidden -PassThru
            $exited = $p.WaitForExit(120000)
            if ($exited) { dbg-ok "Vencord done" }
            else         { dbg-warn "Vencord timeout"; $p.Kill() }
        } catch { dbg-err "Vencord failed: $_" }
    }


    $tUrl = Get-LatestAssetUrl -Owner 'TCNOco' -Repo 'TcNo-Acc-Switcher' -Pattern 'Installer.*\.exe$'
    $tDest = Join-Path $TEMP_DIR 'TcNoInstaller.exe'

    if ($tUrl -and (Invoke-Download $tUrl $tDest)) {
            Start-Process -FilePath $tDest -ArgumentList '/VERYSILENT','/NORESTART' -Wait -NoNewWindow
            dbg-ok "TCNO installed"
    }

    Set-Stage 4
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 4 — GPU Drivers
# ─────────────────────────────────────────────────────────────────────────────
function Stage-GPUDrivers {
    dbg-head "STAGE 4 — GPU Drivers"
    Ensure-TempDir

    $gpu = Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
    $gpuName = if ($gpu) { $gpu.Name } else { 'UNKNOWN' }
    dbg "GPU: $gpuName"

    if ($gpuName -match 'NVIDIA|GeForce|Quadro|Tesla') {
        dbg "Fetching NVIDIA App …"
        $nvUrl = $null
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $page = Invoke-WebRequest -Uri 'https://www.nvidia.com/en-us/software/nvidia-app/' -UseBasicParsing -ErrorAction Stop
            if ($page.Content -match 'https://[^\s"''<>]*us\.download\.nvidia\.com[^\s"''<>]*\.exe') {
                $nvUrl = $Matches[0]
                dbg-ok "Scraped: $nvUrl"
            }
        } catch { dbg-warn "Scrape failed: $_" }
        if (-not $nvUrl) {
            $nvUrl = 'https://us.download.nvidia.com/nvapp/client/11.0.6.383/NVIDIA_app_v11.0.6.383.exe'
            dbg-warn "Using fallback"
        }
        $nvDest = Join-Path $TEMP_DIR 'NVIDIA_app.exe'
        if (Invoke-Download $nvUrl $nvDest) {
            Start-Silent $nvDest '-s -noreboot -noeula -nofinish' 600
            dbg-ok "NVIDIA App executed"
        }
    } elseif ($gpuName -match 'AMD|Radeon') {
        dbg-warn "AMD GPU — download manually: https://www.amd.com/en/support"
    } elseif ($gpuName -match 'Intel|Arc|Iris') {
        $intelUrl = 'https://dsadata.intel.com/installer/Intel%20Driver%20%26%20Support%20Assistant%20Installer.exe'
        $intelDest = Join-Path $TEMP_DIR 'Intel_DSA.exe'
        if (Invoke-Download $intelUrl $intelDest) {
            Start-Silent $intelDest '/quiet /norestart' 300
            dbg-ok "Intel DSA installed"
        }
    } else {
        dbg-warn "No discrete GPU — skipping"
    }

    Set-Stage 5
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 5 — Windows Activation
# ─────────────────────────────────────────────────────────────────────────────
function Stage-Activation {
    dbg-head "STAGE 5 — Windows Activation (MAS)"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $mas = Invoke-WebRequest -Uri 'https://get.activated.win' -UseBasicParsing -ErrorAction Stop
        if ($mas.Content.Length -gt 100) {
            dbg-ok "MAS downloaded"
            & ([ScriptBlock]::Create($mas.Content)) /HWID
            dbg-ok "MAS executed"
        }
    } catch { dbg-err "MAS failed: $_" }

    Set-Stage 99
}

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 99 — Cleanup + Re-enable Defender
# ─────────────────────────────────────────────────────────────────────────────
function Stage-Cleanup {
    dbg-head "STAGE 99 — Cleanup"
    
    # Re-enable Defender
    Enable-Defender
    
    Remove-Persistence
    Start-Process taskmgr.exe -WindowStyle Normal
    dbg-ok "taskmgr launched"
    Start-Sleep 2
    try {
        if (Test-Path $TEMP_DIR) {
            Remove-Item $TEMP_DIR -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    dbg-ok "Done. Log: $LOG_PATH"
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────
Ensure-TempDir
Ensure-Admin

# Disable Defender at start
Disable-Defender

Clear-Host
Write-Host '+----------------------------------------------+' -ForegroundColor Cyan
Write-Host '|   MestalWinBox                               |' -ForegroundColor Cyan
Write-Host '|   Log: %TEMP%\MestalTemp\mestal_debug.log    |' -ForegroundColor Cyan
Write-Host '+----------------------------------------------+' -ForegroundColor Cyan
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
