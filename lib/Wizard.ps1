Set-StrictMode -Version Latest

function New-SetupStateObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath
    )

    $now = (Get-Date).ToString('o')
    return [pscustomobject]@{
        version             = 1
        createdAt           = $now
        updatedAt           = $now
        status              = 'started'
        statePath           = $StatePath
        profiles            = @()
        managedIncludeKeys  = @()
        backup              = $null
    }
}

function New-ProfileObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [string]$GitHubUser = '',
        [string]$CommitName = '',
        [string]$Email = '',
        [Parameter(Mandatory = $true)]
        [string]$KeyPath,
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [bool]$UsePassphrase = $false,
        [bool]$CreateRoot = $true,
        [bool]$IsDetected = $false
    )

    return [pscustomobject]@{
        id             = $Id
        label          = $Label
        root           = $Root
        githubUser     = $GitHubUser
        commitName     = $CommitName
        email          = $Email
        keyPath        = $KeyPath
        configPath     = $ConfigPath
        usePassphrase  = $UsePassphrase
        createRoot     = $CreateRoot
        isDetected     = $IsDetected
        rootExisted    = $false
        keyExisted     = $false
        configExisted  = $false
        keyCreated     = $false
        fingerprint    = ''
        encrypted      = $false
        sshCommand     = ''
        authUser       = ''
        authOk         = $false
        verificationOk = $false
    }
}

function Test-GitHubUsername {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    return ($Value -match '^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$')
}

function Test-EmailAddress {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    return ($Value -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')
}

function Get-DetectedProfiles {
    [CmdletBinding()]
    param(
        [switch]$ResolveAccounts
    )

    $entries = @(Get-ManagedIncludeIfEntries)
    $profiles = New-Object System.Collections.Generic.List[object]
    $usedIds = @()
    $index = 0

    foreach ($entry in $entries) {
        $values = Get-ProfileConfigValues -ConfigPath $entry.ConfigPath

        $id = ''
        $haystack = ('{0} {1}' -f $entry.Root, $entry.ConfigPath).ToLowerInvariant()
        if ($haystack -match 'work|trabajo|empresa|company') {
            $id = 'work'
        }
        elseif ($haystack -match 'personal|persona') {
            $id = 'personal'
        }
        else {
            $id = $(if ($index -eq 0) { 'personal' } else { 'work' })
        }

        if ($usedIds -contains $id) {
            $id = $(if ($id -eq 'personal') { 'work' } else { 'personal' })
        }
        $usedIds += $id

        $label = $(if ($id -eq 'work') { 'Trabajo' } else { 'Personal' })
        $githubUser = ''
        if ($ResolveAccounts -and -not [string]::IsNullOrWhiteSpace($values.KeyPath) -and (Test-Path -LiteralPath $values.KeyPath -PathType Leaf)) {
            try {
                $encrypted = Test-SshKeyEncrypted -KeyPath $values.KeyPath
                if (-not $encrypted) {
                    $auth = Test-GitHubSshAuth -KeyPath $values.KeyPath -TemporaryKnownHosts
                    if ($auth.Ok) {
                        $githubUser = $auth.GitHubUser
                    }
                }
            }
            catch {
                Write-UiLog ("No se pudo resolver la cuenta de {0}: {1}" -f $values.KeyPath, $_.Exception.Message) 'WARN'
            }
        }

        $detectedRoot = [string]$entry.Root
        if ([string]::IsNullOrWhiteSpace($detectedRoot)) {
            $detectedRoot = Get-DefaultRoot -ProfileId $id
        }
        $detectedKeyPath = [string]$values.KeyPath
        if ([string]::IsNullOrWhiteSpace($detectedKeyPath)) {
            $detectedKeyPath = Get-DefaultKeyPath -ProfileId $id
        }

        $profile = New-ProfileObject -Id $id -Label $label -Root $detectedRoot -GitHubUser $githubUser `
            -CommitName ([string]$values.UserName) -Email ([string]$values.Email) `
            -KeyPath $detectedKeyPath -ConfigPath $entry.ConfigPath -IsDetected $true

        $profile.rootExisted = Test-Path -LiteralPath $profile.root -PathType Container
        $profile.keyExisted = -not [string]::IsNullOrWhiteSpace($profile.keyPath) -and (Test-Path -LiteralPath $profile.keyPath -PathType Leaf)
        $profile.configExisted = $values.Exists

        $profiles.Add($profile)
        $index++
    }

    return $profiles.ToArray()
}

function Get-ProfileDefaults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [object[]]$Detected = @(),
        [bool]$UseDetected = $false
    )

    $label = 'Personal'
    if ($Id -eq 'work') {
        $label = 'Trabajo'
    }

    $detectedProfile = $null
    if ($UseDetected) {
        foreach ($profile in @($Detected)) {
            if ($profile.id -eq $Id) {
                $detectedProfile = $profile
                break
            }
        }
    }

    $globalName = Get-GitConfigValue -Key 'user.name' -Global
    $globalEmail = Get-GitConfigValue -Key 'user.email' -Global

    if ($detectedProfile -ne $null) {
        $detectedKeyPath = [string]$detectedProfile.keyPath
        if ([string]::IsNullOrWhiteSpace($detectedKeyPath)) {
            $detectedKeyPath = Get-DefaultKeyPath -ProfileId $Id
        }
        $detectedConfigPath = [string]$detectedProfile.configPath
        if ([string]::IsNullOrWhiteSpace($detectedConfigPath)) {
            $detectedConfigPath = Get-DefaultConfigPath -ProfileId $Id
        }
        $detectedName = [string]$detectedProfile.commitName
        $detectedEmail = [string]$detectedProfile.email
        if ($Id -eq 'work' -and [string]::IsNullOrWhiteSpace($detectedName)) {
            $detectedName = [string]$globalName
        }
        if ($Id -eq 'work' -and [string]::IsNullOrWhiteSpace($detectedEmail)) {
            $detectedEmail = [string]$globalEmail
        }

        return [pscustomobject]@{
            Id            = $Id
            Label         = $detectedProfile.label
            Root          = $detectedProfile.root
            GitHubUser    = $detectedProfile.githubUser
            CommitName    = $detectedName
            Email         = $detectedEmail
            KeyPath       = $detectedKeyPath
            ConfigPath    = $detectedConfigPath
            UsePassphrase = $false
            IsDetected    = $true
        }
    }

    $defaultName = ''
    $defaultEmail = ''
    if ($Id -eq 'work') {
        $defaultName = [string]$globalName
        $defaultEmail = [string]$globalEmail
    }

    return [pscustomobject]@{
        Id            = $Id
        Label         = $label
        Root          = Get-DefaultRoot -ProfileId $Id
        GitHubUser    = ''
        CommitName    = $defaultName
        Email         = $defaultEmail
        KeyPath       = Get-DefaultKeyPath -ProfileId $Id
        ConfigPath    = Get-DefaultConfigPath -ProfileId $Id
        UsePassphrase = $false
        IsDetected    = $false
    }
}

