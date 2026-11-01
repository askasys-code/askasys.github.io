# ==============================================================================
# SCRIPT:        Enterprise NVIDIA Hardware & DLSS Monitor (Clean & Armored)
# COMPATIBILITY: Windows 10 / Windows 11 (PowerShell 5.1 & PowerShell 7+)
# CODING STANDARD: All internal comments and UI strings must be written in ENGLISH.
# ==============================================================================

$ErrorActionPreference = "Continue"

# Configure console title
$Host.UI.RawUI.WindowTitle = "NVIDIA Monitor"

# ---------------------------------------------------------------------------
# NATIVE WIN32 INTEROP (Window Locking, Anti-Freeze & Native Metrics)
# ---------------------------------------------------------------------------
$InteropCode = @'
using System;
using System.Runtime.InteropServices;

public class NativeInterop {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    private static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);

    [DllImport("user32.dll")]
    private static extern bool DeleteMenu(IntPtr hMenu, uint uPosition, uint uFlags);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    public static extern int GetDeviceCaps(IntPtr hdc, int nIndex);

    [DllImport("psapi.dll")]
    public static extern bool EnumProcessModules(IntPtr hProcess, [Out] IntPtr[] lphModule, uint cb, out uint lpcbNeeded);

    [DllImport("psapi.dll", CharSet = CharSet.Unicode)]
    public static extern uint GetModuleBaseName(IntPtr hProcess, IntPtr hModule, [Out] System.Text.StringBuilder lpBaseName, uint nSize);

    [DllImport("kernel32.dll")]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);

    public static void DisableQuickEdit() {
        try {
            IntPtr hIn = GetStdHandle(-10); // STD_INPUT_HANDLE
            uint mode;
            if (GetConsoleMode(hIn, out mode)) {
                mode &= ~0x0040u; // ~ENABLE_QUICK_EDIT_MODE (Prevents freeze on click)
                mode |= 0x0080u;  // ENABLE_EXTENDED_FLAGS
                SetConsoleMode(hIn, mode);
            }
        } catch {}
    }

    public static void LockWindowFrame() {
        try {
            IntPtr hWnd = GetConsoleWindow();
            if (hWnd != IntPtr.Zero) {
                // Strip sizing border (WS_THICKFRAME) and maximize button (WS_MAXIMIZEBOX)
                int style = GetWindowLong(hWnd, -16);
                style &= ~0x00040000; // ~WS_THICKFRAME
                style &= ~0x00010000; // ~WS_MAXIMIZEBOX
                SetWindowLong(hWnd, -16, style);

                // Delete Resize and Maximize from system menu
                IntPtr hMenu = GetSystemMenu(hWnd, false);
                if (hMenu != IntPtr.Zero) {
                    DeleteMenu(hMenu, 0xF000, 0); // SC_SIZE
                    DeleteMenu(hMenu, 0xF030, 0); // SC_MAXIMIZE
                }

                // Force frame update
                SetWindowPos(hWnd, IntPtr.Zero, 0, 0, 0, 0, 0x0027); // SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER
            }
        } catch {}
    }

    public static void GetPhysicalResolution(out int width, out int height) {
        width = 0; height = 0;
        try {
            IntPtr hdc = GetDC(IntPtr.Zero);
            if (hdc != IntPtr.Zero) {
                width = GetDeviceCaps(hdc, 118);  // DESKTOPHORZRES (Unscaled physical pixels)
                height = GetDeviceCaps(hdc, 117); // DESKTOPVERTRES
                ReleaseDC(IntPtr.Zero, hdc);
            }
        } catch {}
    }
}
'@
try {
    Add-Type -TypeDefinition $InteropCode -ErrorAction SilentlyContinue
    [NativeInterop]::DisableQuickEdit()
} catch {}

# ---------------------------------------------------------------------------
# WINDOW LOCKING & GEOMETRY (Fixed 66x35 - Zero Scrollbars)
# ---------------------------------------------------------------------------
$Global:Cols = 66
$Global:Rows = 35

function Set-ArmoredConsole {
    $raw = $Host.UI.RawUI
    try {
        # Shrink window first so buffer resize does not throw errors
        $raw.WindowSize = New-Object System.Management.Automation.Host.Size(20, 20)
        $raw.BufferSize = New-Object System.Management.Automation.Host.Size($Global:Cols, $Global:Rows)
        $raw.WindowSize = New-Object System.Management.Automation.Host.Size($Global:Cols, $Global:Rows)
    } catch {}

    [NativeInterop]::LockWindowFrame()
    [NativeInterop]::DisableQuickEdit()
}

