<#
    WinCare Privacy & AI Manager (Standalone)
    Source: Extracted and Enhanced from WinCare v2.9
    Updated: 2026-02-14
    Author: askasys (Optimized by AI)
    Description: Standalone tool for Windows Telemetry, AI (Recall/Copilot), and Ads management.
#>

# Force UTF-8 Encoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Check for Administrator Privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Definition)`"" -Verb RunAs
    exit
}

#region Helper Functions
function Write-Header {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   WINCARE PRIVACY & AI MANAGER (2026)    " -ForegroundColor White
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
        $sVal = (Get-Service "DiagTrack" -ErrorAction SilentlyContinue).StartType
        if ($tVal -eq 0 -and $sVal -eq "Disabled") { $telemetryStatus = "Disabled" }
    } catch {}

    # 2. Recall (AI Snapshot)
    $recallStatus = "Not Found/Disabled"
    try {
        # Check Optional Feature
        $rFeat = Get-WindowsOptionalFeature -Online -FeatureName "Recall" -ErrorAction SilentlyContinue
        # Check Policy
        $rPol = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "DisableAIDataAnalysis" -ErrorAction SilentlyContinue).DisableAIDataAnalysis
        
        if (($rFeat -and $rFeat.State -eq "Enabled") -or ($rPol -ne 1)) { 
            $recallStatus = "Enabled (Risk)" 
        } else {
            $recallStatus = "Disabled"
        }
    } catch {}

    # 3. Copilot
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

    Write-Host "   Recall AI  : " -NoNewline -ForegroundColor Gray
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
    $services = @("DiagTrack", "dmwappushservice", "diagnosticshub.standardcollector.service", "diagsvc", "wersvc", "wercplsupport")
    foreach ($s in $services) { Disable-ServiceSafe -name $s }

    # 2. Scheduled Tasks (Expanded list)
    Disable-TaskSafe -path "\Microsoft\Windows\Device Information\" -name "Device"
    Disable-TaskSafe -path "\Microsoft\Windows\Device Information\" -name "Device User"
    Disable-TaskSafe -path "\Microsoft\Windows\ErrorDetails\" -name "EnableErrorDetailsUpdate"
    Disable-TaskSafe -path "\Microsoft\Windows\Windows Error Reporting\" -name "QueueReporting"
    Disable-TaskSafe -path "\Microsoft\Windows\Application Experience\" -name "Microsoft Compatibility Appraiser"
    Disable-TaskSafe -path "\Microsoft\Windows\Application Experience\" -name "ProgramDataUpdater"
    Disable-TaskSafe -path "\Microsoft\Windows\Customer Experience Improvement Program\" -name "Consolidator"
    Disable-TaskSafe -path "\Microsoft\Windows\Customer Experience Improvement Program\" -name "UsbCeip"

    # 3. Registry Policies
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowDesktopAnalyticsProcessing" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowDeviceNameInTelemetry" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowCommercialDataPipeline" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "DisableOneSettingsDownloads" 1
    Set-RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform" "NoGenTicket" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" 1

    # 4. Block DeviceCensus.exe (Debugger Trick)
    $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe"
    Set-RegVal $ifeoPath "Debugger" "%SYSTEMROOT%\System32\taskkill.exe" "String"

    Write-Host "SUCCESS: Telemetry neutralized." -ForegroundColor Green
}

function Apply-AIFix {
    Write-Host "`n=== Disabling AI Features (Recall & Copilot) ===" -ForegroundColor Cyan
    
    # 1. Recall (Windows 11 24H2+)
    try {
        if (Get-WindowsOptionalFeature -Online -FeatureName "Recall" -ErrorAction SilentlyContinue) {
            Write-Host "Disabling 'Recall' optional feature..." -ForegroundColor Yellow
            Disable-WindowsOptionalFeature -Online -FeatureName "Recall" -NoRestart -ErrorAction SilentlyContinue | Out-Null
            Write-Host " [OK] Recall Feature Removed." -ForegroundColor Green
        }
    } catch { Write-Host "Recall feature not present on this build." -ForegroundColor DarkGray }

    # 2. Windows AI Policy (New 2025/2026)
    # Blocks AI snapshotting and analysis
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1

    # 3. Copilot
    # Policy: Turn off Copilot
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    
    # Button visibility
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton" 0
    
    # Edge Sidebar (Copilot host)
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "HubsSidebarEnabled" 0

    Write-Host "SUCCESS: AI integrations disabled." -ForegroundColor Green
}

