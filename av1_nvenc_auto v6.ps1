# --------------------------------------------------------
# UNIFIED AV1 NVENC ENCODER (Batch Processing) - V10
# FIX: False Positive Error Detection fixed
# PowerShell 5.1 Compatible
# --------------------------------------------------------

# Set console to UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Path Configuration
$HB = "E:\Binaries\HandBrakeCLI\HandBrakeCLI.exe"
$MI = "E:\Binaries\MediaInfoCLI\MediaInfo.exe"
$OutputDir = Join-Path $PSScriptRoot "output"
$LogFile = Join-Path $OutputDir "encoding_log.txt"

# Binary Verification
if (!(Test-Path $HB)) { Write-Error "HandBrakeCLI not found at $HB"; pause; exit }
if (!(Test-Path $MI)) { Write-Error "MediaInfoCLI not found at $MI"; pause; exit }

# Create Output Directory
if (!(Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

# ========================================================
#  UI & PROFILE SELECTION
# ========================================================
Clear-Host
Write-Host "==============================================================================" -ForegroundColor Yellow
Write-Host "                       AV1 NVENC BATCH ENCODER (V10)                          " -ForegroundColor Yellow
Write-Host "==============================================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  PROFILE 1: STANDARD EFFICIENCY (Best for Viewing)" -ForegroundColor Cyan
Write-Host "  -------------------------------------------------" -ForegroundColor Gray
Write-Host "  [Target]   Optimal balance between file size and visual quality."
Write-Host "  [Video]    AV1 10-bit | Adaptive CQ (28-34) | TemporalAQ"
Write-Host "  [Audio]    Opus (High efficiency, Surround kept)"
Write-Host "  [Filters]  Adaptive Deinterlace + (Optional) Noise Reduction"
Write-Host ""
Write-Host "  PROFILE 2: ARCHIVAL MASTER (Best for Preservation)" -ForegroundColor Magenta
Write-Host "  --------------------------------------------------" -ForegroundColor Gray
Write-Host "  [Target]   Mathematical near-source preservation."
Write-Host "  [Video]    AV1 10-bit | Low CQ (18-20) | Max Fidelity"
Write-Host "  [Audio]    FLAC 24-bit (Lossless Original)"
Write-Host "  [Filters]  Adaptive Deinterlace (If needed). NO Noise Reduction."
Write-Host ""
Write-Host "==============================================================================" -ForegroundColor Yellow

$Selection = Read-Host " Select Profile [1] or [2]"

if ($Selection -eq "2") {
    $Mode = "Archival"
    $Suffix = "_av1_lossless.mkv"
    $UseDenoise = $false
    Write-Host "`n >> SELECTED: ARCHIVAL MODE" -ForegroundColor Magenta
} else {
    $Mode = "Standard"
    $Suffix = "_av1.mkv"
    Write-Host "`n >> SELECTED: STANDARD MODE" -ForegroundColor Cyan
    
    Write-Host "`n [DVD DENOISE OPTION]" -ForegroundColor Yellow
    Write-Host " DVDs often contain analog 'noise' that inflates file size."
    Write-Host " - Press 'Y' to enable NLMeans Light (Cleaner, Smaller)."
    Write-Host " - Press 'N' to disable (Preserves grain, Larger)."
    $DenoiseChoice = Read-Host " Enable Denoise filter? [Y/N]"
    
    if ($DenoiseChoice -eq 'Y' -or $DenoiseChoice -eq 'y') {
        $UseDenoise = $true
        Write-Host " >> DENOISE: ENABLED (Light)" -ForegroundColor Green
    } else {
        $UseDenoise = $false
        Write-Host " >> DENOISE: DISABLED (Grain Preserved)" -ForegroundColor Red
    }
}

Start-Sleep -Seconds 2

# ========================================================
#  FILE SEARCH
# ========================================================
$FileExtensions = "*.mkv", "*.mp4", "*.avi", "*.mov", "*.ts", "*.m2ts", "*.flv", "*.wmv", "*.vob", "*.iso"
$Files = Get-ChildItem -Path "$PSScriptRoot\*" -Include $FileExtensions -File

if ($Files.Count -eq 0) {
    Write-Warning "No video files found in this directory."
    pause
    exit
}

Write-Host "========================================================"
Write-Host " STARTING BATCH PROCESSING ($Mode)"
Write-Host " Found $($Files.Count) files."
Write-Host "========================================================"

foreach ($File in $Files) {
    if ($File.DirectoryName -eq $OutputDir) { continue }

    $OutputFile = Join-Path $OutputDir ($File.BaseName + $Suffix)
    
    if (Test-Path $OutputFile) { 
        Write-Host "Skipping: $($File.Name) (Output exists)" -ForegroundColor DarkGray
        continue 
    }

    # --------------------------------------------------------
    # METADATA EXTRACTION
    # --------------------------------------------------------
    $ScanType = & $MI --Inform="Video;%ScanType%" $File.FullName
    $SourceMedium = & $MI --Inform="General;%OriginalSourceMedium%" $File.FullName
    $HeightStr = & $MI --Inform="Video;%Height%" $File.FullName
    $ChannelsStr = & $MI --Inform="Audio;%Channels%" $File.FullName

    $Height = if ($HeightStr -match '\d+') { [int]$Matches[0] } else { 480 }
    $Channels = if ($ChannelsStr -match '\d+') { [int]$Matches[0] } else { 2 }

    # --------------------------------------------------------
    # 1. QUANTIZATION LOGIC
    # --------------------------------------------------------
    if ($Mode -eq "Archival") {
        $Quality = if ($Height -ge 1080) { 20 } else { 18 }
    } else {
        $Quality = if ($Height -ge 2160) { 34 }      # 4K
                   elseif ($Height -ge 1440) { 32 }  # 1440p
                   elseif ($Height -ge 1080) { 30 }  # 1080p
                   elseif ($Height -ge 720) { 28 }   # 720p
                   else { 28 }                       # SD
    }

    # --------------------------------------------------------
    # 2. AUDIO LOGIC
    # --------------------------------------------------------
    if ($Mode -eq "Archival") {
        $AudioArgs = @("--aencoder", "flac24", "--all-audio")
        $AudioDesc = "FLAC"
    } else {
        $AudioDesc = "Opus"
        if ($Channels -le 2) {
            $AudioArgs = @("--aencoder", "opus", "--ab", "160", "--mixdown", "stereo", "--all-audio")
        } elseif ($Channels -le 6) {
            $AudioArgs = @("--aencoder", "opus", "--ab", "256", "--mixdown", "5point1", "--all-audio")
        } else {
            $AudioArgs = @("--aencoder", "opus", "--ab", "320", "--mixdown", "7point1", "--all-audio")
        }
    }

    # --------------------------------------------------------
    # 3. FILTER LOGIC
    # --------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($ScanType) -or $ScanType -eq "Progressive") {
        $FilterArgs = @() 
        $FilterDesc = "None (Source is Progressive)"
    } elseif ($SourceMedium -eq "DVD-Video") {
        $FilterArgs = @("--detelecine", "--comb-detect", "--decomb=bob", "--vfr")
        if ($UseDenoise) {
            $FilterArgs += "--nlmeans=light"
            $FilterDesc = "Detelecine + Decomb + NLMeans(Light)"
        } else {
            $FilterDesc = "Detelecine + Decomb (Grain Preserved)"
        }
    } else {
        $FilterArgs = @("--comb-detect", "--decomb=bob", "--vfr")
        $FilterDesc = "Decomb Bob"
    }

    # --------------------------------------------------------
    # 4. EXECUTION
    # --------------------------------------------------------
    Write-Host "`n[FILE] $($File.Name)" -ForegroundColor Cyan
    Write-Host "INFO: Mode: $Mode | CQ: $Quality | Audio: $AudioDesc" -ForegroundColor Gray
    Write-Host "INFO: Filter: $FilterDesc" -ForegroundColor DarkGray

    $HBArgs = @(
        "-i", "`"$($File.FullName)`"",
        "-o", "`"$OutputFile`"",
        "-f", "mkv",
        "--encoder", "nvenc_av1_10bit",
        "--encoder-preset", "slowest",
        "--quality", $Quality,
        "--encopts", "temporal-aq=1",
        "--all-subtitles",
        "--markers"
    ) + $FilterArgs + $AudioArgs

    $FullCmd = "& `"$HB`" $($HBArgs -join ' ') 2>&1"
    
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ErrorOccurred = $false

    # FIX: Smart Error Detection (Ignores "0 decoder errors")
    Invoke-Expression $FullCmd | ForEach-Object {
        $Line = $_.ToString()
        
        # Display Progress
        if ($Line -match "(\d+\.\d+ %).*\((\d+\.\d+ fps)") {
            Write-Host -NoNewline "`rProgress: $($Matches[1]) | Speed: $($Matches[2])       "
        } 
        # Check for REAL errors, ignoring "0 errors" success messages
        elseif ($Line -match "error" -or $Line -match "failure") {
            if ($Line -notmatch "0 decoder errors" -and $Line -notmatch "0 errors") {
                Write-Host "`n[HB ERROR] $Line" -ForegroundColor Red
                $ErrorOccurred = $true
            }
        }
    }
    $sw.Stop()

    # Final Verification: Did we create a valid file?
    if ($ErrorOccurred -or !(Test-Path $OutputFile) -or (Get-Item $OutputFile).Length -eq 0) {
        Write-Host "`n[FAILED] Encoding failed for $($File.Name). Check arguments." -ForegroundColor Red
    } else {
        $LogDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $LogLine = "[$LogDate] [$Mode] File: $($File.Name) | Denoise: $UseDenoise | Time: $($sw.Elapsed.ToString('hh\:mm\:ss'))"
        Add-Content -Path $LogFile -Value $LogLine -Encoding UTF8
        Write-Host "`r[DONE] $($File.Name) - Time: $($sw.Elapsed.ToString('hh\:mm\:ss'))        " -ForegroundColor Green
    }
}

Write-Host "`n========================================================"
Write-Host " ALL OPERATIONS COMPLETED."
Write-Host " Log saved to: $LogFile"
Write-Host "========================================================"
pause