Set-ArmoredConsole

# ---------------------------------------------------------------------------
# CORE FUNCTION: NVIDIA-SMI TELEMETRY
# ---------------------------------------------------------------------------
function Find-NvidiaSmiBinary {
    $candidates = @(
        "$env:SystemRoot\System32\nvidia-smi.exe",
        "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    if (Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue) {
        return "nvidia-smi.exe"
    }
    return $null
}

$Global:SmiBin = Find-NvidiaSmiBinary

function Get-NvidiaGpuTelemetry {
    $telemetry = @{
        gpu_name     = "NVIDIA GeForce RTX"
        driver_ver   = "---"
        temp         = "---"
        temp_num     = 0.0
        fan          = "---"
        pwr_draw     = "---"
        pwr_lim      = "---"
        gpu_load     = "---"
        nvdec_load   = "---"
        nvenc_load   = "---"
        vram_use     = "---"
        vram_tot     = "---"
        clk_core     = "---"
        clk_mem      = "---"
        clk_max_core = "---"
        pstate       = "---"
        pcie_link    = "---"
    }

    if (-not $Global:SmiBin) { return $telemetry }

    try {
        $queryArgs = @(
            "--query-gpu=name,driver_version,temperature.gpu,fan.speed,power.draw,power.limit,utilization.gpu,utilization.decoder,utilization.encoder,memory.used,memory.total,clocks.gr,clocks.mem,clocks.max.gr,pstate,pcie.link.gen.current,pcie.link.width.current",
            "--format=csv,noheader,nounits"
        )
        $output = & $Global:SmiBin $queryArgs 2>$null

        if ($output) {
            $lines = @($output)
            if ($lines.Count -gt 0 -and (-not [string]::IsNullOrWhiteSpace($lines[0]))) {
                $rawFields = $lines[0].Split(',')
                $fields = @()
                foreach ($f in $rawFields) { $fields += $f.Trim() }

                if ($fields.Count -ge 17) {
                    $telemetry.gpu_name   = $fields[0]
                    $telemetry.driver_ver = $fields[1]
                    
                    [double]$tVal = 0.0
                    if ([double]::TryParse($fields[2], [ref]$tVal)) {
                        $telemetry.temp     = "$([int][Math]::Round($tVal))"
                        $telemetry.temp_num = $tVal
                    }

                    $fanRaw = $fields[3]
                    if ($fanRaw -in @("0", "0 %")) {
                        $telemetry.fan = "0% (Fan Stop)"
                    } elseif ($fanRaw -in @("[N/A]", "N/A", "")) {
                        $telemetry.fan = "N/A"
                    } else {
                        $telemetry.fan = "$fanRaw%"
                    }

                    # Wattage rounded to nearest integer
                    [double]$pDraw = 0.0
                    [double]$pLim  = 0.0
                    if ([double]::TryParse($fields[4], [ref]$pDraw)) {
                        $telemetry.pwr_draw = "$([int][Math]::Round($pDraw, [MidpointRounding]::AwayFromZero)) W"
                    }
                    if ([double]::TryParse($fields[5], [ref]$pLim))  {
                        $telemetry.pwr_lim  = "$([int][Math]::Round($pLim, [MidpointRounding]::AwayFromZero)) W"
                    }

                    $telemetry.gpu_load   = "$($fields[6])%"
                    $telemetry.nvdec_load = if ($fields[7] -match '\d+') { "$($Matches[0])%" } else { "0%" }
                    $telemetry.nvenc_load = if ($fields[8] -match '\d+') { "$($Matches[0])%" } else { "0%" }

                    [double]$vUsed = 0.0
                    [double]$vTot  = 0.0
                    if ([double]::TryParse($fields[9], [ref]$vUsed)) {
                        $telemetry.vram_use = "{0:N2} GB" -f ($vUsed / 1024.0)
                    }
                    if ([double]::TryParse($fields[10], [ref]$vTot)) {
                        $telemetry.vram_tot = "{0:N0} GB" -f [Math]::Round($vTot / 1024.0)
                    }

                    $telemetry.clk_core     = $fields[11]
                    $telemetry.clk_mem      = $fields[12]
                    $telemetry.clk_max_core = $fields[13]

                    $pst = $fields[14]
                    if ($pst -eq "P0") {
                        $telemetry.pstate = "P0 (Max Performance)"
                    } elseif ($pst -eq "P8" -or $pst -eq "P5" -or $pst -eq "P3") {
                        $telemetry.pstate = "$pst (Power Save)"
                    } else {
                        $telemetry.pstate = $pst
                    }

                    if ($fields[15] -ne "[N/A]" -and $fields[16] -ne "[N/A]") {
                        $telemetry.pcie_link = "PCIe Gen$($fields[15]) x$($fields[16])"
                    } else {
                        $telemetry.pcie_link = "PCIe Active"
                    }
                }
            }
        }
    } catch {}

    return $telemetry
}

