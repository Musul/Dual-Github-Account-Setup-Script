Set-StrictMode -Version Latest

function Invoke-GitCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git no está instalado o no está en PATH.'
    }

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rawLines = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    catch {
        $ErrorActionPreference = $oldErrorActionPreference
        throw ("No se pudo ejecutar Git: {0}" -f $_.Exception.Message)
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    $textLines = @()
    foreach ($line in $rawLines) {
        $textLines += [string]$line
    }

    $result = [pscustomobject]@{
        ExitCode  = $exitCode
        RawLines  = $textLines
        Output    = ($textLines -join [Environment]::NewLine)
        Arguments = $Arguments
    }

    Write-UiLog ("git {0} -> {1}" -f ($Arguments -join ' '), $exitCode) 'DEBUG'

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw ("Git falló con código {0}: git {1}`n{2}" -f $exitCode, ($Arguments -join ' '), $result.Output)
    }

    return $result
}

function Test-GitAvailable {
    [CmdletBinding()]
    param()

    return [bool](Get-Command git -ErrorAction SilentlyContinue)
}

function Get-GitVersion {
    [CmdletBinding()]
    param()

    if (-not (Test-GitAvailable)) {
        return $null
    }

    $result = Invoke-GitCommand -Arguments @('--version') -AllowFailure
    if ($result.ExitCode -ne 0) {
        return $null
    }

    $match = [regex]::Match($result.Output, 'git version\s+([0-9]+(?:\.[0-9]+)*)', 'IgnoreCase')
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return $null
}

function Get-GitExecutablePath {
    [CmdletBinding()]
    param()

    $command = Get-Command git -ErrorAction SilentlyContinue
    if ($command -eq $null) {
        return $null
    }

    return $command.Source
}

function ConvertFrom-GitQuotedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path
    )

    $value = $Path
    if (-not ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2)) {
        return $value
    }

    $inner = $value.Substring(1, $value.Length - 2)
    $bytes = New-Object System.Collections.Generic.List[byte]
    $index = 0

    while ($index -lt $inner.Length) {
        $character = $inner[$index]

        if ($character -ne '\') {
            $literalBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$character)
            foreach ($literalByte in $literalBytes) {
                $bytes.Add($literalByte)
            }
            $index++
            continue
        }

        if ($index + 1 -ge $inner.Length) {
            $bytes.Add([byte]92)
            $index++
            continue
        }

        $escaped = $inner[$index + 1]
        $escapeCode = [int][char]$escaped

        if ($escaped -eq '\') {
            $bytes.Add([byte]92)
            $index += 2
        }
        elseif ($escaped -eq '"') {
            $bytes.Add([byte]34)
            $index += 2
        }
        elseif ($escaped -eq 't') {
            $bytes.Add([byte]9)
            $index += 2
        }
        elseif ($escaped -eq 'n') {
            $bytes.Add([byte]10)
            $index += 2
        }
        elseif ($escaped -eq 'r') {
            $bytes.Add([byte]13)
            $index += 2
        }
        elseif ($escaped -eq 'b') {
            $bytes.Add([byte]8)
            $index += 2
        }
        elseif ($escaped -eq 'f') {
            $bytes.Add([byte]12)
            $index += 2
        }
        elseif ($escaped -eq 'v') {
            $bytes.Add([byte]11)
            $index += 2
        }
        elseif ($escaped -eq 'a') {
            $bytes.Add([byte]7)
            $index += 2
        }
        elseif ($escapeCode -ge 48 -and $escapeCode -le 55) {
            $octal = ''
            $octalIndex = $index + 1
            while ($octalIndex -lt $inner.Length -and $octalIndex -lt ($index + 4)) {
                $octalCharacter = $inner[$octalIndex]
                $octalCode = [int][char]$octalCharacter
                if ($octalCode -lt 48 -or $octalCode -gt 55) {
                    break
                }
                $octal += [string]$octalCharacter
                $octalIndex++
            }
            $bytes.Add([Convert]::ToByte($octal, 8))
            $index = $octalIndex
        }
        else {
            $bytes.Add([byte]92)
            $bytes.Add([byte]$escapeCode)
            $index += 2
        }
    }

    return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

