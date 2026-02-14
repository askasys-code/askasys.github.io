<#
.SYNOPSIS
    Brave Browser Tool
    
.DESCRIPTION
    Keybinding Logic:
    - [1-8]: Toggle specific features.
    - [C]:   Clean Cache (Profiles + DNS Flush).
    - [B]:   Backup Profile (Smart - Excludes Cache).
    - [D]:   Debloat All.
    - [R]:   Restore All.
    - [X]:   Exit.
    
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

# ---------------------------------------------------------------------------
# INITIALIZATION
# ---------------------------------------------------------------------------
$ErrorActionPreference = "SilentlyContinue"

# Admin Check & Auto-Elevation
function Test-Admin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "`n [!] Administrator privileges required." -ForegroundColor Yellow
    Write-Host " [!] Restarting as Administrator..." -ForegroundColor White
    
    $scriptPath = $MyInvocation.MyCommand.Definition
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        Write-Host " [X] Error: Could not determine script path. Run as Admin manually." -ForegroundColor Red
        Start-Sleep -Seconds 4
        Exit
    }

    try {
        # Relaunch the script with RunAs (Admin)
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs
        Exit
    } catch {
        Write-Host " [X] Failed to auto-elevate. Please right-click and 'Run as Administrator'." -ForegroundColor Red
        Start-Sleep -Seconds 4
        Exit
    }
}

# Config
$RegistryPath = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
$BraveProcess = "brave"
$BraveUserDataPath = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
$ScriptPath = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptPath)) { $ScriptPath = [Environment]::GetFolderPath("Desktop") }

# Load .NET Assembly for Zip (Required for custom progress bar)
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Ensure registry path exists
if (-not (Test-Path $RegistryPath)) { New-Item -Path $RegistryPath -Force | Out-Null }

# ---------------------------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------------------------

function Close-Brave {
    # Aggressive process termination check
    $procs = Get-Process -Name $BraveProcess -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host "   [!] Force closing Brave processes..." -ForegroundColor Yellow
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        
        # Active wait loop (Max 5 sec)
        $timer = 0
        while ((Get-Process -Name $BraveProcess -ErrorAction SilentlyContinue) -and ($timer -lt 5)) {
            Start-Sleep -Seconds 1
            $timer++
        }

        if (Get-Process -Name $BraveProcess -ErrorAction SilentlyContinue) {
            Write-Host "   [!] WARNING: Some Brave processes are stuck/locked." -ForegroundColor Red
        } else {
            Write-Host "   [OK] Brave closed successfully." -ForegroundColor DarkGreen
        }
    }
}

function Get-StatusUI {
    param ([string]$KeyName, [string]$LogicType)
    $val = (Get-ItemProperty -Path $RegistryPath -Name $KeyName -ErrorAction SilentlyContinue).$KeyName
    $isClean = $false

    if ($LogicType -eq "DisableKey") {
        if ($val -eq 1) { $isClean = $true }
    } elseif ($LogicType -eq "EnableKey") {
        if ($val -eq 0 -and $val -ne $null) { $isClean = $true }
    }

    if ($isClean) { return @{ Text="DISABLED"; Color="Green" } } 
    else { return @{ Text="ENABLED "; Color="Red" } }
}

