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

#region Tool 8: NVIDIA Menu
function Show-NvidiaMenu {
    # Helper Function to check Admin privileges
    function Test-AdminPrivileges {
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]$currentUser
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    # Helper Function to find nvidia-smi
    function Get-NvidiaSmiPath {
        $path = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
        if ($path) { return $path.Source }
        
        $defaultPath = "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
        if (Test-Path $defaultPath) { return $defaultPath }
        
        return $null
    }

    # Menu Loop
    do {
        Clear-Host
        Write-Host "=== NVIDIA MENU ===" -ForegroundColor Cyan
        Write-Host "Advanced Driver, Cache, and Power Limit Management" -ForegroundColor Gray
        Write-Host ""
        Write-Host "1. Clean App Library Database (NVIDIA App)" -ForegroundColor Yellow
        Write-Host "2. Clean Shader Cache (DirectX/GL) - Fixes Stuttering" -ForegroundColor Yellow
        Write-Host "3. Show GPU Status (Snapshot)" -ForegroundColor Green
        Write-Host "4. Set Power Limit to 50% (Eco Mode)" -ForegroundColor Magenta
        Write-Host "5. Reset Power Limit to 100% (Max Performance)" -ForegroundColor Magenta
        Write-Host "0. Exit" -ForegroundColor White
        Write-Host ""
        
        $choice = Read-Host "Select an option"

        switch ($choice) {
            "1" {
                # --- CLEAN LIBRARY DB ---
                if (-not (Test-AdminPrivileges)) { Write-Host "Administrator privileges required!" -ForegroundColor Red; Start-Sleep 2; break }
                
                $dbPath = "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA app\NvBackend\ApplicationStorage.json"
                Write-Host "`nStopping service NvContainerLocalSystem..." -ForegroundColor Yellow
                try {
                    Stop-Service -Name "NvContainerLocalSystem" -Force -ErrorAction Stop
                    if (Test-Path $dbPath) {
                        Remove-Item -Path $dbPath -Force
                        Write-Host "Database deleted successfully." -ForegroundColor Green
                    } else {
                        Write-Host "Database file not found (already clean)." -ForegroundColor Gray
                    }
                } catch {
                    Write-Host "Error stopping service: $($_.Exception.Message)" -ForegroundColor Red
                }
                Write-Host "Restarting service..." -ForegroundColor Yellow
                Start-Service -Name "NvContainerLocalSystem" -ErrorAction SilentlyContinue
                Write-Host "Done." -ForegroundColor Green
                Pause
            }

            "2" {
                # --- CLEAN SHADER CACHE ---
                if (-not (Test-AdminPrivileges)) { Write-Host "Administrator privileges required!" -ForegroundColor Red; Start-Sleep 2; break }
                
                # Common NVIDIA cache paths
                $cachePaths = @(
                    "$env:LOCALAPPDATA\NVIDIA\DXCache",
                    "$env:LOCALAPPDATA\NVIDIA\GLCache",
                    "$env:APPDATA\NVIDIA\ComputeCache"
                )

                Write-Host "`nCalculating Shader Cache size..." -ForegroundColor Cyan
                $totalSize = 0
                $filesFound = 0

                foreach ($path in $cachePaths) {
                    if (Test-Path $path) {
                        $stats = Get-ChildItem -Path $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
                        if ($stats.Count -gt 0) {
                            $totalSize += $stats.Sum
                            $filesFound += $stats.Count
                        }
                    }
                }

                $sizeMB = [math]::Round($totalSize / 1MB, 2)
                Write-Host "Found $filesFound cache files totaling: $sizeMB MB" -ForegroundColor White

                if ($filesFound -gt 0) {
                    $conf = Read-Host "Do you want to proceed with cleanup? (Y/N)"
                    if ($conf -eq "Y" -or $conf -eq "y") {
                        Write-Host "Cleaning in progress (files in use will be skipped)..." -ForegroundColor Yellow
                        foreach ($path in $cachePaths) {
                            if (Test-Path $path) {
                                # Use SilentlyContinue because some files are locked by drivers
                                Get-ChildItem -Path $path -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                            }
                        }
                        Write-Host "Cleanup complete (cache will regenerate upon next game launch)." -ForegroundColor Green
                    }
                } else {
                    Write-Host "No cache to clean." -ForegroundColor Green
                }
                Pause
            }

            "3" {
                # --- NVIDIA SMI STATS (Single Run) ---
                $smi = Get-NvidiaSmiPath
                if ($smi) {
                    Write-Host "`nRetrieving GPU Status..." -ForegroundColor Cyan
                    & $smi
                } else {
                    Write-Host "NVIDIA-SMI not found. Are drivers installed?" -ForegroundColor Red
                }
                Pause
            }

            "4" {
                # --- ECO MODE (50% TDP) ---
                if (-not (Test-AdminPrivileges)) { Write-Host "Administrator privileges required!" -ForegroundColor Red; Start-Sleep 2; break }
                $smi = Get-NvidiaSmiPath
                
                if ($smi) {
                    try {
                        # Get max limit in Watts
                        $maxPower = & $smi --query-gpu=power.max_limit --format=csv,noheader,nounits
                        # Get min limit allowed in Watts
                        $minPower = & $smi --query-gpu=power.min_limit --format=csv,noheader,nounits
                        
                        if ($maxPower -is [string]) { $maxPower = [double]$maxPower }
                        if ($minPower -is [string]) { $minPower = [double]$minPower }

                        # Calculate 50%
                        $targetPower = [math]::Round($maxPower * 0.5)

                        # If 50% is below the physical minimum, use the minimum
                        if ($targetPower -lt $minPower) {
                            Write-Host "50% ($targetPower W) is below the allowed minimum. Setting to minimum ($minPower W)." -ForegroundColor Yellow
                            $targetPower = $minPower
                        }

                        Write-Host "Setting Power Limit to $targetPower W..." -ForegroundColor Cyan
                        & $smi -pl $targetPower
                        Write-Host "Done. Verification:" -ForegroundColor Green
                        & $smi --query-gpu=power.limit --format=csv,noheader
                    } catch {
                        Write-Host "Error retrieving/setting GPU data." -ForegroundColor Red
                    }
                }
                Pause
            }

            "5" {
                # --- MAX PERFORMANCE (100% TDP) ---
                if (-not (Test-AdminPrivileges)) { Write-Host "Administrator privileges required!" -ForegroundColor Red; Start-Sleep 2; break }
                $smi = Get-NvidiaSmiPath
                
                if ($smi) {
                    try {
                        $maxPower = & $smi --query-gpu=power.max_limit --format=csv,noheader,nounits
                        Write-Host "Restoring Power Limit to maximum ($maxPower W)..." -ForegroundColor Cyan
                        & $smi -pl $maxPower
                        Write-Host "GPU restored to max performance." -ForegroundColor Green
                    } catch {
                        Write-Host "Error." -ForegroundColor Red
                    }
                }
                Pause
            }

            "0" { return }
        }

    } while ($true)
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

#region Tool 11: Privacy, Telemetry & AI
function Disable-RecallAndCopilot {
    # Sub-function to safely disable a scheduled task
    function Disable-TaskSafe {
        param($path, $name)
        try {
            $task = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
            if ($task -and $task.State -ne "Disabled") {
                Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
                Write-Host "Task disabled: $name" -ForegroundColor DarkGray
            }
        } catch {}
    }

    # Sub-function to safely disable a service
    function Disable-ServiceSafe {
        param($name)
        try {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc) {
                if ($svc.Status -eq 'Running') { 
                    Stop-Service -Name $name -Force -ErrorAction SilentlyContinue 
                }
                if ($svc.StartType -ne 'Disabled') {
                    Set-Service -Name $name -StartupType Disabled -ErrorAction SilentlyContinue
                    Write-Host "Service disabled: $name" -ForegroundColor DarkGray
                }
            }
        } catch {}
    }

    # --- MAIN PRIVACY MENU ---
    do {
        Clear-Host
        Write-Host "=== Privacy, Telemetry & AI Management ===" -ForegroundColor Cyan
        Write-Host ""
        
        # 1. Check Telemetry Status
        $telemetryStatus = "Enabled/Unknown"
        try {
            $tVal = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -ErrorAction SilentlyContinue).AllowTelemetry
            $sVal = (Get-Service "DiagTrack" -ErrorAction SilentlyContinue).StartType
            if ($tVal -eq 0 -and $sVal -eq "Disabled") { $telemetryStatus = "Disabled" }
        } catch {}

        # 2. Check Recall Status
        $recallStatus = "Not Found/Disabled"
        try {
            $rFeat = Get-WindowsOptionalFeature -Online -FeatureName "Recall" -ErrorAction SilentlyContinue
            if ($rFeat -and $rFeat.State -eq "Enabled") { $recallStatus = "Enabled" }
        } catch {}

        # 3. Check Copilot Status
        $copilotStatus = "Enabled"
        try {
            $cVal = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -ErrorAction SilentlyContinue).TurnOffWindowsCopilot
            if ($cVal -eq 1) { $copilotStatus = "Disabled" }
        } catch {}

        # --- DISPLAY STATUS (CLEAN LAYOUT) ---
        Write-Host "   Current System Status" -ForegroundColor White
        Write-Host "   ─────────────────────" -ForegroundColor DarkGray
        
        Write-Host "   Telemetry  : " -NoNewline -ForegroundColor Gray
        if($telemetryStatus -eq "Disabled"){ Write-Host "Disabled" -ForegroundColor Green } else { Write-Host $telemetryStatus -ForegroundColor Red }

        Write-Host "   Recall AI  : " -NoNewline -ForegroundColor Gray
        if($recallStatus -ne "Enabled"){ Write-Host "Disabled/Safe" -ForegroundColor Green } else { Write-Host "Enabled" -ForegroundColor Red }

        Write-Host "   Copilot    : " -NoNewline -ForegroundColor Gray
        if($copilotStatus -eq "Disabled"){ Write-Host "Disabled" -ForegroundColor Green } else { Write-Host "Enabled" -ForegroundColor Red }
        
        Write-Host ""
        Write-Host "1. Disable Windows Telemetry & Data Collection (Deep Clean)" -ForegroundColor Yellow
        Write-Host "2. Disable Recall & Copilot (AI Features)" -ForegroundColor Yellow
        Write-Host "3. Disable ALL (Recommended)" -ForegroundColor Green
        Write-Host ""
        Write-Host "0. Back to Main Menu" -ForegroundColor Cyan
        Write-Host ""

        $choice = Read-Host "Select Option"

        if ($choice -eq "0") { return }

        if (-not (Test-Administrator)) {
            Write-Host "ERROR: Admin privileges required." -ForegroundColor Red
            Start-Sleep -Seconds 2
            continue
        }

        # --- EXECUTION LOGIC ---
        
        # === BLOCK A: TELEMETRY ===
        if ($choice -eq "1" -or $choice -eq "3") {
            Write-Host "`nApplying Telemetry Fixes..." -ForegroundColor Cyan
            
            # 1. Services
            $services = @("DiagTrack", "dmwappushservice", "diagnosticshub.standardcollector.service", "diagsvc", "wersvc", "wercplsupport")
            foreach ($s in $services) { Disable-ServiceSafe -name $s }

            # 2. Scheduled Tasks
            Disable-TaskSafe -path "\Microsoft\Windows\Device Information\" -name "Device"
            Disable-TaskSafe -path "\Microsoft\Windows\Device Information\" -name "Device User"
            Disable-TaskSafe -path "\Microsoft\Windows\ErrorDetails\" -name "EnableErrorDetailsUpdate"
            Disable-TaskSafe -path "\Microsoft\Windows\Windows Error Reporting\" -name "QueueReporting"

            # 3. Registry Policies
            $regSettings = @{
                "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" = @{
                    "AllowTelemetry"=0; "AllowDesktopAnalyticsProcessing"=0; "AllowDeviceNameInTelemetry"=0;
                    "MicrosoftEdgeDataOptIn"=0; "AllowWUfBCloudProcessing"=0; "AllowUpdateComplianceProcessing"=0;
                    "AllowCommercialDataPipeline"=0; "DisableOneSettingsDownloads"=1
                };
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" = @{ "AllowTelemetry"=0 };
                "HKLM:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform" = @{ "NoGenTicket"=1 };
                "HKLM:\Software\Policies\Microsoft\Windows\Windows Error Reporting" = @{ "Disabled"=1; "DontSendAdditionalData"=1 };
                "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" = @{ "Disabled"=1 }
            }

            foreach ($path in $regSettings.Keys) {
                if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
                foreach ($name in $regSettings[$path].Keys) {
                    Set-ItemProperty -Path $path -Name $name -Value $regSettings[$path][$name] -Type DWord -Force
                }
            }

            # 4. Block DeviceCensus.exe (Debugger Trick)
            $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe"
            if (-not (Test-Path $ifeoPath)) { New-Item -Path $ifeoPath -Force | Out-Null }
            Set-ItemProperty -Path $ifeoPath -Name "Debugger" -Value "%SYSTEMROOT%\System32\taskkill.exe" -Type String -Force
            
            Write-Host "Telemetry disabled." -ForegroundColor Green
        }

        # === BLOCK B: RECALL & COPILOT ===
        if ($choice -eq "2" -or $choice -eq "3") {
            Write-Host "`nDisabling AI Features..." -ForegroundColor Cyan
            
            # Recall
            try {
                if (Get-WindowsOptionalFeature -Online -FeatureName "Recall" -ErrorAction SilentlyContinue) {
                    Disable-WindowsOptionalFeature -Online -FeatureName "Recall" -NoRestart -ErrorAction SilentlyContinue | Out-Null
                    Write-Host "Recall feature disabled." -ForegroundColor Green
                }
            } catch { Write-Host "Recall not present or error." -ForegroundColor DarkGray }

            # Copilot
            $copilotKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
            if (-not (Test-Path $copilotKey)) { New-Item -Path $copilotKey -Force | Out-Null }
            Set-ItemProperty -Path $copilotKey -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Force
            Write-Host "Copilot policy disabled." -ForegroundColor Green
        }

        Write-Host "`nOperation Complete. Restart recommended." -ForegroundColor White
        Write-Host "Press any key to continue..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

    } while ($true)
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

