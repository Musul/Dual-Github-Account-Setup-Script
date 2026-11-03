Set-StrictMode -Version Latest

function Test-SshAvailable {
    [CmdletBinding()]
    param()

    return [bool](Get-Command ssh -ErrorAction SilentlyContinue) -and
        [bool](Get-Command ssh-keygen -ErrorAction SilentlyContinue)
}

function Get-SshVersion {
    [CmdletBinding()]
    param()

    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        return $null
    }

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& ssh -V 2>&1)
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    return (($output | ForEach-Object { [string]$_ }) -join ' ').Trim()
}

function Get-SshExecutablePath {
    [CmdletBinding()]
    param()

    $command = Get-Command ssh -ErrorAction SilentlyContinue
    if ($command -eq $null) {
        return $null
    }

    return $command.Source
}

function Get-SshKeygenExecutablePath {
    [CmdletBinding()]
    param()

    $command = Get-Command ssh-keygen -ErrorAction SilentlyContinue
    if ($command -eq $null) {
        return $null
    }

    return $command.Source
}

function Get-SshKeyFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath
    )

    $normalized = ConvertTo-NormalizedPath -Path $KeyPath
    $publicPath = $normalized + '.pub'

    if (-not (Test-Path -LiteralPath $normalized -PathType Leaf)) {
        throw ("No existe la clave SSH: {0}" -f $normalized)
    }

    if (-not (Test-Path -LiteralPath $publicPath -PathType Leaf)) {
        if (Test-SshKeyEncrypted -KeyPath $normalized) {
            throw ("Falta la clave pública {0} y la clave privada tiene passphrase. Restaura el archivo .pub o genera una clave nueva." -f $publicPath)
        }
    }

    $target = $normalized
    if (Test-Path -LiteralPath $publicPath -PathType Leaf) {
        $target = $publicPath
    }

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& ssh-keygen -l -f $target 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw ("No se pudo leer la huella de la clave {0}: {1}" -f $normalized, (($output | ForEach-Object { [string]$_ }) -join ' '))
    }

    return (($output | ForEach-Object { [string]$_ }) -join ' ').Trim()
}

function Test-SshKeyEncrypted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath
    )

    $normalized = ConvertTo-NormalizedPath -Path $KeyPath
    if (-not (Test-Path -LiteralPath $normalized -PathType Leaf)) {
        throw ("No existe la clave SSH: {0}" -f $normalized)
    }

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & ssh-keygen -y -P '""' -f $normalized 2>&1 | Out-Null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    return ($exitCode -ne 0)
}

function Set-PrivateKeyAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath
    )

    $normalized = ConvertTo-NormalizedPath -Path $KeyPath
    if (-not (Test-Path -LiteralPath $normalized -PathType Leaf)) {
        throw ("No existe la clave SSH: {0}" -f $normalized)
    }

    if (-not (Get-Command icacls.exe -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Ok      = $false
            Message = 'icacls no está disponible; no se pudieron restringir los permisos.'
        }
    }

    if ($env:OS -ne 'Windows_NT') {
        return [pscustomobject]@{
            Ok      = $true
            Message = 'Los permisos se gestionan fuera de Windows.'
        }
    }

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        $identity = $env:USERNAME
    }

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & icacls.exe $normalized /inheritance:r 2>&1 | Out-Null
        $inheritExit = $LASTEXITCODE
        & icacls.exe $normalized /grant:r "${identity}:(R)" 2>&1 | Out-Null
        $grantExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($inheritExit -ne 0 -or $grantExit -ne 0) {
        return [pscustomobject]@{
            Ok      = $false
            Message = 'No se pudieron restringir los permisos de la clave con icacls.'
        }
    }

    return [pscustomobject]@{
        Ok      = $true
        Message = 'Permisos de la clave restringidos al usuario actual.'
    }
}