function Get-CurrentCacheSize {
    $totalBytes = 0
    
    # 1. Global Caches (User Data Root)
    $GlobalPaths = @("$BraveUserDataPath\ShaderCache", "$BraveUserDataPath\GrShaderCache")
    foreach ($gp in $GlobalPaths) {
        if (Test-Path $gp) {
            $totalBytes += (Get-ChildItem -Path $gp -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        }
    }

    # 2. Per-Profile Caches (Default, Profile 1, Profile 2...)
    if (Test-Path $BraveUserDataPath) {
        $Profiles = Get-ChildItem -Path $BraveUserDataPath -Directory | Where-Object { $_.Name -eq "Default" -or $_.Name -match "^Profile" }
        
        foreach ($p in $Profiles) {
            $SubPaths = @(
                "$($p.FullName)\Cache",
                "$($p.FullName)\Code Cache",
                "$($p.FullName)\GPUCache",
                "$($p.FullName)\Service Worker"
            )
            foreach ($sp in $SubPaths) {
                if (Test-Path $sp) {
                    $totalBytes += (Get-ChildItem -Path $sp -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                }
            }
        }
    }

    if ($totalBytes -gt 1GB) { return "{0:N2} GB" -f ($totalBytes / 1GB) } 
    elseif ($totalBytes -gt 1MB) { return "{0:N2} MB" -f ($totalBytes / 1MB) } 
    else { return "{0:N2} KB" -f ($totalBytes / 1KB) }
}

function Toggle-Feature {
    param ([string]$KeyName, [string]$LogicType, [string]$FeatureName)
    Close-Brave
    $val = (Get-ItemProperty -Path $RegistryPath -Name $KeyName -ErrorAction SilentlyContinue).$KeyName
    
    if ($LogicType -eq "DisableKey") {
        if ($val -eq 1) { Remove-ItemProperty -Path $RegistryPath -Name $KeyName -ErrorAction SilentlyContinue } 
        else { New-ItemProperty -Path $RegistryPath -Name $KeyName -Value 1 -PropertyType DWORD -Force | Out-Null }
    } elseif ($LogicType -eq "EnableKey") {
        if ($val -eq 0 -and $val -ne $null) { Remove-ItemProperty -Path $RegistryPath -Name $KeyName -ErrorAction SilentlyContinue } 
        else { New-ItemProperty -Path $RegistryPath -Name $KeyName -Value 0 -PropertyType DWORD -Force | Out-Null }
    }
}

function Clean-Cache {
    Close-Brave
    Write-Host "`n   --- BRAVE MULTI-PROFILE CLEANER ---" -ForegroundColor Yellow
    
    # Target folders relative to the profile
    $TargetFolders = @("Cache", "Code Cache", "GPUCache", "Service Worker", "ShaderCache") 
    
    # 1. Identify Profiles
    $Profiles = Get-ChildItem -Path $BraveUserDataPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "Default" -or $_.Name -match "^Profile" }
    
    # Add root paths for global ShaderCache
    $PathsToClean = @()
    if (Test-Path "$BraveUserDataPath\ShaderCache") { $PathsToClean += "$BraveUserDataPath\ShaderCache" }
    if (Test-Path "$BraveUserDataPath\GrShaderCache") { $PathsToClean += "$BraveUserDataPath\GrShaderCache" }

    foreach ($p in $Profiles) {
        foreach ($tf in $TargetFolders) {
            $fullPath = Join-Path -Path $p.FullName -ChildPath $tf
            if (Test-Path $fullPath) { $PathsToClean += $fullPath }
        }
    }

    # 2. Execute Cleaning
    foreach ($path in $PathsToClean) {
        try {
            # Check if files exist
            $files = Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            if ($files) {
                # Format path for display (Shorten User Data path)
                $shortName = $path.Replace($BraveUserDataPath, "User Data")
                Remove-Item -Path "$path\*" -Recurse -Force -ErrorAction Stop
                Write-Host "   [CLEANED] $shortName" -ForegroundColor Green
            }
        } catch {
            Write-Host "   [LOCKED]  $($path | Split-Path -Leaf)" -ForegroundColor DarkGray
        }
    }
    
    # 3. DNS Flush
    Write-Host "   [NETWORK] Flushing DNS Cache..." -ForegroundColor DarkCyan
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    
    Write-Host "   Cache cleaning complete." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
}

function Start-Backup {
    Write-Host "`n   --- BRAVE SMART BACKUP ---" -ForegroundColor Yellow
    if (-not (Test-Path $BraveUserDataPath)) { Write-Host "   [ERROR] User Data not found." -ForegroundColor Red; Pause; return }
    
    Close-Brave
    
    $DateStamp = Get-Date -Format "yyyy-MM-dd_HHmm"
    $ZipName = "brave_backup_$DateStamp.zip"
    $DestZip = Join-Path -Path $ScriptPath -ChildPath $ZipName
    
    # Folders to EXCLUDE to save space
    $ExcludeList = @("Cache", "Code Cache", "GPUCache", "ShaderCache", "Service Worker", "BrowserMetrics", "Crashpad", "GrShaderCache")

    try {
        Write-Host "   Indexing files... (Please wait)" -ForegroundColor DarkCyan
        
        # 1. Gather all files first to calculate percentage
        $AllFiles = Get-ChildItem -Path $BraveUserDataPath -Recurse -File -Force -ErrorAction SilentlyContinue
        $FilesToZip = @()

        foreach ($file in $AllFiles) {
            # Check if file path contains any excluded folder
            $shouldExclude = $false
            foreach ($ex in $ExcludeList) {
                if ($file.FullName -match "\\$ex\\") { 
                    $shouldExclude = $true 
                    break 
                }
            }
            if (-not $shouldExclude) {
                $FilesToZip += $file
            }
        }

        $TotalCount = $FilesToZip.Count
        if ($TotalCount -eq 0) { Write-Host "   [ERROR] No files found to backup." -ForegroundColor Red; return }

        # 2. Create Zip using .NET Class for custom progress
        if (Test-Path $DestZip) { Remove-Item $DestZip -Force }
        $ZipArchive = [System.IO.Compression.ZipFile]::Open($DestZip, "Create")
        
        $current = 0
        # Hide cursor for cleaner output
        [Console]::CursorVisible = $false

        foreach ($file in $FilesToZip) {
            $current++
            
            # Calculate relative path for zip structure
            $relativePath = $file.FullName.Substring($BraveUserDataPath.Length + 1)
            
            # Add to zip
            try {
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ZipArchive, $file.FullName, $relativePath) | Out-Null
            } catch {
                # Skip locked files silently or handle error
            }
            
            # Calculate Percentage
            $percent = [math]::Round(($current / $TotalCount) * 100)
            
            # Print simple percentage text: e.g. "BACKUP 13%"
            Write-Host -NoNewline "`r   BACKUP $percent% " -ForegroundColor Cyan
        }
        
        $ZipArchive.Dispose()
        [Console]::CursorVisible = $true
        Write-Host "" # New line after loop finishes

        $Size = (Get-Item $DestZip).Length / 1MB
        Write-Host ("   [SUCCESS] Saved: $ZipName ({0:N2} MB)" -f $Size) -ForegroundColor Green
    } catch { 
        [Console]::CursorVisible = $true
        Write-Host "`n   [ERROR] Backup Failed: $($_.Exception.Message)" -ForegroundColor Red 
    }
    Pause
}