#region Tool 15: ChrisTitusTech (External)
function Run-ChrisTitusTech {
    Write-Host "WARNING: Runs ChrisTitusTech for debloating/tweaks. Backup first." -ForegroundColor Red
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
    
    Write-Host "Launching ChrisTitusTech..." -ForegroundColor Yellow
    try {
        irm "https://christitus.com/win" | iex
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host "Session ended. Press any key..." -ForegroundColor Green
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 16: Raphire (External)
function Run-Raphire {
    Write-Host "WARNING: Runs Raphire for debloating/tweaks. Backup first." -ForegroundColor Red
    Write-Host "Source: https://debloat.raphi.re" -ForegroundColor Yellow
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
    
    Write-Host "Launching Raphire..." -ForegroundColor Yellow
    try {
        irm "https://debloat.raphi.re" | iex
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host "Session ended. Press any key..." -ForegroundColor Green
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Tool 17: Activation Tool (External)
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

#region Tool 18: Windows Settings
# Helpers specific for this tool
function Import-RegistryContent {
    param([string]$RegContent, [string]$Description)
    $tempFile = "$env:TEMP\wincare_temp.reg"
    try {
        $RegContent | Out-File -FilePath $tempFile -Encoding ASCII -Force
        Start-Process -FilePath "reg.exe" -ArgumentList "import `"$tempFile`"" -Wait -NoNewWindow
        Write-Host "SUCCESS: $Description applied." -ForegroundColor Green
    } catch {
        Write-Host "ERROR: Could not apply $Description." -ForegroundColor Red
    } finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-RegistryKey {
    param([string]$KeyPath, [string]$Description)
    try {
        if (Test-Path $KeyPath) {
            Remove-Item -Path $KeyPath -Recurse -Force -ErrorAction Stop
            Write-Host "SUCCESS: $Description removed/reverted." -ForegroundColor Green
        } else {
            Write-Host "INFO: $Description not found (already clean)." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "ERROR: Could not remove $Description. $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Apply-WindowsCustomSettings {
    Write-Host "Applying 'All-in-One' Custom Windows Settings..." -ForegroundColor Cyan
    
    try {
        # --- 1. TASKBAR & DESKTOP ---
        $pathAdv = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        
        # Taskbar Alignment -> LEFT
        Set-ItemProperty -Path $pathAdv -Name "TaskbarAl" -Value 0 -Force
        
        # Task View Button -> OFF
        Set-ItemProperty -Path $pathAdv -Name "ShowTaskViewButton" -Value 0 -Force
        
        # Search Box -> HIDE (0 = Hide, 1 = Icon, 2 = Box)
        $pathSearch = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
        if (!(Test-Path $pathSearch)) { New-Item -Path $pathSearch -Force | Out-Null }
        Set-ItemProperty -Path $pathSearch -Name "SearchboxTaskbarMode" -Value 0 -Force

        # Desktop Wallpaper -> SOLID BLACK
        $pathDesktop = "HKCU:\Control Panel\Desktop"
        Set-ItemProperty -Path $pathDesktop -Name "Wallpaper" -Value "" -Force
        Set-ItemProperty -Path "HKCU:\Control Panel\Colors" -Name "Background" -Value "0 0 0" -Force
        
        Write-Host "[+] Taskbar: Left, Search Hidden, Task View Off" -ForegroundColor Green
        Write-Host "[+] Desktop: Wallpaper set to Solid Black" -ForegroundColor Green

        # --- 2. LOCKSCREEN (No Spotlight) ---
        $pathCDM = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        Set-ItemProperty -Path $pathCDM -Name "RotatingLockScreenEnabled" -Value 0 -Force
        Set-ItemProperty -Path $pathCDM -Name "RotatingLockScreenOverlayEnabled" -Value 0 -Force
        Set-ItemProperty -Path $pathCDM -Name "SubscribedContent-338387Enabled" -Value 0 -Force
        Write-Host "[+] Lockscreen set to static/black" -ForegroundColor Green

        # --- 3. VISUAL EFFECTS (Custom: Thumbnails + Fonts only) ---
        # VisualFXSetting: 3=Custom
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 3 -Force
        # Show thumbnails instead of icons (0 = Enable Thumbnails)
        Set-ItemProperty -Path $pathAdv -Name "IconsOnly" -Value 0 -Force
        # Smooth edges of screen fonts (2 = Enabled)
        Set-ItemProperty -Path $pathDesktop -Name "FontSmoothing" -Value "2" -Force
        # Disable animations/shadows
        Set-ItemProperty -Path $pathAdv -Name "ListviewAlphaSelect" -Value 0 -Force
        Set-ItemProperty -Path $pathAdv -Name "ListviewShadow" -Value 0 -Force
        Set-ItemProperty -Path $pathAdv -Name "TaskbarAnimations" -Value 0 -Force
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value 0 -Force
        Write-Host "[+] Visual Effects optimized (Thumbnails+Fonts only)" -ForegroundColor Green

        # --- 4. START MENU (Clean) ---
        Set-ItemProperty -Path $pathAdv -Name "Start_TrackProgs" -Value 0 -Force # Recently added apps
        Set-ItemProperty -Path $pathAdv -Name "Start_TrackDocs" -Value 0 -Force  # Recently opened items
        Set-ItemProperty -Path $pathAdv -Name "Start_IrisRecommendations" -Value 0 -Force # Recommendations
        Write-Host "[+] Start Menu recommendations disabled" -ForegroundColor Green

        # --- 5. SYSTEM SOUNDS (Silence) ---
        $pathSounds = "HKCU:\AppEvents\Schemes"
        Set-ItemProperty -Path $pathSounds -Name "(Default)" -Value ".None" -Force
        Write-Host "[+] System Sounds disabled" -ForegroundColor Green

        # --- 6. THEME (Dark & Green) ---
        $pathPers = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        Set-ItemProperty -Path $pathPers -Name "AppsUseLightTheme" -Value 0 -Force
        Set-ItemProperty -Path $pathPers -Name "SystemUsesLightTheme" -Value 0 -Force
        Set-ItemProperty -Path $pathPers -Name "EnableTransparency" -Value 0 -Force
        # Accent Color (Green)
        $pathDWM = "HKCU:\Software\Microsoft\Windows\DWM"
        Set-ItemProperty -Path $pathDWM -Name "AccentColor" -Value 0xff00cc00 -Force
        Set-ItemProperty -Path $pathDWM -Name "ColorPrevalence" -Value 0 -Force
        Write-Host "[+] Theme: Dark, Green Accent, No Transparency" -ForegroundColor Green

        # --- 7. FILE EXPLORER (View Settings) ---
        # Show File Extensions (HideFileExt = 0)
        Set-ItemProperty -Path $pathAdv -Name "HideFileExt" -Value 0 -Force
        # Show Hidden Files (Hidden = 1)
        Set-ItemProperty -Path $pathAdv -Name "Hidden" -Value 1 -Force
        # Open Explorer to "This PC" (LaunchTo = 1)
        Set-ItemProperty -Path $pathAdv -Name "LaunchTo" -Value 1 -Force
        Write-Host "[+] Explorer: Show Extensions, Hidden Files, Open to 'This PC'" -ForegroundColor Green

        # --- 8. EXPLORER PRIVACY (Quick Access) ---
        $pathExplorer = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"
        # Uncheck "Show recently used files"
        Set-ItemProperty -Path $pathExplorer -Name "ShowRecent" -Value 0 -Force
        # Uncheck "Show frequently used folders"
        Set-ItemProperty -Path $pathExplorer -Name "ShowFrequent" -Value 0 -Force
        # Uncheck "Show files from Office.com"
        Set-ItemProperty -Path $pathExplorer -Name "ShowCloudFilesInQuickAccess" -Value 0 -Force
        Write-Host "[+] Explorer Privacy: No Recent/Frequent/Office files" -ForegroundColor Green

        # --- 9. RECYCLE BIN (Confirm Delete) ---
        # Using Policy key to enforce confirmation dialog
        $pathPolicies = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        if (!(Test-Path $pathPolicies)) { New-Item -Path $pathPolicies -Force | Out-Null }
        Set-ItemProperty -Path $pathPolicies -Name "ConfirmFileDelete" -Value 1 -Force
        Write-Host "[+] Recycle Bin: Delete Confirmation Enabled" -ForegroundColor Green

        Write-Host "`nDONE. Restarting Explorer to apply changes..." -ForegroundColor Yellow
        Start-Sleep 1
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue

    } catch {
        Write-Host "ERROR applying settings: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Registry-Mods-Menu {
    if (-not (Test-Administrator)) {
        Write-Host "ERROR: Registry modifications require Administrator privileges." -ForegroundColor Red
        Write-Host "Press any key to return..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    do {
        Clear-Host
        Write-Host "=== Registry Hacks & Context Menu Mods ===" -ForegroundColor Cyan
        Write-Host "Apply useful right-click menus and tweaks. Revert options included." -ForegroundColor Gray
        Write-Host ""
        
        Write-Host "1. Add 'Choose Power Plan' to Context Menu" -ForegroundColor White
        Write-Host "2. Add 'Restart Explorer' to Context Menu" -ForegroundColor White
        Write-Host "3. Add 'Take Ownership' to Context Menu" -ForegroundColor White
        Write-Host "4. Restore Classic Context Menu (Windows 11)" -ForegroundColor White
        Write-Host ""
        Write-Host "9. Apply 'All-in-One' Custom Settings (Dark/Black/Perf/Explorer)" -ForegroundColor Green
        Write-Host ""
        Write-Host "5. REVERT: Remove Power Plan Menu" -ForegroundColor Yellow
        Write-Host "6. REVERT: Remove Restart Explorer Menu" -ForegroundColor Yellow
        Write-Host "7. REVERT: Remove Take Ownership Menu" -ForegroundColor Yellow
        Write-Host "8. REVERT: Restore Windows 11 Default Menu" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "0. Back to Main Menu" -ForegroundColor Cyan
        Write-Host ""

        $choice = Read-Host "Choice (0-9)"

        switch ($choice) {
            "0" { return }
            
            # --- APPLY SECTION ---
            "1" {
                $reg = @"
Windows Registry Editor Version 5.00
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan]
"Icon"="powercpl.dll"
"MUIVerb"="Choose Power Plan"
"Position"="Middle"
"SubCommands"=""
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan\shell\01menu]
"MUIVerb"="Power Saver"
"Icon"="powercpl.dll"
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan\shell\01menu\command]
@="powercfg.exe /setactive a1841308-3541-4fab-bc81-f71556f20b4a"
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan\shell\02menu]
"MUIVerb"="Balanced"
"Icon"="powercpl.dll"
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan\shell\02menu\command]
@="powercfg.exe /setactive 381b4222-f694-41f0-9685-ff5bb260df2e"
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan\shell\03menu]
"MUIVerb"="High Performance"
"Icon"="powercpl.dll"
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan\shell\03menu\command]
@="powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan\shell\04menu]
"MUIVerb"="Ultimate Performance"
"Icon"="powercpl.dll"
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan\shell\04menu\command]
@="powercfg.exe /setactive e9a42b02-d5df-448d-aa00-03f14749eb61"
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan\shell\05menu]
"MUIVerb"="Power Options"
"Icon"="powercpl.dll"
"CommandFlags"=dword:00000020
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan\shell\05menu\command]
@="control.exe powercfg.cpl"
"@
                Import-RegistryContent -RegContent $reg -Description "Power Plan Context Menu"
            }

            "2" {
                $reg = @"
Windows Registry Editor Version 5.00
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\Restart Explorer]
"icon"="explorer.exe"
"Position"="Bottom"
"SubCommands"=""
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\Restart Explorer\shell\01menu]
"MUIVerb"="Restart Explorer Now"
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\Restart Explorer\shell\01menu\command]
@=hex(2):63,00,6d,00,64,00,2e,00,65,00,78,00,65,00,20,00,2f,00,63,00,20,00,74,\
  00,61,00,73,00,6b,00,6b,00,69,00,6c,00,6c,00,20,00,2f,00,66,00,20,00,2f,00,\
  69,00,6d,00,20,00,65,00,78,00,70,00,6c,00,6f,00,72,00,65,00,72,00,2e,00,65,\
  00,78,00,65,00,20,00,20,00,26,00,20,00,73,00,74,00,61,00,72,00,74,00,20,00,\
  65,00,78,00,70,00,6c,00,6f,00,72,00,65,00,72,00,2e,00,65,00,78,00,65,00,00,\
  00
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\Restart Explorer\shell\02menu]
"MUIVerb"="Restart Explorer with Pause"
"CommandFlags"=dword:00000020
[HKEY_CLASSES_ROOT\DesktopBackground\Shell\Restart Explorer\shell\02menu\command]
@=hex(2):63,00,6d,00,64,00,2e,00,65,00,78,00,65,00,20,00,2f,00,63,00,20,00,40,\
  00,65,00,63,00,68,00,6f,00,20,00,6f,00,66,00,66,00,20,00,26,00,20,00,65,00,\
  63,00,68,00,6f,00,2e,00,20,00,26,00,20,00,65,00,63,00,68,00,6f,00,20,00,53,\
  00,74,00,6f,00,70,00,70,00,69,00,6e,00,67,00,20,00,65,00,78,00,70,00,6c,00,\
  6f,00,72,00,65,00,72,00,2e,00,65,00,78,00,65,00,20,00,70,00,72,00,6f,00,63,\
  00,65,00,73,00,73,00,20,00,2e,00,20,00,2e,00,20,00,2e,00,20,00,26,00,20,00,\
  65,00,63,00,68,00,6f,00,2e,00,20,00,26,00,20,00,74,00,61,00,73,00,6b,00,6b,\
  00,69,00,6c,00,6c,00,20,00,2f,00,66,00,20,00,2f,00,69,00,6d,00,20,00,65,00,\
  78,00,70,00,6c,00,6f,00,72,00,65,00,72,00,2e,00,65,00,78,00,65,00,20,00,26,\
  00,20,00,65,00,63,00,68,00,6f,00,2e,00,20,00,26,00,20,00,65,00,63,00,68,00,\
  6f,00,2e,00,20,00,26,00,20,00,65,00,63,00,68,00,6f,00,20,00,57,00,61,00,69,\
  00,74,00,69,00,6e,00,67,00,20,00,74,00,6f,00,20,00,73,00,74,00,61,00,72,00,\
  74,00,20,00,65,00,78,00,70,00,6c,00,6f,00,72,00,65,00,72,00,2e,00,65,00,78,\
  00,65,00,20,00,70,00,72,00,6f,00,63,00,65,00,73,00,73,00,20,00,77,00,68,00,\
  65,00,6e,00,20,00,79,00,6f,00,75,00,20,00,61,00,72,00,65,00,20,00,72,00,65,\
  00,61,00,64,00,79,00,20,00,2e,00,20,00,2e,00,20,00,2e,00,20,00,26,00,20,00,\
  70,00,61,00,75,00,73,00,65,00,20,00,26,00,26,00,20,00,73,00,74,00,61,00,72,\
  00,74,00,20,00,65,00,78,00,70,00,6c,00,6f,00,72,00,65,00,72,00,2e,00,65,00,\
  78,00,65,00,20,00,26,00,26,00,20,00,65,00,78,00,69,00,74,00,00,00
