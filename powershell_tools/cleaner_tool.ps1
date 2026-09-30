# REQUIRES: Administrator Privileges
# COMPATIBILITY: Windows PowerShell 5.1+ / PowerShell 7+
# CODING STANDARD: All internal comments must be written in ENGLISH.

# Updated: 2026-09-30

# ---------------------------------------------------------------------------
# INITIALIZATION & SETUP
# ---------------------------------------------------------------------------

#region Setup, Encoding & Auto-Elevation
# --- 1. GLOBAL SETTINGS ---
$ErrorActionPreference = "SilentlyContinue"

# Set Console Encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Enable TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- 2. ADMIN SELF-ELEVATION (ORIGINAL PROVEN METHOD) ---
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

#region Core: High-Performance Engine (.NET Native)
function Format-ByteSize {
    param ([long]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes Bytes" }
    if ($Bytes -lt 1MB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    if ($Bytes -lt 1GB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    return "{0:N2} GB" -f ($Bytes / 1GB)
}

# Sub-second recursive directory scanner bypassing PSObject pipeline overhead
function Get-FastPathSize {
    param ([string[]]$Paths)
    [long]$totalBytes = 0

    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }

        # Check individual file (e.g. MEMORY.DMP)
        if ([System.IO.File]::Exists($p)) {
            try { $totalBytes += (New-Object System.IO.FileInfo($p)).Length } catch {}
            continue
        }

        # Check directory existence
        if (-not [System.IO.Directory]::Exists($p)) { continue }

        $dirsQueue = New-Object System.Collections.Generic.Queue[string]
        $dirsQueue.Enqueue($p)

        while ($dirsQueue.Count -gt 0) {
            $currentDir = $dirsQueue.Dequeue()
            $dirInfo = $null
            try {
                $dirInfo = New-Object System.IO.DirectoryInfo($currentDir)
            } catch { continue }

            # Safe file size accumulation
            try {
                foreach ($file in $dirInfo.EnumerateFiles()) {
                    $totalBytes += $file.Length
                }
            } catch {}

            # Safe subfolder enumeration skipping ReparsePoints (symlinks/junctions)
            try {
                foreach ($sub in $dirInfo.EnumerateDirectories()) {
                    if (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $dirsQueue.Enqueue($sub.FullName)
                    }
                }
            } catch {}
        }
    }
    return $totalBytes
}

# Accurate calculation exclusively for thumbnail/icon cache files
function Get-ThumbCacheSizeFast {
    [long]$total = 0
    $p = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    if ([System.IO.Directory]::Exists($p)) {
        try {
            $dir = New-Object System.IO.DirectoryInfo($p)
            foreach ($f in $dir.EnumerateFiles("*cache_*.db")) {
                $total += $f.Length
            }
        } catch {}
    }
    return $total
}

function Get-RecycleBinSizeFast {
    [long]$total = 0
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.NameSpace(0xA)
        if ($bin) {
            $measure = $bin.Items() | Measure-Object -Property Size -Sum
            if ($null -ne $measure -and $null -ne $measure.Sum) { $total = [long]$measure.Sum }
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($bin) | Out-Null } catch {}
        }
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch {}
    } catch {
        return 0
    }
    return $total
}

function Pause-Script {
    Write-Host "`nPress any key to return to the menu..." -ForegroundColor DarkGray
    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        Read-Host
    }
}
#endregion

#region Function Group 1: Temp, Logs & Recycle Bin
function Invoke-OriginalTempCleanup {
    Write-Host "`n=== Cleaning User/System Temp, Logs & Recycle Bin ===" -ForegroundColor Cyan
    
    # Step 1: User Temp
    Write-Host "1. Cleaning User Temp ($env:TEMP)..." -ForegroundColor Yellow
    Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    
    # Step 2: System Temp
    Write-Host "2. Cleaning System Temp (C:\Windows\Temp)..." -ForegroundColor Yellow
    Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    
    # Step 3: Recycle Bin
    Write-Host "3. Emptying Recycle Bin..." -ForegroundColor Yellow
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    
    # Step 4: System Log Files & HTTPERR (Recursion bug immune)
    Write-Host "4. Cleaning System Logs (Windows\Logs, System32\LogFiles & HTTPERR)..." -ForegroundColor Yellow
    Get-ChildItem -Path "C:\Windows\Logs" -Filter "*.log" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path "C:\Windows\Logs" -Filter "*.cab" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path "C:\Windows\System32\LogFiles" -Filter "*.log" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Windows\System32\LogFiles\HTTPERR\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "`n[OK] Cleanup Complete." -ForegroundColor Green
    if ($args[0] -ne "-NoPause") { Pause-Script }
}
#endregion

