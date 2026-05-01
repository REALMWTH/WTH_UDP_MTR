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

# 3. Track firewall modifications for cleanup
$FirewallRuleAdded = $false

# Configure Windows Defender Firewall (Allow ICMPv4 for Trippy)
if (-not (Get-NetFirewallRule -Name "ICMPv4_TRIPPY_ALLOW" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "ICMPv4 Trippy Allow" -Name "ICMPv4_TRIPPY_ALLOW" -Protocol ICMPv4 -Action Allow *> $null
    $FirewallRuleAdded = $true
}

# Force UTF-8 encoding for correct table borders
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Wrap execution in try-finally to ensure the firewall rule is ALWAYS removed
try {
    # 4. Settings and paths
    $Target = "s1.scpsl.ru"
    $Timestamp = Get-Date -f 'HH-mm-ss'
    $DesktopPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "WTH_Report_$Timestamp.txt"

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
    # Runs 10 cycles by default (-m pretty) and appends to the file with the IP
    & trip $Target --udp --multipath-strategy paris --source-port 5000 --target-port 7788 -m pretty -i 1s -T 2s -a both | Out-File -FilePath $DesktopPath -Encoding utf8 -Append

    # 7. Result evaluation
    if ($LASTEXITCODE -eq 0 -and (Test-Path $DesktopPath)) {
        Write-Host "`n[УСПЕХ] Отчет сохранен на Рабочий стол: WTH_Report_$Timestamp.txt" -ForegroundColor Green
        Write-Host "Передайте этот файл администратору." -ForegroundColor Gray
    } else {
        Write-Host "`n[ОШИБКА] Не удалось выполнить тест. Возможно, блокирует антивирус." -ForegroundColor Red
    }

    Write-Host "`nНажмите Enter, чтобы закрыть окно..." -ForegroundColor Gray
    Read-Host
}
finally {
    # 8. Cleanup: Remove the temporary firewall rule
    if ($FirewallRuleAdded) {
        Remove-NetFirewallRule -Name "ICMPv4_TRIPPY_ALLOW" -ErrorAction SilentlyContinue *> $null
    }
}