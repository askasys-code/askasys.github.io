# ==============================================================================
# SAVE DATA KEEPER - CLI Version (Cumulative Cross-PC Sync & Timestamps)
# ==============================================================================

# Define paths safely
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = (Get-Location).Path
}

$pathsFile = Join-Path $scriptDir "paths.txt"
$defaultDestination = $scriptDir

# Helper function to compute human-readable relative age (Fixed syntax)
function Get-RelativeAge ([datetime]$date) {
    $now = Get-Date
    $span = $now - $date
    if ($span.TotalSeconds -lt 0) {
        return "appena creato"
    }
    if ($span.TotalMinutes -lt 1) { 
        return "meno di 1 minuto fa" 
    }
    if ($span.TotalMinutes -lt 60) {
        $m = [math]::Floor($span.TotalMinutes)
        if ($m -le 1) { return "1 minuto fa" }
        return "$m minuti fa"
    }
    if ($span.TotalHours -lt 24) {
        $h = [math]::Floor($span.TotalHours)
        if ($h -le 1) { return "1 ora fa" }
        return "$h ore fa"
    }
    if ($span.TotalDays -lt 2) {
        return "ieri"
    }
    if ($span.TotalDays -lt 30) {
        $d = [math]::Floor($span.TotalDays)
        return "$d giorni fa"
    }
    if ($span.TotalDays -lt 365) {
        $months = [math]::Floor($span.TotalDays / 30)
        if ($months -le 1) { return "1 mese fa" }
        return "$months mesi fa"
    }
    $y = [math]::Floor($span.TotalDays / 365)
    if ($y -le 1) { return "1 anno fa" }
    return "$y anni fa"
}