function ConvertFrom-GitShowOriginLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    $tabIndex = $Line.IndexOf("`t")
    if ($tabIndex -lt 0) {
        return [pscustomobject]@{
            Origin = ''
            Value  = $Line
        }
    }

    $origin = $Line.Substring(0, $tabIndex)
    $value = $Line.Substring($tabIndex + 1)

    if ($origin.StartsWith('file:')) {
        $origin = $origin.Substring(5)
    }

    $origin = ConvertFrom-GitQuotedPath -Path $origin

    return [pscustomobject]@{
        Origin = $origin
        Value  = $value
    }
}

function Get-EffectiveGlobalConfigPaths {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:GIT_CONFIG_GLOBAL)) {
        return @((ConvertTo-NormalizedPath -Path $env:GIT_CONFIG_GLOBAL))
    }

    $candidates = New-Object System.Collections.Generic.List[string]

    $homePath = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($homePath)) {
        $homePath = $HOME
    }

    if (-not [string]::IsNullOrWhiteSpace($homePath)) {
        $candidates.Add((ConvertTo-NormalizedPath -Path (Join-Path $homePath '.gitconfig')))
        $candidates.Add((ConvertTo-NormalizedPath -Path (Join-Path (Join-Path (Join-Path $homePath '.config') 'git') 'config')))
    }

    if (-not [string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) {
        try {
            $candidates.Add((ConvertTo-NormalizedPath -Path (Join-Path (Join-Path $env:XDG_CONFIG_HOME 'git') 'config')))
        }
        catch {
            # Ignore invalid XDG values.
        }
    }

    if (Test-GitAvailable) {
        $result = Invoke-GitCommand -Arguments @('config', '--global', '--list', '--show-origin') -AllowFailure
        if ($result.ExitCode -eq 0) {
            foreach ($line in $result.RawLines) {
                $parsed = ConvertFrom-GitShowOriginLine -Line $line
                if ($parsed -ne $null -and -not [string]::IsNullOrWhiteSpace($parsed.Origin)) {
                    try {
                        $candidates.Add((ConvertTo-NormalizedPath -Path $parsed.Origin))
                    }
                    catch {
                        # Ignore unparseable origins.
                    }
                }
            }
        }
    }

    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        $found = $false
        foreach ($existing in $unique) {
            if ($existing.Equals($candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            $unique.Add($candidate)
        }
    }

    if ($unique.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($homePath)) {
        $unique.Add((ConvertTo-NormalizedPath -Path (Join-Path $homePath '.gitconfig')))
    }

    return $unique.ToArray()
}

function Get-GlobalConfigPathForDisplay {
    [CmdletBinding()]
    param()

    $paths = @(Get-EffectiveGlobalConfigPaths)
    $existing = @($paths | Where-Object { Test-Path -LiteralPath $_ })
    if ($existing.Count -gt 0) {
        return $existing
    }

    return $paths
}

function Get-GitConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [string]$File,
        [switch]$Global,
        [switch]$AllowMissing
    )

    $arguments = @('config')
    if ($Global) {
        $arguments += '--global'
    }
    if (-not [string]::IsNullOrWhiteSpace($File)) {
        $arguments += @('--file', $File)
    }
    $arguments += @('--get', $Key)

    $result = Invoke-GitCommand -Arguments $arguments -AllowFailure
    if ($result.ExitCode -ne 0) {
        if ($AllowMissing) {
            return $null
        }
        return $null
    }

    return $result.Output.Trim()
}

function New-IncludeIfKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedRoot = ConvertTo-NormalizedPath -Path $Root
    if ($normalizedRoot -match '^[A-Za-z]:/$') {
        throw 'No se puede usar la raíz de una unidad como carpeta de perfil.'
    }

    $normalizedRoot = $normalizedRoot.TrimEnd('/')
    return ('includeIf.gitdir/i:{0}/.path' -f $normalizedRoot)
}

