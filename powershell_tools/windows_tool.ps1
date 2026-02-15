<#
    .SYNOPSIS
        Windows Tool

    .DESCRIPTION
        Keybinding Logic:
        - [1-8]: Interface, Visuals & Context Menus.
        - [9-0]: AI & Telemetry.
        - [W/S/D]: Core Components (Winget, Store, Defender).
        - [A,B,C,E,L]: App Manager.
        - [R,N,I]: Runtimes & Frameworks.
        - [X]: Exit.

    .NOTES
        REQUIRES: Administrator Privileges
        COMPATIBILITY: PowerShell 5.1+
        CODING STANDARD: All internal comments must be written in ENGLISH.
#>

# ---------------------------------------------------------------------------
# INITIALIZATION
# ---------------------------------------------------------------------------
$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

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
        Start-Sleep -Seconds 4; Exit
    }
    try {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs
        Exit
    } catch {
        Write-Host " [X] Failed to auto-elevate." -ForegroundColor Red; Start-Sleep 4; Exit
    }
}

# ---------------------------------------------------------------------------
# HELPERS: STATUS CHECKS
# ---------------------------------------------------------------------------

function Get-RegistryStatus {
    param ([string]$Path, [string]$Name, [int]$TargetValue, [bool]$ReverseColor = $false)
    $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($current -eq $null) { $current = 0 }

    if ($current -eq $TargetValue) {
        if ($ReverseColor) { return @{ Text="ENABLED "; Color="Red" } }
        return @{ Text="ENABLED "; Color="Green" }
    } else {
        if ($ReverseColor) { return @{ Text="DISABLED"; Color="Green" } }
        return @{ Text="DISABLED"; Color="DarkGray" }
    }
}

function Get-ContextStatus {
    param ([string]$RegistryPath)
    if (Test-Path $RegistryPath) { return @{ Text="ACTIVE   "; Color="Green" } } 
    else { return @{ Text="DISABLED "; Color="DarkGray" } }
}

function Get-AppStatus {
    param ([string]$SearchPattern, [string]$ExePath, [System.Collections.IDictionary]$AppCache)
    
    # 1. Check Exe Path
    if ($ExePath -and (Test-Path $ExePath)) {
        return @{ Text="INSTALLED"; Color="Green" }
    }
    
    # 2. Check Cache with Wildcard Matching
    foreach ($appName in $AppCache.Keys) {
        if ($appName -like $SearchPattern) {
            return @{ Text="INSTALLED"; Color="Green" }
        }
    }
    
    return @{ Text="MISSING  "; Color="DarkGray" }
}

function Get-DefenderStatus {
    $regValue = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableRealtimeMonitoring" -ErrorAction SilentlyContinue).DisableRealtimeMonitoring
    if ($regValue -eq 0 -or $regValue -eq $null) { return @{ Text="ACTIVE   "; Color="Green" } } 
    else { return @{ Text="DISABLED "; Color="Red" } }
}

function Get-ComponentStatus {
    param ([string]$Name)
    switch ($Name) {
        "WinGet" {
            if (Get-Command "winget" -ErrorAction SilentlyContinue) { return @{ Text="INSTALLED"; Color="Green" } }
            return @{ Text="MISSING  "; Color="Red" }
        }
        "Store" {
            if (Get-AppxPackage -Name "Microsoft.WindowsStore") { return @{ Text="INSTALLED"; Color="Green" } }
            return @{ Text="MISSING  "; Color="Red" }
        }
        "DirectX" {
            if (Test-Path "$env:SystemRoot\System32\d3dx9_43.dll") { return @{ Text="INSTALLED"; Color="Green" } }
            return @{ Text="MISSING  "; Color="DarkGray" }
        }
    }
}

# ---------------------------------------------------------------------------
# HELPERS: ACTIONS & TOGGLES
# ---------------------------------------------------------------------------

function Toggle-Registry {
    param ([string]$Path, [string]$Name, [int]$OnValue, [int]$OffValue, [string]$Desc)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($current -eq $null) { $current = $OffValue }

    if ($current -eq $OnValue) {
        Set-ItemProperty -Path $Path -Name $Name -Value $OffValue -Type DWord -Force
        Write-Host "   [-] $Desc set to DISABLED/OFF." -ForegroundColor Yellow
    } else {
        Set-ItemProperty -Path $Path -Name $Name -Value $OnValue -Type DWord -Force
        Write-Host "   [+] $Desc set to ENABLED/ON." -ForegroundColor Green
    }
}

