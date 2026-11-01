# ==============================================================================
# SCRIPT:        Brave Browser Tweaker & Debloater
# COMPATIBILITY: Windows 10 / Windows 11
# CODING STANDARD: All internal comments and UI strings must be written in ENGLISH.
# ==============================================================================

$ErrorActionPreference = "Continue"

# Console configuration
$Host.UI.RawUI.WindowTitle = "Brave Browser Tweaker & Debloater"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

$regPath = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
$procName = "brave"

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

# Ensure root policy key exists if elevated
if (Test-IsAdministrator) {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
}

function Close-BraveProcesses {
    $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host "`n   [*] Closing active Brave processes..." -ForegroundColor Yellow
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Write-Host "   [OK] Brave closed successfully." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# POLICY HELPERS
# ---------------------------------------------------------------------------
function Get-PolicyState ([string]$valueName, [string]$logicType) {
    if (-not (Test-Path $regPath)) { return "[ENABLED ]" }
    $prop = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction SilentlyContinue
    if ($null -eq $prop -or $null -eq $prop.$valueName) {
        return "[ENABLED ]"
    }

    $val = [int]$prop.$valueName
    if ($logicType -eq "DisableKey") {
        if ($val -eq 1) { return "[DISABLED]" } else { return "[ENABLED ]" }
    } else {
        if ($val -eq 0) { return "[DISABLED]" } else { return "[ENABLED ]" }
    }
}

function Toggle-BraveFeature ([string]$valueName, [string]$logicType) {
    Close-BraveProcesses
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    $prop = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction SilentlyContinue
    $currentVal = if ($prop) { $prop.$valueName } else { $null }

    if ($logicType -eq "DisableKey") {
        if ($currentVal -eq 1) {
            Remove-ItemProperty -Path $regPath -Name $valueName -Force -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty -Path $regPath -Name $valueName -Value 1 -Type DWord -Force
        }
    } else {
        if ($currentVal -eq 0) {
            Remove-ItemProperty -Path $regPath -Name $valueName -Force -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty -Path $regPath -Name $valueName -Value 0 -Type DWord -Force
        }
    }
    Write-Host "`n   [OK] Policy updated successfully." -ForegroundColor Green
}

function Toggle-Telemetry {
    Close-BraveProcesses
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    $prop = Get-ItemProperty -Path $regPath -Name "MetricsReportingEnabled" -ErrorAction SilentlyContinue
    if ($prop -and $prop.MetricsReportingEnabled -eq 0) {
        Remove-ItemProperty -Path $regPath -Name "MetricsReportingEnabled" -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $regPath -Name "BraveP3AEnabled" -Force -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -Path $regPath -Name "MetricsReportingEnabled" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name "BraveP3AEnabled" -Value 0 -Type DWord -Force
    }
    Write-Host "`n   [OK] Telemetry policies updated successfully." -ForegroundColor Green
}

function Invoke-CleanBraveCache {
    Close-BraveProcesses
    Write-Host "`n   ==================================================================" -ForegroundColor Cyan
    Write-Host "                 BRAVE MULTI-PROFILE CACHE & DNS CLEANER             " -ForegroundColor Yellow
    Write-Host "   ==================================================================" -ForegroundColor Cyan

    $userData = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    if (-not (Test-Path $userData)) {
        Write-Host "   [X] User Data directory not found." -ForegroundColor Red
        Pause-Script
        return
    }

    $targets = @('Cache','Code Cache','GPUCache','DawnGraphiteCache','DawnWebGPUCache','Service Worker','ShaderCache')
    $paths = New-Object System.Collections.Generic.List[string]

    foreach ($g in @('ShaderCache','GrShaderCache')) {
        $gp = Join-Path $userData $g
        if (Test-Path $gp) { $paths.Add($gp) }
    }

    Get-ChildItem $userData -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile*' } |
        ForEach-Object {
            $prof = $_
            foreach ($item in $targets) {
                $sp = Join-Path $prof.FullName $item
                if (Test-Path $sp) { $paths.Add($sp) }
            }
        }

    [long]$freedBytes = 0
    foreach ($p in $paths) {
        $shortName = $p.Replace($userData, 'User Data')
        try {
            $files = [System.IO.Directory]::EnumerateFiles($p, '*', [System.IO.SearchOption]::AllDirectories)
            foreach ($f in $files) {
                try { $freedBytes += (New-Object System.IO.FileInfo($f)).Length } catch {}
            }
            [System.IO.Directory]::Delete($p, $true)
            [void][System.IO.Directory]::CreateDirectory($p)
            Write-Host "   [CLEANED] $shortName" -ForegroundColor Green
        } catch {
            try {
                Remove-Item "$p\*" -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "   [PARTIAL] $shortName" -ForegroundColor Yellow
            } catch {
                Write-Host "   [LOCKED ] $shortName" -ForegroundColor DarkGray
            }
        }
    }

    $freedStr = if ($freedBytes -ge 1GB) { '{0:N2} GB' -f ($freedBytes / 1GB) }
                elseif ($freedBytes -ge 1MB) { '{0:N2} MB' -f ($freedBytes / 1MB) }
                elseif ($freedBytes -gt 0) { '{0:N2} KB' -f ($freedBytes / 1KB) }
                else { '0.00 MB (Already clean)' }

    Write-Host "`n   [NETWORK] Flushing system DNS Resolver Cache..." -ForegroundColor Cyan
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Write-Host "   [SUCCESS] Cleaning complete! Space freed: $freedStr" -ForegroundColor Green
    Pause-Script
}

function Set-AllPolicies ([string]$mode) {
    Close-BraveProcesses
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

    if ($mode -eq "Debloat") {
        Write-Host "`n   [*] Applying all Debloat policies..." -ForegroundColor Yellow
        Set-ItemProperty -Path $regPath -Name "BraveRewardsDisabled"    -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name "BraveWalletDisabled"     -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name "BraveVPNDisabled"        -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name "TorDisabled"             -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name "BraveNewsDisabled"       -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name "BraveAIChatEnabled"      -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name "BackgroundModeEnabled"   -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name "MetricsReportingEnabled" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name "BraveP3AEnabled"         -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $regPath -Name "IPFSEnabled"             -Value 0 -Type DWord -Force
        Write-Host "   [OK] All Debloat policies successfully applied." -ForegroundColor Green
    } else {
        Write-Host "`n   [*] Restoring default browser settings..." -ForegroundColor Magenta
        $toRemove = @("BraveRewardsDisabled","BraveWalletDisabled","BraveVPNDisabled","TorDisabled","BraveNewsDisabled","BraveAIChatEnabled","BackgroundModeEnabled","MetricsReportingEnabled","BraveP3AEnabled","IPFSEnabled")
        foreach ($prop in $toRemove) {
            Remove-ItemProperty -Path $regPath -Name $prop -Force -ErrorAction SilentlyContinue
        }
        Write-Host "   [OK] All policies removed. Default browser behavior restored." -ForegroundColor Green
    }
    Pause-Script
}

# ---------------------------------------------------------------------------
# MAIN MENU LOOP
# ---------------------------------------------------------------------------
do {
    Clear-Host
    $isAdmin = Test-IsAdministrator

    $s1 = Get-PolicyState "BraveRewardsDisabled"    "DisableKey"
    $s2 = Get-PolicyState "BraveWalletDisabled"     "DisableKey"
    $s3 = Get-PolicyState "BraveVPNDisabled"        "DisableKey"
    $s4 = Get-PolicyState "BraveAIChatEnabled"      "EnableKey"
    $s5 = Get-PolicyState "TorDisabled"             "DisableKey"
    $s6 = Get-PolicyState "BackgroundModeEnabled"   "EnableKey"
    $s7 = Get-PolicyState "MetricsReportingEnabled" "EnableKey"
    $s8 = Get-PolicyState "IPFSEnabled"             "EnableKey"
    $s9 = Get-PolicyState "BraveNewsDisabled"       "DisableKey"

    Write-Host "  ==================================================================" -ForegroundColor Cyan
    Write-Host "                 BRAVE BROWSER TWEAKER & DEBLOATER                  " -ForegroundColor White
    Write-Host "             Enterprise GPO & Registry Control Utility              " -ForegroundColor DarkGray
    Write-Host "  ==================================================================" -ForegroundColor Cyan
    if ($isAdmin) {
        Write-Host "   Privilege Level : Administrator (Full Access)`n" -ForegroundColor Green
    } else {
        Write-Host "   Privilege Level : Standard User (Read-Only - Run CMD as Admin)`n" -ForegroundColor Yellow
    }

    function Render-State ([string]$state) {
        if ($state -eq "[DISABLED]") {
            Write-Host $state -ForegroundColor Green
        } else {
            Write-Host $state -ForegroundColor Red
        }
    }

    Write-Host "   FEATURE TOGGLES" -ForegroundColor Yellow
    Write-Host "   --------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "   [1] Rewards & BAT Ads          : " -NoNewline; Render-State $s1
    Write-Host "   [2] Crypto Wallet (Web3)       : " -NoNewline; Render-State $s2
    Write-Host "   [3] Brave VPN & Prompts        : " -NoNewline; Render-State $s3
    Write-Host "   [4] Leo AI Chat & Assistant    : " -NoNewline; Render-State $s4
    Write-Host "   [5] Tor Private Windows        : " -NoNewline; Render-State $s5
    Write-Host "   [6] Background App Execution   : " -NoNewline; Render-State $s6
    Write-Host "   [7] Telemetry & P3A Analytics  : " -NoNewline; Render-State $s7
    Write-Host "   [8] IPFS Protocol Support      : " -NoNewline; Render-State $s8
    Write-Host "   [9] Brave News Feed            : " -NoNewline; Render-State $s9
    Write-Host ""
    Write-Host "   MAINTENANCE & ACTIONS" -ForegroundColor Yellow
    Write-Host "   --------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "   [C] Clean Multi-Profile Cache & Flush DNS" -ForegroundColor Yellow
    Write-Host "   [D] Debloat All (Maximum Privacy & Minimalism)" -ForegroundColor Cyan
    Write-Host "   [R] Restore All (Revert All Policies to Defaults)" -ForegroundColor Magenta
    Write-Host "   [0] Exit" -ForegroundColor DarkGray
    Write-Host "   --------------------------------------------------------------" -ForegroundColor DarkGray

    $choice = (Read-Host "`n   Select an option").Trim().ToUpper()

    if ($choice -match '^(0|X|EXIT|QUIT)$') {
        Clear-Host
        exit 0
    }

    if ($choice -eq "C") {
        Invoke-CleanBraveCache
        continue
    }

    if (-not $isAdmin) {
        Write-Host "`n   [!] Administrator privileges required to modify Brave policies in HKLM." -ForegroundColor Red
        Write-Host "   [i] Please close CMD and launch it via 'Run as administrator'." -ForegroundColor Yellow
        Pause-Script
        continue
    }

    switch ($choice) {
        "1" { Toggle-BraveFeature "BraveRewardsDisabled"    "DisableKey"; Start-Sleep -Milliseconds 600 }
        "2" { Toggle-BraveFeature "BraveWalletDisabled"     "DisableKey"; Start-Sleep -Milliseconds 600 }
        "3" { Toggle-BraveFeature "BraveVPNDisabled"        "DisableKey"; Start-Sleep -Milliseconds 600 }
        "4" { Toggle-BraveFeature "BraveAIChatEnabled"      "EnableKey";  Start-Sleep -Milliseconds 600 }
        "5" { Toggle-BraveFeature "TorDisabled"             "DisableKey"; Start-Sleep -Milliseconds 600 }
        "6" { Toggle-BraveFeature "BackgroundModeEnabled"   "EnableKey";  Start-Sleep -Milliseconds 600 }
        "7" { Toggle-Telemetry;                                           Start-Sleep -Milliseconds 600 }
        "8" { Toggle-BraveFeature "IPFSEnabled"             "EnableKey";  Start-Sleep -Milliseconds 600 }
        "9" { Toggle-BraveFeature "BraveNewsDisabled"       "DisableKey"; Start-Sleep -Milliseconds 600 }
        "D" { Set-AllPolicies "Debloat" }
        "R" { Set-AllPolicies "Restore" }
        Default {
            Write-Host "   [!] Invalid selection." -ForegroundColor Red
            Start-Sleep -Milliseconds 600
        }
    }
} while ($true)