function Get-ManagedIncludeIfEntries {
    [CmdletBinding()]
    param()

    if (-not (Test-GitAvailable)) {
        return @()
    }

    $result = Invoke-GitCommand -Arguments @(
        'config', '--global', '--get-regexp', '^includeIf\.gitdir/i:.*\.path$'
    ) -AllowFailure

    if ($result.ExitCode -ne 0) {
        return @()
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($rawLine in $result.RawLines) {
        $line = ([string]$rawLine).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $match = [regex]::Match(
            $line,
            '^(?<key>includeIf\.gitdir/i:.+?\.path)\s+(?<value>.+)$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if (-not $match.Success) {
            Write-UiWarn ("No se pudo interpretar una entrada includeIf: {0}" -f $line)
            continue
        }

        $key = $match.Groups['key'].Value
        $value = $match.Groups['value'].Value.Trim()

        $root = ''
        $prefixLength = 'includeIf.gitdir/i:'.Length
        $body = $key.Substring($prefixLength)
        if ($body.EndsWith('/.path', [System.StringComparison]::OrdinalIgnoreCase)) {
            $root = $body.Substring(0, $body.Length - '/.path'.Length)
        }
        elseif ($body.EndsWith('.path', [System.StringComparison]::OrdinalIgnoreCase)) {
            $root = $body.Substring(0, $body.Length - '.path'.Length).TrimEnd('/')
        }

        try {
            $normalizedRoot = ConvertTo-NormalizedPath -Path $root
            $normalizedValue = ConvertTo-NormalizedPath -Path $value
        }
        catch {
            $normalizedRoot = $root
            $normalizedValue = $value
        }

        $entries.Add([pscustomobject]@{
            Key         = $key
            Value       = $value
            Root        = $normalizedRoot
            ConfigPath  = $normalizedValue
        })
    }

    return $entries.ToArray()
}

function Get-IncludeIfEntriesForRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedRoot = ConvertTo-NormalizedPath -Path $Root
    $matches = @()
    foreach ($entry in @(Get-ManagedIncludeIfEntries)) {
        if ($entry.Root.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matches += $entry
        }
    }

    return $matches
}

function Set-ManagedIncludeIf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [switch]$Remove,
        [switch]$DryRun
    )

    $key = New-IncludeIfKey -Root $Root
    $normalizedConfig = ConvertTo-NormalizedPath -Path $ConfigPath

    if ($Remove) {
        if ($DryRun) {
            Write-UiLog ("[dry-run] Eliminar includeIf: {0}" -f $key) 'INFO'
            return
        }

        Invoke-GitCommand -Arguments @('config', '--global', '--unset-all', $key) -AllowFailure | Out-Null
        Write-UiLog ("Entrada includeIf eliminada: {0}" -f $key) 'INFO'
        return
    }

    if ($DryRun) {
        Write-UiLog ("[dry-run] includeIf: {0} -> {1}" -f $key, $normalizedConfig) 'INFO'
        return
    }

    $existingEntries = @(Get-ManagedIncludeIfEntries)
    foreach ($entry in $existingEntries) {
        if ($entry.Key.Equals($key, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if ($entry.ConfigPath.Equals($normalizedConfig, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-UiLog ("Eliminando entrada includeIf antigua del mismo perfil: {0}" -f $entry.Key) 'INFO'
            Invoke-GitCommand -Arguments @('config', '--global', '--unset-all', $entry.Key) -AllowFailure | Out-Null
        }
    }

    Invoke-GitCommand -Arguments @(
        'config', '--global', '--replace-all', $key, $normalizedConfig
    ) | Out-Null

    $values = Invoke-GitCommand -Arguments @('config', '--global', '--get-all', $key) -AllowFailure
    if ($values.ExitCode -ne 0 -or $values.RawLines.Count -ne 1) {
        throw ("No se pudo verificar la entrada includeIf: {0}" -f $key)
    }

    Write-UiLog ("includeIf configurado: {0} -> {1}" -f $key, $normalizedConfig) 'INFO'
}

function Remove-ManagedIncludeIf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [switch]$DryRun
    )

    if ($DryRun) {
        Write-UiLog ("[dry-run] Eliminar includeIf: {0}" -f $Key) 'INFO'
        return
    }

    Invoke-GitCommand -Arguments @('config', '--global', '--unset-all', $Key) -AllowFailure | Out-Null
    Write-UiLog ("Entrada includeIf eliminada: {0}" -f $Key) 'INFO'
}

