# REQUIRES: Administrator Privileges
# COMPATIBILITY: PowerShell 5.1+ / Windows 11 IoT LTSC
# CODING STANDARD: All internal comments must be written in ENGLISH.

<#
    Windows Tweaks & Optimization Tool
    Updated: 2026-07-10
    Description: General toolbox for UI, Context Menus, Apps, and CPU performance tweaks.
#>

# ---------------------------------------------------------------------------
# INITIALIZATION & SETUP
# ---------------------------------------------------------------------------

#region Setup, Encoding & Auto-Elevation
# --- 1. GLOBAL SETTINGS ---
$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# --- 2. ADMIN SELF-ELEVATION ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "`n [!] Administrator privileges required." -ForegroundColor Yellow
    Write-Host " [!] Restarting as Administrator..." -ForegroundColor White
    
    # Securely resolve current script path
    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Definition }

    try {
        # Using an array for ArgumentList is safer against spaces in paths
        $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"")
        if ($PSScriptRoot) {
            Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -WorkingDirectory $PSScriptRoot
        } else {
            Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
        }
        Exit
    } catch {
        Write-Host " [X] Elevation failed or cancelled by user." -ForegroundColor Red
        Exit
    }
}
#endregion

# ---------------------------------------------------------------------------
# HELPERS: STATUS CHECKS
# ---------------------------------------------------------------------------

function Get-WindowsVersion {
    # Fetch official OS name from WMI/CIM first (correctly resolves Win 11 vs Win 10 branding)
    $Caption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    if ($Caption) {
        $ProductName = $Caption -replace '^Microsoft\s+', ''
    } else {
        # Fallback to registry if CIM fails
        $ProductName = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).ProductName
    }
    
    $CurrentBuild = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).CurrentBuild
    $buildNum = 0
    [void][int]::TryParse($CurrentBuild, [ref]$buildNum)
    
    # Correct Windows 10 vs 11 branding mismatches in registry/WMI for newer builds (Build 22000+)
    if ($ProductName -match "Windows 10" -and $buildNum -ge 22000) {
        $ProductName = $ProductName -replace "Windows 10", "Windows 11"
    }

    $DisplayVersion = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).DisplayVersion
    if (-not $DisplayVersion) {
        $DisplayVersion = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).ReleaseId
    }
    if (-not $DisplayVersion) { $DisplayVersion = "N/A" }

    $UBR = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).UBR
    $buildString = if ($UBR) { "$CurrentBuild.$UBR" } else { "$CurrentBuild" }
    
    if (-not $ProductName) {
        return "Unknown Windows Version"
    }
    return "$ProductName ($DisplayVersion - Build $buildString)"
}

function Get-LicenseStatus {
    $status = "NOT ACTIVATED / UNKNOWN"
    $color = "DarkGray"
    $key = "N/A"
    $type = "Unknown"
    
    try {
        $license = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "Name like 'Windows%' and PartialProductKey is not null" -ErrorAction SilentlyContinue
        if ($license) {
            $licObj = $license | Select-Object -First 1
            $partialKey = $licObj.PartialProductKey
            
            # Determine Activation Status
            switch ($licObj.LicenseStatus) {
                1 { $status = "ACTIVATED"; $color = "Green" }
                2 { $status = "GRACE PERIOD (OOB)"; $color = "Yellow" }
                3 { $status = "GRACE PERIOD (OOT)"; $color = "Yellow" }
                4 { $status = "NON-GENUINE GRACE"; $color = "Red" }
                5 { $status = "NOTIFICATION"; $color = "Red" }
                6 { $status = "EXTENDED GRACE"; $color = "Yellow" }
                Default { $status = "UNLICENSED"; $color = "Red" }
            }
            
            # Determine License Channel/Type
            $channel = $licObj.ProductKeyChannel
            if (-not $channel) {
                $desc = $licObj.Description
                if ($desc -match "VOLUME_KMSCLIENT|KMS") { $channel = "Volume (KMS)" }
                elseif ($desc -match "VOLUME_MAK|MAK") { $channel = "Volume (MAK)" }
                elseif ($desc -match "OEM") { $channel = "OEM" }
                elseif ($desc -match "RETAIL") { $channel = "Retail" }
                else { $channel = "Unknown Channel" }
            }
            
            if ($channel -match "Retail") { $type = "Retail" }
            elseif ($channel -match "OEM") { $type = "OEM" }
            elseif ($channel -match "KMS|VOLUME_KMS") { $type = "Volume (KMS)" }
            elseif ($channel -match "MAK|VOLUME_MAK") { $type = "Volume (MAK)" }
            else { $type = $channel }

            # Retrieve Backup registry Product Key if available
            $fullKey = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform" -Name "BackupProductKeyDefault" -ErrorAction SilentlyContinue).BackupProductKeyDefault
            
            # Retrieve Bios embedded Product Key (OEM Key)
            $oemKey = (Get-CimInstance SoftwareLicensingService -ErrorAction SilentlyContinue).OA3xOriginalProductKey
            
            if ($fullKey -and $fullKey -ne "BBBBB-BBBBB-BBBBB-BBBBB-BBBBB") {
                $key = $fullKey
            } elseif ($oemKey) {
                $key = "$oemKey (BIOS)"
            } elseif ($partialKey) {
                $key = "Partial Key: $partialKey"
            }
        }
    } catch {}
    
    return @{ 
        Status = $status
        Color = $color
        Key = $key
        Type = $type
    }
}

