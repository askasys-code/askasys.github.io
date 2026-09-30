# REQUIRES: Administrator Privileges
# COMPATIBILITY: PowerShell 5.1+ & PowerShell 7+ (Windows)
# CODING STANDARD: All internal comments must be written in ENGLISH.

# Updated: 2026-09-30

# ---------------------------------------------------------------------------
# INITIALIZATION & SETUP
# ---------------------------------------------------------------------------

#region Setup, Encoding & Auto-Elevation
# --- 1. GLOBAL SETTINGS ---
$ErrorActionPreference = "Continue"

# Set Console Title
$Host.UI.RawUI.WindowTitle = "NVIDIA Optimization & Diagnostic Tool"

# Set Console Encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Enable modern security protocols safely (TLS 1.2 & TLS 1.3 if supported by CLR)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([Net.SecurityProtocolType].GetEnumNames() -contains "Tls13") {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13
    }
} catch {}

# --- 2. ADMIN SELF-ELEVATION ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "`n [!] Administrator privileges required." -ForegroundColor Yellow
    Write-Host " [!] Restarting as Administrator..." -ForegroundColor White
    
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Definition }
    $workingDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($scriptPath) { Split-Path -Parent $scriptPath } else { [System.Environment]::CurrentDirectory }

    # Detect current PowerShell executable to preserve PowerShell 7+ (pwsh) or 5.1 environments
    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe -or -not (Test-Path $psExe)) {
        $psExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }
    }

    try {
        Start-Process $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs -WorkingDirectory $workingDir
        Exit
    } catch {
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
        public struct DISPLAYCONFIG_RATIONAL {
            public uint Numerator;
            public uint Denominator;
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
            public uint targetAvailable;
            public uint statusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_PATH_INFO {
            public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
            public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
            public uint flags;
        }

        [StructLayout(LayoutKind.Explicit, Size = 64)]
        public struct DISPLAYCONFIG_MODE_INFO {
            [FieldOffset(0)] public uint infoType;
            [FieldOffset(4)] public uint id;
            [FieldOffset(8)] public LUID adapterId;
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
                if (err == 0 && pathCount > 0 && modeCount > 0) {
                    DISPLAYCONFIG_PATH_INFO[] paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
                    DISPLAYCONFIG_MODE_INFO[] modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
                    err = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
                    if (err == 0) {
                        for (int i = 0; i < pathCount; i++) {
                            var colorInfo = new DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO();
                            colorInfo.header.type = 9; // DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO
                            colorInfo.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO));
                            colorInfo.header.adapterId = paths[i].targetInfo.adapterId;
                            colorInfo.header.id = paths[i].targetInfo.id;

                            if (DisplayConfigGetDeviceInfo(ref colorInfo) == 0) {
                                if (colorInfo.bitsPerColorChannel > details.BitsPerChannel) {
                                    details.BitsPerChannel = colorInfo.bitsPerColorChannel;
                                }
                                if (colorInfo.advancedColorEnabled) {
                                    details.HdrEnabled = true;
                                }
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
# CORE HELPER FUNCTIONS
# ---------------------------------------------------------------------------

function Get-NvidiaSmi {
    $cmd = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    
    $defaultPaths = @(
        "$env:SystemDrive\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
        "$env:windir\System32\nvidia-smi.exe"
    )
    foreach ($p in $defaultPaths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-InstalledDriverInfo {
    param($SmiPath)
    
    # 1. Primary: Query via nvidia-smi if available
    if ($SmiPath -and (Test-Path $SmiPath)) {
        try {
            $data = & $SmiPath --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>$null
            if ($data -is [array]) { $data = $data[0] }
            if ($data -and $data -match ',') {
                $parts = ($data -split ',\s*').Trim()
                $vramVal = if ($parts[2] -match '^\d+') { [math]::Round([double]$parts[2], 0) } else { 0 }
                return @{ Name = $parts[0]; Version = $parts[1]; VRAM = $vramVal }
            }
        } catch {}
    }

    # 2. Fallback: Query via CIM & 64-bit Registry (Avoids 4GB WMI AdapterRAM limitation)
    try {
        $gpu = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -like "*NVIDIA*" } | Select-Object -First 1
        if ($gpu) {
            $rawVersion = $gpu.DriverVersion
            $formattedVersion = $rawVersion
            if ($rawVersion -match '(\d)\.(\d{2})(\d{2})$') {
                $formattedVersion = "$($Matches[1])$($Matches[2]).$($Matches[3])"
            }
            
            $vram = 0
            try {
                $regGpus = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\000*" -ErrorAction SilentlyContinue
                foreach ($item in $regGpus) {
                    if ($item.DriverDesc -like "*NVIDIA*" -and $item."HardwareInformation.qwMemorySize") {
                        $vram = [math]::Round($item."HardwareInformation.qwMemorySize" / 1MB, 0)
                        break
                    }
                }
            } catch {}

            if ($vram -eq 0 -and $gpu.AdapterRAM) {
                $vram = [math]::Round($gpu.AdapterRAM / 1MB, 0)
            }

            return @{
                Name    = $gpu.Name
                Version = $formattedVersion
                VRAM    = $vram
            }
        }
    } catch {}

    return @{ Name = "NVIDIA Device (Undetected)"; Version = "0.00"; VRAM = 0 }
}

function Get-LatestDriverFromTPU {
    Write-Host "Checking TechPowerUp for latest drivers..." -ForegroundColor DarkGray
    $url = "https://www.techpowerup.com/download/nvidia-geforce-graphics-drivers/"
    try {
        $headers = @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
            "Accept"     = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        }
        $req = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop
        
        # Primary regex match on driver release titles
        if ($req.Content -match '(?i)(?:GeForce\s+Graphics\s+Drivers?|GeForce\s+Driver)[^0-9]*(\d{3}\.\d{2})') {
            return $Matches[1]
        }
        # Fallback regex match on version tags
        if ($req.Content -match '(?i)version[^0-9]*(\d{3}\.\d{2})') {
            return $Matches[1]
        }
        return "Unknown"
    } catch {
        return "Connection Error"
    }
}

function Get-HagsStatus {
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    $name = "HwSchMode"
    try {
        $val = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
        if ($val -eq 2) { return $true }
    } catch {}
    return $false
}

function Get-VrrStatus {
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
    $tasks = @("NvTmMon*", "NvTmRep*", "NvProfileUpdater*")
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
        if ($val -eq 1024) { return $true }
    } catch {}
    return $false
}

function Get-DisplayStats {
    $resolution  = "Unknown"
    $colorDepth  = "8-bit"
    $displayMode = "SDR"

    try {
        # 1. Fetch Resolution and Refresh Rate
        $gpu = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
        if ($gpu) {
            $w = $gpu.CurrentHorizontalResolution
            $h = $gpu.CurrentVerticalResolution
            $r = $gpu.CurrentRefreshRate
            
            # Correct refresh rate rounding
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

    # 2. Get Realtime HDR Status (Decoupled from ACM / 10-bit SDR to prevent false HDR readings)
    $hdrEnabled = $false
    
    # Check A: WMI Display Parameters (Standard on Win 10 1903+)
    try {
        $wmiHdr = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorDisplayParams -ErrorAction SilentlyContinue
        if ($wmiHdr) {
            $activeHdr = $wmiHdr | Where-Object { $_.Active } | Select-Object -ExpandProperty HdrEnabled -First 1
            if ($null -ne $activeHdr) {
                $hdrEnabled = [bool]$activeHdr
            } else {
                $hdrEnabled = ($wmiHdr.HdrEnabled -contains $true)
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

    # 3. Get Color Depth (Bit depth) via native Win32 Helper
    $bpc = 8
    try {
        if ([System.Management.Automation.PSTypeName]"HdrDetector") {
            $details = [HdrDetector]::GetColorDetails()
            if ($details.BitsPerChannel -gt 0) {
                $bpc = $details.BitsPerChannel
            }
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
    
    # 1. Primary: Check BAR1 size via nvidia-smi
    if ($SmiPath -and (Test-Path $SmiPath)) {
        try {
            $smiQuery = (& $SmiPath -q -d MEMORY 2>$null) | Out-String
            if ($smiQuery -match 'BAR1 Memory Usage\s+Total\s+:\s+(\d+)\s+MiB') {
                $barSize = [int]$Matches[1]
                if ($barSize -gt 512) {
                    return "SUPPORTED (UEFI)"
                }
            }
            # Fallback to Select-String match pattern
            $match = $smiQuery | Select-String -Pattern 'BAR1 Memory Usage\s+Total\s+:\s+(\d+)\s+MiB'
            if ($match -and $match.Matches.Groups[1].Value) {
                $barSize = [int]$match.Matches.Groups[1].Value
                if ($barSize -gt 512) {
                    return "SUPPORTED (UEFI)"
                }
            }
        } catch {}
    }
    
    # 2. Fallback: Query Large Memory Range in device PnP allocations (indicates Resizable BAR)
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
    $files = @(
        "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\NvBackend\ApplicationStorage.json",
        "$env:LOCALAPPDATA\NVIDIA\NVIDIA App\NvBackend\ApplicationStorage.json",
        "$env:LOCALAPPDATA\NVIDIA Corporation\NvBackend\JournalBS.main.xml",
        "$env:LOCALAPPDATA\NVIDIA\NvBackend\JournalBS.main.xml"
    )
    
    $lockedCount = 0
    $existingCount = 0

    foreach ($file in $files) {
        if (Test-Path $file) {
            $existingCount++
            $item = Get-Item -Path $file -ErrorAction SilentlyContinue
            if ($item.IsReadOnly) {
                $lockedCount++
            }
        }
    }
    
    if ($existingCount -gt 0 -and $lockedCount -eq $existingCount) {
        return "SAFE LOCKED (File Lock)"
    }
    return "UNLOCKED"
}

function Get-NvidiaScanPaths {
    $paths = [System.Collections.Generic.List[string]]::new()
    
    $searchDirs = @(
        "$env:LOCALAPPDATA\NVIDIA Corporation\NvBackend",
        "$env:LOCALAPPDATA\NVIDIA\NvBackend",
        "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\NvBackend",
        "$env:LOCALAPPDATA\NVIDIA\NVIDIA App\NvBackend"
    )

    foreach ($dir in $searchDirs) {
        if (Test-Path $dir) {
            $targetFiles = Get-ChildItem -Path $dir -Include "*.xml", "*.json" -Recurse -ErrorAction SilentlyContinue
            foreach ($file in $targetFiles) {
                try {
                    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                    if ($content) {
                        $regexMatches = [regex]::Matches($content, '(?i)([A-Z]:\\\\?[^"<>|\r\n]+)')
                        foreach ($m in $regexMatches) {
                            $cleanPath = $m.Groups[1].Value -replace '\\\\', '\'
                            if ($cleanPath -match '^[A-Z]:\\[^\\]+' -and $cleanPath -notmatch '(?i)NVIDIA|Temp|Windows') {
                                if (-not $paths.Contains($cleanPath)) { $paths.Add($cleanPath) }
                            }
                        }
                    }
                } catch {}
            }
        }
    }
    return $paths
}

# --- UNIFIED AND SAFE HOSTS CHANGER AND DETECTOR ---

function Get-HostsBlockStatus {
    param([string[]]$Domains)
    
    $hostsPath = "$env:windir\System32\drivers\etc\hosts"
    if (-not (Test-Path $hostsPath)) { return $false }
    
    $content = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) { return $false }

    foreach ($d in $Domains) {
        $pattern = "(?m)^\s*(?:127\.0\.0\.1|0\.0\.0\.0)\s+$([regex]::Escape($d))\b"
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
        try { New-Item -Path $hostsPath -ItemType File -Force -ErrorAction Stop | Out-Null } catch {}
    }

    $wasReadOnly = $false
    try {
        $item = Get-Item $hostsPath -ErrorAction Stop
        if ($item.IsReadOnly) {
            $wasReadOnly = $true
            $item.IsReadOnly = $false
        }
    } catch {}

    $lines = Get-Content $hostsPath -ErrorAction SilentlyContinue
    if ($null -eq $lines) { $lines = @() }

    $allBlocked = Get-HostsBlockStatus -Domains $Domains
    $newLines = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        $match = $false
        foreach ($d in $Domains) {
            if ($line -match "\b$([regex]::Escape($d))\b") {
                $match = $true
                break
            }
        }
        if (-not $match) { $newLines.Add($line) }
    }

    if ($allBlocked) {
        try {
            [System.IO.File]::WriteAllLines($hostsPath, $newLines, [System.Text.Encoding]::ASCII)
            Write-Host "`n [TOGGLE] Unblocked $Description (Removed from Hosts)." -ForegroundColor Yellow
        } catch {
            Write-Host "`n [ERROR] Failed to write to hosts file. Check permissions or antivirus." -ForegroundColor Red
        }
    } else {
        foreach ($d in $Domains) {
            $newLines.Add("0.0.0.0 $d")
        }
        try {
            [System.IO.File]::WriteAllLines($hostsPath, $newLines, [System.Text.Encoding]::ASCII)
            Write-Host "`n [TOGGLE] Blocked $Description (Added to Hosts)." -ForegroundColor Green
        } catch {
            Write-Host "`n [ERROR] Failed to write to hosts file. Check permissions or antivirus." -ForegroundColor Red
        }
    }

    if ($wasReadOnly) {
        try { (Get-Item $hostsPath).IsReadOnly = $true } catch {}
    }

    try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 1.5
}

# --- SETTINGS TOGGLES ---

function Toggle-HAGS {
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    $name = "HwSchMode"
    $status = Get-HagsStatus
    
    if (-not (Test-Path $path)) { New-Item -Path $path -Force -ErrorAction SilentlyContinue | Out-Null }

    if ($status) {
        Set-ItemProperty -Path $path -Name $name -Value 1 -Type DWord -Force
        Write-Host "`n [TOGGLE] HAGS set to DISABLED. Reboot Required." -ForegroundColor Yellow
    } else {
        Set-ItemProperty -Path $path -Name $name -Value 2 -Type DWord -Force
        Write-Host "`n [TOGGLE] HAGS set to ENABLED. Reboot Required." -ForegroundColor Green
    }
    Start-Sleep -Seconds 1.5
}

function Toggle-VRR {
    $path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    $name = "DirectXUserGlobalSettings"
    
    if (-not (Test-Path $path)) { New-Item -Path $path -Force -ErrorAction SilentlyContinue | Out-Null }

    $currentVal = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
    if ($null -eq $currentVal) { $currentVal = "" }
    
    $status = Get-VrrStatus

    if ($status) {
        if ($currentVal -match 'VRROptimizeEnable=\d') {
            $newVal = $currentVal -replace 'VRROptimizeEnable=\d', 'VRROptimizeEnable=0'
        } else {
            $newVal = ($currentVal.Trim(';') + ';VRROptimizeEnable=0;').TrimStart(';')
        }
        Set-ItemProperty -Path $path -Name $name -Value $newVal -Type String -Force
        Write-Host "`n [TOGGLE] VRR set to DISABLED. Reboot Required." -ForegroundColor Yellow
    } else {
        if ($currentVal -match 'VRROptimizeEnable=\d') {
            $newVal = $currentVal -replace 'VRROptimizeEnable=\d', 'VRROptimizeEnable=1'
        } else {
            $newVal = ($currentVal.Trim(';') + ';VRROptimizeEnable=1;').TrimStart(';')
        }
        Set-ItemProperty -Path $path -Name $name -Value $newVal -Type String -Force
        Write-Host "`n [TOGGLE] VRR set to ENABLED. Reboot Required." -ForegroundColor Green
    }
    Start-Sleep -Seconds 1.5
}

function Toggle-Telemetry {
    $tasks = @("NvTmMon*", "NvTmRep*", "NvProfileUpdater*")
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

    if (-not (Test-Path $path)) { New-Item -Path $path -Force -ErrorAction SilentlyContinue | Out-Null }

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
        if (-not (Test-Path $reg)) { New-Item -Path $reg -Force -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $reg -Name "AllowGameDVR" -Value 0 -Type DWord -Force
        
        # 2. Registry Policies (User Specific)
        $regUser = "HKCU:\System\GameConfigStore"
        if (-not (Test-Path $regUser)) { New-Item -Path $regUser -Force -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $regUser -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $regUser -Name "GameDVR_FSEBehaviorMode" -Value 2 -Type DWord -Force

        # 3. Disable App Capture Components (User Specific)
        $regDVRUser = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR"
        if (-not (Test-Path $regDVRUser)) { New-Item -Path $regDVRUser -Force -ErrorAction SilentlyContinue | Out-Null }
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
        @{ Path="$env:LOCALAPPDATA\NVIDIA\DXCache"; Desc="DirectX Shader Cache" }
        @{ Path="$env:LOCALAPPDATA\NVIDIA\GLCache"; Desc="OpenGL Shader Cache" }
        @{ Path="$env:APPDATA\NVIDIA\ComputeCache"; Desc="CUDA Compute Cache" }
        @{ Path="$env:ProgramData\NVIDIA Corporation\NV_Cache"; Desc="System Cache" }
        @{ Path="$env:ProgramData\NVIDIA Corporation\Downloader"; Desc="Installer Temp Cache" }
        @{ Path="$env:LOCALAPPDATA\Temp\NVIDIA Corporation"; Desc="User Temp Cache" }
        @{ Path="$env:LOCALAPPDATA\D3DSCache"; Desc="Windows D3D Shader Cache" }
        @{ Path="$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\Cache"; Desc="NVIDIA App Cache" }
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
                Write-Host " Location: $p" -ForegroundColor DarkGray
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
                        Write-Host "    [PARTIAL] Cleaned ($removedCount/$count). Some files may be in use by running apps." -ForegroundColor Yellow 
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
    if (-not $SmiPath -or -not (Test-Path $SmiPath)) {
        Write-Host "NVIDIA-SMI is required to configure power limit features." -ForegroundColor Red
        Pause
        return
    }
    try {
        $maxRaw = & $SmiPath --query-gpu=power.max_limit --format=csv,noheader,nounits 2>$null
        $minRaw = & $SmiPath --query-gpu=power.min_limit --format=csv,noheader,nounits 2>$null
        if ($maxRaw -is [array]) { $maxRaw = $maxRaw[0] }
        if ($minRaw -is [array]) { $minRaw = $minRaw[0] }

        if (-not $maxRaw -or $maxRaw -match "Not Supported") {
            Write-Host "Power limit adjustment is not supported by this GPU model." -ForegroundColor Red
            Pause
            return
        }

        $max = [double]($maxRaw -replace '[^\d.]')
        $min = if ($minRaw -and $minRaw -notmatch "Not Supported") { [double]($minRaw -replace '[^\d.]') } else { 0 }
        
        $target = [int][math]::Round($max * 0.50)
        if ($min -gt 0 -and $target -lt [int]$min) {
            $target = [int][math]::Ceiling($min)
            Write-Host "Adjusted to hardware minimum threshold: $target W" -ForegroundColor Yellow
        }
        
        & $SmiPath -pl $target
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to apply power limit. Operation may be restricted (common on mobile GPUs)." -ForegroundColor Red
        } else {
            Write-Host "Power limit successfully set to $target W." -ForegroundColor Green
        }
    } catch {
        Write-Host "Failed to query or adjust limit: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause
}

function Set-MaxMode {
    param($SmiPath)
    Write-Host "`n=== Max Performance Setup (100%) ===" -ForegroundColor Cyan
    if (-not $SmiPath -or -not (Test-Path $SmiPath)) {
        Write-Host "NVIDIA-SMI is required to configure power limit features." -ForegroundColor Red
        Pause
        return
    }
    try {
        $defRaw = & $SmiPath --query-gpu=power.default_limit --format=csv,noheader,nounits 2>$null
        $maxRaw = & $SmiPath --query-gpu=power.max_limit --format=csv,noheader,nounits 2>$null
        if ($defRaw -is [array]) { $defRaw = $defRaw[0] }
        if ($maxRaw -is [array]) { $maxRaw = $maxRaw[0] }

        $targetRaw = if ($defRaw -and $defRaw -notmatch "Not Supported") { $defRaw } else { $maxRaw }
        if (-not $targetRaw -or $targetRaw -match "Not Supported") {
            Write-Host "Power limit adjustment is not supported by this GPU model." -ForegroundColor Red
            Pause
            return
        }

        $target = [int][math]::Round([double]($targetRaw -replace '[^\d.]'))
        & $SmiPath -pl $target
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to apply power limit. Operation may be restricted." -ForegroundColor Red
        } else {
            Write-Host "Power limit successfully restored to $target W." -ForegroundColor Green
        }
    } catch {
        Write-Host "Failed to query or adjust limit: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause
}

# --- MASTER DEBLOAT & SUB-MENU PRIVACY ACTIONS ---

function Lock-NvidiaAppScansSafe {
    Write-Host "`n[SAFE LOCK] Disabling NVIDIA App/GFE Scans..." -ForegroundColor Cyan
    Write-Host "Halting background services temporarily to unlock active handles..." -ForegroundColor Gray

    $services = @("NvContainerLocalSystem", "NvContainerLS")
    foreach ($svc in $services) {
        if (Get-Service $svc -ErrorAction SilentlyContinue) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
    }
    Stop-Process -Name "nvcontainer", "NVIDIA App" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800

    # 1. Handle GFE XML SearchPaths
    $gfeFiles = @(
        "$env:LOCALAPPDATA\NVIDIA Corporation\NvBackend\JournalBS.main.xml",
        "$env:LOCALAPPDATA\NVIDIA\NvBackend\JournalBS.main.xml"
    )
    foreach ($file in $gfeFiles) {
        $parent = Split-Path -Parent $file
        if (-not (Test-Path $parent)) {
            try { New-Item -Path $parent -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        }

        try {
            if (Test-Path $file) {
                $item = Get-Item $file
                if ($item.IsReadOnly) { $item.IsReadOnly = $false }
            }
            $xmlContent = '<?xml version="1.0" encoding="utf-8"?><Journal><SearchPaths></SearchPaths></Journal>'
            [System.IO.File]::WriteAllText($file, $xmlContent, [System.Text.Encoding]::UTF8)
            (Get-Item $file).IsReadOnly = $true
            Write-Host "   Safely cleared and locked: $file" -ForegroundColor Green
        } catch {}
    }

    # 2. Handle NVIDIA App JSON Scan Storage
    $appFiles = @(
        "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\NvBackend\ApplicationStorage.json",
        "$env:LOCALAPPDATA\NVIDIA\NVIDIA App\NvBackend\ApplicationStorage.json"
    )
    foreach ($file in $appFiles) {
        $parent = Split-Path -Parent $file
        if (-not (Test-Path $parent)) {
            try { New-Item -Path $parent -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        }

        try {
            if (Test-Path $file) {
                $item = Get-Item $file
                if ($item.IsReadOnly) { $item.IsReadOnly = $false }
                
                $jsonContent = Get-Content $file -Raw -ErrorAction SilentlyContinue
                if ($jsonContent) {
                    $jsonContent = $jsonContent -replace '"scanLocations"\s*:\s*\[[^\]]*\]', '"scanLocations": []'
                    $jsonContent = $jsonContent -replace '"searchPaths"\s*:\s*\[[^\]]*\]', '"searchPaths": []'
                    [System.IO.File]::WriteAllText($file, $jsonContent, [System.Text.Encoding]::UTF8)
                } else {
                    [System.IO.File]::WriteAllText($file, "{}", [System.Text.Encoding]::UTF8)
                }
            } else {
                [System.IO.File]::WriteAllText($file, "{}", [System.Text.Encoding]::UTF8)
            }
            (Get-Item $file).IsReadOnly = $true
            Write-Host "   Safely cleared and locked: $file" -ForegroundColor Green
        } catch {}
    }

    foreach ($svc in $services) {
        if (Get-Service $svc -ErrorAction SilentlyContinue) {
            Start-Service -Name $svc -ErrorAction SilentlyContinue
        }
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
                $item = Get-Item $file
                if ($item.IsReadOnly) { $item.IsReadOnly = $false }
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

    $currentStatus = Get-NvidiaAppScansStatus
    $wasLocked = ($currentStatus -eq "SAFE LOCKED (File Lock)")

    $services = @("NvContainerLocalSystem", "NvContainerLS")
    foreach ($svc in $services) {
        if (Get-Service $svc -ErrorAction SilentlyContinue) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
    }
    Stop-Process -Name "nvcontainer", "NVIDIA App" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800

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

    foreach ($file in $gfeFiles) {
        if (Test-Path $file) {
            try {
                $item = Get-Item $file
                if ($item.IsReadOnly) { $item.IsReadOnly = $false }
                $xmlContent = '<?xml version="1.0" encoding="utf-8"?><Journal><SearchPaths></SearchPaths></Journal>'
                [System.IO.File]::WriteAllText($file, $xmlContent, [System.Text.Encoding]::UTF8)
                Write-Host "   Cleared GFE scan database: $file" -ForegroundColor Green
            } catch {}
        }
        $parent = Split-Path -Parent $file
        if (Test-Path $parent) {
            foreach ($p in $gfeToPurge) {
                $target = Join-Path $parent $p
                if (Test-Path $target) {
                    try {
                        $targetItem = Get-Item $target
                        if ($targetItem.IsReadOnly) { $targetItem.IsReadOnly = $false }
                        Remove-Item -Path $target -Force -ErrorAction SilentlyContinue
                    } catch {}
                }
            }
            @("StreamingAssetsData", "VisualOPSData") | ForEach-Object {
                $targetDir = Join-Path $parent $_
                if (Test-Path $targetDir) {
                    try { Remove-Item -Path $targetDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
        }
    }

    foreach ($file in $appFiles) {
        if (Test-Path $file) {
            try {
                $item = Get-Item $file
                if ($item.IsReadOnly) { $item.IsReadOnly = $false }
                [System.IO.File]::WriteAllText($file, "{}", [System.Text.Encoding]::UTF8)
                Write-Host "   Cleared NVIDIA App library database: $file" -ForegroundColor Green
            } catch {}
        }
    }

    if ($wasLocked) {
        foreach ($file in @($gfeFiles + $appFiles)) {
            if (Test-Path $file) {
                try {
                    (Get-Item $file).IsReadOnly = $true
                    Write-Host "   Re-applied Privacy Lock on: $file" -ForegroundColor Gray
                } catch {}
            }
        }
    }

    foreach ($svc in $services) {
        if (Get-Service $svc -ErrorAction SilentlyContinue) {
            Start-Service -Name $svc -ErrorAction SilentlyContinue
        }
    }

    Write-Host "`n[SUCCESS] Current game library cleared!" -ForegroundColor Green
    Write-Host "Restart GFE/NVIDIA App to verify." -ForegroundColor Magenta
    Start-Sleep -Seconds 2
}

function Restore-PrivacyDebloatDefaults {
    Write-Host "`n=== REVERTING PRIVACY & DEBLOAT TWEAKS TO DEFAULT ===" -ForegroundColor Cyan
    Write-Host "Restoring tasks, registry telemetry, hosts file blocks, and scan configurations..." -ForegroundColor Gray
    Write-Host ""

    $services = @("NvContainerLocalSystem", "NvContainerLS")
    foreach ($svc in $services) {
        if (Get-Service $svc -ErrorAction SilentlyContinue) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 800

    $filesToRestore = @(
        "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\NvBackend\ApplicationStorage.json",
        "$env:LOCALAPPDATA\NVIDIA\NVIDIA App\NvBackend\ApplicationStorage.json",
        "$env:LOCALAPPDATA\NVIDIA Corporation\NvBackend\JournalBS.main.xml",
        "$env:LOCALAPPDATA\NVIDIA\NvBackend\JournalBS.main.xml"
    )
    foreach ($file in $filesToRestore) {
        if (Test-Path $file) {
            try {
                $item = Get-Item $file
                if ($item.IsReadOnly) { $item.IsReadOnly = $false }
                Write-Host "   Restored scan config attributes on: $file" -ForegroundColor Green
            } catch {}
        }
    }

    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry" -Name "EnableTelemetry" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry" -Name "LogEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" -Name "TelemetryEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" -Name "CrashTrackingEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "   Restored Registry Telemetry keys to default (Enabled)." -ForegroundColor Green
    } catch {}

    $tasks = @("NvTmMon*", "NvTmRep*", "NvProfileUpdater*")
    $scheduledTasks = Get-ScheduledTask -TaskName $tasks -ErrorAction SilentlyContinue
    if ($scheduledTasks) {
        try {
            $scheduledTasks | Enable-ScheduledTask | Out-Null
            Write-Host "   Enabled Scheduled Telemetry Tasks." -ForegroundColor Green
        } catch {}
    }

    $hostsPath = "$env:windir\System32\drivers\etc\hosts"
    if (Test-Path $hostsPath) {
        try {
            $item = Get-Item $hostsPath
            if ($item.IsReadOnly) { $item.IsReadOnly = $false }
            
            $lines = Get-Content $hostsPath -ErrorAction SilentlyContinue
            if ($lines) {
                $nvidiaDomains = @(
                    "ota.nvidia.com", "ota-downloads.nvidia.com",
                    "telemetry.nvidia.com", "gfe-telemetry.nvidia.com", "events.gfe.nvidia.com",
                    "accounts.nvgs.nvidia.com", "login.nvgs.nvidia.com",
                    "gfwsl.geforce.com", "prod.gamestream.nvidia.com"
                )
                $cleanLines = [System.Collections.Generic.List[string]]::new()
                foreach ($line in $lines) {
                    $match = $false
                    foreach ($d in $nvidiaDomains) {
                        if ($line -match "\b$([regex]::Escape($d))\b") { $match = $true; break }
                    }
                    if (-not $match) { $cleanLines.Add($line) }
                }
                [System.IO.File]::WriteAllLines($hostsPath, $cleanLines, [System.Text.Encoding]::ASCII)
                Write-Host "   Removed all NVIDIA domain blocks from Hosts file." -ForegroundColor Green
                Clear-DnsClientCache -ErrorAction SilentlyContinue
            }
        } catch {}
    }

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

# --- PRIVACY & TELEMETRY SUB-MENU ---

function Show-PrivacyDebloatSubMenu {
    $subRunning = $true
    while ($subRunning) {
        Clear-Host
        $tasksStatus = Get-TelemetryStatus
        $appScansStatus = Get-NvidiaAppScansStatus
        
        $otaDomains = @("ota.nvidia.com", "ota-downloads.nvidia.com")
        $telemetryDomains = @("telemetry.nvidia.com", "gfe-telemetry.nvidia.com", "events.gfe.nvidia.com")
        $accountDomains = @("accounts.nvgs.nvidia.com", "login.nvgs.nvidia.com")
        $gamestreamDomains = @("gfwsl.geforce.com", "prod.gamestream.nvidia.com")

        $otaBlocked = Get-HostsBlockStatus -Domains $otaDomains
        $telemetryBlocked = Get-HostsBlockStatus -Domains $telemetryDomains
        $accountBlocked = Get-HostsBlockStatus -Domains $accountDomains
        $gamestreamBlocked = Get-HostsBlockStatus -Domains $gamestreamDomains

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
        Write-Host " Hosts Block: Account/GFE   : " -NoNewline; if ($accountBlocked) { Write-Host "BLOCKED" -ForegroundColor Green } else { Write-Host "UNLOCKED" -ForegroundColor Red }
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
                        Set-ItemProperty -Path "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry" -Name "EnableTelemetry" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry" -Name "LogEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" -Name "TelemetryEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" -Name "CrashTrackingEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
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
    if (-not $SmiPath -or -not (Test-Path $SmiPath)) {
        Write-Host "NVIDIA-SMI is required for Dashboard monitoring." -ForegroundColor Red
        Pause
        return
    }
    try { & $SmiPath -L | Out-Null } catch { Write-Host "NVIDIA-SMI failed." -ForegroundColor Red; Pause; return }
    
    $running = $true
    $deg = [char]0x00B0 

    try { [Console]::CursorVisible = $false } catch {}

    Clear-Host
    try {
        while ($running) {
            [Console]::SetCursorPosition(0,0)
            Write-Host "=== NVIDIA HARDWARE MONITOR ===" -ForegroundColor Cyan -BackgroundColor DarkBlue
            Write-Host " Press '0', 'Q' or 'ESC' to exit. " -ForegroundColor Gray -BackgroundColor Black
            Write-Host "-------------------------------" -ForegroundColor DarkCyan
            
            try {
                $cmdOutput = & $SmiPath --query-gpu=temperature.gpu,fan.speed,power.draw,power.limit,utilization.gpu,memory.used,memory.total,clocks.gr,clocks.mem --format=csv,noheader,nounits 2>$null
                if ($cmdOutput -is [array]) { $cmdOutput = $cmdOutput[0] }
                
                $stats = ($cmdOutput -split ',').Trim()
                $GetVal = { 
                    param($idx) 
                    if ($stats.Count -gt $idx -and $stats[$idx] -ne "[Not Supported]" -and $stats[$idx] -ne "[N/A]") { 
                        return $stats[$idx] 
                    } else { 
                        return "N/A" 
                    } 
                }

                $Temp    = &$GetVal 0
                $Fan     = &$GetVal 1
                $PwrDraw = &$GetVal 2
                $PwrLim  = &$GetVal 3
                $GpuLoad = &$GetVal 4
                $MemUsed = &$GetVal 5 
                $MemTot  = &$GetVal 6 
                $ClkCore = &$GetVal 7
                $ClkMem  = &$GetVal 8

                $MemUsedGB = if ($MemUsed -ne "N/A") { [math]::Round([double]$MemUsed / 1024, 2) } else { "N/A" }
                $MemTotGB  = if ($MemTot -ne "N/A")  { [math]::Round([double]$MemTot / 1024, 0) } else { "N/A" }

                Write-Host " GPU Temp      : " -NoNewline
                if ($Temp -ne "N/A" -and [int]$Temp -gt 80) { 
                    Write-Host ("$Temp $deg`C").PadRight(20) -ForegroundColor Red 
                } elseif ($Temp -ne "N/A") { 
                    Write-Host ("$Temp $deg`C").PadRight(20) -ForegroundColor Green 
                } else { 
                    Write-Host "N/A".PadRight(20) -ForegroundColor DarkGray 
                }
                
                Write-Host " Fan Speed     : " -NoNewline
                if ($Fan -ne "N/A") { Write-Host ("$Fan %").PadRight(20) -ForegroundColor Cyan } else { Write-Host "N/A (Fan Stop/Mobile)".PadRight(20) -ForegroundColor DarkGray }
                
                Write-Host " Power Usage   : " -NoNewline
                if ($PwrDraw -ne "N/A") { Write-Host ("$PwrDraw W / $PwrLim W").PadRight(20) -ForegroundColor Yellow } else { Write-Host "N/A".PadRight(20) -ForegroundColor DarkGray }
                
                Write-Host " GPU Core Load : " -NoNewline
                if ($GpuLoad -ne "N/A") { Write-Host ("$GpuLoad %").PadRight(20) -ForegroundColor Magenta } else { Write-Host "N/A".PadRight(20) -ForegroundColor DarkGray }
                
                Write-Host " VRAM Usage    : " -NoNewline
                if ($MemUsedGB -ne "N/A") { Write-Host ("$MemUsedGB GB / $MemTotGB GB").PadRight(20) -ForegroundColor White } else { Write-Host "N/A".PadRight(20) -ForegroundColor DarkGray }
                
                Write-Host " Core Clock    : " -NoNewline
                if ($ClkCore -ne "N/A") { Write-Host ("$ClkCore MHz").PadRight(20) -ForegroundColor DarkGray } else { Write-Host "N/A".PadRight(20) -ForegroundColor DarkGray }
                
                Write-Host " Mem Clock     : " -NoNewline
                if ($ClkMem -ne "N/A") { Write-Host ("$ClkMem MHz").PadRight(20) -ForegroundColor DarkGray } else { Write-Host "N/A".PadRight(20) -ForegroundColor DarkGray }
                
                Write-Host "-------------------------------" -ForegroundColor DarkCyan
                Write-Host " Last Update: $(Get-Date -Format 'HH:mm:ss')      " -ForegroundColor DarkGray
                
            } catch { 
                Write-Host "Reading sensors...            " -ForegroundColor Red 
            }

            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.KeyChar -eq '0' -or $k.KeyChar -eq 'q' -or $k.KeyChar -eq 'Q' -or $k.Key -eq [ConsoleKey]::Escape) { 
                    $running = $false 
                }
            }
            Start-Sleep -Milliseconds 1000
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

# --- MAIN LOOP ---

$smi = Get-NvidiaSmi
Write-Host "Initializing Nvidia Tool..." -ForegroundColor Green
$localInfo = Get-InstalledDriverInfo -SmiPath $smi
$latestVer = "Check Required"

do {
    Clear-Host
    
    $hagsStatus = Get-HagsStatus
    $vrrStatus = Get-VrrStatus
    $dlssStatus = Get-DlssIndicatorStatus
    
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
            $curClean = [version]($localInfo.Version -replace '[^\d.]')
            $latClean = [version]($latestVer -replace '[^\d.]')
            if ($curClean -and $latClean -and $curClean -ge $latClean) { 
                Write-Host "$latestVer (Up to Date)" -ForegroundColor Green 
            } else { 
                Write-Host "$latestVer (UPDATE AVAILABLE)" -ForegroundColor Red -BackgroundColor Yellow 
            }
        } catch {
            Write-Host "$latestVer" -ForegroundColor White
        }
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