#region Function Group 2: Windows Update & Store Cache
function Invoke-OriginalUpdateStore {
    Write-Host "`n=== Cleaning Windows Update & Store Cache ===" -ForegroundColor Cyan
    
    # Step 1: Stop Services cleanly
    Write-Host "1. Stopping Services (wuauserv, bits, dosvc, cryptsvc)..." -ForegroundColor Yellow
    $services = "wuauserv", "bits", "dosvc", "cryptsvc"
    Stop-Service -Name $services -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    
    # Step 2: Purge Cache
    Write-Host "2. Cleaning SoftwareDistribution (Download & DataStore)..." -ForegroundColor Yellow
    Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Windows\SoftwareDistribution\DataStore\*" -Recurse -Force -ErrorAction SilentlyContinue
    
    # Step 3: Restart Services
    Write-Host "3. Restarting Services..." -ForegroundColor Yellow
    Start-Service -Name $services -ErrorAction SilentlyContinue
    
    # Step 4: Reset Windows Store Cache (Safe execution)
    Write-Host "4. Resetting Windows Store Cache (wsreset)..." -ForegroundColor Yellow
    if (Get-Command -Name "wsreset.exe" -ErrorAction SilentlyContinue) {
        Start-Process -FilePath "wsreset.exe" -NoNewWindow -Wait
    }

    Write-Host "`n[OK] Update & Store Reset Complete." -ForegroundColor Green
    if ($args[0] -ne "-NoPause") { Pause-Script }
}
#endregion

#region Function Group 3: WinSxS Cleanup
function Invoke-OriginalWinSxS {
    Write-Host "`n=== WinSxS Cleanup (Component Store) ===" -ForegroundColor Cyan
    Write-Host "Executing DISM to remove obsolete components..." -ForegroundColor Yellow
    Write-Host "Process may take several minutes. Please wait..." -ForegroundColor Cyan
    
    DISM.exe /Online /Cleanup-Image /StartComponentCleanup
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n[OK] WinSxS cleanup completed." -ForegroundColor Green
    } else {
        Write-Host "`n[!] WinSxS cleanup exited with code: $LASTEXITCODE" -ForegroundColor Red
    }
    if ($args[0] -ne "-NoPause") { Pause-Script }
}
#endregion

#region Function Group 4: Thumbnail & Icon Cache
function Invoke-OriginalThumbnails {
    Write-Host "`n=== Clear Thumbnail & Icon Cache ===" -ForegroundColor Cyan
    Write-Host "Clearing thumbnail and icon cache..." -ForegroundColor Yellow
    
    $thumbCachePath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    if (Test-Path -LiteralPath $thumbCachePath) {
        Get-ChildItem -LiteralPath $thumbCachePath -Filter "thumbcache_*.db" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $thumbCachePath -Filter "iconcache_*.db" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "Thumbnail and icon cache cleared (locked files skipped)." -ForegroundColor Green
    } else {
        Write-Host "Thumbnail cache path not found." -ForegroundColor Red
    }
    if ($args[0] -ne "-NoPause") { Pause-Script }
}
#endregion