function Get-SshKeyPathFromCommand {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$SshCommand
    )

    if ([string]::IsNullOrWhiteSpace($SshCommand)) {
        return $null
    }

    $match = [regex]::Match($SshCommand, "-i\s+(?:'([^']+)'|`"([^`"]+)`"|(\S+))")
    if (-not $match.Success) {
        return $null
    }

    for ($index = 1; $index -le 3; $index++) {
        if ($match.Groups[$index].Success -and -not [string]::IsNullOrWhiteSpace($match.Groups[$index].Value)) {
            return $match.Groups[$index].Value
        }
    }

    return $null
}

function Get-ProfileConfigValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $normalized = ConvertTo-NormalizedPath -Path $ConfigPath
    $exists = Test-Path -LiteralPath $normalized -PathType Leaf

    $sshCommand = Get-GitConfigValue -Key 'core.sshCommand' -File $normalized
    $userName = Get-GitConfigValue -Key 'user.name' -File $normalized
    $email = Get-GitConfigValue -Key 'user.email' -File $normalized
    $keyPath = Get-SshKeyPathFromCommand -SshCommand $sshCommand

    return [pscustomobject]@{
        ConfigPath = $normalized
        Exists     = $exists
        SshCommand = $sshCommand
        KeyPath    = $keyPath
        UserName   = $userName
        Email      = $email
    }
}

function Write-ProfileGitConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [Parameter(Mandatory = $true)]
        [string]$SshCommand,
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [Parameter(Mandatory = $true)]
        [string]$Email,
        [switch]$DryRun
    )

    $normalized = ConvertTo-NormalizedPath -Path $ConfigPath
    $parent = Split-Path -Parent $normalized
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw ("No se pudo determinar la carpeta de configuración: {0}" -f $normalized)
    }

    if ($DryRun) {
        Write-UiLog ("[dry-run] Escribir configuración {0}" -f $normalized) 'INFO'
        Write-UiLog ("[dry-run]   core.sshCommand = {0}" -f $SshCommand) 'INFO'
        Write-UiLog ("[dry-run]   user.name = {0}" -f $UserName) 'INFO'
        Write-UiLog ("[dry-run]   user.email = {0}" -f $Email) 'INFO'
        return
    }

    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Invoke-GitCommand -Arguments @('config', '--file', $normalized, '--replace-all', 'core.sshCommand', $SshCommand) | Out-Null
    Invoke-GitCommand -Arguments @('config', '--file', $normalized, '--replace-all', 'user.name', $UserName) | Out-Null
    Invoke-GitCommand -Arguments @('config', '--file', $normalized, '--replace-all', 'user.email', $Email) | Out-Null

    $check = Get-ProfileConfigValues -ConfigPath $normalized
    if (-not $check.Exists) {
        throw ("No se creó el archivo de configuración: {0}" -f $normalized)
    }
    if ($check.SshCommand -ne $SshCommand) {
        throw ("core.sshCommand no se guardó correctamente en {0}" -f $normalized)
    }
    if ($check.UserName -ne $UserName) {
        throw ("user.name no se guardó correctamente en {0}" -f $normalized)
    }
    if ($check.Email -ne $Email) {
        throw ("user.email no se guardó correctamente en {0}" -f $normalized)
    }

    Write-UiLog ("Configuración escrita: {0}" -f $normalized) 'INFO'
}

function Get-GitConfigWithOrigin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $result = Invoke-GitCommand -Arguments @(
        '-C', $RepositoryPath, 'config', '--show-origin', '--get', $Key
    ) -AllowFailure

    if ($result.ExitCode -ne 0) {
        return $null
    }

    $parsed = ConvertFrom-GitShowOriginLine -Line $result.Output
    if ($parsed -eq $null) {
        return $null
    }

    $origin = $parsed.Origin
    if (-not [string]::IsNullOrWhiteSpace($origin)) {
        try {
            $origin = ConvertTo-NormalizedPath -Path $origin
        }
        catch {
            # Keep the raw origin if it cannot be normalized.
        }
    }

    return [pscustomobject]@{
        Key    = $Key
        Origin = $origin
        Value  = $parsed.Value
    }
}