function Toggle-ExplorerRestart {
    Write-Host "   [!] Restarting Explorer..." -ForegroundColor Cyan
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer }
}

function Toggle-ContextMenu {
    param ([string]$Type)
    switch ($Type) {
        "PowerPlan" {
            $path = "Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan"
            if (Test-Path $path) { Remove-Item $path -Recurse -Force; Write-Host "   [-] Power Plan Menu removed." -ForegroundColor Yellow } 
            else {
                New-Item "$path" -Force | Out-Null; Set-ItemProperty "$path" -Name "MUIVerb" -Value "Choose Power Plan"; Set-ItemProperty "$path" -Name "Icon" -Value "powercpl.dll"; Set-ItemProperty "$path" -Name "Position" -Value "Middle"
                $plans = @{"01"=@("Balanced"; "381b4222-f694-41f0-9685-ff5bb260df2e"); "02"=@("High Performance"; "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")}
                foreach ($k in $plans.Keys) {
                    $sub = "$path\shell\${k}menu"; New-Item $sub -Force | Out-Null; Set-ItemProperty $sub -Name "MUIVerb" -Value $plans[$k][0]; Set-ItemProperty $sub -Name "Icon" -Value "powercpl.dll"
                    New-Item "$sub\command" -Force | Out-Null; Set-ItemProperty "$sub\command" -Name "(default)" -Value "powercfg.exe /setactive $($plans[$k][1])"
                }
                Write-Host "   [+] Power Plan Menu added." -ForegroundColor Green
            }
        }
        "RestartExplorer" {
            $path = "Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\Restart Explorer"
            if (Test-Path $path) { Remove-Item $path -Recurse -Force; Write-Host "   [-] Restart Explorer Menu removed." -ForegroundColor Yellow } 
            else {
                New-Item "$path" -Force | Out-Null; Set-ItemProperty "$path" -Name "Icon" -Value "explorer.exe"; Set-ItemProperty "$path" -Name "Position" -Value "Bottom"
                New-Item "$path\command" -Force | Out-Null; Set-ItemProperty "$path\command" -Name "(default)" -Value "cmd.exe /c taskkill /f /im explorer.exe & start explorer.exe"
                Write-Host "   [+] Restart Explorer Menu added." -ForegroundColor Green
            }
        }
        "TakeOwnership" {
            $path = "Registry::HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership"
            if (Test-Path $path) {
                Remove-Item "Registry::HKEY_CLASSES_ROOT\*\shell\TakeOwnership" -Recurse -Force
                Remove-Item "Registry::HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership" -Recurse -Force
                Write-Host "   [-] Take Ownership Menu removed." -ForegroundColor Yellow
            } else {
                $p1 = "Registry::HKEY_CLASSES_ROOT\*\shell\TakeOwnership"; New-Item $p1 -Force | Out-Null; Set-ItemProperty $p1 -Name "(default)" -Value "Take Ownership"; Set-ItemProperty $p1 -Name "HasLUAShield" -Value ""
                New-Item "$p1\command" -Force | Out-Null; Set-ItemProperty "$p1\command" -Name "(default)" -Value 'cmd.exe /c takeown /f "%1" && icacls "%1" /grant administrators:F'
                $p2 = "Registry::HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership"; New-Item $p2 -Force | Out-Null; Set-ItemProperty $p2 -Name "(default)" -Value "Take Ownership"; Set-ItemProperty $p2 -Name "HasLUAShield" -Value ""
                New-Item "$p2\command" -Force | Out-Null; Set-ItemProperty "$p2\command" -Name "(default)" -Value 'cmd.exe /c takeown /f "%1" /r /d y && icacls "%1" /grant administrators:F /t'
                Write-Host "   [+] Take Ownership Menu added." -ForegroundColor Green
            }
        }
        "ClassicMenu" {
            $path = "Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"
            if (Test-Path $path) { Remove-Item $path -Recurse -Force; Write-Host "   [-] Reverted to Windows 11 Default Menu." -ForegroundColor Yellow } 
            else { New-Item "$path\InprocServer32" -Force | Out-Null; Set-ItemProperty "$path\InprocServer32" -Name "(default)" -Value ""; Write-Host "   [+] Classic Context Menu enabled." -ForegroundColor Green }
            Toggle-ExplorerRestart
        }
    }
    Start-Sleep 2
}

