#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$DryRun,
    [switch]$Rollback,
    [switch]$Force,
    [switch]$NoBrowser,
    [switch]$NoColor,
    [switch]$Help,
    [string]$Config = '',
    [string]$StatePath = '',
    [string]$LogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = $PSScriptRoot

. (Join-Path $script:ProjectRoot 'lib\Ui.ps1')
. (Join-Path $script:ProjectRoot 'lib\Paths.ps1')
. (Join-Path $script:ProjectRoot 'lib\GitConfig.ps1')
. (Join-Path $script:ProjectRoot 'lib\Ssh.ps1')
. (Join-Path $script:ProjectRoot 'lib\GitHub.ps1')
. (Join-Path $script:ProjectRoot 'lib\State.ps1')
. (Join-Path $script:ProjectRoot 'lib\Preflight.ps1')
. (Join-Path $script:ProjectRoot 'lib\Wizard.ps1')

function Show-Usage {
    Write-Ui ''
    Write-Ui 'Uso:' White
    Write-Ui '  .\setup.cmd' Gray
    Write-Ui '  .\setup.cmd -Check' Gray
    Write-Ui '  .\setup.cmd -DryRun' Gray
    Write-Ui '  .\setup.cmd -Config .\examples\setup.example.json' Gray
    Write-Ui '  .\setup.cmd -Rollback' Gray
    Write-Ui ''
    Write-Ui 'Opciones:' White
    Write-Ui '  -Check        Diagnóstico de solo lectura.' Gray
    Write-Ui '  -DryRun       Muestra lo que haría, sin escribir.' Gray
    Write-Ui '  -Rollback     Deshace la última configuración gestionada.' Gray
    Write-Ui '  -Force        No pide confirmación (útil con -Config y -Rollback).' Gray
    Write-Ui '  -NoBrowser    No abre el navegador; muestra la URL.' Gray
    Write-Ui '  -NoColor      Desactiva los colores.' Gray
    Write-Ui '  -Config PATH  Ejecuta con un archivo JSON de configuración.' Gray
    Write-Ui '  -StatePath P  Cambia la ruta del archivo de estado.' Gray
    Write-Ui '  -LogPath P    Cambia la ruta del log.' Gray
    Write-Ui '  -Help         Muestra esta ayuda.' Gray
    Write-Ui ''
}

if ($Help) {
    Initialize-Ui -NoColor:$NoColor
    Write-UiBanner
    Show-Usage
    exit 0
}

if ($Check -and $Rollback) {
    Write-UiError 'No se pueden combinar -Check y -Rollback.'
    exit 1
}

if ($Check -and -not [string]::IsNullOrWhiteSpace($Config)) {
    Write-UiError 'No se pueden combinar -Check y -Config.'
    exit 1
}

if ($Rollback -and -not [string]::IsNullOrWhiteSpace($Config)) {
    Write-UiError 'No se pueden combinar -Rollback y -Config.'
    exit 1
}

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Get-DefaultStatePath
}

if ([string]::IsNullOrWhiteSpace($LogPath) -and -not $Check -and -not $DryRun) {
    $LogPath = Get-DefaultLogPath
}

Initialize-Ui -NoColor:$NoColor -LogPath $LogPath
Write-UiBanner

if (-not $Check -and (Test-IsAdministrator)) {
    Write-UiError 'No ejecutes el asistente como administrador. Usa una sesión normal de Windows.'
    Write-UiHint 'Ejecutarlo elevado puede crear claves y configuración con permisos del administrador.'
    exit 1
}

try {
    if ($Check) {
        $report = Get-PreflightReport
        $code = Invoke-Doctor -Report $report
        exit $code
    }

    if ($Rollback) {
        Invoke-Rollback -StatePath $StatePath -Force:$Force -DryRun:$DryRun
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($Config)) {
        $configPath = ConvertTo-NormalizedPath -Path $Config
        $profiles = Read-SetupConfig -Path $configPath
        $report = Get-PreflightReport
        Show-PreflightReport -Report $report
        Assert-Preflight -Report $report
        Invoke-SetupPlan -Profiles $profiles -DryRun:$DryRun -NoBrowser:$NoBrowser -NonInteractive:$NoBrowser -Force:$Force -StatePath $StatePath
        exit 0
    }

    Invoke-SetupWizard -DryRun:$DryRun -NoBrowser:$NoBrowser -StatePath $StatePath
    exit 0
}
catch {
    Write-UiError $_.Exception.Message
    Write-UiLog ("Error: {0}" -f $_.Exception.ToString()) 'ERROR'
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Write-UiHint ("Revisa el log: {0}" -f $LogPath)
    }
    exit 1
}