function Get-UpdateStatus {
    $service = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
    $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $regValue = $null
    
    try {
        $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU")
        if ($regKey) {
            $regValue = $regKey.GetValue("NoAutoUpdate")
            $regKey.Close()
        }
    } catch {}

    if ($regValue -eq $null) {
        $regValue = (Get-ItemProperty -Path $regPath -Name "NoAutoUpdate" -ErrorAction SilentlyContinue).NoAutoUpdate
    }
    
    if (($service -and $service.StartType -eq "Disabled") -or $regValue -eq 1) {
        return @{ Text="DISABLED"; Color="Red" }
    }
    return @{ Text="ACTIVE   "; Color="Green" }
}

function Get-RegistryStatus {
    param ([string]$Path, [string]$Name, [int]$TargetValue)
    $current = $null
    
    # Performance Optimization: Use rapid .NET registry query first
    try {
        if ($Path -match '^HKCU:\\(.*)$') {
            $subPath = $Matches[1]
            $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subPath)
            if ($regKey) {
                $current = $regKey.GetValue($Name)
                $regKey.Close()
            }
        } elseif ($Path -match '^HKLM:\\(.*)$') {
            $subPath = $Matches[1]
            $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($subPath)
            if ($regKey) {
                $current = $regKey.GetValue($Name)
                $regKey.Close()
            }
        }
    } catch {}

    # Fallback to standard PowerShell cmdlet if .NET is restricted
    if ($current -eq $null) {
        $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    }
    
    if ($current -eq $null) { $current = 0 }

    if ($current -eq $TargetValue) {
        return @{ Text="ENABLED "; Color="Green" }
    } else {
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
    if ($ExePath -and (Test-Path $ExePath -ErrorAction SilentlyContinue)) { return @{ Text="INSTALLED"; Color="Green" } }
    foreach ($appName in $AppCache.Keys) {
        if ($appName -like $SearchPattern) { return @{ Text="INSTALLED"; Color="Green" } }
    }
    return @{ Text="MISSING  "; Color="DarkGray" }
}

function Get-DefenderStatus {
    $current = $null
    try {
        $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows Defender\Real-Time Protection")
        if ($regKey) {
            $current = $regKey.GetValue("DisableRealtimeMonitoring")
            $regKey.Close()
        }
    } catch {}
    
    if ($current -eq $null) {
        $current = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableRealtimeMonitoring" -ErrorAction SilentlyContinue).DisableRealtimeMonitoring
    }
    
    # Secondary check: verification of the actual background service
    $service = Get-Service -Name "WinDefend" -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne "Running") {
        return @{ Text="DISABLED "; Color="Red" }
    }

    if ($current -eq 1) { 
        return @{ Text="DISABLED "; Color="Red" } 
    } 
    return @{ Text="ACTIVE   "; Color="Green" }
}

