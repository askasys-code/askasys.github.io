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

#region Core: Helper Functions (Analysis)
function Format-ByteSize {
    param ([long]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes Bytes" }
    if ($Bytes -lt 1MB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    if ($Bytes -lt 1GB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    return "{0:N2} GB" -f ($Bytes / 1GB)
}

function Get-PathSize {
    param ([string[]]$Paths)
    $total = 0
    foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p) {
            # Optimized parsing avoiding symlink loops and handling nulls safely with -LiteralPath
            $measure = Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            if ($null -ne $measure -and $null -ne $measure.Sum) { $total += $measure.Sum }
        }
    }
    return $total
}

function Get-RecycleBinSize {
    try {
        $bin = (New-Object -ComObject Shell.Application).NameSpace(0xA)
        $measure = $bin.Items() | Measure-Object -Property Size -Sum
        if ($null -ne $measure -and $null -ne $measure.Sum) { return $measure.Sum }
        return 0
    } catch {
        return 0
    }
}

function Pause-Script {
    Write-Host "`nPress any key to return to the menu..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Function Group 1: Temp, Logs & Recycle Bin (Original Steps 1, 2, 3, 5)
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
    
    # Step 5: System Log Files
    Write-Host "4. Cleaning System Logs (Windows\Logs & System32\LogFiles)..." -ForegroundColor Yellow
    Remove-Item -Path "C:\Windows\Logs\*.log" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Windows\System32\LogFiles\*.log" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "`n[OK] Cleanup Complete." -ForegroundColor Green
    if ($args[0] -ne "-NoPause") { Pause-Script }
}
#endregion

#region Function Group 2: Windows Update & Store (Original Steps 4, 6)
function Invoke-OriginalUpdateStore {
    Write-Host "`n=== Cleaning Windows Update & Store Cache ===" -ForegroundColor Cyan
    
    # Step 4: Windows Update
    Write-Host "1. Stopping Services (wuauserv, bits, cryptsvc)..." -ForegroundColor Yellow
    $services = "wuauserv", "bits", "cryptsvc"
    Stop-Service -Name $services -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    
    Write-Host "2. Cleaning SoftwareDistribution (Download & DataStore)..." -ForegroundColor Yellow
    Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Windows\SoftwareDistribution\DataStore\*" -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-Host "3. Restarting Services..." -ForegroundColor Yellow
    Start-Service -Name $services -ErrorAction SilentlyContinue
    
    # Step 6: Windows Store
    Write-Host "4. Resetting Windows Store (wsreset.exe)..." -ForegroundColor Yellow
    Start-Process -FilePath "wsreset.exe" -NoNewWindow -Wait

    Write-Host "`n[OK] Update & Store Reset Complete." -ForegroundColor Green
    if ($args[0] -ne "-NoPause") { Pause-Script }
}
#endregion

#region Function Group 3: WinSxS Cleanup (Original Function 2)
function Invoke-OriginalWinSxS {
    Write-Host "`n=== WinSxS Cleanup (Component Store) ===" -ForegroundColor Cyan
    Write-Host "Executing DISM to remove obsolete components..." -ForegroundColor Yellow
    Write-Host "Process may take several minutes. Please wait..." -ForegroundColor Cyan
    
    DISM /Online /Cleanup-Image /StartComponentCleanup
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n[OK] WinSxS cleanup completed." -ForegroundColor Green
    } else {
        Write-Host "`n[!] WinSxS cleanup issues detected." -ForegroundColor Red
    }
    if ($args[0] -ne "-NoPause") { Pause-Script }
}
#endregion

