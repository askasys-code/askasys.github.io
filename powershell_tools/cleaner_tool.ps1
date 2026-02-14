# REQUIRES: Administrator Privileges
# COMPATIBILITY: PowerShell 5.1+
# CODING STANDARD: All internal comments must be written in ENGLISH.

# ---------------------------------------------------------------------------
# INITIALIZATION & SETUP
# ---------------------------------------------------------------------------
$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

#region Core: Admin Privileges Check
function Test-Administrator {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($user)).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Host "`n [!] Administrator privileges are required." -ForegroundColor Yellow
    Write-Host " [!] Restarting as Administrator..." -ForegroundColor White
    
    $scriptPath = $MyInvocation.MyCommand.Definition
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        Write-Host " [X] Error: Could not determine script path." -ForegroundColor Red
        Start-Sleep -Seconds 4; Exit
    }
    try {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs
        Exit
    } catch {
        Write-Host " [X] Auto-elevation failed. Run as Admin manually." -ForegroundColor Red
        Start-Sleep -Seconds 4; Exit
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
        if (Test-Path $p) {
            $measure = Get-ChildItem -Path $p -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            if ($measure) { $total += $measure.Sum }
        }
    }
    return $total
}

function Get-RecycleBinSize {
    try {
        $bin = (New-Object -ComObject Shell.Application).NameSpace(0xA)
        return ($bin.Items() | Measure-Object -Property Size -Sum).Sum
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
    Pause-Script
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
    Pause-Script
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
    Pause-Script
}
#endregion

#region Function Group 4: Thumbnail Cache (Original Function 3)
function Invoke-OriginalThumbnails {
    Write-Host "`n=== Clear Thumbnail Cache ===" -ForegroundColor Cyan
    Write-Host "Clearing thumbnail cache..." -ForegroundColor Yellow
    
    $thumbCachePath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    if (Test-Path $thumbCachePath) {
        # Note: Some files may be locked if Explorer is running, but we stick to original logic
        Get-ChildItem -Path $thumbCachePath -Filter "thumbcache_*.db" | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "Thumbnail cache cleared." -ForegroundColor Green
    } else {
        Write-Host "Thumbnail cache path not found." -ForegroundColor Red
    }
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

    # --- Analysis Phase (Mapping to Original Paths) ---
    
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
        @{ ID="4"; Name="Thumbnail Cache";                Size=(Format-ByteSize $sizeGroup4); Color="Green" }
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
    Write-Host "   [X] Exit" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host "   Select Action"

    switch ($choice) {
        "1" { Invoke-OriginalTempCleanup }
        "2" { Invoke-OriginalUpdateStore }
        "3" { Invoke-OriginalWinSxS }
        "4" { Invoke-OriginalThumbnails }
        { $_ -eq "x" -or $_ -eq "X" } { exit }
        Default { Write-Host "   Invalid selection." -ForegroundColor Red; Start-Sleep 1 }
    }

} while ($true)