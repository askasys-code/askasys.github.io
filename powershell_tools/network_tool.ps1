<#
.SYNOPSIS
    NetCare: Advanced Network Tool

.DESCRIPTION
    A standalone PowerShell tool for managing DNS settings, IP configurations, performing lookups, and resetting the network stack.

    Keybinding Logic:
    - [1]:   Configure DNS Servers (Google, Cloudflare, AdGuard, etc.).
    - [2]:   Configure IP Address (DHCP / Static).
    - [3]:   Run Interactive NSLookup Query.
    - [4]:   Reset Network Stack (TCP/IP & Winsock).
    - [X]:   Exit.

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

# Force UTF-8 Encoding for correct display of characters
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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

# ---------------------------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------------------------

function Pause-Script {
    # Helper to pause execution until a key is pressed.
    Write-Host "`n   Press any key to return to the menu..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Get-NetworkStatusUI {
    # Retrieves and formats the current primary network adapter status for the UI.
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    if ($adapter) {
        # Get DNS
        $dns = "DHCP/Automatic"
        $dnsObj = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
        if ($dnsObj -and $dnsObj.ServerAddresses) {
            $dns = $dnsObj.ServerAddresses -join ", "
        }

        # Get IP
        $ipConf = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $ipStr = if ($ipConf) { $ipConf.IPAddress } else { "Unknown" }
        $dhcpStatus = if ($ipConf.PrefixOrigin -eq "Dhcp") { " (DHCP)" } else { " (Static)" }

        Write-Host "   Active Adapter: $($adapter.Name)" -ForegroundColor Green
        Write-Host "   Current IP      : $ipStr$dhcpStatus" -ForegroundColor Green
        Write-Host "   Current DNS     : $dns" -ForegroundColor Yellow
    } else {
        Write-Host "   Network Status: NO ACTIVE ADAPTER DETECTED" -ForegroundColor Red
    }
}

function Select-NetworkAdapter {
    # Helper function to select an adapter. Returns the adapter object or $null.
    Write-Host "   [INFO] Scanning network adapters..." -ForegroundColor Yellow
    
    # Wrap in @() to ensure array
    $adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object Name, InterfaceDescription, ifIndex, Status)
    
    if ($adapters.Count -eq 0) {
        Write-Host "   [X] NO ACTIVE ADAPTER FOUND." -ForegroundColor Red
        return $null
    }

    if ($adapters.Count -eq 1) {
        Write-Host "   [OK] Found 1 active adapter: $($adapters[0].Name)" -ForegroundColor Green
        return $adapters[0]
    } else {
        Write-Host "   [!] Multiple active adapters found. Please select one:" -ForegroundColor Cyan
        $i = 1
        foreach ($nic in $adapters) {
            Write-Host "     [$i] $($nic.Name) ($($nic.InterfaceDescription))" -ForegroundColor White
            $i++
        }
        
        do {
            $selInput = Read-Host "   Select Adapter (1-$($adapters.Count))"
            if ($selInput -match '^\d+$' -and [int]$selInput -ge 1 -and [int]$selInput -le $adapters.Count) {
                return $adapters[[int]$selInput - 1]
            }
            Write-Host "   [X] Invalid selection." -ForegroundColor Red
        } while ($true)
    }
    return $null
}