function New-GitHubSshKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath,
        [Parameter(Mandatory = $true)]
        [string]$Comment,
        [switch]$UsePassphrase,
        [switch]$NonInteractive,
        [switch]$DryRun
    )

    $normalized = ConvertTo-NormalizedPath -Path $KeyPath
    $publicPath = $normalized + '.pub'

    if (Test-Path -LiteralPath $normalized) {
        throw ("La clave ya existe y no se sobrescribirá: {0}" -f $normalized)
    }

    if (Test-Path -LiteralPath $publicPath) {
        throw ("Existe una clave pública sin clave privada: {0}. Elige otra ruta o elimina el archivo .pub." -f $publicPath)
    }

    if ($UsePassphrase -and $NonInteractive) {
        throw 'No se puede crear una clave con passphrase en modo no interactivo. Créala manualmente y vuelve a ejecutar.'
    }

    if ($DryRun) {
        Write-UiLog ("[dry-run] Generar clave SSH: {0}" -f $normalized) 'INFO'
        return [pscustomobject]@{
            KeyPath       = $normalized
            PublicKeyPath = $publicPath
            Fingerprint   = ''
            Encrypted     = [bool]$UsePassphrase
            Created       = $false
            Planned       = $true
        }
    }

    $parent = Split-Path -Parent $normalized
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw ("No se pudo determinar la carpeta de la clave: {0}" -f $normalized)
    }

    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $arguments = @('-t', 'ed25519', '-C', $Comment, '-f', $normalized)
    if (-not $UsePassphrase) {
        # PowerShell 5.1 drops a bare empty argument; passing two quotes makes
        # ssh-keygen interpret the passphrase as empty.
        $arguments += @('-N', '""')
    }

    Write-UiInfo ("Generando clave SSH ed25519: {0}" -f $normalized)
    Write-UiLog ("ssh-keygen {0}" -f ($arguments -join ' ')) 'INFO'

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($UsePassphrase) {
            # Do not capture the output: ssh-keygen needs to show its
            # passphrase prompt and read it from the console.
            & ssh-keygen @arguments | Out-Host
            $exitCode = $LASTEXITCODE
        }
        else {
            $keygenOutput = @(& ssh-keygen @arguments 2>&1)
            $exitCode = $LASTEXITCODE
        }
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if (-not $UsePassphrase) {
        foreach ($line in @($keygenOutput)) {
            Write-UiDetail ([string]$line)
        }
    }

    if ($exitCode -ne 0) {
        throw 'ssh-keygen no pudo crear la clave.'
    }

    if (-not (Test-Path -LiteralPath $normalized -PathType Leaf)) {
        throw ("No se creó la clave privada: {0}" -f $normalized)
    }

    if (-not (Test-Path -LiteralPath $publicPath -PathType Leaf)) {
        throw ("No se creó la clave pública: {0}" -f $publicPath)
    }

    $aclResult = Set-PrivateKeyAcl -KeyPath $normalized
    if (-not $aclResult.Ok) {
        Write-UiWarn $aclResult.Message
    }

    return [pscustomobject]@{
        KeyPath       = $normalized
        PublicKeyPath = $publicPath
        Fingerprint   = (Get-SshKeyFingerprint -KeyPath $normalized)
        Encrypted     = (Test-SshKeyEncrypted -KeyPath $normalized)
        Created       = $true
        Planned       = $false
    }
}

function New-SshCommandValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath
    )

    $normalized = ConvertTo-NormalizedPath -Path $KeyPath
    $escaped = $normalized.Replace("'", "'\''")
    return ("ssh -i '{0}' -F /dev/null -o IdentitiesOnly=yes" -f $escaped)
}

function Test-SshCommandParse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SshCommand
    )

    if ([string]::IsNullOrWhiteSpace($SshCommand)) {
        throw 'El comando SSH está vacío.'
    }

    $shellPath = $null
    $shell = Get-Command sh.exe -ErrorAction SilentlyContinue
    if ($shell -ne $null) {
        $shellPath = $shell.Source
    }
    else {
        $gitCommand = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCommand -ne $null) {
            $gitRoot = Split-Path -Parent (Split-Path -Parent $gitCommand.Source)
            $candidates = @(
                (Join-Path (Join-Path $gitRoot 'usr\bin') 'sh.exe'),
                (Join-Path (Join-Path $gitRoot 'bin') 'sh.exe')
            )
            foreach ($candidate in $candidates) {
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $shellPath = $candidate
                    break
                }
            }
        }
    }

    if ($shellPath -eq $null) {
        Write-UiLog 'No se encontró sh.exe; se omite la validación del comando SSH.' 'WARN'
        return [pscustomobject]@{
            Ok      = $true
            Skipped = $true
            Message = 'No se encontró sh.exe; validación omitida.'
        }
    }

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $command = "{0} -G github.com" -f $SshCommand
        $output = @(& $shellPath -c $command 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($exitCode -ne 0) {
        return [pscustomobject]@{
            Ok      = $false
            Skipped = $false
            Message = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        }
    }

    return [pscustomobject]@{
        Ok      = $true
        Skipped = $false
        Message = ''
    }
}

function Get-SshPublicKeyContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath
    )

    $normalized = ConvertTo-NormalizedPath -Path $KeyPath
    $publicPath = $normalized + '.pub'

    if (-not (Test-Path -LiteralPath $publicPath -PathType Leaf)) {
        throw ("No existe la clave pública: {0}" -f $publicPath)
    }

    return ([System.IO.File]::ReadAllText($publicPath)).Trim()
}

