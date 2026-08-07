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

$m = [regex]::Match($xml, 'ib="([^"]*)"')
if (-not $m.Success) { W "FATAL: не найден атрибут ib"; exit 1 }

$ib = $m.Groups[1].Value
$ib = [regex]::Replace($ib, '(?i)Usr=[^;]*;', '')
$ib = [regex]::Replace($ib, '(?i)Pwd=[^;]*;', '')
if (-not $ib.EndsWith(';')) { $ib += ';' }
$ib = $ib + 'Usr=' + (XmlEsc $Пользователь) + ';Pwd=' + (XmlEsc $Пароль) + ';'
$xml = $xml.Remove($m.Groups[1].Index, $m.Groups[1].Length).Insert($m.Groups[1].Index, $ib)
W "ib: дописаны Usr и Pwd (пароль в лог не пишется)"

# --- 3. публикация HTTP-сервиса ---------------------------------------------
# Ставим и общий флаг, и явную запись о сервисе: если один из вариантов схемы
# окажется неверным, второй должен отработать.
$xml = [regex]::Replace($xml, '(?s)\s*<httpServices.*?(?:/>|</httpServices>)', '')

$block = @"

	<httpServices pointEnableCommon="true">
		<service name="$Service" rootUrl="$RootUrl" enable="true"/>
	</httpServices>
"@
$xml = $xml.Replace('</point>', $block + "`r`n</point>")
W "httpServices: добавлен блок для $Service (rootUrl=$RootUrl)"

[System.IO.File]::WriteAllText($Vrd, $xml, (New-Object System.Text.UTF8Encoding $false))

# --- 4. права на файл с паролем ---------------------------------------------
$acl = Get-Acl $Vrd
$acl.SetAccessRuleProtection($true, $false)   # снять наследование, копии не делать
foreach ($id in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Администраторы', "IIS AppPool\$Site")) {
  try {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
      $id, 'ReadAndExecute', 'Allow')))
  } catch { W ("ACL: не удалось добавить $id - " + $_.Exception.Message) }
}
Set-Acl -Path $Vrd -AclObject $acl
W "ACL: наследование снято, доступ - SYSTEM, администраторы, пул $Site"

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