function Set-DnsServers {
    Clear-Host
    Write-Host "--- CONFIGURE DNS SERVERS ---" -ForegroundColor Cyan

    $selectedAdapter = Select-NetworkAdapter
    if (-not $selectedAdapter) { Pause-Script; return }

    Write-Host "`n   [TARGET] Selected Adapter: $($selectedAdapter.Name)" -ForegroundColor Green

    # Expanded DNS List
    $dnsList = @(
        [PSCustomObject]@{Name="Google Public DNS"; Primary="8.8.8.8"; Secondary="8.8.4.4"}
        [PSCustomObject]@{Name="Cloudflare (Standard)"; Primary="1.1.1.1"; Secondary="1.0.0.1"}
        [PSCustomObject]@{Name="Cloudflare (Malware Blocking)"; Primary="1.1.1.2"; Secondary="1.0.0.2"}
        [PSCustomObject]@{Name="Cloudflare (Family / Adult Blocking)"; Primary="1.1.1.3"; Secondary="1.0.0.3"}
        [PSCustomObject]@{Name="Quad9 (Standard - Malware Blocking)"; Primary="9.9.9.9"; Secondary="149.112.112.112"}
        [PSCustomObject]@{Name="Quad9 (Unsecured - No Blocking)"; Primary="9.9.9.10"; Secondary="149.112.112.10"}
        [PSCustomObject]@{Name="Quad9 (ECS Support)"; Primary="9.9.9.11"; Secondary="149.112.112.11"}
        [PSCustomObject]@{Name="AdGuard (Default - Ads/Trackers)"; Primary="94.140.14.14"; Secondary="94.140.15.15"}
        [PSCustomObject]@{Name="AdGuard (Family - Ads/Adult)"; Primary="94.140.14.15"; Secondary="94.140.15.16"}
        [PSCustomObject]@{Name="OpenDNS (Standard)"; Primary="208.67.222.222"; Secondary="208.67.220.220"}
        [PSCustomObject]@{Name="OpenDNS (Family Shield)"; Primary="208.67.222.123"; Secondary="208.67.220.123"}
        [PSCustomObject]@{Name="CleanBrowsing (Family Filter)"; Primary="185.228.168.168"; Secondary="185.228.169.168"}
        [PSCustomObject]@{Name="Yandex (Safe)"; Primary="77.88.8.8"; Secondary="77.88.8.1"}
        [PSCustomObject]@{Name="Yandex (Family)"; Primary="77.88.8.7"; Secondary="77.88.8.3"}
        [PSCustomObject]@{Name="DHCP (Automatic / ISP)"; Primary="DHCP"; Secondary="DHCP"}
    )

    Write-Host "`n   Select a DNS provider:" -ForegroundColor Cyan
    for ($k = 0; $k -lt $dnsList.Count; $k++) {
        Write-Host "     [$k] $($dnsList[$k].Name) ($($dnsList[$k].Primary))" -ForegroundColor White
    }

    $choice = Read-Host "   Choice (0-$($dnsList.Count-1))"

    if ($choice -match '^\d+$' -and [int]$choice -ge 0 -and [int]$choice -lt $dnsList.Count) {
        $selectedDNS = $dnsList[[int]$choice]
        
        try {
            Write-Host "   [INFO] Applying settings..." -ForegroundColor Yellow
            
            if ($selectedDNS.Primary -eq "DHCP") {
                Set-DnsClientServerAddress -InterfaceIndex $selectedAdapter.ifIndex -ResetServerAddresses -ErrorAction Stop
                Write-Host "   [OK] DNS reset to DHCP (Automatic)." -ForegroundColor Green
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $selectedAdapter.ifIndex -ServerAddresses ($selectedDNS.Primary, $selectedDNS.Secondary) -ErrorAction Stop
                Write-Host "   [OK] DNS set to: $($selectedDNS.Name)" -ForegroundColor Green
            }
            
            Write-Host "   [INFO] Flushing DNS cache..." -ForegroundColor DarkCyan
            Clear-DnsClientCache
        } catch {
            Write-Host "   [X] ERROR applying DNS: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "   [!] Canceled." -ForegroundColor Yellow
    }
    
    Pause-Script
}

function Set-IpConfiguration {
    # Allows setting IP address to DHCP or Static with Auto-Calculation for Subnet/Gateway
    Clear-Host
    Write-Host "--- CONFIGURE IP ADDRESS ---" -ForegroundColor Cyan

    $selectedAdapter = Select-NetworkAdapter
    if (-not $selectedAdapter) { Pause-Script; return }
    $idx = $selectedAdapter.ifIndex

    Write-Host "`n   [TARGET] Selected Adapter: $($selectedAdapter.Name)" -ForegroundColor Green
    Write-Host "   [1] Set to DHCP (Automatic IP)"
    Write-Host "   [2] Set to Static IP"
    Write-Host "   [0] Cancel"
    
    $mode = Read-Host "   Select Option"
    
    if ($mode -eq "1") {
        # --- DHCP MODE ---
        try {
            Write-Host "   [INFO] Enabling DHCP..." -ForegroundColor Yellow
            Set-NetIPInterface -InterfaceIndex $idx -Dhcp Enabled -AddressFamily IPv4 -ErrorAction Stop
            
            $resetDns = Read-Host "   Reset DNS to Automatic as well? (Y/N)"
            if ($resetDns -eq "Y" -or $resetDns -eq "y") {
                Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -ErrorAction SilentlyContinue
                Write-Host "   [OK] DNS reset to DHCP." -ForegroundColor Green
            }

            Write-Host "   [OK] IP set to DHCP." -ForegroundColor Green
        } catch {
            Write-Host "   [X] Failed to enable DHCP: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    elseif ($mode -eq "2") {
        # --- STATIC MODE ---
        Write-Host "`n   --- STATIC IP SETUP ---" -ForegroundColor Magenta
        
        # 1. Get IP
        $ip = Read-Host "   Enter IP Address (e.g., 192.168.1.50)"
        
        if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            Write-Host "   [X] Invalid IP address format." -ForegroundColor Red
            Pause-Script
            return
        }

        # 2. Calculate Defaults
        $prefix = "24"
        $gateway = ""
        $gwDefault = ""

        try {
            $ipParts = $ip -split "\."
            $gwDefault = "$($ipParts[0]).$($ipParts[1]).$($ipParts[2]).1"
            
            Write-Host "`n   [?] Recommended Defaults detected:" -ForegroundColor Cyan
            Write-Host "       Subnet Mask : 255.255.255.0 (Prefix 24)" -ForegroundColor Gray
            Write-Host "       Gateway     : $gwDefault" -ForegroundColor Gray
            
            $useDefaults = Read-Host "   Use these defaults? (Y/N) [Default: Y]"
            
            if ($useDefaults -eq "N" -or $useDefaults -eq "n") {
                $prefix = Read-Host "   Enter Subnet Prefix Length (Input '24' for 255.255.255.0)"
                $gateway = Read-Host "   Enter Default Gateway"
            } else {
                $prefix = "24"
                $gateway = $gwDefault
            }
        } catch {
            Write-Host "   [X] Error calculating defaults." -ForegroundColor Red
        }
        
        if ([string]::IsNullOrWhiteSpace($gateway)) { Write-Host "   [X] Gateway required."; Pause-Script; return }
        if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = "24" }

        try {
            Write-Host "   [INFO] Applying Static IP configuration..." -ForegroundColor Yellow
            
            # STEP 1: Disable DHCP explicitly
            Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled -AddressFamily IPv4 -ErrorAction SilentlyContinue

            # STEP 2: Remove existing IP addresses
            Remove-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            
            # STEP 3: Remove existing Default Gateway (Route 0.0.0.0/0) to fix "Instance exists" error
            Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

            # STEP 4: Set New IP and Gateway
            New-NetIPAddress -InterfaceIndex $idx -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gateway -AddressFamily IPv4 -ErrorAction Stop | Out-Null
            
            Write-Host "   [OK] Static IP ($ip/$prefix) applied successfully." -ForegroundColor Green
        } catch {
            Write-Host "   [X] Failed to set Static IP: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    else {
        Write-Host "   [!] Canceled." -ForegroundColor Yellow
    }
    Pause-Script
}

function Start-NslookupInteractive {
    # Provides an interactive prompt to resolve domain names to IP addresses.
    Clear-Host
    Write-Host "--- INTERACTIVE NSLOOKUP ---" -ForegroundColor Cyan
    Write-Host "   Type a domain (e.g., google.com) to resolve it." -ForegroundColor White
    Write-Host "   Type 'exit' to return to the menu." -ForegroundColor Gray
    Write-Host ""
    
    do {
        $domain = Read-Host "   Domain/IP >"
        
        if ([string]::IsNullOrWhiteSpace($domain)) { continue }
        if ($domain -eq "exit") { break }
        
        Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
        cmd /c "nslookup $domain"
        Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
        Write-Host ""
        
    } while ($true)
}

function Reset-NetworkStack {
    # Resets TCP/IP and Winsock configurations to their default state. Requires a reboot.
    Clear-Host
    Write-Host "--- RESET NETWORK STACK ---" -ForegroundColor Cyan
    Write-Host "   [!] This will reset TCP/IP and Winsock." -ForegroundColor Yellow
    Write-Host "   [!] Useful for fixing persistent connectivity issues." -ForegroundColor Yellow
    
    $confirm = Read-Host "`n   Are you sure you want to proceed? (Y/N)"
    if ($confirm -eq "Y" -or $confirm -eq "y") {
        try {
            Write-Host "   [INFO] Resetting 'netsh int ip reset'..." -ForegroundColor DarkCyan
            netsh int ip reset | Out-Null
            Write-Host "   [INFO] Resetting 'netsh winsock reset'..." -ForegroundColor DarkCyan
            netsh winsock reset | Out-Null
            
            Write-Host "`n   [OK] Network reset complete." -ForegroundColor Green
            Write-Host "   [!!!] A SYSTEM REBOOT IS REQUIRED to apply the changes." -ForegroundColor Red
        } catch {
            Write-Host "   [X] ERROR during reset: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "   [!] Canceled." -ForegroundColor Gray
    }
    Pause-Script
}

# ---------------------------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------------------------

do {
    Clear-Host
    Write-Host "   ==============================" -ForegroundColor Cyan
    Write-Host "            NETWORK TOOL         " -ForegroundColor White
    Write-Host "   ==============================" -ForegroundColor Cyan
    
    # Display real-time network status
    Get-NetworkStatusUI

    # Display Menu
    Write-Host ""
    Write-Host "   AVAILABLE ACTIONS" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    Write-Host "   [1] Configure DNS Servers" -ForegroundColor White
    Write-Host "   [2] Configure IP Address (Static/DHCP)" -ForegroundColor White
    Write-Host "   [3] Run NSLookup Query" -ForegroundColor White
    Write-Host "   [4] Reset Network Stack (Reboot Required)" -ForegroundColor Yellow
    Write-Host "   [X] Exit" -ForegroundColor White
    Write-Host ""

    $choice = Read-Host "   Select an option"

    switch ($choice) {
        "1" { Set-DnsServers }
        "2" { Set-IpConfiguration }
        "3" { Start-NslookupInteractive }
        "4" { Reset-NetworkStack }
        
        { $_ -eq "x" -or $_ -eq "X" } { Write-Host "   Exiting..."; Start-Sleep 1; exit }
        
        Default { Write-Host "   [X] Invalid selection." -ForegroundColor Red; Start-Sleep 1 }
    }

} while ($true)