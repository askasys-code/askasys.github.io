<#
================================================================================
.SYNOPSIS
    NVIDIA Driver Telemetry Removal & Verification Script.

.DESCRIPTION
    Disables NVIDIA telemetry tasks, stops secondary tracking services,
    sets anti-telemetry registry flags, neutralizes telemetry plugin DLLs,
    and performs a full post-execution verification audit.

.NOTES
    - Safe & reversible: Display driver and Control Panel remain 100% functional.
    - Interactive: The window stays open until you press Enter.
================================================================================
#>

# ------------------------------------------------------------------------------
# 0. Administrator Privileges Check
# ------------------------------------------------------------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "`n[!] ERROR: Administrator rights required." -ForegroundColor Red
    Write-Host "Please right-click the script and select 'Run with PowerShell as Administrator'." -ForegroundColor Yellow
    Write-Host "`nPress Enter to exit..." -ForegroundColor Gray
    [void][System.Console]::ReadLine()
    Exit 1
}

Clear-Host
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  NVIDIA Telemetry Removal & Hardening Script           " -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# STEP 1: Disable NVIDIA Telemetry & Crash Reporter Scheduled Tasks
# ------------------------------------------------------------------------------
Write-Host "[1/5] Disabling NVIDIA Telemetry Scheduled Tasks..." -ForegroundColor Yellow

$TelemetryTaskPatterns = @(
    "NvTmRep*",
    "NvTmMon*",
    "NvDriverUpdateCheckDaily*",
    "NvProfileUpdaterDaily*",
    "NvNode*"
)

foreach ($Pattern in $TelemetryTaskPatterns) {
    $Tasks = Get-ScheduledTask -TaskPath "\" -TaskName $Pattern -ErrorAction SilentlyContinue
    if ($Tasks) {
        foreach ($Task in $Tasks) {
            Disable-ScheduledTask -TaskName $Task.TaskName -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  [-] Disabled Task: $($Task.TaskName)" -ForegroundColor Green
        }
    }
}

# ------------------------------------------------------------------------------
# STEP 2: Stop & Disable Standalone Telemetry Services
# ------------------------------------------------------------------------------
Write-Host "`n[2/5] Checking for standalone telemetry services..." -ForegroundColor Yellow

$TargetServices = @("NvTelemetryContainer")

