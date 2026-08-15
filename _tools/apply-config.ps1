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
#   powershell -File _tools\apply-config.ps1 -НеЗакрывать1С  # не трогать открытые 1С на этой машине
#   powershell -File _tools\apply-config.ps1 -НеЗапускать1С  # закрыть, но обратно не запускать
#
# Параметры подключения берутся из _tools\1c-local.json (файл машинный, в git не уезжает).
# Если файла нет — скрипт сам предложит выбрать базу из зарегистрированных на машине.
#
# Важно: обновление конфигурации БД требует, чтобы в базе не было других сеансов
# (включая открытый Конфигуратор). Иначе платформа вернёт ошибку блокировки.
# Свои окна 1С (этот компьютер, этот сеанс Windows) скрипт закрывает сам и после
# работы запускает обратно; чужие сеансы на других компьютерах он не видит.

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
    [Alias("noclose")]    [switch]$НеЗакрывать1С,
    [Alias("norestart")]  [switch]$НеЗапускать1С,
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
        Запустить1СОбратно
        exit $p.ExitCode
    }
}

# --- 1С на этой машине: закрыть перед работой, запустить обратно после ------

# Обновление конфигурации БД требует монопольного режима, а загрузка из файлов —
# чтобы базу не держал Конфигуратор. Чаще всего мешает сам запускающий: открытый
# клиент или забытый Конфигуратор на этом же компьютере. Закрываем их сами, а после
# работы запускаем обратно теми же командными строками, с какими они были запущены, —
# та же база, тот же режим.
#
# Только СВОЙ сеанс Windows: машина может быть терминальным сервером, и 1cv8.exe
# чужого пользователя трогать нельзя. Конфигуратор, который запускает сам скрипт,
# в список тоже не попадает — снимок процессов делается до первого запуска.
# Серверные процессы (ragent/rphost/rmngr) не трогаются вообще.

$закрытые = @()

function НайтиПроцессы1С([bool]$ТолькоКонфигуратор) {
    $сеанс = (Get-Process -Id $PID).SessionId
    $найдено = @()
    $процессы = Get-Process -Name "1cv8", "1cv8c" -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $сеанс }
    foreach ($p in $процессы) {
        $cmd = ""
        try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)" -ErrorAction Stop).CommandLine } catch { }
        $путь = ""
        try { $путь = $p.Path } catch { }
        # DESIGNER в командной строке — надёжный признак Конфигуратора; заголовок окна
        # нужен на случай, когда командная строка недоступна.
        $конфигуратор = ($cmd -match "\bDESIGNER\b") -or ($p.MainWindowTitle -match "Конфигуратор")
        if ($ТолькоКонфигуратор -and -not $конфигуратор) { continue }
        $найдено += [pscustomobject]@{
            Процесс      = $p
            Путь         = $путь
            Команда      = $cmd
            Конфигуратор = $конфигуратор
        }
    }
    return $найдено
}