function Read-ProfileInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [Parameter(Mandatory = $true)]
        [object]$Defaults
    )

    $label = Read-UiText -Prompt 'Nombre visible del perfil' -Default ([string]$Defaults.Label) -Required
    $rootValidator = {
        param($value)
        try {
            $validation = Get-RootValidation -Root $value
        }
        catch {
            return $_.Exception.Message
        }
        if ($validation.Errors.Count -gt 0) {
            return ($validation.Errors -join ' ')
        }
        return $null
    }

    $root = Read-UiText -Prompt 'Carpeta raíz para los repositorios' -Default ([string]$Defaults.Root) -Required -Validator $rootValidator
    $root = ConvertTo-NormalizedPath -Path $root
    $rootValidation = Get-RootValidation -Root $root
    foreach ($warning in @($rootValidation.Warnings)) {
        Write-UiWarn $warning
    }

    $userValidator = {
        param($value)
        if (-not (Test-GitHubUsername -Value $value)) {
            return 'El usuario de GitHub solo puede tener letras, números y guiones, y no puede empezar ni terminar con guion.'
        }
        return $null
    }

    $githubUser = Read-UiText -Prompt 'Usuario de GitHub' -Default ([string]$Defaults.GitHubUser) -Required -Validator $userValidator

    $commitName = Read-UiText -Prompt 'Nombre para los commits' -Default ([string]$Defaults.CommitName) -Required

    $emailValidator = {
        param($value)
        if (-not (Test-EmailAddress -Value $value)) {
            return 'El email no tiene un formato válido.'
        }
        return $null
    }

    Write-UiHint 'Usa el email verificado en la cuenta de GitHub correspondiente.'
    $email = Read-UiText -Prompt 'Email para los commits' -Default ([string]$Defaults.Email) -Required -Validator $emailValidator

    $keyDefault = [string]$Defaults.KeyPath
    if ([string]::IsNullOrWhiteSpace($keyDefault)) {
        $keyDefault = Get-DefaultKeyPath -ProfileId $Id
    }
    $keyPath = ConvertTo-NormalizedPath -Path $keyDefault
    while ($true) {
        $keyPath = Read-UiText -Prompt 'Ruta de la clave privada SSH' -Default $keyPath -Required
        $keyPath = ConvertTo-NormalizedPath -Path $keyPath

        if (Test-Path -LiteralPath $keyPath -PathType Container) {
            Write-UiWarn 'La ruta de la clave es una carpeta.'
            continue
        }

        if (Test-Path -LiteralPath $keyPath -PathType Leaf) {
            try {
                $fingerprint = Get-SshKeyFingerprint -KeyPath $keyPath
                Write-UiInfo ("Clave existente: {0}" -f $fingerprint)
                $encrypted = Test-SshKeyEncrypted -KeyPath $keyPath
                if ($encrypted) {
                    Write-UiWarn 'La clave tiene passphrase. Necesitarás cargarla en ssh-agent para que Git no la pida siempre.'
                }
            }
            catch {
                Write-UiWarn ("No se pudo inspeccionar la clave existente: {0}" -f $_.Exception.Message)
            }

            if (-not (Read-UiYesNo '¿Usar esta clave existente?' $true)) {
                $keyPath = ''
                continue
            }
        }

        if (Test-PathWithin -Child $keyPath -Parent $root) {
            Write-UiWarn 'La clave está dentro de la carpeta raíz de repositorios. Se recomienda guardarla en %USERPROFILE%\.ssh.'
        }

        break
    }

    $configDefault = [string]$Defaults.ConfigPath
    if ([string]::IsNullOrWhiteSpace($configDefault)) {
        $configDefault = Get-DefaultConfigPath -ProfileId $Id
    }
    $configPath = ConvertTo-NormalizedPath -Path $configDefault
    while ($true) {
        $configPath = Read-UiText -Prompt 'Archivo de configuración Git del perfil' -Default $configPath -Required
        $configPath = ConvertTo-NormalizedPath -Path $configPath

        if (Test-Path -LiteralPath $configPath -PathType Container) {
            Write-UiWarn 'La ruta de configuración es una carpeta.'
            continue
        }

        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $values = Get-ProfileConfigValues -ConfigPath $configPath
            Write-UiInfo ("Configuración existente: {0}" -f $configPath)
            if (-not [string]::IsNullOrWhiteSpace($values.UserName)) {
                Write-UiDetail ("user.name: {0}" -f $values.UserName)
            }
            if (-not [string]::IsNullOrWhiteSpace($values.Email)) {
                Write-UiDetail ("user.email: {0}" -f $values.Email)
            }
            if (-not [string]::IsNullOrWhiteSpace($values.SshCommand)) {
                Write-UiDetail ("core.sshCommand: {0}" -f $values.SshCommand)
            }

            if (-not (Read-UiYesNo '¿Actualizar este archivo de configuración?' $true)) {
                $configPath = ''
                continue
            }
        }

        break
    }

    $usePassphrase = $false
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
        $usePassphrase = Read-UiYesNo '¿Proteger la nueva clave con passphrase?' $false
    }

    return New-ProfileObject -Id $Id -Label $label -Root $root -GitHubUser $githubUser `
        -CommitName $commitName -Email $email -KeyPath $keyPath -ConfigPath $configPath `
        -UsePassphrase $usePassphrase -IsDetected ([bool]$Defaults.IsDetected)
}

