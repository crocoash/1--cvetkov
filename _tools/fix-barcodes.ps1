# Восстановление встроенных объектов штрихкода в макетах файловой выгрузки.
#
# Проблема: "Выгрузка конфигурации в файлы" выборочно НЕ записывает base64-блоб
# <object> для рисунков типа "Объект" — рисунок в Template.xml остаётся, объект
# пропадает. Обратная загрузка такого файла сносит штрихкод и в базе.
#
# Скрипт дописывает эталонный объект (V8.Barcod.2 из _tools\barcode-object.xml)
# во все рисунки типа "Объект", у которых блоб потерялся.
#
# Запускать ПОСЛЕ каждой выгрузки конфигурации в файлы, ДО загрузки обратно:
#   powershell -File _tools\fix-barcodes.ps1            # только показать, что будет сделано
#   powershell -File _tools\fix-barcodes.ps1 -Применить # записать изменения
#
# ВАЖНО про формат: строки продолжения base64 обязаны идти с нулевой позиции.
# Любой добавленный отступ внутри блока даёт при загрузке "Ошибка формата потока".

param(
    [switch]$Применить,
    # Дополнительно заменить объекты старого класса V8.Barcod.1 (он не рисуется).
    # По умолчанию не трогаем — это меняет поведение чужих печатных форм.
    [switch]$ЗаменитьСтарыйКласс
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$эталонФайл = Join-Path $PSScriptRoot "barcode-object.xml"
if (-not (Test-Path $эталонФайл)) {
    Write-Host "Нет эталона $эталонФайл — восстанавливать нечем." -ForegroundColor Red
    exit 1
}
$эталон = [IO.File]::ReadAllText($эталонФайл)

$ClsidМёртвый = "5c4eb2bc-9ba3-4c78-8799-8322eb1b0bea"
$исправлено = @()

# Выгрузка теряет не только блоб объекта, но и имя рисунка (namedItem).
# Код обращается к рисункам по имени, поэтому имя надо возвращать тоже.
# Таблица: путь макета в выгрузке -> имя, под которым его знает код.
$ИменаОбъектов = @{
    "CommonTemplates\Простир_Процентовка\Ext\Template.xml" = "D1"          # ОбластьПодвал.Рисунки.D1
    "CommonTemplates\Этикетка\Ext\Template.xml"            = "ШтрихКод"
    "CommonTemplates\ЭтикеткаБольшая\Ext\Template.xml"     = "ШтрихКод"
    "DataProcessors\ПечатьЭтикеток\Templates\Макет\Ext\Template.xml" = "Штрихкод"
    "DataProcessors\ПечатьЭтикеток\Templates\Процентовка\Ext\Template.xml" = "D1"   # ОбластьПодвал.Рисунки.D1
}

foreach ($файл in Get-ChildItem $root -Recurse -Filter Template.xml -File) {
    $текст = [IO.File]::ReadAllText($файл.FullName)
    $путь = $файл.FullName.Substring($root.Length + 1).Replace([IO.Path]::DirectorySeparatorChar, '\')
    $изменён = $false

    # Рисунки типа "Объект" без блоба: дописываем эталон после <zOrder>.
    $безОбъекта = '(?s)(<drawing>\s*<drawingType>Object</drawingType>(?:(?!</drawing>).)*?)([ \t]*)(<zOrder>\d+</zOrder>)(\s*</drawing>)'
    while ($true) {
        $m = [regex]::Match($текст, $безОбъекта)
        if (-not $m.Success) { break }
        $id = [regex]::Match($m.Groups[1].Value, '<id>(\d+)</id>').Groups[1].Value
        $текст = $текст.Remove($m.Index, $m.Length).Insert($m.Index,
            $m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value +
            "`r`n" + $m.Groups[2].Value + $эталон + $m.Groups[4].Value)
        $исправлено += "$путь : рисунок id=$id — объект восстановлен"
        $изменён = $true
    }

    # Рисунки типа "Объект" без namedItem: возвращаем имя из таблицы.
    $имяМакета = $ИменаОбъектов[$путь]
    if ($имяМакета) {
        foreach ($р in [regex]::Matches($текст, '(?s)<drawing>\s*<drawingType>Object</drawingType>(.*?)</drawing>')) {
            $id = [regex]::Match($р.Groups[1].Value, '<id>(\d+)</id>').Groups[1].Value
            if (-not $id) { continue }
            $естьИмя = [regex]::IsMatch($текст,
                '(?s)<namedItem xsi:type="NamedItemDrawing">\s*<name>[^<]*</name>\s*<drawingID>' + $id + '</drawingID>')
            if ($естьИмя) { continue }

            # Вставляем рядом с остальными namedItem — после последнего из них.
            $последний = [regex]::Matches($текст, '</namedItem>') | Select-Object -Last 1
            if (-not $последний) { continue }
            $блок = "`r`n`t<namedItem xsi:type=`"NamedItemDrawing`">`r`n`t`t<name>$имяМакета</name>`r`n" +
                    "`t`t<drawingID>$id</drawingID>`r`n`t</namedItem>"
            $вставка = $последний.Index + $последний.Length
            $текст = $текст.Insert($вставка, $блок)
            $исправлено += "$путь : рисунок id=$id — восстановлено имя '$имяМакета'"
            $изменён = $true
        }
    }

    if ($ЗаменитьСтарыйКласс) {
        foreach ($m in [regex]::Matches($текст, '(?s)<object xsi:type="xs:base64Binary">(.*?)</object>')) {
            $байты = [Convert]::FromBase64String(($m.Groups[1].Value -replace '\s', ''))
            if (([Guid]::new([byte[]]$байты[19..34])).ToString() -eq $ClsidМёртвый) {
                $текст = $текст.Replace($m.Value, $эталон)
                $исправлено += "$путь : объект старого класса V8.Barcod.1 заменён на V8.Barcod.2"
                $изменён = $true
            }
        }
    }

    if ($изменён -and $Применить) {
        [IO.File]::WriteAllText($файл.FullName, $текст, (New-Object Text.UTF8Encoding $true))
        # Контроль: файл обязан остаться валидным XML.
        $x = New-Object Xml.XmlDocument
        $x.Load($файл.FullName)
    }
}

if ($исправлено.Count -eq 0) {
    Write-Host "Все внедрённые объекты на месте — восстанавливать нечего." -ForegroundColor Green
    exit 0
}

$исправлено | ForEach-Object { Write-Host "  $_" }
Write-Host ""
if ($Применить) {
    Write-Host "Записано изменений: $($исправлено.Count). XML проверен." -ForegroundColor Green
} else {
    Write-Host "Это предпросмотр. Для записи: powershell -File _tools\fix-barcodes.ps1 -Применить" -ForegroundColor Yellow
}
