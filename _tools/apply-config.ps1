# Пакетная загрузка конфигурации из файлов и обновление базы. Запускать НА МАШИНЕ С 1С.
# Заменяет ручные шаги: git pull -> Конфигуратор -> «Загрузить конфигурацию из файлов» -> F7.
#
# Использование (Windows):
#   powershell -File _tools\apply-config.ps1 -Настроить      # выбрать базу из списка и сохранить настройки
#   powershell -File _tools\apply-config.ps1                # pull + загрузка + обновление БД
#   powershell -File _tools\apply-config.ps1 -СРезервной     # плюс выгрузка базы в .dt перед загрузкой
#   powershell -File _tools\apply-config.ps1 -БезРезервной   # запретить .dt даже для файловой базы
#   powershell -File _tools\apply-config.ps1 -ТолькоЗагрузка  # только загрузка из файлов (можно при людях)
#   powershell -File _tools\apply-config.ps1 -ТолькоОбновить  # только обновление БД
#   powershell -File _tools\apply-config.ps1 -Динамически     # только динамически: не выгонять никого ни при каких условиях
#   powershell -File _tools\apply-config.ps1 -Монопольно      # сразу полноценно, без попытки обновить динамически
#   powershell -File _tools\apply-config.ps1 -БезPull        # загрузить то, что уже лежит в папке
#   powershell -File _tools\apply-config.ps1 -Выгрузить      # обратное направление: БД -> файлы -> снимок
#   powershell -File _tools\apply-config.ps1 -НеЗакрывать1С  # не трогать открытые 1С на этой машине
#   powershell -File _tools\apply-config.ps1 -НеЗапускать1С  # закрыть, но обратно не запускать
#   powershell -File _tools\apply-config.ps1 -ВыгнатьВсех    # завершить и чужие сеансы, а не только фоновые
#   powershell -File _tools\apply-config.ps1 -НеТрогатьЗадания # не блокировать регламентные задания
#
# Параметры подключения берутся из _tools\1c-local.json (файл машинный, в git не уезжает).
# Если файла нет — скрипт сам предложит выбрать базу из зарегистрированных на машине.
#
# Главное правило: никого не беспокоим, пока платформа не скажет, что иначе никак.
#
# Обновление идёт «по возможности динамически» (-Dynamic+). Если правки неструктурные —
# модули, формы, макеты, права — база обновляется на ходу, люди работают дальше, вопросов
# не задаётся вовсе (правку они увидят после перезапуска своего клиента). Если правки
# структурные — новый реквизит, новый объект метаданных — платформа откажет и потребует
# монопольный режим. Вот тогда скрипт смотрит, кто в базе:
#   только фоновые задания — глушит их сам и повторяет обновление молча;
#   работают люди         — показывает их и спрашивает «выгнать?». На «д» запрещает начало
#                           сеансов, завершает все текущие и доделывает обновление тем же
#                           запуском (загрузку из файлов не повторяет, она уже прошла).
#
# Свои окна 1С (этот компьютер, этот сеанс Windows) скрипт закрывает сам и после работы
# запускает обратно. Чужие сеансы завершаются только через агент кластера, поэтому на
# машине должен быть зарегистрирован COM-соединитель (regsvr32 comcntr.dll от админа);
# без него скрипт скажет об этом прямо в консоли.
#
# Ключи меняют умолчание в обе стороны: -Динамически = не выгонять никого ни при каких
# условиях, -Монопольно / -ВыгнатьВсех = сразу монопольно, без попытки обновить динамически.
# Без человека за консолью (перенаправленный ввод, планировщик) вопрос не задаётся.

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
    [Alias("mono")]       [switch]$Монопольно,
    [Alias("dump")]       [switch]$Выгрузить,
    [Alias("noclose")]    [switch]$НеЗакрывать1С,
    [Alias("norestart")]  [switch]$НеЗапускать1С,
    [Alias("kickall")]    [switch]$ВыгнатьВсех,
    [Alias("nojobs")]     [switch]$НеТрогатьЗадания,
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
        # Администратор кластера: обычно не заведён, тогда пустые строки и подходят.
        # Если в консоли кластера заведён — вписать сюда, иначе скрипт не сможет
        # блокировать регламентные задания перед монопольным обновлением.
        АдминКластера  = ""
        ПарольКластера = ""
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

