# ==============================================================================
# SCRIPT:        Windows System Cleaner Tool
# COMPATIBILITY: Windows 10 / Windows 11
# CODING STANDARD: All internal comments and UI strings must be written in ENGLISH.
# ==============================================================================

$ErrorActionPreference = "Continue"

# Console configuration
$Host.UI.RawUI.WindowTitle = "Windows System Cleaner Tool"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

# Check privilege level without closing or blocking startup
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Pause-Script {
    Write-Host "`n   Press any key to return to the menu..." -ForegroundColor DarkGray
    try {
        if ($Host.UI.RawUI -and $Host.Name -notmatch "ISE|Visual Studio Code") {
            while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
            [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }
    } catch {}
    [void](Read-Host)
}

# High-speed non-recursive directory measurement queue
function Get-FastDirectorySize ([string[]]$paths) {
    [long]$totalBytes = 0
    foreach ($p in $paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ([System.IO.File]::Exists($p)) {
            try { $totalBytes += (New-Object System.IO.FileInfo($p)).Length } catch {}
            continue
        }
        if (-not [System.IO.Directory]::Exists($p)) { continue }
        $queue = New-Object System.Collections.Generic.Queue[string]
        $queue.Enqueue($p)
        while ($queue.Count -gt 0) {
            $curr = $queue.Dequeue()
            try {
                $dir = New-Object System.IO.DirectoryInfo($curr)
                foreach ($f in $dir.EnumerateFiles()) { $totalBytes += $f.Length }
                foreach ($s in $dir.EnumerateDirectories()) {
                    if (($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $queue.Enqueue($s.FullName)
                    }
                }
            } catch {}
        }
    }
    return $totalBytes
}

function Format-StorageSize ([long]$bytes) {
    if ($bytes -lt 1KB) { return "$bytes Bytes" }
    if ($bytes -lt 1MB) { return ('{0:N2} KB' -f ($bytes / 1KB)) }
    if ($bytes -lt 1GB) { return ('{0:N2} MB' -f ($bytes / 1MB)) }
    return ('{0:N2} GB' -f ($bytes / 1GB))
}

function Get-StorageAnalysis {
    [long]$recycleBinBytes = 0
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.NameSpace(0xA)
        if ($bin) {
            $sum = ($bin.Items() | Measure-Object -Property Size -Sum).Sum
            if ($sum) { $recycleBinBytes = [long]$sum }
        }
    } catch {}

    $g1 = (Get-FastDirectorySize @($env:TEMP, "$env:SystemRoot\Temp", "$env:SystemRoot\Logs", "$env:SystemRoot\System32\LogFiles")) + $recycleBinBytes
    $g2 = Get-FastDirectorySize @("$env:SystemRoot\SoftwareDistribution\Download", "$env:SystemRoot\SoftwareDistribution\DataStore")
    
    [long]$g4 = 0
    $expPath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    if ([System.IO.Directory]::Exists($expPath)) {
        try {
            $d = New-Object System.IO.DirectoryInfo($expPath)
            foreach ($f in $d.EnumerateFiles('*cache_*.db')) { $g4 += $f.Length }
        } catch {}
    }

    $g5 = Get-FastDirectorySize @(
        "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.Core_cw5n1h2txyewy\TempState\ScreenClip",
        "$env:LOCALAPPDATA\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\TempState",
        "$env:LOCALAPPDATA\CrashDumps",
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
        "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
        "$env:APPDATA\Microsoft\Windows\Recent",
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
        "$env:SystemRoot\Minidump",
        "$env:SystemRoot\LiveKernelReports",
        "$env:SystemRoot\MEMORY.DMP"
    )

    $g6 = Get-FastDirectorySize @(
        "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache",
        "$env:ProgramData\Microsoft\Windows Defender\Scans\History\Service\DetectionHistory"
    )

    return @{
        G1 = Format-StorageSize $g1
        G2 = Format-StorageSize $g2
        G4 = Format-StorageSize $g4
        G5 = Format-StorageSize $g5
        G6 = Format-StorageSize $g6
    }
}

# ---------------------------------------------------------------------------
# CLEANUP ROUTINES
# ---------------------------------------------------------------------------

function Invoke-CleanGroup1 {
    Write-Host "`n   === Cleaning User/System Temp, Logs & Recycle Bin ===" -ForegroundColor Cyan
    Write-Host "   1. Cleaning User Temp ($env:TEMP)..." -ForegroundColor Yellow
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "   2. Cleaning System Temp ($env:SystemRoot\Temp)..." -ForegroundColor Yellow
    Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "   3. Emptying Recycle Bin..." -ForegroundColor Yellow
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue

    Write-Host "   4. Cleaning System Logs (Logs, System32\LogFiles & HTTPERR)..." -ForegroundColor Yellow
    Remove-Item "$env:SystemRoot\Logs\*.log" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\Logs\*.cab" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\System32\LogFiles\*.log" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\System32\LogFiles\HTTPERR\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "   [OK] Temp and Log cleanup completed." -ForegroundColor Green
}

function Invoke-CleanGroup2 {
    Write-Host "`n   === Cleaning Windows Update & Store Cache ===" -ForegroundColor Cyan
    Write-Host "   1. Stopping Windows Update & Delivery Optimization services..." -ForegroundColor Yellow
    Stop-Service -Name wuauserv, bits, dosvc, cryptsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    Write-Host "   2. Cleaning SoftwareDistribution (Download & DataStore)..." -ForegroundColor Yellow
    Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\SoftwareDistribution\DataStore\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "   3. Restarting Services..." -ForegroundColor Yellow
    Start-Service -Name cryptsvc, dosvc, bits, wuauserv -ErrorAction SilentlyContinue

    Write-Host "   4. Resetting Windows Store Cache (wsreset)..." -ForegroundColor Yellow
    if (Get-Command wsreset.exe -ErrorAction SilentlyContinue) {
        Start-Process -FilePath "wsreset.exe" -Wait -NoNewWindow -ErrorAction SilentlyContinue
    }

    Write-Host "   [OK] Windows Update & Store reset completed." -ForegroundColor Green
}

function Invoke-CleanGroup3 {
    Write-Host "`n   === WinSxS Cleanup (Component Store) ===" -ForegroundColor Cyan
    Write-Host "   Executing DISM to remove obsolete components. Please wait..." -ForegroundColor Yellow
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup
    if ($LASTEXITCODE -eq 0) {
        Write-Host "   [OK] WinSxS cleanup completed successfully." -ForegroundColor Green
    } else {
        Write-Host "   [*] WinSxS exited with exit code: $LASTEXITCODE" -ForegroundColor Red
    }
}

function Invoke-CleanGroup4 {
    Write-Host "`n   === Clear Thumbnail & Icon Cache ===" -ForegroundColor Cyan
    Write-Host "   Clearing thumbnail and icon database files..." -ForegroundColor Yellow
    $exp = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    Remove-Item "$exp\thumbcache_*.db" -Force -ErrorAction SilentlyContinue
    Remove-Item "$exp\iconcache_*.db" -Force -ErrorAction SilentlyContinue
    Write-Host "   [OK] Cache cleared (locked files in active use skipped)." -ForegroundColor Green
}

function Invoke-CleanGroup5 {
    Write-Host "`n   === Cleaning Crash Dumps, Diagnostics & Extra Temp ===" -ForegroundColor Cyan
    Write-Host "   1. Clearing Clipboard..." -ForegroundColor Yellow
    try { Set-Clipboard $null -ErrorAction SilentlyContinue } catch { & cmd.exe /c "echo off | clip" }

    Write-Host "   2. Cleaning Snipping Tool ScreenClips..." -ForegroundColor Yellow
    Remove-Item "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.Core_cw5n1h2txyewy\TempState\ScreenClip\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\TempState\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "   3. Cleaning Crash Dumps & Windows Error Reporting..." -ForegroundColor Yellow
    Remove-Item "$env:SystemRoot\MEMORY.DMP" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\Minidump\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\LiveKernelReports\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\CrashDumps\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:ProgramData\Microsoft\Windows\WER\ReportArchive\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:ProgramData\Microsoft\Windows\WER\ReportQueue\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "   4. Cleaning Recent Items History & INetCache..." -ForegroundColor Yellow
    Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\INetCache\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "   5. Flushing DNS Resolver Cache..." -ForegroundColor Yellow
    Clear-DnsClientCache -ErrorAction SilentlyContinue

    Write-Host "   [OK] Diagnostics and crash dump cleanup complete." -ForegroundColor Green
}

function Invoke-CleanGroup6 {
    Write-Host "`n   === Deep System, DO Cache & Event Logs Cleanup ===" -ForegroundColor Cyan
    Write-Host "   1. Cleaning Delivery Optimization Cache..." -ForegroundColor Yellow
    Remove-Item "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*" -Recurse -Force -ErrorAction SilentlyContinue
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
    }

    Write-Host "   2. Cleaning Windows Defender Detection History..." -ForegroundColor Yellow
    Remove-Item "$env:ProgramData\Microsoft\Windows Defender\Scans\History\Service\DetectionHistory\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "   3. Clearing Windows Event Viewer Logs..." -ForegroundColor Yellow
    try {
        $logs = & wevtutil el 2>$null
        foreach ($log in $logs) { & wevtutil cl "$log" 2>$null }
    } catch {}

    Write-Host "   [OK] Deep System Cleanup Complete." -ForegroundColor Green
}