function Toggle-App {
    param ([string]$Name, [string]$WinGetId)
    if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) { Write-Host "   [X] WinGet not found. Cannot manage apps." -ForegroundColor Red; Start-Sleep 2; return }
    Write-Host "   [*] Checking status for $Name..." -ForegroundColor Cyan
    $check = winget list --id $WinGetId --exact --source winget
    if ($check -match $WinGetId) {
        Write-Host "   [-] Uninstalling $Name..." -ForegroundColor Yellow; winget uninstall --id $WinGetId
    } else {
        Write-Host "   [+] Installing $Name..." -ForegroundColor Green; winget install --id $WinGetId -e --accept-package-agreements --accept-source-agreements
    }
    Write-Host "   [OK] Operation complete." -ForegroundColor Green; Start-Sleep 2
}

function Toggle-Defender {
    try {
        if ((Get-DefenderStatus).Text -match "ACTIVE") {
            Write-Host "   [-] Disabling Real-Time Protection..." -ForegroundColor Yellow; Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        } else {
            Write-Host "   [+] Enabling Real-Time Protection..." -ForegroundColor Green; Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        }
        Write-Host "   [OK] Done. Note: Tamper Protection may block this." -ForegroundColor Cyan
    } catch {
        Write-Host "   [X] Failed: $($_.Exception.Message)" -ForegroundColor Red; Write-Host "       Check if Tamper Protection is enabled in Windows Security." -ForegroundColor Gray
    }
    Start-Sleep 2
}