function Set-All {
    param([string]$Mode)
    Close-Brave
    $KeysDisableType = @("BraveRewardsDisabled", "BraveWalletDisabled", "BraveVPNDisabled", "TorDisabled")
    $KeysEnableType = @("BraveAIChatEnabled", "BackgroundModeEnabled", "MetricsReportingEnabled", "IPFSEnabled")
    
    if ($Mode -eq "Restore") {
        foreach ($k in ($KeysDisableType + $KeysEnableType)) {
            Remove-ItemProperty -Path $RegistryPath -Name $k -ErrorAction SilentlyContinue
        }
    } else {
        foreach ($k in $KeysDisableType) { New-ItemProperty -Path $RegistryPath -Name $k -Value 1 -PropertyType DWORD -Force | Out-Null }
        foreach ($k in $KeysEnableType) { New-ItemProperty -Path $RegistryPath -Name $k -Value 0 -PropertyType DWORD -Force | Out-Null }
    }
    Write-Host "   Action completed: $Mode All" -ForegroundColor Green
    Start-Sleep 1
}

# ---------------------------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------------------------

do {
    Clear-Host
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host "      BRAVE BROWSER TOOL      " -ForegroundColor White
    Write-Host "==============================" -ForegroundColor Cyan
    
    # 1. Real-time Cache Size Calculation
    $cacheSize = Get-CurrentCacheSize
    
    # 2. Check Policy Status
    $s1 = Get-StatusUI "BraveRewardsDisabled" "DisableKey"
    $s2 = Get-StatusUI "BraveWalletDisabled" "DisableKey"
    $s3 = Get-StatusUI "BraveVPNDisabled" "DisableKey"
    $s4 = Get-StatusUI "BraveAIChatEnabled" "EnableKey"
    $s5 = Get-StatusUI "TorDisabled" "DisableKey"
    $s6 = Get-StatusUI "BackgroundModeEnabled" "EnableKey"
    $s7 = Get-StatusUI "MetricsReportingEnabled" "EnableKey"
    $s8 = Get-StatusUI "IPFSEnabled" "EnableKey"

    # 3. Display Menu
    Write-Host "   FEATURE TOGGLES" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    Write-Host "   [1] Rewards & Ads : " -NoNewline; Write-Host $s1.Text -ForegroundColor $s1.Color
    Write-Host "   [2] Crypto Wallet : " -NoNewline; Write-Host $s2.Text -ForegroundColor $s2.Color
    Write-Host "   [3] Brave VPN     : " -NoNewline; Write-Host $s3.Text -ForegroundColor $s3.Color
    Write-Host "   [4] Leo AI Chat   : " -NoNewline; Write-Host $s4.Text -ForegroundColor $s4.Color
    Write-Host "   [5] Tor Mode      : " -NoNewline; Write-Host $s5.Text -ForegroundColor $s5.Color
    Write-Host "   [6] Background Run: " -NoNewline; Write-Host $s6.Text -ForegroundColor $s6.Color
    Write-Host "   [7] Telemetry     : " -NoNewline; Write-Host $s7.Text -ForegroundColor $s7.Color
    Write-Host "   [8] IPFS Protocol : " -NoNewline; Write-Host $s8.Text -ForegroundColor $s8.Color
    
    Write-Host ""
    Write-Host "   MAINTENANCE & ACTIONS" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    Write-Host "   [C] Clean Cache & DNS ($cacheSize)" -ForegroundColor Yellow
    Write-Host "   [B] Profile Backup (Zip)" -ForegroundColor Yellow
    Write-Host "   [D] Debloat All" -ForegroundColor Cyan
    Write-Host "   [R] Restore All (Defaults)" -ForegroundColor Magenta
    Write-Host "   [X] Exit" -ForegroundColor White
    Write-Host ""

    $choice = Read-Host "   Select option"

    switch ($choice) {
        "1" { Toggle-Feature "BraveRewardsDisabled" "DisableKey" "Rewards" }
        "2" { Toggle-Feature "BraveWalletDisabled" "DisableKey" "Wallet" }
        "3" { Toggle-Feature "BraveVPNDisabled" "DisableKey" "VPN" }
        "4" { Toggle-Feature "BraveAIChatEnabled" "EnableKey" "AI Chat" }
        "5" { Toggle-Feature "TorDisabled" "DisableKey" "Tor" }
        "6" { Toggle-Feature "BackgroundModeEnabled" "EnableKey" "Background Mode" }
        "7" { Toggle-Feature "MetricsReportingEnabled" "EnableKey" "Telemetry" }
        "8" { Toggle-Feature "IPFSEnabled" "EnableKey" "IPFS" }
        
        { $_ -eq "c" -or $_ -eq "C" } { Clean-Cache }
        { $_ -eq "b" -or $_ -eq "B" } { Start-Backup }
        { $_ -eq "d" -or $_ -eq "D" } { Set-All "Debloat" }
        { $_ -eq "r" -or $_ -eq "R" } { Set-All "Restore" }
        { $_ -eq "x" -or $_ -eq "X" } { Write-Host "   Exiting..."; Start-Sleep 1; exit }
        
        Default { Write-Host "   Invalid selection." -ForegroundColor Red; Start-Sleep 1 }
    }

} while ($true)