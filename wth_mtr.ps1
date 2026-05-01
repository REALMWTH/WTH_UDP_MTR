# 1. Auto-request administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# 2. Silent check/install of Trippy utility
if (-not (Get-Command trip -ErrorAction SilentlyContinue)) {
    Write-Host "Скачивание утилиты для диагностики..." -ForegroundColor Yellow
    
    # Silent install without logs
    winget install trippy --silent --accept-package-agreements --accept-source-agreements *> $null
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    if (Get-Command trip -ErrorAction SilentlyContinue) {
        Write-Host "[УСПЕХ] Утилита Trippy успешно установлена!" -ForegroundColor Green
    } else {
        Write-Host "[ОШИБКА] Установка не удалась. Убедитесь, что интернет стабилен." -ForegroundColor Red
        Write-Host "Нажмите Enter для выхода..." -ForegroundColor Gray
        Read-Host
        exit
    }
}

# 3. Configure Windows Defender Firewall
# Trippy requires incoming ICMP packets to map the route, which Windows blocks by default.
if (-not (Get-NetFirewallRule -Name "ICMPv4_TRIPPY_ALLOW" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "ICMPv4 Trippy Allow" -Name "ICMPv4_TRIPPY_ALLOW" -Protocol ICMPv4 -Action Allow *> $null
}

# 4. Settings and paths
$Target = "s1.scpsl.ru"
$Timestamp = Get-Date -f 'HH-mm-ss'
$DesktopPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "WTH_Report_$Timestamp.txt"

# Force UTF-8 encoding for correct table borders
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "`n>>> ДИАГНОСТИКА СОЕДИНЕНИЯ С СЕРВЕРОМ 'WELCOME TO HELL' <<<" -ForegroundColor Cyan
Write-Host "Сбор данных запущен. Пожалуйста, подождите..." -ForegroundColor Yellow

# 5. Fetch Public IP and write to the first line
try {
    $UserIP = (curl.exe -s https://2ip.ru).Trim()
    "Публичный IP игрока: $UserIP`n" | Out-File -FilePath $DesktopPath -Encoding utf8
} catch {
    "Публичный IP игрока: Не удалось определить`n" | Out-File -FilePath $DesktopPath -Encoding utf8
}

# 6. Execute Trippy
& trip $Target --udp --multipath-strategy paris --source-port 5000 --target-port 7788 -m pretty -i 1s -T 2s -a both | Out-File -FilePath $DesktopPath -Encoding utf8 -Append

# 7. Result evaluation
if ($LASTEXITCODE -eq 0 -and (Test-Path $DesktopPath)) {
    Write-Host "`n[УСПЕХ] Отчет сохранен на Рабочий стол: WTH_Report_$Timestamp.txt" -ForegroundColor Green
    Write-Host "Передайте этот файл администратору." -ForegroundColor Gray
} else {
    Write-Host "`n[ОШИБКА] Не удалось выполнить тест. Возможно, блокирует антивирус или файрвол." -ForegroundColor Red
}

Write-Host "`nНажмите Enter, чтобы закрыть окно..." -ForegroundColor Gray
Read-Host