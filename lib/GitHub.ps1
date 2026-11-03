Set-StrictMode -Version Latest

function Open-GitHubUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [switch]$NoBrowser
    )

    if ($NoBrowser) {
        Write-UiInfo ("Abre esta URL manualmente: {0}" -f $Url)
        return $false
    }

    try {
        Start-Process -FilePath $Url -ErrorAction Stop | Out-Null
        Write-UiInfo ("Navegador abierto: {0}" -f $Url)
        return $true
    }
    catch {
        Write-UiWarn ("No se pudo abrir el navegador automáticamente: {0}" -f $_.Exception.Message)
        Write-UiInfo ("Abre esta URL manualmente: {0}" -f $Url)
        return $false
    }
}

function Copy-PublicKeyToClipboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath
    )

    $content = Get-SshPublicKeyContent -KeyPath $KeyPath

    try {
        Set-Clipboard -Value $content -ErrorAction Stop
        Write-UiSuccess 'La clave pública se copió al portapapeles.'
        return $true
    }
    catch {
        Write-UiWarn ('No se pudo copiar al portapapeles: {0}' -f $_.Exception.Message)
        Write-UiInfo 'Puedes copiar la clave pública manualmente:'
        Write-Ui $content DarkGray
        return $false
    }
}

function Show-GitHubKeyInstructions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Profile,
        [Parameter(Mandatory = $true)]
        [string]$Fingerprint,
        [string]$PublicKey = ''
    )

    $title = 'Windows - {0} - {1}' -f $Profile.Label, (Get-Date -Format 'yyyy-MM-dd')

    Write-UiSection ("Registrar la clave en GitHub: {0}" -f $Profile.Label)
    Write-UiInfo ("Cuenta esperada: {0}" -f $Profile.GitHubUser)
    Write-UiInfo ("Título sugerido: {0}" -f $title)
    Write-UiInfo ("Huella digital: {0}" -f $Fingerprint)
    Write-Ui ''
    Write-Ui 'Pasos:' White
    Write-Ui '  1. Verifica que la sesión del navegador sea la cuenta correcta.' Gray
    Write-Ui '  2. Entra en Settings > SSH and GPG keys > New SSH key.' Gray
    Write-Ui '  3. Pega la clave pública (ya está en el portapapeles).' Gray
    Write-Ui '  4. Elige el tipo Authentication Key.' Gray
    Write-Ui '  5. Guarda y vuelve a esta ventana.' Gray

    if (-not [string]::IsNullOrWhiteSpace($PublicKey)) {
        Write-Ui ''
        Write-Ui 'Clave pública (por si necesitas copiarla manualmente):' DarkGray
        Write-Ui $PublicKey DarkGray
    }
}

