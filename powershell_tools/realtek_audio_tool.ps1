<#
.SYNOPSIS
    Realtek Audio Driver Updater
    
.DESCRIPTION
    Automated tool to check, search, and update Realtek Media Drivers.
    
    Features:
    - Hardcoded TLS 1.2 (3072) enforcement for legacy .NET compatibility.
    - Automatic Administrator elevation.
    - Local driver version detection via WMI.
    - Microsoft Update Catalog scraping (Last 2 Years).
    - Manual installation helper (CAB extraction + PnPUtil).
    
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