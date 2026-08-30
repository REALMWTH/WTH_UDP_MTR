# 1. Auto-request administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# 2. Silent check/install of WinGet (if missing)
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "[!] WinGet не найден. Устанавливаю..." -ForegroundColor Yellow
    try {
        $WinGetUrl = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
        $WinGetInstaller = Join-Path $env:TEMP "WinGet.msixbundle"
        Invoke-WebRequest -Uri $WinGetUrl -OutFile $WinGetInstaller -UseBasicParsing
        Add-AppxPackage -Path $WinGetInstaller -ErrorAction Stop
        Remove-Item $WinGetInstaller -Force -ErrorAction SilentlyContinue
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "[OK] WinGet успешно установлен!" -ForegroundColor Green
        } else {
            Write-Host "[ERR] WinGet не удалось установить. Установите вручную: https://aka.ms/getwinget" -ForegroundColor Red
            Read-Host "Нажмите Enter для выхода..."
            exit
        }
    } catch {
        Write-Host "[ERR] Ошибка при установке WinGet: $_" -ForegroundColor Red
        Write-Host "Установите вручную: https://aka.ms/getwinget" -ForegroundColor Yellow
        Read-Host "Нажмите Enter для выхода..."
        exit
    }
}

# 3. Silent check/install of Trippy utility
if (-not (Get-Command trip -ErrorAction SilentlyContinue)) {
    Write-Host "Установка утилиты Trippy..." -ForegroundColor Yellow
    winget install trippy --silent --accept-package-agreements --accept-source-agreements *> $null
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    if (Get-Command trip -ErrorAction SilentlyContinue) {
        Write-Host "[OK] Утилита Trippy успешно установлена!" -ForegroundColor Green
    } else {
        Write-Host "[ERR] Установка не удалась. Проверьте интернет." -ForegroundColor Red
        Read-Host "Нажмите Enter для выхода..."
        exit
    }
}

# 4. Track firewall modifications
$FirewallRuleAdded = $false

# Force UTF-8 encoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

try {
    # 5. Configure Windows Defender Firewall
    if (-not (Get-NetFirewallRule -Name "ICMPv4_TRIPPY_ALLOW" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "ICMPv4 Trippy Allow" -Name "ICMPv4_TRIPPY_ALLOW" -Protocol ICMPv4 -Action Allow *> $null
        $FirewallRuleAdded = $true
    }

	Write-Host "Проверка соединения с сервером WELCOME TO HELL" -ForegroundColor Red
    Write-Host "Проверка доступности ICMP..." -ForegroundColor Yellow

    # 6. ICMP Pre-check: Try to ping Google DNS to see if ICMP is blocked locally
    # We use -Count 1 and -Quiet to get a fast boolean result
    $IcmpWorks = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet
    
    if (-not $IcmpWorks) {
        Write-Host "`n[ВНИМАНИЕ] ICMP трафик заблокирован!" -ForegroundColor Red
        Write-Host "Скорее всего ваш брандмауэр или антивирус блокирует ICMP трафик." -ForegroundColor Red
        Write-Host "Возможно, ваш антивирус (Kaspersky, ESET, Avast и др.) блокирует этот протокол." -ForegroundColor Yellow
        Write-Host "Попробуйте отключить его на время и запустить снова." -ForegroundColor Cyan
        
        # We don't need to manually delete the rule here, 'finally' block will do it
        Read-Host "`nНажмите Enter для выхода..."
        exit
    }

    # 7. Settings and paths
    $Target = "s1.scpsl.ru"
    $Timestamp = Get-Date -f 'HH-mm-ss'
    $DesktopPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "WTH_Report_$Timestamp.txt"

    Write-Host "ICMP работает. Идёт сбор данных..." -ForegroundColor Green

    # 8. Fetch Public IP
    try {
        $UserIP = (curl.exe -s https://2ip.io).Trim()
        "Публичный IP адрес: $UserIP`n" | Out-File -FilePath $DesktopPath -Encoding utf8
    } catch {
        "Публичный IP адрес: Не удалось определить`n" | Out-File -FilePath $DesktopPath -Encoding utf8
    }

    # 9. Execute Trippy
    & trip $Target --udp --multipath-strategy paris --source-port 5000 --target-port 7788 -m pretty -i 1s -T 2s -a both | Out-File -FilePath $DesktopPath -Encoding utf8 -Append

    if ($LASTEXITCODE -eq 0 -and (Test-Path $DesktopPath)) {
        Write-Host "`n[OK] Отчёт сохранён на рабочий стол: WTH_Report_$Timestamp.txt" -ForegroundColor Green
    } else {
        Write-Host "`n[ERR] Что-то пошло не так." -ForegroundColor Red
    }

    Write-Host "`nНажмите Enter, чтобы закрыть окно..." -ForegroundColor Gray
    Read-Host
}
finally {
    # 10. Cleanup: Remove the temporary firewall rule regardless of success or failure
    if ($FirewallRuleAdded) {
        Remove-NetFirewallRule -Name "ICMPv4_TRIPPY_ALLOW" -ErrorAction SilentlyContinue *> $null
    }
}