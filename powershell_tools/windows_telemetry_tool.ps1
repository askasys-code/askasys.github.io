# REQUIRES: Administrator Privileges
# COMPATIBILITY: PowerShell 5.1+
# CODING STANDARD: All internal comments must be written in ENGLISH.

<#
    Windows Privacy & AI Manager
    Updated: 2026-07-05
    Description: Standalone tool for deep Windows Telemetry, AI (Recall/Copilot/Intelligence/WSAIFabric), and Ads management.
#>

# ---------------------------------------------------------------------------
# INITIALIZATION & SETUP
# ---------------------------------------------------------------------------

#region Setup, Encoding & Auto-Elevation
# --- 1. GLOBAL SETTINGS ---
# Set error preference
$ErrorActionPreference = "SilentlyContinue"

# Set Console Encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Enable modern security protocols (TLS 1.2 & 1.3)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# --- 2. ADMIN SELF-ELEVATION ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "`n [!] Administrator privileges required." -ForegroundColor Yellow
    Write-Host " [!] Restarting as Administrator..." -ForegroundColor White
    
    $scriptPath = $MyInvocation.MyCommand.Definition

    try {
        # Restart the process as Admin, maintaining the current working directory
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs -WorkingDirectory $PSScriptRoot
        Exit
    } catch {
        # If the user clicks "No" on the UAC prompt
        Write-Host " [X] Elevation failed or cancelled by user." -ForegroundColor Red
        Exit
    }
}
#endregion

#region Helper Functions
function Write-Header {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "    WINDOWS AI & TELEMETRY TOOL (2026)    " -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Disable-TaskSafe {
    param($path, $name)
    try {
        $task = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
        if ($task -and $task.State -ne "Disabled") {
            Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
            Write-Host " [OK] Task Disabled: $name" -ForegroundColor DarkGray
        }
    } catch {}
}

function Disable-ServiceSafe {
    param($name)
    try {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -eq 'Running') { 
                Stop-Service -Name $name -Force -ErrorAction SilentlyContinue 
            }
            if ($svc.StartType -ne 'Disabled') {
                Set-Service -Name $name -StartupType Disabled -ErrorAction SilentlyContinue
                Write-Host " [OK] Service Disabled: $name" -ForegroundColor DarkGray
            }
        }
    } catch {}
}

function Set-RegVal {
    param($Path, $Name, $Value, $Type = "DWord")
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction SilentlyContinue
        Write-Host " [OK] Registry: $Name -> $Value" -ForegroundColor DarkGray
    } catch {
        Write-Host " [ERR] Registry: $Name" -ForegroundColor Red
    }
}
#endregion

#region Core Modules

function Get-SystemStatus {
    Write-Host "   Current System Status" -ForegroundColor White
    Write-Host "   ─────────────────────" -ForegroundColor DarkGray
    
    # 1. Telemetry
    $telemetryStatus = "Enabled/Unknown"
    try {
        $tVal = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -ErrorAction SilentlyContinue).AllowTelemetry
        if ($tVal -eq 0) { $telemetryStatus = "Disabled" }
    } catch {}

    # 2. Recall & General AI Data Analysis (Windows 11 24H2/25H2+)
    $recallStatus = "Enabled"
    try {
        $rPol = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "DisableAIDataAnalysis" -ErrorAction SilentlyContinue).DisableAIDataAnalysis
        $fabricSvc = Get-Service -Name "WSAIFabricSvc" -ErrorAction SilentlyContinue
        
        # If AI Data Analysis is blocked, or the AI Fabric Service is disabled, we consider it Disabled
        if ($rPol -eq 1 -or ($fabricSvc -and $fabricSvc.StartType -eq 'Disabled')) { 
            $recallStatus = "Disabled" 
        }
    } catch {}

    # 3. Copilot & Windows Intelligence
    $copilotStatus = "Enabled"
    try {
        $cVal = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -ErrorAction SilentlyContinue).TurnOffWindowsCopilot
        if ($cVal -eq 1) { $copilotStatus = "Disabled" }
    } catch {}

    # 4. Ads/Suggestions
    $adsStatus = "Enabled"
    try {
        $aVal = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -ErrorAction SilentlyContinue).DisableWindowsConsumerFeatures
        if ($aVal -eq 1) { $adsStatus = "Disabled" }
    } catch {}

    Write-Host "   Telemetry  : " -NoNewline -ForegroundColor Gray
    if($telemetryStatus -eq "Disabled"){ Write-Host "Disabled" -ForegroundColor Green } else { Write-Host $telemetryStatus -ForegroundColor Red }

    Write-Host "   Recall/AI  : " -NoNewline -ForegroundColor Gray
    if($recallStatus -eq "Disabled"){ Write-Host "Disabled" -ForegroundColor Green } else { Write-Host $recallStatus -ForegroundColor Red }

    Write-Host "   Copilot    : " -NoNewline -ForegroundColor Gray
    if($copilotStatus -eq "Disabled"){ Write-Host "Disabled" -ForegroundColor Green } else { Write-Host "Enabled" -ForegroundColor Red }

    Write-Host "   Sys Ads    : " -NoNewline -ForegroundColor Gray
    if($adsStatus -eq "Disabled"){ Write-Host "Disabled" -ForegroundColor Green } else { Write-Host "Enabled" -ForegroundColor Yellow }
    Write-Host ""
}

