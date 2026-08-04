# Проверка встроенных объектов (штрихкоды) в макетах файловой выгрузки.
#
# Зачем: рисунок типа "Объект" хранится в Template.xml как base64-блоб <object>.
# Если блоб потерялся, загрузка конфигурации ИЗ ФАЙЛОВ снесёт объект и в базе —
# печать штрихкодов молча ломается (в макете вместо кода красная штриховка,
# в коде "Значение не является значением объектного типа").
#
# Запускать:
#   ПЕРЕД загрузкой конфигурации из файлов в базу — убедиться, что файлы целы;
#   ПОСЛЕ выгрузки из Конфигуратора — убедиться, что выгрузка ничего не потеряла.
#
#   powershell -File _tools\check-barcodes.ps1
#
# Код возврата: 0 — всё цело, 1 — есть проблемы.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

# Рабочий класс компоненты "1С:Печать штрихкодов" — V8.Barcod.2.
$ClsidРабочий = "44f02ecc-3c4a-4473-ad07-b0db9048ad9f"
# Старый класс V8.Barcod.1: объект создаётся, но платформа его НЕ рисует.
$ClsidМёртвый = "5c4eb2bc-9ba3-4c78-8799-8322eb1b0bea"

$проблемы = @()
$всего = 0

foreach ($файл in Get-ChildItem $root -Recurse -Filter Template.xml -File) {
    $текст = [IO.File]::ReadAllText($файл.FullName)
    $путь = $файл.FullName.Substring($root.Length + 1)

    $рисунки = [regex]::Matches($текст, '(?s)<drawing>\s*<drawingType>Object</drawingType>(.*?)</drawing>')
    foreach ($р in $рисунки) {
        $всего++
        $тело = $р.Groups[1].Value
        $id = [regex]::Match($тело, '<id>(\d+)</id>').Groups[1].Value
        $имя = [regex]::Match($текст,
            '(?s)<namedItem xsi:type="NamedItemDrawing">\s*<name>([^<]+)</name>\s*<drawingID>' + $id + '</drawingID>').Groups[1].Value

        $блоб = [regex]::Match($тело, '(?s)<object xsi:type="xs:base64Binary">(.*?)</object>')
        if (-not $блоб.Success) {
            $проблемы += "$путь : рисунок id=$id имя='$имя' — НЕТ внедрённого объекта (<object> отсутствует)"
            continue
        }

        $байты = [Convert]::FromBase64String(($блоб.Groups[1].Value -replace '\s', ''))
        # CLSID контрола лежит со смещения 19 в контейнере 1С.
        $clsid = ([Guid]::new([byte[]]$байты[19..34])).ToString()

        if ($clsid -eq $ClsidМёртвый) {
            $проблемы += "$путь : рисунок id=$id имя='$имя' — старый класс V8.Barcod.1, платформой не рисуется"
        }
        elseif ($clsid -ne $ClsidРабочий) {
            $проблемы += "$путь : рисунок id=$id имя='$имя' — неизвестный CLSID {$clsid}"
        }

        if (-not $имя) {
            $проблемы += "$путь : рисунок id=$id — БЕЗ ИМЕНИ, код обращается к рисункам по имени"
        }
    }
}

Write-Host "Проверено рисунков типа 'Объект': $всего"

if ($проблемы.Count -eq 0) {
    Write-Host "Все внедрённые объекты на месте." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "Проблемы ($($проблемы.Count)):" -ForegroundColor Red
$проблемы | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
Write-Host ""
Write-Host "Чинится копированием рабочего рисунка в Конфигураторе:" -ForegroundColor Yellow
Write-Host "  Общие макеты -> Простир_Процентовка, строка 32 колонка 2 (рисунок D1), Ctrl+C," -ForegroundColor Yellow
Write-Host "  вставить в нужный макет, задать Имя, обновить конфигурацию БД, выгрузить в файлы." -ForegroundColor Yellow
exit 1
