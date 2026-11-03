Set-StrictMode -Version Latest

function ConvertTo-NormalizedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path,
        [switch]$AllowMissing
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'La ruta no puede estar vacía.'
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())

    if ($expanded -eq '~') {
        $expanded = $env:USERPROFILE
    }
    elseif ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        $expanded = Join-Path $env:USERPROFILE $expanded.Substring(2)
    }

    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path (Get-Location).Path $expanded
    }

    try {
        $full = [System.IO.Path]::GetFullPath($expanded)
    }
    catch {
        throw ("La ruta no es válida: {0}" -f $Path)
    }

    $full = $full -replace '\\', '/'

    if ($full -match '^[A-Za-z]:/$') {
        return $full
    }

    return $full.TrimEnd('/')
}

function ConvertTo-GitPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (ConvertTo-NormalizedPath -Path $Path)
}

function Test-PathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Child,
        [Parameter(Mandatory = $true)]
        [string]$Parent
    )

    $normalizedChild = ConvertTo-NormalizedPath -Path $Child
    $normalizedParent = ConvertTo-NormalizedPath -Path $Parent

    if ($normalizedChild.Equals($normalizedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $prefix = $normalizedParent.TrimEnd('/') + '/'
    return $normalizedChild.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoNestedRoots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FirstRoot,
        [Parameter(Mandatory = $true)]
        [string]$SecondRoot
    )

    $first = ConvertTo-NormalizedPath -Path $FirstRoot
    $second = ConvertTo-NormalizedPath -Path $SecondRoot

    if ($first.Equals($second, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Las dos carpetas raíz no pueden ser la misma.'
    }

    if ((Test-PathWithin -Child $first -Parent $second) -or (Test-PathWithin -Child $second -Parent $first)) {
        throw 'Las carpetas raíz no pueden estar anidadas. Elige dos carpetas separadas.'
    }
}

function Get-RootValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    try {
        $normalized = ConvertTo-NormalizedPath -Path $Root
    }
    catch {
        $errors.Add($_.Exception.Message)
        return [pscustomobject]@{
            Root     = $Root
            Errors   = $errors.ToArray()
            Warnings = $warnings.ToArray()
        }
    }

    if ($normalized -match '^[A-Za-z]:/$') {
        $errors.Add('No uses la raíz de una unidad completa (por ejemplo, C:/).')
    }

    $homePath = ''
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $homePath = ConvertTo-NormalizedPath -Path $env:USERPROFILE
    }

    if (-not [string]::IsNullOrWhiteSpace($homePath)) {
        if ($normalized.Equals($homePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add('No uses tu carpeta de usuario completa como raíz.')
        }

        $usersRoot = Split-Path -Parent $homePath
        if ($usersRoot -and $normalized.Equals((ConvertTo-NormalizedPath -Path $usersRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add('No uses la carpeta Users completa como raíz.')
        }
    }

    $forbidden = @(
        'C:/Windows',
        'C:/Program Files',
        'C:/Program Files (x86)',
        'C:/ProgramData'
    )
    foreach ($path in $forbidden) {
        if ($normalized.Equals($path, [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add(("No uses {0} como raíz." -f $path))
        }
    }

    if (Test-Path -LiteralPath $normalized -PathType Leaf) {
        $errors.Add('La ruta existe, pero es un archivo, no una carpeta.')
    }

    if (Test-Path -LiteralPath (Join-Path $normalized '.git') -PathType Container) {
        $warnings.Add('La carpeta raíz ya es un repositorio Git. Se recomienda que solo contenga carpetas de repositorios.')
    }

    $syncRoots = @($env:OneDrive, $env:OneDriveCommercial)
    foreach ($syncRoot in $syncRoots) {
        if (-not [string]::IsNullOrWhiteSpace($syncRoot)) {
            try {
                $syncNormalized = ConvertTo-NormalizedPath -Path $syncRoot
                if (Test-PathWithin -Child $normalized -Parent $syncNormalized) {
                    $warnings.Add('La carpeta está dentro de OneDrive o de una carpeta sincronizada. Evita guardar claves privadas allí.')
                }
            }
            catch {
                # Ignore invalid environment values.
            }
        }
    }

    if ($normalized.Length -gt 200) {
        $warnings.Add('La ruta es muy larga; algunas herramientas de Windows pueden tener problemas.')
    }

    return [pscustomobject]@{
        Root     = $normalized
        Errors   = $errors.ToArray()
        Warnings = $warnings.ToArray()
    }
}

function Assert-SafeRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $validation = Get-RootValidation -Root $Root
    if ($validation.Errors.Count -gt 0) {
        throw ($validation.Errors -join ' ')
    }

    return $validation
}

function Get-DefaultRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileId
    )

    $base = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = $HOME
    }

    return (ConvertTo-NormalizedPath -Path (Join-Path (Join-Path $base 'GitHub') $ProfileId))
}

function Get-DefaultKeyPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileId
    )

    $base = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = $HOME
    }

    $fileName = 'id_ed25519_github_{0}' -f $ProfileId.ToLowerInvariant()
    return (ConvertTo-NormalizedPath -Path (Join-Path (Join-Path $base '.ssh') $fileName))
}

function Get-DefaultConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileId
    )

    $base = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = $HOME
    }

    $fileName = 'github-{0}.gitconfig' -f $ProfileId.ToLowerInvariant()
    return (ConvertTo-NormalizedPath -Path (Join-Path (Join-Path (Join-Path $base '.config') 'git') $fileName))
}

function New-DirectoryIfMissing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [switch]$DryRun
    )

    $normalized = ConvertTo-NormalizedPath -Path $Path

    if (Test-Path -LiteralPath $normalized -PathType Leaf) {
        throw ("La ruta existe, pero es un archivo: {0}" -f $normalized)
    }

    if (Test-Path -LiteralPath $normalized -PathType Container) {
        return $normalized
    }

    if ($DryRun) {
        Write-UiLog ("[dry-run] Crear carpeta: {0}" -f $normalized) 'INFO'
        return $normalized
    }

    New-Item -ItemType Directory -Path $normalized -Force | Out-Null
    Write-UiLog ("Carpeta creada: {0}" -f $normalized) 'INFO'
    return $normalized
}

function New-TemporaryDirectory {
    [CmdletBinding()]
    param(
        [string]$Prefix = 'dgh'
    )

    $base = [System.IO.Path]::GetTempPath()
    $path = Join-Path $base ("{0}-{1}" -f $Prefix, [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return (ConvertTo-NormalizedPath -Path $path)
}

function Remove-TemporaryDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-UiWarn ("No se pudo eliminar la carpeta temporal {0}: {1}" -f $Path, $_.Exception.Message)
    }
}

function Get-NormalizedComparisonKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (ConvertTo-NormalizedPath -Path $Path).ToLowerInvariant()
}
