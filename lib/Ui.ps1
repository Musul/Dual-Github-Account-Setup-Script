Set-StrictMode -Version Latest

$script:UiNoColor = $false
$script:UiSilent = $false
$script:UiLogPath = $null
$script:UiLogEnabled = $false

function Initialize-Ui {
    [CmdletBinding()]
    param(
        [switch]$NoColor,
        [switch]$Silent,
        [string]$LogPath
    )

    $script:UiNoColor = [bool]$NoColor
    $script:UiSilent = [bool]$Silent
    $script:UiLogPath = $LogPath
    $script:UiLogEnabled = -not [string]::IsNullOrWhiteSpace($LogPath)

    if ($script:UiLogEnabled) {
        try {
            $logDir = Split-Path -Parent $LogPath
            if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
        }
        catch {
            $script:UiLogEnabled = $false
        }
    }

    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
    catch {
        # Some hosts (for example ISE) do not allow changing the console encoding.
    }
}

function Write-UiLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    if (-not $script:UiLogEnabled) {
        return
    }

    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message
        Add-Content -LiteralPath $script:UiLogPath -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never break the wizard.
    }
}

function Write-Ui {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray,
        [switch]$NoNewline
    )

    if ($script:UiSilent) {
        return
    }

    if ($script:UiNoColor) {
        if ($NoNewline) {
            Write-Host $Message -NoNewline
        }
        else {
            Write-Host $Message
        }
    }
    else {
        if ($NoNewline) {
            Write-Host $Message -ForegroundColor $Color -NoNewline
        }
        else {
            Write-Host $Message -ForegroundColor $Color
        }
    }
}

function Write-UiBanner {
    [CmdletBinding()]
    param()

    Write-Ui ''
    Write-Ui '============================================================' Cyan
    Write-Ui '  Configurador de dos cuentas de GitHub' Cyan
    Write-Ui '  Personal + Trabajo, con SSH y Git' Cyan
    Write-Ui '============================================================' Cyan
    Write-Ui ''
}

function Write-UiStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Number,
        [Parameter(Mandatory = $true)]
        [int]$Total,
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    Write-Ui ''
    Write-Ui ("[{0}/{1}] {2}" -f $Number, $Total, $Text) Cyan
    Write-Ui ('-' * 60) DarkGray
}

function Write-UiSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    Write-Ui ''
    Write-Ui $Text White
    Write-Ui ('-' * [Math]::Min(60, [Math]::Max(10, $Text.Length))) DarkGray
}

function Write-UiInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()]     [string]$Message)
    Write-Ui ("[i] {0}" -f $Message) Gray
    Write-UiLog $Message 'INFO'
}

function Write-UiDetail {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()]     [string]$Message)
    Write-Ui ("    {0}" -f $Message) DarkGray
}

function Write-UiSuccess {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()]     [string]$Message)
    Write-Ui ("[OK] {0}" -f $Message) Green
    Write-UiLog $Message 'OK'
}

function Write-UiWarn {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()]     [string]$Message)
    Write-Ui ("[!] {0}" -f $Message) Yellow
    Write-UiLog $Message 'WARN'
}

function Write-UiError {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()]     [string]$Message)
    Write-Ui ("[X] {0}" -f $Message) Red
    Write-UiLog $Message 'ERROR'
}

function Write-UiHint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()]     [string]$Message)
    Write-Ui ("    {0}" -f $Message) DarkYellow
}

function Read-UiText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [string]$Default = '',
        [switch]$Required,
        [scriptblock]$Validator
    )

    while ($true) {
        $displayDefault = $Default
        if ($displayDefault -eq $null) {
            $displayDefault = ''
        }

        if ([string]::IsNullOrWhiteSpace($displayDefault)) {
            $value = Read-Host $Prompt
        }
        else {
            $value = Read-Host ("{0} [{1}]" -f $Prompt, $displayDefault)
        }

        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $displayDefault
        }

        $value = $value.Trim()

        if ($Required -and [string]::IsNullOrWhiteSpace($value)) {
            Write-UiWarn 'Este valor es obligatorio.'
            continue
        }

        if ($Validator -ne $null) {
            $validationMessage = & $Validator $value
            if (-not [string]::IsNullOrWhiteSpace([string]$validationMessage)) {
                Write-UiWarn ([string]$validationMessage)
                continue
            }
        }

        return $value
    }
}

