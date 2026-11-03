Set-StrictMode -Version Latest

function Get-DefaultStatePath {
    [CmdletBinding()]
    param()

    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = Join-Path $env:USERPROFILE 'AppData\Local'
    }

    return (ConvertTo-NormalizedPath -Path (Join-Path (Join-Path $base 'DualGithubSetup') 'state.json'))
}

function Get-DefaultBackupRoot {
    [CmdletBinding()]
    param()

    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = Join-Path $env:USERPROFILE 'AppData\Local'
    }

    return (ConvertTo-NormalizedPath -Path (Join-Path (Join-Path $base 'DualGithubSetup') 'backups'))
}

function Get-DefaultLogPath {
    [CmdletBinding()]
    param()

    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = Join-Path $env:USERPROFILE 'AppData\Local'
    }

    $fileName = 'setup-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    return (ConvertTo-NormalizedPath -Path (Join-Path (Join-Path (Join-Path $base 'DualGithubSetup') 'logs') $fileName))
}

function Read-SetupState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = ConvertTo-NormalizedPath -Path $Path
    if (-not (Test-Path -LiteralPath $normalized -PathType Leaf)) {
        return $null
    }

    try {
        $raw = [System.IO.File]::ReadAllText($normalized)
        $state = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($state.version -eq $null) {
            return $null
        }
        if ([int]$state.version -ne 1) {
            throw ("Versión de estado no soportada: {0}" -f $state.version)
        }
        return $state
    }
    catch {
        throw ("No se pudo leer el estado del asistente: {0}" -f $normalized)
    }
}

function Save-SetupState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [switch]$DryRun
    )

    $normalized = ConvertTo-NormalizedPath -Path $Path

    if ($DryRun) {
        Write-UiLog ("[dry-run] Guardar estado: {0}" -f $normalized) 'INFO'
        return
    }

    $parent = Split-Path -Parent $normalized
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if ($State.PSObject.Properties['updatedAt'] -ne $null) {
        $State.updatedAt = (Get-Date).ToString('o')
    }

    $json = $State | ConvertTo-Json -Depth 10
    $temporaryPath = $normalized + '.tmp'
    Set-Content -LiteralPath $temporaryPath -Value $json -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $normalized -Force

    Write-UiLog ("Estado guardado: {0}" -f $normalized) 'INFO'
}

function New-SetupBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Files,
        [string]$BackupRoot = '',
        [switch]$DryRun
    )

    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = Get-DefaultBackupRoot
    }

    $normalizedRoot = ConvertTo-NormalizedPath -Path $BackupRoot
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupDir = Join-Path $normalizedRoot $timestamp

    if ($DryRun) {
        Write-UiLog ("[dry-run] Crear backup en {0}" -f $backupDir) 'INFO'
        return [pscustomobject]@{
            Dir          = $backupDir
            ManifestPath = (Join-Path $backupDir 'manifest.json')
            Entries      = @()
            Planned      = $true
        }
    }

    if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    $filesDir = Join-Path $backupDir 'files'
    New-Item -ItemType Directory -Path $filesDir -Force | Out-Null

    $entries = New-Object System.Collections.Generic.List[object]
    $index = 0

    foreach ($file in $Files) {
        $originalPath = ConvertTo-NormalizedPath -Path $file.Path
        $label = [string]$file.Label
        if ([string]::IsNullOrWhiteSpace($label)) {
            $label = [System.IO.Path]::GetFileName($originalPath)
        }

        $deleteIfCreated = $false
        if ($file.PSObject.Properties['DeleteIfCreated'] -ne $null) {
            $deleteIfCreated = [bool]$file.DeleteIfCreated
        }

        $exists = Test-Path -LiteralPath $originalPath -PathType Leaf
        $backupPath = ''

        if ($exists) {
            $leaf = [System.IO.Path]::GetFileName($originalPath)
            $backupName = '{0:D3}_{1}' -f $index, $leaf
            $backupPath = Join-Path $filesDir $backupName
            Copy-Item -LiteralPath $originalPath -Destination $backupPath -Force
        }

        $entries.Add([pscustomobject]@{
            OriginalPath    = $originalPath
            BackupPath      = $backupPath
            Existed         = $exists
            Label           = $label
            DeleteIfCreated = $deleteIfCreated
        })

        $index++
    }

    $manifest = [pscustomobject]@{
        Version   = 1
        CreatedAt = (Get-Date).ToString('o')
        BackupDir = $backupDir
        Entries   = $entries.ToArray()
    }

    $manifestPath = Join-Path $backupDir 'manifest.json'
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    Write-UiLog ("Backup creado: {0}" -f $backupDir) 'INFO'

    return [pscustomobject]@{
        Dir          = $backupDir
        ManifestPath = $manifestPath
        Entries      = $entries.ToArray()
        Planned      = $false
    }
}

function Read-SetupBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath
    )

    $normalized = ConvertTo-NormalizedPath -Path $ManifestPath
    if (-not (Test-Path -LiteralPath $normalized -PathType Leaf)) {
        throw ("No existe el manifiesto de backup: {0}" -f $normalized)
    }

    $manifest = [System.IO.File]::ReadAllText($normalized) | ConvertFrom-Json
    if ($manifest.entries -eq $null) {
        throw ("El manifiesto de backup no contiene entradas: {0}" -f $normalized)
    }

    return $manifest
}

function Restore-SetupBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Backup,
        [switch]$DryRun
    )

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($entry in @($Backup.Entries)) {
        if ($entry.Existed) {
            if ([string]::IsNullOrWhiteSpace($entry.BackupPath) -or -not (Test-Path -LiteralPath $entry.BackupPath -PathType Leaf)) {
                $results.Add([pscustomobject]@{
                    Path    = $entry.OriginalPath
                    Restored = $false
                    Message = 'No se encontró el archivo de backup.'
                })
                continue
            }

            if ($DryRun) {
                $results.Add([pscustomobject]@{
                    Path     = $entry.OriginalPath
                    Restored = $true
                    Message  = '[dry-run] Se restauraría desde el backup.'
                })
                continue
            }

            $parent = Split-Path -Parent $entry.OriginalPath
            if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $entry.BackupPath -Destination $entry.OriginalPath -Force
            $results.Add([pscustomobject]@{
                Path     = $entry.OriginalPath
                Restored = $true
                Message  = 'Restaurado desde el backup.'
            })
        }
        elseif ($entry.DeleteIfCreated) {
            if (Test-Path -LiteralPath $entry.OriginalPath) {
                if (-not $DryRun) {
                    Remove-Item -LiteralPath $entry.OriginalPath -Force
                }
                $results.Add([pscustomobject]@{
                    Path     = $entry.OriginalPath
                    Restored = $true
                    Message  = $(if ($DryRun) { '[dry-run] Se eliminaría el archivo creado por el asistente.' } else { 'Archivo creado por el asistente eliminado.' })
                })
            }
        }
    }

    return $results.ToArray()
}