function Test-ProfileConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [Parameter(Mandatory = $true)]
        [string]$SshCommand,
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [Parameter(Mandatory = $true)]
        [string]$Email
    )

    $normalizedRoot = ConvertTo-NormalizedPath -Path $Root
    $normalizedConfig = ConvertTo-NormalizedPath -Path $ConfigPath
    $temporaryRepo = Join-Path $normalizedRoot ('.dgh-check-{0}' -f [guid]::NewGuid().ToString('N'))
    $errors = New-Object System.Collections.Generic.List[string]
    $values = [ordered]@{}

    if (-not (Test-Path -LiteralPath $normalizedRoot -PathType Container)) {
        throw ("La carpeta raíz no existe: {0}" -f $normalizedRoot)
    }

    try {
        $init = Invoke-GitCommand -Arguments @('-C', $normalizedRoot, 'init', '--quiet', $temporaryRepo) -AllowFailure
        if ($init.ExitCode -ne 0) {
            throw ("No se pudo crear el repositorio temporal: {0}" -f $init.Output)
        }

        $sshValue = Get-GitConfigWithOrigin -RepositoryPath $temporaryRepo -Key 'core.sshCommand'
        $nameValue = Get-GitConfigWithOrigin -RepositoryPath $temporaryRepo -Key 'user.name'
        $emailValue = Get-GitConfigWithOrigin -RepositoryPath $temporaryRepo -Key 'user.email'

        $values['core.sshCommand'] = $sshValue
        $values['user.name'] = $nameValue
        $values['user.email'] = $emailValue

        if ($sshValue -eq $null) {
            $errors.Add('core.sshCommand no se aplicó dentro de la carpeta raíz.')
        }
        else {
            if ($sshValue.Value -ne $SshCommand) {
                $errors.Add('core.sshCommand no coincide con el valor esperado.')
            }
            if (-not $sshValue.Origin.Equals($normalizedConfig, [System.StringComparison]::OrdinalIgnoreCase)) {
                $errors.Add(("core.sshCommand no viene del archivo de perfil esperado: {0}" -f $sshValue.Origin))
            }
        }

        if ($nameValue -eq $null -or $nameValue.Value -ne $UserName) {
            $errors.Add('user.name no se aplicó correctamente dentro de la carpeta raíz.')
        }
        if ($emailValue -eq $null -or $emailValue.Value -ne $Email) {
            $errors.Add('user.email no se aplicó correctamente dentro de la carpeta raíz.')
        }

        $author = Invoke-GitCommand -Arguments @('-C', $temporaryRepo, 'var', 'GIT_AUTHOR_IDENT') -AllowFailure
        if ($author.ExitCode -ne 0 -or -not $author.Output.Contains($Email)) {
            $errors.Add('La identidad efectiva de Git no contiene el email esperado.')
        }
    }
    finally {
        Remove-TemporaryDirectory -Path $temporaryRepo
    }

    return [pscustomobject]@{
        Ok     = ($errors.Count -eq 0)
        Errors = $errors.ToArray()
        Values = $values
    }
}

function Test-OutsideProfileConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Roots,
        [Parameter(Mandatory = $true)]
        [string[]]$ProfileConfigPaths
    )

    $tempBase = [System.IO.Path]::GetTempPath()
    foreach ($root in $Roots) {
        if (Test-PathWithin -Child $tempBase -Parent $root) {
            return [pscustomobject]@{
                Ok      = $true
                Skipped = $true
                Message = 'La carpeta temporal está dentro de una raíz; se omite la comprobación externa.'
            }
        }
    }

    $temporaryRepo = Join-Path $tempBase ('.dgh-outside-{0}' -f [guid]::NewGuid().ToString('N'))
    $errors = New-Object System.Collections.Generic.List[string]

    try {
        $init = Invoke-GitCommand -Arguments @('init', '--quiet', $temporaryRepo) -AllowFailure
        if ($init.ExitCode -ne 0) {
            throw ("No se pudo crear el repositorio temporal externo: {0}" -f $init.Output)
        }

        $sshValue = Get-GitConfigWithOrigin -RepositoryPath $temporaryRepo -Key 'core.sshCommand'
        if ($sshValue -ne $null) {
            foreach ($profileConfig in $ProfileConfigPaths) {
                if ($sshValue.Origin.Equals($profileConfig, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $errors.Add('core.sshCommand de un repositorio externo viene de un archivo de perfil.')
                }
            }
        }

        $emailValue = Get-GitConfigWithOrigin -RepositoryPath $temporaryRepo -Key 'user.email'
        if ($emailValue -ne $null) {
            foreach ($profileConfig in $ProfileConfigPaths) {
                if ($emailValue.Origin.Equals($profileConfig, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $errors.Add('user.email de un repositorio externo viene de un archivo de perfil.')
                }
            }
        }
    }
    finally {
        Remove-TemporaryDirectory -Path $temporaryRepo
    }

    return [pscustomobject]@{
        Ok      = ($errors.Count -eq 0)
        Skipped = $false
        Errors  = $errors.ToArray()
        Message = ''
    }
}
