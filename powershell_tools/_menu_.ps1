#region Setup, Encoding & Auto-Elevation
# --- 1. GLOBAL SETTINGS ---
# Set error preference
$ErrorActionPreference = "SilentlyContinue"

# Set Console Encoding to UTF-8
# Note: Ensure you save this file as "UTF-8 with BOM" in VS Code.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Enable modern security protocols
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# --- 2. ADMIN SELF-ELEVATION ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "`n [!] Administrator privileges required." -ForegroundColor Yellow
    Write-Host " [!] Restarting as Administrator..." -ForegroundColor White
    
    $scriptPath = $MyInvocation.MyCommand.Definition

    if ([string]::IsNullOrWhiteSpace($scriptPath) -or (-not (Test-Path -Path $scriptPath -PathType Leaf))) {
        Write-Host " [X] Error: Script path not found. Please save the file explicitly before running." -ForegroundColor Red
        Start-Sleep -Seconds 4
        Exit
    }

    try {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs -WorkingDirectory $PSScriptRoot
        Exit
    } catch {
        Write-Host " [X] Elevation failed or cancelled by user." -ForegroundColor Red
        Exit
    }
}
#endregion

# --- MASTER LAUNCHER LOGIC ---

# 1. Get current script name to exclude it from the list
$currentScriptName = $MyInvocation.MyCommand.Name

# 2. Get all .ps1 files in the current folder, excluding this launcher
$scriptList = Get-ChildItem -Path $PSScriptRoot -Filter "*.ps1" | Where-Object { $_.Name -ne $currentScriptName }

if ($scriptList.Count -eq 0) {
    Write-Host "`n [!] No other .ps1 scripts found in this folder." -ForegroundColor Yellow
    Write-Host "     Folder: $PSScriptRoot" -ForegroundColor Gray
    Write-Host "`n Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Exit
}

# 3. Menu Loop
while ($true) {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "       POWERSHELL TOOL LAUNCHER           " -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " Path: $PSScriptRoot" -ForegroundColor DarkGray
    Write-Host " Scripts found: $($scriptList.Count)`n" -ForegroundColor Gray

    # Generate Menu Items
    $i = 1
    foreach ($script in $scriptList) {
        # Clean up name for display (remove extension and replace underscores with spaces)
        $displayName = $script.BaseName -replace "_", " " 
        
        # Align numbers nicely
        if ($i -lt 10) { $numPad = " $i" } else { $numPad = "$i" }
        
        Write-Host " [$numPad] $displayName" -ForegroundColor Yellow
        $i++
    }
    
    Write-Host "`n [ Q] Exit" -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan

    # 4. Get User Input
    $selection = Read-Host " Select a tool to run"

    # Handle Exit
    if ($selection -eq 'q' -or $selection -eq 'Q') {
        Write-Host " Exiting..." -ForegroundColor Gray
        Start-Sleep -Seconds 1
        Exit
    }

    # Handle Selection
    if ($selection -match "^\d+$") { # Check if input is a number
        $index = [int]$selection - 1 # Convert to array index (0-based)

        if ($index -ge 0 -and $index -lt $scriptList.Count) {
            $selectedScript = $scriptList[$index]
            
            Clear-Host
            Write-Host "Launching: $($selectedScript.Name)..." -ForegroundColor Green
            Write-Host "------------------------------------------`n"
            
            # --- EXECUTE THE SELECTED SCRIPT ---
            # We use the '&' operator to run it in the current window.
            # Since we are already Admin, the child script inherits Admin rights.
            try {
                & $selectedScript.FullName
            }
            catch {
                Write-Host "`n [X] Error running script: $_" -ForegroundColor Red
            }

            Write-Host "`n------------------------------------------"
            Write-Host " Execution finished. Press any key to return to menu..." -ForegroundColor DarkCyan
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        else {
            Write-Host " [!] Invalid selection number." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
    else {
        Write-Host " [!] Please enter a number or Q." -ForegroundColor Red
        Start-Sleep -Seconds 1
    }
}