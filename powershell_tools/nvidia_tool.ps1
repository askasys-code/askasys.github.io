<#
.SYNOPSIS
    Nvidia Tool
    
.DESCRIPTION
    Standalone tool for NVIDIA GPUs.
    v8 Changes:
    - MAIN MENU: HAGS and Telemetry status are now displayed in the main info panel.
    - MAIN MENU: Dedicated toggles for HAGS [H] and Telemetry [T] added.
    - REFACTORED: Maintenance function now only handles Cache cleaning. Telemetry is separate.
    - DASHBOARD: Removed VRAM % (shows Capacity only).
    - NEW: "Top GPU Apps" (Process Discovery).
    - NEW: Background CSV Logger (Record stats to Desktop).
    - NEW: Game Bar Presence Writer Fix (Anti-Conflict).
    - RETAINED: All v5 features (TDR, MSI, Eco 50%, Maintenance).
    
.NOTES
    REQUIRES: Administrator Privileges
    COMPATIBILITY: PowerShell 5.1+
    CODING STANDARD: All internal comments must be written in ENGLISH.
    
    !!! CRITICAL INSTRUCTION - STRICT OUTPUT RULES - NO EXCEPTIONS !!!
    1. Whenever asked to modify this script, you MUST ALWAYS return the 
       ENTIRE source code in a SINGLE, CONTINUOUS CODE BLOCK.
    2. ABSOLUTELY NO text, introductions, or explanations before or after the code block.
    3. NO PLACEHOLDERS like "# ... existing code". Every line must be present.
    4. PRESERVE THIS HEADER UNCHANGED in the output.
#>

# --- INITIALIZATION ---
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "SilentlyContinue"

# --- CORE FUNCTIONS ---

function Test-Admin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

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

function Get-HagsStatus {
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    $name = "HwSchMode"
    try {
        $val = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
        if ($val -eq 2) { return $true }
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

function Start-CsvLogger {
    param($SmiPath)
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $fileName = "NvidiaLog_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
    $fullPath = Join-Path $desktopPath $fileName

    Clear-Host
    Write-Host "=== BACKGROUND LOGGING MODE ===" -ForegroundColor Cyan
    Write-Host "Recording GPU stats to: " -NoNewline; Write-Host $fileName -ForegroundColor Yellow
    Write-Host "You can minimize this window and play your game." -ForegroundColor White
    Write-Host ""
    Write-Host "Press '0' to Stop Logging." -ForegroundColor Red
    
    # Initialize CSV Header
    "Timestamp,Temp(C),Fan(%),Power(W),Load(%),VRAM_Used(MB),Clock(MHz)" | Out-File -FilePath $fullPath -Encoding UTF8

    $logging = $true
    while ($logging) {
        try {
            $data = & $SmiPath --query-gpu=temperature.gpu,fan.speed,power.draw,utilization.gpu,memory.used,clocks.gr --format=csv,noheader,nounits
            if ($data -is [array]) { $data = $data[0] }
            
            $timestamp = Get-Date -Format "HH:mm:ss"
            $line = "$timestamp,$data"
            
            # Append to file
            $line | Out-File -FilePath $fullPath -Append -Encoding UTF8
            
            # Visual heartbeat
            Write-Host "." -NoNewline -ForegroundColor DarkGray
        } catch {
            Write-Host "x" -NoNewline -ForegroundColor Red
        }

        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.KeyChar -eq '0') { $logging = $false }
        }
        Start-Sleep -Seconds 2
    }
    
    Write-Host "`nLogging Stopped. File saved." -ForegroundColor Green
    Pause
}

function Show-TopApps {
    param($SmiPath)
    Clear-Host
    Write-Host "=== TOP GPU PROCESSES ===" -ForegroundColor Cyan
    Write-Host "Detecting apps using GPU resources..." -ForegroundColor Gray
    Write-Host ""
    
    # Get Graphics Processes
    $gfxApps = & $SmiPath --query-graphics-apps=pid,process_name,used_memory --format=csv,noheader,nounits
    # Get Compute Processes (CUDA)
    $computeApps = & $SmiPath --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits
    
    $allApps = @()
    if ($gfxApps -is [string]) { $allApps += $gfxApps } elseif ($gfxApps -is [array]) { $allApps += $gfxApps }
    if ($computeApps -is [string]) { $allApps += $computeApps } elseif ($computeApps -is [array]) { $allApps += $computeApps }

    if ($allApps.Count -eq 0) {
        Write-Host "No active GPU processes found." -ForegroundColor Green
    } else {
        Write-Host "PID    | Memory  | Process Name" -ForegroundColor Yellow
        Write-Host "-------+---------+--------------------------------" -ForegroundColor DarkGray
        
        foreach ($line in $allApps) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split ',\s*'
            $pidVal = $parts[0]
            $name   = $parts[1]
            $mem    = $parts[2] # MB
            
            # Formatting
            $memDisplay = "$mem MB"
            if ([int]$mem -gt 1000) { $memDisplay = "$([math]::Round([int]$mem/1024, 2)) GB" }
            
            Write-Host "$($pidVal.PadRight(6)) | $($memDisplay.PadRight(7)) | $name" -ForegroundColor White
        }
    }
    Write-Host ""
    Write-Host "Press any key..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# --- MAINTENANCE & SETTINGS ---

