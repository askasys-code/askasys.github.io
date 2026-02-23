# REQUIRES: Administrator Privileges
# COMPATIBILITY: PowerShell 5.1+
# CODING STANDARD: All internal comments must be written in ENGLISH.

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
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
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

function Get-NvidiaSmi {
    $path = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    if ($path) { return $path.Source }
    $defaultPath = "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    if (Test-Path $defaultPath) { return $defaultPath }
    return $null
}

function Get-InstalledDriverInfo {
    param($SmiPath)
    try {
        $data = & $SmiPath --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits
        if ($data -is [array]) { $data = $data[0] }
        $parts = $data -split ',\s*'
        return @{ Name=$parts[0]; Version=$parts[1]; VRAM=$parts[2] }
    } catch {
        return @{ Name="Unknown Device"; Version="0.00"; VRAM="0" }
    }
}

function Get-LatestDriverFromTPU {
    Write-Host "Checking TechPowerUp for latest drivers..." -ForegroundColor DarkGray
    $url = "https://www.techpowerup.com/download/nvidia-geforce-graphics-drivers/"
    try {
        $req = Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -TimeoutSec 5
        if ($req.Content -match 'NVIDIA GeForce Graphics Drivers\s+(\d{3}\.\d{2})') { return $matches[1] }
        return "Unknown"
    } catch { return "Connection Error" }
}

# --- WINDOWS GRAPHICS SETTINGS CHECKS ---

function Get-HagsStatus {
    # HwSchMode: 2 = On, 1 = Off
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    $name = "HwSchMode"
    try {
        $val = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
        if ($val -eq 2) { return $true }
    } catch {}
    return $false
}

function Get-VrrStatus {
    # VRR is stored in a string value within UserGpuPreferences in HKCU.
    # If the key contains "VRROptimizeEnable=1", it is Explicitly ON.
    # If missing, Windows might default to ON, but script reads Explicit state.
    $path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    $name = "DirectXUserGlobalSettings"
    try {
        $val = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
        if ($null -ne $val -and $val -match "VRROptimizeEnable=1") {
            return $true
        }
    } catch {}
    return $false
}

function Get-TelemetryStatus {
    $tasks = @("NvTmMon", "NvTmRep", "NvTmRepOnLogon", "NvProfileUpdaterOnLogon")
    foreach ($t in $tasks) {
        $obj = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        if ($obj -and $obj.State -ne "Disabled") {
            return $true # At least one is enabled
        }
    }
    return $false # All are disabled or not found
}

function Get-DlssIndicatorStatus {
    $path = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore"
    $name = "ShowDlssIndicator"
    try {
        $val = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
        # 1024 decimal is 0x400 hex
        if ($val -eq 1024) { return $true }
    } catch {}
    return $false
}


# --- MONITORING FUNCTIONS ---