# $ПовторАргументы — что запустить повторно, если шаг упёрся в занятую базу и
# пользователь согласился выгнать сеансы. Для «загрузка + обновление» это только
# обновление: загрузка к этому моменту уже прошла, повторять её незачем (минуты).
function Запустить1С([string[]]$Аргументы, [string]$Что, [string[]]$ПовторАргументы, [string]$ПовторЧто) {
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

            # Сюда попадаем, когда динамическое обновление не прошло: правки структурные,
            # платформе нужна монополия. Освобождаем базу и доделываем тем же запуском —
            # молча, если мешают только фоновые задания, и с вопросом, если работают люди.
            if ($ПовторАргументы -and (ОсвободитьБазуДляПовтора)) {
                Запустить1С $ПовторАргументы $ПовторЧто
                return
            }

            if (-not $ТолькоОбновить) {
                Write-Host "Загрузка из файлов уже прошла — повторять её не нужно. Когда база освободится:" -ForegroundColor Yellow
                Write-Host "  apply-config.ps1 -ТолькоОбновить      (или пункт 4 в меню)" -ForegroundColor Yellow
            }
            # Если в списке выше одни «Фоновое задание» — ждать бесполезно, они
            # перезапускаются по расписанию; помогает запрет заданий и завершение сеансов.
            Write-Host "Выгнать всех и обновить без вопросов:" -ForegroundColor Yellow
            Write-Host "  apply-config.ps1 -ТолькоОбновить -ВыгнатьВсех   (пункт 8)" -ForegroundColor Yellow
        }
        ВернутьБлокировки
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

# --- Серверная база: кто мешает монопольному режиму -------------------------

# Обновление конфигурации БД идёт только когда в базе нет ни одного сеанса. Мешают
# здесь в первую очередь ФОНОВЫЕ ЗАДАНИЯ: они стартуют по расписанию сами, поэтому
# «подождать, пока все выйдут» не работает — пока ждёшь, запускается очередное.
# Лечится блокировкой регламентных заданий на уровне информационной базы (та же
# галка, что в консоли администрирования кластера); после обновления снимаем.
#
# Работаем через COM-соединитель V83.COMConnector: он ставится вместе с клиентом 1С
# и не требует запущенной службы ras (в отличие от rac.exe). Если соединителя нет
# или агент недоступен — не падаем, а печатаем, что сделать руками.
#
# Клиентские сеансы людей по умолчанию не трогаем: -ВыгнатьВсех включает запрет
# начала сеансов и завершение чужих сеансов, и только с подтверждением.

$script:агентКластера        = $null
$script:кластерБазы          = $null
$script:описаниеБазы         = $null
$script:блокировкиПоставлены = $false
$script:былиЗаданияЗапрещены = $false
$script:кодРазрешения        = "applycfg"

