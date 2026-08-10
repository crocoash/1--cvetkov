# Пакетная загрузка конфигурации из файлов и обновление базы. Запускать НА МАШИНЕ С 1С.
# Заменяет ручные шаги: git pull -> Конфигуратор -> «Загрузить конфигурацию из файлов» -> F7.
#
# Использование (Windows):
#   powershell -File _tools\apply-config.ps1 -Настроить      # выбрать базу из списка и сохранить настройки
#   powershell -File _tools\apply-config.ps1                # pull + загрузка + обновление БД
#   powershell -File _tools\apply-config.ps1 -СРезервной     # плюс выгрузка базы в .dt перед загрузкой
#   powershell -File _tools\apply-config.ps1 -БезРезервной   # запретить .dt даже для файловой базы
#   powershell -File _tools\apply-config.ps1 -ТолькоЗагрузка  # только загрузка из файлов (можно при людях)
#   powershell -File _tools\apply-config.ps1 -ТолькоОбновить  # только обновление БД (нужен монопольный режим)
#   powershell -File _tools\apply-config.ps1 -Динамически     # обновить БД не выгоняя людей (только неструктурные правки)
#   powershell -File _tools\apply-config.ps1 -БезPull        # загрузить то, что уже лежит в папке
#   powershell -File _tools\apply-config.ps1 -Выгрузить      # обратное направление: БД -> файлы -> снимок
#
# Параметры подключения берутся из _tools\1c-local.json (файл машинный, в git не уезжает).
# Если файла нет — скрипт сам предложит выбрать базу из зарегистрированных на машине.
#
# Важно: обновление конфигурации БД требует, чтобы в базе не было других сеансов
# (включая открытый Конфигуратор). Иначе платформа вернёт ошибку блокировки.

# Латинские псевдонимы нужны для запуска из .cmd: кириллица в имени параметра
# проходит через cmd только при совпадении кодовых страниц, а это ненадёжно.
param(
    [Alias("setup")]      [switch]$Настроить,
    [Alias("nopull")]     [switch]$БезPull,
    [Alias("nobackup")]   [switch]$БезРезервной,
    [Alias("backup")]     [switch]$СРезервной,
    [Alias("loadonly")]   [switch]$ТолькоЗагрузка,
    [Alias("updateonly")] [switch]$ТолькоОбновить,
    [Alias("dyn")]        [switch]$Динамически,
    [Alias("dump")]       [switch]$Выгрузить,
    [string]$Ветка = "main"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$git = "C:\Program Files\Git\cmd\git.exe"
if (-not (Test-Path $git)) { $git = "git" }

# --- Настройки машины --------------------------------------------------------

$файлНастроек = Join-Path $PSScriptRoot "1c-local.json"

# Диалог настройки: список баз берём из ibases.v8i (то же, что видно в окне запуска 1С),
# спрашиваем номер и учётную запись, пишем json сами. Руками json править не нужно —
# при ручной правке легко забыть сохранить или ошибиться в двойных слэшах.
function Настроить {
    $v8i = Join-Path $env:APPDATA "1C\1CEStart\ibases.v8i"
    $базы = @()
    if (Test-Path $v8i) {
        $имя = ""
        foreach ($строка in (Get-Content $v8i -Encoding UTF8)) {
            $t = $строка.Trim()
            if ($t -match '^\[(.+)\]$') { $имя = $matches[1]; continue }
            if ($t -match '^Connect=(.+)$') {
                $c = $matches[1]
                $файл = ""; $сервер = ""
                if ($c -match 'File\s*=\s*"([^"]+)"') { $файл = $matches[1] }
                if ($c -match 'Srvr\s*=\s*"([^"]+)"' ) { $сервер = $matches[1] }
                $ref = ""
                if ($c -match 'Ref\s*=\s*"([^"]+)"'  ) { $ref = $matches[1] }
                $базы += [pscustomobject]@{
                    Имя           = $имя
                    ФайловаяБаза  = $файл
                    СервернаяБаза = if ($сервер) { "$сервер\$ref" } else { "" }
                }
            }
        }
    }

    if ($базы.Count -eq 0) {
        Write-Host "Не удалось прочитать список баз ($v8i)." -ForegroundColor Red
        Write-Host "Заполните $файлНастроек вручную." -ForegroundColor Red
        exit 1
    }

    Write-Host "Базы, зарегистрированные на этой машине:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $базы.Count; $i++) {
        $где = $базы[$i].ФайловаяБаза
        if (-not $где) { $где = $базы[$i].СервернаяБаза + "  (серверная)" }
        Write-Host ("  [{0}] {1}  ->  {2}" -f ($i + 1), $базы[$i].Имя, $где)
    }
    Write-Host ""

    $номер = 0
    while ($номер -lt 1 -or $номер -gt $базы.Count) {
        $ответ = Read-Host "Номер базы, которую обновлять"
        [int]::TryParse($ответ, [ref]$номер) | Out-Null
    }
    $выбор = $базы[$номер - 1]

    $пользователь = Read-Host "Пользователь Конфигуратора (Enter = Администратор)"
    if (-not $пользователь) { $пользователь = "Администратор" }
    $секрет = Read-Host "Пароль (Enter, если пароля нет)" -AsSecureString
    $пароль = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($секрет))

    $данные = @{
        ФайловаяБаза   = $выбор.ФайловаяБаза
        СервернаяБаза  = $выбор.СервернаяБаза
        Пользователь   = $пользователь
        Пароль         = $пароль
        # .dt нужен только для файловой базы; на серверной страховка — бэкап SQL.
        ПапкаРезервных = if ($выбор.ФайловаяБаза) { Join-Path $env:USERPROFILE "1c-backup" } else { "" }
        Платформа      = ""
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($файлНастроек, $данные, (New-Object System.Text.UTF8Encoding $true))
    Write-Host ""
    Write-Host "Настройки сохранены: $файлНастроек" -ForegroundColor Green
}