# ---------------------------------------------------------------------------
# CORE FUNCTION: DLL PARSING
# ---------------------------------------------------------------------------
function Parse-DlssDllVersion ([string]$filePath) {
    if (-not $filePath -or -not (Test-Path -LiteralPath $filePath)) {
        return @{ VersionStr = $null }
    }

    $verStr = "Unknown"
    try {
        $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($filePath)
        if ($fvi.FileVersion) {
            $verStr = "v$($fvi.FileMajorPart).$($fvi.FileMinorPart).$($fvi.FileBuildPart).$($fvi.FilePrivatePart)"
        }
    } catch {}

    return @{ VersionStr = $verStr }
}

# ---------------------------------------------------------------------------
# CORE FUNCTION: TARGET PROCESS SCANNER & GRAPHICS API
# ---------------------------------------------------------------------------
$Global:CachedTarget = $null

function Find-TargetGameProcess {
    if ($Global:CachedTarget) {
        try {
            $procObj = Get-Process -Id $Global:CachedTarget.Pid -ErrorAction SilentlyContinue
            if ($procObj -and (-not $procObj.HasExited)) {
                $Global:CachedTarget.LoadedModules = Get-LoadedModuleNames $Global:CachedTarget.Pid
                return $Global:CachedTarget
            }
        } catch {}
        $Global:CachedTarget = $null
    }

    $ignored = @(
        'explorer', 'svchost', 'taskmgr', 'cmd', 'powershell', 'pwsh',
        'conhost', 'windowsterminal', 'idle', 'system', 'dwm', 'csrss',
        'lsass', 'services', 'smss', 'python', 'pythonw'
    )

    try {
        $windowProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.MainWindowHandle -ne [IntPtr]::Zero -and $ignored -notcontains $_.ProcessName.ToLower()
        }

        foreach ($p in $windowProcs) {
            $exePath = $null
            try { $exePath = $p.MainModule.FileName } catch {}
            if (-not $exePath -or -not (Test-Path -LiteralPath $exePath)) { continue }

            $gameDir = Split-Path -Parent $exePath
            $searchDirs = @($gameDir)
            foreach ($sub in @('Streamline', 'plugins', 'bin', 'x64')) {
                $subPath = Join-Path $gameDir $sub
                if (Test-Path -LiteralPath $subPath) { $searchDirs += $subPath }
            }

            $foundFiles = @{}
            foreach ($d in $searchDirs) {
                try {
                    Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | ForEach-Object {
                        $fn = $_.Name.ToLower()
                        if ($fn -in @('nvngx_dlss.dll', 'nvngx_dlssg.dll', 'nvngx_dlssd.dll', 'sl.interposer.dll', 'sl.dlss.dll', 'sl.dlss_g.dll', 'sl.dlss_d.dll')) {
                            if (-not $foundFiles.ContainsKey($fn)) {
                                $foundFiles[$fn] = $_.FullName
                            }
                        }
                    }
                } catch {}
            }

            if ($foundFiles.Count -gt 0) {
                $moduleSet = Get-LoadedModuleNames $p.Id

                # Strict API precedence: D3D12 has full priority over auxiliary D3D11 modules
                $detectedApi = "DirectX 12 (D3D12)"
                if ($moduleSet.Contains("d3d12.dll")) {
                    $detectedApi = "DirectX 12 (D3D12)"
                } elseif ($moduleSet.Contains("vulkan-1.dll") -or $moduleSet.Contains("winevulkan.dll")) {
                    $detectedApi = "Vulkan"
                } elseif ($moduleSet.Contains("d3d11.dll")) {
                    $detectedApi = "DirectX 11 (D3D11)"
                }

                $activeInMem = ($moduleSet.Contains("nvngx_dlss.dll") -or $moduleSet.Contains("sl.dlss.dll") -or $moduleSet.Contains("nvngx.dll"))

                $targetObj = [PSCustomObject]@{
                    Pid           = $p.Id
                    Name          = [System.IO.Path]::GetFileName($exePath)
                    Dir           = $gameDir
                    Files         = $foundFiles
                    LoadedModules = $moduleSet
                    ActiveInMem   = $activeInMem
                    GraphicsApi   = $detectedApi
                }

                $Global:CachedTarget = $targetObj
                return $targetObj
            }
        }
    } catch {}

    return $null
}