function Apply-TelemetryFix {
    Write-Host "`n=== Disabling Telemetry & Data Collection ===" -ForegroundColor Cyan
    
    # 1. Services
    # PcaSvc (Program Compatibility Assistant) collects app usage telemetry.
    # MapsBroker (Downloaded Maps Manager) handles offline maps download and transmits background telemetry.
    $services = @("DiagTrack", "dmwappushservice", "diagnosticshub.standardcollector.service", "diagsvc", "wersvc", "wercplsupport", "PcaSvc", "MapsBroker")
    foreach ($s in $services) { Disable-ServiceSafe -name $s }

    # 2. Scheduled Tasks (Aggressive 2026 List)
    $tasks = @(
        @("\Microsoft\Windows\Device Information\", "Device"),
        @("\Microsoft\Windows\Device Information\", "Device User"),
        @("\Microsoft\Windows\ErrorDetails\", "EnableErrorDetailsUpdate"),
        @("\Microsoft\Windows\Windows Error Reporting\", "QueueReporting"),
        @("\Microsoft\Windows\Application Experience\", "Microsoft Compatibility Appraiser"),
        @("\Microsoft\Windows\Application Experience\", "ProgramDataUpdater"),
        @("\Microsoft\Windows\Application Experience\", "StartupAppTask"),
        @("\Microsoft\Windows\Customer Experience Improvement Program\", "Consolidator"),
        @("\Microsoft\Windows\Customer Experience Improvement Program\", "UsbCeip"),
        @("\Microsoft\Windows\Customer Experience Improvement Program\", "Uploader"),
        @("\Microsoft\Windows\Autochk\", "Proxy"),
        @("\Microsoft\Windows\CloudExperienceHost\", "CreateObjectTask"),
        @("\Microsoft\Windows\DiskDiagnostic\", "Microsoft-Windows-DiskDiagnosticDataCollector")
    )
    foreach ($t in $tasks) { Disable-TaskSafe -path $t[0] -name $t[1] }

    # 3. Registry Policies
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "MaxTelemetryAllowed" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "LimitEnhancedDiagnosticDataWindowsInsider" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowDesktopAnalyticsProcessing" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowDeviceNameInTelemetry" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowCommercialDataPipeline" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "DisableOneSettingsDownloads" 1
    Set-RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform" "NoGenTicket" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" 1

    # 4. Block Executables (Debugger Trick)
    # Block DeviceCensus and CompatTelRunner (Microsoft Compatibility Telemetry) from running
    Set-RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe" "Debugger" "%SYSTEMROOT%\System32\taskkill.exe" "String"
    Set-RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CompatTelRunner.exe" "Debugger" "%SYSTEMROOT%\System32\taskkill.exe" "String"

    Write-Host "SUCCESS: Telemetry neutralized." -ForegroundColor Green
}

function Apply-AIFix {
    Write-Host "`n=== Disabling AI Features (Recall, Copilot & Windows Intelligence) ===" -ForegroundColor Cyan
    
    # 1. Disable Windows AI Fabric Service (WSAIFabricSvc)
    # This prevents 'WorkloadsSessionHost.exe' from starting and consuming gigabytes of system RAM in 24H2+
    Disable-ServiceSafe -name "WSAIFabricSvc"

    # 2. Recall Optional Feature (Windows 11 24H2+)
    try {
        $recallFeature = Get-WindowsOptionalFeature -Online -FeatureName "Recall" -ErrorAction SilentlyContinue
        if ($recallFeature -and $recallFeature.State -eq "Enabled") {
            Write-Host " Disabling 'Recall' optional feature (may take a moment)..." -ForegroundColor Yellow
            Disable-WindowsOptionalFeature -Online -FeatureName "Recall" -NoRestart -ErrorAction SilentlyContinue | Out-Null
            Write-Host " [OK] Recall Feature Removed." -ForegroundColor Green
        }
    } catch { Write-Host " [i] Recall feature not present on this build." -ForegroundColor DarkGray }

    # 3. Windows AI Policy (Blocks AI snapshotting, analysis and context actions like Click to Do)
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableClickToDo" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableRecallDataProviders" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableRemoteAgentConnectors" 1

    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI" "DisableClickToDo" 1
    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI" "DisableRecallDataProviders" 1
    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI" "DisableRemoteAgentConnectors" 1

    # 4. Windows Intelligence (New in 2025/2026)
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Intelligence" "DisableWindowsIntelligence" 1
    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\Windows Intelligence" "DisableWindowsIntelligence" 1

    # 5. Copilot Configuration
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    
    # Button and AI Actions visibility in Explorer
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton" 0
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowAIActions" 0
    
    # Edge Sidebar (Copilot host)
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "HubsSidebarEnabled" 0

    # 6. Remove Copilot Appx Package
    Write-Host " Removing Copilot Appx packages (if present)..." -ForegroundColor Yellow
    Get-AppxPackage -AllUsers "*Microsoft.Windows.Ai.Copilot*" -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    
    Write-Host "SUCCESS: AI integrations disabled." -ForegroundColor Green
}

function Apply-AdsFix {
    Write-Host "`n=== Disabling Windows Ads, Suggestions & Web Search ===" -ForegroundColor Cyan

    # 1. Start Menu Ads, Suggestions & Widgets
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableThirdPartySuggestions" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableCloudOptimizedContent" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableSoftLanding" 1
    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\CloudContent" "DisableWindowsSpotlightFeatures" 1
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SystemPaneSuggestionsEnabled" 0
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-338387Enabled" 0 # Start Menu
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_IrisRecommendations" 0

    # Disable Taskbar Widgets & News completely
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0

    # 2. Settings App Suggestions & Nags ("Finish setting up your device" & Microsoft Edge suggestions)
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled" 0
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-310093Enabled" 0 # Welcome Experience
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-353698Enabled" 0 # Settings Ads
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-338389Enabled" 0 # App Suggestions
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SilentInstalledAppsEnabled" 0
    
    # Disable Microsoft Edge Default Browser Nagging
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "DefaultBrowserSettingEnabled" 0

    # 3. Search Highlights & Bing in Search
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableSearchBoxSuggestions" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 0
    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1
    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" 0

    # 4. Lock Screen Tips
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "RotatingLockScreenEnabled" 0
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "RotatingLockScreenOverlayEnabled" 0

    Write-Host "SUCCESS: Ads and Nags disabled." -ForegroundColor Green
}

function Restore-Defaults {
    Write-Host "`n=== Reverting Changes (Restoring Defaults) ===" -ForegroundColor Magenta
    
    $confirm = Read-Host "Are you sure? This will re-enable Telemetry and AI features. (Y/N)"
    if ($confirm -ne "Y" -and $confirm -ne "y") { return }

    # Restore Telemetry Services
    Set-Service -Name "DiagTrack" -StartupType Automatic -ErrorAction SilentlyContinue
    Set-Service -Name "MapsBroker" -StartupType Automatic -ErrorAction SilentlyContinue
    
    # Clean up Telemetry Registry
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "MaxTelemetryAllowed" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "LimitEnhancedDiagnosticDataWindowsInsider" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowDesktopAnalyticsProcessing" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowDeviceNameInTelemetry" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowCommercialDataPipeline" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "DisableOneSettingsDownloads" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowTelemetry" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform" -Name "NoGenTicket" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" -Name "Disabled" -ErrorAction SilentlyContinue

    # Restore Blocked Executables
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe" -Name "Debugger" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CompatTelRunner.exe" -Name "Debugger" -ErrorAction SilentlyContinue

    # Restore AI Services & Components
    Set-Service -Name "WSAIFabricSvc" -StartupType Manual -ErrorAction SilentlyContinue
    
    # Restore AI Optional Feature (Optional, user can also re-enable manually)
    try {
        $recallFeature = Get-WindowsOptionalFeature -Online -FeatureName "Recall" -ErrorAction SilentlyContinue
        if ($recallFeature -and $recallFeature.State -eq "Disabled") {
            Write-Host " Re-enabling 'Recall' optional feature..." -ForegroundColor Yellow
            Enable-WindowsOptionalFeature -Online -FeatureName "Recall" -NoRestart -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}

    # Clean up AI Registry
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -ErrorAction SilentlyContinue
    
    $aiKeys = @("DisableAIDataAnalysis", "DisableClickToDo", "DisableRecallDataProviders", "DisableRemoteAgentConnectors")
    foreach ($key in $aiKeys) {
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name $key -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI" -Name $key -ErrorAction SilentlyContinue
    }
    
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Intelligence" -Name "DisableWindowsIntelligence" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Windows Intelligence" -Name "DisableWindowsIntelligence" -ErrorAction SilentlyContinue
    
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowCopilotButton" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowAIActions" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "HubsSidebarEnabled" -ErrorAction SilentlyContinue

    # Restore Ads & Suggetions Registry
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableThirdPartySuggestions" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableCloudOptimizedContent" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableSoftLanding" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsSpotlightFeatures" -ErrorAction SilentlyContinue
    
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "DefaultBrowserSettingEnabled" -ErrorAction SilentlyContinue
    
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "DisableSearchBoxSuggestions" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "ConnectedSearchUseWeb" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -ErrorAction SilentlyContinue

    Write-Host "Restoration commands sent. A reboot is required." -ForegroundColor Yellow
}

#endregion

#region Main Menu Loop
do {
    Write-Header
    Get-SystemStatus
    
    Write-Host "1. Disable Telemetry & Data Collection (Deep Clean)" -ForegroundColor Yellow
    Write-Host "2. Disable AI Features (Recall, Copilot, Intelligence)" -ForegroundColor Yellow
    Write-Host "3. Disable Windows Ads, Suggestions & Bing Search" -ForegroundColor Yellow
    Write-Host "4. APPLY ALL (Recommended for Privacy)" -ForegroundColor Green
    Write-Host "5. Revert Changes (Restore Defaults)" -ForegroundColor Red
    Write-Host ""
    Write-Host "0. Exit" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host "Select Option"

    switch ($choice) {
        "1" { Apply-TelemetryFix; Start-Sleep 2 }
        "2" { Apply-AIFix; Start-Sleep 2 }
        "3" { Apply-AdsFix; Start-Sleep 2 }
        "4" { 
            Apply-TelemetryFix
            Apply-AIFix
            Apply-AdsFix
            Write-Host "`nALL PRIVACY TWEAKS APPLIED." -ForegroundColor Green -BackgroundColor Black
            Write-Host "Please RESTART your computer to ensure all policies take effect." -ForegroundColor Cyan
            Pause
        }
        "5" { Restore-Defaults; Pause }
        "0" { exit }
        default { Write-Host "Invalid Selection" -ForegroundColor Red; Start-Sleep 1 }
    }

} while ($true)
#endregion