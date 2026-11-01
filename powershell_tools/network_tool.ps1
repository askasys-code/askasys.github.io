# ==============================================================================
# SCRIPT:        Network Diagnostics & Configuration Tool
# COMPATIBILITY: Windows PowerShell 5.1 / PowerShell 7+ on Windows 10/11/Server
# CODING STANDARD: All internal comments and UI strings must be written in ENGLISH.
# ==============================================================================

$ErrorActionPreference = "Continue"

# Configure console title and encoding safely
$Host.UI.RawUI.WindowTitle = "Enterprise Network Utility Tool"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

# Safe TLS protocol setting
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]'Tls12'
} catch {}

# Check privilege level without closing or blocking startup
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# HELPER FUNCTIONS
# ---------------------------------------------------------------------------

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

function Convert-SubnetMaskToPrefix {
    param ([string]$InputMask)

    if ($InputMask -match '^\d+$') {
        $val = [int]$InputMask
        if ($val -ge 1 -and $val -le 32) { return $val }
    }

    $parsedMask = $null
    if ([System.Net.IPAddress]::TryParse($InputMask, [ref]$parsedMask) -and $parsedMask.AddressFamily -eq 'InterNetwork') {
        $bytes = $parsedMask.GetAddressBytes()
        $binaryString = ($bytes | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
        if ($binaryString -match '^1+0*$') {
            return ($binaryString -replace '0', '').Length
        }
    }
    return 24
}

function Test-IsUnicastIPv4 {
    param ([string]$IpAddress)

    if ([string]::IsNullOrWhiteSpace($IpAddress)) { return $false }
    if ($IpAddress -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { return $false }

    $ipObj = $null
    if (-not [System.Net.IPAddress]::TryParse($IpAddress, [ref]$ipObj) -or $ipObj.AddressFamily -ne 'InterNetwork') {
        return $false
    }

    $bytes = $ipObj.GetAddressBytes()
    if ($bytes[0] -eq 0 -or $bytes[0] -eq 127 -or $bytes[0] -ge 224) {
        return $false
    }
    return $true
}

function Get-PrimaryNetworkAdapter {
    $activeRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Sort-Object -Property RouteMetric, InterfaceMetric |
                   Select-Object -First 1

    if ($activeRoute) {
        $adapter = Get-NetAdapter -InterfaceIndex $activeRoute.InterfaceIndex -ErrorAction SilentlyContinue
        if ($adapter -and $adapter.Status -eq 'Up') {
            return $adapter
        }
    }

    $physical = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' } |
                Select-Object -First 1
    if ($physical) { return $physical }

    return (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1)
}

function Get-NetworkStatusUI {
    $isAdmin = Test-IsAdministrator
    $adapter = Get-PrimaryNetworkAdapter

    if ($adapter) {
        # DNS Servers
        $dns = "DHCP/Automatic"
        $dnsObj = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($dnsObj -and $dnsObj.ServerAddresses) {
            $dns = $dnsObj.ServerAddresses -join ", "
        }

        # IP Address
        $ipConf = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Where-Object { $_.IPAddress -notlike "169.254.*" } |
                  Select-Object -First 1

        $ipStr = if ($ipConf) { "$($ipConf.IPAddress)/$($ipConf.PrefixLength)" } else { "Unknown" }
        $dhcpStatus = if ($ipConf) { if ($ipConf.PrefixOrigin -eq "Dhcp") { " (DHCP)" } else { " (Static)" } } else { "" }

        # Default Gateway
        $gwRoute = Get-NetRoute -InterfaceIndex $adapter.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
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

    # Privilege banner
    if ($isAdmin) {
        Write-Host "   Privilege Level : Administrator (Full Access)" -ForegroundColor Green
    } else {
        Write-Host "   Privilege Level : Standard User (Read-Only - Run CMD as Admin to modify)" -ForegroundColor Yellow
    }
}

function Select-NetworkAdapter {
    Write-Host "   [INFO] Scanning operational network interfaces..." -ForegroundColor Yellow
    
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | 
                  Where-Object { $_.Status -eq "Up" } | 
                  Sort-Object -Property Physical, Name -Descending)

    if ($adapters.Count -eq 0) {
        Write-Host "   [X] No operational (UP) adapters found." -ForegroundColor Red
        return $null
    }

    if ($adapters.Count -eq 1) {
        Write-Host "   [OK] Targeted active adapter: $($adapters[0].Name)" -ForegroundColor Green
        return $adapters[0]
    }

    Write-Host "`n   Multiple active adapters detected. Choose target interface:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $adapters.Count; $i++) {
        $nicType = if ($adapters[$i].Physical) { "Physical" } else { "Virtual" }
        Write-Host "     [$($i + 1)] $($adapters[$i].Name) | Type: $nicType | Descr: $($adapters[$i].InterfaceDescription)" -ForegroundColor White
    }
    Write-Host "     [0] Cancel" -ForegroundColor DarkGray

    do {
        $selection = Read-Host "`n   Select Adapter (1-$($adapters.Count) or 0 to Cancel)"
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

    if (-not (Test-IsAdministrator)) {
        Write-Host "`n   [!] Administrator privileges required to change DNS servers." -ForegroundColor Red
        Write-Host "   [i] Please close CMD and launch it via 'Run as administrator'." -ForegroundColor Yellow
        Pause-Script
        return
    }

    $adapter = Select-NetworkAdapter
    if (-not $adapter) { Pause-Script; return }

    Write-Host "`n   [TARGET] Selected Interface: $($adapter.Name)" -ForegroundColor Green

    $dnsList = @(
        [PSCustomObject]@{ Name = "Google Public DNS";                    Primary = "8.8.8.8";         Secondary = "8.8.4.4" }
        [PSCustomObject]@{ Name = "Cloudflare (Standard)";                Primary = "1.1.1.1";         Secondary = "1.0.0.1" }
        [PSCustomObject]@{ Name = "Cloudflare (Malware Protection)";      Primary = "1.1.1.2";         Secondary = "1.0.0.2" }
        [PSCustomObject]@{ Name = "Cloudflare (Family / Adult Blocking)"; Primary = "1.1.1.3";         Secondary = "1.0.0.3" }
        [PSCustomObject]@{ Name = "Quad9 (Standard Malware Filter)";      Primary = "9.9.9.9";         Secondary = "149.112.112.112" }
        [PSCustomObject]@{ Name = "Quad9 (Unsecured / No Filter)";        Primary = "9.9.9.10";        Secondary = "149.112.112.10" }
        [PSCustomObject]@{ Name = "Quad9 (ECS Support)";                  Primary = "9.9.9.11";        Secondary = "149.112.112.11" }
        [PSCustomObject]@{ Name = "AdGuard (Default - Ads/Trackers)";     Primary = "94.140.14.14";     Secondary = "94.140.15.15" }
        [PSCustomObject]@{ Name = "OpenDNS (Standard)";                   Primary = "208.67.222.222";   Secondary = "208.67.220.220" }
        [PSCustomObject]@{ Name = "DHCP / Automatic (Reset to ISP)";      Primary = "DHCP";             Secondary = "DHCP" }
    )

    Write-Host "`n   Select a predefined DNS Provider:" -ForegroundColor Cyan
    for ($k = 0; $k -lt $dnsList.Count; $k++) {
        $ipDisplay = if ($dnsList[$k].Primary -eq "DHCP") { "Automatic via Gateway" } else { "$($dnsList[$k].Primary), $($dnsList[$k].Secondary)" }
        Write-Host "     [$($k + 1)] $($dnsList[$k].Name) ($ipDisplay)" -ForegroundColor White
    }
    Write-Host "     [C] Custom DNS Entry" -ForegroundColor Magenta
    Write-Host "     [0] Cancel" -ForegroundColor DarkGray

    $choice = Read-Host "`n   Option"

    if ($choice -match '^(0|x|cancel)$') {
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
                    Write-Host "   [!] Secondary DNS was invalid; using Primary only." -ForegroundColor Yellow
                }
            }

            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $customServers -ErrorAction Stop
            Write-Host "   [OK] Custom DNS successfully applied: $($customServers -join ', ')" -ForegroundColor Green
        }
        elseif ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $dnsList.Count) {
            $selected = $dnsList[[int]$choice - 1]
            if ($selected.Primary -eq "DHCP") {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                Write-Host "   [OK] DNS reset to DHCP (Automatic)." -ForegroundColor Green
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses @($selected.Primary, $selected.Secondary) -ErrorAction Stop
                Write-Host "   [OK] DNS successfully assigned to: $($selected.Name)" -ForegroundColor Green
            }
        } else {
            Write-Host "   [!] Invalid selection." -ForegroundColor Yellow
            Pause-Script; return
        }

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

    if (-not (Test-IsAdministrator)) {
        Write-Host "`n   [!] Administrator privileges required to change IP configuration." -ForegroundColor Red
        Write-Host "   [i] Please close CMD and launch it via 'Run as administrator'." -ForegroundColor Yellow
        Pause-Script
        return
    }

    $adapter = Select-NetworkAdapter
    if (-not $adapter) { Pause-Script; return }
    $idx = $adapter.InterfaceIndex

    Write-Host "`n   [TARGET] Selected Interface: $($adapter.Name)" -ForegroundColor Green
    Write-Host "   [1] Enable DHCP (Automatic IP & Gateway)"
    Write-Host "   [2] Configure Static IPv4 Address"
    Write-Host "   [0] Cancel"
    
    $mode = Read-Host "`n   Select mode (0-2)"

    switch ($mode) {
        "1" {
            try {
                Write-Host "   [INFO] Enabling DHCP on interface..." -ForegroundColor Yellow
                Set-NetIPInterface -InterfaceIndex $idx -Dhcp Enabled -AddressFamily IPv4 -ErrorAction Stop
                
                Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.PrefixOrigin -eq 'Manual' } |
                    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

                Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
                    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

                $resetDns = Read-Host "   Reset DNS to Automatic (DHCP) as well? (Y/N) [Default: Y]"
                if ([string]::IsNullOrWhiteSpace($resetDns) -or $resetDns -match '^y(es)?$') {
                    Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -ErrorAction SilentlyContinue
                    Write-Host "   [OK] DNS reset to DHCP." -ForegroundColor Green
                }

                Start-Process -FilePath "ipconfig.exe" -ArgumentList "/renew `"$($adapter.Name)`"" -NoNewWindow -Wait -ErrorAction SilentlyContinue
                Write-Host "   [OK] Interface successfully switched to DHCP." -ForegroundColor Green
            } catch {
                Write-Host "   [X] Failed to enable DHCP: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "2" {
            Write-Host "`n   --- STATIC IPv4 CONFIGURATION ---" -ForegroundColor Magenta
            $inputIp = Read-Host "   Enter desired IP Address (e.g., 192.168.1.150)"
            if (-not (Test-IsUnicastIPv4 $inputIp)) {
                Write-Host "   [X] Error: '$inputIp' is not a valid IPv4 address." -ForegroundColor Red
                Pause-Script; return
            }

            $octets = $inputIp.Split('.')
            $suggestedGw = "$($octets[0]).$($octets[1]).$($octets[2]).1"
            
            Write-Host "`n   [SUGGESTION] Recommended Defaults:" -ForegroundColor DarkCyan
            Write-Host "       Subnet Mask : 255.255.255.0 (/24)" -ForegroundColor Gray
            Write-Host "       Gateway     : $suggestedGw" -ForegroundColor Gray

            $useDefaults = Read-Host "`n   Use these defaults? (Y/N) [Default: Y]"
            if ($useDefaults -match '^n(o)?$') {
                $rawMask = Read-Host "   Enter Subnet Mask or CIDR Prefix"
                $prefixLength = Convert-SubnetMaskToPrefix $rawMask
                $gateway = Read-Host "   Enter Default Gateway IP"
            } else {
                $prefixLength = 24
                $gateway = $suggestedGw
            }

            if (-not (Test-IsUnicastIPv4 $gateway)) {
                Write-Host "   [X] Error: '$gateway' is not a valid Gateway address." -ForegroundColor Red
                Pause-Script; return
            }

            try {
                Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled -AddressFamily IPv4 -ErrorAction Stop

                Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

                Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

                New-NetIPAddress -InterfaceIndex $idx -IPAddress $inputIp -PrefixLength $prefixLength -DefaultGateway $gateway -AddressFamily IPv4 -ErrorAction Stop | Out-Null
                Write-Host "   [OK] Static IP applied: $inputIp/$prefixLength | GW: $gateway" -ForegroundColor Green
            } catch {
                Write-Host "   [X] Error: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    Pause-Script
}

function Test-ConnectivitySuite {
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

    # Test 1: Gateway Ping
    $gwRoute = Get-NetRoute -InterfaceIndex $adapter.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gwRoute -and $gwRoute.NextHop -ne '0.0.0.0') {
        $gw = $gwRoute.NextHop
        Write-Host "   [1/3] Testing Gateway ($gw)..." -NoNewline
        $gwPing = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($gwPing) { Write-Host " [PASS]" -ForegroundColor Green } else { Write-Host " [FAIL]" -ForegroundColor Red }
    } else {
        Write-Host "   [1/3] Gateway: [SKIPPED] Not configured." -ForegroundColor Yellow
    }

    # Test 2: Internet Ping
    Write-Host "   [2/3] Testing Internet Routing (Ping 1.1.1.1)..." -NoNewline
    $wanPing = Test-Connection -ComputerName 1.1.1.1 -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($wanPing) { Write-Host " [PASS]" -ForegroundColor Green } else { Write-Host " [FAIL]" -ForegroundColor Red }

    # Test 3: DNS Resolution
    Write-Host "   [3/3] Testing DNS Resolution (one.one.one.one)..." -NoNewline
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses("one.one.one.one")
        if ($resolved) { Write-Host " [PASS]" -ForegroundColor Green } else { Write-Host " [FAIL]" -ForegroundColor Red }
    } catch {
        Write-Host " [FAIL]" -ForegroundColor Red
    }

    Pause-Script
}