function Get-LoadedModuleNames ([int]$processId) {
    $set = New-Object System.Collections.Generic.HashSet[string]
    $hProc = [NativeInterop]::OpenProcess(0x0410, $false, $processId)
    if ($hProc -ne [IntPtr]::Zero) {
        try {
            $hMods = New-Object IntPtr[] 1024
            $cbNeeded = 0
            if ([NativeInterop]::EnumProcessModules($hProc, $hMods, [uint32]($hMods.Length * [IntPtr]::Size), [ref]$cbNeeded)) {
                $count = [Math]::Min(1024, [int]($cbNeeded / [IntPtr]::Size))
                $sb = New-Object System.Text.StringBuilder 260
                for ($i = 0; $i -lt $count; $i++) {
                    $sb.Clear() | Out-Null
                    if ([NativeInterop]::GetModuleBaseName($hProc, $hMods[$i], $sb, 260) -gt 0) {
                        [void]$set.Add($sb.ToString().ToLower())
                    }
                }
            }
        } finally {
            [NativeInterop]::CloseHandle($hProc) | Out-Null
        }
    }
    return $set
}

# ---------------------------------------------------------------------------
# CORE FUNCTION: PHYSICAL DISPLAY
# ---------------------------------------------------------------------------
function Get-DisplayMetrics {
    $w = 0; $h = 0
    try {
        [NativeInterop]::GetPhysicalResolution([ref]$w, [ref]$h)
    } catch {}

    if ($w -le 0 -or $h -le 0) {
        $w = 3840
        $h = 2160
    }

    $resStr = "$w x $h"

    $hzStr = "60 Hz"
    try {
        $gpuWmi = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.CurrentRefreshRate } | Select-Object -First 1
        if ($gpuWmi -and $gpuWmi.CurrentRefreshRate) {
            $roundedHz = [int][Math]::Round($gpuWmi.CurrentRefreshRate, [MidpointRounding]::AwayFromZero)
            if ($roundedHz -eq 59) { $roundedHz = 60 }
            $hzStr = "$roundedHz Hz"
        }
    } catch {}

    return @{ Resolution = $resStr; RefreshRate = $hzStr }
}