function Get-MitigationStatus {
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    $val = $null
    try {
        $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management")
        if ($regKey) {
            $val = $regKey.GetValue("FeatureSettingsOverride")
            $regKey.Close()
        }
    } catch {}
    
    if ($val -eq $null) {
        $val = (Get-ItemProperty -Path $path -Name "FeatureSettingsOverride" -ErrorAction SilentlyContinue).FeatureSettingsOverride
    }
    
    # 3 = Mitigations OFF (Fastest but vulnerable)
    # 0 / null = Mitigations ON (Secure but slower)
    if ($val -eq 3) { return @{ Text="DISABLED (FAST)  "; Color="Yellow" } } 
    else { return @{ Text="ACTIVE (SECURE)  "; Color="Green" } }
}

function Get-ComponentStatus {
    param ([string]$Name)
    switch ($Name) {
        "WinGet" {
            if (Get-Command "winget" -ErrorAction SilentlyContinue) { return @{ Text="INSTALLED"; Color="Green" } }
            return @{ Text="MISSING  "; Color="Red" }
        }
        "Store" {
            if (Get-AppxPackage -Name "Microsoft.WindowsStore" -ErrorAction SilentlyContinue) { return @{ Text="INSTALLED"; Color="Green" } }
            return @{ Text="MISSING  "; Color="Red" }
        }
        "DirectX" {
            if (Test-Path "$env:SystemRoot\System32\d3dx9_43.dll" -ErrorAction SilentlyContinue) { return @{ Text="INSTALLED"; Color="Green" } }
            return @{ Text="MISSING  "; Color="DarkGray" }
        }
    }
}

# ---------------------------------------------------------------------------
# HELPERS: ACTIONS & TOGGLES
# ---------------------------------------------------------------------------

function Toggle-Updates {
    $status = Get-UpdateStatus
    $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    
    if ($status.Text -match "ACTIVE") {
        Write-Host "   [-] Disabling Windows Updates..." -ForegroundColor Yellow
        
        # Stop and Disable Windows Update Services
        Set-Service -Name "wuauserv" -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name "wuauserv" -Force -ErrorAction SilentlyContinue
        
        # Set Group Policies via Registry to block updates permanently
        if (-not (Test-Path $regPath)) { $null = New-Item -Path $regPath -Force -ErrorAction SilentlyContinue }
        Set-ItemProperty -Path $regPath -Name "NoAutoUpdate" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        
        # Prevent delivery optimization bypass from forcing downloads
        $optPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
        if (-not (Test-Path $optPath)) { $null = New-Item -Path $optPath -Force -ErrorAction SilentlyContinue }
        Set-ItemProperty -Path $optPath -Name "DODownloadMode" -Value 100 -Type DWord -Force -ErrorAction SilentlyContinue
        
        Write-Host "   [OK] Windows Updates disabled." -ForegroundColor Yellow
    } else {
        Write-Host "   [+] Enabling Windows Updates..." -ForegroundColor Green
        
        # Enable and Start Windows Update Services
        Set-Service -Name "wuauserv" -StartupType Manual -ErrorAction SilentlyContinue
        Start-Service -Name "wuauserv" -ErrorAction SilentlyContinue
        
        # Clear update block registry policies
        if (Test-Path $regPath) {
            Remove-ItemProperty -Path $regPath -Name "NoAutoUpdate" -Force -ErrorAction SilentlyContinue
        }
        $optPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
        if (Test-Path $optPath) {
            Remove-ItemProperty -Path $optPath -Name "DODownloadMode" -Force -ErrorAction SilentlyContinue
        }
        
        Write-Host "   [OK] Windows Updates enabled (Manual)." -ForegroundColor Green
    }
    Start-Sleep 2
}