if ($Настроить -or -not (Test-Path $файлНастроек)) {
    Настроить
    if ($Настроить) { exit 0 }
    Write-Host ""
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
    $текст = ""
    if (Test-Path $лог) {
        $текст = (Get-Content $лог -Raw -Encoding UTF8)
        if ($текст) { Write-Host $текст.Trim() }
    }
    if ($p.ExitCode -ne 0) {
        Write-Host "ОШИБКА: «$Что» завершилось с кодом $($p.ExitCode). Лог: $лог" -ForegroundColor Red
        # Самая частая помеха — забытый открытый Конфигуратор, часто на другом компьютере:
        # платформа пишет в лог, где именно он висит. Подсказываем, что читать.
        # Две разные блокировки, лечатся по-разному:
        #   «для конфигурирования» — базу держит открытый Конфигуратор, загрузка даже не начиналась;
        #   «исключительной»       — работают пользователи, загрузка уже прошла, остался шаг обновления.
        if ($текст -match "для конфигурирования") {
            Write-Host ""
            Write-Host "Базу держит открытый КОНФИГУРАТОР — компьютер и сеанс указаны выше." -ForegroundColor Yellow
            Write-Host "Закройте его там (это может быть другой компьютер) и запустите снова." -ForegroundColor Yellow
            Write-Host "Загрузка из файлов при этом НЕ выполнялась — нужен обычный запуск, не -ТолькоОбновить." -ForegroundColor Yellow
        } elseif ($текст -match "блокировк") {
            Write-Host ""
            Write-Host "В базе работают пользователи — компьютеры и сеансы перечислены выше." -ForegroundColor Yellow
            Write-Host "Обновление конфигурации БД идёт только в монопольном режиме: нужно, чтобы все" -ForegroundColor Yellow
            Write-Host "вышли из базы, либо завершить сеансы в консоли администрирования кластера." -ForegroundColor Yellow
            if (-not $ТолькоОбновить) {
                Write-Host "Загрузка из файлов уже прошла — повторять её не нужно. Когда база освободится:" -ForegroundColor Yellow
                Write-Host "  apply-config.ps1 -ТолькоОбновить      (или пункт 4 в меню)" -ForegroundColor Yellow
                Write-Host "Не выгоняя людей, если правки неструктурные:" -ForegroundColor Yellow
                Write-Host "  apply-config.ps1 -ТолькоОбновить -Динамически   (пункт 5)" -ForegroundColor Yellow
            }
        }
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

# На серверной базе (SQL) выгрузка в .dt идёт десятки минут и страховкой не является —
# её роль играет бэкап самого SQL Server. Поэтому для серверной базы .dt по умолчанию
# пропускаем; если он всё-таки нужен — явный флаг -СРезервной.
$делатьРезервную = -not $БезРезервной
if ($нст.СервернаяБаза -and -not $СРезервной) {
    if ($делатьРезервную) {
        Write-Host "== Резервная копия .dt пропущена: база серверная (страховка — бэкап SQL)." -ForegroundColor DarkGray
        Write-Host "   Нужна выгрузка в .dt — запустить с флагом -СРезервной." -ForegroundColor DarkGray
    }
    $делатьРезервную = $false
}

if ($делатьРезервную) {
    $папка = $нст.ПапкаРезервных
    if ($папка) {
        if (-not (Test-Path $папка)) { New-Item -ItemType Directory -Path $папка -Force | Out-Null }
        # Имя файла — от имени базы, а не захардкоженное: чтобы бэкапы разных баз не путались.
        if ($нст.ФайловаяБаза) {
            $имяБазы = Split-Path $нст.ФайловаяБаза -Leaf
        } else {
            $имяБазы = ($нст.СервернаяБаза -split '\\')[-1]
        }
        $dt = Join-Path $папка ($имяБазы + "-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".dt")
        Запустить1С @("/DumpIB", $dt) "Резервная копия базы -> $dt"
    }
}

# Два шага с разными требованиями к базе:
#   загрузка из файлов  — работает при активных пользователях, идёт долго (минуты);
#   обновление конфигурации БД — требует МОНОПОЛЬНОГО режима, ни одного сеанса.
# По умолчанию делаем оба одним вызовом Конфигуратора, чтобы база не задерживалась
# в состоянии «основная конфигурация новая, конфигурация БД ещё старая». Если люди
# работают — днём -ТолькоЗагрузка, вечером -ТолькоОбновить.
# -Dynamic- запрещает динамическое обновление: структурные изменения должны
# применяться полноценно, иначе часть правок в базу не попадёт.
# -WarningsAsErrors не ставим — типовая конфигурация даёт предупреждения всегда.
# -Динамически (-Dynamic+) обновляет на живой базе, не выгоняя пользователей. Проходит
# только если правки не требуют реструктуризации таблиц (модули, формы, макеты, права).
# Структурные изменения платформа динамически не применит и всё равно попросит монополию —
# поэтому флаг явный, а не по умолчанию: иначе легко решить, что правка уехала, когда нет.
$режимОбновления = "-Dynamic-"
if ($Динамически) { $режимОбновления = "-Dynamic+" }

if ($ТолькоЗагрузка) {
    Запустить1С @("/LoadConfigFromFiles", $root) "Загрузка из файлов (без обновления БД)"
    Write-Host ""
    Write-Host "Конфигурация загружена. Конфигурация БД ещё СТАРАЯ — правки в базе не работают." -ForegroundColor Yellow
    Write-Host "Дообновить: apply-config.ps1 -ТолькоОбновить [-Динамически]" -ForegroundColor Yellow
} elseif ($ТолькоОбновить) {
    Запустить1С @("/UpdateDBCfg", $режимОбновления) "Обновление конфигурации БД"
    Write-Host ""
    Write-Host "Готово: конфигурация БД обновлена." -ForegroundColor Green
} else {
    Запустить1С @("/LoadConfigFromFiles", $root, "/UpdateDBCfg", $режимОбновления) "Загрузка из файлов + обновление конфигурации БД"
    Write-Host ""
    Write-Host "Готово: конфигурация загружена, база обновлена." -ForegroundColor Green
}
if ($Динамически) {
    Write-Host "Обновление было динамическим: открытые сеансы работают на старых метаданных" -ForegroundColor DarkGray
    Write-Host "до перезапуска клиента. Структурные изменения так не применяются." -ForegroundColor DarkGray
}