function Apply-AdsFix {
    Write-Host "`n=== Disabling Windows Ads & Recommendations ===" -ForegroundColor Cyan

    # 1. Start Menu Ads & Recommendations
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SystemPaneSuggestionsEnabled" 0
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-338387Enabled" 0 # Start Menu
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_IrisRecommendations" 0

    # 2. Settings App Suggestions ("Finish setting up your device")
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled" 0
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-310093Enabled" 0 # Welcome Experience
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-353698Enabled" 0 # Settings Ads

    # 3. Search Highlights (Bing in Search)
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableSearchBoxSuggestions" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 0
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" 0

    # 4. Lock Screen Tips
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "RotatingLockScreenEnabled" 0
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "RotatingLockScreenOverlayEnabled" 0

    Write-Host "SUCCESS: Ads and Nags disabled." -ForegroundColor Green
}

function Restore-Defaults {
    Write-Host "`n=== Reverting Changes (Restoring Defaults) ===" -ForegroundColor Magenta
    
    $confirm = Read-Host "Are you sure? This will re-enable Telemetry and AI features. (Y/N)"
    if ($confirm -ne "Y") { return }

    # Telemetry
    Set-Service -Name "DiagTrack" -StartupType Automatic -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe" -Name "Debugger" -ErrorAction SilentlyContinue

    # AI
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "DisableAIDataAnalysis" -ErrorAction SilentlyContinue
    
    # Ads
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -ErrorAction SilentlyContinue

    Write-Host "Restoration commands sent. A reboot is required." -ForegroundColor Yellow
}

#endregion

#region Main Menu Loop
do {
    Write-Header
    Get-SystemStatus
    
    Write-Host "1. Disable Telemetry & Data Collection (Deep Clean)" -ForegroundColor Yellow
    Write-Host "2. Disable AI Features (Recall, Copilot, Edge AI)" -ForegroundColor Yellow
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

<#
    WinCare Privacy & AI Manager (Standalone)
    Source: Extracted and Enhanced from WinCare v2.9
    Updated: 2026-02-14
    Author: askasys (Optimized by AI)
    Description: Standalone tool for Windows Telemetry, AI (Recall/Copilot), and Ads management.
#>

# Force UTF-8 Encoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Check for Administrator Privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Definition)`"" -Verb RunAs
    exit
}

#region Helper Functions
function Write-Header {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   WINCARE PRIVACY & AI MANAGER (2026)    " -ForegroundColor White
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
        $sVal = (Get-Service "DiagTrack" -ErrorAction SilentlyContinue).StartType
        if ($tVal -eq 0 -and $sVal -eq "Disabled") { $telemetryStatus = "Disabled" }
    } catch {}

    # 2. Recall (AI Snapshot)
    $recallStatus = "Not Found/Disabled"
    try {
        # Check Optional Feature
        $rFeat = Get-WindowsOptionalFeature -Online -FeatureName "Recall" -ErrorAction SilentlyContinue
        # Check Policy
        $rPol = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "DisableAIDataAnalysis" -ErrorAction SilentlyContinue).DisableAIDataAnalysis
        
        if (($rFeat -and $rFeat.State -eq "Enabled") -or ($rPol -ne 1)) { 
            $recallStatus = "Enabled (Risk)" 
        } else {
            $recallStatus = "Disabled"
        }
    } catch {}

    # 3. Copilot
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

    Write-Host "   Recall AI  : " -NoNewline -ForegroundColor Gray
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
    $services = @("DiagTrack", "dmwappushservice", "diagnosticshub.standardcollector.service", "diagsvc", "wersvc", "wercplsupport")
    foreach ($s in $services) { Disable-ServiceSafe -name $s }

    # 2. Scheduled Tasks (Expanded list)
    Disable-TaskSafe -path "\Microsoft\Windows\Device Information\" -name "Device"
    Disable-TaskSafe -path "\Microsoft\Windows\Device Information\" -name "Device User"
    Disable-TaskSafe -path "\Microsoft\Windows\ErrorDetails\" -name "EnableErrorDetailsUpdate"
    Disable-TaskSafe -path "\Microsoft\Windows\Windows Error Reporting\" -name "QueueReporting"
    Disable-TaskSafe -path "\Microsoft\Windows\Application Experience\" -name "Microsoft Compatibility Appraiser"
    Disable-TaskSafe -path "\Microsoft\Windows\Application Experience\" -name "ProgramDataUpdater"
    Disable-TaskSafe -path "\Microsoft\Windows\Customer Experience Improvement Program\" -name "Consolidator"
    Disable-TaskSafe -path "\Microsoft\Windows\Customer Experience Improvement Program\" -name "UsbCeip"

    # 3. Registry Policies
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowDesktopAnalyticsProcessing" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowDeviceNameInTelemetry" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowCommercialDataPipeline" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "DisableOneSettingsDownloads" 1
    Set-RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry" 0
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform" "NoGenTicket" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" 1

    # 4. Block DeviceCensus.exe (Debugger Trick)
    $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe"
    Set-RegVal $ifeoPath "Debugger" "%SYSTEMROOT%\System32\taskkill.exe" "String"

    Write-Host "SUCCESS: Telemetry neutralized." -ForegroundColor Green
}