function Assert-Profiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Profiles
    )

    if ($Profiles.Count -ne 2) {
        throw 'La versión actual requiere exactamente dos perfiles: personal y trabajo.'
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $ids = @()
    $users = @()
    $keys = @()
    $configs = @()
    $emails = @()

    foreach ($profile in $Profiles) {
        try {
            $profile.root = ConvertTo-NormalizedPath -Path $profile.root
            $profile.keyPath = ConvertTo-NormalizedPath -Path $profile.keyPath
            $profile.configPath = ConvertTo-NormalizedPath -Path $profile.configPath
        }
        catch {
            $errors.Add(("Ruta inválida en el perfil {0}: {1}" -f $profile.id, $_.Exception.Message))
            continue
        }

        $ids += $profile.id
        $users += $profile.githubUser
        $keys += $profile.keyPath
        $configs += $profile.configPath
        $emails += $profile.email

        $rootValidation = Get-RootValidation -Root $profile.root
        foreach ($errorMessage in @($rootValidation.Errors)) {
            $errors.Add(("Perfil {0}: {1}" -f $profile.label, $errorMessage))
        }
        foreach ($warning in @($rootValidation.Warnings)) {
            $warnings.Add(("Perfil {0}: {1}" -f $profile.label, $warning))
        }

        if (Test-Path -LiteralPath $profile.root -PathType Leaf) {
            $errors.Add(("Perfil {0}: la raíz es un archivo." -f $profile.label))
        }
        elseif (-not (Test-Path -LiteralPath $profile.root -PathType Container)) {
            if ($profile.createRoot) {
                $warnings.Add(("Perfil {0}: se creará la carpeta raíz {1}." -f $profile.label, $profile.root))
            }
            else {
                $errors.Add(("Perfil {0}: la carpeta raíz no existe y createRoot está desactivado." -f $profile.label))
            }
        }

        if (-not (Test-GitHubUsername -Value $profile.githubUser)) {
            $errors.Add(("Perfil {0}: el usuario de GitHub no es válido." -f $profile.label))
        }
        if ([string]::IsNullOrWhiteSpace($profile.commitName)) {
            $errors.Add(("Perfil {0}: el nombre para commits está vacío." -f $profile.label))
        }
        if (-not (Test-EmailAddress -Value $profile.email)) {
            $errors.Add(("Perfil {0}: el email no es válido." -f $profile.label))
        }

        if (Test-Path -LiteralPath $profile.keyPath -PathType Container) {
            $errors.Add(("Perfil {0}: la ruta de la clave es una carpeta." -f $profile.label))
        }
        if (-not (Test-Path -LiteralPath $profile.keyPath -PathType Leaf) -and (Test-Path -LiteralPath ($profile.keyPath + '.pub') -PathType Leaf)) {
            $errors.Add(("Perfil {0}: existe la clave pública pero falta la privada en {1}." -f $profile.label, $profile.keyPath))
        }
        if ($profile.keyPath.Equals($profile.configPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add(("Perfil {0}: la clave y la configuración no pueden ser el mismo archivo." -f $profile.label))
        }
        $keyParent = Split-Path -Parent $profile.keyPath
        if (-not [string]::IsNullOrWhiteSpace($keyParent) -and (Test-Path -LiteralPath $keyParent -PathType Leaf)) {
            $errors.Add(("Perfil {0}: la carpeta de la clave es un archivo." -f $profile.label))
        }
        if (Test-PathWithin -Child $profile.keyPath -Parent $profile.root) {
            $warnings.Add(("Perfil {0}: la clave está dentro de la raíz de repositorios; se recomienda %USERPROFILE%\.ssh." -f $profile.label))
        }

        if (Test-Path -LiteralPath $profile.configPath -PathType Container) {
            $errors.Add(("Perfil {0}: la configuración es una carpeta." -f $profile.label))
        }
        $configParent = Split-Path -Parent $profile.configPath
        if (-not [string]::IsNullOrWhiteSpace($configParent) -and (Test-Path -LiteralPath $configParent -PathType Leaf)) {
            $errors.Add(("Perfil {0}: la carpeta de configuración es un archivo." -f $profile.label))
        }

        $profile.rootExisted = Test-Path -LiteralPath $profile.root -PathType Container
        $profile.keyExisted = Test-Path -LiteralPath $profile.keyPath -PathType Leaf
        $profile.configExisted = Test-Path -LiteralPath $profile.configPath -PathType Leaf
    }

    $uniqueIds = @($ids | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    $uniqueUsers = @($users | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    $uniqueKeys = @($keys | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    $uniqueConfigs = @($configs | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    $uniqueEmails = @($emails | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)

    if ($uniqueIds.Count -ne $ids.Count) {
        $errors.Add('Los identificadores de perfil deben ser únicos.')
    }
    if ($uniqueUsers.Count -ne $users.Count) {
        $errors.Add('Los dos perfiles deben usar usuarios de GitHub distintos.')
    }
    if ($uniqueKeys.Count -ne $keys.Count) {
        $errors.Add('Los dos perfiles no pueden usar la misma clave SSH.')
    }
    if ($uniqueConfigs.Count -ne $configs.Count) {
        $errors.Add('Los dos perfiles no pueden usar el mismo archivo de configuración.')
    }
    if ($uniqueEmails.Count -ne $emails.Count) {
        $warnings.Add('Los dos perfiles usan el mismo email. Los commits no se podrán distinguir por email.')
    }

    if ($Profiles.Count -eq 2) {
        try {
            Assert-NoNestedRoots -FirstRoot $Profiles[0].root -SecondRoot $Profiles[1].root
        }
        catch {
            $errors.Add($_.Exception.Message)
        }
    }

    if ($errors.Count -gt 0) {
        throw (($errors -join [Environment]::NewLine))
    }

    return $warnings.ToArray()
}

function Show-ProfilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Profiles,
        [object[]]$Warnings = @()
    )

    Write-UiSection 'Resumen de la configuración'
    $rows = @()
    foreach ($profile in $Profiles) {
        $rows += [pscustomobject]@{
            'Perfil'   = $profile.label
            'Cuenta'   = $profile.githubUser
            'Raíz'     = $profile.root
            'Email'    = $profile.email
            'Clave'    = $profile.keyPath
            'Config'   = $profile.configPath
        }
    }

    Write-UiKeyValueTable -Rows $rows -Columns @('Perfil', 'Cuenta', 'Raíz', 'Email', 'Clave', 'Config')

    Write-Ui ''
    foreach ($profile in $Profiles) {
        $keyState = 'se creará'
        if (Test-Path -LiteralPath $profile.keyPath -PathType Leaf) {
            $keyState = 'existente'
        }
        $configState = 'se creará'
        if (Test-Path -LiteralPath $profile.configPath -PathType Leaf) {
            $configState = 'existente (se actualizará)'
        }
        Write-UiDetail ("{0}: clave {1}; configuración {2}." -f $profile.label, $keyState, $configState)
    }

    foreach ($warning in @($Warnings)) {
        Write-UiWarn $warning
    }
}

function Invoke-KeyPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Profiles,
        [switch]$NonInteractive,
        [switch]$DryRun
    )

    Write-UiStep -Number 4 -Total 8 -Text 'Preparando claves SSH'

    foreach ($profile in $Profiles) {
        Write-UiSection ("Perfil: {0}" -f $profile.label)
        $profile.keyExisted = Test-Path -LiteralPath $profile.keyPath -PathType Leaf
        $profile.configExisted = Test-Path -LiteralPath $profile.configPath -PathType Leaf

        if ($profile.keyExisted) {
            $profile.fingerprint = Get-SshKeyFingerprint -KeyPath $profile.keyPath
            $profile.encrypted = Test-SshKeyEncrypted -KeyPath $profile.keyPath
            $profile.keyCreated = $false
            Write-UiInfo ("Clave existente: {0}" -f $profile.fingerprint)
            if ($profile.encrypted) {
                Write-UiWarn 'La clave tiene passphrase. Si Git la pide en cada operación, cárgala en ssh-agent.'
            }

            if (-not $DryRun) {
                $aclResult = Set-PrivateKeyAcl -KeyPath $profile.keyPath
                if (-not $aclResult.Ok) {
                    Write-UiWarn $aclResult.Message
                }
            }

            $publicPath = $profile.keyPath + '.pub'
            if (-not (Test-Path -LiteralPath $publicPath -PathType Leaf) -and -not $profile.encrypted -and -not $DryRun) {
                try {
                    $oldPreference = $ErrorActionPreference
                    $ErrorActionPreference = 'Continue'
                    $publicContent = & ssh-keygen -y -f $profile.keyPath 2>&1
                    $exitCode = $LASTEXITCODE
                    $ErrorActionPreference = $oldPreference
                    if ($exitCode -eq 0) {
                        $publicText = ((($publicContent | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim() + [Environment]::NewLine)
                        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                        [System.IO.File]::WriteAllText($publicPath, $publicText, $utf8NoBom)
                        Write-UiInfo ("Se reconstruyó la clave pública: {0}" -f $publicPath)
                    }
                }
                catch {
                    Write-UiWarn ("No se pudo reconstruir la clave pública: {0}" -f $_.Exception.Message)
                }
            }
            elseif (-not (Test-Path -LiteralPath $publicPath -PathType Leaf) -and $profile.encrypted -and -not $DryRun) {
                throw ("Falta la clave pública {0} y la clave privada tiene passphrase. Restaura el archivo .pub o genera una clave nueva." -f $publicPath)
            }
        }
        else {
            $comment = 'github-{0}-{1}' -f $profile.id, $profile.githubUser
            $keyResult = New-GitHubSshKey -KeyPath $profile.keyPath -Comment $comment -UsePassphrase:$profile.usePassphrase -NonInteractive:$NonInteractive -DryRun:$DryRun
            $profile.keyCreated = [bool]$keyResult.Created
            $profile.fingerprint = [string]$keyResult.Fingerprint
            $profile.encrypted = [bool]$keyResult.Encrypted
            if ($keyResult.Planned) {
                Write-UiInfo ("Se creará la clave: {0}" -f $profile.keyPath)
            }
            else {
                Write-UiSuccess ("Clave creada: {0}" -f $profile.keyPath)
            }
        }

        $profile.sshCommand = New-SshCommandValue -KeyPath $profile.keyPath
        Write-UiDetail ("core.sshCommand: {0}" -f $profile.sshCommand)

        if (-not $DryRun) {
            $parseResult = Test-SshCommandParse -SshCommand $profile.sshCommand
            if (-not $parseResult.Ok) {
                throw ("El comando SSH no se pudo validar para {0}: {1}" -f $profile.label, $parseResult.Message)
            }
        }
    }
}

function Invoke-AuthPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Profiles,
        [switch]$NoBrowser,
        [switch]$NonInteractive,
        [switch]$DryRun
    )

    Write-UiStep -Number 5 -Total 8 -Text 'Registrando y verificando claves en GitHub'

    foreach ($profile in $Profiles) {
        Write-UiSection ("Perfil: {0}" -f $profile.label)

        if ($DryRun) {
            if (Test-Path -LiteralPath $profile.keyPath -PathType Leaf) {
                try {
                    $encrypted = Test-SshKeyEncrypted -KeyPath $profile.keyPath
                    if (-not $encrypted) {
                        $auth = Test-GitHubSshAuth -KeyPath $profile.keyPath -TemporaryKnownHosts
                        if ($auth.Ok) {
                            Write-UiInfo ("[dry-run] La clave autentica como {0}." -f $auth.GitHubUser)
                        }
                        else {
                            Write-UiInfo ("[dry-run] La clave todavía no autentica: {0}" -f $auth.Message)
                        }
                    }
                    else {
                        Write-UiInfo '[dry-run] La clave tiene passphrase; se omite la prueba automática.'
                    }
                }
                catch {
                    Write-UiInfo ("[dry-run] No se pudo probar la clave: {0}" -f $_.Exception.Message)
                }
            }
            else {
                Write-UiInfo ("[dry-run] Se abriría GitHub para registrar la clave de {0}." -f $profile.label)
            }
            continue
        }

        $auth = Register-GitHubKey -Profile $profile -NoBrowser:$NoBrowser -NonInteractive:$NonInteractive
        $profile.authOk = [bool]$auth.Ok
        $profile.authUser = [string]$auth.GitHubUser
        Write-UiSuccess ("Perfil {0} verificado como {1}." -f $profile.label, $profile.authUser)
    }
}

function Remove-ManagedIncludeIfForProfiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Profiles,
        [switch]$DryRun
    )

    foreach ($profile in $Profiles) {
        $key = New-IncludeIfKey -Root $profile.root
        $target = ConvertTo-NormalizedPath -Path $profile.configPath
        $current = Invoke-GitCommand -Arguments @('config', '--global', '--get-all', $key) -AllowFailure
        if ($current.ExitCode -ne 0) {
            continue
        }

        foreach ($value in @($current.RawLines)) {
            try {
                $normalizedValue = ConvertTo-NormalizedPath -Path $value
                if ($normalizedValue.Equals($target, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Remove-ManagedIncludeIf -Key $key -DryRun:$DryRun
                    break
                }
            }
            catch {
                # Ignore malformed values.
            }
        }
    }
}

