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

# Configuration
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
# UPDATED: Added 'Audio' to the search query to avoid generic Card Reader/Bluetooth results
$SearchUrlBase = "https://www.catalog.update.microsoft.com/Search.aspx?q=Realtek+Semiconductor+Corp.+-+MEDIA+-+Audio+{0}&scol=DateComputed&sdir=desc"

# ---------------------------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------------------------

function Set-SecurityProtocol {
    Write-Host " [CHECK] Setting network security protocol..." -NoNewline
    try {
        # Hardcoded integer 3072 for TLS 1.2 to bypass Enum parsing errors on older .NET
        [Net.ServicePointManager]::SecurityProtocol = 3072
        Write-Host " OK." -ForegroundColor Green
    } catch {
        Write-Host " FAIL." -ForegroundColor Red
        throw "FATAL ERROR: Could not set TLS 1.2 (3072)."
    }
}

function Get-LocalDriver {
    Write-Host " [CHECK] Analyzing local driver..." -ForegroundColor Yellow
    try {
        # UPDATED: Stricter filter. Now requires 'Audio' in the DeviceName to avoid picking up Realtek Card Readers or Network Adapters.
        $audioDev = Get-WmiObject Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { 
            ($_.DeviceName -like "*Realtek*Audio*" -or $_.DeviceName -like "*Realtek High Definition*") -and $_.DeviceClass -eq "MEDIA" 
        } | Select-Object -First 1

        if (-not $audioDev) { 
            Write-Host "   [X] No active Realtek audio device found." -ForegroundColor Red
            return $null 
        }

        $ver = [Version]$audioDev.DriverVersion
        Write-Host "   [INFO] Device Found: $($audioDev.DeviceName)" -ForegroundColor Gray
        Write-Host "   [INFO] Local Version: $ver" -ForegroundColor Green
        return $ver
    } catch {
        Write-Host "   [X] WMI Error: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Search-Catalog {
    param([int[]]$Years)
    Write-Host " [CHECK] Scanning Microsoft Catalog..." -ForegroundColor Yellow
    
    $bestVer = [Version]"0.0.0.0"
    $bestYear = $null
    $bestUrl = $null

    foreach ($year in $Years) {
        Write-Host "   - Scanning Year $year..." -NoNewline
        $url = $SearchUrlBase -f $year
        
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{"User-Agent"=$UserAgent} -TimeoutSec 15 -ErrorAction Stop
            
            # Regex to find Version numbers (standard Realtek format 6.0.xxxx.xxxx)
            $matches = [regex]::Matches($resp.Content, "6\.0\.\d{4,5}\.\d{1,5}")
            
            if ($matches.Count -gt 0) {
                Write-Host " FOUND ($($matches.Count) results)." -ForegroundColor Green
                foreach ($m in $matches) {
                    $v = [Version]$m.Value
                    if ($v -gt $bestVer) { 
                        $bestVer = $v 
                        $bestYear = $year
                    }
                }
            } else { 
                Write-Host " No results." -ForegroundColor Gray 
            }
        } catch {
            Write-Host " Network Error." -ForegroundColor Red
        }
    }
    
    if ($bestYear) {
        $bestUrl = $SearchUrlBase -f $bestYear
    }

    return @{ Version = $bestVer; Year = $bestYear; Url = $bestUrl }
}