# Function to read and parse the custom game configuration
function Get-GamesConfig {
    if (-not (Test-Path -LiteralPath $pathsFile)) {
        $templateContent = "# Format: Game Title = Folder Path`n" +
                            "# Relative paths will start automatically from your user profile (C:\Users\Username).`n" +
                            "# Lines starting with # are comments and will be ignored.`n`n" +
                            "The Witcher 3 = Documents\The Witcher 3`n" +
                            "Steam Shared = C:\Users\Public\Documents\Steam`n" +
                            "Granblue Fantasy Relink = AppData\Local\GBFR"
        Set-Content -Path $pathsFile -Value $templateContent -Encoding UTF8
        Write-Host "Created a template 'paths.txt'. Please edit it to configure your games." -ForegroundColor Yellow
        return @()
    }
    
    $lines = Get-Content -LiteralPath $pathsFile | Where-Object {
        $_ -and $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$'
    }
    
    $games = @()
    foreach ($line in $lines) {
        $line = $line.Trim()
        if ($line -match '^([^=]+)=(.*)$') {
            $name = $Matches[1].Trim()
            $rawPath = $Matches[2].Trim()
        } else {
            $rawPath = $line
            $name = Split-Path $rawPath -Leaf
            if ([string]::IsNullOrEmpty($name)) {
                $name = Split-Path (Split-Path $rawPath -Parent) -Leaf
            }
        }
        
        # Calculate portable path (cross-PC compatible without hardcoded username)
        if ([System.IO.Path]::IsPathRooted($rawPath)) {
            $resolvedPath = $rawPath
            if ($resolvedPath.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rel = $resolvedPath.Substring($env:USERPROFILE.Length).TrimStart('\', '/')
            } else {
                $drive = [System.IO.Path]::GetPathRoot($resolvedPath)
                $driveLetter = ($drive -replace '[:\\/]', '').Trim()
                if ([string]::IsNullOrWhiteSpace($driveLetter)) {
                    $driveLetter = "Drive"
                }
                $rel = Join-Path "Drive_$driveLetter" ($resolvedPath.Substring($drive.Length).TrimStart('\', '/'))
            }
        } else {
            $resolvedPath = Join-Path $env:USERPROFILE $rawPath
            $rel = $rawPath.TrimStart('\', '/')
        }
        
        try {
            if (Test-Path -LiteralPath $resolvedPath) {
                [string]$fullPath = (Resolve-Path -LiteralPath $resolvedPath).Path
            } else {
                [string]$fullPath = [System.IO.Path]::GetFullPath($resolvedPath)
            }
        } catch {
            [string]$fullPath = $resolvedPath
        }

        # Legacy relative path (for backward compatibility with older backups containing Users\Username\...)
        $driveRoot = [System.IO.Path]::GetPathRoot($fullPath)
        [string]$legacyRel = ""
        if ($fullPath.Length -ge $driveRoot.Length) {
            $legacyRel = $fullPath.Substring($driveRoot.Length).TrimStart('\', '/')
        } else {
            $legacyRel = $fullPath
        }

        $games += [PSCustomObject]@{
            Name               = [string]$name
            FullPath           = [string]$fullPath
            RelativePath       = [string]$rel
            LegacyRelativePath = [string]$legacyRel
        }
    }
    return $games
}

# Scan destination for existing backups with Smart Date Detection
function Get-AvailableBackups {
    param ([string]$destination)
    if (-not (Test-Path -LiteralPath $destination)) { return @() }
    
    $folders = Get-ChildItem -LiteralPath $destination -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Backup*" }
    $zips = Get-ChildItem -LiteralPath $destination -File -Filter "*.zip" -ErrorAction SilentlyContinue
    
    $allBackups = @()
    if ($folders) {
        foreach ($f in $folders) {
            $bDate = $f.LastWriteTime
            if ($f.Name -match 'Backup_(\d{8})_(\d{6})') {
                try {
                    $bDate = [datetime]::ParseExact($matches[1] + $matches[2], "yyyyMMddHHmmss", [System.Globalization.CultureInfo]::InvariantCulture)
                } catch {}
            }
            $allBackups += [PSCustomObject]@{
                Name      = [string]$f.Name
                FullPath  = [string]$f.FullName
                Type      = "Folder"
                LastWrite = $bDate
            }
        }
    }
    if ($zips) {
        foreach ($z in $zips) {
            $bDate = $z.LastWriteTime
            if ($z.Name -match 'Backup_(\d{8})_(\d{6})') {
                try {
                    $bDate = [datetime]::ParseExact($matches[1] + $matches[2], "yyyyMMddHHmmss", [System.Globalization.CultureInfo]::InvariantCulture)
                } catch {}
            }
            $allBackups += [PSCustomObject]@{
                Name      = [string]$z.Name
                FullPath  = [string]$z.FullName
                Type      = "ZIP File"
                LastWrite = $bDate
            }
        }
    }
    
    if ($allBackups.Count -gt 0) {
        return ($allBackups | Sort-Object LastWrite -Descending)
    }
    return @()
}

# Main function to run backup (Normal or ZIP) - CUMULATIVE & NEVER DROPS GAMES
function Start-Backup {
    param (
        [string]$destination,
        [switch]$Zip
    )

    $games = @(Get-GamesConfig)
    if ($games.Count -eq 0) {
        Write-Host "Error: No games configured in '$pathsFile'." -ForegroundColor Red
        return
    }

    if (-not (Test-Path -LiteralPath $destination)) {
        try {
            New-Item -Path $destination -ItemType Directory -Force | Out-Null
        } catch {
            Write-Host "Failed to create destination directory: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $stagingDir = Join-Path $env:TEMP "BackupStaging_$timestamp"
    if (Test-Path -LiteralPath $stagingDir) {
        Remove-Item -LiteralPath $stagingDir -Recurse -Force | Out-Null
    }
    New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null

    try {
        # Check for previous backup to accumulate from
        $existingBackups = @(Get-AvailableBackups -destination $destination)
        if ($existingBackups.Count -gt 0) {
            $latest = $existingBackups[0]
            $latestDateStr = $latest.LastWrite.ToString("dd/MM/yyyy HH:mm")
            $latestAgeStr = Get-RelativeAge $latest.LastWrite
            Write-Host "`n[ACCUMULATION] Found previous backup: '$($latest.Name)'" -ForegroundColor Cyan
            Write-Host " -> Date: $latestDateStr ($latestAgeStr)" -ForegroundColor Gray
            Write-Host "Inheriting previous saves so no games from other PCs are lost..." -ForegroundColor Gray
            
            if ($latest.Type -eq "ZIP File") {
                Expand-Archive -LiteralPath $latest.FullPath -DestinationPath $stagingDir -Force
            } else {
                Copy-Item -Path "$($latest.FullPath)\*" -Destination $stagingDir -Recurse -Force
            }
        } else {
            Write-Host "`n[NEW BACKUP SET] No previous backup found. Creating first master backup..." -ForegroundColor Cyan
        }

        Write-Host "`nProcessing configured games on this PC:" -ForegroundColor Cyan
        foreach ($game in $games) {
            $targetStaging = Join-Path $stagingDir $game.RelativePath
            
            if (Test-Path -LiteralPath $game.FullPath) {
                # Game is present on this PC: Update/Add it to the backup
                if ((Get-Item -LiteralPath $game.FullPath) -is [System.IO.DirectoryInfo]) {
                    if (-not (Test-Path -LiteralPath $targetStaging)) {
                        New-Item -Path $targetStaging -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -Path "$($game.FullPath)\*" -Destination $targetStaging -Recurse -Force
                } else {
                    $parentStaging = Split-Path $targetStaging -Parent
                    if (-not (Test-Path -LiteralPath $parentStaging)) {
                        New-Item -Path $parentStaging -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -LiteralPath $game.FullPath -Destination $targetStaging -Force
                }
                Write-Host " [Added/Updated]  '$($game.Name)' (from this PC)" -ForegroundColor Green
            } else {
                # Game not on this PC: check if it was preserved from another PC
                $leafName = Split-Path $game.FullPath -Leaf
                $preserved = (Test-Path -LiteralPath $targetStaging) -or 
                             (Test-Path -LiteralPath (Join-Path $stagingDir $leafName)) -or 
                             (Test-Path -LiteralPath (Join-Path $stagingDir $game.LegacyRelativePath))

                if ($preserved) {
                    Write-Host " [Preserved]      '$($game.Name)' (kept from another PC/backup)" -ForegroundColor Cyan
                } else {
                    Write-Host " [Not Found]      '$($game.Name)' (not on PC nor in previous backup)" -ForegroundColor DarkGray
                }
            }
        }

        $stagedItems = Get-ChildItem -LiteralPath $stagingDir -Force
        if (-not $stagedItems -or $stagedItems.Count -eq 0) {
            Write-Host "`nWarning: No save files found to back up." -ForegroundColor Yellow
            return
        }

        # Save to Destination
        if ($Zip) {
            $zipFileName = "Backup_$timestamp.zip"
            $zipFilePath = Join-Path $destination $zipFileName
            if (Test-Path -LiteralPath $zipFilePath) {
                Remove-Item -LiteralPath $zipFilePath -Force | Out-Null
            }
            Write-Host "`nCompressing cumulative archive..." -ForegroundColor Cyan
            Compress-Archive -LiteralPath ($stagedItems.FullName) -DestinationPath $zipFilePath -Force
            Write-Host "Cumulative ZIP backup completed! Saved to: $zipFilePath" -ForegroundColor Green
        } else {
            $backupRoot = Join-Path $destination "Backup_$timestamp"
            New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
            Copy-Item -Path "$stagingDir\*" -Destination $backupRoot -Recurse -Force
            Write-Host "`nCumulative folder backup completed! Saved to: $backupRoot" -ForegroundColor Green
        }
    } catch {
        Write-Host "Error during backup: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        if (Test-Path -LiteralPath $stagingDir) {
            Remove-Item -LiteralPath $stagingDir -Recurse -Force | Out-Null
        }
    }
}

# Function to display path configuration status with colors
function Show-CurrentPaths {
    Write-Host "`n--- CONFIGURATED GAMES STATUS ---" -ForegroundColor Cyan
    $games = @(Get-GamesConfig)
    if ($games.Count -eq 0) {
        Write-Host "No games configured or 'paths.txt' is empty." -ForegroundColor Yellow
        return
    }
    foreach ($game in $games) {
        if (Test-Path -LiteralPath $game.FullPath) {
            Write-Host " [Found]     " -NoNewline -ForegroundColor Green
            Write-Host "$($game.Name)" -ForegroundColor Yellow
        } else {
            Write-Host " [Not Found] " -NoNewline -ForegroundColor Red
            Write-Host "$($game.Name)" -ForegroundColor Red
        }
    }
    Write-Host "---------------------------------" -ForegroundColor Cyan
}

# Function to selectively delete local game saves from PC
function Remove-LocalGameSaves {
    $games = @(Get-GamesConfig)
    if ($games.Count -eq 0) {
        Write-Host "Error: No games configured in '$pathsFile'." -ForegroundColor Red
        return
    }

    $existingGames = @()
    foreach ($game in $games) {
        if (Test-Path -LiteralPath $game.FullPath) {
            $existingGames += $game
        }
    }

    if ($existingGames.Count -eq 0) {
        Write-Host "`nNo local game saves found on your PC." -ForegroundColor Yellow
        return
    }

    do {
        Clear-Host
        Write-Host "==================================================" -ForegroundColor Red
        Write-Host "          DELETE LOCAL GAME SAVES FROM PC         " -ForegroundColor White
        Write-Host "==================================================" -ForegroundColor Red
        Write-Host "This menu allows you to permanently delete save folders from your PC." -ForegroundColor Gray
        Write-Host "Choose a game to delete its local save folder:" -ForegroundColor Cyan
        Write-Host "--------------------------------------------------" -ForegroundColor Red

        for ($i = 0; $i -lt $existingGames.Count; $i++) {
            Write-Host "[$($i + 1)] " -NoNewline -ForegroundColor White
            Write-Host "$($existingGames[$i].Name)" -ForegroundColor Yellow
        }
        Write-Host "--------------------------------------------------" -ForegroundColor Red
        Write-Host "[0] Cancel / Go Back" -ForegroundColor White
        Write-Host "--------------------------------------------------" -ForegroundColor Red

        $choice = Read-Host "Select a game [1-$($existingGames.Count)] or 0 to Cancel"

        if ($choice.Trim() -eq "0" -or $choice.Trim().ToUpper() -eq "C" -or [string]::IsNullOrWhiteSpace($choice)) {
            break
        }

        $index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $existingGames.Count) {
            $selectedGame = $existingGames[$index - 1]
            
            Write-Host "`n--------------------------------------------------" -ForegroundColor Red
            Write-Host "WARNING: You are about to permanently delete the save folder for:" -ForegroundColor Red
            Write-Host " -> $($selectedGame.Name)" -ForegroundColor Yellow
            Write-Host " Path: $($selectedGame.FullPath)" -ForegroundColor DarkGray
            Write-Host "--------------------------------------------------" -ForegroundColor Red
            
            $confirm = Read-Host "Are you absolutely sure you want to delete this folder? (y/n)"
            if ($confirm.Trim().ToLower() -eq 'y') {
                try {
                    if (Test-Path -LiteralPath $selectedGame.FullPath) {
                        Remove-Item -LiteralPath $selectedGame.FullPath -Recurse -Force | Out-Null
                        Write-Host "Successfully deleted local saves for '$($selectedGame.Name)'." -ForegroundColor Green
                    } else {
                        Write-Host "The folder was already deleted or is no longer accessible." -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "Failed to delete the folder: $($_.Exception.Message)" -ForegroundColor Red
                }
            } else {
                Write-Host "Deletion canceled." -ForegroundColor Yellow
            }
            
            Write-Host "`nPress any key to continue..."
            [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            break
        } else {
            Write-Host "Invalid option." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    } while ($true)
}

# Perform restore actions without deleting extra local files
function Restore-BackupSet {
    param (
        [PSCustomObject]$backup,
        [switch]$SingleGame
    )

    $games = @(Get-GamesConfig)
    if ($games.Count -eq 0) {
        Write-Host "Error: No games configured in '$pathsFile'." -ForegroundColor Red
        return
    }

    $tempDir = $null
    $sourceRoot = [string]$backup.FullPath

    if ($backup.Type -eq "ZIP File") {
        Write-Host "Extracting ZIP archive for restoration..." -ForegroundColor Cyan
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $tempDir = Join-Path $env:TEMP "RestoreStaging_$timestamp"
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force | Out-Null }
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        
        try {
            Expand-Archive -LiteralPath $backup.FullPath -DestinationPath $tempDir -Force
            $sourceRoot = $tempDir
        } catch {
            Write-Host "Failed to extract ZIP file: $($_.Exception.Message)" -ForegroundColor Red
            if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force | Out-Null }
            return
        }
    }

    try {
        # Intelligent identification across all PCs and backup structures
        $availableInBackup = @()
        foreach ($game in $games) {
            $targetPath = $null
            [string]$relPath = $game.RelativePath
            [string]$legacyRel = $game.LegacyRelativePath
            [string]$fullPath = $game.FullPath
            [string]$leafName = Split-Path $fullPath -Leaf
            [string]$gameName = $game.Name
            
            # 1. Portable relative path
            if (-not [string]::IsNullOrWhiteSpace($relPath)) {
                $candidate1 = Join-Path $sourceRoot $relPath
                if (Test-Path -LiteralPath $candidate1) { $targetPath = $candidate1 }
            }
            
            # 2. Legacy relative path (with older username folder structure)
            if (-not $targetPath -and -not [string]::IsNullOrWhiteSpace($legacyRel)) {
                $candidateOld = Join-Path $sourceRoot $legacyRel
                if (Test-Path -LiteralPath $candidateOld) { $targetPath = $candidateOld }
            }

            # 3. Leaf folder name at root (e.g. GBFR or The Witcher 3)
            if (-not $targetPath -and -not [string]::IsNullOrWhiteSpace($leafName)) {
                $candidate2 = Join-Path $sourceRoot $leafName
                if (Test-Path -LiteralPath $candidate2) { $targetPath = $candidate2 }
            }

            # 4. Game title at root
            if (-not $targetPath -and -not [string]::IsNullOrWhiteSpace($gameName)) {
                $candidate3 = Join-Path $sourceRoot $gameName
                if (Test-Path -LiteralPath $candidate3) { $targetPath = $candidate3 }
            }

            # 5. Deep search inside archive
            if (-not $targetPath -and -not [string]::IsNullOrWhiteSpace($leafName)) {
                $found = Get-ChildItem -LiteralPath $sourceRoot -Directory -Recurse -Filter $leafName -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) { $targetPath = $found.FullName }
            }

            if ($targetPath) {
                $availableInBackup += [PSCustomObject]@{
                    Game       = $game
                    BackupPath = $targetPath
                }
            }
        }

        if ($availableInBackup.Count -eq 0) {
            Write-Host "`nNo matching games found inside this backup set." -ForegroundColor Yellow
            return
        }

        if ($SingleGame) {
            Write-Host "`nSelect a game to restore:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $availableInBackup.Count; $i++) {
                Write-Host "[$($i + 1)] $($availableInBackup[$i].Game.Name)" -ForegroundColor White
            }
            Write-Host "[0] Cancel" -ForegroundColor Red
            
            $choice = Read-Host "Select [1-$($availableInBackup.Count)] or 0 to Cancel"
            if ($choice.Trim() -eq "0" -or $choice.Trim().ToUpper() -eq "C" -or [string]::IsNullOrWhiteSpace($choice)) {
                Write-Host "Restoration canceled." -ForegroundColor Yellow
                return
            }

            $index = 0
            if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $availableInBackup.Count) {
                $selectedItem = $availableInBackup[$index - 1]
                $game = $selectedItem.Game
                $src = $selectedItem.BackupPath

                $confirm = Read-Host "Are you sure you want to update/restore save files for '$($game.Name)'? (y/n)"
                if ($confirm.Trim().ToLower() -eq 'y') {
                    $dest = $game.FullPath
                    if (-not (Test-Path -LiteralPath $dest)) {
                        New-Item -Path $dest -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -Path "$src\*" -Destination $dest -Recurse -Force
                    Write-Host "Successfully restored '$($game.Name)'!" -ForegroundColor Green
                } else {
                    Write-Host "Canceled." -ForegroundColor Yellow
                }
            } else {
                Write-Host "Invalid selection." -ForegroundColor Red
            }
        } else {
            $confirm = Read-Host "Are you sure you want to restore ALL $($availableInBackup.Count) games from this backup? (y/n)"
            if ($confirm.Trim().ToLower() -eq 'y') {
                foreach ($item in $availableInBackup) {
                    $game = $item.Game
                    $src = $item.BackupPath
                    $dest = $game.FullPath
                    
                    if (-not (Test-Path -LiteralPath $dest)) {
                        New-Item -Path $dest -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -Path "$src\*" -Destination $dest -Recurse -Force
                    Write-Host "Restored/Updated: $($game.Name)" -ForegroundColor Gray
                }
                Write-Host "All games restored successfully!" -ForegroundColor Green
            } else {
                Write-Host "Canceled." -ForegroundColor Yellow
            }
        }
    } finally {
        if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force | Out-Null
        }
    }
}

# Permanently delete a backup set
function Delete-BackupSet {
    param ([PSCustomObject]$backup)
    
    $confirm = Read-Host "Are you sure you want to PERMANENTLY delete the backup '$($backup.Name)'? This cannot be undone. (y/n)"
    if ($confirm.Trim().ToLower() -eq 'y') {
        try {
            Remove-Item -LiteralPath $backup.FullPath -Recurse -Force | Out-Null
            Write-Host "Backup deleted successfully." -ForegroundColor Green
        } catch {
            Write-Host "Failed to delete backup: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "Deletion canceled." -ForegroundColor Yellow
    }
}

# Secondary menu: Operations on a selected backup
function Show-BackupOperationsMenu {
    param ([PSCustomObject]$backup)
    
    $dateStr = $backup.LastWrite.ToString("dd/MM/yyyy HH:mm")
    $ageStr = Get-RelativeAge $backup.LastWrite

    do {
        Clear-Host
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "               BACKUP OPERATIONS                  " -ForegroundColor White
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host " Selected: $($backup.Name)" -ForegroundColor Yellow
        Write-Host " Type:     $($backup.Type)" -ForegroundColor Yellow
        Write-Host " Date:     $dateStr ($ageStr)" -ForegroundColor Cyan
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "[1] Restore ALL games from this backup" -ForegroundColor White
        Write-Host "[2] Restore a SINGLE game selectively" -ForegroundColor White
        Write-Host "[3] Delete this backup set permanently" -ForegroundColor White
        Write-Host "[0] Go Back to list" -ForegroundColor White
        Write-Host "--------------------------------------------------" -ForegroundColor Green
        
        $choice = Read-Host "Select option [1-3] or 0 to Go Back"
        
        switch ($choice.Trim().ToUpper()) {
            "1" {
                Restore-BackupSet -backup $backup
                Write-Host "`nPress any key to continue..."
                [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
            "2" {
                Restore-BackupSet -backup $backup -SingleGame
                Write-Host "`nPress any key to continue..."
                [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
            "3" {
                Delete-BackupSet -backup $backup
                Write-Host "`nPress any key to continue..."
                [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                break
            }
            "0" { break }
            "B" { break }
            default {
                Write-Host "Invalid option." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}

# Sub-menu: Manage existing backups list with timestamps and relative age
function Show-ManageBackupsMenu {
    param ([string]$destination)
    
    do {
        Clear-Host
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "               MANAGE BACKUPS MENU                " -ForegroundColor White
        Write-Host "==================================================" -ForegroundColor Green
        
        $backups = @(Get-AvailableBackups -destination $destination)
        if ($backups.Count -eq 0) {
            Write-Host "No backups found in destination: $destination" -ForegroundColor Yellow
            Write-Host "`n[0] Go Back" -ForegroundColor White
        } else {
            Write-Host "Available Backups in: $destination" -ForegroundColor Gray
            Write-Host "Backups list (Newest First):`n" -ForegroundColor Cyan
            
            for ($i = 0; $i -lt $backups.Count; $i++) {
                $b = $backups[$i]
                $dateStr = $b.LastWrite.ToString("dd/MM/yyyy HH:mm")
                $ageStr = Get-RelativeAge $b.LastWrite
                
                Write-Host "[$($i + 1)] " -NoNewline -ForegroundColor White
                Write-Host "$($b.Name) " -NoNewline -ForegroundColor Yellow
                Write-Host "($($b.Type))" -ForegroundColor DarkGray
                Write-Host "    Data: " -NoNewline -ForegroundColor Gray
                Write-Host "$dateStr " -NoNewline -ForegroundColor Cyan
                Write-Host "($ageStr)" -ForegroundColor DarkCyan
            }
            Write-Host "--------------------------------------------------" -ForegroundColor Green
            Write-Host "[0] Go Back" -ForegroundColor White
        }
        
        Write-Host "--------------------------------------------------" -ForegroundColor Green
        $choice = Read-Host "Select a backup [1-$($backups.Count)] or 0 to Go Back"
        
        if ($choice.Trim() -eq "0" -or $choice.Trim().ToUpper() -eq "B" -or [string]::IsNullOrWhiteSpace($choice)) {
            break
        }
        
        $index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $backups.Count) {
            $selectedBackup = $backups[$index - 1]
            Show-BackupOperationsMenu -backup $selectedBackup
        } else {
            Write-Host "Invalid option." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    } while ($true)
}

# Prompt to change destination directory
function Set-DestinationFolder {
    param ($current)
    Write-Host "`nCurrent Destination: $current" -ForegroundColor Cyan
    $newDest = Read-Host "Enter new destination folder path (press 0 or Enter to cancel)"
    if ([string]::IsNullOrWhiteSpace($newDest) -or $newDest.Trim() -eq "0") {
        return $current
    }
    return $newDest.Trim().Trim('"').Trim("'")
}

# --- MAIN MENU LOOP ---
$destination = $defaultDestination

do {
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "                SAVE DATA KEEPER                  " -ForegroundColor White
    Write-Host "==================================================" -ForegroundColor Green
    
    try {
        $loadedCount = @(Get-GamesConfig).Count
    } catch {
        $loadedCount = 0
    }
    
    Write-Host " Destination: " -NoNewline -ForegroundColor Gray
    Write-Host "$destination" -ForegroundColor Yellow
    Write-Host " Configured Games: " -NoNewline -ForegroundColor Gray
    Write-Host "$loadedCount" -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Green
    
    Write-Host "[1] Run Normal Backup (Cumulative)" -ForegroundColor White
    Write-Host "[2] Run ZIP Backup (Cumulative)" -ForegroundColor White
    Write-Host "[3] Manage Backups (Restore / Delete)" -ForegroundColor White
    Write-Host "[4] Check Games Status on This PC" -ForegroundColor White
    Write-Host "[5] Delete Local Game Saves on PC (Selective)" -ForegroundColor White
    Write-Host "[6] Change Destination Folder" -ForegroundColor White
    Write-Host "[7] Open / Edit Paths File (paths.txt)" -ForegroundColor White
    Write-Host "[0] Exit" -ForegroundColor White
    Write-Host "--------------------------------------------------" -ForegroundColor Green
    
    $choice = Read-Host "Select an option [0-7]"
    
    switch ($choice.Trim()) {
        "1" {
            Start-Backup -destination $destination
            Write-Host "`nPress any key to return to menu..."
            [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        "2" {
            Start-Backup -destination $destination -Zip
            Write-Host "`nPress any key to return to menu..."
            [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        "3" {
            Show-ManageBackupsMenu -destination $destination
        }
        "4" {
            Show-CurrentPaths
            Write-Host "`nPress any key to return to menu..."
            [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        "5" {
            Remove-LocalGameSaves
        }
        "6" {
            $destination = Set-DestinationFolder -current $destination
        }
        "7" {
            try {
                if (Test-Path -LiteralPath $pathsFile) {
                    Write-Host "`nOpening 'paths.txt'..." -ForegroundColor Cyan
                    Invoke-Item $pathsFile
                } else {
                    $null = Get-GamesConfig
                    Invoke-Item $pathsFile
                }
            } catch {
                Write-Host "Error opening file: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "`nPress any key..."
                [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
        }
        { $_ -eq "0" -or $_ -eq "8" } {
            Write-Host "`nExiting..." -ForegroundColor Green
            Start-Sleep -Seconds 1
            break
        }
        default {
            Write-Host "Invalid option. Please choose an option from the menu." -ForegroundColor Red
            Start-Sleep -Seconds 1.5
        }
    }
} while ($true)