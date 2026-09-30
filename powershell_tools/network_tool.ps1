# SCRIPT:        Network Diagnostics & Configuration Tool
# REQUIRES:      Administrator Privileges
# COMPATIBILITY: Windows PowerShell 5.1 / PowerShell 7+ (Core) on Windows 10/11/Server
# CODING STANDARD: All internal comments must be written in ENGLISH.

# Updated: 2026-09-30

# ---------------------------------------------------------------------------
# INITIALIZATION & SETUP
# ---------------------------------------------------------------------------

#region Setup, Encoding & Auto-Elevation
# --- 1. GLOBAL SETTINGS ---
$ErrorActionPreference = "Continue"

# Configure console encoding to UTF-8 without byte-order marks
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# Modern TLS Security Protocols (TLS 1.2 & TLS 1.3)
# Note: Using numeric bitmask casting (3072 = Tls12, 12288 = Tls13) prevents crashes on legacy .NET Framework assemblies lacking the Tls13 enum symbol.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072 -bor [Net.SecurityProtocolType]12288
} catch {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
        # Fallback to system default if restricted by group policies
    }
}

# --- 2. ADMIN SELF-ELEVATION ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "`n [!] Administrator privileges required." -ForegroundColor Yellow
    Write-Host " [INFO] Elevating process permissions..." -ForegroundColor Cyan

    # Accurately detect calling engine (pwsh.exe vs powershell.exe) to maintain PowerShell edition
    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe -or -not (Test-Path -Path $psExe -PathType Leaf)) {
        $psExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }
    }

    # Resolve accurate script path
    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = $MyInvocation.MyCommand.Definition
    }

    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -Path $scriptPath -PathType Leaf)) {
        Write-Host " [X] Failed to determine script path. Please run PowerShell as Administrator manually." -ForegroundColor Red
        Write-Host "`n Press Enter to exit..." -ForegroundColor Gray
        [void](Read-Host)
        exit 1
    }

    $workingDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { (Get-Location).Path }

    try {
        Start-Process -FilePath $psExe `
                      -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
                      -Verb RunAs `
                      -WorkingDirectory $workingDir
        exit 0
    } catch {
        Write-Host " [X] Elevation aborted or rejected by user: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "`n Press Enter to exit..." -ForegroundColor Gray
        [void](Read-Host)
        exit 1
    }
}
#endregion

# ---------------------------------------------------------------------------
# HELPER FUNCTIONS
# ---------------------------------------------------------------------------

function Pause-Script {
    <#
    .SYNOPSIS
        Safely pauses execution across different console hosts (Console, ISE, Terminal, VSCode).
    #>
    Write-Host "`n   Press any key to return to the menu..." -ForegroundColor Gray
    if ($Host.UI.RawUI -and $Host.Name -notmatch "ISE|Visual Studio Code") {
        try {
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        } catch {
            # Fallback to standard Read-Host if raw reading fails
        }
    }
    [void](Read-Host)
}