function Invoke-WritePhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Profiles,
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [switch]$DryRun
    )

    Write-UiStep -Number 6 -Total 8 -Text 'Escribiendo configuración de Git'

    $backupFiles = New-Object System.Collections.Generic.List[object]
    $globalPaths = @(Get-EffectiveGlobalConfigPaths)
    $globalIndex = 0
    foreach ($globalPath in $globalPaths) {
        if (Test-Path -LiteralPath $globalPath -PathType Leaf) {
            $backupFiles.Add([pscustomobject]@{
                Path            = $globalPath
                Label           = ('global-{0}' -f $globalIndex)
                DeleteIfCreated = $false
            })
            $globalIndex++
        }
    }

    if ($backupFiles.Count -eq 0 -and $globalPaths.Count -gt 0) {
        $backupFiles.Add([pscustomobject]@{
            Path            = $globalPaths[0]
            Label           = 'global-default'
            DeleteIfCreated = $false
        })
    }

    foreach ($profile in $Profiles) {
        $backupFiles.Add([pscustomobject]@{
            Path            = $profile.configPath
            Label           = ('profile-{0}' -f $profile.id)
            DeleteIfCreated = (-not (Test-Path -LiteralPath $profile.configPath -PathType Leaf))
        })
    }

    $backup = New-SetupBackup -Files $backupFiles.ToArray() -BackupRoot $BackupRoot -DryRun:$DryRun
    $script:LastSetupBackup = $backup

    try {
        foreach ($profile in $Profiles) {
            if ($DryRun) {
                Write-UiInfo ("[dry-run] Se escribiría {0}" -f $profile.configPath)
            }
            else {
                Write-UiInfo ("Escribiendo {0}" -f $profile.configPath)
            }
            Write-ProfileGitConfig -ConfigPath $profile.configPath -SshCommand $profile.sshCommand `
                -UserName $profile.commitName -Email $profile.email -DryRun:$DryRun

            if ($DryRun) {
                Write-UiInfo ("[dry-run] Se vincularía {0} con {1}" -f $profile.configPath, $profile.root)
            }
            else {
                Write-UiInfo ("Vinculando {0} con {1}" -f $profile.configPath, $profile.root)
            }
            Set-ManagedIncludeIf -Root $profile.root -ConfigPath $profile.configPath -DryRun:$DryRun
        }

        if (-not $DryRun) {
            Write-UiStep -Number 7 -Total 8 -Text 'Verificando la configuración'
            $verificationErrors = New-Object System.Collections.Generic.List[string]

            foreach ($profile in $Profiles) {
                $result = Test-ProfileConfiguration -Root $profile.root -ConfigPath $profile.configPath `
                    -SshCommand $profile.sshCommand -UserName $profile.commitName -Email $profile.email
                $profile.verificationOk = [bool]$result.Ok
                if ($result.Ok) {
                    Write-UiSuccess ("Configuración verificada en {0}." -f $profile.root)
                }
                else {
                    foreach ($errorMessage in @($result.Errors)) {
                        $verificationErrors.Add(("Perfil {0}: {1}" -f $profile.label, $errorMessage))
                    }
                }
            }

            $outside = Test-OutsideProfileConfiguration -Roots @($Profiles | ForEach-Object { $_.root }) `
                -ProfileConfigPaths @($Profiles | ForEach-Object { $_.configPath })
            if (-not $outside.Ok) {
                foreach ($errorMessage in @($outside.Errors)) {
                    $verificationErrors.Add($errorMessage)
                }
            }
            elseif ($outside.Skipped) {
                Write-UiWarn $outside.Message
            }
            else {
                Write-UiSuccess 'Los repositorios fuera de las raíces no heredan estos perfiles.'
            }

            if ($verificationErrors.Count -gt 0) {
                throw (($verificationErrors -join [Environment]::NewLine))
            }
        }
        else {
            Write-UiInfo '[dry-run] Se omitió la verificación real.'
        }
    }
    catch {
        $message = $_.Exception.Message
        if (-not $DryRun -and $backup -ne $null -and -not $backup.Planned) {
            Write-UiWarn 'Se produjo un error. Restaurando la configuración anterior desde el backup...'
            try {
                Remove-ManagedIncludeIfForProfiles -Profiles $Profiles
            }
            catch {
                Write-UiWarn ("No se pudieron limpiar todas las entradas includeIf: {0}" -f $_.Exception.Message)
            }
            try {
                $restoreResults = Restore-SetupBackup -Backup $backup
                foreach ($restore in @($restoreResults)) {
                    if (-not $restore.Restored) {
                        Write-UiWarn ("No se pudo restaurar {0}: {1}" -f $restore.Path, $restore.Message)
                    }
                }
                Write-UiSuccess ("Configuración restaurada. Backup: {0}" -f $backup.Dir)
            }
            catch {
                Write-UiError ("No se pudo restaurar el backup: {0}" -f $_.Exception.Message)
                Write-UiHint ("Ejecuta .\setup.cmd -Rollback o revisa {0}" -f $backup.Dir)
            }
        }
        throw $message
    }

    return $backup
}

function Show-FinalSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Profiles,
        [object]$Backup = $null,
        [switch]$DryRun
    )

    Write-UiStep -Number 8 -Total 8 -Text 'Resumen final'

    if ($DryRun) {
        Write-UiWarn 'Dry run: no se modificó ninguna configuración.'
        return
    }

    $rows = @()
    foreach ($profile in $Profiles) {
        $rows += [pscustomobject]@{
            'Perfil' = $profile.label
            'Cuenta' = $profile.githubUser
            'Raíz'   = $profile.root
            'Clave'  = $profile.keyPath
            'Estado' = $(if ($profile.verificationOk) { 'Verificado' } else { 'Revisar' })
        }
    }
    Write-UiKeyValueTable -Rows $rows -Columns @('Perfil', 'Cuenta', 'Raíz', 'Clave', 'Estado')

    Write-Ui ''
    Write-UiSuccess 'Configuración completada.'
    if ($Backup -ne $null) {
        Write-UiInfo ("Backup: {0}" -f $Backup.Dir)
    }
    Write-Ui ''
    Write-Ui 'Prueba ahora:' White
    foreach ($profile in $Profiles) {
        Write-UiDetail ("cd `"{0}`"" -f $profile.root)
        Write-UiDetail ("git clone git@github.com:{0}/tu-repositorio.git" -f $profile.githubUser)
    }
    Write-Ui ''
    Write-Ui 'Para deshacer la configuración:' White
    Write-UiDetail '.\setup.cmd -Rollback'
    Write-Ui ''
    Write-UiHint 'Los comandos Git dentro de cada raíz usarán la clave y la identidad de su perfil.'
    Write-UiHint 'Un ssh ejecutado fuera de Git no usa esta configuración; usa ssh -i con la clave correspondiente.'
}