function ПодключитьсяККластеру {
    if ($script:агентКластера) { return $true }
    if (-not $нст.СервернаяБаза) { return $false }

    $части = $нст.СервернаяБаза -split '\\'
    if ($части.Count -lt 2) {
        Write-Host "Не разобрать имя серверной базы: $($нст.СервернаяБаза)" -ForegroundColor Yellow
        return $false
    }
    $сервер  = $части[0]
    $имяБазы = $части[1]

    $соединитель = $null
    foreach ($progid in @("V83.COMConnector", "V83.COMConnector.1")) {
        if ($соединитель) { continue }
        try { $соединитель = New-Object -ComObject $progid } catch { }
    }
    if (-not $соединитель) {
        Write-Host "COM-соединитель V83.COMConnector на этой машине не зарегистрирован —" -ForegroundColor Yellow
        Write-Host "регламентные задания сам заблокировать не могу." -ForegroundColor Yellow
        return $false
    }

    $админ  = ""
    $парольАдмина = ""
    if ($нст.АдминКластера)  { $админ = $нст.АдминКластера }
    if ($нст.ПарольКластера) { $парольАдмина = $нст.ПарольКластера }
    $пользовательБазы = ""
    $парольБазы = ""
    if ($нст.Пользователь) { $пользовательБазы = $нст.Пользователь }
    if ($нст.Пароль)       { $парольБазы = $нст.Пароль }

    try {
        $агент = $соединитель.ConnectAgent($сервер)
        foreach ($кластер in $агент.GetClusters()) {
            $агент.Authenticate($кластер, $админ, $парольАдмина)
            # Аутентификация администратора ИБ нужна, чтобы видеть сеансы и менять свойства базы.
            $агент.AddAuthentication($пользовательБазы, $парольБазы)
            foreach ($иб in $агент.GetInfoBases($кластер)) {
                if ($иб.Name -eq $имяБазы) {
                    $script:агентКластера = $агент
                    $script:кластерБазы   = $кластер
                    $script:описаниеБазы  = $иб
                    return $true
                }
            }
        }
        Write-Host "База «$имяБазы» не найдена в кластерах сервера $сервер." -ForegroundColor Yellow
    } catch {
        Write-Host ("Не удалось подключиться к агенту сервера {0}: {1}" -f $сервер, $_.Exception.Message) -ForegroundColor Yellow
        # «Библиотека не зарегистрирована» (0x8002801D) — comcntr.dll не прописан в реестре.
        # Лечится один раз regsvr32 от администратора; разрядность должна совпадать с
        # разрядностью PowerShell, иначе объект создастся, а библиотека не найдётся.
        if ($_.Exception.Message -match "не зарегистрирована|LIBNOTREGISTERED|0x8002801D") {
            $dll = Join-Path (Split-Path $exe -Parent) "comcntr.dll"
            Write-Host "COM-соединитель не зарегистрирован. Один раз, в PowerShell ОТ АДМИНИСТРАТОРА:" -ForegroundColor Yellow
            Write-Host ("   regsvr32 ""{0}""" -f $dll) -ForegroundColor Yellow
            Write-Host ("   (PowerShell сейчас {0}-битный — dll нужна той же разрядности)" -f $(if ([Environment]::Is64BitProcess) { "64" } else { "32" })) -ForegroundColor Yellow
        }
    }
    return $false
}

function ПоказатьСеансы($Сеансы) {
    foreach ($с in $Сеансы) {
        Write-Host ("      сеанс {0,-6} {1,-16} {2,-18} {3}" -f $с.SessionID, $с.AppID, $с.Host, $с.UserName) -ForegroundColor DarkGray
    }
}

# Спрашивать можно только у живого человека за консолью. Запуск из планировщика или
# с перенаправленным вводом Read-Host не переживёт: вернёт пустую строку или повиснет.
function МожноСпрашивать {
    if (-not [Environment]::UserInteractive) { return $false }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { }
    return $true
}

# Выгнать людей можно только на серверной базе: сеансы завершает агент кластера.
# У файловой базы кластера нет, там сеанс — это чужой запущенный 1cv8.exe.
function МожноВыгонять {
    if ($НеТрогатьЗадания)      { return $false }
    if (-not $нст.СервернаяБаза) { return $false }
    return (МожноСпрашивать)
}

# При запрете начала сеансов Конфигуратор и сам не пустят в базу без кода разрешения.
function ДобавитьКодРазрешения {
    if ($script:общие -contains "/UC") { return }
    $script:общие += @("/UC", $script:кодРазрешения)
}