"@
                Import-RegistryContent -RegContent $reg -Description "Restart Explorer Menu"
            }

            "3" {
                $reg = @"
Windows Registry Editor Version 5.00
[-HKEY_CLASSES_ROOT\*\shell\TakeOwnership]
[-HKEY_CLASSES_ROOT\*\shell\runas]
[HKEY_CLASSES_ROOT\*\shell\TakeOwnership]
@="Take Ownership"
"Extended"=-
"HasLUAShield"=""
"NoWorkingDirectory"=""
"NeverDefault"=""
[HKEY_CLASSES_ROOT\*\shell\TakeOwnership\command]
@="powershell -windowstyle hidden -command \"Start-Process cmd -ArgumentList '/c takeown /f \\\"%1\\\" && icacls \\\"%1\\\" /grant *S-1-3-4:F /t /c /l' -Verb runAs\""
"IsolatedCommand"= "powershell -windowstyle hidden -command \"Start-Process cmd -ArgumentList '/c takeown /f \\\"%1\\\" && icacls \\\"%1\\\" /grant *S-1-3-4:F /t /c /l' -Verb runAs\""
[HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership]
@="Take Ownership"
"AppliesTo"="NOT (System.ItemPathDisplay:=\"C:\\Users\" OR System.ItemPathDisplay:=\"C:\\ProgramData\" OR System.ItemPathDisplay:=\"C:\\Windows\" OR System.ItemPathDisplay:=\"C:\\Windows\\System32\" OR System.ItemPathDisplay:=\"C:\\Program Files\" OR System.ItemPathDisplay:=\"C:\\Program Files (x86)\")"
"Extended"=-
"HasLUAShield"=""
"NoWorkingDirectory"=""
"Position"="middle"
[HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership\command]
@="powershell -windowstyle hidden -command \"Start-Process cmd -ArgumentList '/c takeown /f \\\"%1\\\" /r /d y && icacls \\\"%1\\\" /grant *S-1-3-4:F /t /c /l /q' -Verb runAs\""
"IsolatedCommand"="powershell -windowstyle hidden -command \"Start-Process cmd -ArgumentList '/c takeown /f \\\"%1\\\" /r /d y && icacls \\\"%1\\\" /grant *S-1-3-4:F /t /c /l /q' -Verb runAs\""
[HKEY_CLASSES_ROOT\Drive\shell\runas]
@="Take Ownership"
"Extended"=-
"HasLUAShield"=""
"NoWorkingDirectory"=""
"Position"="middle"
"AppliesTo"="NOT (System.ItemPathDisplay:=\"C:\\\")"
[HKEY_CLASSES_ROOT\Drive\shell\runas\command]
@="cmd.exe /c takeown /f \"%1\\\" /r /d y && icacls \"%1\\\" /grant *S-1-3-4:F /t /c"
"IsolatedCommand"="cmd.exe /c takeown /f \"%1\\\" /r /d y && icacls \"%1\\\" /grant *S-1-3-4:F /t /c"
"@
                Import-RegistryContent -RegContent $reg -Description "Take Ownership Menu"
            }

            "4" {
                $reg = @"
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32]
@=""
"@
                Import-RegistryContent -RegContent $reg -Description "Win11 Classic Menu"
                Write-Host "Restarting Explorer to apply..." -ForegroundColor Yellow
                Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            }

            "9" {
                Apply-WindowsCustomSettings
            }

            # --- REVERT SECTION ---
            "5" { Remove-RegistryKey -KeyPath "Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan" -Description "Power Plan Menu" }
            
            "6" { Remove-RegistryKey -KeyPath "Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\Restart Explorer" -Description "Restart Explorer Menu" }
            
            "7" { 
                Remove-RegistryKey -KeyPath "Registry::HKEY_CLASSES_ROOT\*\shell\TakeOwnership" -Description "Take Ownership (Files)"
                Remove-RegistryKey -KeyPath "Registry::HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership" -Description "Take Ownership (Dirs)"
                Remove-RegistryKey -KeyPath "Registry::HKEY_CLASSES_ROOT\Drive\shell\runas" -Description "Take Ownership (Drives)"
            }

            "8" {
                Remove-RegistryKey -KeyPath "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}" -Description "Classic Context Menu"
                Write-Host "Restarting Explorer to revert..." -ForegroundColor Yellow
                Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            }
        }
        
        Write-Host "Press any key to continue..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } while ($true)
}
#endregion