function Invoke-SetupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Profiles,
        [switch]$DryRun,
        [switch]$NoBrowser,
        [switch]$NonInteractive,
        [switch]$Force,
        [string]$StatePath,
        [string]$BackupRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Get-DefaultStatePath
    }
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = Get-DefaultBackupRoot
    }

    $warnings = Assert-Profiles -Profiles $Profiles
    Show-ProfilePlan -Profiles $Profiles -Warnings $warnings

    if (-not $Force) {
        if ([Console]::IsInputRedirected) {
            throw 'La ejecución no es interactiva. Usa -Force para confirmar sin preguntas.'
        }
        if (-not (Read-UiYesNo '¿Aplicar esta configuración?' $true)) {
            throw 'Operación cancelada por el usuario.'
        }
    }

    $state = New-SetupStateObject -StatePath $StatePath
    $state.profiles = [object[]]$Profiles
    $state.status = 'plan-approved'
    Save-SetupState -State $state -Path $StatePath -DryRun:$DryRun

    Write-UiStep -Number 3 -Total 8 -Text 'Creando carpetas necesarias'
    foreach ($profile in $Profiles) {
        if (Test-Path -LiteralPath $profile.root -PathType Container) {
            Write-UiInfo ("La carpeta raíz ya existe: {0}" -f $profile.root)
        }
        else {
            if (-not $profile.createRoot) {
                throw ("La carpeta raíz no existe y createRoot está desactivado: {0}" -f $profile.root)
            }
            if ($DryRun) {
                Write-UiInfo ("[dry-run] Se creará la carpeta raíz: {0}" -f $profile.root)
            }
            else {
                New-DirectoryIfMissing -Path $profile.root | Out-Null
                Write-UiSuccess ("Carpeta raíz creada: {0}" -f $profile.root)
            }
        }
    }

    $effectiveNonInteractive = $NonInteractive -or [Console]::IsInputRedirected

    Invoke-KeyPhase -Profiles $Profiles -NonInteractive:$effectiveNonInteractive -DryRun:$DryRun
    $state.status = 'keys-ready'
    $state.profiles = [object[]]$Profiles
    Save-SetupState -State $state -Path $StatePath -DryRun:$DryRun

    Invoke-AuthPhase -Profiles $Profiles -NoBrowser:$NoBrowser -NonInteractive:$effectiveNonInteractive -DryRun:$DryRun
    $state.status = 'auth-ready'
    $state.profiles = [object[]]$Profiles
    Save-SetupState -State $state -Path $StatePath -DryRun:$DryRun

    $script:LastSetupBackup = $null
    try {
        $backup = Invoke-WritePhase -Profiles $Profiles -BackupRoot $BackupRoot -DryRun:$DryRun
    }
    catch {
        if ($script:LastSetupBackup -ne $null -and -not $DryRun) {
            $state.status = 'failed'
            $state.profiles = [object[]]$Profiles
            $state.backup = $script:LastSetupBackup
            try {
                Save-SetupState -State $state -Path $StatePath
            }
            catch {
                Write-UiWarn ("No se pudo guardar el estado del fallo: {0}" -f $_.Exception.Message)
            }
        }
        throw
    }

    $state.status = 'verified'
    $state.profiles = [object[]]$Profiles
    $state.backup = $backup
    $state.managedIncludeKeys = @($Profiles | ForEach-Object { New-IncludeIfKey -Root $_.root })
    Save-SetupState -State $state -Path $StatePath -DryRun:$DryRun

    Show-FinalSummary -Profiles $Profiles -Backup $backup -DryRun:$DryRun
}