function Show-Dashboard {
    param($SmiPath)
    try { & $SmiPath -L | Out-Null } catch { Write-Host "NVIDIA-SMI failed." -ForegroundColor Red; Pause; return }
    $running = $true
    $deg = [char]0x00B0 

    Clear-Host
    while ($running) {
        [Console]::SetCursorPosition(0,0)
        Write-Host "=== NVIDIA HARDWARE MONITOR ===" -ForegroundColor Cyan -BackgroundColor DarkBlue
        Write-Host " Press '0' to return to menu.  " -ForegroundColor Gray -BackgroundColor Black
        Write-Host "-------------------------------" -ForegroundColor DarkCyan
        
        try {
            $cmdOutput = & $SmiPath --query-gpu=temperature.gpu,fan.speed,power.draw,power.limit,utilization.gpu,memory.used,memory.total,clocks.gr,clocks.mem --format=csv,noheader,nounits
            if ($cmdOutput -is [array]) { $cmdOutput = $cmdOutput[0] }
            $stats = $cmdOutput -split ',' | ForEach-Object { $_.Trim() }
            
            $GetVal = { param($idx) if ($stats.Count -gt $idx -and $stats[$idx] -ne "[Not Supported]") { return $stats[$idx] } else { return "0" } }

            $Temp    = &$GetVal 0
            $Fan     = &$GetVal 1
            $PwrDraw = &$GetVal 2
            $PwrLim  = &$GetVal 3
            $GpuLoad = &$GetVal 4
            $MemUsed = &$GetVal 5 
            $MemTot  = &$GetVal 6 
            $ClkCore = &$GetVal 7
            $ClkMem  = &$GetVal 8

            # Conversions
            $MemUsedGB = [math]::Round([double]$MemUsed / 1024, 2)
            $MemTotGB  = [math]::Round([double]$MemTot / 1024, 0)

            # RENDER
            Write-Host " GPU Temp      : " -NoNewline
            if ([int]$Temp -gt 80) { Write-Host "$Temp $deg`C" -ForegroundColor Red } else { Write-Host "$Temp $deg`C" -ForegroundColor Green }
            
            Write-Host " Fan Speed     : " -NoNewline; Write-Host "$Fan %" -ForegroundColor Cyan
            Write-Host " Power Usage   : " -NoNewline; Write-Host "$PwrDraw W / $PwrLim W" -ForegroundColor Yellow
            Write-Host " GPU Core Load : " -NoNewline; Write-Host "$GpuLoad %" -ForegroundColor Magenta
            
            Write-Host " VRAM Usage    : " -NoNewline; Write-Host "$MemUsedGB GB / $MemTotGB GB" -ForegroundColor White
            
            Write-Host " Core Clock    : " -NoNewline; Write-Host "$ClkCore MHz" -ForegroundColor DarkGray
            Write-Host " Mem Clock     : " -NoNewline; Write-Host "$ClkMem MHz" -ForegroundColor DarkGray
            
            Write-Host "-------------------------------" -ForegroundColor DarkCyan
            Write-Host " Last Update: $(Get-Date -Format 'HH:mm:ss') " -ForegroundColor DarkGray
            
        } catch { Write-Host "Reading sensors..." -ForegroundColor Red }

        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.KeyChar -eq '0') { $running = $false }
        }
        Start-Sleep -Milliseconds 1000
    }
}

# --- SETTINGS TOGGLES ---

function Toggle-HAGS {
    # Hardware-Accelerated GPU Scheduling
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    $name = "HwSchMode"
    $status = Get-HagsStatus
    
    # Ensure path exists
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }

    if ($status) {
        # Turn OFF (Value 1)
        Set-ItemProperty -Path $path -Name $name -Value 1 -PropertyType DWord -Force
        Write-Host "`n [TOGGLE] HAGS set to DISABLED. Reboot Required." -ForegroundColor Yellow
    } else {
        # Turn ON (Value 2)
        Set-ItemProperty -Path $path -Name $name -Value 2 -PropertyType DWord -Force
        Write-Host "`n [TOGGLE] HAGS set to ENABLED. Reboot Required." -ForegroundColor Green
    }
    Start-Sleep -Seconds 1.5
}

function Toggle-VRR {
    # Variable Refresh Rate (User Preference String in HKCU)
    $path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    $name = "DirectXUserGlobalSettings"
    
    # Ensure key exists
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }

    # Read current string value safely
    $currentVal = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
    if ($null -eq $currentVal) { $currentVal = "" }
    
    # Check status using the Getter
    $status = Get-VrrStatus

    if ($status) {
        # DISABLE: Replace =1 with =0
        if ($currentVal -match "VRROptimizeEnable=1") {
            $newVal = $currentVal -replace "VRROptimizeEnable=1", "VRROptimizeEnable=0"
            Set-ItemProperty -Path $path -Name $name -Value $newVal -Type String -Force
        } else {
            # Fallback if parsing failed but logic said true
            $newVal = "$currentVal;VRROptimizeEnable=0;" -replace ";;", ";"
            Set-ItemProperty -Path $path -Name $name -Value $newVal -Type String -Force
        }
        Write-Host "`n [TOGGLE] VRR set to DISABLED. Reboot Required." -ForegroundColor Yellow
    } else {
        # ENABLE: Replace =0 with =1 or Append if missing
        if ($currentVal -match "VRROptimizeEnable=0") {
            $newVal = $currentVal -replace "VRROptimizeEnable=0", "VRROptimizeEnable=1"
            Set-ItemProperty -Path $path -Name $name -Value $newVal -Type String -Force
        } elseif ($currentVal -match "VRROptimizeEnable=1") {
            # Already enabled in string, maybe glitch? Force write anyway.
            Set-ItemProperty -Path $path -Name $name -Value $currentVal -Type String -Force
        } else {
            # Not present, append it. Clean up double semicolons.
            $newVal = "$currentVal;VRROptimizeEnable=1;" -replace ";;", ";"
            if ($newVal.StartsWith(";")) { $newVal = $newVal.Substring(1) }
            Set-ItemProperty -Path $path -Name $name -Value $newVal -Type String -Force
        }
        Write-Host "`n [TOGGLE] VRR set to ENABLED. Reboot Required." -ForegroundColor Green
    }
    Start-Sleep -Seconds 1.5
}