function Register-GitHubKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Profile,
        [switch]$NoBrowser,
        [switch]$NonInteractive,
        [switch]$DryRun
    )

    if ($DryRun) {
        Write-UiInfo ("[dry-run] Se verificaría la clave {0} contra la cuenta {1}." -f $Profile.KeyPath, $Profile.GitHubUser)
        return [pscustomobject]@{
            Ok         = $true
            GitHubUser = $Profile.GitHubUser
            ErrorKind  = ''
            Message    = 'Dry run'
            RawOutput  = ''
            ExitCode   = 0
        }
    }

    Write-UiInfo ("Comprobando si la clave ya autentica como {0}..." -f $Profile.GitHubUser)
    $auth = Test-GitHubSshAuth -KeyPath $Profile.KeyPath -ExpectedUser $Profile.GitHubUser -AcceptNewHostKey

    if ($auth.Ok) {
        Write-UiSuccess ("La clave ya autentica correctamente como {0}." -f $auth.GitHubUser)
        return $auth
    }

    if ($auth.ErrorKind -eq 'WrongAccount') {
        Write-UiError $auth.Message
        Write-UiHint 'Elimina esta clave de la cuenta incorrecta en GitHub y vuelve a ejecutar el asistente.'
        throw ("La clave de {0} pertenece a otra cuenta de GitHub ({1})." -f $Profile.Label, $auth.GitHubUser)
    }
    elseif ($auth.ErrorKind -eq 'HostKey') {
        Write-UiError $auth.Message
        throw 'La verificación de la clave del host falló. No se continuará automáticamente.'
    }
    elseif ($auth.ErrorKind -eq 'Network') {
        Write-UiError $auth.Message
        throw 'No hay conexión con GitHub. Revisa la red y vuelve a intentarlo.'
    }
    elseif ($auth.ErrorKind -eq 'EncryptedKey') {
        Write-UiWarn $auth.Message
        Write-UiHint ("Carga la clave en el agente SSH: ssh-add '{0}'" -f $Profile.KeyPath)
    }
    else {
        Write-UiWarn $auth.Message
    }

    $fingerprint = Get-SshKeyFingerprint -KeyPath $Profile.KeyPath
    $publicKey = ''
    try {
        $publicKey = Get-SshPublicKeyContent -KeyPath $Profile.KeyPath
    }
    catch {
        $publicKey = ''
    }

    [void](Copy-PublicKeyToClipboard -KeyPath $Profile.KeyPath)

    $url = 'https://github.com/login?return_to=%2Fsettings%2Fssh%2Fnew'
    [void](Open-GitHubUrl -Url $url -NoBrowser:$NoBrowser)
    Show-GitHubKeyInstructions -Profile $Profile -Fingerprint $fingerprint -PublicKey $publicKey

    if ($NonInteractive) {
        throw ("La clave {0} no está verificada. Agrégala manualmente en GitHub y vuelve a ejecutar el asistente." -f $Profile.Label)
    }

    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Ui ''
        Write-Ui ("Intento {0} de {1}." -f $attempt, $maxAttempts) Cyan
        [void](Read-Host 'Presiona Enter cuando hayas guardado la clave en GitHub')
        Write-UiInfo 'Verificando autenticación con GitHub...'

        $auth = Test-GitHubSshAuth -KeyPath $Profile.KeyPath -ExpectedUser $Profile.GitHubUser -AcceptNewHostKey
        if ($auth.Ok) {
            Write-UiSuccess ("Autenticación correcta como {0}." -f $auth.GitHubUser)
            return $auth
        }

        if ($auth.ErrorKind -eq 'WrongAccount') {
            Write-UiError $auth.Message
            Write-UiHint 'La clave está en otra cuenta. Elimínala de esa cuenta y agrégala a la correcta.'
        }
        elseif ($auth.ErrorKind -eq 'EncryptedKey') {
            Write-UiWarn $auth.Message
            Write-UiHint ("Carga la clave en ssh-agent: ssh-add '{0}'" -f $Profile.KeyPath)
        }
        elseif ($auth.ErrorKind -eq 'HostKey') {
            Write-UiError $auth.Message
            Write-UiHint 'Revisa la huella de GitHub antes de continuar. No desactives la verificación permanentemente.'
        }
        else {
            Write-UiWarn $auth.Message
        }
    }

    throw ("No se pudo verificar la clave {0} después de {1} intentos." -f $Profile.Label, $maxAttempts)
}

function Get-GitHubNoreplyEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitHubUser
    )

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $user = Invoke-RestMethod -Uri ("https://api.github.com/users/{0}" -f [uri]::EscapeDataString($GitHubUser)) -TimeoutSec 10 -ErrorAction Stop
        if ($user -ne $null -and $user.id -ne $null) {
            return ('{0}+{1}@users.noreply.github.com' -f $user.id, $GitHubUser)
        }
    }
    catch {
        Write-UiLog ("No se pudo consultar el email noreply de GitHub: {0}" -f $_.Exception.Message) 'WARN'
    }

    return $null
}
