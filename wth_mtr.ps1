# 1. Авто-запрос прав администратора
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# 2. Тихая проверка/установка утилиты Trippy
if (-not (Get-Command trip -ErrorAction SilentlyContinue)) {
    Write-Host "Скачивание утилиты для диагностики..." -ForegroundColor Yellow
    
    # Скрытая установка без логов
    winget install trippy --silent --accept-package-agreements --accept-source-agreements *> $null
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    if (Get-Command trip -ErrorAction SilentlyContinue) {
        Write-Host "[УСПЕХ] Утилита Trippy успешно установлена!" -ForegroundColor Green
    } else {
        Write-Host "[ОШИБКА] Установка не удалась. Убедитесь, что интернет-соединение стабильно." -ForegroundColor Red
        Write-Host "Нажмите Enter для выхода..." -ForegroundColor Gray
        Read-Host
        exit
    }
}

# 3. Настройки и пути
$Target = "s1.scpsl.ru"
$Timestamp = Get-Date -f 'HH-mm-ss'
$DesktopPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "WTH_Report_$Timestamp.txt"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# ---------------------------------------------------------

Write-Host "`n>>> ДИАГНОСТИКА СОЕДИНЕНИЯ С СЕРВЕРОМ 'WELCOME TO HELL' <<<" -ForegroundColor Cyan
Write-Host "Сбор данных запущен. Пожалуйста, подождите..." -ForegroundColor Yellow

# 4. Запуск
& trip $Target --udp --multipath-strategy paris --source-port 5000 --target-port 7788 -m pretty -i 1s -T 2s -a both | Out-File -FilePath $DesktopPath -Encoding utf8

# 5. Результат
if ($LASTEXITCODE -eq 0 -and (Test-Path $DesktopPath)) {
    Write-Host "`n[УСПЕХ] Отчет сохранен на Рабочий стол: WTH_Report_$Timestamp.txt" -ForegroundColor Green
    Write-Host "Передайте этот файл администратору." -ForegroundColor Gray
} else {
    Write-Host "`n[ОШИБКА] Не удалось выполнить тест. Убедитесь, что антивирус не блокирует работу." -ForegroundColor Red
}

Write-Host "`nНажмите Enter, чтобы закрыть окно..." -ForegroundColor Gray
Read-Host