function Toggle-Telemetry {
    $tasks = @("NvTmMon", "NvTmRep", "NvTmRepOnLogon", "NvProfileUpdaterOnLogon")
    $status = Get-TelemetryStatus

    if ($status) {
        # Disable
        foreach ($t in $tasks) {
            $obj = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            if ($obj) { Disable-ScheduledTask -TaskName $t | Out-Null }
        }
        Write-Host "`n [TOGGLE] NVIDIA Telemetry Tasks DISABLED." -ForegroundColor Green
    } else {
        # Enable
        foreach ($t in $tasks) {
            $obj = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            if ($obj) { Enable-ScheduledTask -TaskName $t | Out-Null }
        }
        Write-Host "`n [TOGGLE] NVIDIA Telemetry Tasks ENABLED." -ForegroundColor Red
    }
    Start-Sleep -Seconds 1
}

function Toggle-DlssIndicator {
    $path = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore"
    $name = "ShowDlssIndicator"
    $status = Get-DlssIndicatorStatus

    # Ensure path exists
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }

    if ($status) {
        # Turn OFF
        Set-ItemProperty -Path $path -Name $name -Value 0 -Type DWord -Force
        Write-Host "`n [TOGGLE] DLSS Overlay has been DISABLED." -ForegroundColor Yellow
    } else {
        # Turn ON
        Set-ItemProperty -Path $path -Name $name -Value 1024 -Type DWord -Force
        Write-Host "`n [TOGGLE] DLSS Overlay has been ENABLED." -ForegroundColor Green
    }
    Start-Sleep -Seconds 1
}

