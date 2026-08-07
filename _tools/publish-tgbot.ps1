$ErrorActionPreference = 'Continue'
$log = Join-Path $PSScriptRoot 'publish-tgbot.log'
function W([string]$m) { Add-Content -Path $log -Value $m -Encoding UTF8 }
Set-Content -Path $log -Value "=== publish-tgbot start ===" -Encoding UTF8

# Публикация HTTPСервис.ТелеграмВебхук в сайт tg1c:8443, созданный setup-tgsite.ps1.
# Запускать от администратора. Идемпотентен.
#
# Учётные данные (Usr/Pwd) в default.vrd НЕ пишутся: пользователя ТелеграмВебхук
# ещё нет в базе. Пока их нет, правильный ответ сервиса - 401, и это уже
# доказывает, что модуль загрузился и добрался до 1С.

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
W ("elevated: " + $isAdmin)
if (-not $isAdmin) {
  Write-Host ""
  Write-Host "  Скрипт запущен БЕЗ прав администратора - ничего не сделано." -ForegroundColor Red
  Write-Host "  Нужно окно PowerShell с заголовком 'Администратор:'." -ForegroundColor Red
  Write-Host ""
  exit 1
}

$Bin      = 'C:\Program Files\1cv8\8.3.25.1374\bin'
$Isapi    = Join-Path $Bin 'wsisapi.dll'
$WebInst  = Join-Path $Bin 'webinst.exe'
$Site     = 'tg1c'
$AppName  = 'tgbot'
$Dir      = 'C:\inetpub\tg1c\tgbot'
$Port     = 8443
$ConnStr  = 'Srvr="c-db01srv";Ref="work";'

if (-not (Test-Path $Isapi)) {
  W "FATAL: нет $Isapi"
  Write-Host "  Нет $Isapi - публиковать нечем." -ForegroundColor Red
  exit 1
}
W ("isapi: " + (Get-Item $Isapi).VersionInfo.FileVersion)

Import-Module WebAdministration -ErrorAction Stop

# --- 1. разрешить ISAPI-модуль на уровне сервера ----------------------------
# Без этого IIS отдаёт 404.4 даже при полностью правильной публикации.
$flt = "/system.webServer/security/isapiCgiRestriction/add[@path='$Isapi']"
$cur = Get-WebConfiguration -Filter $flt -PSPath 'IIS:\' -ErrorAction SilentlyContinue
if ($null -eq $cur) {
  Add-WebConfiguration -Filter '/system.webServer/security/isapiCgiRestriction' -PSPath 'IIS:\' `
    -Value @{ path = $Isapi; allowed = $true; description = '1C Enterprise 8.3 Web Service Extension' }
  W "isapiCgiRestriction: добавлено, allowed=true"
} else {
  Set-WebConfigurationProperty -Filter $flt -PSPath 'IIS:\' -Name allowed -Value $true
  W "isapiCgiRestriction: уже было, allowed=true"
}

# --- 2. сгенерировать default.vrd / web.config ------------------------------
if (Test-Path $WebInst) {
  W "webinst: найден, публикуем штатной утилитой"
  $out = & $WebInst -publish -iis -wsdir $AppName -dir $Dir -connstr $ConnStr 2>&1
  foreach ($l in $out) { W ("  " + $l) }

  # webinst создаёт приложение в Default Web Site (выбора сайта у него нет).
  # Нам это приложение там не нужно - на том сайте RDWeb, наружу он не идёт.
  # Файлы в $Dir оставляем, само приложение убираем.
  $stray = Get-WebApplication -Site 'Default Web Site' -Name $AppName -ErrorAction SilentlyContinue
  if ($stray) {
    Remove-WebApplication -Site 'Default Web Site' -Name $AppName
    W "убрано лишнее приложение /$AppName из Default Web Site"
  }
} else {
  W "webinst: НЕ найден - пишем default.vrd вручную"
}

if (-not (Test-Path (Join-Path $Dir 'default.vrd'))) {
  $vrd = @"
<?xml version="1.0" encoding="UTF-8"?>
<point xmlns="http://v8.1c.ru/8.2/virtual-resource-system"
		xmlns:xs="http://www.w3.org/2001/XMLSchema"
		xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
		base="/$AppName"
		ib="Srvr=&quot;c-db01srv&quot;;Ref=&quot;work&quot;;">
	<httpServices publishByDefault="true"/>
</point>
"@
  [System.IO.File]::WriteAllText((Join-Path $Dir 'default.vrd'), $vrd, (New-Object System.Text.UTF8Encoding $false))
  W "default.vrd: написан вручную (publishByDefault, HTTP-сервис в конфигурации один)"
} else {
  W "default.vrd: на месте"
}

if (-not (Test-Path (Join-Path $Dir 'web.config'))) {
  $wc = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
	<system.webServer>
		<handlers>
			<add name="1C Web-service Extension" path="*" verb="*" modules="IsapiModule"
			     scriptProcessor="$Isapi" resourceType="Unspecified" requireAccess="None" />
		</handlers>
	</system.webServer>
</configuration>
"@
  [System.IO.File]::WriteAllText((Join-Path $Dir 'web.config'), $wc, (New-Object System.Text.UTF8Encoding $false))
  W "web.config: написан вручную"
} else {
  W "web.config: на месте"
}

# --- 3. разблокировать секцию handlers для нашего сайта ----------------------
# По умолчанию system.webServer/handlers заблокирована, и web.config с обработчиком
# даёт 500.19. Разблокируем точечно для tg1c, а не для всего сервера.
Set-WebConfiguration -Filter '/system.webServer/handlers' -PSPath 'IIS:\' -Location $Site `
  -Metadata overrideMode -Value Allow
W "handlers: overrideMode=Allow для сайта $Site"

# --- 4. приложение /tgbot в сайте tg1c --------------------------------------
$app = Get-WebApplication -Site $Site -Name $AppName -ErrorAction SilentlyContinue
if (-not $app) {
  New-WebApplication -Site $Site -Name $AppName -PhysicalPath $Dir -ApplicationPool $Site -Force | Out-Null
  W "приложение: создано /$AppName в сайте $Site"
} else {
  W "приложение: уже есть /$AppName"
}

# --- 5. права пула на каталог публикации ------------------------------------
$acl = Get-Acl $Dir
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
  "IIS AppPool\$Site", 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.SetAccessRule($rule)
Set-Acl -Path $Dir -AclObject $acl
W "ACL: IIS AppPool\$Site -> ReadAndExecute на $Dir"

# --- 6. проверка -------------------------------------------------------------
W "--- файлы публикации ---"
Get-ChildItem $Dir | ForEach-Object { W ("  " + $_.Name + "  " + $_.Length) }

W "--- POST на вебхук (ожидается 401: Usr/Pwd в vrd ещё нет) ---"
$code = & curl.exe -k -s -o NUL -w "%{http_code}" --max-time 30 `
  -X POST -H "Content-Type: application/json" -d "{}" `
  "https://localhost:$Port/$AppName/hs/tg/hook" 2>&1
W ("  http_code " + $code)

W "--- RDWeb не задет? (ожидается 200 или 3xx) ---"
$rd = & curl.exe -k -s -o NUL -w "%{http_code}" --max-time 20 "https://localhost/RDWeb/Pages/" 2>&1
W ("  RDWeb http_code " + $rd)

W "=== done ==="
Write-Host ""
Write-Host "  Готово. Лог: $log" -ForegroundColor Green
Get-Content $log | Select-Object -Last 12
