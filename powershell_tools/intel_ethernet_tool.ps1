<#
.SYNOPSIS
    Intel Ethernet Multi-Adapter Updater (Failsafe Edition)
    
.DESCRIPTION
    Automated tool to check, search, and update MULTIPLE Intel Ethernet Drivers.
    
    Features:
    - Multi-Adapter Support: Detects and iterates through ALL Intel Ethernet adapters (e.g., I219-V AND I226-V).
    - Specific Versioning: Searches based on specific Adapter Name to avoid version mismatches between different chipsets.
    - Hardcoded TLS 1.2 (3072) enforcement.
    - Automatic Administrator elevation.
    - Microsoft Update Catalog scraping.
    - Manual installation helper.
    
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
# Search query placeholder: {0} = Device Name, {1} = Year
$SearchUrlBase = "https://www.catalog.update.microsoft.com/Search.aspx?q={0}+{1}&scol=DateComputed&sdir=desc"

# ---------------------------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------------------------

function Set-SecurityProtocol {
    Write-Host " [CHECK] Setting network security protocol..." -NoNewline
    try {
        # Hardcoded integer 3072 for TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = 3072
        Write-Host " OK." -ForegroundColor Green
    } catch {
        Write-Host " FAIL." -ForegroundColor Red
        throw "FATAL ERROR: Could not set TLS 1.2 (3072)."
    }
}

function Get-LocalDrivers {
    Write-Host " [CHECK] Analyzing local network adapters..." -ForegroundColor Yellow
    try {
        # Get all signed drivers, filter for Class=Net, Manufacturer=Intel
        # Removed "Select-Object -First 1" to capture ALL adapters
        $netDevices = Get-WmiObject Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { 
            $_.DeviceClass -eq "NET" -and 
            $_.Manufacturer -like "*Intel*" -and 
            $_.DeviceName -notlike "*Wireless*" -and 
            $_.DeviceName -notlike "*Wi-Fi*" -and 
            $_.DeviceName -notlike "*Bluetooth*"
        }

        if (-not $netDevices) { 
            Write-Host "   [X] No active Intel Ethernet devices found." -ForegroundColor Red
            return @() 
        }

        return $netDevices
    } catch {
        Write-Host "   [X] WMI Error: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

function Search-Catalog {
    param(
        [string]$DeviceName,
        [int[]]$Years
    )
    
    # Clean the device name for better search results (remove extra chars if needed)
    # Usually searching the full name is accurate for the Catalog
    $searchName = $DeviceName -replace "\(R\)", "" -replace "\(TM\)", ""
    
    Write-Host "   - Scanning Catalog for: " -NoNewline
    Write-Host "$searchName" -ForegroundColor Cyan
    
    $bestVer = [Version]"0.0.0.0"
    $bestYear = $null
    $bestUrl = $null

    foreach ($year in $Years) {
        Write-Host "     > Checking Year $year..." -NoNewline
        $url = $SearchUrlBase -f $searchName, $year
        
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{"User-Agent"=$UserAgent} -TimeoutSec 15 -ErrorAction Stop
            
            # Regex to find driver versions (e.g. 12.19.1.37 or 2.1.3.15)
            $matches = [regex]::Matches($resp.Content, "\d{1,3}\.\d{1,5}\.\d{1,5}\.\d{1,5}")
            
            if ($matches.Count -gt 0) {
                Write-Host " FOUND ($($matches.Count) results)." -ForegroundColor Green
                foreach ($m in $matches) {
                    try {
                        $v = [Version]$m.Value
                        if ($v -gt $bestVer) { 
                            $bestVer = $v 
                            $bestYear = $year
                        }
                    } catch { }
                }
            } else { 
                Write-Host " No results." -ForegroundColor Gray 
            }
        } catch {
            Write-Host " Network Error." -ForegroundColor Red
        }
    }
    
    if ($bestYear) {
        $bestUrl = $SearchUrlBase -f $searchName, $bestYear
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

    $workDir = "$env:TEMP\IntelEthernet_Install_$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    
    try {
        Write-Host "`n [INSTALL] Processing..." -ForegroundColor Yellow
        
        # Extract
        Write-Host "   - Extracting CAB archive..." -ForegroundColor Gray
        $expand = Start-Process "expand" -ArgumentList "`"$userPath`" -F:* `"$workDir`"" -Wait -NoNewWindow -PassThru
        if ($expand.ExitCode -ne 0) { throw "Expansion failed. Ensure the path is correct." }
        
        # Install
        Write-Host "   - Installing via PnPUtil..." -ForegroundColor Gray
        $inst = Start-Process "pnputil.exe" -ArgumentList "/add-driver `"$workDir\*.inf`" /subdirs /install" -Wait -PassThru -NoNewWindow
        
        if ($inst.ExitCode -eq 0 -or $inst.ExitCode -eq 3010) {
            Write-Host "`n [SUCCESS] Driver installed successfully." -ForegroundColor Green
            Write-Host " ==========================================================" -ForegroundColor Red
            Write-Host "  IMPORTANT: REBOOT REQUIRED TO APPLY CHANGES." -ForegroundColor Red
            Write-Host " ==========================================================" -ForegroundColor Red
        } else {
            Write-Host "`n [X] Installation failed. PnPUtil Error Code: $($inst.ExitCode)" -ForegroundColor Red
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
    Write-Host "   INTEL ETHERNET UPDATER (MULTI-DEVICE)  " -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan

    # 1. Setup Network
    Set-SecurityProtocol

    # 2. Local Analysis (Get ALL Adapters)
    $adapters = Get-LocalDrivers
    if ($adapters.Count -eq 0) { throw "No compatible network adapters found." }

    # 3. Process Each Adapter
    $currentYear = [int][DateTime]::Now.Year
    $prevYear = $currentYear - 1
    $yearsToScan = @($currentYear, $prevYear)
    
    Write-Host "`n[INFO] Found $($adapters.Count) Intel Adapter(s)." -ForegroundColor White

    foreach ($device in $adapters) {
        Write-Host "`n----------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host " DEVICE: $($device.DeviceName)" -ForegroundColor Yellow
        
        $localVer = [Version]$device.DriverVersion
        Write-Host "   [LOCAL]  Version: $localVer"
        
        # Search specifically for this device name
        $onlineResult = Search-Catalog -DeviceName $device.DeviceName -Years $yearsToScan

        if ($onlineResult.Version -gt [Version]"0.0.0.0") {
            Write-Host "   [ONLINE] Version: $($onlineResult.Version)" -ForegroundColor Cyan
            
            if ($onlineResult.Version -gt $localVer) {
                Write-Host "`n   [!] UPDATE FOUND FOR THIS ADAPTER!" -ForegroundColor Green -BackgroundColor DarkGreen
                Write-Host "   Direct Link: $($onlineResult.Url)" -ForegroundColor White
                
                $choice = Read-Host "`n   > Install this update now? (Y/N)"
                if ($choice -eq 'Y' -or $choice -eq 'y') {
                    Install-Driver -DownloadUrl $onlineResult.Url
                }
            } else {
                Write-Host "   [OK] Adapter is up to date." -ForegroundColor Green
            }
        } else {
            Write-Host "   [!] No drivers found in Catalog for this specific model." -ForegroundColor Red
        }
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