$ErrorActionPreference = 'Continue'
$log = Join-Path $PSScriptRoot 'setup-tgsite.log'
function W([string]$m) { Add-Content -Path $log -Value $m -Encoding UTF8 }
Set-Content -Path $log -Value "=== setup-tgsite start ===" -Encoding UTF8

# Dedicated IIS site for the 1C HTTP service HTTPServices/TelegramWebhook.
# Port 8443 on purpose: Default Web Site here serves RD Web Access on 80/443,
# and that must never be exposed to the internet. Telegram accepts 443/80/88/8443.
# Certificate is self-signed and uploaded to Telegram in setWebhook (certificate=),
# which removes both the port-80 ACME challenge and the 60-day renewal.
# Run elevated. Idempotent - safe to re-run.

$SiteName = 'tg1c'
$Port     = 8443
$Root     = 'C:\inetpub\tg1c'
$Host1    = 'tg.cvetkovtm.com'
$Ip       = '5.255.168.246'
$CertOut  = Join-Path $PSScriptRoot 'telegram-webhook.crt'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
W ("elevated: " + $isAdmin)
if (-not $isAdmin) {
  W "FATAL: not elevated, nothing done"
  Write-Host ""
  Write-Host "  Скрипт запущен БЕЗ прав администратора - ничего не сделано." -ForegroundColor Red
  Write-Host "  Нужно окно PowerShell с заголовком 'Администратор:'." -ForegroundColor Red
  Write-Host ""
  Write-Host "  Пуск -> набрать 'PowerShell' -> правой кнопкой ->" -ForegroundColor Yellow
  Write-Host "  'Запуск от имени администратора', и повторить ту же команду." -ForegroundColor Yellow
  Write-Host ""
  exit 1
}

# --- 1. folders -------------------------------------------------------------
if (-not (Test-Path $Root))            { New-Item -ItemType Directory -Path $Root            | Out-Null }
if (-not (Test-Path "$Root\tgbot"))    { New-Item -ItemType Directory -Path "$Root\tgbot"    | Out-Null }
W "folders: $Root, $Root\tgbot"

# --- 2. self-signed certificate --------------------------------------------
$existing = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$Host1" }
if ($existing) {
  $cert = $existing | Sort-Object NotAfter -Descending | Select-Object -First 1
  W ("cert: reuse existing " + $cert.Thumbprint + " until " + $cert.NotAfter)
} else {
  $cert = New-SelfSignedCertificate `
    -Subject "CN=$Host1" `
    -TextExtension @("2.5.29.17={text}DNS=$Host1&IPAddress=$Ip") `
    -KeyAlgorithm RSA -KeyLength 2048 `
    -KeyExportPolicy Exportable `
    -NotAfter (Get-Date).AddYears(10) `
    -CertStoreLocation Cert:\LocalMachine\My `
    -FriendlyName 'Telegram webhook 1C'
  W ("cert: created " + $cert.Thumbprint + " until " + $cert.NotAfter)
}

# public part in PEM - this file is uploaded to Telegram in setWebhook
$b64 = [Convert]::ToBase64String($cert.RawData, 'InsertLineBreaks')
$pem = "-----BEGIN CERTIFICATE-----`r`n" + $b64 + "`r`n-----END CERTIFICATE-----`r`n"
[System.IO.File]::WriteAllText($CertOut, $pem, (New-Object System.Text.ASCIIEncoding))
W "cert PEM -> $CertOut"

# --- 3. IIS site ------------------------------------------------------------
Import-Module WebAdministration -ErrorAction Stop

if (-not (Test-Path "IIS:\AppPools\$SiteName")) {
  New-WebAppPool -Name $SiteName | Out-Null
  W "apppool: created $SiteName"
} else { W "apppool: exists $SiteName" }
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name managedRuntimeVersion   -Value ''
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name enable32BitAppOnWin64   -Value $false
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)
W "apppool: no managed runtime, 64-bit, no idle timeout, no periodic recycle"

if (-not (Get-Website -Name $SiteName -ErrorAction SilentlyContinue)) {
  New-Website -Name $SiteName -PhysicalPath $Root -ApplicationPool $SiteName -Port $Port -Ssl -Force | Out-Null
  W "site: created $SiteName on $Port"
} else { W "site: exists $SiteName" }

$existingBinding = Get-WebBinding -Name $SiteName -Protocol https -ErrorAction SilentlyContinue
if (-not $existingBinding) {
  New-WebBinding -Name $SiteName -Protocol https -Port $Port -IPAddress '*' | Out-Null
  W "binding: added https *:$Port"
}
$sslPath = "IIS:\SslBindings\0.0.0.0!$Port"
if (Test-Path $sslPath) { Remove-Item $sslPath -Force }
New-Item $sslPath -Value $cert | Out-Null
W ("sslbinding: 0.0.0.0:$Port -> " + $cert.Thumbprint)

# --- 4. firewall: inbound 8443 only from Telegram subnets --------------------
$fwName = 'Telegram webhook 1C (8443)'
$tgRanges = @('149.154.160.0/20','91.108.4.0/22')
$r = Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue
if ($r) { Remove-NetFirewallRule -DisplayName $fwName }
New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort $Port -RemoteAddress $tgRanges -Profile Any | Out-Null
W ("firewall: allow TCP $Port from " + ($tgRanges -join ', '))

# --- 5. report --------------------------------------------------------------
W "--- sites ---"
Get-Website | ForEach-Object {
  $b = ($_.bindings.Collection | ForEach-Object { $_.protocol + ' ' + $_.bindingInformation }) -join ' | '
  W ("  " + $_.Name + " [" + $_.State + "] " + $_.PhysicalPath + " :: " + $b)
}
# Проверяем через curl.exe, а не Invoke-WebRequest: .NET Framework под PowerShell 5.1
# запрещает пересогласование TLS и падает с «Базовое соединение закрыто» там,
# где на самом деле всё исправно. 403 на пустом сайте - правильный ответ.
W "--- local probe ---"
$code = & curl.exe -k -s -o NUL -w "%{http_code}" --max-time 15 "https://localhost:$Port/" 2>&1
W ("  http_code " + $code + "  (403 на пустом сайте - норма)")

W "--- ssl binding ---"
& netsh http show sslcert ipport=0.0.0.0:$Port 2>&1 |
  Where-Object { $_ -match 'Certificate Hash|Negotiate Client Certificate|Disable TLS' } |
  ForEach-Object { W ("  " + $_.Trim()) }
W "=== done ==="
