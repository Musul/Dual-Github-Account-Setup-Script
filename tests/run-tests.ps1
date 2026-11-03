#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'lib\Ui.ps1')
. (Join-Path $projectRoot 'lib\Paths.ps1')
. (Join-Path $projectRoot 'lib\GitConfig.ps1')
. (Join-Path $projectRoot 'lib\Ssh.ps1')
. (Join-Path $projectRoot 'lib\GitHub.ps1')
. (Join-Path $projectRoot 'lib\State.ps1')
. (Join-Path $projectRoot 'lib\Preflight.ps1')
. (Join-Path $projectRoot 'lib\Wizard.ps1')

Initialize-Ui -NoColor -Silent

$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message = ''
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw ("Esperado: [{0}]`nActual:   [{1}]`n{2}" -f $Expected, $Actual, $Message)
    }
}

function Assert-True {
    param(
        $Value,
        [string]$Message = ''
    )

    if (-not $Value) {
        throw ("Se esperaba verdadero. {0}" -f $Message)
    }
}

function Assert-False {
    param(
        $Value,
        [string]$Message = ''
    )

    if ($Value) {
        throw ("Se esperaba falso. {0}" -f $Message)
    }
}

function Assert-Throws {
    param(
        [scriptblock]$Body,
        [string]$Message = ''
    )

    $threw = $false
    try {
        & $Body
    }
    catch {
        $threw = $true
    }

    if (-not $threw) {
        throw ("Se esperaba una excepción. {0}" -f $Message)
    }
}