function Invoke-CleanAll {
    Write-Host "`n   === Running Comprehensive System Clean ===" -ForegroundColor Magenta
    Invoke-CleanGroup1
    Invoke-CleanGroup2
    Invoke-CleanGroup3
    Invoke-CleanGroup4
    Invoke-CleanGroup5
    Invoke-CleanGroup6
    Write-Host "`n   [ALL TASKS COMPLETED] System fully cleaned and optimized." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# MAIN MENU LOOP
# ---------------------------------------------------------------------------
do {
    Clear-Host
    $isAdmin = Test-IsAdministrator
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "                   WINDOWS SYSTEM CLEANER TOOL                    " -ForegroundColor White
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "   Analyzing current storage usage... Please wait..." -ForegroundColor Yellow

    $sizes = Get-StorageAnalysis

    Clear-Host
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "                   WINDOWS SYSTEM CLEANER TOOL                    " -ForegroundColor White
    Write-Host "                Deep Storage Optimization Utility                 " -ForegroundColor DarkGray
    Write-Host "==================================================================" -ForegroundColor Cyan
    if ($isAdmin) {
        Write-Host "   Privilege Level : Administrator (Full Access)`n" -ForegroundColor Green
    } else {
        Write-Host "   Privilege Level : Standard User (Read-Only - Run CMD as Admin)`n" -ForegroundColor Yellow
    }

    Write-Host "   CURRENT STORAGE ANALYSIS" -ForegroundColor Yellow
    Write-Host "   --------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "   [1] Temp Files, Logs & Recycle Bin     : " -NoNewline; Write-Host $sizes.G1 -ForegroundColor Green
    Write-Host "   [2] Windows Update & Store Cache       : " -NoNewline; Write-Host $sizes.G2 -ForegroundColor Green
    Write-Host "   [3] WinSxS Component Store             : " -NoNewline; Write-Host "[Optimization Action]" -ForegroundColor DarkGray
    Write-Host "   [4] Thumbnail & Icon Cache             : " -NoNewline; Write-Host $sizes.G4 -ForegroundColor Green
    Write-Host "   [5] Dumps, ScreenClips & Extra         : " -NoNewline; Write-Host $sizes.G5 -ForegroundColor Green
    Write-Host "   [6] Deep System, DO & Event Logs       : " -NoNewline; Write-Host $sizes.G6 -ForegroundColor Green
    Write-Host ""
    Write-Host "   BATCH OPERATIONS & ACTIONS" -ForegroundColor Yellow
    Write-Host "   --------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "   [A] Run All Cleaning Tasks" -ForegroundColor Magenta
    Write-Host "   [0] Exit" -ForegroundColor DarkGray
    Write-Host "   --------------------------------------------------------------" -ForegroundColor DarkGray

    $choice = (Read-Host "`n   Select Action").Trim().ToUpper()

    if ($choice -match '^(0|X|EXIT|QUIT)$') {
        Write-Host "   Exiting Cleaner Tool..." -ForegroundColor Cyan
        Start-Sleep -Milliseconds 300
        Clear-Host
        exit 0
    }

    if (-not $isAdmin) {
        Write-Host "`n   [!] Administrator privileges required to execute cleaning tasks." -ForegroundColor Red
        Write-Host "   [i] Please close CMD and launch it via 'Run as administrator'." -ForegroundColor Yellow
        Pause-Script
        continue
    }

    switch ($choice) {
        "1" { Invoke-CleanGroup1; Pause-Script }
        "2" { Invoke-CleanGroup2; Pause-Script }
        "3" { Invoke-CleanGroup3; Pause-Script }
        "4" { Invoke-CleanGroup4; Pause-Script }
        "5" { Invoke-CleanGroup5; Pause-Script }
        "6" { Invoke-CleanGroup6; Pause-Script }
        "A" { Invoke-CleanAll;    Pause-Script }
        Default {
            Write-Host "   [!] Invalid selection." -ForegroundColor Red
            Start-Sleep -Milliseconds 600
        }
    }
} while ($true)