foreach ($ServiceName in $TargetServices) {
    $Service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($Service) {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host "  [-] Service stopped and disabled: $ServiceName" -ForegroundColor Green
    } else {
        Write-Host "  [i] Service not found (clean): $ServiceName" -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------------------------------
# STEP 3: Configure Registry Flags (Opt-out from Data Collection & FTS)
# ------------------------------------------------------------------------------
Write-Host "`n[3/5] Applying anti-telemetry registry policies..." -ForegroundColor Yellow

$RegistryPaths = @(
    "HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS",
    "HKLM:\SOFTWARE\NVIDIA Corporation\NvTelemetry",
    "HKLM:\SOFTWARE\NVIDIA Corporation\Global\Startup"
)

foreach ($Path in $RegistryPaths) {
    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

$RegValues = @(
    @{ Path = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS"; Name = "EnableRID44231"; Value = 0 },
    @{ Path = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS"; Name = "EnableRID64640"; Value = 0 },
    @{ Path = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS"; Name = "EnableRID66610"; Value = 0 },
    @{ Path = "HKLM:\SOFTWARE\NVIDIA Corporation\NvTelemetry"; Name = "NdrTelemetry"; Value = 0 },
    @{ Path = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\Startup"; Name = "SendCustomerExperienceData"; Value = 0 }
)

foreach ($Item in $RegValues) {
    Set-ItemProperty -Path $Item.Path -Name $Item.Name -Value $Item.Value -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Host "  [-] Applied Registry Value: $($Item.Path)\$($Item.Name) = 0" -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# STEP 4: Neutralize Container Plugin DLLs
# ------------------------------------------------------------------------------
Write-Host "`n[4/5] Neutralizing telemetry plugin libraries inside NvContainer..." -ForegroundColor Yellow

$ContainerService = "NVDisplay.ContainerLocalSystem"
Stop-Service -Name $ContainerService -Force -ErrorAction SilentlyContinue

$PluginDirectories = @(
    "$env:ProgramFiles\NVIDIA Corporation\Display.NvContainer\plugins\LocalSystem",
    "$env:ProgramFiles(x86)\NVIDIA Corporation\Display.NvContainer\plugins\LocalSystem"
)

$TelemetryDllFilters = @(
    "*telemetry*.dll",
    "*profileupdaterplugin*.dll"
)

foreach ($Dir in $PluginDirectories) {
    if (Test-Path -Path $Dir) {
        foreach ($Filter in $TelemetryDllFilters) {
            $Dlls = Get-ChildItem -Path $Dir -Filter $Filter -File -ErrorAction SilentlyContinue
            foreach ($Dll in $Dlls) {
                if (-not $Dll.Name.EndsWith(".disabled")) {
                    $NewName = "$($Dll.Name).disabled"
                    Rename-Item -Path $Dll.FullName -NewName $NewName -Force -ErrorAction SilentlyContinue
                    Write-Host "  [-] Neutralized DLL: $($Dll.Name) -> $NewName" -ForegroundColor Green
                }
            }
        }
    }
}

# ------------------------------------------------------------------------------
# STEP 5: Restart Display Container Service
# ------------------------------------------------------------------------------
Write-Host "`n[5/5] Restarting essential display container..." -ForegroundColor Yellow

Start-Service -Name $ContainerService -ErrorAction SilentlyContinue

# ==============================================================================
# POST-EXECUTION AUDIT & VERIFICATION
# ==============================================================================
Write-Host "`n========================================================" -ForegroundColor Magenta
Write-Host "  POST-EXECUTION VERIFICATION & AUDIT                   " -ForegroundColor Magenta
Write-Host "========================================================" -ForegroundColor Magenta

# Audit 1: Scheduled Tasks
$ActiveTelemetryTasks = 0
foreach ($Pattern in $TelemetryTaskPatterns) {
    $RemainingTasks = Get-ScheduledTask -TaskPath "\" -TaskName $Pattern -ErrorAction SilentlyContinue | Where-Object { $_.State -ne "Disabled" }
    if ($RemainingTasks) {
        $ActiveTelemetryTasks += $RemainingTasks.Count
        foreach ($T in $RemainingTasks) {
            Write-Host "  [FAIL] Task still active: $($T.TaskName)" -ForegroundColor Red
        }
    }
}
if ($ActiveTelemetryTasks -eq 0) {
    Write-Host "  [PASS] All NVIDIA Telemetry Scheduled Tasks are DISABLED." -ForegroundColor Green
}

# Audit 2: Telemetry Services
$ActiveServices = Get-Service -Name "NvTelemetryContainer" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Running" -or $_.StartType -ne "Disabled" }
if (-not $ActiveServices) {
    Write-Host "  [PASS] Standalone Telemetry Service is INACTIVE / DISABLED." -ForegroundColor Green
} else {
    Write-Host "  [FAIL] NvTelemetryContainer service is still active." -ForegroundColor Red
}

# Audit 3: Registry Policies
$RegCheckFailed = 0
foreach ($Item in $RegValues) {
    $CurrentVal = (Get-ItemProperty -Path $Item.Path -Name $Item.Name -ErrorAction SilentlyContinue).$($Item.Name)
    if ($CurrentVal -ne 0) {
        $RegCheckFailed++
        Write-Host "  [FAIL] Registry mismatch: $($Item.Path)\$($Item.Name) is not 0" -ForegroundColor Red
    }
}
if ($RegCheckFailed -eq 0) {
    Write-Host "  [PASS] All Anti-Telemetry Registry keys are active (Value = 0)." -ForegroundColor Green
}

# Audit 4: Un-neutralized DLLs
$ActiveTelemetryDlls = 0
foreach ($Dir in $PluginDirectories) {
    if (Test-Path -Path $Dir) {
        foreach ($Filter in $TelemetryDllFilters) {
            $RawDlls = Get-ChildItem -Path $Dir -Filter $Filter -File -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.EndsWith(".disabled") }
            if ($RawDlls) {
                $ActiveTelemetryDlls += $RawDlls.Count
                foreach ($D in $RawDlls) {
                    Write-Host "  [FAIL] Active DLL detected: $($D.FullName)" -ForegroundColor Red
                }
            }
        }
    }
}
if ($ActiveTelemetryDlls -eq 0) {
    Write-Host "  [PASS] No active Telemetry DLL plugins found in NvContainer." -ForegroundColor Green
}

# Audit 5: Essential Core Container State
$CoreContainerStatus = (Get-Service -Name $ContainerService -ErrorAction SilentlyContinue).Status
if ($CoreContainerStatus -eq "Running") {
    Write-Host "  [PASS] Core Display Container is RUNNING securely (Display/G-Sync intact)." -ForegroundColor Green
} else {
    Write-Host "  [WARN] Core Display Container is currently: $CoreContainerStatus" -ForegroundColor Yellow
}

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Process finished. Telemetry has been neutralized.      " -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# Prevent automatic window closing
# ------------------------------------------------------------------------------
Write-Host "Press Enter to exit..." -ForegroundColor Gray
[void][System.Console]::ReadLine()