#region Function Group 4: Thumbnail Cache (Original Function 3 - Safe Non-Intrusive Cleaning)
function Invoke-OriginalThumbnails {
    Write-Host "`n=== Clear Thumbnail Cache ===" -ForegroundColor Cyan
    Write-Host "Clearing thumbnail cache..." -ForegroundColor Yellow
    
    $thumbCachePath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    if (Test-Path -LiteralPath $thumbCachePath) {
        # Original cleaning logic preserved with literal path processing.
        # No process termination is used to prevent interface flashing; locked files are skipped.
        Get-ChildItem -LiteralPath $thumbCachePath -Filter "thumbcache_*.db" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "Thumbnail cache cleared (locked files skipped)." -ForegroundColor Green
    } else {
        Write-Host "Thumbnail cache path not found." -ForegroundColor Red
    }
    if ($args[0] -ne "-NoPause") { Pause-Script }
}
#endregion

#region Function Group 5: Clipboard, Snipping Tool & Extra Temp (IIS Logs & Minidumps Included)
function Invoke-ExtraCleanup {
    Write-Host "`n=== Cleaning Clipboard, ScreenClips & Extra Temp ===" -ForegroundColor Cyan
    
    # Step 1: Clipboard
    Write-Host "1. Clearing Clipboard & Clipboard History..." -ForegroundColor Yellow
    Set-Clipboard $null -ErrorAction SilentlyContinue
    cmd.exe /c "echo off | clip"
    # Restart Clipboard User Service to clear history effectively
    Restart-Service -Name "cbdhsvc*" -Force -ErrorAction SilentlyContinue

    # Step 2: ScreenClips / Snipping Tool
    Write-Host "2. Cleaning Snipping Tool (ScreenClips)..." -ForegroundColor Yellow
    Remove-Item -Path "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.Core_cw5n1h2txyewy\TempState\ScreenClip\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$env:LOCALAPPDATA\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\TempState\*" -Recurse -Force -ErrorAction SilentlyContinue

    # Step 3: Windows Prefetch
    Write-Host "3. Cleaning Windows Prefetch..." -ForegroundColor Yellow
    Remove-Item -Path "C:\Windows\Prefetch\*" -Recurse -Force -ErrorAction SilentlyContinue

    # Step 4: Crash Dumps & Windows Error Reporting
    Write-Host "4. Cleaning Crash Dumps & Windows Error Reporting..." -ForegroundColor Yellow
    Remove-Item -Path "$env:LOCALAPPDATA\CrashDumps\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\ProgramData\Microsoft\Windows\WER\ReportArchive\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\*" -Recurse -Force -ErrorAction SilentlyContinue

    # Step 5: Recent Items
    Write-Host "5. Cleaning Recent Items History..." -ForegroundColor Yellow
    Remove-Item -Path "$env:APPDATA\Microsoft\Windows\Recent\*" -Recurse -Force -ErrorAction SilentlyContinue

    # Step 6: INetCache
    Write-Host "6. Cleaning INetCache..." -ForegroundColor Yellow
    Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\Windows\INetCache\*" -Recurse -Force -ErrorAction SilentlyContinue

    # Step 7: DNS Cache
    Write-Host "7. Flushing DNS Cache..." -ForegroundColor Yellow
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    ipconfig /flushdns | Out-Null

    # Step 8: IIS HTTPERR Logs & System Minidumps (Safe additions)
    Write-Host "8. Cleaning IIS HTTPERR Logs & Minidumps..." -ForegroundColor Yellow
    Remove-Item -Path "C:\Windows\System32\LogFiles\HTTPERR\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Windows\Minidump\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "`n[OK] Extra Cleanup Complete." -ForegroundColor Green
    if ($args[0] -ne "-NoPause") { Pause-Script }
}
#endregion

#region Function Group 6: Modern Deep System, DO Cache & Event Logs (Excludes GPU Shader Caches)
function Invoke-DeepSystemCleanup {
    Write-Host "`n=== Deep System, DO Cache & Event Logs Cleanup ===" -ForegroundColor Cyan
    
    # Step 1: Windows Delivery Optimization (DO) Cache
    Write-Host "1. Cleaning Delivery Optimization Cache..." -ForegroundColor Yellow
    Remove-Item -Path "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*" -Recurse -Force -ErrorAction SilentlyContinue

    # Step 2: Windows Defender Scan Detection History
    Write-Host "2. Cleaning Windows Defender Detection History..." -ForegroundColor Yellow
    Remove-Item -Path "C:\ProgramData\Microsoft\Windows Defender\Scans\History\Service\DetectionHistory\*" -Recurse -Force -ErrorAction SilentlyContinue

    # Step 3: Windows Event Viewer Logs
    Write-Host "3. Clearing Windows Event Viewer Logs..." -ForegroundColor Yellow
    Get-WinEvent -ListLog * -Force -ErrorAction SilentlyContinue | Where-Object { $_.RecordCount -gt 0 } | ForEach-Object {
        wevtutil.exe cl $_.LogName 2>&1 | Out-Null
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
    Write-Host "   Analyzing current usage... Please wait." -ForegroundColor DarkGray

    # --- Analysis Phase (Mapping to Original & New Paths) ---
    
    # Group 1: Temp, Logs, Bin
    $pathsGroup1 = @(
        "$env:TEMP",
        "C:\Windows\Temp",
        "C:\Windows\Logs",
        "C:\Windows\System32\LogFiles"
    )
    $sizeGroup1 = (Get-PathSize $pathsGroup1) + (Get-RecycleBinSize)

    # Group 2: Windows Update (Download + DataStore)
    $pathsGroup2 = @(
        "C:\Windows\SoftwareDistribution\Download",
        "C:\Windows\SoftwareDistribution\DataStore"
    )
    $sizeGroup2 = Get-PathSize $pathsGroup2

    # Group 4: Thumbnails
    $pathGroup4 = @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer")
    $sizeGroup4 = Get-PathSize $pathGroup4

    # Group 5: Clipboard, Snipping Tool & Extra Temp (Includes HTTPERR and Minidump)
    $pathsGroup5 = @(
        "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.Core_cw5n1h2txyewy\TempState\ScreenClip",
        "$env:LOCALAPPDATA\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\TempState",
        "C:\Windows\Prefetch",
        "$env:LOCALAPPDATA\CrashDumps",
        "C:\ProgramData\Microsoft\Windows\WER\ReportArchive",
        "C:\ProgramData\Microsoft\Windows\WER\ReportQueue",
        "$env:APPDATA\Microsoft\Windows\Recent",
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
        "C:\Windows\System32\LogFiles\HTTPERR",
        "C:\Windows\Minidump"
    )
    $sizeGroup5 = Get-PathSize $pathsGroup5

    # Group 6: Modern Deep System, DO Cache (GPU Shaders are excluded)
    $pathsGroup6 = @(
        "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache",
        "C:\ProgramData\Microsoft\Windows Defender\Scans\History\Service\DetectionHistory"
    )
    $sizeGroup6 = Get-PathSize $pathsGroup6

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
        @{ ID="4"; Name="Thumbnail Cache";                Size=(Format-ByteSize $sizeGroup4); Color="Green" },
        @{ ID="5"; Name="Clipboard, ScreenClips & Extra"; Size=(Format-ByteSize $sizeGroup5); Color="Green" },
        @{ ID="6"; Name="Deep System, DO & Event Logs";   Size=(Format-ByteSize $sizeGroup6); Color="Green" }
    )

    # Display Menu
    foreach ($item in $menu) {
        # Pad string for alignment
        $pad = " " * (35 - $item.Name.Length)
        
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

    switch ($choice) {
        "1" { Invoke-OriginalTempCleanup }
        "2" { Invoke-OriginalUpdateStore }
        "3" { Invoke-OriginalWinSxS }
        "4" { Invoke-OriginalThumbnails }
        "5" { Invoke-ExtraCleanup }
        "6" { Invoke-DeepSystemCleanup }
        { $_ -eq "a" -or $_ -eq "A" } { Invoke-AllCleanups }
        { $_ -eq "x" -or $_ -eq "X" } { exit }
        Default { Write-Host "   Invalid selection." -ForegroundColor Red; Start-Sleep 1 }
    }

} while ($true)