# Запрет новых сеансов + завершение всех текущих. Возвращает $true, если база пуста.
function ВыгнатьВсехИзБазы {
    if (-not $нст.СервернаяБаза) {
        Write-Host "База файловая: сеансы завершать нечем, закройте 1С у работающих." -ForegroundColor Yellow
        return $false
    }
    if (-not (ПодключитьсяККластеру)) { return $false }

    $агент   = $script:агентКластера
    $кластер = $script:кластерБазы
    $иб      = $script:описаниеБазы

    Write-Host "== Выгоняю всех из базы" -ForegroundColor Cyan
    try {
        # Запрет ставим ДО завершения сеансов, иначе выгнанные тут же зайдут обратно
        # (клиент 1С переподключается сам) и монопольный режим снова не наступит.
        if (-not $script:блокировкиПоставлены) {
            $script:былиЗаданияЗапрещены = [bool]$иб.ScheduledJobsDenied
        }
        $иб.ScheduledJobsDenied = $true
        $иб.SessionsDenied      = $true
        $иб.PermissionCode      = $script:кодРазрешения
        $иб.DeniedMessage       = "База закрыта на обновление конфигурации. Зайдите через несколько минут."
        $иб.DeniedFrom          = (Get-Date).AddMinutes(-1)
        $иб.DeniedTo            = (Get-Date).AddMinutes(30)
        $агент.UpdateInfoBase($кластер, $иб)
        $script:блокировкиПоставлены = $true
        ДобавитьКодРазрешения
    } catch {
        Write-Host ("   не удалось запретить начало сеансов: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
    Write-Host "   начало сеансов запрещено, код разрешения: $($script:кодРазрешения)" -ForegroundColor DarkGray

    # Пара заходов: платформа завершает сеанс не мгновенно, а какой-нибудь фоновый
    # мог стартовать между запретом и завершением.
    for ($заход = 1; $заход -le 3; $заход++) {
        $сеансы = @($агент.GetInfoBaseSessions($кластер, $иб))
        if ($сеансы.Count -eq 0) { break }
        Write-Host ("   завершаю сеансы ({0}):" -f $сеансы.Count) -ForegroundColor DarkGray
        ПоказатьСеансы $сеансы
        foreach ($с in $сеансы) {
            try { $агент.TerminateSession($кластер, $с) } catch {
                Write-Host ("      сеанс {0} завершить не удалось: {1}" -f $с.SessionID, $_.Exception.Message) -ForegroundColor Yellow
            }
        }
        Start-Sleep -Seconds 5
    }

    $осталось = @($агент.GetInfoBaseSessions($кластер, $иб))
    if ($осталось.Count -gt 0) {
        Write-Host "   часть сеансов завершить не удалось:" -ForegroundColor Yellow
        ПоказатьСеансы $осталось
        Write-Host "   обновление всё равно попробую — но может снова упереться в блокировку." -ForegroundColor Yellow
        Write-Host ""
        return $true
    }
    Write-Host "   база пуста" -ForegroundColor DarkGray
    Write-Host ""
    return $true
}

# Вызывается уже ПОСЛЕ отказа платформы: динамически правки не применились, нужна
# монополия. Здесь и решается, беспокоить ли кого-нибудь: фоновые задания снимаем
# молча (они перезапустятся сами), про живых людей спрашиваем.
$script:былаЭскалация = $false
function ОсвободитьБазуДляПовтора {
    if ($НеТрогатьЗадания) { return $false }
    if (-not $нст.СервернаяБаза) {
        Write-Host ""
        Write-Host "База файловая: завершить чужие сеансы нечем — закройте 1С у работающих." -ForegroundColor Yellow
        return $false
    }
    if (-not (ПодключитьсяККластеру)) { return $false }

    $сеансы = @()
    try {
        $сеансы = @($script:агентКластера.GetInfoBaseSessions($script:кластерБазы, $script:описаниеБазы))
    } catch {
        Write-Host ("Не удалось получить список сеансов: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
    $люди = @($сеансы | Where-Object { $_.AppID -ne "BackgroundJob" })

    if ($люди.Count -eq 0) {
        Write-Host ""
        Write-Host "В базе только фоновые задания — снимаю их и повторяю обновление." -ForegroundColor Cyan
    } else {
        Write-Host ""
        Write-Host "Правки структурные: динамически они не применяются, базу нужно освободить." -ForegroundColor Yellow
        Write-Host "Сейчас в базе работают:" -ForegroundColor Yellow
        ПоказатьСеансы $люди
        if (-not (МожноСпрашивать)) { return $false }
        Write-Host "Завершить эти сеансы и доделать обновление? Несохранённые данные у них потеряются." -ForegroundColor Yellow
        $ответ = Read-Host "«д» — выгнать и обновить, Enter — не трогать"
        if ($ответ -notmatch "^\s*(д|d|y)") { return $false }
    }

    $script:былаЭскалация = $true
    $вышло = ВыгнатьВсехИзБазы
    if (-not $вышло) { Write-Host "Освободить базу не получилось — причина выше." -ForegroundColor Red }
    return $вышло
}

function ОсвободитьБазу {
    if ($НеТрогатьЗадания) { return }
    if (-not $нст.СервернаяБаза) { return }   # файловой базе кластер не нужен

    if (-not (ПодключитьсяККластеру)) {
        Write-Host "Если обновление упрётся в блокировку — снимите нагрузку руками: консоль" -ForegroundColor Yellow
        Write-Host "администрирования кластера, свойства ИБ, «Блокировка регламентных заданий»." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    $агент   = $script:агентКластера
    $кластер = $script:кластерБазы
    $иб      = $script:описаниеБазы

    Write-Host "== Освобождаю базу перед монопольным обновлением" -ForegroundColor Cyan
    try {
        # Запомним исходное состояние: если задания были заблокированы до нас
        # (кем-то намеренно или упавшим прошлым запуском) — вернём как было.
        $script:былиЗаданияЗапрещены = [bool]$иб.ScheduledJobsDenied
        if ($script:былиЗаданияЗапрещены) {
            Write-Host "   регламентные задания были заблокированы ещё до запуска — так и оставлю после" -ForegroundColor Yellow
        }
        $иб.ScheduledJobsDenied = $true
        if ($ВыгнатьВсех) {
            $иб.SessionsDenied  = $true
            $иб.PermissionCode  = $script:кодРазрешения
            $иб.DeniedMessage   = "База закрыта на обновление конфигурации. Зайдите через несколько минут."
            # Срок с запасом: если скрипт прервать, запрет сеансов истечёт сам.
            $иб.DeniedFrom      = (Get-Date).AddMinutes(-1)
            $иб.DeniedTo        = (Get-Date).AddMinutes(30)
            ДобавитьКодРазрешения
        }
        $агент.UpdateInfoBase($кластер, $иб)
        $script:блокировкиПоставлены = $true
    } catch {
        Write-Host ("   не удалось поставить блокировку: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host ""
        return
    }

    Write-Host "   регламентные задания заблокированы (новые фоновые не стартуют)" -ForegroundColor DarkGray
    if ($ВыгнатьВсех) {
        Write-Host "   начало сеансов запрещено, код разрешения: $($script:кодРазрешения)" -ForegroundColor DarkGray
    }
    Write-Host "   если прервать скрипт сейчас — снять блокировку в консоли кластера!" -ForegroundColor DarkGray

    # Блокировка не останавливает уже запущенные задания — даём им доработать.
    $срок = 90
    while ($срок -gt 0) {
        $сеансы = @($агент.GetInfoBaseSessions($кластер, $иб))
        if ($сеансы.Count -eq 0) { break }
        Write-Host ("   в базе ещё {0} сеанс(ов), жду до {1} с..." -f $сеансы.Count, $срок) -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
        $срок = $срок - 5
    }

    $сеансы = @($агент.GetInfoBaseSessions($кластер, $иб))
    if ($сеансы.Count -eq 0) {
        Write-Host "   база пуста" -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    # Фоновое задание завершить безопасно: транзакция откатится, задание перезапустится
    # по расписанию после снятия блокировки. Живые сеансы людей — только по -ВыгнатьВсех.
    $задания = @($сеансы | Where-Object { $_.AppID -eq "BackgroundJob" })
    $люди    = @($сеансы | Where-Object { $_.AppID -ne "BackgroundJob" })

    if ($задания.Count -gt 0) {
        Write-Host "   завершаю сеансы фоновых заданий:" -ForegroundColor DarkGray
        ПоказатьСеансы $задания
        foreach ($с in $задания) {
            try { $агент.TerminateSession($кластер, $с) } catch {
                Write-Host ("      сеанс {0} завершить не удалось: {1}" -f $с.SessionID, $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    }

    if ($люди.Count -gt 0) {
        Write-Host "   в базе работают не только задания:" -ForegroundColor Yellow
        ПоказатьСеансы $люди
        # С -ВыгнатьВсех согласие уже дано ключом (пункт 8 меню) — второй раз не спрашиваем.
        # Без ключа спрашиваем здесь: монопольное обновление при этих сеансах не пройдёт,
        # и лучше решить это до запуска Конфигуратора, чем после ошибки блокировки.
        $выгонять = [bool]$ВыгнатьВсех
        if (-not $выгонять -and (МожноВыгонять)) {
            Write-Host "   Обновление конфигурации БД при этих сеансах не пройдёт." -ForegroundColor Yellow
            Write-Host "   Завершить их? Несохранённые данные у людей потеряются." -ForegroundColor Yellow
            $ответ = Read-Host "   «д» — выгнать и обновить, Enter — попробовать так"
            $выгонять = $ответ -match "^\s*(д|d|y)"
        }
        if ($выгонять) {
            ВыгнатьВсехИзБазы | Out-Null
        } else {
            Write-Host "   их не трогаю — обновление может не пройти. Выгнать всех:" -ForegroundColor Yellow
            Write-Host "   apply-config.ps1 -ТолькоОбновить -ВыгнатьВсех   (пункт 8 в меню)" -ForegroundColor Yellow
        }
    }
    Start-Sleep -Seconds 3
    Write-Host ""
}

function ВернутьБлокировки {
    if (-not $script:блокировкиПоставлены) { return }
    $script:блокировкиПоставлены = $false
    try {
        $script:описаниеБазы.ScheduledJobsDenied = $script:былиЗаданияЗапрещены
        $script:описаниеБазы.SessionsDenied      = $false
        $script:агентКластера.UpdateInfoBase($script:кластерБазы, $script:описаниеБазы)
        if ($script:былиЗаданияЗапрещены) {
            Write-Host "== Запрет сеансов снят; блокировку регламентных заданий оставил как было" -ForegroundColor Cyan
        } else {
            Write-Host "== Блокировки сняты: регламентные задания снова работают" -ForegroundColor Cyan
        }
    } catch {
        Write-Host ("ВНИМАНИЕ: не удалось снять блокировку: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host "Снимите её в консоли кластера: свойства ИБ -> блокировка регламентных заданий" -ForegroundColor Red
        Write-Host "и блокировка начала сеансов. Иначе регламентные задания стоят молча." -ForegroundColor Red
    }
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

# Копия «Обновить базу.cmd» на рабочем столе живёт своей жизнью: git pull правит файл
# в _tools, а двойным кликом запускают копию — и меню в ней остаётся старым, хотя сам
# скрипт уже новый (он берётся из репозитория). Внешне это выглядит как «залил, а пункты
# те же». Свежая копия — тонкий запускатель, она сразу передаёт управление в _tools,
# так что достаточно один раз её обновить.
#
# Перезаписать копию, которой запущены прямо сейчас, нельзя: cmd.exe читает .bat по мере
# выполнения и после подмены файла продолжит с прежнего смещения — остаток разберётся
# в мусор. Поэтому: если запущены не ею — обновляем молча, если ею — просим сделать руками.
function ПроверитьКопииЗапускателя {
    $эталон = Join-Path $PSScriptRoot "Обновить базу.cmd"
    if (-not (Test-Path $эталон)) { return }

    $строкиЗапуска = ""
    $ид = $PID
    for ($шаг = 0; $шаг -lt 5 -and $ид; $шаг++) {
        $проц = $null
        try { $проц = Get-CimInstance Win32_Process -Filter "ProcessId = $ид" -ErrorAction Stop } catch { }
        if (-not $проц) { break }
        if ($проц.CommandLine) { $строкиЗапуска += $проц.CommandLine + "`n" }
        $ид = $проц.ParentProcessId
    }

    $папки = @()
    foreach ($имя in @("Desktop", "CommonDesktopDirectory")) {
        try { $папки += [Environment]::GetFolderPath($имя) } catch { }
    }
    $папки += (Join-Path $env:USERPROFILE "Desktop")

    foreach ($папка in ($папки | Where-Object { $_ } | Select-Object -Unique)) {
        $копия = Join-Path $папка "Обновить базу.cmd"
        if (-not (Test-Path $копия)) { continue }
        # Сверяем не побайтно, а по признаку «копия передаёт управление в _tools»:
        # такая копия показывает свежее меню независимо от своего возраста, и ругаться
        # на неё после каждой правки пунктов было бы ложной тревогой.
        $текстКопии = ""
        try {
            $текстКопии = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($копия))
        } catch { continue }
        if ($текстКопии.Contains('call "%REPO%\')) { continue }

        $этойИЗапущены = $строкиЗапуска.IndexOf($копия, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        if (-not $этойИЗапущены) {
            try {
                Copy-Item $эталон $копия -Force
                Write-Host "== Обновил запускатель на рабочем столе: $копия" -ForegroundColor Cyan
                Write-Host ""
                continue
            } catch {
                Write-Host ("Не удалось обновить {0}: {1}" -f $копия, $_.Exception.Message) -ForegroundColor Yellow
            }
        }
        Write-Host ""
        Write-Host "ВНИМАНИЕ: меню, из которого запущено, — старая копия:" -ForegroundColor Yellow
        Write-Host "   $копия" -ForegroundColor Yellow
        Write-Host "Скрипт при этом новый, но пункты меню в копии остались прежними." -ForegroundColor Yellow
        Write-Host "Обновить её (один раз, дальше она будет открывать меню из _tools):" -ForegroundColor Yellow
        Write-Host "   закрыть это окно и выполнить в командной строке" -ForegroundColor Yellow
        Write-Host ("   copy /y ""{0}"" ""{1}""" -f $эталон, $копия) -ForegroundColor Yellow
        Write-Host ""
    }
}
ПроверитьКопииЗапускателя

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
# -WarningsAsErrors не ставим — типовая конфигурация даёт предупреждения всегда.
#
# Режим обновления по умолчанию — -Dynamic+ («по возможности динамически»), и это
# главное правило скрипта: никого не трогаем, пока платформа не скажет, что иначе никак.
#   правки неструктурные (модули, формы, макеты, права) — обновление проходит на живой
#     базе, люди работают дальше, вопросов не задаётся вовсе;
#   правки структурные (новый реквизит, новый объект) — платформа откажет и попросит
#     монополию, и только тогда скрипт спрашивает про выгон и повторяет уже -Dynamic-.
# Ключи меняют умолчание в обе стороны: -Динамически = «только динамически, не выгонять
# ни при каких условиях», -Монопольно / -ВыгнатьВсех = «сразу полноценно, без попытки».
$режимОбновления = "-Dynamic+"
if ($Монопольно -or $ВыгнатьВсех) { $режимОбновления = "-Dynamic-" }

# Повтор после освобождения базы — всегда полноценный: раз динамически не вышло,
# пробовать то же самое второй раз бессмысленно.
$повторОбновления = @("/UpdateDBCfg", "-Dynamic-")
$повторЧто        = "Обновление конфигурации БД (база освобождена)"
# С -Динамически повторять нечего: договорились никого не трогать.
if ($Динамически) { $повторОбновления = $null }

# Заранее освобождаем базу только когда монополия запрошена явно. В остальных случаях
# сначала пробуем по-хорошему: фоновые задания и людей трогаем уже по факту отказа.
if (-not $ТолькоЗагрузка -and ($Монопольно -or $ВыгнатьВсех)) { ОсвободитьБазу }

if ($ТолькоЗагрузка) {
    Запустить1С @("/LoadConfigFromFiles", $root) "Загрузка из файлов (без обновления БД)"
    Write-Host ""
    Write-Host "Конфигурация загружена. Конфигурация БД ещё СТАРАЯ — правки в базе не работают." -ForegroundColor Yellow
    Write-Host "Дообновить: apply-config.ps1 -ТолькоОбновить" -ForegroundColor Yellow
} elseif ($ТолькоОбновить) {
    Запустить1С @("/UpdateDBCfg", $режимОбновления) "Обновление конфигурации БД" `
                $повторОбновления $повторЧто
    Write-Host ""
    Write-Host "Готово: конфигурация БД обновлена." -ForegroundColor Green
} else {
    # Повтор — только обновление: загрузка из файлов к моменту отказа уже прошла.
    Запустить1С @("/LoadConfigFromFiles", $root, "/UpdateDBCfg", $режимОбновления) "Загрузка из файлов + обновление конфигурации БД" `
                $повторОбновления $повторЧто
    Write-Host ""
    Write-Host "Готово: конфигурация загружена, база обновлена." -ForegroundColor Green
}
# Если базу освобождать не пришлось — обновление прошло динамически, и это стоит сказать:
# открытые сеансы доработают на старых метаданных, правку в них увидят после перезапуска.
if ($режимОбновления -eq "-Dynamic+" -and -not $script:былаЭскалация) {
    Write-Host "Никого выгонять не понадобилось: обновление прошло динамически." -ForegroundColor DarkGray
    Write-Host "Открытые сеансы работают на старых метаданных до перезапуска клиента." -ForegroundColor DarkGray
}

ВернутьБлокировки
Запустить1СОбратно