function Toggle-HAGS {
    Clear-Host
    Write-Host "=== Hardware Accelerated GPU Scheduling (HAGS) ===" -ForegroundColor Cyan
    Write-Host "Required for DLSS 3 Frame Generation." -ForegroundColor Gray
    
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    $name = "HwSchMode"
    $status = Get-HagsStatus

    Write-Host ""
    Write-Host "Current Status: " -NoNewline
    if ($status) { Write-Host "ENABLED (ON)" -ForegroundColor Green } 
    else { Write-Host "DISABLED (OFF)" -ForegroundColor Red }
    
    Write-Host ""
    if ($status) {
        $c = Read-Host "Do you want to DISABLE HAGS? (y/n)"
        if ($c.ToLower() -eq "y") {
            New-ItemProperty -Path $path -Name $name -Value 1 -PropertyType DWord -Force | Out-Null
            Write-Host "HAGS Disabled. REBOOT REQUIRED." -ForegroundColor Magenta
        }
    } else {
        $c = Read-Host "Do you want to ENABLE HAGS? (y/n)"
        if ($c.ToLower() -eq "y") {
            New-ItemProperty -Path $path -Name $name -Value 2 -PropertyType DWord -Force | Out-Null
            Write-Host "HAGS Enabled. REBOOT REQUIRED." -ForegroundColor Magenta
        }
    }
    Pause
}

function Toggle-Telemetry {
    Clear-Host
    Write-Host "=== NVIDIA Telemetry Tasks ===" -ForegroundColor Cyan
    $tasks = @("NvTmMon", "NvTmRep", "NvTmRepOnLogon", "NvProfileUpdaterOnLogon")
    $status = Get-TelemetryStatus

    Write-Host ""
    Write-Host "Current Status: " -NoNewline
    if ($status) { Write-Host "ENABLED (Active)" -ForegroundColor Red } 
    else { Write-Host "DISABLED (Inactive)" -ForegroundColor Green }
    Write-Host ""

    if ($status) {
        $c = Read-Host "Do you want to DISABLE Telemetry tasks? (y/n)"
        if ($c.ToLower() -eq "y") {
            foreach ($t in $tasks) {
                $obj = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
                if ($obj) {
                    Disable-ScheduledTask -TaskName $t | Out-Null
                    Write-Host " [DISABLED] $t" -ForegroundColor Green
                }
            }
            Write-Host "`nTelemetry disabled." -ForegroundColor Green
        }
    } else {
        $c = Read-Host "Do you want to ENABLE Telemetry tasks? (y/n)"
        if ($c.ToLower() -eq "y") {
            foreach ($t in $tasks) {
                 $obj = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
                 if ($obj) {
                    Enable-ScheduledTask -TaskName $t | Out-Null
                    Write-Host " [ENABLED] $t" -ForegroundColor Red
                }
            }
             Write-Host "`nTelemetry enabled." -ForegroundColor Red
        }
    }
    Pause
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

function Enable-MSIMode {
    Clear-Host
    Write-Host "=== Enable MSI Mode ===" -ForegroundColor Cyan
    $adapterPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    $count = 0
    if (Test-Path $adapterPath) {
        $keys = Get-ChildItem -Path $adapterPath -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            $driverDesc = (Get-ItemProperty -Path $key.PSPath -Name "DriverDesc" -ErrorAction SilentlyContinue).DriverDesc
            if ($driverDesc -like "*NVIDIA*") {
                Write-Host "Found Adapter: $driverDesc" -ForegroundColor White
                $enumPathRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum"
                $matchesFound = Get-ChildItem -Path $enumPathRoot -Recurse -Include "MessageSignaledInterruptProperties" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*MessageSignaledInterruptProperties*" }
                foreach ($msiKey in $matchesFound) {
                    $parent = Split-Path $msiKey.PSPath -Parent; $grandParent = Split-Path $parent -Parent; $greatGrand = Split-Path $grandParent -Parent
                    $deviceService = (Get-ItemProperty -Path $greatGrand -Name "Service" -ErrorAction SilentlyContinue).Service
                    if ($deviceService -eq "nvlddmkm") {
                        Set-ItemProperty -Path $msiKey.PSPath -Name "MSISupported" -Value 1 -Type DWord -Force
                        Write-Host "    [SUCCESS] MSI Mode Enabled." -ForegroundColor Green; $count++
                    }
                }
            }
        }
    }
    if ($count -eq 0) { Write-Host "No NVIDIA keys found." -ForegroundColor Red } else { Write-Host "Reboot required." -ForegroundColor Magenta }
    Pause
}

