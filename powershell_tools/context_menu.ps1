# ==============================================================================
# SCRIPT:        Windows Context Menu & System Manager
# COMPATIBILITY: Windows 10 / Windows 11 (PowerShell 5.1 & PowerShell 7+)
# CODING STANDARD: All internal comments and UI strings must be written in ENGLISH.
# ==============================================================================

$ErrorActionPreference = "Continue"

# Console configuration
$Host.UI.RawUI.WindowTitle = "Windows Context Menu & System Manager"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

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

# ---------------------------------------------------------------------------
# NATIVE .NET REGISTRY HELPERS (Zero escaping/wildcard bugs)
# ---------------------------------------------------------------------------

function Test-HKCRKey ([string]$subKeyPath) {
    try {
        $key = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey($subKeyPath)
        if ($null -ne $key) {
            $key.Close()
            return $true
        }
    } catch {}
    return $false
}

function Set-HKCREntry {
    param (
        [string]$SubKey,
        [string]$DefaultValue = $null,
        [hashtable]$Values = $null
    )
    try {
        $key = [Microsoft.Win32.Registry]::ClassesRoot.CreateSubKey($SubKey)
        if ($null -ne $key) {
            if ($null -ne $DefaultValue) {
                $key.SetValue("", $DefaultValue, [Microsoft.Win32.RegistryValueKind]::String)
            }
            if ($null -ne $Values) {
                foreach ($name in $Values.Keys) {
                    $key.SetValue($name, $Values[$name], [Microsoft.Win32.RegistryValueKind]::String)
                }
            }
            $key.Close()
        }
    } catch {
        Write-Host "   [!] Error setting registry key: $SubKey ($($_.Exception.Message))" -ForegroundColor Red
    }
}

function Remove-HKCREntry ([string]$subKeyPath) {
    try {
        [Microsoft.Win32.Registry]::ClassesRoot.DeleteSubKeyTree($subKeyPath, $false)
    } catch {}
}

function Get-SystemMenuStatus {
    $std = if (Test-HKCRKey "Directory\shell\OpenCmdPrompt\command") { "[ INSTALLED ]" } else { "[ NOT INSTALLED ]" }
    $adm = if (Test-HKCRKey "Directory\shell\runas\command") { "[ INSTALLED ]" } else { "[ NOT INSTALLED ]" }
    $own = if (Test-HKCRKey "*\shell\TakeOwnership\command") { "[ INSTALLED ]" } else { "[ NOT INSTALLED ]" }
    $res = if (Test-HKCRKey "DesktopBackground\shell\RestartExplorer\command") { "[ INSTALLED ]" } else { "[ NOT INSTALLED ]" }

    return @{
        Std = $std
        Adm = $adm
        Own = $own
        Res = $res
    }
}