function Start-DnsLookupInteractive {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "       DNS RESOLUTION & NSLOOKUP          " -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   Enter domain/hostname (type 'exit' to return).`n" -ForegroundColor DarkGray

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
                & nslookup.exe $query
            }
        } catch {
            Write-Host "   [X] Resolution failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host "   " + ("-" * 45) -ForegroundColor DarkGray
        Write-Host ""
    } while ($true)
}

function Restart-TargetAdapter {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "        RESTART NETWORK ADAPTER           " -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan

    if (-not (Test-IsAdministrator)) {
        Write-Host "`n   [!] Administrator privileges required to restart adapter." -ForegroundColor Red
        Write-Host "   [i] Please close CMD and launch it via 'Run as administrator'." -ForegroundColor Yellow
        Pause-Script
        return
    }

    $adapter = Select-NetworkAdapter
    if (-not $adapter) { Pause-Script; return }

    $confirm = Read-Host "`n   Restart adapter '$($adapter.Name)'? Active network traffic will briefly drop. (Y/N)"
    if ($confirm -match '^y(es)?$') {
        try {
            Restart-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop
            Write-Host "   [OK] Adapter restarted successfully." -ForegroundColor Green
        } catch {
            try {
                Disable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                Enable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "   [OK] Adapter restarted successfully (via cycle fallback)." -ForegroundColor Green
            } catch {
                Write-Host "   [X] Failed to restart adapter: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    Pause-Script
}

function Reset-NetworkStack {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "         RESET NETWORK STACK              " -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Cyan

    if (-not (Test-IsAdministrator)) {
        Write-Host "`n   [!] Administrator privileges required to reset network stack." -ForegroundColor Red
        Write-Host "   [i] Please close CMD and launch it via 'Run as administrator'." -ForegroundColor Yellow
        Pause-Script
        return
    }

    $confirm = Read-Host "`n   Reset Winsock, TCP/IP stack and ARP? (Y/N)"
    if ($confirm -match '^y(es)?$') {
        try {
            & netsh winsock reset | Out-Null
            & netsh int ip reset | Out-Null
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            Remove-NetNeighbor -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            & ipconfig.exe /registerdns | Out-Null
            Write-Host "`n   [OK] Network stack wipe completed. System reboot recommended." -ForegroundColor Green
        } catch {
            Write-Host "   [X] Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Pause-Script
}

# ---------------------------------------------------------------------------
# MAIN MENU LOOP (Always launches immediately in the same console)
# ---------------------------------------------------------------------------
do {
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "            ENTERPRISE NETWORK UTILITY TOOL               " -ForegroundColor White
    Write-Host "==========================================================" -ForegroundColor Cyan
    
    Get-NetworkStatusUI

    Write-Host ""
    Write-Host "   ACTIONS" -ForegroundColor Gray
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
            Write-Host "   Exiting..." -ForegroundColor Gray
            Start-Sleep -Milliseconds 250
            Clear-Host
            exit 
        }
        Default { 
            Write-Host "   [!] Invalid selection." -ForegroundColor Red
            Start-Sleep -Milliseconds 500
        }
    }
} while ($true)