# ---------------------------------------------------------------------------
# CLEAN ROW RENDERING (Padded to 66 Columns)
# ---------------------------------------------------------------------------
function Write-FieldLine ([string]$label, [string]$value, [string]$color = "White") {
    $labelFormatted = "   {0,-18} : " -f $label
    Write-Host $labelFormatted -NoNewline -ForegroundColor Gray
    $valPadded = "{0,-41}" -f $value
    Write-Host $valPadded -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# MAIN MONITOR LOOP (Fixed Position - Zero Drift)
# ---------------------------------------------------------------------------
Clear-Host
try { [Console]::CursorVisible = $false } catch {}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    do {
        $stopwatch.Restart()

        $smi    = Get-NvidiaGpuTelemetry
        $target = Find-TargetGameProcess
        $disp   = Get-DisplayMetrics

        # Temperature threshold coloring
        $tempColor = "Green"
        if ($smi.temp_num -ge 82.0) {
            $tempColor = "Red"
        } elseif ($smi.temp_num -ge 72.0) {
            $tempColor = "Yellow"
        }

        # Core clock string
        $coreClockStr = "$($smi.clk_core) MHz"
        if ($smi.clk_max_core -and $smi.clk_max_core -notin @("---", "[N/A]", "")) {
            $coreClockStr += " (Max: $($smi.clk_max_core) MHz)"
        }

        # Status text
        $statusText  = "STANDBY (Waiting for 3D Application...)"
        $statusColor = "DarkGray"
        $targetName  = "None"
        $targetColor = "DarkGray"

        if ($target) {
            $targetName  = "$($target.Name) [PID: $($target.Pid)]"
            $targetColor = "Green"
            if ($target.ActiveInMem) {
                $statusText  = "ACTIVE - $($target.Name) [PID: $($target.Pid)]"
                $statusColor = "Green"
            } else {
                $statusText  = "LOADED - $($target.Name) [PID: $($target.Pid)]"
                $statusColor = "Yellow"
            }
        }

        # -------------------------------------------------------------------
        # DLSS IN-MEMORY TELEMETRY (Real Status Only - No Presets)
        # -------------------------------------------------------------------
        $srDisplay = "Not Detected"; $srColor = "DarkGray"
        $fgDisplay = "Not Detected"; $fgColor = "DarkGray"
        $rrDisplay = "Not Detected"; $rrColor = "DarkGray"

        if ($target) {
            $files   = $target.Files
            $modules = $target.LoadedModules

            $srPath = if ($files.ContainsKey("nvngx_dlss.dll")) { $files["nvngx_dlss.dll"] } else { $files["sl.dlss.dll"] }
            $fgPath = if ($files.ContainsKey("nvngx_dlssg.dll")) { $files["nvngx_dlssg.dll"] } else { $files["sl.dlss_g.dll"] }
            $rrPath = if ($files.ContainsKey("nvngx_dlssd.dll")) { $files["nvngx_dlssd.dll"] } else { $files["sl.dlss_d.dll"] }

            $srParsed = Parse-DlssDllVersion $srPath
            $fgParsed = Parse-DlssDllVersion $fgPath
            $rrParsed = Parse-DlssDllVersion $rrPath

            # 1. Super Resolution Check
            if ($srParsed.VersionStr) {
                if ($modules.Contains("nvngx_dlss.dll") -or $modules.Contains("sl.dlss.dll") -or $modules.Contains("nvngx.dll")) {
                    $srDisplay = "Active ($($srParsed.VersionStr))"
                    $srColor   = "Green"
                } else {
                    $srDisplay = "Inactive (Disabled in Game)"
                    $srColor   = "DarkGray"
                }
            } else {
                $srDisplay = "Not Installed"
                $srColor   = "DarkGray"
            }

            # 2. Frame Generation Check
            if ($fgParsed.VersionStr) {
                if ($modules.Contains("nvngx_dlssg.dll") -or $modules.Contains("sl.dlss_g.dll")) {
                    $fgDisplay = "Active ($($fgParsed.VersionStr))"
                    $fgColor   = "Green"
                } else {
                    $fgDisplay = "Inactive (Disabled in Game)"
                    $fgColor   = "DarkGray"
                }
            } else {
                $fgDisplay = "Not Installed"
                $fgColor   = "DarkGray"
            }

            # 3. Ray Reconstruction Check
            if ($rrParsed.VersionStr) {
                if ($modules.Contains("nvngx_dlssd.dll") -or $modules.Contains("sl.dlss_d.dll")) {
                    $rrDisplay = "Active ($($rrParsed.VersionStr))"
                    $rrColor   = "Green"
                } else {
                    $rrDisplay = "Inactive (Disabled in Game)"
                    $rrColor   = "DarkGray"
                }
            } else {
                $rrDisplay = "Not Installed"
                $rrColor   = "DarkGray"
            }
        }

        # Reset cursor position to top-left (Row 0, Col 0)
        [Console]::SetCursorPosition(0, 0)

        Write-Host "==================================================================" -ForegroundColor Cyan
        Write-Host "                  NVIDIA HARDWARE & DLSS MONITOR                  " -ForegroundColor White
        Write-Host "==================================================================" -ForegroundColor Cyan

        Write-FieldLine "GPU Device"        $smi.gpu_name "White"
        Write-FieldLine "Driver Version"    $smi.driver_ver "White"
        Write-FieldLine "Process Status"    $statusText $statusColor
        Write-FieldLine "Graphics API"      $(if ($target) { $target.GraphicsApi } else { "---" }) "White"

        Write-Host ""
        Write-Host "   GPU METRICS" -ForegroundColor Cyan
        Write-Host "   --------------------------------------------------------------" -ForegroundColor DarkGray
        Write-FieldLine "Core Clock"        $coreClockStr "Yellow"
        Write-FieldLine "Memory Clock"      "$($smi.clk_mem) MHz" "Yellow"
        Write-FieldLine "GPU Load"          $smi.gpu_load "White"
        Write-FieldLine "VRAM Allocated"    "$($smi.vram_use) / $($smi.vram_tot)" "White"
        Write-FieldLine "Video Dec / Enc"   "NVDEC: $($smi.nvdec_load) | NVENC: $($smi.nvenc_load)" "White"
        Write-FieldLine "GPU Temperature"   "$($smi.temp) C" $tempColor
        Write-FieldLine "Fan Speed"         $smi.fan "White"
        Write-FieldLine "Power Usage"       $smi.pwr_draw "Yellow"
        Write-FieldLine "Power Limit"       $smi.pwr_lim "DarkGray"
        Write-FieldLine "Power State"       $smi.pstate "Green"
        Write-FieldLine "PCIe Interface"    $smi.pcie_link "White"

        Write-Host ""
        Write-Host "   DLSS VERSION" -ForegroundColor Cyan
        Write-Host "   --------------------------------------------------------------" -ForegroundColor DarkGray
        Write-FieldLine "Target Process"    $targetName $targetColor
        Write-FieldLine "Super Resolution"  $srDisplay $srColor
        Write-FieldLine "Frame Generation"  $fgDisplay $fgColor
        Write-FieldLine "Ray Reconstruct"   $rrDisplay $rrColor

        Write-Host ""
        Write-Host "   DISPLAY" -ForegroundColor Cyan
        Write-Host "   --------------------------------------------------------------" -ForegroundColor DarkGray
        Write-FieldLine "Display Output"    "$($disp.Resolution) @ $($disp.RefreshRate)" "White"

        Write-Host "==================================================================" -ForegroundColor Cyan
        # Final row without trailing newline to strictly prevent buffer auto-scrolling
        Write-Host "   [C] Copy Snapshot     [R] Refresh Now     [0] Exit     " -ForegroundColor Gray -NoNewline

        # Precision 1-second interval
        while ($stopwatch.ElapsedMilliseconds -lt 1000) {
            try {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -in @([ConsoleKey]::D0, [ConsoleKey]::NumPad0, [ConsoleKey]::Q, [ConsoleKey]::Escape)) {
                        Clear-Host
                        exit 0
                    }
                    if ($k.Key -eq [ConsoleKey]::C) {
                        $snapshotText = @"
==================================================================
NVIDIA HARDWARE & DLSS MONITOR SNAPSHOT
==================================================================
GPU Device          : $($smi.gpu_name)
Driver Version      : $($smi.driver_ver)
Process Status      : $statusText
Graphics API        : $(if ($target) { $target.GraphicsApi } else { '---' })
Core Clock          : $coreClockStr
Memory Clock        : $($smi.clk_mem) MHz
GPU Load            : $($smi.gpu_load)
VRAM Allocated      : $($smi.vram_use) / $($smi.vram_tot)
Video Dec / Enc     : NVDEC: $($smi.nvdec_load) | NVENC: $($smi.nvenc_load)
GPU Temperature     : $($smi.temp) C
Fan Speed           : $($smi.fan)
Power Usage         : $($smi.pwr_draw)
Power Limit         : $($smi.pwr_lim)
Power State         : $($smi.pstate)
PCIe Interface      : $($smi.pcie_link)
Target Process      : $targetName
Super Resolution    : $srDisplay
Frame Generation    : $fgDisplay
Ray Reconstruction  : $rrDisplay
Display Output      : $($disp.Resolution) @ $($disp.RefreshRate)
==================================================================
"@
                        try {
                            Set-Clipboard -Value $snapshotText -ErrorAction Stop
                        } catch {
                            & cmd.exe /c "echo $snapshotText | clip"
                        }
                        break
                    }
                    if ($k.Key -eq [ConsoleKey]::R) {
                        break
                    }
                }
            } catch {}
            Start-Sleep -Milliseconds 40
        }
    } while ($true)
} finally {
    try { [Console]::CursorVisible = $true } catch {}
}