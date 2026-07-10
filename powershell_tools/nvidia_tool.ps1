# REQUIRES: Administrator Privileges
# COMPATIBILITY: PowerShell 5.1+
# CODING STANDARD: All internal comments must be written in ENGLISH.

# ---------------------------------------------------------------------------
# INITIALIZATION & SETUP
# ---------------------------------------------------------------------------

#region Setup, Encoding & Auto-Elevation
# --- 1. GLOBAL SETTINGS ---
# We avoid global SilentlyContinue as it hides critical script errors. 
# Instead, we handle issues gracefully using local ErrorActions or Try/Catch.
$ErrorActionPreference = "Continue"

# Set Console Title
$Host.UI.RawUI.WindowTitle = "NVIDIA Optimization & Diagnostic Tool"

# Set Console Encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Enable modern security protocols (TLS 1.2 & 1.3)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# --- 2. ADMIN SELF-ELEVATION ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "`n [!] Administrator privileges required." -ForegroundColor Yellow
    Write-Host " [!] Restarting as Administrator..." -ForegroundColor White
    
    $scriptPath = $MyInvocation.MyCommand.Definition
    $workingDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $scriptPath }

    try {
        # Restart the process as Admin, maintaining the current working directory
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs -WorkingDirectory $workingDir
        Exit
    } catch {
        # If the user clicks "No" on the UAC prompt
        Write-Host " [X] Elevation failed or cancelled by user." -ForegroundColor Red
        Exit
    }
}
#endregion