function Disable-GameBarWriter {
    Clear-Host
    Write-Host "=== Disable Game Bar Presence Writer ===" -ForegroundColor Cyan
    Write-Host "Fixes conflicts between Xbox overlay and NVIDIA overlay." -ForegroundColor Gray
    
    try {
        # 1. Registry Policies
        $reg = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
        if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
        Set-ItemProperty -Path $reg -Name "AllowGameDVR" -Value 0 -Type DWord -Force
        
        $regUser = "HKCU:\System\GameConfigStore"
        if (-not (Test-Path $regUser)) { New-Item -Path $regUser -Force | Out-Null }
        Set-ItemProperty -Path $regUser -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force

        # 2. Stop Process
        $proc = Get-Process "GameBarPresenceWriter" -ErrorAction SilentlyContinue
        if ($proc) { 
            Stop-Process -InputObject $proc -Force
            Write-Host "Process terminated." -ForegroundColor Green
        }
        
        Write-Host "Game Bar Writer disabled via Registry." -ForegroundColor Green
        Write-Host "Reboot recommended." -ForegroundColor Magenta
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause
}

function Clean-Caches {
    Clear-Host
    Write-Host "=== NVIDIA CACHE CLEANUP ===" -ForegroundColor Cyan
    Write-Host "You will be asked to confirm each action." -ForegroundColor Gray
    Write-Host ""
    
    $targets = @(
        @{ Path="$env:LOCALAPPDATA\NVIDIA\DXCache"; Desc="DirectX Cache" }
        @{ Path="$env:LOCALAPPDATA\NVIDIA\GLCache"; Desc="OpenGL Cache" }
        @{ Path="$env:APPDATA\NVIDIA\ComputeCache"; Desc="Compute Cache" }
        @{ Path="$env:ProgramData\NVIDIA Corporation\NV_Cache"; Desc="System Cache" }
        @{ Path="$env:ProgramData\NVIDIA Corporation\Downloader"; Desc="Installer Temp" }
        @{ Path="$env:LOCALAPPDATA\Temp\NVIDIA Corporation"; Desc="User Temp" }
    )

    foreach ($target in $targets) {
        $p = $target.Path
        
        if (Test-Path $p) {
            $files = Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue
            $count = $files.Count
            $size = ($files | Measure-Object -Property Length -Sum).Sum / 1MB
            
            if ($count -gt 0) {
                Write-Host ""
                Write-Host " Found: $($target.Desc)" -ForegroundColor Cyan
                Write-Host " Files: $count | Size: $([math]::Round($size, 2)) MB" -ForegroundColor White
                $ask = Read-Host " >> Delete these files? (y/n)"
                
                if ($ask.ToLower() -eq "y") {
                    $removedCount = 0
                    foreach ($file in $files) { 
                        try { Remove-Item -Path $file.FullName -Force -ErrorAction Stop; $removedCount++ } catch {} 
                    }
                    if ($removedCount -eq $count) { Write-Host "    [SUCCESS] Cleaned." -ForegroundColor Green }
                    else { Write-Host "    [PARTIAL] Cleaned ($removedCount/$count)." -ForegroundColor Yellow }
                } else {
                    Write-Host "    Skipped." -ForegroundColor DarkGray
                }
            }
        }
    }
    Write-Host "`nDone. Press any key..." -ForegroundColor Green
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Set-EcoMode {
    param($SmiPath)
    Write-Host "`n=== Eco Mode Setup (50%) ===" -ForegroundColor Cyan
    try {
        $max = & $SmiPath --query-gpu=power.max_limit --format=csv,noheader,nounits
        $min = & $SmiPath --query-gpu=power.min_limit --format=csv,noheader,nounits
        if ($max -eq "[Not Supported]" -or $null -eq $max) { Write-Host "Not Supported." -ForegroundColor Red; Pause; return }
        $target = [math]::Round([double]$max * 0.50)
        if ($target -lt [double]$min) { $target = [double]$min; Write-Host "Adjusted to hardware min: $target W" -ForegroundColor Yellow }
        & $SmiPath -pl $target
        Write-Host "Limit set to $target W." -ForegroundColor Green
    } catch { Write-Host "Failed." -ForegroundColor Red }
    Pause
}

function Set-MaxMode {
    param($SmiPath)
    Write-Host "`n=== Max Performance Setup ===" -ForegroundColor Cyan
    try {
        $max = & $SmiPath --query-gpu=power.max_limit --format=csv,noheader,nounits
        if ($max -eq "[Not Supported]") { Write-Host "Not Supported." -ForegroundColor Red; Pause; return }
        & $SmiPath -pl $max
        Write-Host "Limit restored to $max W." -ForegroundColor Green
    } catch { Write-Host "Failed." -ForegroundColor Red }
    Pause
}

# --- MAIN LOGIC ---

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Definition)`"" -Verb RunAs
    exit
}

$smi = Get-NvidiaSmi
if (-not $smi) { Write-Host "NVIDIA Driver not found." -ForegroundColor Red; Pause; exit }

Write-Host "Initializing Nvidia Tool..." -ForegroundColor Green
$localInfo = Get-InstalledDriverInfo -SmiPath $smi
$latestVer = "Check Required"

do {
    Clear-Host
    
    $hagsStatus = Get-HagsStatus
    $vrrStatus = Get-VrrStatus
    $telemetryStatus = Get-TelemetryStatus
    $dlssStatus = Get-DlssIndicatorStatus

    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "                  NVIDIA TOOL                   " -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    
    Write-Host " GPU Device    : " -NoNewline; Write-Host "$($localInfo.Name)" -ForegroundColor White
    Write-Host " VRAM Size     : " -NoNewline; Write-Host "$($localInfo.VRAM) MB" -ForegroundColor White
    Write-Host "------------------------------------------" -ForegroundColor DarkGray
    Write-Host " Installed Ver : " -NoNewline; Write-Host "$($localInfo.Version)" -ForegroundColor Yellow
    Write-Host " Latest        : " -NoNewline
    
    if ($latestVer -eq "Check Required") {
        Write-Host "[Press U to Check] " -ForegroundColor DarkGray
    } elseif ($latestVer -eq "Connection Error" -or $latestVer -eq "Unknown") { 
        Write-Host $latestVer -ForegroundColor Red 
    } else {
        try { 
            if ([version]$localInfo.Version -ge [version]$latestVer) { Write-Host "$latestVer (Up to Date)" -ForegroundColor Green } 
            else { Write-Host "$latestVer (UPDATE AVAILABLE)" -ForegroundColor Red -BackgroundColor Yellow } 
        } catch { Write-Host "$latestVer" -ForegroundColor White }
    }

    Write-Host "------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " Hardware-Accelerated GPU Scheduling : " -NoNewline; if ($hagsStatus) { Write-Host "ON" -ForegroundColor Green } else { Write-Host "OFF" -ForegroundColor Red }
    Write-Host " Variable Refresh Rate               : " -NoNewline; if ($vrrStatus) { Write-Host "ON" -ForegroundColor Green } else { Write-Host "OFF" -ForegroundColor Red }
    Write-Host " Telemetry Tasks                     : " -NoNewline; if ($telemetryStatus) { Write-Host "ENABLED" -ForegroundColor Red } else { Write-Host "DISABLED" -ForegroundColor Green }
    Write-Host " DLSS Info Overlay                   : " -NoNewline; if ($dlssStatus) { Write-Host "ENABLED" -ForegroundColor Green } else { Write-Host "DISABLED" -ForegroundColor Red }

    Write-Host "================================================" -ForegroundColor Cyan
    
    Write-Host " [WINDOWS GRAPHICS SETTINGS]" -ForegroundColor DarkCyan
    Write-Host " H. Toggle HAGS" -ForegroundColor Magenta
    Write-Host " V. Toggle VRR" -ForegroundColor Magenta
    
    Write-Host "`n [NVIDIA SETTINGS]" -ForegroundColor DarkCyan
    Write-Host " T. Toggle Telemetry" -ForegroundColor Yellow
    Write-Host " D. Toggle DLSS Indicator" -ForegroundColor Yellow
    Write-Host " U. Check Driver Updates (TPU)" -ForegroundColor White

    Write-Host "`n [MONITORING]" -ForegroundColor DarkCyan
    Write-Host " 1. Hardware Dashboard" -ForegroundColor Cyan
    
    Write-Host "`n [MAINTENANCE & FIXES]" -ForegroundColor DarkCyan
    Write-Host " 2. Clean DirectX Caches and other temp files" -ForegroundColor Yellow
    Write-Host " 3. Disable Game Bar Presence" -ForegroundColor Yellow
    
    Write-Host "`n [POWER MANAGEMENT]" -ForegroundColor DarkCyan
    Write-Host " 4. Eco Mode (50% Power)" -ForegroundColor Green
    Write-Host " 5. Max Performance (100% Power)" -ForegroundColor Green
    
    Write-Host "`n X. Exit"
    Write-Host ""
    
    $choice = Read-Host " Select Option"
    
    switch ($choice.ToUpper()) {
        "H" { Toggle-HAGS }
        "V" { Toggle-VRR }
        "T" { Toggle-Telemetry }
        "D" { Toggle-DlssIndicator }
        "U" { $latestVer = Get-LatestDriverFromTPU }
        "1" { Show-Dashboard -SmiPath $smi }
        "2" { Clean-Caches }
        "3" { Disable-GameBarWriter }
        "4" { Set-EcoMode -SmiPath $smi }
        "5" { Set-MaxMode -SmiPath $smi }
        "X" { exit }
    }
} while ($true)