# Arresto dei servizi NVIDIA coinvolti nella telemetria e scansione
Stop-Service -Name "NvContainerLocalSystem" -Force

# Percorso del database delle applicazioni scansionate
$path = "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA app\NvBackend\ApplicationStorage.json"

# Rimozione del database se esistente
if (Test-Path $path) {
    Remove-Item $path -Force
    Write-Output "Database delle scansioni eliminato con successo."
}

# Riattivazione del servizio core
Start-Service -Name "NvContainerLocalSystem"