function Apply-AIFix {
    Write-Host "`n=== Disabling AI Features (Recall & Copilot) ===" -ForegroundColor Cyan
    
    # 1. Recall (Windows 11 24H2+)
    try {
        if (Get-WindowsOptionalFeature -Online -FeatureName "Recall" -ErrorAction SilentlyContinue) {
            Write-Host "Disabling 'Recall' optional feature..." -ForegroundColor Yellow
            Disable-WindowsOptionalFeature -Online -FeatureName "Recall" -NoRestart -ErrorAction SilentlyContinue | Out-Null
            Write-Host " [OK] Recall Feature Removed." -ForegroundColor Green
        }
    } catch { Write-Host "Recall feature not present on this build." -ForegroundColor DarkGray }

    # 2. Windows AI Policy (New 2025/2026)
    # Blocks AI snapshotting and analysis
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1

    # 3. Copilot
    # Policy: Turn off Copilot
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    Set-RegVal "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    
    # Button visibility
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton" 0
    
    # Edge Sidebar (Copilot host)
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "HubsSidebarEnabled" 0

    Write-Host "SUCCESS: AI integrations disabled." -ForegroundColor Green
}

function Apply-AdsFix {
    Write-Host "`n=== Disabling Windows Ads & Recommendations ===" -ForegroundColor Cyan

    # 1. Start Menu Ads & Recommendations
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SystemPaneSuggestionsEnabled" 0
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-338387Enabled" 0 # Start Menu
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_IrisRecommendations" 0

    # 2. Settings App Suggestions ("Finish setting up your device")
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled" 0
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-310093Enabled" 0 # Welcome Experience
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-353698Enabled" 0 # Settings Ads

    # 3. Search Highlights (Bing in Search)
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableSearchBoxSuggestions" 1
    Set-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 0
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" 0

    # 4. Lock Screen Tips
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "RotatingLockScreenEnabled" 0
    Set-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "RotatingLockScreenOverlayEnabled" 0

    Write-Host "SUCCESS: Ads and Nags disabled." -ForegroundColor Green
}

function Restore-Defaults {
    Write-Host "`n=== Reverting Changes (Restoring Defaults) ===" -ForegroundColor Magenta
    
    $confirm = Read-Host "Are you sure? This will re-enable Telemetry and AI features. (Y/N)"
    if ($confirm -ne "Y") { return }

    # Telemetry
    Set-Service -Name "DiagTrack" -StartupType Automatic -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe" -Name "Debugger" -ErrorAction SilentlyContinue

    # AI
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "DisableAIDataAnalysis" -ErrorAction SilentlyContinue
    
    # Ads
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -ErrorAction SilentlyContinue

    Write-Host "Restoration commands sent. A reboot is required." -ForegroundColor Yellow
}

#endregion

#region Main Menu Loop
do {
    Write-Header
    Get-SystemStatus
    
    Write-Host "1. Disable Telemetry & Data Collection (Deep Clean)" -ForegroundColor Yellow
    Write-Host "2. Disable AI Features (Recall, Copilot, Edge AI)" -ForegroundColor Yellow
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

<#
    RIASSUNTO APPLICAZIONI (Italiano):
    
    Ho estratto la funzione 12 (Privacy) dallo script originale e l'ho trasformata in un tool standalone completo.
    Ho aggiornato le logiche inserendo funzionalità per il 2026/Windows 11 24H2+:
    
    1.  **Recall (AI Snapshot):** Aggiunta la rimozione della feature opzionale e la chiave di registro `DisableAIDataAnalysis` (WindowsAI) per bloccare l'analisi dati locale.
    2.  **Copilot:** Disattivazione tramite policy machine-wide, user-wide e rimozione integrazione Sidebar di Edge.
    3.  **Ads & Nags:** Aggiunta una nuova sezione per rimuovere:
        - Pubblicità nel menu Start (Consumer Features).
        - Suggerimenti "Termina configurazione dispositivo" (Settings Nag).
        - Ricerca Bing nel menu Start (Search Highlights).
    4.  **Telemetry:** Mantenuta la logica "Deep Clean" originale (Servizi + Task + Blocco Registry) ottimizzandola.
    5.  **Interfaccia:** Creata una dashboard che mostra lo stato attuale (Enabled/Disabled) prima di agire.
#>