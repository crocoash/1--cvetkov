param(
  [Parameter(Mandatory = $true)][string]$Пароль,
  [string]$Пользователь = 'ТелеграмВебхук'
)

$ErrorActionPreference = 'Continue'
$log = Join-Path $PSScriptRoot 'vrd-httpservices.log'
function W([string]$m) { Add-Content -Path $log -Value $m -Encoding UTF8 }
Set-Content -Path $log -Value "=== vrd-httpservices start ===" -Encoding UTF8

# Дописывает в default.vrd публикацию HTTP-сервиса и учётные данные.
# Запускать ПОСЛЕ того, как конфигурация загружена в базу и создан пользователь.
#
# Пароль в лог не пишется. Сам default.vrd хранит его открытым текстом - так
# устроена платформа, поэтому скрипт заодно снимает у файла наследование прав,
# чтобы пароль не читался всеми пользователями терминального сервера.

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
W ("elevated: " + $isAdmin)
if (-not $isAdmin) {
  Write-Host "  Нужны права администратора - ничего не сделано." -ForegroundColor Red
  exit 1
}

$Vrd     = 'C:\inetpub\tg1c\tgbot\default.vrd'
$Site    = 'tg1c'
$Port    = 8443
$Service = 'ТелеграмВебхук'
$RootUrl = 'tg'

if (-not (Test-Path $Vrd)) { W "FATAL: нет $Vrd"; Write-Host "  Нет $Vrd" -ForegroundColor Red; exit 1 }

# --- 1. резервная копия (один раз) ------------------------------------------
if (-not (Test-Path "$Vrd.bak")) {
  Copy-Item $Vrd "$Vrd.bak" -Force
  W "бэкап: $Vrd.bak"
} else { W "бэкап: уже был" }

$xml = [System.IO.File]::ReadAllText($Vrd, [System.Text.Encoding]::UTF8)

# --- 2. учётные данные в строке соединения ----------------------------------
function XmlEsc([string]$s) {
  $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&apos;')
}

# ';' и кавычки разделяют части строки соединения - пароль с ними не доедет
# до 1С целым, а ошибка будет выглядеть как обычный 401.
if ($Пароль -match '[;"'']') {
  W "FATAL: пароль содержит ; или кавычку"
  Write-Host "  В пароле есть ; или кавычка - в строке соединения такой пароль не живёт." -ForegroundColor Red
  Write-Host "  Задайте пользователю пароль из латиницы, цифр и - _ и запустите скрипт снова." -ForegroundColor Red
  exit 1
}

$m = [regex]::Match($xml, 'ib="([^"]*)"')
if (-not $m.Success) { W "FATAL: не найден атрибут ib"; exit 1 }

# Сначала нормализуем хвост, потом вырезаем старые Usr/Pwd: шаблон ищет их
# вместе с ';', и без этого порядка последний в строке Pwd (у него ';' нет)
# не удалялся бы, а новый дописывался вторым - в vrd оставалось два пароля.
$ib = $m.Groups[1].Value
if (-not $ib.EndsWith(';')) { $ib += ';' }
$ib = [regex]::Replace($ib, '(?i)Usr=[^;]*;', '')
$ib = [regex]::Replace($ib, '(?i)Pwd=[^;]*;', '')
$ib = $ib + 'Usr=' + (XmlEsc $Пользователь) + ';Pwd=' + (XmlEsc $Пароль) + ';'
$xml = $xml.Remove($m.Groups[1].Index, $m.Groups[1].Length).Insert($m.Groups[1].Index, $ib)
W "ib: дописаны Usr и Pwd (пароль в лог не пишется)"

# --- 3. публикация HTTP-сервиса ---------------------------------------------
# Атрибутов у <httpServices> не пишем вовсе - только явную запись <service>.
# Проверено на машине 07.08.2026: с pointEnableCommon 1С отвечает 500
# «Ошибка при разборе дескриптора виртуальных ресурсов. НачалоСвойства:
# pointEnableCommon Форма: Атрибут» - схема этот атрибут у httpServices не
# принимает (у <ws> он валиден, там его пишет сам webinst). publishByDefault
# так же не проверен, поэтому не рискуем: публикацию делает <service>.
#
# Два отдельных шаблона, а не один с '(?:/>|</httpServices>)': ленивый .*?
# в парном блоке останавливался на '/>' вложенного <service .../> и оставлял
# в файле висячий </httpServices>. На первом запуске это незаметно (блока ещё
# нет), а на втором - когда меняют пароль - vrd становился невалидным XML.
$xml = [regex]::Replace($xml, '(?s)\s*<httpServices\b[^>]*>.*?</httpServices>', '')
$xml = [regex]::Replace($xml, '\s*<httpServices\b[^>]*/>', '')

