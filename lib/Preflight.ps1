Set-StrictMode -Version Latest

function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Test-VersionAtLeast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [Parameter(Mandatory = $true)]
        [string]$Minimum
    )

    try {
        $versionParts = @($Version -split '\.')
        $minimumParts = @($Minimum -split '\.')
        $count = [Math]::Max($versionParts.Count, $minimumParts.Count)

        for ($index = 0; $index -lt $count; $index++) {
            $versionPart = 0
            $minimumPart = 0

            if ($index -lt $versionParts.Count) {
                [void][int]::TryParse(($versionParts[$index] -replace '[^0-9].*$', ''), [ref]$versionPart)
            }
            if ($index -lt $minimumParts.Count) {
                [void][int]::TryParse(($minimumParts[$index] -replace '[^0-9].*$', ''), [ref]$minimumPart)
            }

            if ($versionPart -gt $minimumPart) {
                return $true
            }
            if ($versionPart -lt $minimumPart) {
                return $false
            }
        }

        return $true
    }
    catch {
        return $false
    }
}

function Get-PreflightReport {
    [CmdletBinding()]
    param()

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $checks = New-Object System.Collections.Generic.List[object]

    $powerShellVersion = $PSVersionTable.PSVersion.ToString()
    $checks.Add([pscustomobject]@{
        Name    = 'PowerShell'
        Status  = $(if ((Test-VersionAtLeast -Version $powerShellVersion -Minimum '5.1')) { 'OK' } else { 'ERROR' })
        Details = $powerShellVersion
    })
    if (-not (Test-VersionAtLeast -Version $powerShellVersion -Minimum '5.1')) {
        $errors.Add('Se requiere PowerShell 5.1 o superior.')
    }

    $gitAvailable = Test-GitAvailable
    $gitVersion = $null
    $gitPath = $null
    if ($gitAvailable) {
        $gitVersion = Get-GitVersion
        $gitPath = Get-GitExecutablePath
    }

    $checks.Add([pscustomobject]@{
        Name    = 'Git'
        Status  = $(if ($gitAvailable) { 'OK' } else { 'ERROR' })
        Details = $(if ($gitAvailable) { ("{0} ({1})" -f $gitVersion, $gitPath) } else { 'No encontrado' })
    })

    if (-not $gitAvailable) {
        $errors.Add('Git no está instalado o no está en PATH. Instálalo con: winget install --id Git.Git -e --source winget, o descárgalo de https://git-scm.com/download/win')
    }
    elseif ($gitVersion -ne $null -and -not (Test-VersionAtLeast -Version $gitVersion -Minimum '2.30')) {
        $warnings.Add(("Git {0} es antiguo. Se recomienda Git 2.30 o superior." -f $gitVersion))
    }

    $sshAvailable = [bool](Get-Command ssh -ErrorAction SilentlyContinue)
    $sshKeygenAvailable = [bool](Get-Command ssh-keygen -ErrorAction SilentlyContinue)
    $sshVersion = Get-SshVersion
    $sshDetails = 'No encontrado'
    if ($sshAvailable) {
        $sshDetails = ("{0} ({1})" -f $sshVersion, (Get-SshExecutablePath))
    }

    $checks.Add([pscustomobject]@{
        Name    = 'OpenSSH'
        Status  = $(if ($sshAvailable -and $sshKeygenAvailable -and $sshVersion -match 'OpenSSH') { 'OK' } else { 'ERROR' })
        Details = $sshDetails
    })

    if (-not $sshAvailable -or -not $sshKeygenAvailable) {
        $errors.Add('No se encontraron ssh y ssh-keygen en PATH. Instala OpenSSH Client desde Settings > Apps > Optional Features > OpenSSH Client.')
    }
    elseif ($sshVersion -notmatch 'OpenSSH') {
        $errors.Add('El cliente SSH encontrado no es OpenSSH. Instala OpenSSH Client y vuelve a intentarlo.')
    }

    $checks.Add([pscustomobject]@{
        Name    = 'ssh-keygen'
        Status  = $(if ($sshKeygenAvailable) { 'OK' } else { 'ERROR' })
        Details = $(if ($sshKeygenAvailable) { Get-SshKeygenExecutablePath } else { 'No encontrado' })
    })

    $icaclsAvailable = [bool](Get-Command icacls.exe -ErrorAction SilentlyContinue)
    $checks.Add([pscustomobject]@{
        Name    = 'icacls'
        Status  = $(if ($icaclsAvailable) { 'OK' } else { 'WARN' })
        Details = $(if ($icaclsAvailable) { 'Disponible' } else { 'No disponible; los permisos de la clave no se podrán restringir automáticamente.' })
    })
    if (-not $icaclsAvailable) {
        $warnings.Add('icacls no está disponible; revisa manualmente los permisos de la clave privada.')
    }

    $isAdmin = Test-IsAdministrator
    $checks.Add([pscustomobject]@{
        Name    = 'Permisos'
        Status  = 'OK'
        Details = $(if ($isAdmin) { 'Sesión elevada (no es necesaria)' } else { 'Usuario normal' })
    })
    if ($isAdmin) {
        $warnings.Add('El asistente no necesita ejecutarse como administrador. Una sesión normal es suficiente.')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GIT_SSH_COMMAND)) {
        $checks.Add([pscustomobject]@{
            Name    = 'GIT_SSH_COMMAND'
            Status  = 'ERROR'
            Details = $env:GIT_SSH_COMMAND
        })
        $errors.Add('GIT_SSH_COMMAND está definida y tiene prioridad sobre core.sshCommand. Elimínala del entorno y vuelve a ejecutar.')
    }
    else {
        $checks.Add([pscustomobject]@{
            Name    = 'GIT_SSH_COMMAND'
            Status  = 'OK'
            Details = 'No definida'
        })
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GIT_SSH)) {
        $warnings.Add(("GIT_SSH está definida ({0}); Git usará esa configuración si no hay core.sshCommand." -f $env:GIT_SSH))
    }

    $globalPaths = @(Get-EffectiveGlobalConfigPaths)
    $existingGlobalPaths = @($globalPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    $globalDetails = ($globalPaths -join '; ')
    if ($existingGlobalPaths.Count -gt 0) {
        $globalDetails = ($existingGlobalPaths -join '; ')
    }
    elseif ($globalPaths.Count -gt 0) {
        $globalDetails = ('{0} (se creará)' -f $globalPaths[0])
    }

    $checks.Add([pscustomobject]@{
        Name    = 'Configuración global'
        Status  = 'OK'
        Details = $globalDetails
    })

    $globalSshCommand = ''
    if ($gitAvailable) {
        $globalSshCommand = Get-GitConfigValue -Key 'core.sshCommand' -Global
    }
    if (-not [string]::IsNullOrWhiteSpace($globalSshCommand)) {
        $warnings.Add('Hay un core.sshCommand global. Los perfiles lo reemplazarán dentro de sus carpetas, pero los repositorios externos seguirán usando ese valor.')
    }

    $homePath = $env:USERPROFILE
    if (-not [string]::IsNullOrWhiteSpace($env:HOME) -and -not [string]::IsNullOrWhiteSpace($homePath)) {
        if (-not $env:HOME.Equals($homePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $warnings.Add(("HOME ({0}) y USERPROFILE ({1}) no coinciden. Revisa dónde espera Git encontrar ~/.ssh." -f $env:HOME, $homePath))
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.ssh') -PathType Container)) {
        $warnings.Add('La carpeta %USERPROFILE%\.ssh no existe; se creará si hace falta.')
    }

    return [pscustomobject]@{
        PowerShellVersion = $powerShellVersion
        GitAvailable      = $gitAvailable
        GitVersion        = $gitVersion
        GitPath           = $gitPath
        SshAvailable      = $sshAvailable
        SshVersion        = $sshVersion
        SshKeygenAvailable = $sshKeygenAvailable
        IsAdmin           = $isAdmin
        GlobalConfigPaths = $globalPaths
        GlobalSshCommand  = $globalSshCommand
        Checks            = $checks.ToArray()
        Errors            = @($errors)
        Warnings          = $warnings.ToArray()
    }
}

function Show-PreflightReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Report
    )

    Write-UiSection 'Comprobación del entorno'
    foreach ($check in @($Report.Checks)) {
        $prefix = '[OK]'
        $color = [ConsoleColor]::Green
        if ($check.Status -eq 'WARN') {
            $prefix = '[!]'
            $color = [ConsoleColor]::Yellow
        }
        elseif ($check.Status -eq 'ERROR') {
            $prefix = '[X]'
            $color = [ConsoleColor]::Red
        }

        Write-Ui ("{0} {1}: {2}" -f $prefix, $check.Name, $check.Details) $color
    }

    if ($Report.Warnings.Count -gt 0) {
        Write-Ui ''
        foreach ($warning in @($Report.Warnings)) {
            Write-UiWarn $warning
        }
    }

    if ($Report.Errors.Count -gt 0) {
        Write-Ui ''
        foreach ($errorMessage in @($Report.Errors)) {
            Write-UiError $errorMessage
        }
    }
}

function Assert-Preflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Report
    )

    if ($Report.Errors.Count -gt 0) {
        throw (($Report.Errors -join ' '))
    }
}