#region Function Group 5: Memory Dumps, Diagnostics, Clipboard & Extras
function Invoke-ExtraCleanup {
    Write-Host "`n=== Cleaning Crash Dumps, Diagnostics & Extra Temp ===" -ForegroundColor Cyan
    
    # Step 1: Clipboard
    Write-Host "1. Clearing Clipboard & History..." -ForegroundColor Yellow
    Set-Clipboard $null -ErrorAction SilentlyContinue
    Restart-Service -Name "cbdhsvc*" -Force -ErrorAction SilentlyContinue

    # Step 2: ScreenClips / Snipping Tool
    Write-Host "2. Cleaning Snipping Tool (ScreenClips)..." -ForegroundColor Yellow
    Remove-Item -Path "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.Core_cw5n1h2txyewy\TempState\ScreenClip\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$env:LOCALAPPDATA\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\TempState\*" -Recurse -Force -ErrorAction SilentlyContinue

    # Step 3: Crash Dumps, Windows Error Reporting & Full Memory Dump
    Write-Host "3. Cleaning Crash Dumps, LiveKernelReports & Windows Error Reporting..." -ForegroundColor Yellow
    if (Test-Path -LiteralPath "C:\Windows\MEMORY.DMP") {
        Remove-Item -LiteralPath "C:\Windows\MEMORY.DMP" -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path "C:\Windows\Minidump\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Windows\LiveKernelReports\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$env:LOCALAPPDATA\CrashDumps\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\ProgramData\Microsoft\Windows\WER\ReportArchive\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\*" -Recurse -Force -ErrorAction SilentlyContinue

    # Step 4: Recent Items & INetCache
    Write-Host "4. Cleaning Recent Items History & INetCache..." -ForegroundColor Yellow
    Remove-Item -Path "$env:APPDATA\Microsoft\Windows\Recent\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\Windows\INetCache\*" -Recurse -Force -ErrorAction SilentlyContinue

    # Step 5: DNS Cache
    Write-Host "5. Flushing DNS Cache..." -ForegroundColor Yellow
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    ipconfig /flushdns | Out-Null

    Write-Host "`n[OK] Diagnostics & Extra Cleanup Complete." -ForegroundColor Green
    if ($args[0] -ne "-NoPause") { Pause-Script }
}
#endregion

#region Function Group 6: Modern Deep System, DO Cache & Event Logs
function Invoke-DeepSystemCleanup {
    Write-Host "`n=== Deep System, DO Cache & Event Logs Cleanup ===" -ForegroundColor Cyan
    
    # Step 1: Windows Delivery Optimization (DO) Cache
    Write-Host "1. Cleaning Delivery Optimization Cache..." -ForegroundColor Yellow
    Remove-Item -Path "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*" -Recurse -Force -ErrorAction SilentlyContinue
    if (Get-Command -Name "Delete-DeliveryOptimizationCache" -ErrorAction SilentlyContinue) {
        Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
    }

    # Step 2: Windows Defender Detection History
    Write-Host "2. Cleaning Windows Defender Detection History..." -ForegroundColor Yellow
    Remove-Item -Path "C:\ProgramData\Microsoft\Windows Defender\Scans\History\Service\DetectionHistory\*" -Recurse -Force -ErrorAction SilentlyContinue

    # Step 3: Windows Event Viewer Logs (Ultra-fast .NET API with fallback)
    Write-Host "3. Clearing Windows Event Viewer Logs..." -ForegroundColor Yellow
    try {
        $session = [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession
        Get-WinEvent -ListLog * -Force -ErrorAction SilentlyContinue | Where-Object { $_.RecordCount -gt 0 } | ForEach-Object {
            try { $session.ClearLog($_.LogName) } catch {}
        }
    } catch {
        wevtutil el | ForEach-Object { wevtutil cl "$_" 2>$null }
    }

    Write-Host "`n[OK] Deep System Cleanup Complete." -ForegroundColor Green
    if ($args[0] -ne "-NoPause") { Pause-Script }
}
#endregion

#region Function Group 7: Run All Tasks
function Invoke-AllCleanups {
    Write-Host "`n=== Running Comprehensive System Clean ===" -ForegroundColor Magenta
    Invoke-OriginalTempCleanup -NoPause
    Invoke-OriginalUpdateStore -NoPause
    Invoke-OriginalWinSxS -NoPause
    Invoke-OriginalThumbnails -NoPause
    Invoke-ExtraCleanup -NoPause
    Invoke-DeepSystemCleanup -NoPause
    Write-Host "`n[ALL TASKS COMPLETED] System fully cleaned and optimized." -ForegroundColor Green
    Pause-Script
}
#endregion

# ---------------------------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------------------------
do {
    Clear-Host
    Write-Host "   =========================================" -ForegroundColor Cyan
    Write-Host "                 CLEANER TOOL               " -ForegroundColor White
    Write-Host "   =========================================" -ForegroundColor Cyan
    Write-Host "   Analyzing current storage usage..." -ForegroundColor Yellow

    # Group 1: Temp, Logs, HTTPERR, Bin
    Write-Host "   [1/5] Checking Temp Files & System Logs..." -ForegroundColor DarkGray
    $pathsGroup1 = @(
        $env:TEMP,
        "C:\Windows\Temp",
        "C:\Windows\Logs",
        "C:\Windows\System32\LogFiles"
    )
    $sizeGroup1 = (Get-FastPathSize $pathsGroup1) + (Get-RecycleBinSizeFast)

    # Group 2: Windows Update (Download + DataStore)
    Write-Host "   [2/5] Checking Windows Update Cache..." -ForegroundColor DarkGray
    $pathsGroup2 = @(
        "C:\Windows\SoftwareDistribution\Download",
        "C:\Windows\SoftwareDistribution\DataStore"
    )
    $sizeGroup2 = Get-FastPathSize $pathsGroup2

    # Group 4: Thumbnails & Icons (Accurate targeted measurement)
    Write-Host "   [3/5] Checking Thumbnail & Icon Cache..." -ForegroundColor DarkGray
    $sizeGroup4 = Get-ThumbCacheSizeFast

    # Group 5: Crash Dumps, Diagnostics & Extras
    Write-Host "   [4/5] Checking Crash Dumps & Diagnostics..." -ForegroundColor DarkGray
    $pathsGroup5 = @(
        "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.Core_cw5n1h2txyewy\TempState\ScreenClip",
        "$env:LOCALAPPDATA\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\TempState",
        "$env:LOCALAPPDATA\CrashDumps",
        "C:\ProgramData\Microsoft\Windows\WER\ReportArchive",
        "C:\ProgramData\Microsoft\Windows\WER\ReportQueue",
        "$env:APPDATA\Microsoft\Windows\Recent",
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
        "C:\Windows\Minidump",
        "C:\Windows\LiveKernelReports",
        "C:\Windows\MEMORY.DMP"
    )
    $sizeGroup5 = Get-FastPathSize $pathsGroup5

    # Group 6: Modern Deep System & DO Cache
    Write-Host "   [5/5] Checking Delivery Optimization & Deep Cache..." -ForegroundColor DarkGray
    $pathsGroup6 = @(
        "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache",
        "C:\ProgramData\Microsoft\Windows Defender\Scans\History\Service\DetectionHistory"
    )
    $sizeGroup6 = Get-FastPathSize $pathsGroup6

    # Refresh Screen with Final Menu
    Clear-Host
    Write-Host "   =========================================" -ForegroundColor Cyan
    Write-Host "                 CLEANER TOOL               " -ForegroundColor White
    Write-Host "   =========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   CURRENT STORAGE ANALYSIS" -ForegroundColor Yellow
    Write-Host "   -----------------------------------------" -ForegroundColor DarkGray

    # Define menu layout
    $menu = @(
        @{ ID="1"; Name="Temp Files, Logs & Recycle Bin"; Size=(Format-ByteSize $sizeGroup1); Color="Green" },
        @{ ID="2"; Name="Windows Update & Store Cache";   Size=(Format-ByteSize $sizeGroup2); Color="Green" },
        @{ ID="3"; Name="WinSxS Component Store";         Size="[Optimization Action]";       Color="Gray" },
        @{ ID="4"; Name="Thumbnail & Icon Cache";         Size=(Format-ByteSize $sizeGroup4); Color="Green" },
        @{ ID="5"; Name="Dumps, ScreenClips & Extra";     Size=(Format-ByteSize $sizeGroup5); Color="Green" },
        @{ ID="6"; Name="Deep System, DO & Event Logs";   Size=(Format-ByteSize $sizeGroup6); Color="Green" }
    )

    # Display Menu
    foreach ($item in $menu) {
        $pad = " " * [Math]::Max(1, (35 - $item.Name.Length))
        Write-Host "   " -NoNewline
        Write-Host "[$($item.ID)]" -ForegroundColor Yellow -NoNewline
        Write-Host " $($item.Name)$pad : " -ForegroundColor White -NoNewline
        Write-Host "$($item.Size)" -ForegroundColor $item.Color
    }

    Write-Host ""
    Write-Host "   [A] Run All Cleaning Tasks" -ForegroundColor Magenta
    Write-Host "   [X] Exit" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host "   Select Action"
    if (-not $choice) { continue }

    switch ($choice.Trim().ToLower()) {
        "1" { Invoke-OriginalTempCleanup }
        "2" { Invoke-OriginalUpdateStore }
        "3" { Invoke-OriginalWinSxS }
        "4" { Invoke-OriginalThumbnails }
        "5" { Invoke-ExtraCleanup }
        "6" { Invoke-DeepSystemCleanup }
        "a" { Invoke-AllCleanups }
        "x" { exit }
        Default { 
            Write-Host "   Invalid selection." -ForegroundColor Red
            Start-Sleep -Milliseconds 600 
        }
    }

} while ($true)