# Снимок текущей выгрузки конфигурации в git.
# Запускать ПОСЛЕ того, как залил новую полную выгрузку файлов поверх этой папки.
# Использование:
#   powershell -File _tools\snapshot.ps1
#   powershell -File _tools\snapshot.ps1 "Добавил реквизит в справочник Контрагенты"

param([string]$Message = "")

$ErrorActionPreference = "Stop"
$git = "C:\Program Files\Git\cmd\git.exe"
if (-not (Test-Path $git)) { $git = "git" }

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Выгрузка выборочно теряет base64-блоб <object> у рисунков-штрихкодов.
# Сначала восстанавливаем потерянные объекты, затем проверяем результат.
$починка = Join-Path $PSScriptRoot "fix-barcodes.ps1"
if (Test-Path $починка) { & powershell -NoProfile -ExecutionPolicy Bypass -File $починка -Применить }

# Проверка встроенных объектов в макетах (штрихкоды) — выгрузка их иногда теряет.
$проверка = Join-Path $PSScriptRoot "check-barcodes.ps1"
if (Test-Path $проверка) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $проверка
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ВНИМАНИЕ: в выгрузке битые макеты штрихкодов (см. выше)." -ForegroundColor Yellow
        Write-Host "Снимок всё равно будет создан — он фиксирует то, что реально лежит в файлах." -ForegroundColor Yellow
    }
    Write-Host ""
}

& $git add -A 2>&1 | Out-Null

$dirty = & $git status --porcelain
if (-not $dirty) {
    Write-Host "Изменений нет — новый снимок не создан." -ForegroundColor Yellow
    exit 0
}

$stat = & $git diff --cached --shortstat
if (-not $Message) {
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
    $Message = "Выгрузка $stamp"
}

& $git commit -q -m $Message
Write-Host "Снимок создан: $Message" -ForegroundColor Green
Write-Host $stat
Write-Host ""
Write-Host "Что изменилось:" -ForegroundColor Cyan
& $git show --stat --oneline HEAD | Select-Object -First 40