function Convert-SubnetMaskToPrefix {
    <#
    .SYNOPSIS
        Converts Subnet Mask (e.g. 255.255.255.0) or CIDR (e.g. 24) to integer prefix length.
    #>
    param ([string]$InputMask)

    if ($InputMask -match '^\d+$') {
        $val = [int]$InputMask
        if ($val -ge 1 -and $val -le 32) { return $val }
    }

    # Attempt parsing dotted-decimal mask
    $parsedMask = $null
    if ([System.Net.IPAddress]::TryParse($InputMask, [ref]$parsedMask) -and $parsedMask.AddressFamily -eq 'InterNetwork') {
        $bytes = $parsedMask.GetAddressBytes()
        $binaryString = ($bytes | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
        # Valid subnet mask must be contiguous 1s followed by contiguous 0s
        if ($binaryString -match '^1+0*$') {
            return ($binaryString -replace '0', '').Length
        }
    }

    return 24 # Safe default if input is malformed
}

function Test-IsUnicastIPv4 {
    <#
    .SYNOPSIS
        Validates if an IP is a valid routable/local IPv4 address (filters out multicast, loopback, broadcast).
    #>
    param ([string]$IpAddress)

    $ipObj = $null
    if (-not [System.Net.IPAddress]::TryParse($IpAddress, [ref]$ipObj) -or $ipObj.AddressFamily -ne 'InterNetwork') {
        return $false
    }

    $bytes = $ipObj.GetAddressBytes()
    # Reject: 0.0.0.0, Loopback (127.0.0.0/8), Multicast (224.0.0.0/4), Broadcast (255.255.255.255)
    if ($bytes[0] -eq 0 -or $bytes[0] -eq 127 -or $bytes[0] -ge 224) {
        return $false
    }

    return $true
}

function Get-PrimaryNetworkAdapter {
    <#
    .SYNOPSIS
        Determines the true active primary network adapter prioritizing the default gateway route,
        preventing WSL, Hyper-V, Docker, or Bluetooth adapters from overriding display metrics.
    #>
    # Attempt 1: Identify adapter owning the default route (0.0.0.0/0)
    $activeRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Sort-Object -Property RouteMetric, InterfaceMetric |
                   Select-Object -First 1

    if ($activeRoute) {
        $adapter = Get-NetAdapter -InterfaceIndex $activeRoute.InterfaceIndex -ErrorAction SilentlyContinue
        if ($adapter -and $adapter.Status -eq 'Up') {
            return $adapter
        }
    }

    # Attempt 2: First active physical adapter
    $physical = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' } |
                Select-Object -First 1
    if ($physical) { return $physical }

    # Attempt 3: Any operational adapter
    return (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1)
}

function Get-NetworkStatusUI {
    <#
    .SYNOPSIS
        Displays real-time status banner for the primary network interface.
    #>
    $adapter = Get-PrimaryNetworkAdapter

    if ($adapter) {
        # DNS Servers
        $dns = "DHCP/Automatic"
        $dnsObj = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($dnsObj -and $dnsObj.ServerAddresses) {
            $dns = $dnsObj.ServerAddresses -join ", "
        }

        # IP Address (Excluding APIPA 169.254.x.x)
        $ipConf = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Where-Object { $_.IPAddress -notlike "169.254.*" } |
                  Select-Object -First 1

        $ipStr = if ($ipConf) { "$($ipConf.IPAddress)/$($ipConf.PrefixLength)" } else { "Unknown" }
        $dhcpStatus = if ($ipConf) { if ($ipConf.PrefixOrigin -eq "Dhcp") { " (DHCP)" } else { " (Static)" } } else { "" }

        # Default Gateway
        $gwRoute = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Select-Object -First 1
        $gwStr = if ($gwRoute -and $gwRoute.NextHop -ne '0.0.0.0') { $gwRoute.NextHop } else { "Not configured" }

        # Link Speed
        $speed = if ($adapter.LinkSpeed) { " [$($adapter.LinkSpeed)]" } else { "" }

        Write-Host "   Active Adapter  : $($adapter.Name) ($($adapter.InterfaceDescription))$speed" -ForegroundColor Green
        Write-Host "   IPv4 Address    : $ipStr$dhcpStatus" -ForegroundColor Green
        Write-Host "   Default Gateway : $gwStr" -ForegroundColor Green
        Write-Host "   DNS Servers     : $dns" -ForegroundColor Yellow
    } else {
        Write-Host "   Network Status  : NO ACTIVE NETWORK ADAPTER DETECTED" -ForegroundColor Red
    }
}

function Select-NetworkAdapter {
    <#
    .SYNOPSIS
        Presents an adapter selection menu or auto-selects if only one is available.
    #>
    Write-Host "   [INFO] Scanning operational network interfaces..." -ForegroundColor Yellow
    
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | 
                  Where-Object { $_.Status -eq "Up" } | 
                  Sort-Object -Property Physical, Name -Descending)

    if ($adapters.Count -eq 0) {
        Write-Host "   [X] No operational (UP) adapters found." -ForegroundColor Red
        return $null
    }

    if ($adapters.Count -eq 1) {
        Write-Host "   [OK] Automatically targeted active adapter: $($adapters[0].Name)" -ForegroundColor Green
        return $adapters[0]
    }

    Write-Host "   Multiple active adapters detected. Choose target interface:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $adapters.Count; $i++) {
        $nicType = if ($adapters[$i].Physical) { "Physical" } else { "Virtual" }
        Write-Host "     [$($i + 1)] $($adapters[$i].Name) | Type: $nicType | Descr: $($adapters[$i].InterfaceDescription)" -ForegroundColor White
    }
    Write-Host "     [0] Cancel" -ForegroundColor DarkGray

    do {
        $selection = Read-Host "   Select Adapter (1-$($adapters.Count) or 0 to Cancel)"
        if ($selection -eq '0') { return $null }
        if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $adapters.Count) {
            return $adapters[[int]$selection - 1]
        }
        Write-Host "   [!] Invalid selection. Please re-enter." -ForegroundColor Yellow
    } while ($true)
}

