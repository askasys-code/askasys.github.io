# WinCare: Windows Maintenance Menu
# Compatible with PowerShell 5.1
# Author: askasys
# Description: Menu-driven tool for Windows system integrity, cleanup, and configuration tasks.

# Force UTF-8 Encoding for correct display of borders/characters
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Ensure TLS 1.2 is used for external web calls (Crucial for Tools 15 & 16)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#region Core Utilities
# Function to check if running as Administrator
function Test-Administrator {
    (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
#endregion

#region Tool 1: Create Restore Point (NEW)
function Create-RestorePoint {
    Write-Host "=== Create System Restore Point ===" -ForegroundColor Cyan
    Write-Host "Attempting to create a system checkpoint..." -ForegroundColor Yellow
    
    try {
        # Ensure System Restore is enabled for C:
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        
        $desc = "WinCare Checkpoint $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        Checkpoint-Computer -Description $desc -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        
        Write-Host "SUCCESS: Restore point '$desc' created." -ForegroundColor Green
    } catch {
        Write-Host "ERROR: Could not create restore point." -ForegroundColor Red
        Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Gray
        Write-Host "Ensure 'System Protection' is enabled in Windows Settings." -ForegroundColor Yellow
    }
    Write-Host "Press any key to continue..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 2: SFC Scan
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

#region Tool 3: CHKDSK
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
        # Using Start-Process to ensure arguments are parsed correctly if needed, but & works for chkdsk
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

#region Tool 4: DISM Health Check
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

#region Tool 5: Advanced Disk Cleanup (Improved)
function Run-AdvancedDiskCleanup {
    Clear-Host
    Write-Host "=== Advanced Disk Cleanup ===" -ForegroundColor Cyan
    
    # Helper to get space
    function Get-FreeSpaceGB {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
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
        @{ID=4; Name="Windows Update Cache"; Desc="Stops wuauserv/bits/cryptsvc, cleans SoftwareDistribution"},
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
                        Write-Host "Stopping Services (wuauserv, bits, cryptsvc)..." -ForegroundColor Yellow
                        $services = "wuauserv", "bits", "cryptsvc"
                        Stop-Service -Name $services -Force -ErrorAction SilentlyContinue
                        
                        Start-Sleep -Seconds 2
                        Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
                        Remove-Item -Path "C:\Windows\SoftwareDistribution\DataStore\*" -Recurse -Force -ErrorAction SilentlyContinue
                        
                        Write-Host "Restarting Services..." -ForegroundColor Yellow
                        Start-Service -Name $services -ErrorAction SilentlyContinue
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

#region Tool 7: Thumbnail Cache
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

#region Tool 8: Clean NVIDIA Library
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
            Remove-Item -Path $dbPath -Force
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

#region Tool 9: DNS & Network (Enhanced)
# Sub-Function: Configure DNS Servers
function Change-DNSServers {
    if (-not (Test-Administrator)) {
        Write-Host "ERROR: Requires Admin privileges." -ForegroundColor Red
        Write-Host "Press any key..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    Write-Host "Scanning network adapters..." -ForegroundColor Yellow
    
    # Get Up adapters
    $rawAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object Name, InterfaceDescription, ifIndex, Status
    
    # Ensure it's an array even if only 1 found (or 0)
    if ($rawAdapters -eq $null) {
        $adapters = @()
    } elseif ($rawAdapters -is [PSCustomObject]) {
        $adapters = @($rawAdapters)
    } else {
        $adapters = $rawAdapters
    }

    # Debug check (invisible to user unless empty)
    if ($adapters.Count -eq 0) {
        Write-Host "No active network adapters found (Status: Up)." -ForegroundColor Red
        Write-Host "Check your internet connection." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    $selectedAdapter = $null

    # --- SINGLE ADAPTER CASE ---
    if ($adapters.Count -eq 1) {
        $selectedAdapter = $adapters[0]
        
        # Get Current DNS
        $currentDNS = "Unknown"
        try {
            $dnsObj = Get-DnsClientServerAddress -InterfaceIndex $selectedAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($dnsObj -and $dnsObj.ServerAddresses) {
                $currentDNS = $dnsObj.ServerAddresses -join ", "
            } else {
                $currentDNS = "DHCP/Auto"
            }
        } catch {}

        Write-Host "Found 1 Active Adapter:" -ForegroundColor Cyan
        Write-Host "Name: " -NoNewline -ForegroundColor White; Write-Host $selectedAdapter.Name -ForegroundColor Green
        Write-Host "Desc: " -NoNewline -ForegroundColor White; Write-Host $selectedAdapter.InterfaceDescription -ForegroundColor Gray
        Write-Host "DNS : " -NoNewline -ForegroundColor White; Write-Host $currentDNS -ForegroundColor Yellow
        Write-Host ""
    } 
    # --- MULTIPLE ADAPTERS CASE ---
    else {
        Write-Host "Multiple active adapters found ($($adapters.Count)). Please select one:" -ForegroundColor Cyan
        Write-Host "------------------------------------------------" -ForegroundColor Gray
        
        $i = 1
        foreach ($nic in $adapters) {
            # Get DNS for list view
            $dnsStr = "DHCP"
            try {
                $dnsObj = Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                if ($dnsObj -and $dnsObj.ServerAddresses) {
                    $dnsStr = $dnsObj.ServerAddresses -join ", "
                }
            } catch {}

            Write-Host "[$i] " -NoNewline -ForegroundColor Yellow
            Write-Host "$($nic.Name)" -NoNewline -ForegroundColor Green
            Write-Host " ($($nic.InterfaceDescription))" -ForegroundColor Gray
            Write-Host "    DNS: $dnsStr" -ForegroundColor White
            $i++
        }
        Write-Host "------------------------------------------------" -ForegroundColor Gray
        
        do {
            $selInput = Read-Host "Select Adapter (1-$($adapters.Count))"
            # Validate input
            if ($selInput -match '^\d+$' -and [int]$selInput -ge 1 -and [int]$selInput -le $adapters.Count) {
                $selectedAdapter = $adapters[[int]$selInput - 1]
                break
            }
            Write-Host "Invalid selection. Enter a number between 1 and $($adapters.Count)." -ForegroundColor Red
        } while ($true)
    }

    Write-Host "`nTargeting: " -NoNewline -ForegroundColor Cyan
    Write-Host "$($selectedAdapter.Name)" -ForegroundColor Green

    # 2. DNS Provider List
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
        [PSCustomObject]@{Name="DHCP (Automatic / ISP)"; Primary="DHCP"; Secondary="DHCP"}
    )

    Write-Host "`nSelect DNS Provider:" -ForegroundColor Cyan
    for ($k = 0; $k -lt $dnsList.Count; $k++) {
        Write-Host "$k. " -NoNewline -ForegroundColor Yellow
        Write-Host "$($dnsList[$k].Name)" -NoNewline -ForegroundColor White
        Write-Host " ($($dnsList[$k].Primary))" -ForegroundColor DarkGray
    }

    $choice = Read-Host "Choice (0-$($dnsList.Count-1))"

    if ($choice -match '^\d+$' -and [int]$choice -ge 0 -and [int]$choice -lt $dnsList.Count) {
        $selectedDNS = $dnsList[[int]$choice]
        
        try {
            Write-Host "Applying settings..." -ForegroundColor Yellow
            
            if ($selectedDNS.Primary -eq "DHCP") {
                Set-DnsClientServerAddress -InterfaceIndex $selectedAdapter.ifIndex -ResetServerAddresses -ErrorAction Stop
                Write-Host "Successfully reset to DHCP (Automatic)." -ForegroundColor Green
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $selectedAdapter.ifIndex -ServerAddresses ($selectedDNS.Primary, $selectedDNS.Secondary) -ErrorAction Stop
                Write-Host "Successfully set DNS to: $($selectedDNS.Name)" -ForegroundColor Green
            }
            
            Write-Host "Flushing DNS Cache..." -ForegroundColor Yellow
            Clear-DnsClientCache
            Write-Host "Done." -ForegroundColor Green

        } catch {
            Write-Host "Error applying DNS: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Try running the script again." -ForegroundColor Gray
        }
    } else {
        Write-Host "Cancelled." -ForegroundColor Yellow
    }
    
    Write-Host "Press any key to continue..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Sub-Function: Interactive NSLookup
function Perform-NSLookup {
    Clear-Host
    Write-Host "=== Interactive NSLookup ===" -ForegroundColor Cyan
    Write-Host "Type a domain (e.g., google.com) to resolve." -ForegroundColor White
    Write-Host "Type 'exit' to return to menu." -ForegroundColor Gray
    Write-Host ""
    
    # Helper to show current DNS
    try {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
        if ($adapter) {
             $dns = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses
             Write-Host "System DNS: $($dns -join ', ')" -ForegroundColor DarkGray
        }
    } catch {}

    do {
        Write-Host ""
        $domain = Read-Host "Domain/IP >"
        
        if ([string]::IsNullOrWhiteSpace($domain)) { continue }
        if ($domain -eq "exit") { break }
        
        Write-Host "----------------------------------------" -ForegroundColor Cyan
        
        # Use cmd /c to bypass PowerShell's strict error handling of stderr in nslookup
        cmd /c "nslookup $domain"
        
        Write-Host "----------------------------------------" -ForegroundColor Cyan
        
    } while ($true)
}

# Sub-Function: Reset Network Stack
function Reset-NetworkStack {
    Write-Host "Resetting TCP/IP Stack and Winsock..." -ForegroundColor Yellow
    Write-Host "This will reset network configurations and may fix connectivity issues." -ForegroundColor Cyan
    
    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -eq "Y" -or $confirm -eq "y") {
        try {
            netsh int ip reset
            netsh winsock reset
            Write-Host "Network Reset Complete." -ForegroundColor Green
            Write-Host "A SYSTEM REBOOT IS REQUIRED to take effect." -ForegroundColor Red
        } catch {
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "Cancelled." -ForegroundColor Gray
    }
    Write-Host "Press any key..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Function 9: DNS Management Menu
function DNSManagementMenu {
    do {
        Clear-Host
        Write-Host "=== Network Tools ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Configure DNS Servers" -ForegroundColor Cyan
        Write-Host "2. NSLookup Query (Interactive)" -ForegroundColor Cyan
        Write-Host "3. Reset Network Stack (Fixes connectivity)" -ForegroundColor Red
        Write-Host ""
        Write-Host "0. Back"
        Write-Host ""
        
        $choice = Read-Host "Choice (0-3)"
        
        switch ($choice) {
            "1" { Change-DNSServers }
            "2" { Perform-NSLookup }
            "3" { Reset-NetworkStack }
            "0" { return } # Return exits the function back to main menu
            default { 
                # Loop
            }
        }
    } while ($true)
}
#endregion

#region Tool 10: Execution Policy
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
        if ($policyChoice -eq "0") { return }
        
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

#region Tool 11: Recall & Copilot
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

#region Tool 12: System Information (Hardware)
function Show-HardwareInfo {
    [CmdletBinding()]
    param()

    Clear-Host

    # Info Gathering via CIM (Standard for PS 5.1+)
    $computer = $env:COMPUTERNAME

    # CPU
    $proc = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
    $cpu = if ($proc.Name) { $proc.Name } else { "Unknown" }
    $cpuPhysicalCores = if ($proc.NumberOfCores) { $proc.NumberOfCores } else { "N/A" }
    $cpuLogicalCores  = if ($proc.NumberOfLogicalProcessors) { $proc.NumberOfLogicalProcessors } else { "N/A" }

    # RAM
    $memPoints = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum
    $systemRamGB = if ($memPoints.Sum) { [math]::Round($memPoints.Sum / 1GB, 1) } else { "Unknown" }

    # GPU Info (Universal: tries Nvidia-SMI first, falls back to WMI for AMD/Intel)
    $gpuInfo = @()
    try {
        # Try NVIDIA-SMI for detailed VRAM info if available
        $smi = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
        if ($smi) {
            foreach ($line in $smi) {
                $parts = $line -split ',\s*'
                if ($parts.Count -ge 2) {
                    $vramGB = [math]::Round([int]$parts[1] / 1024, 1)
                    $gpuInfo += "$($parts[0]) ($vramGB GB VRAM)"
                }
            }
        }
    } catch {}

    # Fallback to WMI if NVIDIA-SMI failed or returned nothing
    if ($gpuInfo.Count -eq 0) {
        $videoControllers = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
        foreach ($vc in $videoControllers) {
            $gpuInfo += $vc.Name
        }
    }
    
    if ($gpuInfo.Count -eq 0) { $gpuInfo += "Unknown / Standard Display Adapter" }
    $gpuDisplay = $gpuInfo -join " | "

    # Storage Info (Better Math)
    $diskPoints = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | Measure-Object -Property Size -Sum
    $totalStorageBytes = $diskPoints.Sum
    $storageDisplay = "Unknown"
    
    if ($totalStorageBytes -gt 0) {
        if ($totalStorageBytes -lt 1TB) {
            $storageDisplay = "$([math]::Round($totalStorageBytes / 1GB, 0)) GB"
        } else {
            $storageDisplay = "$([math]::Round($totalStorageBytes / 1TB, 2)) TB"
        }
    }

    # Output
    Write-Host "SYSTEM HARDWARE INFORMATION" -ForegroundColor Cyan -BackgroundColor DarkBlue
    Write-Host "────────────────────────────" -ForegroundColor DarkCyan

    Write-Host "Computer              : " -NoNewline -ForegroundColor DarkGray
    Write-Host $computer -ForegroundColor White

    Write-Host ""
    Write-Host "CPU                   : " -NoNewline -ForegroundColor DarkGray
    Write-Host $cpu -ForegroundColor Green

    Write-Host "CPU Cores             : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$cpuPhysicalCores Cores / $cpuLogicalCores Threads" -ForegroundColor Yellow

    Write-Host ""
    Write-Host "RAM                   : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$systemRamGB GB" -ForegroundColor Magenta

    Write-Host ""
    Write-Host "GPU                   : " -NoNewline -ForegroundColor DarkGray
    Write-Host $gpuDisplay -ForegroundColor Green

    Write-Host ""
    Write-Host "Total Internal Storage: " -NoNewline -ForegroundColor DarkGray
    Write-Host $storageDisplay -ForegroundColor Cyan

    Write-Host "────────────────────────────" -ForegroundColor DarkCyan

    Write-Host ""
    Write-Host "Press any key to continue..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 13: Battery Report (NEW)
function Generate-BatteryReport {
    Write-Host "Generating Windows Battery Report..." -ForegroundColor Yellow
    $reportPath = "$env:USERPROFILE\Desktop\battery-report.html"
    
    try {
        & powercfg /batteryreport /output "$reportPath" | Out-Null
        if (Test-Path $reportPath) {
            Write-Host "Report saved to: $reportPath" -ForegroundColor Green
            $open = Read-Host "Open report now? (Y/N)"
            if ($open -eq "Y" -or $open -eq "y") {
                Invoke-Item $reportPath
            }
        }
    } catch {
        Write-Host "Error generating report: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Note: This feature may not work on Desktops." -ForegroundColor Gray
    }
    Write-Host "Press any key..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 14: Shutdown & Power
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
        if ($choice -eq "0") { return } 
        
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

#region Tool 15: WinUtil (External)
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

#region Tool 16: Activation Tool (External)
function Run-WindowsOfficeActivator {
    Write-Host "WARNING: Runs third-party activation script." -ForegroundColor Red
    Write-Host "Ensure you have valid licenses. This tool connects to external servers." -ForegroundColor Red
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

#region Main Menu Logic
function Show-Menu {
    Clear-Host
    Write-Host "========== WinCare v2.5 ==========" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "---------- Safety & Backup ----------" -ForegroundColor White
    Write-Host "1. Create System Restore Point (Recommended)" -ForegroundColor Yellow
    
    Write-Host "`n---------- System Repair ----------" -ForegroundColor White
    Write-Host "2. SFC Scan - Repairs corrupted files" -ForegroundColor Cyan
    Write-Host "3. CHKDSK Scan - Checks disk errors" -ForegroundColor Cyan
    Write-Host "4. DISM Image Repair - Restores system health" -ForegroundColor Cyan
    
    Write-Host "`n---------- Maintenance & Cleanup ----------" -ForegroundColor White
    Write-Host "5. Advanced Disk Cleanup (Temp, Updates, Logs)" -ForegroundColor Cyan
    Write-Host "6. WinSxS Cleanup - Component Store" -ForegroundColor Cyan
    Write-Host "7. Clear Thumbnail Cache" -ForegroundColor Cyan
    Write-Host "8. Clean NVIDIA Library DB" -ForegroundColor Cyan
    
    Write-Host "`n---------- Network & Configuration ----------" -ForegroundColor White
    Write-Host "9.  DNS & Network Tools (Set DNS, NSLookup, Reset)" -ForegroundColor Cyan
    Write-Host "10. PowerShell Policy Config" -ForegroundColor Cyan
    Write-Host "11. Disable Recall/Copilot" -ForegroundColor Cyan
    
    Write-Host "`n---------- Hardware & Power ----------" -ForegroundColor White
    Write-Host "12. View System Hardware Info" -ForegroundColor Green
    Write-Host "13. Generate Battery Health Report" -ForegroundColor Green
    Write-Host "14. Shutdown/Restart Menu" -ForegroundColor Green
    
    Write-Host "`n---------- External Tools (3rd Party) ----------" -ForegroundColor Red
    Write-Host "15. WinUtil (Debloat/Tweaks)" -ForegroundColor Cyan
    Write-Host "16. Activation Tool" -ForegroundColor Cyan
    
    Write-Host ""
    Write-Host "0. Exit" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "Choice (0-16)"
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
        "1" { Create-RestorePoint }
        "2" { Run-SFCScan }
        "3" { Run-CHKDSK }
        "4" { Run-DISMCheck }
        "5" { Run-AdvancedDiskCleanup }
        "6" { Run-DISMCleanupWinSxS }
        "7" { Clear-ThumbnailCache }
        "8" { Clean-NvidiaLibrary }
        "9" { DNSManagementMenu }
        "10" { Set-ExecutionPolicyMenu }
        "11" { Disable-RecallAndCopilot }
        "12" { Show-HardwareInfo }
        "13" { Generate-BatteryReport }
        "14" { ShutdownMenu }
        "15" { Run-WinUtilDebloat }
        "16" { Run-WindowsOfficeActivator }
        "0" { Write-Host "Exiting." -ForegroundColor Green; break }
        default { 
            # Invalid choice handling
            if (-not [string]::IsNullOrWhiteSpace($selection)) {
                Write-Host "Invalid." -ForegroundColor Red
                Write-Host "Press any key..." -ForegroundColor Gray
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
        }
    }
} while ($selection -ne "0")

Write-Host "Complete." -ForegroundColor Green
#endregion