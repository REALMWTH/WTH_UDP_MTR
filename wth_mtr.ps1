# 1. Auto-request administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# 2. Silent check/install of Trippy utility
if (-not (Get-Command trip -ErrorAction SilentlyContinue)) {
    Write-Host "Скачивание утилиты для диагностики..." -ForegroundColor Yellow
    winget install trippy --silent --accept-package-agreements --accept-source-agreements *> $null
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    if (Get-Command trip -ErrorAction SilentlyContinue) {
        Write-Host "[УСПЕХ] Утилита Trippy успешно установлена!" -ForegroundColor Green
    } else {
        Write-Host "[ОШИБКА] Установка не удалась. Проверьте интернет." -ForegroundColor Red
        Read-Host "Нажмите Enter для выхода..."
        exit
    }
}

# 3. Track firewall modifications
$FirewallRuleAdded = $false

# Force UTF-8 encoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

try {
    # 4. Configure Windows Defender Firewall
    if (-not (Get-NetFirewallRule -Name "ICMPv4_TRIPPY_ALLOW" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "ICMPv4 Trippy Allow" -Name "ICMPv4_TRIPPY_ALLOW" -Protocol ICMPv4 -Action Allow *> $null
        $FirewallRuleAdded = $true
    }

	Write-Host "Проверка соединения с сервером WELCOME TO HELL" -ForegroundColor Red
    Write-Host "Проверка доступности ICMP..." -ForegroundColor Yellow

    # 5. ICMP Pre-check: Try to ping Google DNS to see if ICMP is blocked locally
    # We use -Count 1 and -Quiet to get a fast boolean result
    $IcmpWorks = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet
    
    if (-not $IcmpWorks) {
        Write-Host "`n[КРИТИЧЕСКАЯ ОШИБКА] ICMP трафик заблокирован!" -ForegroundColor Red
        Write-Host "Даже после настройки брандмауэра система не может отправить/получить пакеты." -ForegroundColor Red
        Write-Host "Вероятно, ваш антивирус (Kaspersky, ESET, Avast и др.) полностью блокирует диагностику." -ForegroundColor Yellow
        Write-Host "Пожалуйста, отключите защиту на время теста и попробуйте снова." -ForegroundColor Cyan
        
        # We don't need to manually delete the rule here, 'finally' block will do it
        Read-Host "`nНажмите Enter для выхода..."
        exit
    }

    # 6. Settings and paths
    $Target = "s1.scpsl.ru"
    $Timestamp = Get-Date -f 'HH-mm-ss'
    $DesktopPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "WTH_Report_$Timestamp.txt"

    Write-Host "ICMP работает. Сбор данных запущен..." -ForegroundColor Green

    # 7. Fetch Public IP
    try {
        $UserIP = (curl.exe -s https://2ip.ru).Trim()
        "Публичный IP игрока: $UserIP`n" | Out-File -FilePath $DesktopPath -Encoding utf8
    } catch {
        "Публичный IP игрока: Не удалось определить`n" | Out-File -FilePath $DesktopPath -Encoding utf8
    }

    # 8. Execute Trippy
    & trip $Target --udp --multipath-strategy paris --source-port 5000 --target-port 7788 -m pretty -i 1s -T 2s -a both | Out-File -FilePath $DesktopPath -Encoding utf8 -Append

    if ($LASTEXITCODE -eq 0 -and (Test-Path $DesktopPath)) {
        Write-Host "`n[УСПЕХ] Отчет сохранен на Рабочий стол: WTH_Report_$Timestamp.txt" -ForegroundColor Green
    } else {
        Write-Host "`n[ОШИБКА] Тест завершился неудачно." -ForegroundColor Red
    }

    Write-Host "`nНажмите Enter, чтобы закрыть окно..." -ForegroundColor Gray
    Read-Host
}
finally {
    # 9. Cleanup: Remove the temporary firewall rule regardless of success or failure
    if ($FirewallRuleAdded) {
        Remove-NetFirewallRule -Name "ICMPv4_TRIPPY_ALLOW" -ErrorAction SilentlyContinue *> $null
    }
}