function Set-TdrDelay {
    Clear-Host
    Write-Host "=== TDR Delay Stability Fix ===" -ForegroundColor Cyan
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    try {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name "TdrDelay" -Value 10 -Type DWord -Force
        Set-ItemProperty -Path $path -Name "TdrDdiDelay" -Value 10 -Type DWord -Force
        Write-Host "[SUCCESS] TdrDelay set to 10s. Reboot required." -ForegroundColor Green
    } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
    Pause
}

# --- MAIN LOGIC ---

if (-not (Test-Admin)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Definition)`"" -Verb RunAs
    exit
}

$smi = Get-NvidiaSmi
if (-not $smi) { Write-Host "NVIDIA Driver not found." -ForegroundColor Red; Pause; exit }

Write-Host "Initializing Nvidia Tool..." -ForegroundColor Green
$localInfo = Get-InstalledDriverInfo -SmiPath $smi
$latestVer = Get-LatestDriverFromTPU

do {
    Clear-Host
    
    $hagsStatus = Get-HagsStatus
    $telemetryStatus = Get-TelemetryStatus

    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "               NVIDIA TOOL                " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    
    Write-Host " GPU Device    : " -NoNewline; Write-Host "$($localInfo.Name)" -ForegroundColor White
    Write-Host " VRAM Size     : " -NoNewline; Write-Host "$($localInfo.VRAM) MB" -ForegroundColor White
    Write-Host "------------------------------------------" -ForegroundColor DarkGray
    Write-Host " Installed Ver : " -NoNewline; Write-Host "$($localInfo.Version)" -ForegroundColor Yellow
    Write-Host " Latest (TPU)  : " -NoNewline
    if ($latestVer -eq "Connection Error" -or $latestVer -eq "Unknown") { Write-Host $latestVer -ForegroundColor Red } 
    else {
        try { if ([version]$localInfo.Version -ge [version]$latestVer) { Write-Host "$latestVer (Up to Date)" -ForegroundColor Green } else { Write-Host "$latestVer (UPDATE AVAILABLE)" -ForegroundColor Red -BackgroundColor Yellow } } catch { Write-Host "$latestVer" -ForegroundColor White }
    }
    Write-Host "------------------------------------------" -ForegroundColor DarkGray
    Write-Host " HAGS Scheduling: " -NoNewline; if ($hagsStatus) { Write-Host "ENABLED" -ForegroundColor Green } else { Write-Host "DISABLED" -ForegroundColor Red }
    Write-Host " Telemetry Tasks  : " -NoNewline; if ($telemetryStatus) { Write-Host "ENABLED" -ForegroundColor Red } else { Write-Host "DISABLED" -ForegroundColor Green }

    Write-Host "==========================================" -ForegroundColor Cyan
    
    Write-Host " [SETTINGS TOGGLES]" -ForegroundColor DarkCyan
    Write-Host " H. Toggle HAGS" -ForegroundColor Magenta
    Write-Host " T. Toggle Telemetry" -ForegroundColor Yellow

    Write-Host "`n [MONITORING & LOGGING]" -ForegroundColor DarkCyan
    Write-Host " 1. Hardware Dashboard" -ForegroundColor Cyan
    Write-Host " 2. Show Top GPU Apps" -ForegroundColor Cyan
    Write-Host " 3. Start Background CSV Logger" -ForegroundColor Cyan
    
    Write-Host "`n [MAINTENANCE & FIXES]" -ForegroundColor DarkCyan
    Write-Host " 4. Clean DirectX Caches" -ForegroundColor Yellow
    Write-Host " 5. Fix TDR Delay" -ForegroundColor Yellow
    Write-Host " 6. Disable Game Bar Presence" -ForegroundColor Yellow
    
    Write-Host "`n [PERFORMANCE TWEAKS]" -ForegroundColor DarkCyan
    Write-Host " 7. Enable MSI Mode (Low Latency)" -ForegroundColor Magenta
    Write-Host " 8. Eco Mode (50% Power)" -ForegroundColor Green
    Write-Host " 9. Max Performance (100% Power)" -ForegroundColor Green
    
    Write-Host "`n 10. TechPowerUp Page" -ForegroundColor White
    Write-Host " X. Exit"
    Write-Host ""
    
    $choice = Read-Host " Select Option"
    
    switch ($choice.ToUpper()) {
        "H" { Toggle-HAGS }
        "T" { Toggle-Telemetry }
        "1" { Show-Dashboard -SmiPath $smi }
        "2" { Show-TopApps -SmiPath $smi }
        "3" { Start-CsvLogger -SmiPath $smi }
        "4" { Clean-Caches }
        "5" { Set-TdrDelay }
        "6" { Disable-GameBarWriter }
        "7" { Enable-MSIMode }
        "8" { Set-EcoMode -SmiPath $smi }
        "9" { Set-MaxMode -SmiPath $smi }
        "10" { Start-Process "https://www.techpowerup.com/download/nvidia-geforce-graphics-drivers/" }
        "X" { exit }
    }
} while ($true)