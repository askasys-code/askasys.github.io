# REQUIRES: Administrator Privileges
# COMPATIBILITY: PowerShell 5.1+
# CODING STANDARD: All internal comments must be written in ENGLISH.

# ---------------------------------------------------------------------------
# INITIALIZATION & SETUP
# ---------------------------------------------------------------------------

#region Setup, Encoding & Auto-Elevation
# --- 1. GLOBAL SETTINGS ---
# Set error preference to Continue to avoid masking critical runtime script errors
$ErrorActionPreference = "Continue"

# Set Console Encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Enable modern security protocols safely (TLS 1.2 as base, TLS 1.3 if supported by .NET)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ([System.Enum]::IsDefined([Net.SecurityProtocolType], 'Tls13')) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13
}

# --- 2. ADMIN SELF-ELEVATION ---
# Check and enforce Administrator privileges at startup
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
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

#region Global Variables
function Draw-Header {
    param ([string]$Title)
    Clear-Host
    Write-Host ""
    Write-Host "  ::::::::::::::::::::::::::::::::::::::::::::::::::::::::" -ForegroundColor DarkCyan
    Write-Host "     WINDOWS SYSTEM REPAIR TOOL" -ForegroundColor Cyan
    Write-Host "     $Title" -ForegroundColor White
    Write-Host "  ::::::::::::::::::::::::::::::::::::::::::::::::::::::::" -ForegroundColor DarkCyan
    Write-Host "  System: $env:COMPUTERNAME | User: $env:USERNAME" -ForegroundColor DarkGray
    Write-Host "  Date: $(Get-Date -Format 'yyyy-MM-dd')" -ForegroundColor DarkGray
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
}