function Test-Case {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Body
    )

    try {
        & $Body
        $script:Passed++
        Write-Host ("[OK] {0}" -f $Name) -ForegroundColor Green
    }
    catch {
        $script:Failed++
        $script:Failures.Add(("{0}: {1}" -f $Name, $_.Exception.Message))
        Write-Host ("[X]  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("     {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dgh-tests-{0}' -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$oldEnvironment = @{
    GIT_CONFIG_GLOBAL = $env:GIT_CONFIG_GLOBAL
    GIT_CONFIG_SYSTEM = $env:GIT_CONFIG_SYSTEM
    HOME              = $env:HOME
    PATH              = $env:PATH
}

try {
    $env:GIT_CONFIG_GLOBAL = Join-Path $testRoot 'gitconfig'
    $env:GIT_CONFIG_SYSTEM = Join-Path $testRoot 'gitconfig-system'
    Set-Content -LiteralPath $env:GIT_CONFIG_SYSTEM -Value '' -Encoding ASCII
    $env:HOME = $testRoot

    Test-Case 'Normaliza rutas con barras invertidas y barra final' {
        $inputPath = Join-Path $testRoot 'a\b\'
        $expected = ($testRoot -replace '\\', '/') + '/a/b'
        Assert-Equal $expected (ConvertTo-NormalizedPath -Path $inputPath)
    }

    Test-Case 'Detecta si una ruta está dentro de otra' {
        $parent = Join-Path $testRoot 'parent'
        $child = Join-Path $parent 'child'
        $other = Join-Path $testRoot 'other'
        Assert-True (Test-PathWithin -Child $child -Parent $parent)
        Assert-False (Test-PathWithin -Child $other -Parent $parent)
    }

    Test-Case 'Rechaza raíces anidadas' {
        $parent = Join-Path $testRoot 'nested'
        $child = Join-Path $parent 'child'
        Assert-Throws { Assert-NoNestedRoots -FirstRoot $parent -SecondRoot $child }
    }

    Test-Case 'Valida raíces peligrosas' {
        $driveRoot = (Split-Path -Qualifier $testRoot) + '/'
        $driveValidation = Get-RootValidation -Root $driveRoot
        Assert-True ($driveValidation.Errors.Count -gt 0)

        $homeValidation = Get-RootValidation -Root $env:USERPROFILE
        Assert-True ($homeValidation.Errors.Count -gt 0)

        $okValidation = Get-RootValidation -Root $testRoot
        Assert-Equal 0 $okValidation.Errors.Count
    }

    Test-Case 'Construye el comando SSH con comillas seguras' {
        $keyPath = Join-Path $testRoot "O'Brien\id key"
        $command = New-SshCommandValue -KeyPath $keyPath
        Assert-True ($command.Contains('-F /dev/null'))
        Assert-True ($command.Contains('-o IdentitiesOnly=yes'))
        Assert-True ($command.Contains("O'\''Brien"))
        $parsed = Test-SshCommandParse -SshCommand $command
        Assert-True $parsed.Ok
    }

    Test-Case 'Construye la clave includeIf correctamente' {
        $root = Join-Path $testRoot 'Root With Space'
        $expected = 'includeIf.gitdir/i:{0}/.path' -f ($root -replace '\\', '/')
        Assert-Equal $expected (New-IncludeIfKey -Root $root)
    }

    Test-Case 'Decodifica rutas entrecomilladas por Git' {
        $line = 'file:"C:/Users/me/perfil \303\263.gitconfig"' + "`t" + 'value'
        $parsed = ConvertFrom-GitShowOriginLine -Line $line
        Assert-Equal 'C:/Users/me/perfil ó.gitconfig' $parsed.Origin
    }

    Test-Case 'Interpreta el saludo de GitHub y distingue cuentas' {
        $success = ConvertFrom-GitHubSshOutput -Output "Hi personal-user! You've successfully authenticated, but GitHub does not provide shell access." -ExitCode 1 -ExpectedUser 'personal-user'
        Assert-True $success.Ok
        Assert-Equal 'personal-user' $success.GitHubUser

        $wrong = ConvertFrom-GitHubSshOutput -Output "Hi personal-user! You've successfully authenticated, but GitHub does not provide shell access." -ExitCode 1 -ExpectedUser 'work-user'
        Assert-False $wrong.Ok
        Assert-Equal 'WrongAccount' $wrong.ErrorKind

        $denied = ConvertFrom-GitHubSshOutput -Output 'git@github.com: Permission denied (publickey).' -ExitCode 255
        Assert-Equal 'NotRegistered' $denied.ErrorKind
    }

    Test-Case 'Aplica includeIf de forma idempotente y lo elimina' {
        $root = Join-Path $testRoot 'Include Root'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $configPath = Join-Path $testRoot 'include-profile.gitconfig'

        Set-ManagedIncludeIf -Root $root -ConfigPath $configPath
        Set-ManagedIncludeIf -Root $root -ConfigPath $configPath

        $normalizedRoot = ConvertTo-NormalizedPath -Path $root
        $entries = @(Get-ManagedIncludeIfEntries | Where-Object { $_.Root -eq $normalizedRoot })
        Assert-Equal 1 $entries.Count
        Assert-Equal (ConvertTo-NormalizedPath -Path $configPath) $entries[0].ConfigPath

        Set-ManagedIncludeIf -Root $root -ConfigPath $configPath -Remove
        $entriesAfter = @(Get-ManagedIncludeIfEntries | Where-Object { $_.Root -eq $normalizedRoot })
        Assert-Equal 0 $entriesAfter.Count
    }

    Test-Case 'Escribe y verifica la configuración de un perfil' {
        $root = Join-Path $testRoot 'Profile Root'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $configPath = Join-Path $testRoot 'profile.gitconfig'
        $sshCommand = New-SshCommandValue -KeyPath (Join-Path $testRoot 'fake-key')

        Set-ManagedIncludeIf -Root $root -ConfigPath $configPath
        Write-ProfileGitConfig -ConfigPath $configPath -SshCommand $sshCommand -UserName 'Test User' -Email 'test@example.com'

        $values = Get-ProfileConfigValues -ConfigPath $configPath
        Assert-Equal $sshCommand $values.SshCommand
        Assert-Equal 'Test User' $values.UserName
        Assert-Equal 'test@example.com' $values.Email

        $verification = Test-ProfileConfiguration -Root $root -ConfigPath $configPath -SshCommand $sshCommand -UserName 'Test User' -Email 'test@example.com'
        Assert-True $verification.Ok ($verification.Errors -join ' ')

        $outside = Test-OutsideProfileConfiguration -Roots @($root) -ProfileConfigPaths @($configPath)
        Assert-True $outside.Ok ($outside.Errors -join ' ')

        Set-ManagedIncludeIf -Root $root -ConfigPath $configPath -Remove
    }

    Test-Case 'Crea y restaura un backup' {
        $file = Join-Path $testRoot 'backup-test.txt'
        Set-Content -LiteralPath $file -Value 'before' -Encoding ASCII
        $backup = New-SetupBackup -Files @([pscustomobject]@{
                    Path            = $file
                    Label           = 'test-file'
                    DeleteIfCreated = $false
                }) -BackupRoot (Join-Path $testRoot 'backups')

        Set-Content -LiteralPath $file -Value 'after' -Encoding ASCII
        $results = @(Restore-SetupBackup -Backup $backup)
        Assert-Equal 'before' (Get-Content -LiteralPath $file -Raw).Trim()
        Assert-True ($results.Count -gt 0)

        $createdFile = Join-Path $testRoot 'created-by-wizard.txt'
        $createdBackup = New-SetupBackup -Files @([pscustomobject]@{
                    Path            = $createdFile
                    Label           = 'created-file'
                    DeleteIfCreated = $true
                }) -BackupRoot (Join-Path $testRoot 'backups')
        Set-Content -LiteralPath $createdFile -Value 'created' -Encoding ASCII
        [void](Restore-SetupBackup -Backup $createdBackup)
        Assert-False (Test-Path -LiteralPath $createdFile)
    }

    Test-Case 'Guarda y lee el estado sin secretos' {
        $statePath = Join-Path $testRoot 'state.json'
        $state = New-SetupStateObject -StatePath $statePath
        $state.status = 'testing'
        Save-SetupState -State $state -Path $statePath
        $loaded = Read-SetupState -Path $statePath
        Assert-Equal 'testing' $loaded.status
        Assert-Equal 1 $loaded.version
    }

    Test-Case 'Lee un archivo de configuración JSON' {
        $configPath = Join-Path $testRoot 'setup.json'
        $json = [pscustomobject]@{
            version  = 1
            profiles = @(
                [pscustomobject]@{
                    id         = 'personal'
                    label      = 'Personal'
                    root       = (Join-Path $testRoot 'json-personal')
                    githubUser = 'personal-user'
                    commitName = 'Personal User'
                    email      = 'personal@example.com'
                    keyPath    = (Join-Path $testRoot 'json-keys\personal')
                    configPath = (Join-Path $testRoot 'json-personal.gitconfig')
                },
                [pscustomobject]@{
                    id         = 'work'
                    label      = 'Trabajo'
                    root       = (Join-Path $testRoot 'json-work')
                    githubUser = 'work-user'
                    commitName = 'Work User'
                    email      = 'work@example.com'
                    keyPath    = (Join-Path $testRoot 'json-keys\work')
                    configPath = (Join-Path $testRoot 'json-work.gitconfig')
                }
            )
        }
        $json | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
        $profiles = @(Read-SetupConfig -Path $configPath)
        Assert-Equal 2 $profiles.Count
        Assert-Equal 'personal' $profiles[0].id
        Assert-Equal 'work' $profiles[1].id
    }

    Test-Case 'Rechaza perfiles con el mismo usuario de GitHub' {
        $p1 = New-ProfileObject -Id personal -Label Personal -Root (Join-Path $testRoot 'dup-personal') -GitHubUser 'same-user' -CommitName 'Personal User' -Email 'personal@example.com' -KeyPath (Join-Path $testRoot 'dup-keys\personal') -ConfigPath (Join-Path $testRoot 'dup-personal.gitconfig')
        $p2 = New-ProfileObject -Id work -Label Trabajo -Root (Join-Path $testRoot 'dup-work') -GitHubUser 'same-user' -CommitName 'Work User' -Email 'work@example.com' -KeyPath (Join-Path $testRoot 'dup-keys\work') -ConfigPath (Join-Path $testRoot 'dup-work.gitconfig')
        Assert-Throws { Assert-Profiles -Profiles @($p1, $p2) }
    }

    Test-Case 'Genera una clave SSH sin passphrase' {
        $keyPath = Join-Path $testRoot 'generated keys\id test'
        $result = New-GitHubSshKey -KeyPath $keyPath -Comment 'test-key' -NonInteractive
        Assert-True $result.Created
        Assert-True (Test-Path -LiteralPath $keyPath)
        Assert-True (Test-Path -LiteralPath ($keyPath + '.pub'))
        Assert-False $result.Encrypted
        Assert-True (-not [string]::IsNullOrWhiteSpace($result.Fingerprint))
        Assert-True ((Get-SshPublicKeyContent -KeyPath $keyPath).StartsWith('ssh-ed25519'))
    }

    Test-Case 'Flujo completo con SSH simulado y rollback' {
        $fakeBin = Join-Path $testRoot 'fakebin'
        New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
        $sshLines = @(
            '@echo off',
            'echo %* | findstr /C:"-G" >nul',
            'if %errorlevel%==0 exit /b 0',
            'echo %* | findstr /C:"id_work" >nul',
            'if %errorlevel%==0 goto work',
            "echo Hi personal-user! You've successfully authenticated, but GitHub does not provide shell access.",
            'exit /b 1',
            ':work',
            "echo Hi work-user! You've successfully authenticated, but GitHub does not provide shell access.",
            'exit /b 1'
        )
        [System.IO.File]::WriteAllLines((Join-Path $fakeBin 'ssh.cmd'), $sshLines, [System.Text.Encoding]::ASCII)

        $oldPath = $env:PATH
        try {
            $env:PATH = $fakeBin + ';' + $oldPath
            $e2eRoot = Join-Path $testRoot 'e2e'
            $p1 = New-ProfileObject -Id personal -Label Personal -Root (Join-Path $e2eRoot 'personal') -GitHubUser 'personal-user' -CommitName 'Personal User' -Email 'personal@example.com' -KeyPath (Join-Path $e2eRoot 'keys\id_personal') -ConfigPath (Join-Path $e2eRoot 'personal.gitconfig')
            $p2 = New-ProfileObject -Id work -Label Trabajo -Root (Join-Path $e2eRoot 'work') -GitHubUser 'work-user' -CommitName 'Work User' -Email 'work@example.com' -KeyPath (Join-Path $e2eRoot 'keys\id_work') -ConfigPath (Join-Path $e2eRoot 'work.gitconfig')
            $statePath = Join-Path $e2eRoot 'state.json'

            Invoke-SetupPlan -Profiles @($p1, $p2) -NoBrowser -NonInteractive -Force -StatePath $statePath -BackupRoot (Join-Path $e2eRoot 'backups')

            $state = Read-SetupState -Path $statePath
            Assert-Equal 'verified' $state.status
            Assert-True (Test-Path -LiteralPath $p1.configPath)
            Assert-True (Test-Path -LiteralPath $p2.configPath)

            $entries = @(Get-ManagedIncludeIfEntries)
            $e2eEntries = @($entries | Where-Object { $_.Root -eq (ConvertTo-NormalizedPath -Path $p1.root) -or $_.Root -eq (ConvertTo-NormalizedPath -Path $p2.root) })
            Assert-Equal 2 $e2eEntries.Count

            $values = Get-ProfileConfigValues -ConfigPath $p1.configPath
            Assert-Equal 'Personal User' $values.UserName
            Assert-Equal 'personal@example.com' $values.Email

            Invoke-Rollback -StatePath $statePath -Force

            $entriesAfter = @(Get-ManagedIncludeIfEntries)
            $e2eEntriesAfter = @($entriesAfter | Where-Object { $_.Root -eq (ConvertTo-NormalizedPath -Path $p1.root) -or $_.Root -eq (ConvertTo-NormalizedPath -Path $p2.root) })
            Assert-Equal 0 $e2eEntriesAfter.Count
            Assert-False (Test-Path -LiteralPath $p1.configPath)
            Assert-False (Test-Path -LiteralPath $p2.configPath)
        }
        finally {
            $env:PATH = $oldPath
        }
    }
}
finally {
    foreach ($key in $oldEnvironment.Keys) {
        Set-Item -Path ("Env:{0}" -f $key) -Value $oldEnvironment[$key] -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('Resultado: {0} correctos, {1} fallidos.' -f $script:Passed, $script:Failed) -ForegroundColor Cyan
if ($script:Failed -gt 0) {
    Write-Host ''
    foreach ($failure in $script:Failures) {
        Write-Host ("- {0}" -f $failure) -ForegroundColor Red
    }
    exit 1
}

exit 0
