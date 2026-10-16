param(
    [ValidateSet('Install','Uninstall')]
    [string]$Action = 'Install'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir      = Join-Path $here 'install'
$dataDir     = Join-Path $env:APPDATA 'HytalePL'
$backupFiles = Join-Path $dataDir 'files'
$manifestPath = Join-Path $dataDir 'manifest.json'
$logPath     = Join-Path $dataDir 'log.txt'

New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

function Log([string]$msg) {
    Write-Host $msg
    Add-Content -Path $logPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
}

function Get-Sha([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

function Find-GameRoot {
    $default = Join-Path $env:APPDATA 'Hytale'
    if (Test-Path -LiteralPath (Join-Path $default 'install')) { return $default }

    Write-Host 'Nie znaleziono gry w domyślnej lokalizacji.'
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Wskaż główny folder Hytale (ten, w którym jest folder "install"). W launcherze: koło zębate > Open directory.'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        if (Test-Path -LiteralPath (Join-Path $dlg.SelectedPath 'install')) { return $dlg.SelectedPath }
    }
    throw 'Nie znaleziono folderu gry (brak podfolderu "install").'
}

function Warn-IfGameRunning {
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*Hytale*' }
    if ($procs) {
        Write-Host ''
        Write-Host 'Wykryto uruchomione procesy Hytale. Zamknij grę i launcher, zanim przejdziesz dalej.'
        Read-Host 'Naciśnij Enter, aby kontynuować mimo to (lub zamknij to okno)'
    }
}

function Load-Manifest {
    if (Test-Path -LiteralPath $manifestPath) {
        return (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    return $null
}

function Do-Install {
    if (-not (Test-Path -LiteralPath $srcDir)) {
        throw 'Obok skryptu nie ma folderu "install". Skopiuj go tutaj z paczki spolszczenia.'
    }
    $root = Find-GameRoot
    Warn-IfGameRunning
    Log "Instalacja do: $root"

    $entries = @{}
    $old = Load-Manifest
    if ($old -and $old.root -eq $root) {
        foreach ($e in $old.files) {
            $entries[$e.rel] = @{ existed = [bool]$e.existed; hash = $e.hash }
        }
    }

    $files = Get-ChildItem -LiteralPath $srcDir -Recurse -File
    $count = 0
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($here.Length).TrimStart('\')
        $dst = Join-Path $root $rel
        $bak = Join-Path $backupFiles $rel

        if (Test-Path -LiteralPath $dst) {
            $cur = Get-Sha $dst
            $isOurs = $entries.ContainsKey($rel) -and ($entries[$rel].hash -eq $cur)
            if (-not $isOurs) {
                # to jest oryginalny plik gry (lub nowa wersja po aktualizacji) - zrób kopię
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bak) | Out-Null
                Copy-Item -LiteralPath $dst -Destination $bak -Force
                $entries[$rel] = @{ existed = $true; hash = $null }
            }
        } else {
            $entries[$rel] = @{ existed = $false; hash = $null }
        }

        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
        $entries[$rel].hash = Get-Sha $dst
        $count++
    }

    $list = @()
    foreach ($k in $entries.Keys) {
        $list += @{ rel = $k; existed = $entries[$k].existed; hash = $entries[$k].hash }
    }
    $manifest = @{ root = $root; date = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); files = $list }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    Log "Gotowe. Skopiowano plików: $count."
    Write-Host 'Uruchom grę i wybierz język polski w ustawieniach.'
}

function Do-Uninstall {
    $m = Load-Manifest
    if (-not $m) {
        Log 'Brak zapisanych informacji o instalacji - nie ma czego odinstalować.'
        return
    }
    Warn-IfGameRunning
    Log "Odinstalowywanie z: $($m.root)"

    foreach ($e in $m.files) {
        $dst = Join-Path $m.root $e.rel
        $bak = Join-Path $backupFiles $e.rel

        if (Test-Path -LiteralPath $dst) {
            if ((Get-Sha $dst) -ne $e.hash) {
                Log "Pominięto (plik zmieniony przez grę lub użytkownika): $($e.rel)"
                continue
            }
        }

        if ($e.existed) {
            if (Test-Path -LiteralPath $bak) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                Copy-Item -LiteralPath $bak -Destination $dst -Force
            } else {
                Log "Brak kopii zapasowej: $($e.rel)"
            }
        } else {
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
        }
    }

    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupFiles -Recurse -Force -ErrorAction SilentlyContinue
    Log 'Spolszczenie zostało odinstalowane.'
}

try {
    if ($Action -eq 'Install') { Do-Install } else { Do-Uninstall }
} catch {
    Log ("BŁĄD: " + $_.Exception.Message)
    Write-Host 'Szczegóły zapisano w: ' $logPath
}