#region Tool 19: Advanced Debloat
function Run-DebloaterMenu {
    # --- INTERNAL HELPER FUNCTIONS ---
    
    # Rinominata in "Uninstall-StoreApp" per evitare conflitti con l'alias di sistema
    function Uninstall-StoreApp {
        param([string]$PackageName, [string]$Description)
        
        # Suppress progress bar spam
        $ProgressPreference = 'SilentlyContinue'
        
        Write-Host "Processing: $Description ($PackageName)..." -ForegroundColor Yellow
        
        # 1. Remove for Current User
        $pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
        if ($pkg) {
            try {
                if ($pkg.NonRemovable -eq $true) {
                    Write-Host "  [INFO] App is flagged 'NonRemovable' by Windows. Skipping safely." -ForegroundColor DarkGray
                    return
                }
                Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                Write-Host "  [OK] Removed from current user." -ForegroundColor Green
            } catch {
                if ($_.Exception.Message -match "0x80073CFA") {
                     Write-Host "  [INFO] System Protected App (Cannot be uninstalled). Disabling via registry instead." -ForegroundColor Gray
                } else {
                     Write-Host "  [ERR] Failed to remove: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        } else {
            Write-Host "  [SKIP] Not installed/Found." -ForegroundColor DarkGray
        }

        # 2. Remove Provisioned (prevent return for new users)
        $provPkg = Get-AppxProvisionedPackage -Online | Where-Object {$_.DisplayName -like $PackageName}
        if ($provPkg) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $provPkg.PackageName -ErrorAction Stop | Out-Null
                Write-Host "  [OK] Deprovisioned from system image." -ForegroundColor Green
            } catch {
                Write-Host "  [ERR] Failed to deprovision." -ForegroundColor Red
            }
        }

        # 3. Registry Deprovisioning Block
        $deprovisionKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\$PackageName"
        if (-not (Test-Path $deprovisionKey)) {
            try { New-Item -Path $deprovisionKey -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
        
        $ProgressPreference = 'Continue'
    }

    function Uninstall-EdgeComplete {
        Write-Host "=== Removing Microsoft Edge ===" -ForegroundColor Cyan
        
        # 1. Allow Uninstall via Registry
        $regPath = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev"
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name "AllowUninstall" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

        # 2. Create Placeholder to prevent reinstall (Trick from privacy.sexy)
        $placeHolderPath = "$env:SYSTEMROOT\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe"
        if (-not (Test-Path $placeHolderPath)) {
            try {
                $parent = Split-Path $placeHolderPath
                if (-not (Test-Path $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
                New-Item -Path $placeHolderPath -ItemType File -Value "Placeholder" -Force | Out-Null
            } catch {}
        }

        # 3. Locate and Run Installer with uninstall flags
        try {
            $installer = Get-ChildItem -Path "$env:ProgramFiles (x86)\Microsoft\Edge\Application\*\Installer\setup.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($installer) {
                Write-Host "Running Edge Uninstaller..." -ForegroundColor Yellow
                $args = "--uninstall --system-level --verbose-logging --force-uninstall"
                Start-Process -FilePath $installer.FullName -ArgumentList $args -Wait -NoNewWindow
                Write-Host "Edge uninstalled." -ForegroundColor Green
            } else {
                Write-Host "Edge Installer not found (maybe already removed)." -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "Error uninstalling Edge: $($_.Exception.Message)" -ForegroundColor Red
        }

        # 4. Remove Shortcuts
        $shortcuts = @(
            "$env:Public\Desktop\Microsoft Edge.lnk",
            "$env:UserProfile\Desktop\Microsoft Edge.lnk",
            "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
            "$env:AppData\Microsoft\Internet Explorer\Quick Launch\Microsoft Edge.lnk",
            "$env:AppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk"
        )
        foreach ($lnk in $shortcuts) {
            if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue }
        }
    }

    function Remove-OneDriveComplete {
        Write-Host "=== Removing OneDrive ===" -ForegroundColor Cyan
        
        # Kill Process
        Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue

        # Registry Startup
        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -ErrorAction SilentlyContinue

        # Uninstall
        $onedriveSetup = "$env:SYSTEMROOT\SysWOW64\OneDriveSetup.exe"
        if (-not (Test-Path $onedriveSetup)) { $onedriveSetup = "$env:SYSTEMROOT\System32\OneDriveSetup.exe" }
        
        if (Test-Path $onedriveSetup) {
            Write-Host "Running Uninstaller..." -ForegroundColor Yellow
            Start-Process -FilePath $onedriveSetup -ArgumentList "/uninstall" -Wait -NoNewWindow
            Write-Host "Uninstaller finished." -ForegroundColor Green
        }

        # Registry Policies
        $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"
        if (-not (Test-Path $policyPath)) { New-Item -Path $policyPath -Force | Out-Null }
        Set-ItemProperty -Path $policyPath -Name "DisableFileSyncNGSC" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $policyPath -Name "DisableFileSync" -Value 1 -Type DWord -Force

        # Remove Folder from Explorer
        Set-ItemProperty -Path "HKCU:\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Name "System.IsPinnedToNameSpaceTree" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        
        Write-Host "OneDrive clean up done." -ForegroundColor Green
    }

    # --- MAIN DEBLOAT MENU ---
    do {
        Clear-Host
        Write-Host "=== Advanced Debloater (Based on Privacy.sexy) ===" -ForegroundColor Cyan
        Write-Host "WARNING: Removing System Apps may break functionality." -ForegroundColor Red
        Write-Host ""
        
        Write-Host "1. Remove 3rd Party Bloat (CandyCrush, Netflix, Spotify, Socials)" -ForegroundColor White
        Write-Host "2. Remove Non-Essential MS Apps (3D, Tips, Weather, News, Solitaire)" -ForegroundColor White
        Write-Host "3. Remove System/Office Apps (Mail, People, Maps, Camera, Calculator, StickyNotes)" -ForegroundColor Yellow
        Write-Host "4. Remove Xbox & Gaming Services" -ForegroundColor White
        Write-Host "5. Remove OneDrive (Full Uninstall)" -ForegroundColor Magenta
        Write-Host "6. Remove Microsoft Edge (Browser)" -ForegroundColor Magenta
        Write-Host "7. Remove Widgets, Meet Now & Copilot (UI Only)" -ForegroundColor Magenta
        Write-Host ""
        Write-Host "9. Execute ALL (Aggressive)" -ForegroundColor Red
        Write-Host "0. Back to Main Menu" -ForegroundColor Cyan
        Write-Host ""

        $choice = Read-Host "Select Option"

        if ($choice -eq "0") { return }
        
        if (-not (Test-Administrator)) {
            Write-Host "ERROR: Admin privileges required." -ForegroundColor Red
            Start-Sleep -Seconds 2
            continue
        }

        # --- EXECUTION ---
        
        # 1. 3rd Party / Junk
        if ($choice -eq "1" -or $choice -eq "9") {
            $junkApps = @(
                "king.com.CandyCrushSaga", "king.com.CandyCrushSodaSaga", "ShazamEntertainmentLtd.Shazam",
                "Flipboard.Flipboard", "9E2F88E3.Twitter", "ClearChannelRadioDigital.iHeartRadio",
                "D5EA27B7.Duolingo-LearnLanguagesforFree", "AdobeSystemsIncorporated.AdobePhotoshopExpress",
                "PandoraMediaInc.29680B314EFC2", "46928bounde.EclipseManager", "ActiproSoftwareLLC.562882FEEB491",
                "SpotifyAB.SpotifyMusic", "Microsoft.GroupMe10", "Microsoft.SkypeApp", "Microsoft.LinkedIn",
                "Microsoft.BingFoodAndDrink", "Microsoft.BingTravel", "Microsoft.BingHealthAndFitness"
            )
            foreach ($a in $junkApps) { Uninstall-StoreApp -PackageName $a -Description "Bloatware" }
        }

        # 2. Non-Essential MS
        if ($choice -eq "2" -or $choice -eq "9") {
            $minorApps = @(
                "Microsoft.Print3D", "Microsoft.3DBuilder", "Microsoft.Microsoft3DViewer", "Microsoft.MSPaint", 
                "Microsoft.BingWeather", "Microsoft.BingSports", "Microsoft.BingNews", "Microsoft.BingFinance",
                "Microsoft.Getstarted", # Tips
                "Microsoft.MicrosoftSolitaireCollection", "Microsoft.ZuneMusic", "Microsoft.ZuneVideo",
                "Microsoft.WindowsSoundRecorder", "Microsoft.WindowsAlarms", "Microsoft.WindowsFeedbackHub"
            )
            foreach ($a in $minorApps) { Uninstall-StoreApp -PackageName $a -Description "Optional MS App" }
        }

        # 3. System Apps (Risky)
        if ($choice -eq "3" -or $choice -eq "9") {
            Write-Host "WARNING: Removing core apps like Calculator or Store can't be easily undone." -ForegroundColor Red
            if ($choice -ne "9") {
                 $confirm = Read-Host "Are you sure? (Y/N)"
                 if ($confirm -ne "Y") { continue }
            }
            
            $sysApps = @(
                "Microsoft.MicrosoftOfficeHub", "Microsoft.Office.OneNote", "Microsoft.Office.Sway", "Microsoft.Todos",
                "Microsoft.WindowsStore", "Microsoft.StorePurchaseApp", 
                "Microsoft.WindowsPhone", "Microsoft.YourPhone", "Microsoft.Windows.CallingShellApp", # Phone stuff
                "Microsoft.WindowsCalculator", "Microsoft.WindowsCamera", "Microsoft.WindowsMaps",
                "microsoft.windowscommunicationsapps", # Mail & Calendar
                "Microsoft.People", "Microsoft.GetHelp"
            )
            foreach ($a in $sysApps) { Uninstall-StoreApp -PackageName $a -Description "System App" }
        }

        # 4. Xbox
        if ($choice -eq "4" -or $choice -eq "9") {
            $xboxApps = @(
                "Microsoft.GamingApp", "Microsoft.XboxGamingOverlay", "Microsoft.XboxGameOverlay", "Microsoft.XboxApp",
                "Microsoft.Xbox.TCUI", "Microsoft.XboxSpeechToTextOverlay", "Microsoft.XboxIdentityProvider"
            )
            foreach ($a in $xboxApps) { Uninstall-StoreApp -PackageName $a -Description "Xbox Service" }
            
            # Disable Services
            Write-Host "Disabling Xbox Services..." -ForegroundColor Yellow
            $xServices = "XblGameSave", "XboxNetApiSvc", "XblAuthManager"
            foreach ($s in $xServices) {
                if (Get-Service $s -ErrorAction SilentlyContinue) {
                    Stop-Service $s -Force -ErrorAction SilentlyContinue
                    Set-Service $s -StartupType Disabled -ErrorAction SilentlyContinue
                }
            }
        }

        # 5. OneDrive
        if ($choice -eq "5" -or $choice -eq "9") {
            Remove-OneDriveComplete
        }

        # 6. Microsoft Edge
        if ($choice -eq "6" -or $choice -eq "9") {
            Uninstall-EdgeComplete
        }

        # 7. Widgets / Copilot / MeetNow (Registry)
        if ($choice -eq "7" -or $choice -eq "9") {
            Write-Host "Applying UI Tweaks & Policies..." -ForegroundColor Cyan

            # Widgets (TaskbarDa)
            $regAdv = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            Set-ItemProperty -Path $regAdv -Name "TaskbarDa" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

            # Attempt to remove Web Experience (Breaks widgets) if possible
            Uninstall-StoreApp -PackageName "MicrosoftWindows.Client.WebExperience" -Description "Web Experience Pack"

            # Disable Content Delivery Manager (Ads/Spotlight) - Instead of uninstall
            $regContent = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            if (-not (Test-Path $regContent)) { New-Item -Path $regContent -Force | Out-Null }
            Set-ItemProperty -Path $regContent -Name "ContentDeliveryAllowed" -Value 0 -Type DWord -Force
            Set-ItemProperty -Path $regContent -Name "OemPreInstalledAppsEnabled" -Value 0 -Type DWord -Force
            Set-ItemProperty -Path $regContent -Name "PreInstalledAppsEnabled" -Value 0 -Type DWord -Force
            Set-ItemProperty -Path $regContent -Name "SilentInstalledAppsEnabled" -Value 0 -Type DWord -Force
            Write-Host "  [TWEAK] Content Delivery (Ads/Suggestions) disabled." -ForegroundColor Gray

            # Disable People Bar (instead of uninstalling PeopleExperienceHost)
            Set-ItemProperty -Path $regAdv -Name "Peopleband" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Host "  [TWEAK] People Bar disabled." -ForegroundColor Gray

            # Copilot
            $coKeys = @(
                "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot",
                "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
            )
            foreach ($k in $coKeys) {
                if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
                Set-ItemProperty -Path $k -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Force
            }
            # Hide Copilot Button
            Set-ItemProperty -Path $regAdv -Name "ShowCopilotButton" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

            # Meet Now (HideSCAMeetNow)
            $polExp = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
            if (-not (Test-Path $polExp)) { New-Item -Path $polExp -Force | Out-Null }
            Set-ItemProperty -Path $polExp -Name "HideSCAMeetNow" -Value 1 -Type DWord -Force

            Write-Host "UI Tweaks applied. Restart Explorer to see changes." -ForegroundColor Green
        }

        Write-Host "Operation finished." -ForegroundColor Green
        Write-Host "Press any key..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

    } while ($true)
}
#endregion

#region Tool 20: Browser Profile Backup
function Run-BrowserProfileBackup {
    # ============================================================
    # BROWSER PROFILE BACKUP UTILITY
    # Compatibility: PowerShell 5.1+
    # Supports: Chrome, Edge, Brave, Chromium, Firefox, LibreWolf
    # ============================================================

    # Get the directory where this script is running
    $ScriptPath = $PSScriptRoot
    if ([string]::IsNullOrEmpty($ScriptPath)) { $ScriptPath = [Environment]::GetFolderPath("Desktop") }

    # Define Root Paths
    $LocalAppData = $env:LOCALAPPDATA
    $AppData      = $env:APPDATA
    
    # Get Current Date for Filename
    $DateStamp = Get-Date -Format "yyyy-MM-dd"

    # Define Browser Paths & Zip Names
    # Note: Chromium-based browsers use LOCALAPPDATA and "User Data" folder.
    #       Firefox-based browsers use APPDATA (Roaming) and the root folder to capture profiles.ini.
    $Browsers = @(
        [PSCustomObject]@{ Id=1; Name="Google Chrome";  Source="$LocalAppData\Google\Chrome\User Data";             ZipName="chrome_backup_$DateStamp.zip" }
        [PSCustomObject]@{ Id=2; Name="Microsoft Edge"; Source="$LocalAppData\Microsoft\Edge\User Data";            ZipName="edge_backup_$DateStamp.zip" }
        [PSCustomObject]@{ Id=3; Name="Brave Browser";  Source="$LocalAppData\BraveSoftware\Brave-Browser\User Data"; ZipName="brave_backup_$DateStamp.zip" }
        [PSCustomObject]@{ Id=4; Name="Chromium";       Source="$LocalAppData\Chromium\User Data";                  ZipName="chromium_backup_$DateStamp.zip" }
        [PSCustomObject]@{ Id=5; Name="Mozilla Firefox";Source="$AppData\Mozilla\Firefox";                          ZipName="firefox_backup_$DateStamp.zip" }
        [PSCustomObject]@{ Id=6; Name="LibreWolf";      Source="$AppData\LibreWolf";                                ZipName="librewolf_backup_$DateStamp.zip" }
    )

    # --- INTERACTIVE MENU ---
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "      BROWSER PROFILE BACKUP UTILITY"
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Saving backups to: $ScriptPath" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Select browser(s) to backup:" -ForegroundColor Yellow

    foreach ($b in $Browsers) {
        Write-Host "   [$($b.Id)] $($b.Name)"
    }
    Write-Host "   [A] All supported browsers"
    Write-Host ""
    
    $Selection = Read-Host "   Selection"

    # Filter selection
    $SelectedBrowsers = @()
    if ($Selection -eq "A" -or $Selection -eq "a") {
        $SelectedBrowsers = $Browsers
    }
    else {
        # Allow multiple numbers separated by comma (e.g. 1,5) or single number
        $Ids = $Selection -split ","
        foreach ($id in $Ids) {
            $Found = $Browsers | Where-Object { $_.Id -eq $id.Trim() }
            if ($Found) { $SelectedBrowsers += $Found }
        }
    }

    if ($SelectedBrowsers.Count -eq 0) {
        Write-Host "No valid selection made." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host ""

    # --- PROCESSING FUNCTION ---
    foreach ($Browser in $SelectedBrowsers) {
        $SourcePath  = $Browser.Source
        $DestZip     = Join-Path -Path $ScriptPath -ChildPath $Browser.ZipName
        $Name        = $Browser.Name

        if (Test-Path -Path $SourcePath) {
            Write-Host "Processing $Name..." -ForegroundColor Cyan
            
            try {
                # Check if file exists and remove it to avoid append errors
                if (Test-Path $DestZip) { Remove-Item $DestZip -Force }

                # Progress Bar (Indeterminate)
                Write-Progress -Activity "Backing up: $Name" -Status "Compressing profile data..." -PercentComplete 50

                # Compress
                # We use ErrorAction Stop to catch open file errors
                Compress-Archive -Path $SourcePath -DestinationPath $DestZip -CompressionLevel Optimal -Force -ErrorAction Stop
                
                # Complete
                Write-Progress -Activity "Backing up: $Name" -Status "Done" -PercentComplete 100 -Completed
                Write-Host " [OK] Saved: $DestZip" -ForegroundColor Green
            }
            catch {
                Write-Progress -Activity "Backing up: $Name" -Status "Error" -Completed
                Write-Host " [ERROR] Failed to backup $Name." -ForegroundColor Red
                Write-Host " Details: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host " Tip: Ensure the browser is CLOSED before backing up." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host " [SKIP] Profile path not found for $Name." -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    Write-Host "Backup process finished. Press any key..." -ForegroundColor Green
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

#region Main Menu Logic
function Show-Menu {
    Clear-Host
    Write-Host "========== WinCare v2.7 ==========" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "---------- Safety & Backup ----------" -ForegroundColor White
    Write-Host "1. Create System Restore Point (Recommended)" -ForegroundColor Yellow
    Write-Host "2. Browser Profile Backup Utility" -ForegroundColor Cyan
    
    Write-Host "`n---------- System Repair ----------" -ForegroundColor White
    Write-Host "3. SFC Scan - Repairs corrupted files" -ForegroundColor Cyan
    Write-Host "4. CHKDSK Scan - Checks disk errors" -ForegroundColor Cyan
    Write-Host "5. DISM Image Repair - Restores system health" -ForegroundColor Cyan
    
    Write-Host "`n---------- Maintenance & Cleanup ----------" -ForegroundColor White
    Write-Host "6. Advanced Disk Cleanup (Temp, Updates, Logs)" -ForegroundColor Cyan
    Write-Host "7. WinSxS Cleanup - Component Store" -ForegroundColor Cyan
    Write-Host "8. Clear Thumbnail Cache" -ForegroundColor Cyan
    Write-Host "9. NVIDIA Menu" -ForegroundColor Cyan
    
    Write-Host "`n---------- Network & Configuration ----------" -ForegroundColor White
    Write-Host "10. DNS & Network Tools (Set DNS, NSLookup, Reset)" -ForegroundColor Cyan
    Write-Host "11. PowerShell Policy Config" -ForegroundColor Cyan
    Write-Host "12. Privacy, Telemetry & AI" -ForegroundColor Cyan
    
    Write-Host "`n---------- Hardware & Power ----------" -ForegroundColor White
    Write-Host "13. View System Hardware Info" -ForegroundColor Green
    Write-Host "14. Generate Battery Health Report" -ForegroundColor Green
    Write-Host "15. Shutdown/Restart Menu" -ForegroundColor Green
    
    Write-Host "`n---------- External Tools (3rd Party) ----------" -ForegroundColor Red
    Write-Host "16. ChrisTitusTech (Debloat/Tweaks)" -ForegroundColor Cyan
    Write-Host "17. Raphire (Debloat/Tweaks)" -ForegroundColor Cyan
    Write-Host "18. Activation Tool" -ForegroundColor Cyan
    
    Write-Host "`n---------- Registry Hacks & Debloat ----------" -ForegroundColor Magenta
    Write-Host "19. Windows Settings" -ForegroundColor Cyan
    Write-Host "20. Advanced Debloat" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "0. Exit" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "Choice (0-20)"
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
        "2" { Run-BrowserProfileBackup }
        "3" { Run-SFCScan }
        "4" { Run-CHKDSK }
        "5" { Run-DISMCheck }
        "6" { Run-AdvancedDiskCleanup }
        "7" { Run-DISMCleanupWinSxS }
        "8" { Clear-ThumbnailCache }
        "9" { Show-NvidiaMenu }
        "10" { DNSManagementMenu }
        "11" { Set-ExecutionPolicyMenu }
        "12" { Disable-RecallAndCopilot }
        "13" { Show-HardwareInfo }
        "14" { Generate-BatteryReport }
        "15" { ShutdownMenu }
        "16" { Run-ChrisTitusTech }
        "17" { Run-Raphire }
        "18" { Run-WindowsOfficeActivator }
        "19" { Registry-Mods-Menu }
        "20" { Run-DebloaterMenu }

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