function Render-StatusItem ([string]$label, [string]$status) {
    Write-Host "    * $label" -NoNewline
    if ($status -like "*NOT*") {
        Write-Host $status -ForegroundColor DarkGray
    } else {
        Write-Host $status -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# COMMAND PROMPT ROUTINES
# ---------------------------------------------------------------------------

function Install-StandardCmd {
    Write-Host "`n   [*] Adding 'Open Command Prompt here'..." -ForegroundColor Cyan
    $cmdVal = 'cmd.exe /s /k pushd "%V"'

    Set-HKCREntry "Directory\shell\OpenCmdPrompt" "Open Command Prompt here" @{ "Icon" = "cmd.exe" }
    Set-HKCREntry "Directory\shell\OpenCmdPrompt\command" $cmdVal

    Set-HKCREntry "Directory\Background\shell\OpenCmdPrompt" "Open Command Prompt here" @{ "Icon" = "cmd.exe"; "NoWorkingDirectory" = "" }
    Set-HKCREntry "Directory\Background\shell\OpenCmdPrompt\command" $cmdVal

    Set-HKCREntry "Drive\shell\OpenCmdPrompt" "Open Command Prompt here" @{ "Icon" = "cmd.exe"; "NoWorkingDirectory" = "" }
    Set-HKCREntry "Drive\shell\OpenCmdPrompt\command" $cmdVal

    Write-Host "   [+] Standard Command Prompt added successfully." -ForegroundColor Green
}

function Install-AdminCmd {
    Write-Host "`n   [*] Adding 'Open Command Prompt here as Administrator'..." -ForegroundColor Cyan
    $cmdVal = 'cmd.exe /s /k pushd "%V"'

    Set-HKCREntry "Directory\shell\runas" "Open Command Prompt here as Administrator" @{ "Icon" = "cmd.exe"; "HasLUAShield" = "" }
    Set-HKCREntry "Directory\shell\runas\command" $cmdVal

    Set-HKCREntry "Directory\Background\shell\runas" "Open Command Prompt here as Administrator" @{ "Icon" = "cmd.exe"; "HasLUAShield" = ""; "NoWorkingDirectory" = "" }
    Set-HKCREntry "Directory\Background\shell\runas\command" $cmdVal

    Set-HKCREntry "Drive\shell\runas" "Open Command Prompt here as Administrator" @{ "Icon" = "cmd.exe"; "HasLUAShield" = ""; "NoWorkingDirectory" = "" }
    Set-HKCREntry "Drive\shell\runas\command" $cmdVal

    Write-Host "   [+] Administrator Command Prompt added successfully." -ForegroundColor Green
}

function Remove-StandardCmd {
    Write-Host "`n   [*] Removing 'Open Command Prompt here'..." -ForegroundColor Cyan
    Remove-HKCREntry "Directory\shell\OpenCmdPrompt"
    Remove-HKCREntry "Directory\Background\shell\OpenCmdPrompt"
    Remove-HKCREntry "Drive\shell\OpenCmdPrompt"
    Write-Host "   [-] Standard Command Prompt removed." -ForegroundColor Yellow
}

function Remove-AdminCmd {
    Write-Host "`n   [*] Removing 'Open Command Prompt here as Administrator'..." -ForegroundColor Cyan
    Remove-HKCREntry "Directory\shell\runas"
    Remove-HKCREntry "Directory\Background\shell\runas"
    Remove-HKCREntry "Drive\shell\runas"
    Write-Host "   [-] Administrator Command Prompt removed." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# TAKE OWNERSHIP ROUTINES
# ---------------------------------------------------------------------------

function Install-TakeOwnership {
    Write-Host "`n   [*] Adding 'Take Ownership' to Files and Folders..." -ForegroundColor Cyan

    $fileCmd = 'powershell.exe -NoProfile -WindowStyle Hidden -Command "Start-Process cmd.exe -ArgumentList ''/c takeown /f \""%1\"" && icacls \""%1\"" /grant *S-1-5-32-544:F'' -Verb RunAs"'
    $dirCmd  = 'powershell.exe -NoProfile -WindowStyle Hidden -Command "Start-Process cmd.exe -ArgumentList ''/c takeown /f \""%1\"" /r /d y && icacls \""%1\"" /grant *S-1-5-32-544:F /t'' -Verb RunAs"'

    # For Files (*)
    Set-HKCREntry "*\shell\TakeOwnership" "Take Ownership" @{ "Icon" = "imageres.dll,-5308"; "HasLUAShield" = "" }
    Set-HKCREntry "*\shell\TakeOwnership\command" $fileCmd

    # For Folders (Directory)
    Set-HKCREntry "Directory\shell\TakeOwnership" "Take Ownership" @{ "Icon" = "imageres.dll,-5308"; "HasLUAShield" = "" }
    Set-HKCREntry "Directory\shell\TakeOwnership\command" $dirCmd

    Write-Host "   [+] 'Take Ownership' added successfully." -ForegroundColor Green
}

function Remove-TakeOwnership {
    Write-Host "`n   [*] Removing 'Take Ownership'..." -ForegroundColor Cyan
    Remove-HKCREntry "*\shell\TakeOwnership"
    Remove-HKCREntry "Directory\shell\TakeOwnership"
    Write-Host "   [-] 'Take Ownership' removed." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# RESTART EXPLORER ROUTINES
# ---------------------------------------------------------------------------

function Install-RestartExplorerMenu {
    Write-Host "`n   [*] Adding 'Restart Windows Explorer' to Context Menus..." -ForegroundColor Cyan
    $cmd = 'cmd.exe /c taskkill /f /im explorer.exe & start explorer.exe'

    Set-HKCREntry "DesktopBackground\shell\RestartExplorer" "Restart Windows Explorer" @{ "Icon" = "shell32.dll,238"; "Position" = "bottom" }
    Set-HKCREntry "DesktopBackground\shell\RestartExplorer\command" $cmd

    Set-HKCREntry "Directory\Background\shell\RestartExplorer" "Restart Windows Explorer" @{ "Icon" = "shell32.dll,238"; "Position" = "bottom" }
    Set-HKCREntry "Directory\Background\shell\RestartExplorer\command" $cmd

    Write-Host "   [+] 'Restart Windows Explorer' added to context menu." -ForegroundColor Green
}

function Remove-RestartExplorerMenu {
    Write-Host "`n   [*] Removing 'Restart Windows Explorer'..." -ForegroundColor Cyan
    Remove-HKCREntry "DesktopBackground\shell\RestartExplorer"
    Remove-HKCREntry "Directory\Background\shell\RestartExplorer"
    Write-Host "   [-] 'Restart Windows Explorer' removed from context menu." -ForegroundColor Yellow
}

function Restart-ExplorerNow {
    Write-Host "`n   [*] Restarting Windows Explorer process..." -ForegroundColor Cyan
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Process explorer.exe
    Write-Host "   [+] Windows Explorer restarted." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# MAIN MENU LOOP
# ---------------------------------------------------------------------------
do {
    Clear-Host
    $isAdmin = Test-IsAdministrator
    $st = Get-SystemMenuStatus

    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "                    WINDOWS CONTEXT MENU & SYSTEM MANAGER                       " -ForegroundColor White
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  --- SYSTEM STATUS ------------------------------------------------------------" -ForegroundColor Cyan
    if ($isAdmin) {
        Write-Host "    * Privilege Level:                       " -NoNewline; Write-Host "Administrator (Full Access)" -ForegroundColor Green
    } else {
        Write-Host "    * Privilege Level:                       " -NoNewline; Write-Host "Standard User (Read-Only - Run CMD as Admin)" -ForegroundColor Yellow
    }

    # Render menu statuses cleanly without inline subexpression errors
    Render-StatusItem "Command Prompt (Standard):             " $st.Std
    Render-StatusItem "Command Prompt (Administrator):        " $st.Adm
    Render-StatusItem "Take Ownership (Files & Folders):      " $st.Own
    Render-StatusItem "Restart Explorer (Context Menu):       " $st.Res
    Write-Host "  ------------------------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  --- BATCH OPERATIONS ---------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "    [1]  Install ALL Features" -ForegroundColor White
    Write-Host "    [2]  Remove ALL Features" -ForegroundColor White
    Write-Host ""
    Write-Host "  --- COMMAND PROMPT TOOLS -----------------------------------------------------" -ForegroundColor Cyan
    Write-Host "    [3]  Install 'Open Command Prompt here'" -ForegroundColor Yellow
    Write-Host "    [4]  Install 'Open Command Prompt here as Administrator'" -ForegroundColor Yellow
    Write-Host "    [5]  Remove  'Open Command Prompt here'" -ForegroundColor Yellow
    Write-Host "    [6]  Remove  'Open Command Prompt here as Administrator'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  --- FILE & PERMISSION TOOLS --------------------------------------------------" -ForegroundColor Cyan
    Write-Host "    [7]  Install 'Take Ownership' (Files & Folders)" -ForegroundColor Yellow
    Write-Host "    [8]  Remove  'Take Ownership'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  --- WINDOWS EXPLORER UTILITIES -----------------------------------------------" -ForegroundColor Cyan
    Write-Host "    [9]  Install 'Restart Explorer' in Desktop/Folder Context Menu" -ForegroundColor Yellow
    Write-Host "    [10] Remove  'Restart Explorer' from Desktop/Folder Context Menu" -ForegroundColor Yellow
    Write-Host "    [11] Restart Windows Explorer Process Now" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    [0]  Exit" -ForegroundColor DarkGray
    Write-Host "================================================================================" -ForegroundColor Cyan

    $choice = (Read-Host "`n  Enter your choice [0-11]").Trim()

    if ($choice -eq "0" -or $choice -match '^(x|exit|quit)$') {
        Clear-Host
        exit 0
    }

    if ($choice -eq "11") {
        Restart-ExplorerNow
        Pause-Script
        continue
    }

    if (-not $isAdmin) {
        Write-Host "`n  [!] Administrator privileges required to modify context menu registry entries." -ForegroundColor Red
        Write-Host "  [i] Please close CMD and launch it via 'Run as administrator'." -ForegroundColor Yellow
        Pause-Script
        continue
    }

    switch ($choice) {
        "1" {
            Install-StandardCmd
            Install-AdminCmd
            Install-TakeOwnership
            Install-RestartExplorerMenu
            Write-Host "`n  [+] All features installed successfully." -ForegroundColor Green
            Pause-Script
        }
        "2" {
            Remove-StandardCmd
            Remove-AdminCmd
            Remove-TakeOwnership
            Remove-RestartExplorerMenu
            Write-Host "`n  [-] All features removed successfully." -ForegroundColor Yellow
            Pause-Script
        }
        "3"  { Install-StandardCmd; Pause-Script }
        "4"  { Install-AdminCmd; Pause-Script }
        "5"  { Remove-StandardCmd; Pause-Script }
        "6"  { Remove-AdminCmd; Pause-Script }
        "7"  { Install-TakeOwnership; Pause-Script }
        "8"  { Remove-TakeOwnership; Pause-Script }
        "9"  { Install-RestartExplorerMenu; Pause-Script }
        "10" { Remove-RestartExplorerMenu; Pause-Script }
        Default {
            Write-Host "  [!] Invalid selection." -ForegroundColor Red
            Start-Sleep -Milliseconds 600
        }
    }
} while ($true)