function Toggle-Registry {
    param ([string]$Path, [string]$Name, [int]$OnValue, [int]$OffValue, [string]$Desc)
    if (-not (Test-Path $Path)) { $null = New-Item -Path $Path -Force -ErrorAction SilentlyContinue }
    $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($current -eq $null) { $current = $OffValue }

    if ($current -eq $OnValue) {
        Set-ItemProperty -Path $Path -Name $Name -Value $OffValue -Type DWord -Force | Out-Null
        Write-Host "   [-] $Desc set to DISABLED/OFF." -ForegroundColor Yellow
    } else {
        Set-ItemProperty -Path $Path -Name $Name -Value $OnValue -Type DWord -Force | Out-Null
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
        "ClassicMenu" {
            $path = "Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"
            if (Test-Path $path) { 
                Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "   [-] Reverted to Windows 11 Default Menu." -ForegroundColor Yellow 
            } else { 
                $null = New-Item "$path\InprocServer32" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty "$path\InprocServer32" -Name "(default)" -Value "" -Force -ErrorAction SilentlyContinue
                Write-Host "   [+] Classic Context Menu enabled." -ForegroundColor Green 
            }
            Toggle-ExplorerRestart
        }
        "TakeOwnership" {
            $path = "Registry::HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership"
            if (Test-Path $path) {
                Remove-Item "Registry::HKEY_CLASSES_ROOT\*\shell\TakeOwnership" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item "Registry::HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership" -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "   [-] Take Ownership Extension removed." -ForegroundColor Yellow
            } else {
                $p1 = "Registry::HKEY_CLASSES_ROOT\*\shell\TakeOwnership"
                $null = New-Item $p1 -Force -ErrorAction SilentlyContinue
                Set-ItemProperty $p1 -Name "(default)" -Value "Take Ownership" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty $p1 -Name "HasLUAShield" -Value "" -Force -ErrorAction SilentlyContinue
                
                $null = New-Item "$p1\command" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty "$p1\command" -Name "(default)" -Value 'cmd.exe /c takeown /f "%1" && icacls "%1" /grant administrators:F' -Force -ErrorAction SilentlyContinue
                
                $p2 = "Registry::HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership"
                $null = New-Item $p2 -Force -ErrorAction SilentlyContinue
                Set-ItemProperty $p2 -Name "(default)" -Value "Take Ownership" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty $p2 -Name "HasLUAShield" -Value "" -Force -ErrorAction SilentlyContinue
                
                $null = New-Item "$p2\command" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty "$p2\command" -Name "(default)" -Value 'cmd.exe /c takeown /f "%1" /r /d y && icacls "%1" /grant administrators:F /t' -Force -ErrorAction SilentlyContinue
                
                Write-Host "   [+] Take Ownership Extension added." -ForegroundColor Green
            }
        }
        "PowerPlan" {
            $path = "Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan"
            if (Test-Path $path) { 
                Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "   [-] Power Options Menu removed." -ForegroundColor Yellow 
            } else {
                $null = New-Item "$path" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty "$path" -Name "MUIVerb" -Value "Choose Power Plan" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty "$path" -Name "Icon" -Value "powercpl.dll" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty "$path" -Name "Position" -Value "Middle" -Force -ErrorAction SilentlyContinue
                
                # Ordered dictionary prevents randomized menu rendering order
                $plans = [ordered]@{"01"=@("Balanced"; "381b4222-f694-41f0-9685-ff5bb260df2e"); "02"=@("High Performance"; "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")}
                foreach ($k in $plans.Keys) {
                    $sub = "$path\shell\${k}menu"
                    $null = New-Item $sub -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $sub -Name "MUIVerb" -Value $plans[$k][0] -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $sub -Name "Icon" -Value "powercpl.dll" -Force -ErrorAction SilentlyContinue
                    
                    $null = New-Item "$sub\command" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty "$sub\command" -Name "(default)" -Value "powercfg.exe /setactive $($plans[$k][1])" -Force -ErrorAction SilentlyContinue
                }
                Write-Host "   [+] Power Options Menu added." -ForegroundColor Green
            }
        }
        "RunPS1Admin" {
            $path = "Registry::HKEY_CLASSES_ROOT\Microsoft.PowerShellScript.1\Shell\runas"
            if (Test-Path $path) { 
                Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "   [-] Elevated .ps1 Execution Menu removed." -ForegroundColor Yellow 
            } else {
                $null = New-Item "$path\command" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty $path -Name "HasLUAShield" -Value "" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty "$path\command" -Name "(default)" -Value 'powershell.exe -Command "if((Get-ExecutionPolicy ) -ne ''AllSigned'') { Set-ExecutionPolicy -Scope Process Bypass }; & ''%1''"' -Force -ErrorAction SilentlyContinue
                Write-Host "   [+] Elevated .ps1 Execution Menu added." -ForegroundColor Green
            }
        }
        "PSHereAdmin" {
            $roots = @("Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\PowerShellAsAdmin", "Registry::HKEY_CLASSES_ROOT\Directory\shell\PowerShellAsAdmin", "Registry::HKEY_CLASSES_ROOT\Drive\shell\PowerShellAsAdmin")
            if (Test-Path $roots[0]) { 
                foreach ($r in $roots) { Remove-Item $r -Recurse -Force -ErrorAction SilentlyContinue }
                Write-Host "   [-] Elevated PowerShell Here Menu removed." -ForegroundColor Yellow 
            } else {
                foreach ($r in $roots) {
                    $null = New-Item "$r\command" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $r -Name "(default)" -Value "Open PowerShell here as administrator" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $r -Name "Icon" -Value "powershell.exe" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $r -Name "HasLUAShield" -Value "" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty "$r\command" -Name "(default)" -Value 'powershell.exe -WindowStyle Hidden -Command "Start-Process powershell.exe -ArgumentList ''-NoExit -NoProfile -Command Set-Location -LiteralPath \"\"%V\"\"'' -Verb RunAs"' -Force -ErrorAction SilentlyContinue
                }
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLinkedConnections" -Value 1 -Type DWord -Force | Out-Null
                Write-Host "   [+] Elevated PowerShell Here Menu added." -ForegroundColor Green
            }
        }
        "CmdHere" {
            $roots = @("Registry::HKEY_CLASSES_ROOT\DesktopBackground\shell\CommandPrompt", "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\CommandPrompt", "Registry::HKEY_CLASSES_ROOT\Directory\shell\CommandPrompt", "Registry::HKEY_CLASSES_ROOT\Drive\shell\CommandPrompt")
            if (Test-Path $roots[0]) { 
                foreach ($r in $roots) { Remove-Item $r -Recurse -Force -ErrorAction SilentlyContinue }
                Write-Host "   [-] Extended CMD Prompts Here Menu removed." -ForegroundColor Yellow 
            } else {
                foreach ($r in $roots) {
                    $null = New-Item r -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $r -Name "MUIVerb" -Value "Command Prompt" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $r -Name "Icon" -Value "cmd.exe" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $r -Name "SubCommands" -Value "" -Force -ErrorAction SilentlyContinue

                    $cmd1 = "$r\shell\cmd1"
                    $null = New-Item "$cmd1\command" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $cmd1 -Name "MUIVerb" -Value "Open here" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $cmd1 -Name "Icon" -Value "cmd.exe" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty "$cmd1\command" -Name "(default)" -Value 'cmd.exe /s /k pushd "%V"' -Force -ErrorAction SilentlyContinue

                    $cmd2 = "$r\shell\cmd2"
                    $null = New-Item "$cmd2\command" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $cmd2 -Name "MUIVerb" -Value "Open here as administrator" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $cmd2 -Name "HasLUAShield" -Value "" -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty "$cmd2\command" -Name "(default)" -Value 'powershell.exe -WindowStyle Hidden -Command "Start-Process cmd.exe -ArgumentList ''/s /k pushd \"\"%V\"\"'' -Verb RunAs"' -Force -ErrorAction SilentlyContinue
                }
                Write-Host "   [+] Extended CMD Prompts Here Menu added." -ForegroundColor Green
            }
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

function Toggle-Mitigations {
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    $val = (Get-ItemProperty -Path $path -Name "FeatureSettingsOverride" -ErrorAction SilentlyContinue).FeatureSettingsOverride
    
    # Val 3 means mitigations are disabled
    if ($val -eq 3) {
        Write-Host "   [+] Enabling Spectre/Meltdown Mitigations (Secure)..." -ForegroundColor Green
        Set-ItemProperty -Path $path -Name "FeatureSettingsOverride" -Value 0 -Type DWord -Force | Out-Null
        Set-ItemProperty -Path $path -Name "FeatureSettingsOverrideMask" -Value 3 -Type DWord -Force | Out-Null
        Write-Host "   [OK] CPU Mitigations ENABLED." -ForegroundColor Green
    } else {
        Write-Host "   [-] Disabling Spectre/Meltdown Mitigations (Fast)..." -ForegroundColor Yellow
        Set-ItemProperty -Path $path -Name "FeatureSettingsOverride" -Value 3 -Type DWord -Force | Out-Null
        Set-ItemProperty -Path $path -Name "FeatureSettingsOverrideMask" -Value 3 -Type DWord -Force | Out-Null
        Write-Host "   [OK] CPU Mitigations DISABLED. Older CPUs will perform faster." -ForegroundColor Yellow
    }
    Write-Host "   [!] A SYSTEM REBOOT IS REQUIRED to apply these changes." -ForegroundColor Cyan
    Start-Sleep 3
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
        Get-AppxPackage -AllUsers *WindowsStore* -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        Get-AppxPackage -AllUsers *StorePurchaseApp* -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        Write-Host "   [OK] Microsoft Store removed." -ForegroundColor Green
    } else {
        Write-Host "   [+] Installing Microsoft Store (LTSC Method)..." -ForegroundColor Green
        Write-Host "       Executing 'wsreset.exe -i' to download Store..." -ForegroundColor Cyan
        try {
            Start-Process "wsreset.exe" -ArgumentList "-i" -NoNewWindow
            Write-Host "   [!] Install command sent. The Store will appear in a few minutes." -ForegroundColor Yellow
            Write-Host "       Requires active Internet connection." -ForegroundColor DarkGray
        } catch {
            Write-Host "   [X] Failed to execute wsreset: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Start-Sleep 2
}

# ---------------------------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------------------------

# Cache slow-to-load System Information before starting the UI loop to prevent lag on refreshes
$cachedOSVersion = Get-WindowsVersion
$cachedLicenseInfo = Get-LicenseStatus

do {
    Clear-Host
    Write-Host "   ========================================" -ForegroundColor Cyan
    Write-Host "                 WINDOWS TOOL              " -ForegroundColor Cyan
    Write-Host "   ========================================" -ForegroundColor Cyan
    Write-Host "   OS Version   : " -NoNewline -ForegroundColor White; Write-Host $cachedOSVersion -ForegroundColor Gray
    Write-Host "   License      : " -NoNewline -ForegroundColor White; Write-Host $cachedLicenseInfo.Status -ForegroundColor $cachedLicenseInfo.Color
    Write-Host "   Lic. Channel : " -NoNewline -ForegroundColor White; Write-Host $cachedLicenseInfo.Type -ForegroundColor Gray
    Write-Host "   Product Key  : " -NoNewline -ForegroundColor White; Write-Host $cachedLicenseInfo.Key -ForegroundColor Gray
    Write-Host "   ========================================" -ForegroundColor Cyan
    Write-Host ""

    # --- PERFORMANCE OPTIMIZATION: Ultra-fast registry reading using .NET ---
    $installedAppsCache = @{}
    try {
        $uninstallPaths = @(
            "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", 
            "SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        )
        
        # Fast read Local Machine
        foreach ($subPath in $uninstallPaths) {
            $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($subPath)
            if ($regKey) {
                foreach ($subKeyName in $regKey.GetSubKeyNames()) {
                    $subKey = $regKey.OpenSubKey($subKeyName)
                    if ($subKey) {
                        $displayName = $subKey.GetValue("DisplayName")
                        if ($displayName) { $installedAppsCache[$displayName] = $true }
                        $subKey.Close()
                    }
                }
                $regKey.Close()
            }
        }
        
        # Fast read Current User
        $regKeyUser = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")
        if ($regKeyUser) {
            foreach ($subKeyName in $regKeyUser.GetSubKeyNames()) {
                $subKey = $regKeyUser.OpenSubKey($subKeyName)
                if ($subKey) {
                    $displayName = $subKey.GetValue("DisplayName")
                    if ($displayName) { $installedAppsCache[$displayName] = $true }
                    $subKey.Close()
                }
            }
            $regKeyUser.Close()
        }
    } catch {
        # Secure Fallback to slower native method if .NET access fails
        $uninstallPathsFallback = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", 
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
        )
        foreach ($path in $uninstallPathsFallback) {
            Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object { 
                $displayName = $_.GetValue("DisplayName")
                if ($displayName) { $installedAppsCache[$displayName] = $true }
            }
        }
    }

    # --- DRAW MENU ---
    Write-Host "   INTERFACE & SYSTEM SETTINGS" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    $s = Get-RegistryStatus "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAl" 0; Write-Host "   [1] Taskbar Alignment (Left)  : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-RegistryStatus "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "HideFileExt" 0; Write-Host "   [2] Show File Extensions      : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-RegistryStatus "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" "SystemUsesLightTheme" 0; Write-Host "   [3] System Dark Mode          : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-RegistryStatus "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 1; Write-Host "   [4] Taskbar Search Box        : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color

    Write-Host ""
    Write-Host "   CONTEXT MENUS" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    $s = Get-ContextStatus "Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"; Write-Host "   [5] Win11 Legacy Context Menu : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ContextStatus "Registry::HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership"; Write-Host "   [6] Take Ownership Extension  : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ContextStatus "Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\PowerPlan"; Write-Host "   [7] Power Options Context Menu: " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ContextStatus "Registry::HKEY_CLASSES_ROOT\Microsoft.PowerShellScript.1\Shell\runas"; Write-Host "   [8] Elevated .ps1 Execution   : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ContextStatus "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\PowerShellAsAdmin"; Write-Host "   [9] Elevated PowerShell Here  : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ContextStatus "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\CommandPrompt"; Write-Host "   [0] Extended CMD Prompts Here : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color

    Write-Host ""
    Write-Host "   CORE COMPONENTS & SECURITY" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    $s = Get-ComponentStatus "WinGet"; Write-Host "   [W] Install / Repair WinGet   : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ComponentStatus "Store"; Write-Host "   [S] Microsoft Store (LTSC)    : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-DefenderStatus; Write-Host "   [D] Windows Defender (RTP)    : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-MitigationStatus; Write-Host "   [M] CPU Mitigations (Spectre) : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-UpdateStatus; Write-Host "   [U] Windows Update (Updates)  : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color

    Write-Host ""
    Write-Host "   RUNTIMES & FRAMEWORKS" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    $s = Get-AppStatus "*Visual C++*Redistributable*" "" $installedAppsCache; Write-Host "   [R] VC++ Redist (2015-2022)   : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-AppStatus "*Desktop Runtime*9*" "" $installedAppsCache; Write-Host "   [N] .NET 9 Desktop Runtime    : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-ComponentStatus "DirectX"; Write-Host "   [I] DirectX                   : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color

    Write-Host ""
    Write-Host "   APP MANAGER (WinGet)" -ForegroundColor Gray
    Write-Host "   ----------------------------------------" -ForegroundColor DarkGray
    $s = Get-AppStatus "Google Chrome" "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" $installedAppsCache; Write-Host "   [A] Google Chrome             : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-AppStatus "Brave" "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe" $installedAppsCache; Write-Host "   [B] Brave Browser             : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-AppStatus "Mozilla Firefox" "$env:ProgramFiles\Mozilla Firefox\firefox.exe" $installedAppsCache; Write-Host "   [C] Mozilla Firefox           : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-AppStatus "Microsoft Edge" "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe" $installedAppsCache; Write-Host "   [E] Microsoft Edge            : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color
    $s = Get-AppStatus "LibreWolf" "$env:ProgramFiles\LibreWolf\librewolf.exe" $installedAppsCache; Write-Host "   [L] LibreWolf                 : " -NoNewline; Write-Host $s.Text -ForegroundColor $s.Color

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
        
        # CONTEXT MENUS
        "5" { Toggle-ContextMenu "ClassicMenu" }
        "6" { Toggle-ContextMenu "TakeOwnership" }
        "7" { Toggle-ContextMenu "PowerPlan" }
        "8" { Toggle-ContextMenu "RunPS1Admin" }
        "9" { Toggle-ContextMenu "PSHereAdmin" }
        "0" { Toggle-ContextMenu "CmdHere" }

        # COMPONENTS & SECURITY
        { $_ -eq "w" } { Install-Repair-Winget }
        { $_ -eq "s" } { Toggle-Store }
        { $_ -eq "d" } { Toggle-Defender }
        { $_ -eq "m" } { Toggle-Mitigations }
        { $_ -eq "u" } { Toggle-Updates }

        # RUNTIMES
        { $_ -eq "r" } { Toggle-App "VC++ Redistributable 2015-2022" "Microsoft.VCRedist.2015+.x64" }
        { $_ -eq "n" } { Toggle-App ".NET 9 Desktop Runtime" "Microsoft.DotNet.DesktopRuntime.9" }
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