$block = @"

	<httpServices>
		<service name="$Service" rootUrl="$RootUrl" enable="true"/>
	</httpServices>
"@
if ($xml -notmatch '</point>') {
  W "FATAL: в vrd нет </point> - вставлять блок некуда"
  Write-Host "  В default.vrd нет закрывающего </point>. Файл не тронут, смотрите $Vrd." -ForegroundColor Red
  exit 1
}
$xml = $xml.Replace('</point>', $block + "`r`n</point>")
W "httpServices: добавлен блок для $Service (rootUrl=$RootUrl)"

[System.IO.File]::WriteAllText($Vrd, $xml, (New-Object System.Text.UTF8Encoding $false))

# Копия vrd в лог с замазанным паролем: задание просит прислать этот файл,
# а отдавать его как есть нельзя - пароль в нём открытым текстом.
W "--- default.vrd (пароль скрыт) ---"
foreach ($l in ([regex]::Replace($xml, '(?i)Pwd=[^;"]*', 'Pwd=***') -split "`r?`n")) { W ("  " + $l) }

# --- 4. права на файл с паролем ---------------------------------------------
# SYSTEM и «Администраторы» задаём известными SID, а не именами: на английской
# ОС группы 'BUILTIN\Администраторы' не существует, правило не создавалось бы,
# а наследование при этом уже снято - файл остался бы без доступа вообще.
#
# IIS_IUSRS (S-1-5-32-568) и IUSR (S-1-5-17) обязательны. Одной учётки пула мало:
# wsisapi читает vrd под токеном веб-запроса, а не пула, и без этих двух 1С
# отвечает 500 «Ошибка при разборе дескриптора виртуальных ресурсов ...
# default.vrd: 5(0x00000005): Отказано в доступе» - поймано на живой машине
# 07.08.2026. Учётка пула в IIS_IUSRS входит, но оставляем её явно.
$rules = @()
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-568', 'S-1-5-17')) {
  $rules += New-Object System.Security.AccessControl.FileSystemAccessRule(
    (New-Object System.Security.Principal.SecurityIdentifier($sid)), 'ReadAndExecute', 'Allow')
}

# Пул читает vrd сам - без его правила публикация встанет. Если учётки пула нет
# (сайт называется иначе), наследование НЕ трогаем: пусть пароль лучше будет
# читаем, чем публикация ляжет.
$poolRule = $null
try {
  $poolRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "IIS AppPool\$Site", 'ReadAndExecute', 'Allow')
} catch { W ("ACL: не удалось создать правило для пула $Site - " + $_.Exception.Message) }

if ($poolRule) {
  $acl = Get-Acl $Vrd
  $acl.SetAccessRuleProtection($true, $false)   # снять наследование, копии не делать
  foreach ($r in ($rules + $poolRule)) { $acl.AddAccessRule($r) }
  Set-Acl -Path $Vrd -AclObject $acl
  W "ACL: наследование снято, доступ - SYSTEM, администраторы, пул $Site"
} else {
  W "ACL: пропущен, права файла остались наследованными - пароль читается всеми"
  Write-Host "  Права на default.vrd не сужены - пароль в нём читает любой пользователь сервера." -ForegroundColor Yellow
}

# --- 5. перезапуск пула и проверка ------------------------------------------
Import-Module WebAdministration -ErrorAction Stop
Restart-WebAppPool -Name $Site
W "пул $Site перезапущен"

Start-Sleep -Seconds 3

W "--- POST на вебхук ---"
$code = & curl.exe -k -s -o NUL -w "%{http_code}" --max-time 30 `
  -X POST -H "Content-Type: application/json" -d "{}" `
  "https://localhost:$Port/tgbot/hs/tg/hook" 2>&1
W ("  http_code " + $code)

W "=== done ==="

Write-Host ""
switch ("$code") {
  '403' { Write-Host "  403 - ЭТО УСПЕХ. Сервис отработал и отклонил запрос из-за пустого секрета." -ForegroundColor Green }
  '401' { Write-Host "  401 - логин/пароль не приняты. Проверьте пользователя $Пользователь и пароль." -ForegroundColor Red }
  '404' { Write-Host "  404 - сервис не опубликован либо конфигурация в базе ещё старая." -ForegroundColor Red }
  '500' { Write-Host "  500 - сервис вызвался и упал. Смотреть журнал регистрации, событие Телеграм.Вебхук." -ForegroundColor Red }
  default { Write-Host "  Ответ $code - разбираем по таблице в задании." -ForegroundColor Yellow }
}
Write-Host ""
Write-Host "  Лог: $log" -ForegroundColor Green
