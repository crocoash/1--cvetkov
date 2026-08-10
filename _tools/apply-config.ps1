# Пакетная загрузка конфигурации из файлов и обновление базы. Запускать НА МАШИНЕ С 1С.
# Заменяет ручные шаги: git pull -> Конфигуратор -> «Загрузить конфигурацию из файлов» -> F7.
#
# Использование (Windows):
#   powershell -File _tools\apply-config.ps1                # pull + резервная копия + загрузка + обновление БД
#   powershell -File _tools\apply-config.ps1 -БезРезервной   # без .dt (быстрее, но без страховки)
#   powershell -File _tools\apply-config.ps1 -БезPull        # загрузить то, что уже лежит в папке
#   powershell -File _tools\apply-config.ps1 -Выгрузить      # обратное направление: БД -> файлы -> снимок
#
# Параметры подключения берутся из _tools\1c-local.json (файл машинный, в git не уезжает).
# При первом запуске скрипт создаст шаблон и остановится.
#
# Важно: обновление конфигурации БД требует, чтобы в базе не было других сеансов
# (включая открытый Конфигуратор). Иначе платформа вернёт ошибку блокировки.

param(
    [switch]$БезPull,
    [switch]$БезРезервной,
    [switch]$Выгрузить,
    [string]$Ветка = "main"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$git = "C:\Program Files\Git\cmd\git.exe"
if (-not (Test-Path $git)) { $git = "git" }

# --- Настройки машины --------------------------------------------------------

$файлНастроек = Join-Path $PSScriptRoot "1c-local.json"
if (-not (Test-Path $файлНастроек)) {
    $шаблон = @{
        # Заполнить ОДНО из двух: путь к каталогу файловой базы либо "сервер\имя_базы".
        ФайловаяБаза   = "C:\Базы\cvetkov"
        СервернаяБаза  = ""
        Пользователь   = "Администратор"
        Пароль         = ""
        ПапкаРезервных = "C:\Базы\backup"
        # Путь к 1cv8.exe. Пусто — искать самую свежую установленную версию.
        Платформа      = ""
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($файлНастроек, $шаблон, (New-Object System.Text.UTF8Encoding $true))
    Write-Host "Создан шаблон настроек: $файлНастроек" -ForegroundColor Yellow
    Write-Host "Заполните базу и пользователя, затем запустите скрипт снова." -ForegroundColor Yellow
    exit 2
}
$нст = Get-Content $файлНастроек -Raw -Encoding UTF8 | ConvertFrom-Json

# --- Поиск платформы --------------------------------------------------------

$exe = $нст.Платформа
if (-not $exe) {
    $кандидаты = @()
    foreach ($база in @("C:\Program Files\1cv8", "C:\Program Files (x86)\1cv8")) {
        if (Test-Path $база) {
            $кандидаты += Get-ChildItem $база -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
                ForEach-Object { Join-Path $_.FullName "bin\1cv8.exe" } |
                Where-Object { Test-Path $_ }
        }
    }
    # Сортировка по номеру версии, а не по строке: иначе 8.3.9 окажется старше 8.3.25.
    $exe = $кандидаты |
        Sort-Object { [version](Split-Path (Split-Path (Split-Path $_ -Parent) -Parent) -Leaf) } |
        Select-Object -Last 1
}
if (-not $exe -or -not (Test-Path $exe)) {
    Write-Host "Не найден 1cv8.exe. Укажите путь в поле Платформа файла $файлНастроек" -ForegroundColor Red
    exit 1
}

# --- Общие аргументы Конфигуратора ------------------------------------------

$общие = @("DESIGNER")
if ($нст.ФайловаяБаза) {
    $общие += @("/F", $нст.ФайловаяБаза)
} elseif ($нст.СервернаяБаза) {
    $общие += @("/S", $нст.СервернаяБаза)
} else {
    Write-Host "В $файлНастроек не заполнена ни ФайловаяБаза, ни СервернаяБаза." -ForegroundColor Red
    exit 1
}
if ($нст.Пользователь) { $общие += @("/N", $нст.Пользователь) }
if ($нст.Пароль)       { $общие += @("/P", $нст.Пароль) }
$общие += @("/DisableStartupMessages", "/DisableStartupDialogs")

function Запустить1С([string[]]$Аргументы, [string]$Что) {
    Write-Host "== $Что" -ForegroundColor Cyan
    $лог = Join-Path $env:TEMP ("1c-apply-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".log")
    $всё = $общие + $Аргументы + @("/Out", $лог)
    $p = Start-Process -FilePath $exe -ArgumentList $всё -Wait -PassThru -WindowStyle Hidden
    if (Test-Path $лог) {
        $текст = (Get-Content $лог -Raw -Encoding UTF8)
        if ($текст) { Write-Host $текст.Trim() }
    }
    if ($p.ExitCode -ne 0) {
        Write-Host "ОШИБКА: «$Что» завершилось с кодом $($p.ExitCode). Лог: $лог" -ForegroundColor Red
        exit $p.ExitCode
    }
}

# --- Обратное направление: БД -> файлы -> снимок ----------------------------

if ($Выгрузить) {
    Запустить1С @("/DumpConfigToFiles", $root, "-force") "Выгрузка конфигурации в файлы"
    $шелл = (Get-Process -Id $PID).Path
    if (-not $шелл) { $шелл = "powershell" }
    & $шелл -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "snapshot.ps1") "Выгрузка конфигурации из базы"
    exit $LASTEXITCODE
}

# --- Прямое направление: git -> файлы -> БД ---------------------------------

if (-not $БезPull) {
    Write-Host "== git pull --ff-only origin $Ветка" -ForegroundColor Cyan
    & $git pull --ff-only origin $Ветка
    if ($LASTEXITCODE -ne 0) {
        Write-Host "git pull не прошёл. Вероятно, в папке есть локальные изменения" -ForegroundColor Red
        Write-Host "(выгрузка из Конфигуратора поверх папки?). Разобраться вручную." -ForegroundColor Red
        exit 1
    }
}

if (-not $БезРезервной) {
    $папка = $нст.ПапкаРезервных
    if ($папка) {
        if (-not (Test-Path $папка)) { New-Item -ItemType Directory -Path $папка -Force | Out-Null }
        $dt = Join-Path $папка ("cvetkov-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".dt")
        Запустить1С @("/DumpIB", $dt) "Резервная копия базы -> $dt"
    }
}

# Загрузка и обновление одним вызовом Конфигуратора: между ними база не остаётся
# в состоянии «основная конфигурация уже новая, конфигурация БД ещё старая».
# -Dynamic- запрещает динамическое обновление: структурные изменения должны
# применяться полноценно, иначе часть правок в базу не попадёт.
# -WarningsAsErrors не ставим — типовая конфигурация даёт предупреждения всегда.
Запустить1С @("/LoadConfigFromFiles", $root, "/UpdateDBCfg", "-Dynamic-") "Загрузка из файлов + обновление конфигурации БД"

Write-Host ""
Write-Host "Готово: конфигурация загружена, база обновлена." -ForegroundColor Green