function Запустить1СОбратно {
    if ($script:закрытые.Count -eq 0) { return }
    $список = $script:закрытые
    $script:закрытые = @()
    if ($НеЗапускать1С) {
        Write-Host "1С обратно не запускаю (-НеЗапускать1С)." -ForegroundColor DarkGray
        return
    }
    Write-Host ""
    Write-Host "== Запускаю 1С обратно" -ForegroundColor Cyan
    foreach ($п in $список) {
        # То, что закрыть не удалось (пользователь отменил), уже работает — не двоить.
        if ($п.Процесс -and -not $п.Процесс.HasExited) { continue }
        if (-not $п.Путь) { continue }
        # Аргументы берём из командной строки закрытого процесса. Первый токен — путь
        # к exe, он же в $п.Путь; отрезаем его вместе с кавычками, остальное отдаём как есть,
        # без повторного разбора на слова — иначе поломаются пути с пробелами.
        $аргументы = ""
        if ($п.Команда) {
            if ($п.Команда -match '^\s*"[^"]+"\s*(.*)$') {
                $аргументы = $matches[1]
            } elseif ($п.Команда.StartsWith($п.Путь, [System.StringComparison]::OrdinalIgnoreCase)) {
                $аргументы = $п.Команда.Substring($п.Путь.Length).Trim()
            }
        }
        try {
            # Без аргументов 1С просто покажет список баз — это и есть запасной вариант,
            # если командную строку прочитать не удалось.
            if ($аргументы) {
                Start-Process -FilePath $п.Путь -ArgumentList $аргументы | Out-Null
            } else {
                Start-Process -FilePath $п.Путь | Out-Null
            }
            Write-Host ("   {0} {1}" -f (Split-Path $п.Путь -Leaf), $аргументы)
        } catch {
            Write-Host ("   Не удалось запустить {0}: {1}" -f $п.Путь, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

function Закрыть1С([bool]$ТолькоКонфигуратор) {
    if ($НеЗакрывать1С) { return }
    $список = @(НайтиПроцессы1С $ТолькоКонфигуратор)
    if ($список.Count -eq 0) { return }

    Write-Host "== Закрываю 1С на этой машине" -ForegroundColor Cyan
    foreach ($п in $список) {
        $что = "1С:Предприятие"
        if ($п.Конфигуратор) { $что = "Конфигуратор" }
        Write-Host ("   {0}  (PID {1})  {2}" -f $что, $п.Процесс.Id, $п.Процесс.MainWindowTitle)
        # CloseMainWindow — то же, что «крестик»: 1С успевает спросить про несохранённые
        # данные. Stop-Process сразу здесь не годится — в форме может висеть незаписанный
        # документ, и он потеряется молча.
        try { $п.Процесс.CloseMainWindow() | Out-Null } catch { }
    }
    $script:закрытые += $список

    while ($true) {
        $ждать = 20
        while ($ждать -gt 0) {
            Start-Sleep -Seconds 1
            $ждать--
            if (@($список | Where-Object { -not $_.Процесс.HasExited }).Count -eq 0) { break }
        }
        $остались = @($список | Where-Object { -not $_.Процесс.HasExited })
        if ($остались.Count -eq 0) { break }

        Write-Host ""
        Write-Host "1С не закрылась. Обычно на экране висит вопрос о несохранённых данных" -ForegroundColor Yellow
        Write-Host "или модальное окно — ответьте в самой 1С:" -ForegroundColor Yellow
        foreach ($п in $остались) {
            Write-Host ("   PID {0}  {1}" -f $п.Процесс.Id, $п.Процесс.MainWindowTitle) -ForegroundColor Yellow
        }
        Write-Host "Enter — проверить ещё раз, «у» — завершить принудительно (несохранённое потеряется)," -ForegroundColor Yellow
        Write-Host "«о» — отменить обновление." -ForegroundColor Yellow
        $ответ = Read-Host "Что делаем"
        if ($ответ -match "^\s*(у|y)") {
            foreach ($п in $остались) {
                try { Stop-Process -Id $п.Процесс.Id -Force -ErrorAction Stop } catch { }
            }
            Start-Sleep -Seconds 2
            break
        }
        if ($ответ -match "^\s*(о|o|н|n)") {
            Write-Host "Отменено: ничего не загружалось, конфигурация в базе прежняя." -ForegroundColor Red
            Запустить1СОбратно
            exit 1
        }
    }
    Write-Host ""
}

# --- Обратное направление: БД -> файлы -> снимок ----------------------------

if ($Выгрузить) {
    # Выгрузке мешает только занятый Конфигуратор; работающим клиентам она безразлична.
    Закрыть1С $true
    Запустить1С @("/DumpConfigToFiles", $root, "-force") "Выгрузка конфигурации в файлы"
    $шелл = (Get-Process -Id $PID).Path
    if (-not $шелл) { $шелл = "powershell" }
    & $шелл -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "snapshot.ps1") "Выгрузка конфигурации из базы"
    $код = $LASTEXITCODE
    Запустить1СОбратно
    exit $код
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

# Клиент 1С мешает только обновлению конфигурации БД (нужен монопольный режим);
# для одной загрузки из файлов достаточно, чтобы не был занят Конфигуратор. При
# -Динамически монополия не нужна, но свой клиент всё равно закрываем: иначе он
# останется работать на старых метаданных, а после перезапуска подхватит новые.
Закрыть1С ([bool]$ТолькоЗагрузка)

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

Запустить1СОбратно