function Pause-Script {
    Write-Host ""
    Write-Host "  Press any key to return to menu..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Core Utilities
function Check-Internet {
    try {
        # Perform a fast, lightweight HTTP HEAD request to Microsoft's official connectivity endpoint
        $request = [System.Net.HttpWebRequest]::Create("http://www.msftconnecttest.com/connecttest.txt")
        $request.Method = "HEAD"
        $request.Timeout = 5000 # 5 seconds timeout
        $response = $request.GetResponse()
        $response.Close()
        return $true
    } catch {
        return $false
    }
}
#endregion

#region Tool 1: SFC Scan
function Run-SFCScan {
    Draw-Header "SYSTEM FILE CHECKER (SFC)"
    
    Write-Host "Initializing SFC Scanner..." -ForegroundColor Cyan
    Write-Host "This utility scans protected system files and replaces corrupted files." -ForegroundColor Gray
    Write-Host "Status: Running..." -ForegroundColor Yellow
    Write-Host ""
    
    $process = Start-Process "sfc" -ArgumentList "/scannow" -NoNewWindow -Wait -PassThru
    
    Write-Host ""
    if ($process.ExitCode -eq 0) {
        Write-Host "SUCCESS: Windows Resource Protection did not find any integrity violations." -ForegroundColor Green
    }
    elseif ($process.ExitCode -eq 1) {
        Write-Host "ERROR: Windows Resource Protection could not perform the requested operation." -ForegroundColor Red
    }
    else {
        Write-Host "INFO: Scan complete. Review output above for details." -ForegroundColor White
        Write-Host "Detailed logs located at: C:\Windows\Logs\CBS\CBS.log" -ForegroundColor Gray
    }
    
    Pause-Script
}
#endregion

#region Tool 2: CHKDSK
function Run-CHKDSK {
    Draw-Header "CHECK DISK UTILITY (CHKDSK)"
    
    Write-Host "Available Drives:" -ForegroundColor Cyan
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    foreach ($d in $drives) {
        if ($d.Free -ne $null) {
            Write-Host "  [$($d.Name)] Free: $([math]::round($d.Free/1GB,2)) GB" -ForegroundColor White
        }
    }
    Write-Host ""
    
    $driveInput = Read-Host "  Select Drive Letter (Default: C)"
    if ([string]::IsNullOrWhiteSpace($driveInput)) { 
        $drive = "C:" 
    } else { 
        $cleanInput = $driveInput.Trim()
        if ($cleanInput.Length -gt 0) {
            $drive = $cleanInput.Substring(0,1).ToUpper() + ":"
        } else {
            $drive = "C:"
        }
    }
    
    if (-not (Test-Path $drive -ErrorAction SilentlyContinue)) {
        Write-Host "Error: Drive $drive not found." -ForegroundColor Red
        Pause-Script
        return
    }

    Write-Host ""
    Write-Host "Select Scan Mode:" -ForegroundColor Cyan
    Write-Host "1. Scan Only (Read-only, fast)" -ForegroundColor Green
    Write-Host "2. Standard Repair (/F) - Fixes filesystem errors" -ForegroundColor Yellow
    Write-Host "3. Deep Repair (/R) - Fixes sectors (Takes hours)" -ForegroundColor Magenta
    Write-Host "4. Full Repair (/F /R) - Maximum recovery" -ForegroundColor Red
    
    $mode = Read-Host "  Choice [1-4]"
    
    $params = switch ($mode) {
        "2" { "/f" }
        "3" { "/r" }
        "4" { "/f /r" }
        default { "/scan" }
    }
    
    Draw-Header "CHKDSK EXECUTION ($drive $params)"
    Write-Host "Starting Check Disk..." -ForegroundColor Yellow
    
    if ($params -ne "/scan" -and $drive -eq "C:") {
        Write-Host "WARNING: System drive selected for repair." -ForegroundColor Red
        Write-Host "The computer must restart to perform this action." -ForegroundColor Red
        $confirm = Read-Host "  Schedule for next restart? (Y/N)"
        if ($confirm -ieq "Y") {
            try {
                cmd.exe /c "echo y | chkdsk $drive $params" | Out-Null
                Write-Host "SUCCESS: Disk check scheduled for next reboot." -ForegroundColor Green
            } catch {
                Write-Host "ERROR: Could not schedule check." -ForegroundColor Red
            }
        }
    } else {
        try {
            cmd.exe /c "chkdsk $drive $params"
            Write-Host "Operation Completed." -ForegroundColor Green
        } catch {
            Write-Host "Execution Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    Pause-Script
}
#endregion

#region Tool 3: DISM Health Check
function Run-DISMCheck {
    Draw-Header "DEPLOYMENT IMAGE SERVICING (DISM)"
    
    Write-Host "This tool fixes the Windows System Image component store." -ForegroundColor Cyan
    Write-Host "Internet connection is recommended for repair operations." -ForegroundColor Gray
    Write-Host ""
    
    Write-Host "[Step 1/3] CheckHealth (Fast diagnostic)..." -ForegroundColor Yellow
    $p1 = Start-Process "DISM" -ArgumentList "/Online /Cleanup-Image /CheckHealth" -NoNewWindow -Wait -PassThru
    if ($p1.ExitCode -ne 0) { Write-Host "Issues detected in CheckHealth." -ForegroundColor Red }
    
    Write-Host ""
    Write-Host "[Step 2/3] ScanHealth (Deep scan, takes time)..." -ForegroundColor Yellow
    $p2 = Start-Process "DISM" -ArgumentList "/Online /Cleanup-Image /ScanHealth" -NoNewWindow -Wait -PassThru
    
    Write-Host ""
    Write-Host "[Step 3/3] RestoreHealth (Repair)..." -ForegroundColor Yellow
    
    if (Check-Internet) {
        $p3 = Start-Process "DISM" -ArgumentList "/Online /Cleanup-Image /RestoreHealth" -NoNewWindow -Wait -PassThru
        if ($p3.ExitCode -eq 0) {
            Write-Host "SUCCESS: Image repair completed successfully." -ForegroundColor Green
        } else {
            Write-Host "WARNING: RestoreHealth encountered errors." -ForegroundColor Red
        }
    } else {
        Write-Host "ERROR: No Internet Connection detected. Skipping RestoreHealth." -ForegroundColor Red
        Write-Host "DISM requires Windows Update access to download repair files." -ForegroundColor Gray
    }

    Pause-Script
}
#endregion

#region Tool 4: Auto-Pilot (Run All)
function Run-AutoPilot {
    Draw-Header "AUTO-PILOT REPAIR SEQUENCE"
    Write-Host "Automated sequence initiated." -ForegroundColor Cyan
    Write-Host "Sequence: DISM -> SFC -> CHKDSK (Scan)" -ForegroundColor Gray
    Write-Host ""
    
    Write-Host ">>> STARTING DISM RESTORE..." -ForegroundColor Magenta
    if (Check-Internet) {
        cmd.exe /c "DISM /Online /Cleanup-Image /RestoreHealth"
    } else {
        Write-Host "Skipping DISM (No Internet)." -ForegroundColor Red
    }
    
    Write-Host ""
    Write-Host ">>> STARTING SFC SCAN..." -ForegroundColor Magenta
    cmd.exe /c "sfc /scannow"
    
    Write-Host ""
    Write-Host ">>> STARTING CHKDSK (SCAN MODE)..." -ForegroundColor Magenta
    cmd.exe /c "chkdsk C: /scan"
    
    Write-Host ""
    Write-Host "Auto-Pilot Sequence Complete." -ForegroundColor Green
    Pause-Script
}
#endregion

#region Main Menu Logic
function Show-Menu {
    Draw-Header "MAIN MENU"
    
    Write-Host "  REPAIR TOOLS" -ForegroundColor Yellow
    Write-Host "  [1] SFC Scan" -ForegroundColor Cyan -NoNewline; Write-Host "           Repairs corrupted system files" -ForegroundColor Gray
    Write-Host "  [2] CHKDSK Utility" -ForegroundColor Cyan -NoNewline; Write-Host "     Fixes file system & disk errors" -ForegroundColor Gray
    Write-Host "  [3] DISM Image Repair" -ForegroundColor Cyan -NoNewline; Write-Host "  Restores Windows Component Store" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  AUTOMATION" -ForegroundColor Yellow
    Write-Host "  [4] Run All Repairs" -ForegroundColor Magenta -NoNewline; Write-Host "    Execute 3 -> 1 -> 2 sequentially" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [0] Exit Application" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host "  Select Option"
    return $choice
}
#endregion

#region Script Initialization
# Main execution loop
do {
    $selection = Show-Menu
    switch ($selection) {
        "1" { Run-SFCScan }
        "2" { Run-CHKDSK }
        "3" { Run-DISMCheck }
        "4" { Run-AutoPilot }
        "0" { 
            Clear-Host
            Write-Host "Exiting WinCare..." -ForegroundColor Green
            Start-Sleep -Seconds 1
            break 
        }
    }
} while ($selection -ne "0")
#endregion