function Read-UiYesNo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [bool]$Default = $false
    )

    if ($Default) {
        $suffix = 'S/n'
    }
    else {
        $suffix = 's/N'
    }

    while ($true) {
        $value = Read-Host ("{0} [{1}]" -f $Prompt, $suffix)
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $Default
        }

        switch ($value.Trim().ToLowerInvariant()) {
            's' { return $true }
            'si' { return $true }
            'sí' { return $true }
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
            default { Write-UiWarn 'Responde s o n.' }
        }
    }
}

function Read-UiChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [Parameter(Mandatory = $true)]
        [string[]]$Options,
        [int]$DefaultIndex = 0
    )

    if ($Options.Count -eq 0) {
        throw 'Read-UiChoice requires at least one option.'
    }

    while ($true) {
        for ($index = 0; $index -lt $Options.Count; $index++) {
            $marker = ''
            if ($index -eq $DefaultIndex) {
                $marker = ' (predeterminado)'
            }
            Write-Ui ("  {0}. {1}{2}" -f ($index + 1), $Options[$index], $marker) Gray
        }

        $value = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $DefaultIndex
        }

        $number = 0
        if ([int]::TryParse($value.Trim(), [ref]$number)) {
            if ($number -ge 1 -and $number -le $Options.Count) {
                return ($number - 1)
            }
        }

        Write-UiWarn ("Elige un número entre 1 y {0}." -f $Options.Count)
    }
}

function Write-UiKeyValueTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,
        [Parameter(Mandatory = $true)]
        [string[]]$Columns,
        [int[]]$Widths
    )

    if ($Rows.Count -eq 0) {
        return
    }

    if ($Widths -eq $null -or $Widths.Count -ne $Columns.Count) {
        $computed = @()
        for ($index = 0; $index -lt $Columns.Count; $index++) {
            $max = $Columns[$index].Length
            foreach ($row in $Rows) {
                $value = [string]$row.($Columns[$index])
                if ($value.Length -gt $max) {
                    $max = $value.Length
                }
            }
            $computed += [Math]::Min(48, [Math]::Max(8, $max))
        }
        $Widths = $computed
    }

    $headerParts = @()
    for ($index = 0; $index -lt $Columns.Count; $index++) {
        $headerParts += $Columns[$index].PadRight($Widths[$index])
    }
    Write-Ui ($headerParts -join ' ') DarkGray

    $separatorParts = @()
    for ($index = 0; $index -lt $Columns.Count; $index++) {
        $separatorParts += ('-' * $Widths[$index])
    }
    Write-Ui ($separatorParts -join ' ') DarkGray

    foreach ($row in $Rows) {
        $parts = @()
        for ($index = 0; $index -lt $Columns.Count; $index++) {
            $value = [string]$row.($Columns[$index])
            if ($value.Length -gt $Widths[$index]) {
                $value = $value.Substring(0, [Math]::Max(0, $Widths[$index] - 3)) + '...'
            }
            $parts += $value.PadRight($Widths[$index])
        }
        Write-Ui ($parts -join ' ') Gray
    }
}

function Wait-UiEnter {
    [CmdletBinding()]
    param([string]$Message = 'Presiona Enter para continuar...')

    [void](Read-Host $Message)
}

function Assert-UiInteractive {
    [CmdletBinding()]
    param([string]$Context = 'esta operación')

    if ([Console]::IsInputRedirected) {
        throw ("{0} requiere una consola interactiva." -f $Context)
    }
}