function Invoke-SetupWizard {
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        [switch]$NoBrowser,
        [string]$StatePath
    )

    $report = Get-PreflightReport
    Show-PreflightReport -Report $report
    Assert-Preflight -Report $report

    if ([Console]::IsInputRedirected) {
        throw 'El asistente interactivo requiere una consola. Para automatizar, usa -Config con -Force.'
    }

    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Get-DefaultStatePath
    }

    Write-UiStep -Number 1 -Total 8 -Text 'Eligiendo el modo de configuración'
    $detected = @(Get-DetectedProfiles)
    $useDetected = $false

    if ($detected.Count -gt 0) {
        Write-UiSection 'Configuración detectada'
        $rows = @()
        foreach ($profile in $detected) {
            $rows += [pscustomobject]@{
                'Perfil'  = $profile.label
                'Raíz'    = $profile.root
                'Cuenta'  = $(if ([string]::IsNullOrWhiteSpace($profile.githubUser)) { '(por confirmar)' } else { $profile.githubUser })
                'Email'   = $(if ([string]::IsNullOrWhiteSpace($profile.email)) { '(sin definir)' } else { $profile.email })
                'Clave'   = $profile.keyPath
            }
        }
        Write-UiKeyValueTable -Rows $rows -Columns @('Perfil', 'Raíz', 'Cuenta', 'Email', 'Clave')

        $choice = Read-UiChoice -Prompt '¿Qué quieres hacer?' -Options @(
            'Revisar o reparar la configuración detectada',
            'Crear una configuración nueva'
        ) -DefaultIndex 0

        if ($choice -eq 0) {
            $useDetected = $true
            Write-UiInfo 'Detectando la cuenta de GitHub asociada a cada clave...'
            $detected = @(Get-DetectedProfiles -ResolveAccounts)
        }
    }

    Write-UiStep -Number 2 -Total 8 -Text 'Datos de los perfiles'
    $profiles = @()
    foreach ($id in @('personal', 'work')) {
        $defaults = Get-ProfileDefaults -Id $id -Detected $detected -UseDetected $useDetected
        Write-UiSection ("Perfil {0}" -f $defaults.Label)
        $profiles += Read-ProfileInteractive -Id $id -Defaults $defaults
    }

    Invoke-SetupPlan -Profiles $profiles -DryRun:$DryRun -NoBrowser:$NoBrowser -StatePath $StatePath
}

