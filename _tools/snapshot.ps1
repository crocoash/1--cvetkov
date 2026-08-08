# Снимок текущей выгрузки конфигурации в git.
# Запускать ПОСЛЕ того, как залил новую полную выгрузку файлов поверх этой папки.
# Использование:
#   Windows: powershell -File _tools\snapshot.ps1 ["сообщение"]
#   macOS:   pwsh -NoProfile -File _tools/snapshot.ps1 ["сообщение"]

param([string]$Message = "")

$ErrorActionPreference = "Stop"
$git = "C:\Program Files\Git\cmd\git.exe"
if (-not (Test-Path $git)) { $git = "git" }

# Хост-шелл: на Windows это powershell.exe, на macOS/Linux — pwsh. Нужен для вызова
# вложенных скриптов тем же интерпретатором, которым запущен этот.
$шелл = (Get-Process -Id $PID).Path
if (-not $шелл) { $шелл = if ($IsWindows -eq $false) { "pwsh" } else { "powershell" } }

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Выгрузка выборочно теряет base64-блоб <object> у рисунков-штрихкодов.
# Сначала восстанавливаем потерянные объекты, затем проверяем результат.
$починка = Join-Path $PSScriptRoot "fix-barcodes.ps1"
if (Test-Path $починка) { & $шелл -NoProfile -ExecutionPolicy Bypass -File $починка -Применить }

# Проверка встроенных объектов в макетах (штрихкоды) — выгрузка их иногда теряет.
$проверка = Join-Path $PSScriptRoot "check-barcodes.ps1"
if (Test-Path $проверка) {
    & $шелл -NoProfile -ExecutionPolicy Bypass -File $проверка
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ВНИМАНИЕ: в выгрузке битые макеты штрихкодов (см. выше)." -ForegroundColor Yellow
        Write-Host "Снимок всё равно будет создан — он фиксирует то, что реально лежит в файлах." -ForegroundColor Yellow
    }
    Write-Host ""
}

# Структурная проверка изменённых модулей .bsl. Конфигуратора здесь нет, и
# ошибка компиляции иначе выясняется только после круга push -> pull -> загрузка
# конфигурации. Снимок при ошибке всё равно создаём (он страховка), но push
# не делаем: пусть сломанный модуль не уезжает на машину с 1С.
$бсл = Join-Path $PSScriptRoot "check-bsl.ps1"
$бслСломан = $false
if (Test-Path $бсл) {
    & $шелл -NoProfile -ExecutionPolicy Bypass -File $бсл
    if ($LASTEXITCODE -ne 0) { $бслСломан = $true }
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

# Перенос на машину с 1С идёт через GitHub: без push снимок туда не попадёт.
Write-Host ""
$ветка = (& $git rev-parse --abbrev-ref HEAD).Trim()

if ($бслСломан) {
    Write-Host "PUSH ПРОПУЩЕН: в модулях .bsl ошибки (см. выше)." -ForegroundColor Red
    Write-Host "Снимок создан локально. Почините модуль и повторите снимок." -ForegroundColor Red
    exit 1
}

& $git push origin $ветка 2>&1 | Write-Host
if ($LASTEXITCODE -eq 0) {
    Write-Host "Отправлено на origin/$ветка — можно делать pull на машине с 1С." -ForegroundColor Green
} else {
    Write-Host "PUSH НЕ ПРОШЁЛ. Снимок есть только локально, на машину с 1С он не попадёт." -ForegroundColor Red
    Write-Host "Разобраться и отправить вручную: git push origin $ветка" -ForegroundColor Red
    exit 1
}