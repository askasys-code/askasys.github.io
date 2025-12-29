# WinCare: Windows Maintenance Menu
# Compatible with PowerShell 5.1
# Author: askasys
# Description: Menu-driven tool for Windows system integrity, cleanup, and configuration tasks.

#region Core Utilities
# Function to check if running as Administrator
function Test-Administrator {
    (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
#endregion

#region Tool 1: System File Checker
function Run-SFCScan {
    Write-Host "Executing SFC /scannow to scan and repair corrupted system files..." -ForegroundColor Yellow
    Write-Host "Process may take several minutes. Please wait..." -ForegroundColor Cyan
    
    sfc /scannow
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "SFC scan completed without errors." -ForegroundColor Green
    } else {
        Write-Host "SFC scan detected issues. Review CBS.log for details." -ForegroundColor Red
    }
    Write-Host "Press any key to continue..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 2: CHKDSK
function Run-CHKDSK {
    Write-Host "Executing CHKDSK for disk error scanning and repair..." -ForegroundColor Yellow
    
    do {
        Write-Host "Select drive (e.g., C:) or press Enter for C:" -ForegroundColor Cyan
        $drive = Read-Host "Drive letter"
        if ([string]::IsNullOrWhiteSpace($drive)) { $drive = "C:" }
        
        if ($drive -notmatch ':') { $drive += ":" }
        
        if (Test-Path $drive -PathType Container) {
            break
        }
        Write-Host "Invalid drive letter or path not found: $drive" -ForegroundColor Red
    } while ($true)
    
    Write-Host "Options:" -ForegroundColor Cyan
    Write-Host "1. Scan only (/scan)" -ForegroundColor White
    Write-Host "2. Fix errors (/f)" -ForegroundColor White
    Write-Host "3. Recover bad sectors (/r)" -ForegroundColor White
    Write-Host "4. Full repair (/f /r)" -ForegroundColor White
    $option = Read-Host "Choice (1-4)"
    
    $params = switch ($option) {
        "1" { "/scan" }
        "2" { "/f" }
        "3" { "/r" }
        "4" { "/f /r" }
        default { "/scan" }
    }
    
    $fullCmd = "chkdsk $drive $params"
    Write-Host "Running: $fullCmd (may require reboot if drive in use)..." -ForegroundColor Yellow
    
    try {
        & chkdsk $drive $params
        if ($LASTEXITCODE -eq 0) {
            Write-Host "CHKDSK completed successfully." -ForegroundColor Green
        } else {
            Write-Host "CHKDSK detected issues. Reboot recommended." -ForegroundColor Red
        }
    } catch {
        Write-Host "Error executing CHKDSK: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host "Press any key to continue..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 3: DISM Health Check
function Run-DISMCheck {
    Write-Host "Executing DISM to validate and restore Windows image integrity..." -ForegroundColor Yellow
    Write-Host "Process may take several minutes; internet required for repairs. Please wait..." -ForegroundColor Cyan
    
    DISM /Online /Cleanup-Image /CheckHealth
    DISM /Online /Cleanup-Image /ScanHealth
    DISM /Online /Cleanup-Image /RestoreHealth
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "DISM operations completed successfully." -ForegroundColor Green
    } else {
        Write-Host "DISM detected issues. Verify connectivity; review DISM.log." -ForegroundColor Red
    }
    Write-Host "Press any key to continue..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 4: Thumbnail Cache
function Clear-ThumbnailCache {
    Write-Host "Clearing thumbnail cache to fix display issues and free space..." -ForegroundColor Yellow
    $thumbCachePath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    if (Test-Path $thumbCachePath) {
        Get-ChildItem -Path $thumbCachePath -Filter "thumbcache_*.db" | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "Thumbnail cache cleared." -ForegroundColor Green
    } else {
        Write-Host "Thumbnail cache path not found." -ForegroundColor Red
    }
    Write-Host "Press any key to continue..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 5: Advanced Disk Cleanup
function Run-AdvancedDiskCleanup {
    Clear-Host
    Write-Host "=== Advanced Disk Cleanup ===" -ForegroundColor Cyan
    
    # Helper to get space
    function Get-FreeSpaceGB {
        $disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
        return [math]::Round($disk.FreeSpace / 1GB, 2)
    }

    $startSpace = Get-FreeSpaceGB
    Write-Host "Initial Free Space: $startSpace GB" -ForegroundColor Green
    Write-Host ""

    # Define cleanup steps
    $steps = @(
        @{ID=1; Name="User Temporary Files"; Desc="Files in $env:TEMP"},
        @{ID=2; Name="System Temporary Files"; Desc="Files in C:\Windows\Temp"},
        @{ID=3; Name="Recycle Bin"; Desc="Empty all items"},
        @{ID=4; Name="Windows Update Cache"; Desc="Stops wuauserv, cleans SoftwareDistribution"},
        @{ID=5; Name="System Log Files"; Desc="Deletes .log files in Windows/Logs"},
        @{ID=6; Name="Windows Store Cache"; Desc="Runs wsreset.exe"}
    )

    $totalSteps = $steps.Count
    $currentStep = 0

    foreach ($step in $steps) {
        # Calculate Percentage (Integer)
        $percent = [math]::Round(($currentStep / $totalSteps) * 100)
        
        Write-Host "--------------------------------------------------" -ForegroundColor Gray
        Write-Host "[Progress: $percent%]" -ForegroundColor Yellow
        Write-Host "Step $($step.ID): $($step.Name)" -ForegroundColor Cyan
        Write-Host "Target: $($step.Desc)" -ForegroundColor White
        
        $confirm = Read-Host "Execute this step? (Y/N)"
        if ($confirm -eq "Y" -or $confirm -eq "y") {
            try {
                switch ($step.ID) {
                    1 { 
                        Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue 
                        Write-Host "User Temp cleared." -ForegroundColor Green
                    }
                    2 { 
                        Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue 
                        Write-Host "System Temp cleared." -ForegroundColor Green
                    }
                    3 { 
                        Clear-RecycleBin -Force -ErrorAction SilentlyContinue 
                        Write-Host "Recycle Bin emptied." -ForegroundColor Green
                    }
                    4 { 
                        Write-Host "Stopping Windows Update Service..." -ForegroundColor Yellow
                        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
                        Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
                        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
                        Write-Host "Update Cache cleared." -ForegroundColor Green
                    }
                    5 { 
                        Remove-Item -Path "C:\Windows\Logs\*.log" -Recurse -Force -ErrorAction SilentlyContinue
                        Remove-Item -Path "C:\Windows\System32\LogFiles\*.log" -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Host "Logs cleared." -ForegroundColor Green
                    }
                    6 { 
                        Write-Host "Resetting Store (Wait)..." -ForegroundColor Yellow
                        Start-Process -FilePath "wsreset.exe" -NoNewWindow -Wait
                        Write-Host "Store cache reset." -ForegroundColor Green
                    }
                }
            } catch {
                Write-Host "Error during step $($step.ID): $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            Write-Host "Skipped." -ForegroundColor Gray
        }
        $currentStep++
    }

    Write-Host "--------------------------------------------------" -ForegroundColor Gray
    Write-Host "[Progress: 100%]" -ForegroundColor Yellow
    
    $endSpace = Get-FreeSpaceGB
    $reclaimed = [math]::Round($endSpace - $startSpace, 2)
    
    Write-Host ""
    Write-Host "Cleanup Complete." -ForegroundColor Cyan
    Write-Host "Final Free Space: $endSpace GB" -ForegroundColor Green
    Write-Host "Space Reclaimed:  $reclaimed GB" -ForegroundColor Green
    
    Write-Host "Press any key to continue..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 6: WinSxS Cleanup
function Run-DISMCleanupWinSxS {
    Write-Host "Executing DISM WinSxS cleanup to remove obsolete components..." -ForegroundColor Yellow
    Write-Host "Process may take several minutes; reboot may be needed. Please wait..." -ForegroundColor Cyan
    
    DISM /Online /Cleanup-Image /StartComponentCleanup
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "WinSxS cleanup completed." -ForegroundColor Green
    } else {
        Write-Host "WinSxS cleanup issues detected. Review DISM.log." -ForegroundColor Red
    }
    Write-Host "Press any key to continue..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 7: Execution Policy
function Set-ExecutionPolicyMenu {
    do {
        Clear-Host
        Write-Host "=== PowerShell Execution Policy Configuration ===" -ForegroundColor Cyan
        Write-Host ""

        Write-Host "Current Policies by Scope:" -ForegroundColor White
        $policiesList = Get-ExecutionPolicy -List
        $effectivePolicy = Get-ExecutionPolicy

        $policiesList | Format-Table -AutoSize
        Write-Host "Effective Policy: $($effectivePolicy)" -ForegroundColor Green
        Write-Host ""

        $policies = @{
            "1" = "Restricted"
            "2" = "AllSigned"
            "3" = "RemoteSigned"
            "4" = "Unrestricted"
            "5" = "Bypass"
        }
        $scopes = @{
            "A" = "LocalMachine"
            "B" = "CurrentUser"
            "C" = "Process"
        }

        Write-Host "Select Policy:" -ForegroundColor Cyan
        Write-Host "1. Restricted (Blocks all scripts)"
        Write-Host "2. AllSigned (Requires signatures)"
        Write-Host "3. RemoteSigned (Local OK; remote signed)"
        Write-Host "4. Unrestricted (Allows all; remote warnings)"
        Write-Host "5. Bypass (No restrictions)"
        Write-Host "0. Back"
        Write-Host ""

        $policyChoice = Read-Host "Choice (0-5)"
        if ($policyChoice -eq "0") { break }
        if (-not $policies.ContainsKey($policyChoice)) {
             Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1
             continue
        }
        $selectedPolicy = $policies[$policyChoice]

        Write-Host "`nSelect Scope:" -ForegroundColor Cyan
        Write-Host "A. LocalMachine (System-wide; Admin required)"
        Write-Host "B. CurrentUser (User-specific)"
        Write-Host "C. Process (Session-only)"
        Write-Host "0. Back"
        Write-Host ""

        $scopeChoice = Read-Host "Choice (A-C or 0)"
        if ($scopeChoice -eq "0") { continue }
        if (-not $scopes.ContainsKey($scopeChoice)) {
             Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1
             continue
        }
        $selectedScope = $scopes[$scopeChoice]

        if ($selectedScope -eq "LocalMachine" -and -not (Test-Administrator)) {
            Write-Host "`nERROR: Requires Admin privileges." -ForegroundColor Red
            Write-Host "Press any key..." -ForegroundColor Gray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            continue
        }

        Write-Host "`nSet '$selectedPolicy' for '$selectedScope'? (Y/N)" -ForegroundColor Red
        $confirm = Read-Host

        if ($confirm -ne "Y" -and $confirm -ne "y") {
            Write-Host "Cancelled." -ForegroundColor Yellow
        } else {
            try {
                Set-ExecutionPolicy -ExecutionPolicy $selectedPolicy -Scope $selectedScope -Force -ErrorAction Stop
                Write-Host "`nSUCCESS: Policy set to '$selectedPolicy'." -ForegroundColor Green
                Write-Host "Verification: $(Get-ExecutionPolicy -Scope $selectedScope)" -ForegroundColor White
            } catch {
                Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "Group Policy may override." -ForegroundColor Yellow
            }
        }

        Write-Host "`nPress any key..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

    } while ($true)
}
#endregion

#region Tool 8: Recall & Copilot
function Disable-RecallAndCopilot {
    Clear-Host
    Write-Host "=== Disable Recall and Copilot ===" -ForegroundColor Cyan
    Write-Host ""
    
    # --- Disable Recall ---
    Write-Host "Checking Recall..." -ForegroundColor Yellow
    $recallStatus = Get-WindowsOptionalFeature -Online -FeatureName "Recall" -ErrorAction SilentlyContinue
    
    if ($recallStatus -and $recallStatus.State -eq "Enabled") {
        Write-Host "Recall enabled. Disable? (Y/N)" -ForegroundColor Red
        $disableRecall = Read-Host
        if ($disableRecall -eq "Y" -or $disableRecall -eq "y") {
            try {
                if (-not (Test-Administrator)) {
                    Write-Host "ERROR: Recall requires Admin privileges." -ForegroundColor Red
                } else {
                    Disable-WindowsOptionalFeature -Online -FeatureName "Recall" -NoRestart -ErrorAction Stop
                    Write-Host "Recall disabled. Restart required." -ForegroundColor Green
                }
            } catch {
                Write-Host "Error disabling Recall: $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            Write-Host "Skipped." -ForegroundColor Yellow
        }
    } elseif ($recallStatus) {
        Write-Host "Recall is already disabled." -ForegroundColor White
    } else {
         Write-Host "Recall feature is not found (or not available on this version)." -ForegroundColor Yellow
    }
    
    # --- Disable Copilot (via Registry Policy) ---
    Write-Host ""
    Write-Host "Checking Copilot..." -ForegroundColor Yellow
    $copilotKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
    $copilotValue = "TurnOffWindowsCopilot"
    
    $currentValue = Get-ItemProperty -Path $copilotKey -Name $copilotValue -ErrorAction SilentlyContinue
    
    if ($currentValue -and $currentValue.TurnOffWindowsCopilot -eq 1) {
        Write-Host "Copilot already disabled." -ForegroundColor White
    } else {
        Write-Host "Copilot enabled. Disable? (Y/N)" -ForegroundColor Red
        $disableCopilot = Read-Host
        if ($disableCopilot -eq "Y" -or $disableCopilot -eq "y") {
            if (-not (Test-Administrator)) {
                Write-Host "ERROR: Copilot policy requires Admin privileges." -ForegroundColor Red
            } else {
                try {
                    if (-not (Test-Path $copilotKey)) {
                        New-Item -Path $copilotKey -Force | Out-Null
                    }
                    Set-ItemProperty -Path $copilotKey -Name $copilotValue -Value 1 -Type DWord -Force
                    Write-Host "Copilot disabled. Restart required." -ForegroundColor Green
                } catch {
                    Write-Host "Error disabling Copilot: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        } else {
            Write-Host "Skipped." -ForegroundColor Yellow
        }
    }
    
    Write-Host ""
    Write-Host "Restart recommended." -ForegroundColor Cyan
    Write-Host "Press any key..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 9: Shutdown & Power
function ShutdownMenu {
    do {
        Clear-Host
        Write-Host "=== Shutdown and Restart Controls ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "WARNING: Terminates all applications without saving." -ForegroundColor Red
        Write-Host ""
        Write-Host "1. Immediate Shutdown" -ForegroundColor Cyan
        Write-Host "2. Immediate Restart" -ForegroundColor Cyan
        Write-Host "3. Immediate Logoff" -ForegroundColor Cyan
        Write-Host "4. Hibernate" -ForegroundColor Cyan
        Write-Host "5. Restart with Updates" -ForegroundColor Cyan
        Write-Host "6. Restart to Recovery (Advanced Startup)" -ForegroundColor Cyan
        Write-Host "7. Restart to UEFI/BIOS (Requires BIOS support)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "0. Back"
        Write-Host ""
        
        $choice = Read-Host "Choice (0-7)"
        if ($choice -eq "0") { break }
        
        $commands = @{
            "1" = "shutdown /s /f /t 0"
            "2" = "shutdown /r /f /t 0"
            "3" = "shutdown /l"
            "4" = "shutdown /h"
            "5" = "shutdown /g"
            "6" = "shutdown /r /o /f /t 0"
            "7" = "shutdown /r /fw /f /t 0"
        }
        
        $selectedCmd = $commands[$choice]
        if (-not $selectedCmd) {
            Write-Host "Invalid choice." -ForegroundColor Red
            Write-Host "Press any key..." -ForegroundColor Gray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            continue
        }
        
        if ($choice -in @("1","2","4","5","6","7") -and -not (Test-Administrator)) {
            Write-Host "ERROR: Requires Admin." -ForegroundColor Red
            Write-Host "Press any key..." -ForegroundColor Gray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            continue
        }

        Write-Host "`nConfirm execution of: $selectedCmd? (Y/N)" -ForegroundColor Red
        $confirm = Read-Host
        
        if ($confirm -ne "Y" -and $confirm -ne "y") {
            Write-Host "Cancelled." -ForegroundColor Yellow
            Write-Host "Press any key..." -ForegroundColor Gray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            continue
        }
        
        try {
            Write-Host "Executing: $selectedCmd" -ForegroundColor Yellow
            if ($choice -eq "4") {
                & shutdown /h
            } else {
                Invoke-Expression $selectedCmd
            }
        } catch {
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        }
        
    } while ($true)
}
#endregion

#region Tool 10: DNS & Network
# Sub-Function: Configure DNS Servers
function Change-DNSServers {
    if (-not (Test-Administrator)) {
        Write-Host "ERROR: Requires Admin." -ForegroundColor Red
        Write-Host "Press any key..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    $activeInterface = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notlike "*Virtual*" } | Select-Object -First 1

    if ($activeInterface) {
        $interfaceName = $activeInterface.Name
        Write-Host "Active interface: $interfaceName" -ForegroundColor Green

        $dnsList = @(
            [PSCustomObject]@{Name="Google Public DNS"; Primary="8.8.8.8"; Secondary="8.8.4.4"}
            [PSCustomObject]@{Name="Cloudflare (Standard)"; Primary="1.1.1.1"; Secondary="1.0.0.1"}
            [PSCustomObject]@{Name="Cloudflare (Malware Block)"; Primary="1.1.1.2"; Secondary="1.0.0.2"}
            [PSCustomObject]@{Name="Cloudflare (Malware + Adult)"; Primary="1.1.1.3"; Secondary="1.0.0.3"}
            [PSCustomObject]@{Name="Quad9 (Standard)"; Primary="9.9.9.9"; Secondary="149.112.112.112"}
            [PSCustomObject]@{Name="Quad9 (Unsecured)"; Primary="9.9.9.10"; Secondary="149.112.112.10"}
            [PSCustomObject]@{Name="Quad9 (ECS)"; Primary="9.9.9.11"; Secondary="149.112.112.11"}
            [PSCustomObject]@{Name="Yandex (Safe)"; Primary="77.88.8.8"; Secondary="77.88.8.1"}
            [PSCustomObject]@{Name="Yandex (Family)"; Primary="77.88.8.7"; Secondary="77.88.8.3"}
            [PSCustomObject]@{Name="OpenDNS"; Primary="208.67.222.222"; Secondary="208.67.220.220"}
        )

        Write-Host "`nSelect DNS (number):"
        for ($i = 0; $i -lt $dnsList.Count; $i++) {
            Write-Host "$i. $($dnsList[$i].Name) - $($dnsList[$i].Primary)/$($dnsList[$i].Secondary)"
        }

        $choice = (Read-Host "Number (0-$($dnsList.Count-1))").Trim()

        if ($choice -match '^\d+$') {
            $choice = [int]$choice
            if ($choice -ge 0 -and $choice -lt $dnsList.Count) {
                $selectedDNS = $dnsList[$choice]
                try {
                    Set-DnsClientServerAddress -InterfaceAlias $interfaceName -ServerAddresses ($selectedDNS.Primary, $selectedDNS.Secondary) -ErrorAction Stop
                    Write-Host "DNS set: $($selectedDNS.Primary)/$($selectedDNS.Secondary)" -ForegroundColor Green
                    
                    Clear-DnsClientCache
                    Write-Host "Cache flushed." -ForegroundColor Green
                } catch {
                    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
                }
            } else {
                Write-Host "Invalid range." -ForegroundColor Red
            }
        } else {
            Write-Host "Invalid input." -ForegroundColor Red
        }
    } else {
        Write-Host "No active interface found." -ForegroundColor Red
    }
    
    Write-Host "Press any key..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Sub-Function: Execute NSLookup Query
function Perform-NSLookup {
    $activeInterface = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notlike "*Virtual*" } | Select-Object -First 1
    if ($activeInterface) {
        $currentDNS = Get-DnsClientServerAddress -InterfaceAlias $activeInterface.Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ServerAddresses
        Write-Host "Current DNS: $($currentDNS -join ', ')" -ForegroundColor White
    } else {
        Write-Host "No active interface." -ForegroundColor Yellow
    }
    
    Write-Host "`nDomain/IP:" -ForegroundColor Yellow
    $domain = Read-Host
    if ([string]::IsNullOrWhiteSpace($domain)) {
        Write-Host "No query." -ForegroundColor Red
        Write-Host "Press any key..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }
    
    Write-Host "Resolving $domain..." -ForegroundColor Yellow
    Write-Host "----------------------------------------" -ForegroundColor Cyan
    try {
        $output = nslookup $domain 2>&1
        $output | Out-Host
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host "----------------------------------------" -ForegroundColor Cyan
    Write-Host "Press any key..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Function 10: DNS Configuration and Resolution Tools
function DNSManagementMenu {
    do {
        Clear-Host
        Write-Host "=== DNS Tools ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Configure DNS Servers" -ForegroundColor Cyan
        Write-Host "2. NSLookup Query" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "0. Back"
        Write-Host ""
        
        $choice = Read-Host "Choice (0-2)"
        if ($choice -eq "0") { break }
        
        switch ($choice) {
            "1" { Change-DNSServers }
            "2" { Perform-NSLookup }
            default { 
                Write-Host "Invalid." -ForegroundColor Red
                Write-Host "Press any key..." -ForegroundColor Gray
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
        }
    } while ($true)
}
#endregion

#region Tool 11: WinUtil (External)
function Run-WinUtilDebloat {
    Write-Host "WARNING: Runs WinUtil for debloating/tweaks. Backup first." -ForegroundColor Red
    Write-Host "Source: https://christitus.com/win" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -ne "Y" -and $confirm -ne "y") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Write-Host "Press any key..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }
    
    if (-not (Test-Administrator)) {
        Write-Host "ERROR: Requires Admin." -ForegroundColor Red
        Write-Host "Press any key..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }
    
    Write-Host "Launching WinUtil..." -ForegroundColor Yellow
    try {
        irm "https://christitus.com/win" | iex
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host "Session ended. Press any key..." -ForegroundColor Green
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 12: Activation Tool (External)
function Run-WindowsOfficeActivator {
    Write-Host "WARNING: Runs third-party activation script. Use with valid licenses; backup first." -ForegroundColor Red
    Write-Host "Source: https://get.activated.win" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -ne "Y" -and $confirm -ne "y") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Write-Host "Press any key..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }
    
    if (-not (Test-Administrator)) {
        Write-Host "ERROR: Requires Admin." -ForegroundColor Red
        Write-Host "Press any key..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }
    
    Write-Host "Launching tool..." -ForegroundColor Yellow
    try {
        irm https://get.activated.win | iex
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host "Session ended. Press any key..." -ForegroundColor Green
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 13: Clean NVIDIA Library
function Clean-NvidiaLibrary {
    Write-Host "=== NVIDIA App Library Cleanup ===" -ForegroundColor Cyan
    Write-Host "This will reset the NVIDIA App scan database." -ForegroundColor Yellow
    Write-Host "It involves stopping the 'NvContainerLocalSystem' service temporarily." -ForegroundColor White
    
    if (-not (Test-Administrator)) {
        Write-Host "ERROR: Requires Admin privileges." -ForegroundColor Red
        Write-Host "Press any key..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -ne "Y" -and $confirm -ne "y") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }

    $dbPath = "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA app\NvBackend\ApplicationStorage.json"
    
    try {
        Write-Host "Stopping Service: NvContainerLocalSystem..." -ForegroundColor Yellow
        Stop-Service -Name "NvContainerLocalSystem" -Force -ErrorAction Stop
        
        if (Test-Path $dbPath) {
            Write-Host "Removing database file..." -ForegroundColor Yellow
            Remove-Item $dbPath -Force
            Write-Host "Scan database deleted successfully." -ForegroundColor Green
        } else {
            Write-Host "Database file not found (already clean or path invalid)." -ForegroundColor White
        }
        
        Write-Host "Restarting Service: NvContainerLocalSystem..." -ForegroundColor Yellow
        Start-Service -Name "NvContainerLocalSystem"
        Write-Host "Service restarted." -ForegroundColor Green

    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Ensure NVIDIA App is installed and you are Admin." -ForegroundColor White
    }
    
    Write-Host "Press any key to continue..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 14: System Information
function Show-HardwareInfo {
    [CmdletBinding()]
    param()

    Clear-Host

    # Info Gathering
    $computer = $env:COMPUTERNAME

    $cpu = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).Name
    if (-not $cpu) { $cpu = "Non rilevato" }

    $cpuPhysicalCores = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).NumberOfCores
    $cpuLogicalCores  = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).NumberOfLogicalProcessors

    $systemRamGB = [math]::Round(
        (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | 
         Measure-Object -Property Capacity -Sum).Sum / 1GB,
        1
    )
    if (-not $systemRamGB) { $systemRamGB = "Non rilevata" }

    $gpuModel   = "N/A"
    $gpuVramGB  = "N/A"

    try {
        $smi = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
        if ($smi) {
            $line = ($smi -split "`n")[0]
            $parts = $line -split ',\s*'
            if ($parts.Count -ge 2) {
                $gpuModel = $parts[0].Trim()
                $vramMB   = [int]$parts[1].Trim()
                $gpuVramGB = [math]::Round($vramMB / 1024, 1)
            }
        }
    }
    catch {}

    $storageTotalTB = [math]::Round(
        (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | 
         Measure-Object -Property Size -Sum).Sum / 1TB,
        0
    )
    if (-not $storageTotalTB) { $storageTotalTB = "Non rilevato" }

    # Output
    Write-Host "SYSTEM HARDWARE INFORMATION" -ForegroundColor Cyan -BackgroundColor DarkBlue
    Write-Host "────────────────────────────" -ForegroundColor DarkCyan

    Write-Host "Computer              : " -NoNewline -ForegroundColor DarkGray
    Write-Host $computer -ForegroundColor White

    Write-Host ""
    Write-Host "CPU                   : " -NoNewline -ForegroundColor DarkGray
    Write-Host $cpu -ForegroundColor Green

    Write-Host "CPU Cores             : " -NoNewline -ForegroundColor DarkGray
    Write-Host $cpuPhysicalCores -ForegroundColor Yellow

    Write-Host "CPU Threads           : " -NoNewline -ForegroundColor DarkGray
    Write-Host $cpuLogicalCores -ForegroundColor Yellow

    Write-Host ""
    Write-Host "RAM                   : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$systemRamGB GB" -ForegroundColor Magenta

    Write-Host ""
    Write-Host "GPU                   : " -NoNewline -ForegroundColor DarkGray
    Write-Host $gpuModel -ForegroundColor Green

    Write-Host "VRAM                  : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$gpuVramGB GB" -ForegroundColor Magenta

    Write-Host ""
    Write-Host "Total Internal Storage: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$storageTotalTB TB" -ForegroundColor Cyan

    Write-Host "────────────────────────────" -ForegroundColor DarkCyan

    Write-Host ""
    pause
}
#endregion

#region Main Menu Logic
function Show-Menu {
    Clear-Host
    Write-Host "========== WinCare ==========" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "---------- System Integrity & Repair ----------" -ForegroundColor White
    Write-Host "1. SFC Scan - Repairs corrupted files" -ForegroundColor Cyan
    Write-Host "2. CHKDSK Scan - Checks and repairs disk errors" -ForegroundColor Cyan
    Write-Host "3. DISM Image Repair - Restores system integrity" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "---------- Cleanup Tools ----------" -ForegroundColor White
    Write-Host "4. Clear Thumbnail Cache - Fixes display, frees space" -ForegroundColor Cyan
    Write-Host "5. Advanced Disk Cleanup - Temp, Logs, Update Cache (Prompted)" -ForegroundColor Cyan
    Write-Host "6. WinSxS Cleanup - Reduces component store size" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "---------- Configuration ----------" -ForegroundColor White
    Write-Host "7. PS Policy Config - Sets script security" -ForegroundColor Cyan
    Write-Host "8. Disable Recall/Copilot - Deactivates AI tools" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "---------- Power & Network ----------" -ForegroundColor White
    Write-Host "9. Shutdown/Restart - Manages power operations" -ForegroundColor Cyan
    Write-Host "10. DNS Tools - Configures servers, lookups" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "---------- Advanced Tools (Use with Caution) ----------" -ForegroundColor Red
    Write-Host "11. WinUtil Optimize - Debloat/tweaks (3rd-party)" -ForegroundColor Cyan
    Write-Host "12. Activation Tool - Licensing script (3rd-party)" -ForegroundColor Cyan
    Write-Host "13. Clean NVIDIA Library - Reset App Scan DB" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "---------- System Hardware Information ----------" -ForegroundColor Green
    Write-Host "14. View System Info" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "0. Exit" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "Choice (0-14)"
    return $choice
}
#endregion

#region Script Initialization
Write-Host "Initializing Tools..." -ForegroundColor Green

# Auto-elevate if not admin
if (-not (Test-Administrator)) {
    Write-Host "Elevating to Administrator..." -ForegroundColor Yellow
    Write-Host "Confirm UAC if prompted." -ForegroundColor Cyan
    $scriptPath = $MyInvocation.MyCommand.Definition
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs
    exit
}

Write-Host "Admin: Yes" -ForegroundColor Green
do {
    $selection = Show-Menu
    
    switch ($selection) {
        "1" { Run-SFCScan }
        "2" { Run-CHKDSK }
        "3" { Run-DISMCheck }
        "4" { Clear-ThumbnailCache }
        "5" { Run-AdvancedDiskCleanup }
        "6" { Run-DISMCleanupWinSxS }
        "7" { Set-ExecutionPolicyMenu }
        "8" { Disable-RecallAndCopilot }
        "9" { ShutdownMenu }
        "10" { DNSManagementMenu }
        "11" { Run-WinUtilDebloat }
        "12" { Run-WindowsOfficeActivator }
        "13" { Clean-NvidiaLibrary }
        "14" { Show-HardwareInfo }
        "0" { Write-Host "Exiting." -ForegroundColor Green; break }
        default { 
            Write-Host "Invalid." -ForegroundColor Red
            Write-Host "Press any key..." -ForegroundColor Gray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    }
} while ($selection -ne "0")

Write-Host "Complete." -ForegroundColor Green
#endregion