function Read-SetupConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = ConvertTo-NormalizedPath -Path $Path
    if (-not (Test-Path -LiteralPath $normalized -PathType Leaf)) {
        throw ("No existe el archivo de configuración: {0}" -f $normalized)
    }

    try {
        $raw = [System.IO.File]::ReadAllText($normalized)
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw ("No se pudo leer el JSON de configuración: {0}" -f $normalized)
    }

    if ($json.profiles -eq $null -or @($json.profiles).Count -ne 2) {
        throw 'El archivo de configuración debe contener exactamente dos perfiles.'
    }

    $profiles = @()
    foreach ($entry in @($json.profiles)) {
        $id = [string]$entry.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            $id = $(if ($profiles.Count -eq 0) { 'personal' } else { 'work' })
        }
        if ($id -ne 'personal' -and $id -ne 'work') {
            throw ("El id de perfil debe ser personal o work: {0}" -f $id)
        }

        $root = [string]$entry.root
        if ([string]::IsNullOrWhiteSpace($root)) {
            throw ("Falta root en el perfil {0}." -f $id)
        }

        $keyPath = [string]$entry.keyPath
        if ([string]::IsNullOrWhiteSpace($keyPath)) {
            $keyPath = Get-DefaultKeyPath -ProfileId $id
        }
        $configPath = [string]$entry.configPath
        if ([string]::IsNullOrWhiteSpace($configPath)) {
            $configPath = Get-DefaultConfigPath -ProfileId $id
        }

        $label = [string]$entry.label
        if ([string]::IsNullOrWhiteSpace($label)) {
            $label = $(if ($id -eq 'work') { 'Trabajo' } else { 'Personal' })
        }

        $usePassphrase = $false
        if ($entry.PSObject.Properties['usePassphrase'] -ne $null) {
            $usePassphrase = [bool]$entry.usePassphrase
        }
        $createRoot = $true
        if ($entry.PSObject.Properties['createRoot'] -ne $null) {
            $createRoot = [bool]$entry.createRoot
        }

        $profiles += New-ProfileObject -Id $id -Label $label -Root $root `
            -GitHubUser ([string]$entry.githubUser) -CommitName ([string]$entry.commitName) `
            -Email ([string]$entry.email) -KeyPath $keyPath -ConfigPath $configPath `
            -UsePassphrase $usePassphrase -CreateRoot $createRoot -IsDetected $false
    }

    $warnings = Assert-Profiles -Profiles $profiles
    foreach ($warning in @($warnings)) {
        Write-UiWarn $warning
    }
    return $profiles
}

function Invoke-Doctor {
    [CmdletBinding()]
    param(
        [object]$Report = $null,
        [switch]$NoColor
    )

    if ($Report -eq $null) {
        $Report = Get-PreflightReport
    }
    Show-PreflightReport -Report $Report

    Write-UiSection 'Estado de los perfiles'
    $entries = @(Get-ManagedIncludeIfEntries)
    if ($entries.Count -eq 0) {
        Write-UiInfo 'No se encontraron entradas includeIf para perfiles Git.'
    }

    $rows = @()
    foreach ($entry in $entries) {
        $values = Get-ProfileConfigValues -ConfigPath $entry.ConfigPath
        $keyExists = -not [string]::IsNullOrWhiteSpace($values.KeyPath) -and (Test-Path -LiteralPath $values.KeyPath -PathType Leaf)
        $fingerprint = ''
        $encrypted = $false
        $authUser = ''
        $authStatus = 'No probada'
        $authOk = $false

        if ($keyExists) {
            try {
                $fingerprint = Get-SshKeyFingerprint -KeyPath $values.KeyPath
                $encrypted = Test-SshKeyEncrypted -KeyPath $values.KeyPath
                if (-not $encrypted) {
                    $auth = Test-GitHubSshAuth -KeyPath $values.KeyPath -TemporaryKnownHosts
                    if ($auth.Ok) {
                        $authUser = $auth.GitHubUser
                        $authStatus = ("OK: {0}" -f $authUser)
                        $authOk = $true
                    }
                    else {
                        $authStatus = $auth.Message
                    }
                }
                else {
                    $authStatus = 'Clave con passphrase; prueba omitida'
                }
            }
            catch {
                $authStatus = $_.Exception.Message
            }
        }

        $identityOk = -not [string]::IsNullOrWhiteSpace($values.UserName) -and -not [string]::IsNullOrWhiteSpace($values.Email)
        $identitiesOnly = $values.SshCommand -match 'IdentitiesOnly=yes'
        $configOk = $values.Exists
        $rootExists = Test-Path -LiteralPath $entry.Root -PathType Container

        $status = 'OK'
        if (-not $configOk -or -not $keyExists -or -not $rootExists) {
            $status = 'ERROR'
        }
        elseif (-not $identityOk -or -not $identitiesOnly -or -not $authOk) {
            $status = 'REVISAR'
        }

        $rows += [pscustomobject]@{
            'Raíz'      = $entry.Root
            'Cuenta'    = $(if ([string]::IsNullOrWhiteSpace($authUser)) { '(desconocida)' } else { $authUser })
            'Email'     = $(if ([string]::IsNullOrWhiteSpace($values.Email)) { '(sin definir)' } else { $values.Email })
            'Clave'     = $(if ($keyExists) { 'OK' } else { 'FALTA' })
            'Identidad' = $(if ($identityOk) { 'OK' } else { 'FALTA' })
            'SSH'       = $(if ($identitiesOnly) { 'OK' } else { 'FALTA IdentitiesOnly' })
            'Auth'      = $authStatus
            'Estado'    = $status
        }

        if (-not $identityOk) {
            Write-UiWarn ("{0}: falta user.name o user.email en {1}." -f $entry.Root, $entry.ConfigPath)
        }
        if (-not $identitiesOnly) {
            Write-UiWarn ("{0}: core.sshCommand no incluye IdentitiesOnly=yes." -f $entry.Root)
        }
        if (-not $rootExists) {
            Write-UiWarn ("{0}: la carpeta raíz no existe." -f $entry.Root)
        }
        if ($keyExists -and -not [string]::IsNullOrWhiteSpace($entry.Root) -and (Test-PathWithin -Child $values.KeyPath -Parent $entry.Root)) {
            Write-UiWarn ("{0}: la clave está dentro de la raíz de repositorios." -f $entry.Root)
        }
    }

    if ($rows.Count -gt 0) {
        Write-UiKeyValueTable -Rows $rows -Columns @('Raíz', 'Cuenta', 'Email', 'Clave', 'Identidad', 'SSH', 'Auth', 'Estado')
    }

    Write-UiSection 'Identidad global'
    if (Test-GitAvailable) {
        $globalName = Get-GitConfigValue -Key 'user.name' -Global
        $globalEmail = Get-GitConfigValue -Key 'user.email' -Global
        Write-UiInfo ("user.name: {0}" -f $(if ([string]::IsNullOrWhiteSpace($globalName)) { '(sin definir)' } else { $globalName }))
        Write-UiInfo ("user.email: {0}" -f $(if ([string]::IsNullOrWhiteSpace($globalEmail)) { '(sin definir)' } else { $globalEmail }))
        $globalSsh = Get-GitConfigValue -Key 'core.sshCommand' -Global
        Write-UiInfo ("core.sshCommand global: {0}" -f $(if ([string]::IsNullOrWhiteSpace($globalSsh)) { '(sin definir)' } else { $globalSsh }))
    }
    else {
        Write-UiWarn 'No se puede leer la identidad global porque Git no está instalado.'
    }

    if ($Report.Errors.Count -gt 0) {
        return 2
    }
    return 0
}

function Invoke-Rollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,
        [switch]$Force,
        [switch]$DryRun
    )

    $state = Read-SetupState -Path $StatePath
    if ($state -eq $null) {
        throw ("No se encontró un estado del asistente en {0}." -f $StatePath)
    }

    Write-UiSection 'Rollback de la configuración'
    Write-UiInfo ("Estado: {0}" -f $state.status)
    if ($state.profiles -ne $null) {
        foreach ($profile in @($state.profiles)) {
            Write-UiDetail ("{0}: {1} ({2})" -f $profile.label, $profile.root, $profile.githubUser)
        }
    }

    if (-not $Force) {
        if ([Console]::IsInputRedirected) {
            throw 'El rollback no es interactivo. Usa -Force para confirmar.'
        }
        if (-not (Read-UiYesNo '¿Deshacer los cambios gestionados por el asistente?' $false)) {
            throw 'Rollback cancelado por el usuario.'
        }
    }

    $managedKeys = @()
    if ($state.managedIncludeKeys -ne $null) {
        $managedKeys = @($state.managedIncludeKeys)
    }
    if ($managedKeys.Count -eq 0 -and $state.profiles -ne $null) {
        foreach ($profile in @($state.profiles)) {
            $managedKeys += New-IncludeIfKey -Root $profile.root
        }
    }

    $profileConfigPaths = @()
    if ($state.profiles -ne $null) {
        foreach ($profile in @($state.profiles)) {
            $profileConfigPaths += ConvertTo-NormalizedPath -Path $profile.configPath
        }
    }

    foreach ($key in $managedKeys) {
        if ($DryRun) {
            Write-UiInfo ("[dry-run] Se eliminaría includeIf: {0}" -f $key)
            continue
        }

        $current = Invoke-GitCommand -Arguments @('config', '--global', '--get-all', $key) -AllowFailure
        $shouldRemove = $false
        if ($current.ExitCode -eq 0) {
            foreach ($value in @($current.RawLines)) {
                foreach ($configPath in $profileConfigPaths) {
                    try {
                        if ((ConvertTo-NormalizedPath -Path $value).Equals($configPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $shouldRemove = $true
                        }
                    }
                    catch {
                        # Ignore malformed values.
                    }
                }
            }
        }

        if ($shouldRemove) {
            Remove-ManagedIncludeIf -Key $key -DryRun:$DryRun
        }
        else {
            Write-UiWarn ("Se omite includeIf {0}: ya no apunta a un perfil gestionado." -f $key)
        }
    }

    if ($state.backup -ne $null -and -not [string]::IsNullOrWhiteSpace($state.backup.ManifestPath)) {
        if (Test-Path -LiteralPath $state.backup.ManifestPath -PathType Leaf) {
            $manifest = Read-SetupBackup -ManifestPath $state.backup.ManifestPath
            $profileEntries = @($manifest.Entries | Where-Object { $_.Label -like 'profile-*' })
            if ($profileEntries.Count -gt 0) {
                $partialBackup = [pscustomobject]@{ Entries = $profileEntries }
                $restoreResults = Restore-SetupBackup -Backup $partialBackup -DryRun:$DryRun
                foreach ($result in @($restoreResults)) {
                    if ($result.Restored) {
                        Write-UiInfo ($result.Message + ' ' + $result.Path)
                    }
                    else {
                        Write-UiWarn ($result.Message + ' ' + $result.Path)
                    }
                }
            }
        }
        else {
            Write-UiWarn ("No se encontró el manifiesto de backup: {0}" -f $state.backup.ManifestPath)
        }
    }

    if (-not $DryRun) {
        $state.status = 'rolled-back'
        $state | Add-Member -NotePropertyName rolledBackAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
        Save-SetupState -State $state -Path $StatePath
    }

    if ($DryRun) {
        Write-UiInfo '[dry-run] No se modificó ninguna configuración.'
    }
    else {
        Write-UiSuccess 'Rollback completado.'
    }
    Write-Ui ''
    Write-Ui 'Claves que puedes eliminar manualmente de GitHub:' White
    if ($state.profiles -ne $null) {
        foreach ($profile in @($state.profiles)) {
            $fingerprint = ''
            if (-not [string]::IsNullOrWhiteSpace($profile.keyPath) -and (Test-Path -LiteralPath $profile.keyPath -PathType Leaf)) {
                try {
                    $fingerprint = Get-SshKeyFingerprint -KeyPath $profile.keyPath
                }
                catch {
                    $fingerprint = '(no se pudo leer)'
                }
            }
            Write-UiDetail ("{0}: {1} {2}" -f $profile.label, $profile.githubUser, $fingerprint)
        }
    }
    Write-UiHint 'El asistente no borra claves privadas ni claves de GitHub automáticamente.'
}