function Install-Driver {
    param([string]$DownloadUrl)
    
    Write-Host "`n ----------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " MANUAL INSTALLATION WIZARD" -ForegroundColor Cyan
    Write-Host " ----------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " 1. Download the .CAB file from the link below:"
    Write-Host "    $DownloadUrl" -ForegroundColor Yellow
    Write-Host " 2. Copy the full path of the downloaded .CAB file."
    
    $userPath = Read-Host "`n > Paste .CAB file path here (or press Enter to exit)"
    
    if ([string]::IsNullOrWhiteSpace($userPath)) { return }
    
    $userPath = $userPath -replace '"',''
    if (-not (Test-Path $userPath)) { 
        Write-Host "   [X] File not found." -ForegroundColor Red
        return
    }

    $workDir = "$env:TEMP\Realtek_Install_$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    
    try {
        Write-Host "`n [INSTALL] Processing..." -ForegroundColor Yellow
        
        # Extract
        Write-Host "   - Extracting CAB archive..." -ForegroundColor Gray
        $expand = Start-Process "expand" -ArgumentList "`"$userPath`" -F:* `"$workDir`"" -Wait -NoNewWindow -PassThru
        if ($expand.ExitCode -ne 0) { throw "Expansion failed." }
        
        # Install
        # NOTE: DCH Drivers contain multiple components (Extension, Component, Media). 
        # Using /subdirs is necessary to ensure the Audio Console works, even if it looks like it's adding many files.
        Write-Host "   - Installing via PnPUtil (This may list multiple components)..." -ForegroundColor Gray
        $inst = Start-Process "pnputil.exe" -ArgumentList "/add-driver `"$workDir\*.inf`" /subdirs /install" -Wait -PassThru -NoNewWindow
        
        if ($inst.ExitCode -eq 0 -or $inst.ExitCode -eq 3010) {
            Write-Host "`n [SUCCESS] Driver installed successfully." -ForegroundColor Green
            Write-Host " ==========================================================" -ForegroundColor Red
            Write-Host "  IMPORTANT: REBOOT REQUIRED TO APPLY CHANGES." -ForegroundColor Red
            Write-Host " ==========================================================" -ForegroundColor Red
        } else {
            Write-Host "`n [X] Installation failed. Error Code: $($inst.ExitCode)" -ForegroundColor Red
        }
    } catch {
        Write-Host "   [X] Process Error: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        # Cleanup
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# MAIN EXECUTION
# ---------------------------------------------------------------------------

try {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "            REALTEK AUDIO TOOL            " -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan

    # 1. Setup Network
    Set-SecurityProtocol

    # 2. Local Analysis
    $localVer = Get-LocalDriver
    if (-not $localVer) { throw "Driver detection failed. Ensure a Realtek AUDIO device is present." }

    # 3. Online Search
    $dateStr = Get-Date -Format "yyyy"
    if ($dateStr -is [array]) { $dateStr = $dateStr[0] }
    $currentYear = [int]$dateStr
    $prevYear = $currentYear - 1
    $yearsToScan = @($currentYear, $prevYear)
    
    $onlineResult = Search-Catalog -Years $yearsToScan

    # 4. Results & Comparison
    Write-Host "`n ----------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " FINAL SUMMARY" -ForegroundColor White
    Write-Host "   Your Version   : $localVer"
    
    if ($onlineResult.Version -gt [Version]"0.0.0.0") {
        Write-Host "   Online Version : $($onlineResult.Version)" -ForegroundColor Cyan
        
        if ($onlineResult.Version -gt $localVer) {
            Write-Host "`n [!] NEW UPDATE AVAILABLE!" -ForegroundColor Green -BackgroundColor DarkGreen
            Write-Host "`n DIRECT LINK (Ctrl+Click to Open):" -ForegroundColor Yellow
            Write-Host " $($onlineResult.Url)" -ForegroundColor White
            
            # 5. Trigger Install Wizard
            Install-Driver -DownloadUrl $onlineResult.Url
        } else {
            Write-Host "`n [OK] System is already up to date." -ForegroundColor Green
        }
    } else {
        Write-Host "   [!] No compatible drivers found online." -ForegroundColor Red
    }

} catch {
    Write-Host "`n ==========================================================" -ForegroundColor Red
    Write-Host "   FATAL ERROR - SCRIPT HALTED" -ForegroundColor Red
    Write-Host " =========================================================="
    Write-Host " REASON: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host " ----------------------------------------------------------"
} finally {
    Write-Host "`nScript finished. Press Enter to exit."
    $null = Read-Host
}