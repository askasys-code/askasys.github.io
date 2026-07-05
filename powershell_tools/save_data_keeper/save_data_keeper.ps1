# ==============================================================================
# SAVE DATA KEEPER - CLI Version (With Game Titles, Selective Restore & Delete)
# ==============================================================================

# Define paths
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pathsFile = Join-Path $scriptDir "paths.txt"
$defaultDestination = $scriptDir

# Function to read and parse the custom game configuration
function Get-GamesConfig {
    if (-not (Test-Path $pathsFile)) {
        # Template showing the new 'Game Name = Path' format
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
    
    $lines = Get-Content $pathsFile | Where-Object {
        $_ -and $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$'
    }
    
    $games = @()
    foreach ($line in $lines) {
        $line = $line.Trim()
        if ($line -match '^([^=]+)=(.*)$') {
            $name = $Matches[1].Trim()
            $rawPath = $Matches[2].Trim()
        } else {
            # Backward compatibility: use the last folder name as game title if '=' is missing
            $rawPath = $line
            $name = Split-Path $rawPath -Leaf
            if ([string]::IsNullOrEmpty($name)) {
                $name = Split-Path (Split-Path $rawPath -Parent) -Leaf
            }
        }
        
        # Resolve path
        if ([System.IO.Path]::IsPathRooted($rawPath)) {
            $resolvedPath = $rawPath
        } else {
            $resolvedPath = Join-Path $env:USERPROFILE $rawPath
        }
        
        # Resolve full normalized path and its relative structure for backup preservation
        try {
            if (Test-Path $resolvedPath) {
                $fullPath = (Resolve-Path $resolvedPath).Path
            } else {
                $fullPath = [System.IO.Path]::GetFullPath($resolvedPath)
            }
            $drive = [System.IO.Path]::GetPathRoot($fullPath)
            $relativePath = $fullPath.Substring($drive.Length)
        } catch {
            $fullPath = $resolvedPath
            $relativePath = $resolvedPath
        }

        $games += [PSCustomObject]@{
            Name         = $name
            FullPath     = $fullPath
            RelativePath = $relativePath
        }
    }
    return $games
}

# Main function to run backup (Normal or ZIP)
function Start-Backup {
    param (
        [string]$destination,
        [switch]$Zip
    )

    $games = Get-GamesConfig
    if ($games.Count -eq 0) {
        Write-Host "Error: No games configured in '$pathsFile'." -ForegroundColor Red
        return
    }

    if (-not (Test-Path $destination)) {
        try {
            New-Item -Path $destination -ItemType Directory -Force | Out-Null
        } catch {
            Write-Host "Failed to create destination directory: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    if ($Zip) {
        Write-Host "`n[ZIP BACKUP IN PROGRESS]" -ForegroundColor Cyan
        $zipFileName = "Backup_$timestamp.zip"
        $zipFilePath = Join-Path $destination $zipFileName
        
        $tempDir = Join-Path $env:TEMP "BackupStaging_$timestamp"
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force | Out-Null
        }
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

        try {
            foreach ($game in $games) {
                if (Test-Path $game.FullPath) {
                    $stagingPath = Join-Path $tempDir $game.RelativePath
                    $parentStagingPath = Split-Path $stagingPath -Parent
                    
                    if (-not (Test-Path $parentStagingPath)) {
                        New-Item -Path $parentStagingPath -ItemType Directory -Force | Out-Null
                    }
                    
                    Copy-Item -Path $game.FullPath -Destination $stagingPath -Recurse -Force
                    Write-Host "Staged: '$($game.Name)'" -ForegroundColor Gray
                } else {
                    Write-Host "Warning: Path not found for '$($game.Name)'" -ForegroundColor Yellow
                }
            }
            
            if (Test-Path $zipFilePath) {
                Remove-Item -Path $zipFilePath -Force | Out-Null
            }

            Write-Host "Compressing archive..." -ForegroundColor Cyan
            Compress-Archive -Path "$tempDir\*" -DestinationPath $zipFilePath -Force
            Write-Host "Backup completed successfully! Saved to: $zipFilePath" -ForegroundColor Green
        } catch {
            Write-Host "Error during ZIP backup: $($_.Exception.Message)" -ForegroundColor Red
        } finally {
            if (Test-Path $tempDir) {
                Remove-Item -Path $tempDir -Recurse -Force | Out-Null
            }
        }
    } else {
        Write-Host "`n[NORMAL BACKUP IN PROGRESS]" -ForegroundColor Cyan
        $backupRoot = Join-Path $destination "Backup_$timestamp"
        
        try {
            New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
            
            foreach ($game in $games) {
                if (Test-Path $game.FullPath) {
                    $destPath = Join-Path $backupRoot $game.RelativePath
                    $parentDestPath = Split-Path $destPath -Parent
                    
                    if (-not (Test-Path $parentDestPath)) {
                        New-Item -Path $parentDestPath -ItemType Directory -Force | Out-Null
                    }
                    
                    Copy-Item -Path $game.FullPath -Destination $destPath -Recurse -Force
                    Write-Host "Backed up: '$($game.Name)'" -ForegroundColor Gray
                } else {
                    Write-Host "Warning: Path not found for '$($game.Name)'" -ForegroundColor Yellow
                }
            }
            Write-Host "Backup completed successfully! Saved to: $backupRoot" -ForegroundColor Green
        } catch {
            Write-Host "Error during backup: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# Function to display path configuration status with colors
function Show-CurrentPaths {
    Write-Host "`n--- CONFIGURATED GAMES STATUS ---" -ForegroundColor Cyan
    $games = Get-GamesConfig
    if ($games.Count -eq 0) {
        Write-Host "No games configured or 'paths.txt' is empty." -ForegroundColor Yellow
        return
    }
    foreach ($game in $games) {
        if (Test-Path $game.FullPath) {
            Write-Host " [Found]     " -NoNewline -ForegroundColor Green
            Write-Host "$($game.Name)" -ForegroundColor Yellow
        } else {
            Write-Host " [Not Found] " -NoNewline -ForegroundColor Red
            Write-Host "$($game.Name)" -ForegroundColor Red
        }
    }
    Write-Host "---------------------------------" -ForegroundColor Cyan
}

# New function to selectively delete local game saves from the PC
function Remove-LocalGameSaves {
    $games = Get-GamesConfig
    if ($games.Count -eq 0) {
        Write-Host "Error: No games configured in '$pathsFile'." -ForegroundColor Red
        return
    }

    # Filter only games that exist on the PC
    $existingGames = @()
    foreach ($game in $games) {
        if (Test-Path $game.FullPath) {
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
        # Coretto: "Gray" sostituisce "LightGray" per evitare l'errore di enumeratore
        Write-Host "This menu allows you to permanently delete save folders from your PC." -ForegroundColor Gray
        Write-Host "Choose a game to delete its local save folder:" -ForegroundColor Cyan
        Write-Host "--------------------------------------------------" -ForegroundColor Red

        for ($i = 0; $i -lt $existingGames.Count; $i++) {
            Write-Host "[$($i + 1)] " -NoNewline -ForegroundColor White
            Write-Host "$($existingGames[$i].Name)" -ForegroundColor Yellow
        }
        Write-Host "--------------------------------------------------" -ForegroundColor Red
        Write-Host "[C] Cancel / Go Back" -ForegroundColor White
        Write-Host "--------------------------------------------------" -ForegroundColor Red

        $choice = Read-Host "Select a game [1-$($existingGames.Count) or C]"

        if ($choice.Trim().ToUpper() -eq "C" -or [string]::IsNullOrWhiteSpace($choice)) {
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
                    if (Test-Path $selectedGame.FullPath) {
                        Remove-Item -Path $selectedGame.FullPath -Recurse -Force | Out-Null
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
            break # Exit loop to refresh menu lists
        } else {
            Write-Host "Invalid option." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    } while ($true)
}

# Scan destination for existing backups (folders and ZIP files)
function Get-AvailableBackups {
    param ([string]$destination)
    if (-not (Test-Path $destination)) { return @() }
    
    $folders = Get-ChildItem -Path $destination -Directory -Filter "Backup_*"
    $zips = Get-ChildItem -Path $destination -File -Filter "Backup_*.zip"
    
    $allBackups = @()
    foreach ($f in $folders) {
        $allBackups += [PSCustomObject]@{
            Name      = $f.Name
            FullPath  = $f.FullName
            Type      = "Folder"
            LastWrite = $f.LastWriteTime
        }
    }
    foreach ($z in $zips) {
        $allBackups += [PSCustomObject]@{
            Name      = $z.Name
            FullPath  = $z.FullName
            Type      = "ZIP File"
            LastWrite = $z.LastWriteTime
        }
    }
    
    return $allBackups | Sort-Object LastWrite -Descending
}

# Perform restore actions (All or Single)
function Restore-BackupSet {
    param (
        [PSCustomObject]$backup,
        [switch]$SingleGame
    )

    $games = Get-GamesConfig
    if ($games.Count -eq 0) {
        Write-Host "Error: No games configured in '$pathsFile'." -ForegroundColor Red
        return
    }

    $tempDir = $null
    $sourceRoot = $backup.FullPath

    # If the backup is a ZIP file, extract it to a temp folder first
    if ($backup.Type -eq "ZIP File") {
        Write-Host "Extracting ZIP archive for restoration..." -ForegroundColor Cyan
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $tempDir = Join-Path $env:TEMP "RestoreStaging_$timestamp"
        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force | Out-Null }
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        
        try {
            Expand-Archive -Path $backup.FullPath -DestinationPath $tempDir -Force
            $sourceRoot = $tempDir
        } catch {
            Write-Host "Failed to extract ZIP file: $($_.Exception.Message)" -ForegroundColor Red
            if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force | Out-Null }
            return
        }
    }

    try {
        # Check which of the configured games are present in this backup set
        $availableInBackup = @()
        foreach ($game in $games) {
            $gameBackupPath = Join-Path $sourceRoot $game.RelativePath
            if (Test-Path $gameBackupPath) {
                $availableInBackup += [PSCustomObject]@{
                    Game       = $game
                    BackupPath = $gameBackupPath
                }
            }
        }

        if ($availableInBackup.Count -eq 0) {
            Write-Host "No matching games found inside this backup set." -ForegroundColor Yellow
            return
        }

        if ($SingleGame) {
            # Selective single-game restore
            Write-Host "`nSelect a game to restore:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $availableInBackup.Count; $i++) {
                Write-Host "[$($i + 1)] $($availableInBackup[$i].Game.Name)" -ForegroundColor White
            }
            Write-Host "[C] Cancel" -ForegroundColor Red
            
            $choice = Read-Host "Select [1-$($availableInBackup.Count) or C]"
            if ($choice.Trim().ToUpper() -eq "C" -or [string]::IsNullOrWhiteSpace($choice)) {
                Write-Host "Restoration canceled." -ForegroundColor Yellow
                return
            }

            $index = 0
            if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $availableInBackup.Count) {
                $selectedItem = $availableInBackup[$index - 1]
                $game = $selectedItem.Game
                $src = $selectedItem.BackupPath

                # Overwrite warning
                $confirm = Read-Host "Are you sure you want to OVERWRITE your current save files for '$($game.Name)'? (y/n)"
                if ($confirm.Trim().ToLower() -eq 'y') {
                    $parentDest = Split-Path $game.FullPath -Parent
                    if (-not (Test-Path $parentDest)) {
                        New-Item -Path $parentDest -ItemType Directory -Force | Out-Null
                    }
                    if (Test-Path $game.FullPath) {
                        Remove-Item -Path $game.FullPath -Recurse -Force | Out-Null
                    }
                    Copy-Item -Path $src -Destination $game.FullPath -Recurse -Force
                    Write-Host "Successfully restored '$($game.Name)'!" -ForegroundColor Green
                } else {
                    Write-Host "Canceled." -ForegroundColor Yellow
                }
            } else {
                Write-Host "Invalid selection." -ForegroundColor Red
            }
        } else {
            # Restore all games
            $confirm = Read-Host "Are you sure you want to restore ALL $($availableInBackup.Count) games from this backup? This will overwrite your current saves. (y/n)"
            if ($confirm.Trim().ToLower() -eq 'y') {
                foreach ($item in $availableInBackup) {
                    $game = $item.Game
                    $src = $item.BackupPath
                    
                    $parentDest = Split-Path $game.FullPath -Parent
                    if (-not (Test-Path $parentDest)) {
                        New-Item -Path $parentDest -ItemType Directory -Force | Out-Null
                    }
                    if (Test-Path $game.FullPath) {
                        Remove-Item -Path $game.FullPath -Recurse -Force | Out-Null
                    }
                    Copy-Item -Path $src -Destination $game.FullPath -Recurse -Force
                    Write-Host "Restored: $($game.Name)" -ForegroundColor Gray
                }
                Write-Host "All games restored successfully!" -ForegroundColor Green
            } else {
                Write-Host "Canceled." -ForegroundColor Yellow
            }
        }
    } finally {
        if ($tempDir -and (Test-Path $tempDir)) {
            Remove-Item -Path $tempDir -Recurse -Force | Out-Null
        }
    }
}

# Permanently delete a backup set
function Delete-BackupSet {
    param ([PSCustomObject]$backup)
    
    $confirm = Read-Host "Are you sure you want to PERMANENTLY delete the backup '$($backup.Name)'? This cannot be undone. (y/n)"
    if ($confirm.Trim().ToLower() -eq 'y') {
        try {
            Remove-Item -Path $backup.FullPath -Recurse -Force | Out-Null
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
    
    do {
        Clear-Host
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "               BACKUP OPERATIONS                  " -ForegroundColor White
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host " Selected: $($backup.Name)" -ForegroundColor Yellow
        Write-Host " Type:     $($backup.Type)" -ForegroundColor Yellow
        Write-Host " Date:     $($backup.LastWrite)" -ForegroundColor Yellow
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "[1] Restore ALL games from this backup" -ForegroundColor White
        Write-Host "[2] Restore a SINGLE game selectively" -ForegroundColor White
        Write-Host "[3] Delete this backup set permanently" -ForegroundColor White
        Write-Host "[B] Go Back to list" -ForegroundColor White
        Write-Host "--------------------------------------------------" -ForegroundColor Green
        
        $choice = Read-Host "Select option [1-3] or B to Go Back"
        
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
                break # Exit current menu since the item is deleted
            }
            "B" {
                break
            }
            default {
                Write-Host "Invalid option." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}

# Sub-menu: Manage existing backups list
function Show-ManageBackupsMenu {
    param ([string]$destination)
    
    do {
        Clear-Host
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "               MANAGE BACKUPS MENU                " -ForegroundColor White
        Write-Host "==================================================" -ForegroundColor Green
        
        $backups = Get-AvailableBackups -destination $destination
        if ($backups.Count -eq 0) {
            Write-Host "No backups found in destination folder." -ForegroundColor Yellow
            Write-Host "`n[B] Go Back" -ForegroundColor White
        } else {
            Write-Host "Available Backups (Newest First):" -ForegroundColor Cyan
            for ($i = 0; $i -lt $backups.Count; $i++) {
                $b = $backups[$i]
                Write-Host "[$($i + 1)] $($b.Name) ($($b.Type))" -ForegroundColor White
            }
            Write-Host "--------------------------------------------------" -ForegroundColor Green
            Write-Host "[B] Go Back" -ForegroundColor White
        }
        
        Write-Host "--------------------------------------------------" -ForegroundColor Green
        $choice = Read-Host "Select a backup [1-$($backups.Count)] or B to Go Back"
        
        if ($choice.Trim().ToUpper() -eq "B" -or [string]::IsNullOrWhiteSpace($choice)) {
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
    $newDest = Read-Host "Enter new destination folder path (press Enter to cancel)"
    if ([string]::IsNullOrWhiteSpace($newDest)) {
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
        $loadedCount = (Get-GamesConfig).Count
    } catch {
        $loadedCount = 0
    }
    
    Write-Host " Destination: " -NoNewline -ForegroundColor Gray
    Write-Host "$destination" -ForegroundColor Yellow
    Write-Host " Configured Games: " -NoNewline -ForegroundColor Gray
    Write-Host "$loadedCount" -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Green
    
    Write-Host "[1] Run Normal Backup (All Games)" -ForegroundColor White
    Write-Host "[2] Run ZIP Backup (All Games)" -ForegroundColor White
    Write-Host "[3] Manage Backups (Restore / Delete)" -ForegroundColor White
    Write-Host "[4] Check Games Status" -ForegroundColor White
    Write-Host "[5] Delete Local Game Saves on PC (Selective)" -ForegroundColor White
    Write-Host "[6] Change Destination Folder" -ForegroundColor White
    Write-Host "[7] Open / Edit Paths File (paths.txt)" -ForegroundColor White
    Write-Host "[8] Exit" -ForegroundColor White
    Write-Host "--------------------------------------------------" -ForegroundColor Green
    
    $choice = Read-Host "Select an option [1-8]"
    
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
                if (Test-Path $pathsFile) {
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
        "8" {
            Write-Host "`nExiting..." -ForegroundColor Green
            Start-Sleep -Seconds 1
            break
        }
        default {
            Write-Host "Invalid option. Please choose between 1 and 8." -ForegroundColor Red
            Start-Sleep -Seconds 1.5
        }
    }
} while ($true)