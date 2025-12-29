# Controlla se lo script è in esecuzione come amministratore
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Se non è amministratore, riesegue lo script con privilegi elevati
if (-not $isAdmin) {
    Write-Host "Questo script richiede privilegi amministrativi. Tentativo di elevazione..."
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Esegue le funzioni richieste
try {
    Write-Host "Installazione del modulo Microsoft.WinGet.Client..."
    Install-Module -Name Microsoft.WinGet.Client -Force -ErrorAction Stop
    Write-Host "Modulo Microsoft.WinGet.Client installato con successo."

    Write-Host "Esecuzione di Repair-WinGetPackageManager..."
    Repair-WinGetPackageManager -ErrorAction Stop
    Write-Host "Riparazione completata con successo."
}
catch {
    Write-Host "Si è verificato un errore: $_" -ForegroundColor Red
}
finally {
    Write-Host "Premi un tasto per uscire..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}