# --- 3. COMPILE NATIVE DISPLAY CONFIGURATION HELPER FOR BIT-DEPTH EXTRACTION ---
if (-not ([System.Management.Automation.PSTypeName]"HdrDetector").Type) {
    $hdrSource = @"
    using System;
    using System.Runtime.InteropServices;

    public class HdrDetector {
        [DllImport("user32.dll")]
        public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

        [DllImport("user32.dll")]
        public static extern int QueryDisplayConfig(uint flags, ref uint numPathArrayElements, [In, Out] DISPLAYCONFIG_PATH_INFO[] pathArray, ref uint numModeInfoArrayElements, [In, Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray, IntPtr topologyId);

        [DllImport("user32.dll")]
        public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO request);

        public const uint QDC_ONLY_ACTIVE_PATHS = 2;

        [StructLayout(LayoutKind.Sequential)]
        public struct LUID {
            public uint LowPart;
            public int HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_DEVICE_INFO_HEADER {
            public uint type;
            public uint size;
            public LUID adapterId;
            public uint id;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO {
            public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            public uint value;
            public int colorEncoding;
            public uint bitsPerColorChannel;

            public bool advancedColorSupported {
                get { return (value & 1) != 0; }
            }
            public bool advancedColorEnabled {
                get { return (value & 2) != 0; }
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_PATH_SOURCE_INFO {
            public LUID adapterId;
            public uint id;
            public uint modeInfoIdx;
            public uint statusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_PATH_TARGET_INFO {
            public LUID adapterId;
            public uint id;
            public uint modeInfoIdx;
            public uint outputTechnology;
            public uint rotation;
            public uint scaling;
            public DISPLAYCONFIG_RATIONAL refreshRate;
            public uint scanLineOrdering;
            public bool targetAvailable;
            public uint statusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_RATIONAL {
            public uint Numerator;
            public uint Denominator;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_PATH_INFO {
            public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
            public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
            public uint flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_MODE_INFO {
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)]
            public byte[] dummy;
        }

        public class DisplayColorDetails {
            public bool HdrEnabled;
            public uint BitsPerChannel;
        }

        public static DisplayColorDetails GetColorDetails() {
            DisplayColorDetails details = new DisplayColorDetails();
            details.HdrEnabled = false;
            details.BitsPerChannel = 8;
            try {
                uint pathCount, modeCount;
                int err = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount);
                if (err == 0) {
                    DISPLAYCONFIG_PATH_INFO[] paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
                    DISPLAYCONFIG_MODE_INFO[] modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
                    err = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
                    if (err == 0) {
                        foreach (var path in paths) {
                            var colorInfo = new DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO();
                            colorInfo.header.type = 9; // DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO
                            colorInfo.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO));
                            colorInfo.header.adapterId = path.targetInfo.adapterId;
                            colorInfo.header.id = path.targetInfo.id;

                            err = DisplayConfigGetDeviceInfo(ref colorInfo);
                            if (err == 0) {
                                details.HdrEnabled = colorInfo.advancedColorEnabled;
                                if (colorInfo.bitsPerColorChannel > 0) {
                                    details.BitsPerChannel = colorInfo.bitsPerColorChannel;
                                }
                                break;
                            }
                        }
                    }
                }
            } catch {}
            return details;
        }
    }
"@
    try {
        Add-Type -TypeDefinition $hdrSource -ErrorAction SilentlyContinue
    } catch {}
}

# ---------------------------------------------------------------------------
# CORE HELPER FUNCTIONS (DEFINED BEFORE EXECUTION CODES)
# ---------------------------------------------------------------------------

function Get-NvidiaSmi {
    $path = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    if ($path) { return $path.Source }
    
    # Common installation paths for nvidia-smi
    $defaultPaths = @(
        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
        "C:\Windows\System32\nvidia-smi.exe"
    )
    foreach ($p in $defaultPaths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-InstalledDriverInfo {
    param($SmiPath)
    
    # Fallback to CIM if nvidia-smi is not found or fails
    if (-not $SmiPath) {
        try {
            $gpu = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -like "*NVIDIA*" } | Select-Object -First 1
            if ($gpu) {
                # Format driver version to matching NVIDIA style (e.g. 31.0.15.5123 -> 551.23)
                $rawVersion = $gpu.DriverVersion
                $formattedVersion = $rawVersion
                if ($rawVersion -match '(\d)\.(\d)(\d)(\d)(\d)$') {
                    $formattedVersion = "$($Matches[1])$($Matches[2])$($Matches[3]).$($Matches[4])$($Matches[5])"
                }
                $vram = 0
                if ($gpu.AdapterRAM) { $vram = [math]::Round($gpu.AdapterRAM / 1MB, 0) }
                return @{ 
                    Name    = $gpu.Name
                    Version = $formattedVersion
                    VRAM    = $vram
                }
            }
        } catch {}
        return @{ Name="NVIDIA Device (No SMI)"; Version="0.00"; VRAM="0" }
    }

    try {
        $data = & $SmiPath --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits
        if ($data -is [array]) { $data = $data[0] }
        $parts = $data -split ',\s*'
        return @{ Name=$parts[0]; Version=$parts[1]; VRAM=$parts[2] }
    } catch {
        return @{ Name="Unknown Device"; Version="0.00"; VRAM="0" }
    }
}

function Get-LatestDriverFromTPU {
    Write-Host "Checking TechPowerUp for latest drivers..." -ForegroundColor DarkGray
    $url = "https://www.techpowerup.com/download/nvidia-geforce-graphics-drivers/"
    try {
        $req = Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -TimeoutSec 5 -ErrorAction Stop
        if ($req.Content -match 'NVIDIA GeForce Graphics Drivers\s+(\d{3}\.\d{2})') { return $matches[1] }
        return "Unknown"
    } catch { return "Connection Error" }
}

function Get-HagsStatus {
    # HwSchMode: 2 = On, 1 = Off
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    $name = "HwSchMode"
    try {
        $val = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
        if ($val -eq 2) { return $true }
    } catch {}
    return $false
}

function Get-VrrStatus {
    # VRR is stored in a string value within UserGpuPreferences in HKCU.
    $path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    $name = "DirectXUserGlobalSettings"
    try {
        $val = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
        if ($null -ne $val -and $val -match "VRROptimizeEnable=1") {
            return $true
        }
    } catch {}
    return $false
}

function Get-TelemetryStatus {
    $tasks = @("NvTmMon", "NvTmRep", "NvTmRepOnLogon", "NvProfileUpdaterOnLogon")
    $scheduledTasks = Get-ScheduledTask -TaskName $tasks -ErrorAction SilentlyContinue
    if ($scheduledTasks) {
        $anyEnabled = $scheduledTasks | Where-Object { $_.State -ne "Disabled" }
        if ($anyEnabled) { return $true }
    }
    return $false
}

function Get-DlssIndicatorStatus {
    $path = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore"
    $name = "ShowDlssIndicator"
    try {
        $val = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
        # 1024 decimal is 0x400 hex
        if ($val -eq 1024) { return $true }
    } catch {}
    return $false
}

function Get-DisplayStats {
    $resolution = "Unknown"
    $colorDepth = "8-bit"
    $displayMode = "SDR"

    try {
        # 1. Fetch Resolution and Refresh Rate
        $gpu = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
        if ($gpu) {
            $w = $gpu.CurrentHorizontalResolution
            $h = $gpu.CurrentVerticalResolution
            $r = $gpu.CurrentRefreshRate
            
            # Correct refresh rate rounding (e.g. 59 Hz / 59.94 Hz -> 60 Hz)
            if ($r -gt 0) {
                if ($r -eq 59 -or $r -eq 59.94) { $r = 60 }
                elseif ($r -eq 143 -or $r -eq 143.8) { $r = 144 }
                elseif ($r -eq 119 -or $r -eq 119.8) { $r = 120 }
                elseif ($r -eq 239) { $r = 240 }
                else { $r = [math]::Round($r) }
            }
            $resolution = "$w x $h @ $r Hz"
        } else {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            $primary = [System.Windows.Forms.Screen]::PrimaryScreen
            if ($primary) {
                $w = $primary.Bounds.Width
                $h = $primary.Bounds.Height
                $resolution = "$w x $h @ 60 Hz"
            }
        }
    } catch {}

    # 2. Get Realtime HDR Status (Highly Robust & Decoupled from ACM / 10-bit SDR)
    $hdrEnabled = $false
    
    # Check A: WMI Display Parameters (Standard on Win 10 1903+)
    try {
        $wmiHdr = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorDisplayParams -ErrorAction SilentlyContinue
        if ($wmiHdr) {
            $activeHdr = $wmiHdr | Where-Object { $_.Active } | Select-Object -ExpandProperty HdrEnabled -First 1
            if ($null -ne $activeHdr) {
                $hdrEnabled = $activeHdr
            } else {
                $hdrEnabled = $wmiHdr.HdrEnabled -contains $true
            }
        }
    } catch {}

    # Check B: Fallback to Graphic Drivers Active MonitorDataStore configuration
    if (-not $hdrEnabled) {
        try {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore"
            if (Test-Path $regPath) {
                $keys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
                foreach ($k in $keys) {
                    $hdrVal = (Get-ItemProperty -Path $k.PSPath -Name "HDREnabled" -ErrorAction SilentlyContinue).HDREnabled
                    if ($hdrVal -eq 1) {
                        $hdrEnabled = $true
                        break
                    }
                }
            }
        } catch {}
    }

    # 3. Get Color Depth (Bit depth)
    $bpc = 8
    try {
        if ([System.Management.Automation.PSTypeName]"HdrDetector") {
            $details = [HdrDetector]::GetColorDetails()
            $bpc = $details.BitsPerChannel
        }
    } catch {}

    if ($hdrEnabled) {
        $displayMode = "HDR"
    } else {
        $displayMode = "SDR"
    }
    
    $colorDepth = "$bpc-bit"

    return @{
        Resolution  = $resolution
        ColorDepth  = $colorDepth
        DisplayMode = $displayMode
    }
}

function Get-RebarStatus {
    param($SmiPath)
    
    # Check BAR1 size via nvidia-smi if available
    if ($SmiPath -and (Test-Path $SmiPath)) {
        try {
            $smiQuery = & $SmiPath -q -d MEMORY 2>$null
            $match = $smiQuery | Out-String | Select-String -Pattern 'BAR1 Memory Usage\s+Total\s+:\s+(\d+)\s+MiB'
            if ($match -and $match.Matches.Groups[1].Value) {
                $barSize = [int]$match.Matches.Groups[1].Value
                if ($barSize -gt 512) {
                    return "SUPPORTED (UEFI)"
                }
            }
        } catch {}
    }
    
    # Fallback: Query Large Memory Range in device PnP allocations (indicate Resizable BAR)
    try {
        $addresses = Get-CimInstance Win32_DeviceMemoryAddress -ErrorAction SilentlyContinue
        foreach ($addr in $addresses) {
            $size = $addr.EndingAddress - $addr.StartingAddress
            if ($size -ge 1073741824) { # 1 GB or larger range
                return "SUPPORTED (UEFI)"
            }
        }
    } catch {}

    return "NOT SUPPORTED / DISABLED"
}

function Get-NvidiaAppScansStatus {
    $file1 = "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\NvBackend\ApplicationStorage.json"
    $file2 = "$env:LOCALAPPDATA\NVIDIA Corporation\NvBackend\JournalBS.main.xml"
    $file3 = "$env:LOCALAPPDATA\NvBackend\JournalBS.main.xml"
    
    $isLocked = $false
    
    foreach ($file in @($file1, $file2, $file3)) {
        if (Test-Path $file) {
            $attribs = Get-ItemProperty -Path $file -ErrorAction SilentlyContinue
            if ($attribs.Attributes -match "ReadOnly") {
                $isLocked = $true
            }
        }
    }
    
    if ($isLocked) {
        return "SAFE LOCKED (File Lock)"
    }
    return "UNLOCKED"
}

function Get-NvidiaScanPaths {
    $paths = @()
    $backendDir = "$env:LOCALAPPDATA\NVIDIA Corporation\NvBackend"
    if (-not (Test-Path $backendDir)) {
        $backendDir = "$env:LOCALAPPDATA\NVIDIA\NvBackend"
    }
    if (Test-Path $backendDir) {
        $xmlFiles = Get-ChildItem -Path $backendDir -Filter "*.xml" -ErrorAction SilentlyContinue
        foreach ($file in $xmlFiles) {
            try {
                $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    $matches = [regex]::Matches($content, '(?i)"([a-z]:\\[^"]+)"')
                    foreach ($m in $matches) {
                        $p = $m.Groups[1].Value
                        if ($p -match '^[A-Z]:\\[^\\]+' -and $p -notmatch 'NVIDIA' -and $p -notmatch 'Temp') {
                            if ($paths -notcontains $p) { $paths += $p }
                        }
                    }
                }
            } catch {}
        }
    }
    return $paths
}

# --- UNIFIED AND SAFE HOSTS CHANGER AND DETECTOR ---

function Get-HostsBlockStatus {
    param(
        [string[]]$Domains
    )
    $hostsPath = "$env:windir\System32\drivers\etc\hosts"
    if (-not (Test-Path $hostsPath)) { return $false }
    
    # Read entire file as raw string to avoid array match pitfalls
    $content = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) { return $false }

    # All target domains must be explicitly active (uncommented) to be declared BLOCKED
    foreach ($d in $Domains) {
        $escaped = [regex]::Escape($d)
        # Matches non-commented redirects only (supports optional whitespaces)
        $pattern = "(?m)^\s*(?:127\.0\.0\.1|0\.0\.0\.0)\s+$escaped\b"
        if ($content -notmatch $pattern) {
            return $false
        }
    }
    return $true
}

function Toggle-HostsDomainBlock {
    param(
        [string[]]$Domains,
        [string]$Description
    )
    $hostsPath = "$env:windir\System32\drivers\etc\hosts"
    if (-not (Test-Path $hostsPath)) {
        try { New-Item -Path $hostsPath -ItemType File -Force | Out-Null } catch {}
    }
    
    # Read as lines for safe filter/removal
    $lines = Get-Content $hostsPath -ErrorAction SilentlyContinue
    if ($null -eq $lines) { $lines = @() }

    $allBlocked = Get-HostsBlockStatus -Domains $Domains

    $newLines = @()
    if ($allBlocked) {
        # UNBLOCK: Remove any line that contains the target domains (commented or active)
        foreach ($line in $lines) {
            $match = $false
            foreach ($d in $Domains) {
                if ($line -match "\b$([regex]::Escape($d))\b") { $match = $true; break }
            }
            if (-not $match) { $newLines += $line }
        }
        try {
            $newLines | Out-File $hostsPath -Force -Encoding ascii -ErrorAction Stop
            Write-Host "`n [TOGGLE] Unblocked $Description (Removed from Hosts)." -ForegroundColor Yellow
        } catch {
            Write-Host "`n [ERROR] Failed to write to hosts file. Check permissions or antivirus." -ForegroundColor Red
        }
    } else {
        # BLOCK: Remove old commented/active entries first to prevent duplication
        foreach ($line in $lines) {
            $match = $false
            foreach ($d in $Domains) {
                if ($line -match "\b$([regex]::Escape($d))\b") { $match = $true; break }
            }
            if (-not $match) { $newLines += $line }
        }
        # Append clean active block lines
        foreach ($d in $Domains) {
            $newLines += "127.0.0.1 $d"
        }
        try {
            $newLines | Out-File $hostsPath -Force -Encoding ascii -ErrorAction Stop
            Write-Host "`n [TOGGLE] Blocked $Description (Added to Hosts)." -ForegroundColor Green
        } catch {
            Write-Host "`n [ERROR] Failed to write to hosts file. Check permissions or antivirus." -ForegroundColor Red
        }
    }
    Start-Sleep -Seconds 1.5
}

# --- SETTINGS TOGGLES ---

function Toggle-HAGS {
    # Hardware-Accelerated GPU Scheduling
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    $name = "HwSchMode"
    $status = Get-HagsStatus
    
    if (-not (Test-Path $path)) { New-Item -Path $path -ErrorAction SilentlyContinue | Out-Null }

    if ($status) {
        # Turn OFF (Value 1)
        Set-ItemProperty -Path $path -Name $name -Value 1 -PropertyType DWord -Force
        Write-Host "`n [TOGGLE] HAGS set to DISABLED. Reboot Required." -ForegroundColor Yellow
    } else {
        # Turn ON (Value 2)
        Set-ItemProperty -Path $path -Name $name -Value 2 -PropertyType DWord -Force
        Write-Host "`n [TOGGLE] HAGS set to ENABLED. Reboot Required." -ForegroundColor Green
    }
    Start-Sleep -Seconds 1.5
}

function Toggle-VRR {
    # Variable Refresh Rate (User Preference String in HKCU)
    $path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    $name = "DirectXUserGlobalSettings"
    
    if (-not (Test-Path $path)) { New-Item -Path $path -ErrorAction SilentlyContinue | Out-Null }

    $currentVal = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
    if ($null -eq $currentVal) { $currentVal = "" }
    
    $status = Get-VrrStatus

    if ($status) {
        # DISABLE: Replace =1 with =0
        if ($currentVal -match "VRROptimizeEnable=1") {
            $newVal = $currentVal -replace "VRROptimizeEnable=1", "VRROptimizeEnable=0"
            Set-ItemProperty -Path $path -Name $name -Value $newVal -Type String -Force
        } else {
            $newVal = "$currentVal;VRROptimizeEnable=0;" -replace ";;", ";"
            Set-ItemProperty -Path $path -Name $name -Value $newVal -Type String -Force
        }
        Write-Host "`n [TOGGLE] VRR set to DISABLED. Reboot Required." -ForegroundColor Yellow
    } else {
        # ENABLE: Replace =0 with =1 or Append if missing
        if ($currentVal -match "VRROptimizeEnable=0") {
            $newVal = $currentVal -replace "VRROptimizeEnable=0", "VRROptimizeEnable=1"
            Set-ItemProperty -Path $path -Name $name -Value $newVal -Type String -Force
        } elseif ($currentVal -match "VRROptimizeEnable=1") {
            Set-ItemProperty -Path $path -Name $name -Value $currentVal -Type String -Force
        } else {
            $newVal = "$currentVal;VRROptimizeEnable=1;" -replace ";;", ";"
            if ($newVal.StartsWith(";")) { $newVal = $newVal.Substring(1) }
            Set-ItemProperty -Path $path -Name $name -Value $newVal -Type String -Force
        }
        Write-Host "`n [TOGGLE] VRR set to ENABLED. Reboot Required." -ForegroundColor Green
    }
    Start-Sleep -Seconds 1.5
}

function Toggle-Telemetry {
    $tasks = @("NvTmMon", "NvTmRep", "NvTmRepOnLogon", "NvProfileUpdaterOnLogon")
    $status = Get-TelemetryStatus

    $scheduledTasks = Get-ScheduledTask -TaskName $tasks -ErrorAction SilentlyContinue
    if (-not $scheduledTasks) {
        Write-Host "`n [!] No NVIDIA Telemetry tasks found on this system." -ForegroundColor Yellow
        Start-Sleep -Seconds 1.5
        return
    }

    if ($status) {
        $scheduledTasks | Disable-ScheduledTask | Out-Null
        Write-Host "`n [TOGGLE] NVIDIA Telemetry Tasks DISABLED." -ForegroundColor Green
    } else {
        $scheduledTasks | Enable-ScheduledTask | Out-Null
        Write-Host "`n [TOGGLE] NVIDIA Telemetry Tasks ENABLED." -ForegroundColor Red
    }
    Start-Sleep -Seconds 1
}

function Toggle-DlssIndicator {
    $path = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore"
    $name = "ShowDlssIndicator"
    $status = Get-DlssIndicatorStatus

    if (-not (Test-Path $path)) { New-Item -Path $path -ErrorAction SilentlyContinue | Out-Null }

    if ($status) {
        Set-ItemProperty -Path $path -Name $name -Value 0 -Type DWord -Force
        Write-Host "`n [TOGGLE] DLSS Overlay has been DISABLED." -ForegroundColor Yellow
    } else {
        Set-ItemProperty -Path $path -Name $name -Value 1024 -Type DWord -Force
        Write-Host "`n [TOGGLE] DLSS Overlay has been ENABLED." -ForegroundColor Green
    }
    Start-Sleep -Seconds 1
}

function Disable-GameBarWriter {
    Clear-Host
    Write-Host "=== Disable Game Bar Presence Writer ===" -ForegroundColor Cyan
    Write-Host "Fixes conflicts between Xbox overlay and NVIDIA overlay." -ForegroundColor Gray
    
    try {
        # 1. Registry Policies (System Wide)
        $reg = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
        if (-not (Test-Path $reg)) { New-Item -Path $reg -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $reg -Name "AllowGameDVR" -Value 0 -Type DWord -Force
        
        # 2. Registry Policies (User Specific)
        $regUser = "HKCU:\System\GameConfigStore"
        if (-not (Test-Path $regUser)) { New-Item -Path $regUser -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $regUser -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $regUser -Name "GameDVR_FSEBehaviorMode" -Value 2 -Type DWord -Force

        # 3. Disable App Capture Components (User Specific)
        $regDVRUser = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR"
        if (-not (Test-Path $regDVRUser)) { New-Item -Path $regDVRUser -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $regDVRUser -Name "AppCaptureEnabled" -Value 0 -Type DWord -Force

        # 4. Stop Process if Running
        $proc = Get-Process "GameBarPresenceWriter" -ErrorAction SilentlyContinue
        if ($proc) { 
            Stop-Process -InputObject $proc -Force
            Write-Host "Process terminated." -ForegroundColor Green
        }
        
        Write-Host "Game Bar Writer disabled via Registry." -ForegroundColor Green
        Write-Host "Reboot recommended." -ForegroundColor Magenta
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause
}

function Clean-Caches {
    Clear-Host
    Write-Host "=== NVIDIA CACHE CLEANUP ===" -ForegroundColor Cyan
    Write-Host "You will be asked to confirm each action." -ForegroundColor Gray
    Write-Host ""
    
    $targets = @(
        @{ Path="$env:LOCALAPPDATA\NVIDIA\DXCache"; Desc="DirectX Cache" }
        @{ Path="$env:LOCALAPPDATA\NVIDIA\GLCache"; Desc="OpenGL Cache" }
        @{ Path="$env:APPDATA\NVIDIA\ComputeCache"; Desc="Compute Cache" }
        @{ Path="$env:ProgramData\NVIDIA Corporation\NV_Cache"; Desc="System Cache" }
        @{ Path="$env:ProgramData\NVIDIA Corporation\Downloader"; Desc="Installer Temp" }
        @{ Path="$env:LOCALAPPDATA\Temp\NVIDIA Corporation"; Desc="User Temp" }
    )

    foreach ($target in $targets) {
        $p = $target.Path
        
        if (Test-Path $p) {
            $files = Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue
            $count = $files.Count
            $size = ($files | Measure-Object -Property Length -Sum).Sum / 1MB
            
            if ($count -gt 0) {
                Write-Host ""
                Write-Host " Found: $($target.Desc)" -ForegroundColor Cyan
                Write-Host " Files: $count | Size: $([math]::Round($size, 2)) MB" -ForegroundColor White
                $ask = Read-Host " >> Delete these files? (y/n)"
                
                if ($ask.ToLower() -eq "y") {
                    $removedCount = 0
                    foreach ($file in $files) { 
                        try { 
                            Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                            $removedCount++ 
                        } catch {} 
                    }
                    if ($removedCount -eq $count) { 
                        Write-Host "    [SUCCESS] Cleaned." -ForegroundColor Green 
                    } else { 
                        Write-Host "    [PARTIAL] Cleaned ($removedCount/$count). Some files may be in use by the system or running apps." -ForegroundColor Yellow 
                    }
                } else {
                    Write-Host "    Skipped." -ForegroundColor DarkGray
                }
            }
        }
    }
    Write-Host "`nDone. Press any key..." -ForegroundColor Green
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Set-EcoMode {
    param($SmiPath)
    Write-Host "`n=== Eco Mode Setup (50%) ===" -ForegroundColor Cyan
    if (-not $SmiPath) {
        Write-Host "NVIDIA-SMI is required to configure power limit features." -ForegroundColor Red
        Pause
        return
    }
    try {
        $max = & $SmiPath --query-gpu=power.max_limit --format=csv,noheader,nounits
        $min = & $SmiPath --query-gpu=power.min_limit --format=csv,noheader,nounits
        if ($max -eq "[Not Supported]" -or $null -eq $max) { Write-Host "Not Supported by this GPU model." -ForegroundColor Red; Pause; return }
        $target = [math]::Round([double]$max * 0.50)
        if ($target -lt [double]$min) { $target = [double]$min; Write-Host "Adjusted to hardware min: $target W" -ForegroundColor Yellow }
        
        # Capture actual execution exit code (PowerShell does not throw exceptions on external process failures)
        & $SmiPath -pl $target
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to apply power limit. Changes may be locked on this system (common on laptop GPUs)." -ForegroundColor Red
        } else {
            Write-Host "Limit set to $target W." -ForegroundColor Green
        }
    } catch { Write-Host "Failed to query or adjust limit." -ForegroundColor Red }
    Pause
}

function Set-MaxMode {
    param($SmiPath)
    Write-Host "`n=== Max Performance Setup ===" -ForegroundColor Cyan
    if (-not $SmiPath) {
        Write-Host "NVIDIA-SMI is required to configure power limit features." -ForegroundColor Red
        Pause
        return
    }
    try {
        $max = & $SmiPath --query-gpu=power.max_limit --format=csv,noheader,nounits
        if ($max -eq "[Not Supported]") { Write-Host "Not Supported by this GPU model." -ForegroundColor Red; Pause; return }
        
        # Capture actual execution exit code (PowerShell does not throw exceptions on external process failures)
        & $SmiPath -pl $max
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to apply power limit. Changes may be locked on this system." -ForegroundColor Red
        } else {
            Write-Host "Limit restored to $max W." -ForegroundColor Green
        }
    } catch { Write-Host "Failed to query or adjust limit." -ForegroundColor Red }
    Pause
}

# --- MASTER DEBLOAT & SUB-MENU PRIVACY ACTIONS (FULLY SAFE CONFIG BLOCK WITH NO ACL MODIFICATION) ---

function Lock-NvidiaAppScansSafe {
    Write-Host "`n[SAFE LOCK] Disabling NVIDIA App/GFE Scans..." -ForegroundColor Cyan
    Write-Host "Creating empty scan databases and locking configuration file attributes safely." -ForegroundColor Gray

    # 1. Handle GFE XML SearchPaths Config File
    $gfeFiles = @(
        "$env:LOCALAPPDATA\NVIDIA Corporation\NvBackend\JournalBS.main.xml",
        "$env:LOCALAPPDATA\NVIDIA\NvBackend\JournalBS.main.xml"
    )
    foreach ($file in $gfeFiles) {
        # Force create parent directory if it does not exist yet (important on post-DDU clean installs)
        $parent = Split-Path -Parent $file
        if (-not (Test-Path $parent)) {
            try { New-Item -Path $parent -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        }

        try {
            # Strip Read-Only if it already exists
            if (Test-Path $file) {
                Set-ItemProperty -Path $file -Name Attributes -Value "Normal" -Force -ErrorAction SilentlyContinue
            }
            
            # Replace or pre-create with empty structure to discard existing/future hard drive search targets
            $xmlContent = '<?xml version="1.0" encoding="utf-8"?><Journal><SearchPaths></SearchPaths></Journal>'
            $xmlContent | Out-File -FilePath $file -Force -Encoding utf8
            
            # Set only the specific file to Read-Only (Safe - doesn't crash GFE)
            Set-ItemProperty -Path $file -Name Attributes -Value "ReadOnly" -Force
            Write-Host "   Safely cleared/pre-created and locked: $file" -ForegroundColor Green
        } catch {}
    }

    # 2. Handle New NVIDIA App JSON Scan Config File
    $appFiles = @(
        "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\NvBackend\ApplicationStorage.json",
        "$env:LOCALAPPDATA\NVIDIA\NVIDIA App\NvBackend\ApplicationStorage.json"
    )
    foreach ($file in $appFiles) {
        # Force create parent directory if it does not exist yet (important on post-DDU clean installs)
        $parent = Split-Path -Parent $file
        if (-not (Test-Path $parent)) {
            try { New-Item -Path $parent -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        }

        try {
            if (Test-Path $file) {
                Set-ItemProperty -Path $file -Name Attributes -Value "Normal" -Force -ErrorAction SilentlyContinue
                
                $jsonContent = Get-Content $file -Raw -ErrorAction SilentlyContinue
                if ($jsonContent) {
                    # Strip whitelisted search scan locations safely in JSON format
                    $modifiedJson = $jsonContent -replace '"scanLocations"\s*:\s*\[[^\]]*\]', '"scanLocations": []'
                    $modifiedJson = $modifiedJson -replace '"searchPaths"\s*:\s*\[[^\]]*\]', '"searchPaths": []'
                    $modifiedJson | Out-File -FilePath $file -Force -Encoding utf8
                } else {
                    '{}' | Out-File -FilePath $file -Force -Encoding utf8
                }
            } else {
                # Pre-create a fresh empty JSON database so it starts empty and cannot be written to
                '{}' | Out-File -FilePath $file -Force -Encoding utf8
            }
            
            # Set only the specific JSON file to Read-Only (Safe - doesn't crash NVIDIA App)
            Set-ItemProperty -Path $file -Name Attributes -Value "ReadOnly" -Force
            Write-Host "   Safely cleared/pre-created and locked: $file" -ForegroundColor Green
        } catch {}
    }

    Write-Host "`nNVIDIA App scans blocked safely without modifying directory permissions!" -ForegroundColor Green
    Start-Sleep -Seconds 1.5
}

function Unlock-NvidiaAppScans {
    Write-Host "`n[UNLOCK] Restoring configuration files to normal..." -ForegroundColor Cyan

    $filesToUnlock = @(
        "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\NvBackend\ApplicationStorage.json",
        "$env:LOCALAPPDATA\NVIDIA\NVIDIA App\NvBackend\ApplicationStorage.json",
        "$env:LOCALAPPDATA\NVIDIA Corporation\NvBackend\JournalBS.main.xml",
        "$env:LOCALAPPDATA\NVIDIA\NvBackend\JournalBS.main.xml"
    )

    foreach ($file in $filesToUnlock) {
        if (Test-Path $file) {
            try {
                Set-ItemProperty -Path $file -Name Attributes -Value "Normal" -Force
                Write-Host "   Restored file attributes (Normal): $file" -ForegroundColor Green
            } catch {
                Write-Host "   Failed to restore attributes on: $file" -ForegroundColor Yellow
            }
        }
    }
    Write-Host "`nNVIDIA App configuration files unlocked." -ForegroundColor Green
    Start-Sleep -Seconds 1.5
}

function Clear-NvidiaLibrary {
    Write-Host "`n[WIPE] Clearing existing Scanned Game Library..." -ForegroundColor Cyan
    Write-Host "This will remove all currently detected games from GFE/NVIDIA App library." -ForegroundColor Gray

    # 1. Check current lock status so we can restore it afterward
    $currentStatus = Get-NvidiaAppScansStatus
    $wasLocked = ($currentStatus -eq "SAFE LOCKED (File Lock)")

    # 2. Stop services
    $services = @("NvContainerLocalSystem", "NvContainerLS")
    foreach ($svc in $services) {
        if (Get-Service $svc -ErrorAction SilentlyContinue) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
    }
    Stop-Process -Name "nvcontainer" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    # 3. Target config files
    $gfeFiles = @(
        "$env:LOCALAPPDATA\NVIDIA Corporation\NvBackend\JournalBS.main.xml",
        "$env:LOCALAPPDATA\NVIDIA\NvBackend\JournalBS.main.xml"
    )
    $gfeToPurge = @(
        "journalBS.jour.dat", "journalBS.jour.dat.bak", "journalBS.main.xml.bak", "OpsStorage.xml"
    )
    $appFiles = @(
        "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\NvBackend\ApplicationStorage.json",
        "$env:LOCALAPPDATA\NVIDIA\NVIDIA App\NvBackend\ApplicationStorage.json"
    )

    # 4. Clean GFE (GeForce Experience) scan history and assets
    foreach ($file in $gfeFiles) {
        if (Test-Path $file) {
            try {
                Set-ItemProperty -Path $file -Name Attributes -Value "Normal" -Force -ErrorAction SilentlyContinue
                # Clear content
                $xmlContent = '<?xml version="1.0" encoding="utf-8"?><Journal><SearchPaths></SearchPaths></Journal>'
                $xmlContent | Out-File -FilePath $file -Force -Encoding utf8
                Write-Host "   Cleared GFE scan database: $file" -ForegroundColor Green
            } catch {}
        }
        # Delete helper database files in the same directory
        $parent = Split-Path -Parent $file
        if (Test-Path $parent) {
            foreach ($p in $gfeToPurge) {
                $target = Join-Path $parent $p
                if (Test-Path $target) {
                    try {
                        Set-ItemProperty -Path $target -Name Attributes -Value "Normal" -Force -ErrorAction SilentlyContinue
                        Remove-Item -Path $target -Force -ErrorAction SilentlyContinue
                    } catch {}
                }
            }
            # Clean streaming asset subdirs
            @("StreamingAssetsData", "VisualOPSData") | ForEach-Object {
                $targetDir = Join-Path $parent $_
                if (Test-Path $targetDir) {
                    try { Remove-Item -Path $targetDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
        }
    }

    # 5. Clean NVIDIA App JSON database
    foreach ($file in $appFiles) {
        if (Test-Path $file) {
            try {
                Set-ItemProperty -Path $file -Name Attributes -Value "Normal" -Force -ErrorAction SilentlyContinue
                # Write an empty JSON object to clear all games and lists
                '{}' | Out-File -FilePath $file -Force -Encoding utf8
                Write-Host "   Cleared NVIDIA App library database: $file" -ForegroundColor Green
            } catch {}
        }
    }

    # 6. Re-apply Read-Only attribute if the user had it locked
    if ($wasLocked) {
        foreach ($file in @($gfeFiles + $appFiles)) {
            if (Test-Path $file) {
                try {
                    Set-ItemProperty -Path $file -Name Attributes -Value "ReadOnly" -Force -ErrorAction SilentlyContinue
                    Write-Host "   Re-applied Privacy Lock on: $file" -ForegroundColor Gray
                } catch {}
            }
        }
    }

    # 7. Restart services
    foreach ($svc in $services) {
        if (Get-Service $svc -ErrorAction SilentlyContinue) {
            Start-Service -Name $svc -ErrorAction SilentlyContinue
        }
    }

    Write-Host "`n[SUCCESS] Current game library cleared!" -ForegroundColor Green
    Write-Host "Restart GFE/NVIDIA App to see an empty list." -ForegroundColor Magenta
    Start-Sleep -Seconds 2
}

function Restore-PrivacyDebloatDefaults {
    Write-Host "`n=== REVERTING PRIVACY & DEBLOAT TWEAKS TO DEFAULT ===" -ForegroundColor Cyan
    Write-Host "Restoring tasks, registry telemetry, hosts file blocks, and scan configurations..." -ForegroundColor Gray
    Write-Host ""

    # 1. Stop core services to release write locks
    $services = @("NvContainerLocalSystem", "NvContainerLS")
    foreach ($svc in $services) {
        if (Get-Service $svc -ErrorAction SilentlyContinue) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 1

    # 2. Unlock scan config files (Remove Read-Only)
    $filesToRestore = @(
        "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\NvBackend\ApplicationStorage.json",
        "$env:LOCALAPPDATA\NVIDIA\NVIDIA App\NvBackend\ApplicationStorage.json",
        "$env:LOCALAPPDATA\NVIDIA Corporation\NvBackend\JournalBS.main.xml",
        "$env:LOCALAPPDATA\NVIDIA\NvBackend\JournalBS.main.xml"
    )
    foreach ($file in $filesToRestore) {
        if (Test-Path $file) {
            try {
                Set-ItemProperty -Path $file -Name Attributes -Value "Normal" -Force -ErrorAction SilentlyContinue
                Write-Host "   Restored scan config file attributes on: $file" -ForegroundColor Green
            } catch {}
        }
    }

    # 3. Restore Registry Telemetry Defaults
    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry" -Name "EnableTelemetry" -Value 1 -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry" -Name "LogEnabled" -Value 1 -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" -Name "TelemetryEnabled" -Value 1 -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" -Name "CrashTrackingEnabled" -Value 1 -Force -ErrorAction SilentlyContinue
        Write-Host "   Restored Registry Telemetry keys to default (Enabled)." -ForegroundColor Green
    } catch {}

    # 4. Enable Telemetry Tasks
    $tasks = @("NvTmMon", "NvTmRep", "NvTmRepOnLogon", "NvProfileUpdaterOnLogon")
    $scheduledTasks = Get-ScheduledTask -TaskName $tasks -ErrorAction SilentlyContinue
    if ($scheduledTasks) {
        try {
            $scheduledTasks | Enable-ScheduledTask | Out-Null
            Write-Host "   Enabled Scheduled Telemetry Tasks." -ForegroundColor Green
        } catch {}
    }

    # 5. Clean NVIDIA domain blocks from Hosts file
    $hostsPath = "$env:windir\System32\drivers\etc\hosts"
    if (Test-Path $hostsPath) {
        $lines = Get-Content $hostsPath -ErrorAction SilentlyContinue
        if ($lines) {
            $nvidiaDomains = @(
                "ota.nvidia.com", "ota-downloads.nvidia.com",
                "telemetry.nvidia.com", "gfe-telemetry.nvidia.com", "events.gfe.nvidia.com",
                "accounts.nvgs.nvidia.com", "login.nvgs.nvidia.com",
                "gfwsl.geforce.com", "prod.gamestream.nvidia.com"
            )
            $cleanLines = @()
            foreach ($line in $lines) {
                $match = $false
                foreach ($d in $nvidiaDomains) {
                    if ($line -match "\b$([regex]::Escape($d))\b") { $match = $true; break }
                }
                if (-not $match) { $cleanLines += $line }
            }
            try {
                $cleanLines | Out-File $hostsPath -Force -Encoding ascii -ErrorAction Stop
                Write-Host "   Removed all NVIDIA domain blocks from Hosts file." -ForegroundColor Green
            } catch {}
        }
    }

    # 6. Restart core services
    foreach ($svc in $services) {
        if (Get-Service $svc -ErrorAction SilentlyContinue) {
            Start-Service -Name $svc -ErrorAction SilentlyContinue
        }
    }

    Write-Host "`n[SUCCESS] Reverted all script-based tweaks to defaults!" -ForegroundColor Green
    Start-Sleep -Seconds 2
}

function Show-NvidiaScanVerification {
    Clear-Host
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "       NVIDIA SCAN & PRIVACY VERIFICATION       " -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Check folder block status
    $appScansStatus = Get-NvidiaAppScansStatus
    Write-Host " Privacy Lock Status : " -NoNewline
    if ($appScansStatus -eq "SAFE LOCKED (File Lock)") {
        Write-Host "SAFE LOCKED (File Lock) - Scans Blocked!" -ForegroundColor Green
    } else {
        Write-Host "UNLOCKED - Normal scan operations allowed." -ForegroundColor Red
    }
    
    $path1 = "$env:LOCALAPPDATA\NVIDIA Corporation\NvBackend"
    $path2 = "$env:LOCALAPPDATA\NVIDIA\NvBackend"
    $targetPath = if (Test-Path $path1) { $path1 } else { $path2 }
    Write-Host " Target Folder        : " -NoNewline; Write-Host $targetPath -ForegroundColor Gray
    
    # Check permissions
    if (Test-Path $targetPath) {
        try {
            $acl = Get-Acl $targetPath
            $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.NTAccount])
            $denyCount = 0
            foreach ($rule in $rules) {
                if ($rule.AccessControlType -eq "Deny") {
                    Write-Host "   -> Found Rule: $($rule.IdentityReference) | Rights: $($rule.FileSystemRights)" -ForegroundColor Yellow
                    $denyCount++
                }
            }
            if ($denyCount -eq 0) {
                Write-Host "   -> No explicit Deny rule present (Folder open)." -ForegroundColor Gray
            }
        } catch {
            Write-Host "   -> Unable to verify ACL parameters." -ForegroundColor Red
        }
    } else {
        Write-Host "   -> Target directory does not exist yet." -ForegroundColor Yellow
    }

    # Display logged / configured game paths
    Write-Host ""
    Write-Host " Scanned Game Directories Saved in Cache:" -ForegroundColor Cyan
    $paths = Get-NvidiaScanPaths
    if ($paths.Count -gt 0) {
        foreach ($p in $paths) {
            Write-Host "   [+] $p" -ForegroundColor White
        }
    } else {
        Write-Host "   No logged directories or scan targets found (History empty or locked)." -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "Press any key to return..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# --- UNIFIED PRIVACY & TELEMETRY SUB-MENU WITH RECOVERY AND SAFE LOCK ---

function Show-PrivacyDebloatSubMenu {
    $subRunning = $true
    while ($subRunning) {
        Clear-Host
        $tasksStatus = Get-TelemetryStatus
        $appScansStatus = Get-NvidiaAppScansStatus
        
        # Hosts grouping parameters
        $otaDomains = @("ota.nvidia.com", "ota-downloads.nvidia.com")
        $telemetryDomains = @("telemetry.nvidia.com", "gfe-telemetry.nvidia.com", "events.gfe.nvidia.com")
        $accountDomains = @("accounts.nvgs.nvidia.com", "login.nvgs.nvidia.com")
        $gamestreamDomains = @("gfwsl.geforce.com", "prod.gamestream.nvidia.com")

        $otaBlocked = Get-HostsBlockStatus -Domains $otaDomains
        $telemetryBlocked = Get-HostsBlockStatus -Domains $telemetryDomains
        $accountBlocked = Get-HostsBlockStatus -Domains $accountDomains
        $gamestreamBlocked = Get-HostsBlockStatus -Domains $gamestreamDomains

        # Check Registry telemetry status
        $regBlocked = $true
        try {
            $val1 = (Get-ItemProperty -Path "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry" -Name "EnableTelemetry" -ErrorAction SilentlyContinue).EnableTelemetry
            $val2 = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" -Name "TelemetryEnabled" -ErrorAction SilentlyContinue).TelemetryEnabled
            if ($val1 -ne 0 -or $val2 -ne 0) { $regBlocked = $false }
        } catch {
            $regBlocked = $false
        }

        Write-Host "================================================" -ForegroundColor Cyan
        Write-Host "       PRIVACY, TELEMETRY & DEBLOAT MENU       " -ForegroundColor Cyan
        Write-Host "================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host " Telemetry Tasks Status     : " -NoNewline; if ($tasksStatus) { Write-Host "ENABLED" -ForegroundColor Red } else { Write-Host "DISABLED" -ForegroundColor Green }
        Write-Host " Registry Telemetry Block   : " -NoNewline; if ($regBlocked) { Write-Host "BLOCKED" -ForegroundColor Green } else { Write-Host "UNBLOCKED" -ForegroundColor Red }
        Write-Host " NVIDIA App Privacy Lock    : " -NoNewline; if ($appScansStatus -eq "SAFE LOCKED (File Lock)") { Write-Host "SAFE LOCKED (File Lock)" -ForegroundColor Green } else { Write-Host "UNLOCKED" -ForegroundColor Red }
        Write-Host " Hosts Block: OTA Updates   : " -NoNewline; if ($otaBlocked) { Write-Host "BLOCKED" -ForegroundColor Green } else { Write-Host "UNBLOCKED" -ForegroundColor Red }
        Write-Host " Hosts Block: Telemetry     : " -NoNewline; if ($telemetryBlocked) { Write-Host "BLOCKED" -ForegroundColor Green } else { Write-Host "UNBLOCKED" -ForegroundColor Red }
        Write-Host " Hosts Block: Account/GFE   : " -NoNewline; if ($accountBlocked) { Write-Host "BLOCKED" -ForegroundColor Green } else { Write-Host "UNBLOCKED" -ForegroundColor Red }
        Write-Host " Hosts Block: GameStream    : " -NoNewline; if ($gamestreamBlocked) { Write-Host "BLOCKED" -ForegroundColor Green } else { Write-Host "UNBLOCKED" -ForegroundColor Red }
        Write-Host ""
        Write-Host "------------------------------------------------" -ForegroundColor DarkGray
        Write-Host " 1. Toggle Telemetry Tasks" -ForegroundColor Yellow
        Write-Host " 2. Toggle Registry Telemetry Tweaks" -ForegroundColor Yellow
        Write-Host " 3. Safe Lock NVIDIA App Scans (Disable Scans & Lock Configs)" -ForegroundColor Red
        Write-Host " 4. Restore NVIDIA App Defaults (Unlock Scans)" -ForegroundColor Green
        Write-Host " 5. Toggle Hosts Block: OTA Updates (NVIDIA App Update)" -ForegroundColor Magenta
        Write-Host " 6. Toggle Hosts Block: Telemetry Domains" -ForegroundColor Magenta
        Write-Host " 7. Toggle Hosts Block: Account Login Domains" -ForegroundColor Magenta
        Write-Host " 8. Toggle Hosts Block: GameStream/Grid Domains" -ForegroundColor Magenta
        Write-Host " 9. Reset & Clear Scanned Game Library (Wipe Current Library)" -ForegroundColor White
        Write-Host " V. Verify Active Scans & Scan History Status" -ForegroundColor White
        Write-Host " R. Reset & Revert Privacy Tweaks (Safe Defaults)" -ForegroundColor Green
        Write-Host " 0. Go Back to Main Menu" -ForegroundColor White
        Write-Host "================================================" -ForegroundColor Cyan
        Write-Host ""
        
        $subChoice = Read-Host " Select Option"
        switch ($subChoice.ToUpper()) {
            "1" { Toggle-Telemetry }
            "2" {
                if ($regBlocked) {
                    try {
                        Set-ItemProperty -Path "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry" -Name "EnableTelemetry" -Value 1 -Force -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry" -Name "LogEnabled" -Value 1 -Force -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" -Name "TelemetryEnabled" -Value 1 -Force -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" -Name "CrashTrackingEnabled" -Value 1 -Force -ErrorAction SilentlyContinue
                        Write-Host "`n [TOGGLE] Registry Telemetry restored to default (Enabled)." -ForegroundColor Yellow
                    } catch {}
                } else {
                    try {
                        $p1 = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry"
                        $p2 = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup"
                        if (-not (Test-Path $p1)) { New-Item -Path $p1 -Force -ErrorAction SilentlyContinue | Out-Null }
                        if (-not (Test-Path $p2)) { New-Item -Path $p2 -Force -ErrorAction SilentlyContinue | Out-Null }
                        Set-ItemProperty -Path $p1 -Name "EnableTelemetry" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path $p1 -Name "LogEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path $p2 -Name "TelemetryEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path $p2 -Name "CrashTrackingEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                        Write-Host "`n [TOGGLE] Registry Telemetry BLOCKED." -ForegroundColor Green
                    } catch {}
                }
                Start-Sleep -Seconds 1.5
            }
            "3" { Lock-NvidiaAppScansSafe; Show-NvidiaScanVerification }
            "4" { Unlock-NvidiaAppScans; Show-NvidiaScanVerification }
            "5" { Toggle-HostsDomainBlock -Domains $otaDomains -Description "OTA Updates" }
            "6" { Toggle-HostsDomainBlock -Domains $telemetryDomains -Description "Telemetry Domains" }
            "7" { Toggle-HostsDomainBlock -Domains $accountDomains -Description "Account Login" }
            "8" { Toggle-HostsDomainBlock -Domains $gamestreamDomains -Description "GameStream Services" }
            "9" { Clear-NvidiaLibrary }
            "V" { Show-NvidiaScanVerification }
            "R" { Restore-PrivacyDebloatDefaults }
            "0" { $subRunning = $false }
        }
    }
}

# --- MONITORING DASHBOARD ---

function Show-Dashboard {
    param($SmiPath)
    if (-not $SmiPath) {
        Write-Host "NVIDIA-SMI is required for Dashboard monitoring." -ForegroundColor Red
        Pause
        return
    }
    try { & $SmiPath -L | Out-Null } catch { Write-Host "NVIDIA-SMI failed." -ForegroundColor Red; Pause; return }
    $running = $true
    $deg = [char]0x00B0 

    Clear-Host
    while ($running) {
        [Console]::SetCursorPosition(0,0)
        Write-Host "=== NVIDIA HARDWARE MONITOR ===" -ForegroundColor Cyan -BackgroundColor DarkBlue
        Write-Host " Press '0' to return to menu.  " -ForegroundColor Gray -BackgroundColor Black
        Write-Host "-------------------------------" -ForegroundColor DarkCyan
        
        try {
            $cmdOutput = & $SmiPath --query-gpu=temperature.gpu,fan.speed,power.draw,power.limit,utilization.gpu,memory.used,memory.total,clocks.gr,clocks.mem --format=csv,noheader,nounits
            if ($cmdOutput -is [array]) { $cmdOutput = $cmdOutput[0] }
            
            # Optimized split and trim via member enumeration (much faster than ForEach-Object in high-frequency loops)
            $stats = ($cmdOutput -split ',').Trim()
            
            $GetVal = { param($idx) if ($stats.Count -gt $idx -and $stats[$idx] -ne "[Not Supported]") { return $stats[$idx] } else { return "0" } }

            $Temp    = &$GetVal 0
            $Fan     = &$GetVal 1
            $PwrDraw = &$GetVal 2
            $PwrLim  = &$GetVal 3
            $GpuLoad = &$GetVal 4
            $MemUsed = &$GetVal 5 
            $MemTot  = &$GetVal 6 
            $ClkCore = &$GetVal 7
            $ClkMem  = &$GetVal 8

            # Conversions
            $MemUsedGB = [math]::Round([double]$MemUsed / 1024, 2)
            $MemTotGB  = [math]::Round([double]$MemTot / 1024, 0)

            # RENDER
            Write-Host " GPU Temp      : " -NoNewline
            if ([int]$Temp -gt 80) { Write-Host "$Temp $deg`C" -ForegroundColor Red } else { Write-Host "$Temp $deg`C" -ForegroundColor Green }
            
            Write-Host " Fan Speed     : " -NoNewline; Write-Host "$Fan %" -ForegroundColor Cyan
            Write-Host " Power Usage   : " -NoNewline; Write-Host "$PwrDraw W / $PwrLim W" -ForegroundColor Yellow
            Write-Host " GPU Core Load : " -NoNewline; Write-Host "$GpuLoad %" -ForegroundColor Magenta
            
            Write-Host " VRAM Usage    : " -NoNewline; Write-Host "$MemUsedGB GB / $MemTotGB GB" -ForegroundColor White
            
            Write-Host " Core Clock    : " -NoNewline; Write-Host "$ClkCore MHz" -ForegroundColor DarkGray
            Write-Host " Mem Clock     : " -NoNewline; Write-Host "$ClkMem MHz" -ForegroundColor DarkGray
            
            Write-Host "-------------------------------" -ForegroundColor DarkCyan
            Write-Host " Last Update: $(Get-Date -Format 'HH:mm:ss') " -ForegroundColor DarkGray
            
        } catch { Write-Host "Reading sensors..." -ForegroundColor Red }

        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.KeyChar -eq '0') { $running = $false }
        }
        Start-Sleep -Milliseconds 1000
    }
}

# --- MAIN LOOP ---

$smi = Get-NvidiaSmi
# We fall back to standard CIM querying if nvidia-smi is not available
Write-Host "Initializing Nvidia Tool..." -ForegroundColor Green
$localInfo = Get-InstalledDriverInfo -SmiPath $smi
$latestVer = "Check Required"

do {
    Clear-Host
    
    $hagsStatus = Get-HagsStatus
    $vrrStatus = Get-VrrStatus
    $dlssStatus = Get-DlssIndicatorStatus
    
    # Custom stats dynamic querying
    $displayStats = Get-DisplayStats
    $rebarStatus = Get-RebarStatus -SmiPath $smi
    $appScansStatus = Get-NvidiaAppScansStatus

    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "                  NVIDIA TOOL                   " -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    
    Write-Host " GPU Device    : " -NoNewline; Write-Host "$($localInfo.Name)" -ForegroundColor White
    Write-Host " VRAM Size     : " -NoNewline; Write-Host "$($localInfo.VRAM) MB" -ForegroundColor White
    Write-Host "--------------- MONITOR STATS -----------------" -ForegroundColor DarkGray
    Write-Host " Resolution    : " -NoNewline; Write-Host "$($displayStats.Resolution)" -ForegroundColor White
    Write-Host " Color Depth   : " -NoNewline; Write-Host "$($displayStats.ColorDepth)" -ForegroundColor White
    Write-Host " Display Mode  : " -NoNewline; Write-Host "$($displayStats.DisplayMode)" -ForegroundColor White
    Write-Host "------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " Installed Ver : " -NoNewline; Write-Host "$($localInfo.Version)" -ForegroundColor Yellow
    Write-Host " Latest        : " -NoNewline
    
    if ($latestVer -eq "Check Required") {
        Write-Host "[Press U to Check]" -ForegroundColor DarkGray
    } elseif ($latestVer -eq "Connection Error" -or $latestVer -eq "Unknown") { 
        Write-Host $latestVer -ForegroundColor Red 
    } else {
        try { 
            if ([version]$localInfo.Version -ge [version]$latestVer) { Write-Host "$latestVer (Up to Date)" -ForegroundColor Green } 
            else { Write-Host "$latestVer (UPDATE AVAILABLE)" -ForegroundColor Red -BackgroundColor Yellow } 
        } catch { Write-Host "$latestVer" -ForegroundColor White }
    }

    Write-Host "------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " Hardware-Accelerated GPU Scheduling : " -NoNewline; if ($hagsStatus) { Write-Host "ON" -ForegroundColor Green } else { Write-Host "OFF" -ForegroundColor Red }
    Write-Host " Variable Refresh Rate               : " -NoNewline; if ($vrrStatus) { Write-Host "ON" -ForegroundColor Green } else { Write-Host "OFF" -ForegroundColor Red }
    Write-Host " BIOS ReBAR Support                  : " -NoNewline; if ($rebarStatus -eq "SUPPORTED (UEFI)") { Write-Host "SUPPORTED (UEFI)" -ForegroundColor Green } else { Write-Host "$rebarStatus" -ForegroundColor Red }
    Write-Host " DLSS Info Overlay                   : " -NoNewline; if ($dlssStatus) { Write-Host "ENABLED" -ForegroundColor Green } else { Write-Host "DISABLED" -ForegroundColor Red }
    Write-Host " NVIDIA App Scans (Privacy Lock)     : " -NoNewline; if ($appScansStatus -eq "SAFE LOCKED (File Lock)") { Write-Host "SAFE LOCKED (File Lock)" -ForegroundColor Green } else { Write-Host "UNLOCKED" -ForegroundColor Red }

    Write-Host "================================================" -ForegroundColor Cyan
    
    Write-Host " [WINDOWS & GPU GRAPHICS SETTINGS]" -ForegroundColor Cyan
    Write-Host " H. Toggle HAGS" -ForegroundColor Magenta
    Write-Host " V. Toggle VRR" -ForegroundColor Magenta
    Write-Host ""
    Write-Host " [NVIDIA SETTINGS]" -ForegroundColor Cyan
    Write-Host " D. Toggle DLSS Indicator" -ForegroundColor Yellow
    Write-Host " U. Check Driver Updates (TPU)" -ForegroundColor White
    Write-Host ""
    Write-Host " [NVIDIA APP DEBLOAT & PRIVACY]" -ForegroundColor Cyan
    Write-Host " 6. Debloat, Privacy & App Scan Sub-Menu" -ForegroundColor Red
    Write-Host ""
    Write-Host " [MONITORING]" -ForegroundColor Cyan
    Write-Host " 1. Hardware Dashboard" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " [MAINTENANCE & FIXES]" -ForegroundColor Cyan
    Write-Host " 2. Clean DirectX Caches and other temp files" -ForegroundColor Yellow
    Write-Host " 3. Disable Game Bar Presence" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " [POWER MANAGEMENT]" -ForegroundColor Cyan
    Write-Host " 4. Eco Mode (50% Power)" -ForegroundColor Green
    Write-Host " 5. Max Performance (100% Power)" -ForegroundColor Green
    Write-Host ""
    Write-Host " X. Exit" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host " Select Option"
    
    switch ($choice.ToUpper()) {
        "H" { Toggle-HAGS }
        "V" { Toggle-VRR }
        "D" { Toggle-DlssIndicator }
        "U" { $latestVer = Get-LatestDriverFromTPU }
        "6" { Show-PrivacyDebloatSubMenu }
        "1" { Show-Dashboard -SmiPath $smi }
        "2" { Clean-Caches }
        "3" { Disable-GameBarWriter }
        "4" { Set-EcoMode -SmiPath $smi }
        "5" { Set-MaxMode -SmiPath $smi }
        "X" { exit }
    }
} while ($true)