function ConvertFrom-GitHubSshOutput {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Output,
        [int]$ExitCode,
        [string]$ExpectedUser = ''
    )

    $text = ''
    if ($Output -ne $null) {
        $text = $Output
    }

    $greeting = [regex]::Match($text, "Hi\s+(?<user>[^!]+)!\s+You've successfully authenticated", 'IgnoreCase')
    if ($greeting.Success) {
        $user = $greeting.Groups['user'].Value.Trim()
        $matchesExpected = $true
        if (-not [string]::IsNullOrWhiteSpace($ExpectedUser)) {
            $matchesExpected = $user.Equals($ExpectedUser.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
        }

        return [pscustomobject]@{
            Ok          = $matchesExpected
            GitHubUser  = $user
            ErrorKind   = $(if ($matchesExpected) { '' } else { 'WrongAccount' })
            Message     = $(if ($matchesExpected) {
                    ("Autenticación correcta como {0}." -f $user)
                }
                else {
                    ("La clave autentica como {0}, pero se esperaba {1}." -f $user, $ExpectedUser)
                })
            RawOutput   = $text
            ExitCode    = $ExitCode
        }
    }

    $errorKind = 'Unknown'
    $message = 'No se pudo autenticar con GitHub.'

    if ($text -match 'Permission denied \(publickey\)') {
        $errorKind = 'NotRegistered'
        $message = 'GitHub rechazó la clave. Puede que no esté registrada en la cuenta o que la clave no sea válida.'
    }
    elseif ($text -match 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED') {
        $errorKind = 'HostKey'
        $message = 'La verificación de la clave del host falló. Revisa known_hosts y la huella de GitHub.'
    }
    elseif ($text -match 'Could not resolve hostname|Connection timed out|Connection refused|Network is unreachable|No route to host') {
        $errorKind = 'Network'
        $message = 'No se pudo conectar con github.com. Revisa tu conexión, firewall o proxy.'
    }
    elseif ($text -match 'BatchMode') {
        $errorKind = 'EncryptedKey'
        $message = 'La clave parece tener passphrase y el modo automático no puede pedirla. Cárgala en ssh-agent o usa una clave sin passphrase.'
    }

    return [pscustomobject]@{
        Ok          = $false
        GitHubUser  = ''
        ErrorKind   = $errorKind
        Message     = $message
        RawOutput   = $text
        ExitCode    = $ExitCode
    }
}

function Test-GitHubSshAuth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath,
        [string]$ExpectedUser = '',
        [switch]$TemporaryKnownHosts,
        [switch]$NoBatchMode,
        [switch]$AcceptNewHostKey
    )

    $normalizedKey = ConvertTo-NormalizedPath -Path $KeyPath
    if (-not (Test-Path -LiteralPath $normalizedKey -PathType Leaf)) {
        throw ("No existe la clave SSH: {0}" -f $normalizedKey)
    }

    $temporaryDir = $null
    $knownHostsOption = $null
    if ($TemporaryKnownHosts) {
        $temporaryDir = New-TemporaryDirectory -Prefix 'dgh-known-hosts'
        $knownHostsPath = Join-Path $temporaryDir 'known_hosts'
        $knownHostsOption = $knownHostsPath
    }

    $arguments = @(
        '-T',
        '-i', $normalizedKey,
        '-F', '/dev/null',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'ConnectTimeout=10'
    )

    if (-not $NoBatchMode) {
        $arguments += @('-o', 'BatchMode=yes')
    }

    if ($AcceptNewHostKey -or $TemporaryKnownHosts) {
        $arguments += @('-o', 'StrictHostKeyChecking=accept-new')
    }

    if (-not [string]::IsNullOrWhiteSpace($knownHostsOption)) {
        $arguments += @('-o', ("UserKnownHostsFile={0}" -f $knownHostsOption))
    }

    $arguments += 'git@github.com'

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rawOutput = @(& ssh @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    catch {
        $ErrorActionPreference = $oldErrorActionPreference
        throw ("No se pudo ejecutar ssh: {0}" -f $_.Exception.Message)
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
        if ($temporaryDir -ne $null) {
            Remove-TemporaryDirectory -Path $temporaryDir
        }
    }

    $text = (($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    $parsed = ConvertFrom-GitHubSshOutput -Output $text -ExitCode $exitCode -ExpectedUser $ExpectedUser

    if (-not $parsed.Ok -and $parsed.ErrorKind -eq 'NotRegistered') {
        $encrypted = $false
        try {
            $encrypted = Test-SshKeyEncrypted -KeyPath $normalizedKey
        }
        catch {
            $encrypted = $false
        }
        if ($encrypted -and -not $NoBatchMode) {
            $parsed.ErrorKind = 'EncryptedKey'
            $parsed.Message = 'La clave tiene passphrase. Cárgala en ssh-agent o ejecuta la verificación de forma interactiva.'
        }
    }

    Write-UiLog ("ssh -T ({0}) -> {1}; {2}" -f $normalizedKey, $exitCode, $parsed.Message) 'DEBUG'
    return $parsed
}