function Install-Repair-Winget {
    if ((Get-ComponentStatus "WinGet").Text -match "INSTALLED") { Write-Host "   [!] WinGet is already installed. Attempting repair..." -ForegroundColor Yellow } 
    else { Write-Host "   [+] Installing/Repairing WinGet..." -ForegroundColor Green }
    try {
        Write-Host "       Installing Microsoft.WinGet.Client module..." -ForegroundColor DarkGray
        if (-not (Get-Module -ListAvailable "Microsoft.WinGet.Client")) { Install-Module -Name Microsoft.WinGet.Client -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop }
        Import-Module -Name Microsoft.WinGet.Client -Force
        Write-Host "       Running Repair-WinGetPackageManager..." -ForegroundColor DarkGray
        Repair-WinGetPackageManager -Force -ErrorAction Stop
        Write-Host "   [OK] WinGet Repaired/Installed successfully." -ForegroundColor Green
    } catch {
        Write-Host "   [!] Module method failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    Start-Sleep 3
}

function Toggle-Store {
    if ((Get-ComponentStatus "Store").Text -match "INSTALLED") {
        Write-Host "   [-] Removing Microsoft Store..." -ForegroundColor Yellow
        Get-AppxPackage -AllUsers *WindowsStore* | Remove-AppxPackage -AllUsers
        Get-AppxPackage -AllUsers *StorePurchaseApp* | Remove-AppxPackage -AllUsers
    } else {
        Write-Host "   [+] Restoring Microsoft Store..." -ForegroundColor Green
        Get-AppxPackage -AllUsers *WindowsStore* | Foreach {Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml"}
        Start-Process "wsreset.exe" -NoNewWindow
    }
    Start-Sleep 2
}

# ---------------------------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------------------------

do {
    Clear-Host
    Write-Host "   ==============================" -ForegroundColor Cyan
    Write-Host "           WINDOWS TOOL          " -ForegroundColor White
    Write-Host "   ==============================" -ForegroundColor Cyan

    # --- PERFORMANCE OPTIMIZATION: Cache the installed apps list ---
    $installedAppsCache = @{}
    $uninstallPaths = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    foreach ($path in $uninstallPaths) {
        Get-ChildItem -Path $path | ForEach-Object { 
            $displayName = $_.GetValue("DisplayName")
            if ($displayName) { $installedAppsCache[$displayName] = $true }
        }
    }

    # --- DRAW MENU ---
    Write-Host "   INTERFACE, VISUALS & CONTEXT MENUS" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    $s = Get-RegistryStatus "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAl" 0; Write-Host "   [1] Taskbar Alignment (Left): " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-RegistryStatus "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "HideFileExt" 0; Write-Host "   [2] Show File Extensions    : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-RegistryStatus "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" "SystemUsesLightTheme" 0; Write-Host "   [3] System Dark Mode        : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-RegistryStatus "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 1; Write-Host "   [4] Taskbar Search Box      : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ContextStatus "Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan"; Write-Host "   [5] Power Plan Context Menu : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ContextStatus "Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\Restart Explorer"; Write-Host "   [6] Restart Explorer Menu   : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ContextStatus "Registry::HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership"; Write-Host "   [7] Take Ownership Menu     : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ContextStatus "Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"; Write-Host "   [8] Win11 Classic Context   : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color

    Write-Host ""
    Write-Host "   AI & TELEMETRY" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    $s = Get-RegistryStatus "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 0 -ReverseColor $true; Write-Host "   [9] Windows Copilot (AI)    : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-RegistryStatus "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 3 -ReverseColor $true; Write-Host "   [0] Windows Telemetry       : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color

    Write-Host ""
    Write-Host "   CORE COMPONENTS & SECURITY" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    $s = Get-ComponentStatus "WinGet"; Write-Host "   [W] Install / Repair WinGet : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ComponentStatus "Store"; Write-Host "   [S] Microsoft Store         : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-DefenderStatus; Write-Host "   [D] Windows Defender (RTP)  : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color

    Write-Host ""
    Write-Host "   RUNTIMES & FRAMEWORKS" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    $s = Get-AppStatus "*Visual C++*Redistributable*" "" $installedAppsCache; Write-Host "   [R] VC++ Redist (2015-2022) : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-AppStatus "*Desktop Runtime*8*" "" $installedAppsCache; Write-Host "   [N] .NET 8 Desktop Runtime  : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ComponentStatus "DirectX"; Write-Host "   [I] DirectX                 : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color

    Write-Host ""
    Write-Host "   APP MANAGER (WinGet)" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    $s = Get-AppStatus "Google Chrome" "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" $installedAppsCache; Write-Host "   [A] Google Chrome           : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-AppStatus "Brave" "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe" $installedAppsCache; Write-Host "   [B] Brave Browser           : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-AppStatus "Mozilla Firefox" "$env:ProgramFiles\Mozilla Firefox\firefox.exe" $installedAppsCache; Write-Host "   [C] Mozilla Firefox         : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-AppStatus "Microsoft Edge" "$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe" $installedAppsCache; Write-Host "   [E] Microsoft Edge          : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-AppStatus "LibreWolf" "$env:ProgramFiles\LibreWolf\librewolf.exe" $installedAppsCache; Write-Host "   [L] LibreWolf               : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color

    Write-Host ""
    Write-Host "   [X] Exit" -ForegroundColor White
    Write-Host ""

    $sel = Read-Host "   Select option to toggle"

    switch ($sel) {
        # INTERFACE
        "1" { Toggle-Registry "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAl" 0 1 "Taskbar Align (Left)"; Toggle-ExplorerRestart }
        "2" { Toggle-Registry "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "HideFileExt" 0 1 "File Extensions"; Toggle-ExplorerRestart }
        "3" { Toggle-Registry "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" "SystemUsesLightTheme" 0 1 "System Dark Mode" }
        "4" { Toggle-Registry "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 1 0 "Search Box"; Toggle-ExplorerRestart }
        "5" { Toggle-ContextMenu "PowerPlan" }
        "6" { Toggle-ContextMenu "RestartExplorer" }
        "7" { Toggle-ContextMenu "TakeOwnership" }
        "8" { Toggle-ContextMenu "ClassicMenu" }
        
        # AI & TELEMETRY
        "9" { Toggle-Registry "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 0 1 "Copilot"; Toggle-ExplorerRestart }
        "0" { Toggle-Registry "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 3 0 "Telemetry" }

        # COMPONENTS
        { $_ -eq "w" } { Install-Repair-Winget }
        { $_ -eq "s" } { Toggle-Store }
        { $_ -eq "d" } { Toggle-Defender }

        # RUNTIMES
        { $_ -eq "r" } { Toggle-App "VC++ Redistributable 2015-2022" "Microsoft.VCRedist.2015+.x64" }
        { $_ -eq "n" } { Toggle-App ".NET 8 Desktop Runtime" "Microsoft.DotNet.DesktopRuntime.8" }
        { $_ -eq "i" } { Toggle-App "DirectX End-User Runtimes" "Microsoft.DirectX" }

        # APPS
        { $_ -eq "a" } { Toggle-App "Google Chrome" "Google.Chrome" }
        { $_ -eq "b" } { Toggle-App "Brave Browser" "Brave.Brave" }
        { $_ -eq "c" } { Toggle-App "Mozilla Firefox" "Mozilla.Firefox" }
        { $_ -eq "e" } { Toggle-App "Microsoft Edge" "Microsoft.Edge" }
        { $_ -eq "l" } { Toggle-App "LibreWolf" "LibreWolf.LibreWolf" }

        { $_ -eq "x" } { exit }
    }

} while ($true)