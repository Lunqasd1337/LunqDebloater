# Счётчик шагов для вывода «Шаг N из M».
$script:StepCurrent = 0
$script:StepTotal = 0

function Initialize-LunqSteps {
    param([Parameter(Mandatory)][int]$Total)
    $script:StepCurrent = 0
    $script:StepTotal = $Total
}

function Write-Step {
    # Заголовок шага. -Hint выводит под ним короткое пояснение для нового пользователя.
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Hint
    )
    Write-Host ''
    if ($script:StepTotal -gt 0) {
        $script:StepCurrent++
        Write-Host ("==> Шаг {0} из {1}. {2}" -f $script:StepCurrent, $script:StepTotal, $Message) -ForegroundColor Cyan
    }
    else {
        Write-Host "==> $Message" -ForegroundColor Cyan
    }
    if ($Hint) { Write-Host "    $Hint" -ForegroundColor DarkGray }
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor Yellow
}

function Write-Info {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Write-Host "    $Message"
}

function Write-Check {
    # Строка проверки: [ OK ], [ !! ] (предупреждение) или [FAIL].
    param(
        [Parameter(Mandatory)][ValidateSet('Ok', 'Warn', 'Fail')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [string]$Hint
    )
    $label = @{ Ok = '[ OK ]'; Warn = '[ !! ]'; Fail = '[FAIL]' }[$Status]
    $color = @{ Ok = 'Green'; Warn = 'Yellow'; Fail = 'Red' }[$Status]
    # Одной строкой: Write-Host -NoNewline разбивает строку в логе надвое.
    Write-Host "    $label $Message" -ForegroundColor $color
    if ($Hint) { Write-Host "           $Hint" -ForegroundColor DarkGray }
}

function Read-YesNo {
    # Спрашивает да/нет. Принимает y/yes/д/да в любом регистре, всё остальное означает «нет».
    param([Parameter(Mandatory)][string]$Prompt)
    $answer = Read-Host "    $Prompt [Y/N]"
    return ($answer.Trim().ToLower() -in @('y', 'yes', 'д', 'да'))
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -lt 1GB) { return ('{0:N0} МБ' -f ($Bytes / 1MB)) }
    return ('{0:N1} ГБ' -f ($Bytes / 1GB))
}