# ---------------------------------------------------------------------------
# CORE OPERATIONS
# ---------------------------------------------------------------------------

function Set-DnsServers {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "         CONFIGURE DNS SERVERS            " -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan

    $adapter = Select-NetworkAdapter
    if (-not $adapter) { Pause-Script; return }

    Write-Host "`n   [TARGET] Selected Interface: $($adapter.Name)" -ForegroundColor Green

    $dnsList = @(
        [PSCustomObject]@{ Name = "Google Public DNS";                   Primary = "8.8.8.8";         Secondary = "8.8.4.4" }
        [PSCustomObject]@{ Name = "Cloudflare (Standard)";               Primary = "1.1.1.1";         Secondary = "1.0.0.1" }
        [PSCustomObject]@{ Name = "Cloudflare (Malware Protection)";     Primary = "1.1.1.2";         Secondary = "1.0.0.2" }
        [PSCustomObject]@{ Name = "Cloudflare (Family / Adult Blocking)"; Primary = "1.1.1.3";        Secondary = "1.0.0.3" }
        [PSCustomObject]@{ Name = "Quad9 (Standard Malware Filter)";     Primary = "9.9.9.9";         Secondary = "149.112.112.112" }
        [PSCustomObject]@{ Name = "Quad9 (Unsecured / No Filter)";       Primary = "9.9.9.10";        Secondary = "149.112.112.10" }
        [PSCustomObject]@{ Name = "Quad9 (ECS Support)";                 Primary = "9.9.9.11";        Secondary = "149.112.112.11" }
        [PSCustomObject]@{ Name = "AdGuard (Default - Ads/Trackers)";    Primary = "94.140.14.14";     Secondary = "94.140.15.15" }
        [PSCustomObject]@{ Name = "AdGuard (Family Filter)";             Primary = "94.140.14.15";     Secondary = "94.140.15.16" }
        [PSCustomObject]@{ Name = "OpenDNS (Standard)";                  Primary = "208.67.222.222";   Secondary = "208.67.220.220" }
        [PSCustomObject]@{ Name = "OpenDNS (Family Shield)";             Primary = "208.67.222.123";   Secondary = "208.67.220.123" }
        [PSCustomObject]@{ Name = "CleanBrowsing (Family Filter)";       Primary = "185.228.168.168"; Secondary = "185.228.169.168" }
        [PSCustomObject]@{ Name = "DHCP / Automatic (Reset to ISP)";     Primary = "DHCP";            Secondary = "DHCP" }
    )

    Write-Host "`n   Select a predefined DNS Provider:" -ForegroundColor Cyan
    for ($k = 0; $k -lt $dnsList.Count; $k++) {
        $ipDisplay = if ($dnsList[$k].Primary -eq "DHCP") { "Automatic via Gateway" } else { "$($dnsList[$k].Primary), $($dnsList[$k].Secondary)" }
        Write-Host "     [$k] $($dnsList[$k].Name) ($ipDisplay)" -ForegroundColor White
    }
    Write-Host "     [C] Custom DNS Entry" -ForegroundColor Magenta
    Write-Host "     [X] Cancel" -ForegroundColor DarkGray

    $choice = Read-Host "`n   Option"

    if ($choice -match '^(x|cancel)$') {
        Write-Host "   [INFO] Operation canceled." -ForegroundColor Yellow
        Pause-Script
        return
    }

    try {
        if ($choice -match '^(c|custom)$') {
            $pDns = Read-Host "   Enter Primary DNS IPv4"
            if (-not (Test-IsUnicastIPv4 $pDns)) {
                Write-Host "   [X] Invalid Primary DNS address." -ForegroundColor Red
                Pause-Script; return
            }

            $sDns = Read-Host "   Enter Secondary DNS IPv4 (Optional, press Enter to skip)"
            $customServers = @($pDns)
            if (-not [string]::IsNullOrWhiteSpace($sDns)) {
                if (Test-IsUnicastIPv4 $sDns) {
                    $customServers += $sDns
                } else {
                    Write-Host "   [!] Warning: Secondary DNS address was invalid; using Primary only." -ForegroundColor Yellow
                }
            }

            Write-Host "   [INFO] Applying custom DNS servers..." -ForegroundColor Yellow
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $customServers -ErrorAction Stop
            Write-Host "   [OK] Custom DNS successfully applied: $($customServers -join ', ')" -ForegroundColor Green
        }
        elseif ($choice -match '^\d+$' -and [int]$choice -ge 0 -and [int]$choice -lt $dnsList.Count) {
            $selected = $dnsList[[int]$choice]
            Write-Host "   [INFO] Configuring '$($selected.Name)'..." -ForegroundColor Yellow

            if ($selected.Primary -eq "DHCP") {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
                Write-Host "   [OK] DNS reset to DHCP (Automatic)." -ForegroundColor Green
            } else {
                [string[]]$targetServers = @($selected.Primary, $selected.Secondary)
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $targetServers -ErrorAction Stop
                Write-Host "   [OK] DNS successfully assigned to: $($selected.Name)" -ForegroundColor Green
            }
        }
        else {
            Write-Host "   [!] Invalid choice. Aborted." -ForegroundColor Yellow
            Pause-Script; return
        }

        # Flush cache to immediately activate changes
        Write-Host "   [INFO] Flushing local DNS resolver cache..." -ForegroundColor DarkCyan
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    } catch {
        Write-Host "   [X] Configuration failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    Pause-Script
}

function Set-IpConfiguration {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "         CONFIGURE IP ADDRESS             " -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan

    $adapter = Select-NetworkAdapter
    if (-not $adapter) { Pause-Script; return }
    $idx = $adapter.ifIndex

    Write-Host "`n   [TARGET] Selected Interface: $($adapter.Name)" -ForegroundColor Green
    Write-Host "   [1] Enable DHCP (Automatic IP & Default Gateway)"
    Write-Host "   [2] Configure Static IPv4 Address"
    Write-Host "   [0] Cancel"
    
    $mode = Read-Host "`n   Select mode (0-2)"

    switch ($mode) {
        "1" {
            # --- DHCP CONFIGURATION ---
            try {
                Write-Host "   [INFO] Enabling DHCP on interface..." -ForegroundColor Yellow
                
                # Enable DHCP on interface protocol
                Set-NetIPInterface -InterfaceIndex $idx -Dhcp Enabled -AddressFamily IPv4 -ErrorAction Stop

                # Remove legacy static IP and Routes if lingering
                Remove-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
                Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
                    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

                $resetDnsPrompt = Read-Host "   Reset DNS to Automatic (DHCP) as well? (Y/N) [Default: Y]"
                if ([string]::IsNullOrWhiteSpace($resetDnsPrompt) -or $resetDnsPrompt -match '^y(es)?$') {
                    Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -ErrorAction SilentlyContinue
                    Write-Host "   [OK] DNS reset to DHCP." -ForegroundColor Green
                }

                # Trigger immediate DHCP lease solicitation
                Write-Host "   [INFO] Requesting DHCP lease renewal from server..." -ForegroundColor DarkCyan
                Start-Process -FilePath "ipconfig.exe" -ArgumentList "/renew `"$($adapter.Name)`"" -NoNewWindow -Wait -ErrorAction SilentlyContinue

                Write-Host "   [OK] Interface successfully switched to DHCP." -ForegroundColor Green
            } catch {
                Write-Host "   [X] Failed to enable DHCP: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "2" {
            # --- STATIC IP CONFIGURATION ---
            Write-Host "`n   --- STATIC IPv4 CONFIGURATION ---" -ForegroundColor Magenta
            
            # Step 1: Input & Validate Static IP
            $inputIp = Read-Host "   Enter desired IP Address (e.g., 192.168.1.150)"
            if (-not (Test-IsUnicastIPv4 $inputIp)) {
                Write-Host "   [X] Error: '$inputIp' is not a valid routable unicast IPv4 address." -ForegroundColor Red
                Pause-Script; return
            }

            # Step 2: Auto-compute Intelligent Gateway and Subnet defaults
            $octets = $inputIp.Split('.')
            $suggestedGw = "$($octets[0]).$($octets[1]).$($octets[2]).1"
            
            Write-Host "`n   [SUGGESTION] Recommended Defaults:" -ForegroundColor DarkCyan
            Write-Host "       Subnet Mask : 255.255.255.0 (/24)" -ForegroundColor Gray
            Write-Host "       Gateway     : $suggestedGw" -ForegroundColor Gray

            $useDefaults = Read-Host "`n   Use these defaults? (Y/N) [Default: Y]"
            
            if ($useDefaults -match '^n(o)?$') {
                $rawMask = Read-Host "   Enter Subnet Mask or CIDR Prefix (e.g., 255.255.255.0 or 24)"
                $prefixLength = Convert-SubnetMaskToPrefix $rawMask
                $gateway = Read-Host "   Enter Default Gateway IP"
            } else {
                $prefixLength = 24
                $gateway = $suggestedGw
            }

            # Validate Gateway
            if (-not (Test-IsUnicastIPv4 $gateway)) {
                Write-Host "   [X] Error: '$gateway' is not a valid Gateway address." -ForegroundColor Red
                Pause-Script; return
            }

            try {
                Write-Host "`n   [INFO] Applying static network parameters..." -ForegroundColor Yellow

                # Disable DHCP
                Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled -AddressFamily IPv4 -ErrorAction Stop

                # Clear previous IPs to avoid multi-homing conflicts
                Remove-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue

                # Clear existing default routes on this interface
                Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

                # Assign New IP, Prefix, and Default Gateway atomically
                New-NetIPAddress -InterfaceIndex $idx `
                                 -IPAddress $inputIp `
                                 -PrefixLength $prefixLength `
                                 -DefaultGateway $gateway `
                                 -AddressFamily IPv4 `
                                 -ErrorAction Stop | Out-Null

                Write-Host "   [OK] Static IP applied: $inputIp/$prefixLength | GW: $gateway" -ForegroundColor Green
            } catch {
                Write-Host "   [X] Error applying configuration: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        Default {
            Write-Host "   [INFO] Action canceled." -ForegroundColor Yellow
        }
    }

    Pause-Script
}

function Start-DnsLookupInteractive {
    <#
    .SYNOPSIS
        Provides a DNS resolution console using native PowerShell cmdlets with fallback to nslookup.
    #>
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "       DNS RESOLUTION & NSLOOKUP          " -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   Enter domain/hostname (e.g., cloudflare.com)." -ForegroundColor White
    Write-Host "   Type 'exit' to return to menu.`n" -ForegroundColor DarkGray

    do {
        $query = Read-Host "   Resolve Query >"
        if ([string]::IsNullOrWhiteSpace($query)) { continue }
        if ($query -match '^(exit|quit|q)$') { break }

        Write-Host "   " + ("-" * 45) -ForegroundColor DarkGray
        try {
            if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
                $records = Resolve-DnsName -Name $query -ErrorAction Stop
                foreach ($r in $records) {
                    $type = $r.Type
                    $data = switch ($type) {
                        "A"     { $r.IPAddress }
                        "AAAA"  { $r.IPAddress }
                        "CNAME" { $r.NameHost }
                        "MX"    { "$($r.NameExchange) (Priority: $($r.Preference))" }
                        "TXT"   { $r.Strings -join ' ' }
                        Default { $r.ToString() }
                    }
                    Write-Host "   [$type] $($r.Name) -> $data" -ForegroundColor Green
                }
            } else {
                # Fallback to direct nslookup executable execution without spawning cmd.exe shell
                & nslookup.exe $query
            }
        } catch {
            Write-Host "   [X] Resolution failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host "   " + ("-" * 45) -ForegroundColor DarkGray
        Write-Host ""
    } while ($true)
}

function Test-ConnectivitySuite {
    <#
    .SYNOPSIS
        Performs end-to-end diagnostic ping tests: Local Gateway, WAN IP, and Public DNS.
    #>
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "       NETWORK DIAGNOSTICS & PING         " -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan

    $adapter = Get-PrimaryNetworkAdapter
    if (-not $adapter) {
        Write-Host "   [X] No active adapter to test." -ForegroundColor Red
        Pause-Script; return
    }

    Write-Host "   Interface: $($adapter.Name)`n" -ForegroundColor DarkCyan

    # Test 1: Default Gateway Ping
    $gwRoute = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gwRoute -and $gwRoute.NextHop -ne '0.0.0.0') {
        $gw = $gwRoute.NextHop
        Write-Host "   [1/3] Testing Local Gateway Reachability ($gw)..." -NoNewline
        $gwPing = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($gwPing) { Write-Host " [PASS]" -ForegroundColor Green } else { Write-Host " [FAIL]" -ForegroundColor Red }
    } else {
        Write-Host "   [1/3] Local Gateway: Not configured (Skipped)." -ForegroundColor Yellow
    }

    # Test 2: WAN IP Ping (Cloudflare Anycast IP 1.1.1.1)
    Write-Host "   [2/3] Testing Internet Routing (Ping 1.1.1.1)..." -NoNewline
    $wanPing = Test-Connection -ComputerName 1.1.1.1 -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($wanPing) { Write-Host " [PASS]" -ForegroundColor Green } else { Write-Host " [FAIL]" -ForegroundColor Red }

    # Test 3: Public DNS Resolution Test
    Write-Host "   [3/3] Testing DNS Resolution (one.one.one.one)..." -NoNewline
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses("one.one.one.one")
        if ($resolved) { Write-Host " [PASS]" -ForegroundColor Green } else { Write-Host " [FAIL]" -ForegroundColor Red }
    } catch {
        Write-Host " [FAIL]" -ForegroundColor Red
    }

    Pause-Script
}

function Restart-TargetAdapter {
    <#
    .SYNOPSIS
        Performs a clean hardware/software soft-restart of the network adapter.
    #>
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "        RESTART NETWORK ADAPTER           " -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan

    $adapter = Select-NetworkAdapter
    if (-not $adapter) { Pause-Script; return }

    $confirm = Read-Host "`n   Restart adapter '$($adapter.Name)'? Active network traffic will briefly drop. (Y/N)"
    if ($confirm -match '^y(es)?$') {
        try {
            Write-Host "   [INFO] Disabling adapter..." -ForegroundColor Yellow
            Restart-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop
            Write-Host "   [OK] Adapter restarted successfully." -ForegroundColor Green
        } catch {
            Write-Host "   [X] Failed to restart adapter: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "   [INFO] Aborted." -ForegroundColor Gray
    }
    Pause-Script
}

function Reset-NetworkStack {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "         RESET NETWORK STACK              " -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   [!] This procedure resets Winsock, TCP/IP stack, ARP, and DNS cache." -ForegroundColor Yellow
    Write-Host "   [!] It will restore network components to clean installation defaults." -ForegroundColor Yellow
    Write-Host "   [!] A SYSTEM REBOOT IS REQUIRED to finalize." -ForegroundColor Red
    
    $confirm = Read-Host "`n   Do you wish to proceed with stack wipe? (Y/N)"
    if ($confirm -match '^y(es)?$') {
        try {
            Write-Host "`n   [1/5] Resetting Winsock catalog..." -ForegroundColor DarkCyan
            & netsh winsock reset | Out-Null

            Write-Host "   [2/5] Resetting TCP/IP protocol stack..." -ForegroundColor DarkCyan
            & netsh int ip reset | Out-Null

            Write-Host "   [3/5] Flushing DNS client cache..." -ForegroundColor DarkCyan
            Clear-DnsClientCache -ErrorAction SilentlyContinue

            Write-Host "   [4/5] Clearing ARP / Neighbor cache..." -ForegroundColor DarkCyan
            Remove-NetNeighbor -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue

            Write-Host "   [5/5] Re-registering DNS with network..." -ForegroundColor DarkCyan
            & ipconfig.exe /registerdns | Out-Null
            
            Write-Host "`n   [OK] Network stack wipe completed successfully." -ForegroundColor Green
            Write-Host "   [CRITICAL] SYSTEM REBOOT IS REQUIRED." -ForegroundColor Red

            $reboot = Read-Host "`n   Reboot computer now? (Y/N) [Default: N]"
            if ($reboot -match '^y(es)?$') {
                Write-Host "   [INFO] Restarting system in 5 seconds..." -ForegroundColor Red
                Restart-Computer -Force
                exit
            }
        } catch {
            Write-Host "   [X] Error during stack reset: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "   [INFO] Operation canceled." -ForegroundColor Gray
    }
    Pause-Script
}

# ---------------------------------------------------------------------------
# MAIN INTERACTION LOOP
# ---------------------------------------------------------------------------

do {
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "            ENTERPRISE NETWORK UTILITY TOOL               " -ForegroundColor White
    Write-Host "==========================================================" -ForegroundColor Cyan
    
    # Render primary adapter real-time telemetry
    Get-NetworkStatusUI

    Write-Host ""
    Write-Host "   CONFIGURATION & ACTIONS" -ForegroundColor Gray
    Write-Host "   -------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "   [1] Configure DNS Servers (Preset Profiles / Custom)" -ForegroundColor White
    Write-Host "   [2] Configure IPv4 Address (Static / DHCP)" -ForegroundColor White
    Write-Host "   [3] Test Connectivity & Diagnostics (Ping Suite)" -ForegroundColor White
    Write-Host "   [4] DNS Name Resolution (Interactive NSLookup)" -ForegroundColor White
    Write-Host "   [5] Soft-Restart Network Adapter" -ForegroundColor White
    Write-Host "   [6] Reset Complete Network Stack (Winsock / IP Reset)" -ForegroundColor Yellow
    Write-Host "   [0] Exit" -ForegroundColor DarkGray
    Write-Host ""

    $selection = Read-Host "   Select an action [0-6]"

    switch ($selection) {
        "1" { Set-DnsServers }
        "2" { Set-IpConfiguration }
        "3" { Test-ConnectivitySuite }
        "4" { Start-DnsLookupInteractive }
        "5" { Restart-TargetAdapter }
        "6" { Reset-NetworkStack }
        "0" { 
            Write-Host "   Closing session..." -ForegroundColor Gray
            Start-Sleep -Milliseconds 600
            Clear-Host
            exit 
        }
        Default { 
            Write-Host "   [!] Invalid selection." -ForegroundColor Red
            Start-Sleep -Milliseconds 800
        }
    }
} while ($true)