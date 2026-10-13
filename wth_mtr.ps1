# 1. Auto-request administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Force UTF-8 console output
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 2. Settings and parameters
$Target = "s1.scpsl.ru"
$TargetPort = 7780
$MtrCycles = 100
$Timestamp = Get-Date -f 'yyyy-MM-dd_HH-mm-ss'
$DesktopPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "WTH_Report_$Timestamp.txt"

# 3. Resolve Target IP
try {
    $TargetIps = [System.Net.Dns]::GetHostAddresses($Target) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }
    if ($TargetIps.Count -eq 0) {
        Write-Host "[ERR] Не удалось разрешить домен $Target в IPv4 адрес." -ForegroundColor Red
        Read-Host "Нажмите Enter для выхода..."
        exit
    }
    $TargetIp = $TargetIps[0].ToString()
} catch {
    Write-Host "[ERR] Ошибка DNS при обращении к $Target : $_" -ForegroundColor Red
    Read-Host "Нажмите Enter для выхода..."
    exit
}

Clear-Host
Write-Host "==========================================================" -ForegroundColor Red
Write-Host "   ДИАГНОСТИКА СОЕДИНЕНИЯ С СЕРВЕРОМ WELCOME TO HELL" -ForegroundColor Yellow
Write-Host "   Целевой сервер: $Target ($TargetIp)" -ForegroundColor Cyan
Write-Host "   Игровой UDP порт: $TargetPort" -ForegroundColor Cyan
Write-Host "   Количество циклов MTR: $MtrCycles пакетов на каждый узел" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Red
Write-Host ""

# 4. Fetch Public IP
$DateStr = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$PublicIpText = "Публичный IP адрес: Не удалось определить"
try {
    $UserIP = (curl.exe -s --max-time 4 https://2ip.io).Trim()
    if (-not $UserIP) {
        $UserIP = (curl.exe -s --max-time 4 https://icanhazip.com).Trim()
    }
    if ($UserIP) {
        $PublicIpText = "Публичный IP адрес: $UserIP"
    }
} catch {
    # ignore
}

Write-Host "[*] $PublicIpText" -ForegroundColor Gray
Write-Host "[*] Дата и время: $DateStr" -ForegroundColor Gray
Write-Host ""

@(
    "==================== WTH CONNECTION DIAGNOSTIC REPORT ====================",
    $PublicIpText,
    "Дата и время: $DateStr",
    "Целевой сервер: $Target ($TargetIp)",
    "Игровой UDP порт: $TargetPort",
    "Пакетов на хоп: $MtrCycles",
    ""
) | Out-File -FilePath $DesktopPath -Encoding utf8

# Helper: Fast Reverse DNS (skip private/CGNAT to prevent timeouts)
function Get-FastHostName([string]$ip) {
    if ($ip -eq "???" -or [string]::IsNullOrWhiteSpace($ip)) { return "???" }
    if ($ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.|169\.254\.|198\.18\.)') {
        return $ip
    }
    try {
        $task = [System.Net.Dns]::GetHostEntryAsync($ip)
        if ($task.Wait(350)) {
            return $task.Result.HostName
        }
    } catch {}
    return $ip
}

# =========================================================================
# UDP MTR ТРАССИРОВКА МАРШРУТА (100 ЦИКЛОВ)
# =========================================================================
Write-Host "[*] Определение маршрута к серверу (трассировка хопов)..." -ForegroundColor Cyan

$ping = New-Object System.Net.NetworkInformation.Ping
$discoveredHops = [System.Collections.Generic.List[PSCustomObject]]::new()

for ($ttl = 1; $ttl -le 25; $ttl++) {
    $opt = New-Object System.Net.NetworkInformation.PingOptions($ttl, $true)
    $reply = $ping.Send($TargetIp, 800, [byte[]]@(1,2,3), $opt)
    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::TtlExpired) {
        $ipStr = $reply.Address.ToString()
        $discoveredHops.Add([PSCustomObject]@{ Hop = $ttl; Ip = $ipStr; Host = (Get-FastHostName $ipStr); IsTarget = $false })
    } elseif ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
        $ipStr = $reply.Address.ToString()
        $discoveredHops.Add([PSCustomObject]@{ Hop = $ttl; Ip = $ipStr; Host = "${Target}:${TargetPort} [Game Port]"; IsTarget = $true })
        break
    } else {
        $discoveredHops.Add([PSCustomObject]@{ Hop = $ttl; Ip = "???"; Host = "???"; IsTarget = $false })
    }
}

# Ensure the destination target is present as final hop
if ($discoveredHops.Count -gt 0 -and -not $discoveredHops[$discoveredHops.Count - 1].IsTarget) {
    $discoveredHops.Add([PSCustomObject]@{ Hop = ($discoveredHops.Count + 1); Ip = $TargetIp; Host = "${Target}:${TargetPort} [Game Port]"; IsTarget = $true })
}

$hopStats = @{}
foreach ($h in $discoveredHops) {
    $hopStats[$h.Hop] = [PSCustomObject]@{
        Hop = $h.Hop
        IP = $h.Ip
        Host = $h.Host
        IsTarget = $h.IsTarget
        Sent = 0
        Recv = 0
        Rtts = [System.Collections.Generic.List[double]]::new()
    }
}

Write-Host "[*] Запуск MTR замеров маршрута ($MtrCycles циклов по маршруту и игровому порту)..." -ForegroundColor Cyan

$udp = [System.Net.Sockets.UdpClient]::new()
$udp.Client.ReceiveTimeout = 1000
$pingPayload = [System.Text.Encoding]::ASCII.GetBytes("WTH_PING_DIAGNOSTIC_DATA")

for ($c = 1; $c -le $MtrCycles; $c++) {
    Write-Host -NoNewline ("`r  [*] Прогресс MTR: {0}%" -f $c, $MtrCycles)
    foreach ($h in $discoveredHops) {
        $st = $hopStats[$h.Hop]
        $st.Sent++
        if ($st.IsTarget) {
            # Destination hop: Probe via custom UDP packet directly to game port 7780
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $null = $udp.Send($pingPayload, $pingPayload.Length, $TargetIp, $TargetPort)
                $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                $resp = $udp.Receive([ref]$ep)
                $sw.Stop()
                if ($resp.Length -ge 8 -and [System.Text.Encoding]::ASCII.GetString($resp[0..7]) -eq "WTH_PING") {
                    $st.Recv++
                    $st.Rtts.Add([Math]::Round($sw.Elapsed.TotalMilliseconds, 1))
                }
            } catch {
                $sw.Stop()
            }
        } else {
            # Intermediate hop: Probe via TTL targeting the destination
            $opt = New-Object System.Net.NetworkInformation.PingOptions($h.Hop, $true)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $reply = $ping.Send($TargetIp, 800, [byte[]]@(1,2,3), $opt)
            $sw.Stop()
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::TtlExpired -or $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $st.Recv++
                $st.Rtts.Add([Math]::Round($sw.Elapsed.TotalMilliseconds, 1))
                if ($st.IP -eq "???") {
                    $st.IP = $reply.Address.ToString()
                    $st.Host = Get-FastHostName $st.IP
                }
            }
        }
    }
    Start-Sleep -Milliseconds 40
}
$udp.Close()
Write-Host "`r  [+] MTR замеры из $MtrCycles пакетов успешно завершены!                    " -ForegroundColor Green

# Format and write MTR table
$tableHeader = @(
    "",
    "==================== UDP ROUTE MTR TRACE (PORT $TargetPort) ====================",
    "+-----+-----------------+-------------------------------+-------+------+------+-------+-------+-------+-------+--------+",
    "| Hop | IP              | Host                          | Loss% |  Snt | Recv |  Last |   Avg |  Best |  Wrst | StdDev |",
    "+-----+-----------------+-------------------------------+-------+------+------+-------+-------+-------+-------+--------+"
)

$tableRows = [System.Collections.Generic.List[string]]::new()
foreach ($h in $discoveredHops) {
    $st = $hopStats[$h.Hop]
    $loss = if ($st.Sent -gt 0) { [Math]::Round((($st.Sent - $st.Recv) / $st.Sent) * 100, 1) } else { 0.0 }
    $last = if ($st.Rtts.Count -gt 0) { $st.Rtts[$st.Rtts.Count - 1] } else { 0.0 }
    $avg = if ($st.Rtts.Count -gt 0) { [Math]::Round(($st.Rtts | Measure-Object -Average).Average, 1) } else { 0.0 }
    $best = if ($st.Rtts.Count -gt 0) { ($st.Rtts | Measure-Object -Minimum).Minimum } else { 0.0 }
    $worst = if ($st.Rtts.Count -gt 0) { ($st.Rtts | Measure-Object -Maximum).Maximum } else { 0.0 }
    
    $stdDev = 0.0
    if ($st.Rtts.Count -gt 1) {
        $sumSq = 0.0
        foreach ($r in $st.Rtts) { $sumSq += [Math]::Pow($r - $avg, 2) }
        $stdDev = [Math]::Round([Math]::Sqrt($sumSq / ($st.Rtts.Count - 1)), 1)
    }

    $ipDisplay = if ($st.IP.Length -gt 15) { $st.IP.Substring(0, 15) } else { $st.IP }
    $hostDisplay = if ($st.Host.Length -gt 29) { $st.Host.Substring(0, 29) } else { $st.Host }

    $line = "| {0,3} | {1,-15} | {2,-29} | {3,5:F1} | {4,4} | {5,4} | {6,5:F1} | {7,5:F1} | {8,5:F1} | {9,5:F1} | {10,6:F1} |" -f `
        $st.Hop, $ipDisplay, $hostDisplay, $loss, $st.Sent, $st.Recv, $last, $avg, $best, $worst, $stdDev
    $tableRows.Add($line)
}

$tableFooter = "+-----+-----------------+-------------------------------+-------+------+------+-------+-------+-------+-------+--------+"

Write-Host ""
$tableHeader | ForEach-Object { Write-Host $_ -ForegroundColor Yellow; $_ | Out-File -FilePath $DesktopPath -Encoding utf8 -Append }
$tableRows | ForEach-Object { 
    if ($_ -like "*Game Port*") {
        Write-Host $_ -ForegroundColor Green
    } elseif ($_ -like "* 100,0 *" -or $_ -like "* 100.0 *") {
        Write-Host $_ -ForegroundColor DarkGray
    } else {
        Write-Host $_ -ForegroundColor White
    }
    $_ | Out-File -FilePath $DesktopPath -Encoding utf8 -Append
}
Write-Host $tableFooter -ForegroundColor Yellow
$tableFooter | Out-File -FilePath $DesktopPath -Encoding utf8 -Append

# =========================================================================
# АВТОМАТИЧЕСКАЯ ОЦЕНКА И ЗАКЛЮЧЕНИЕ
# =========================================================================
Write-Host ""
Write-Host "==================== ЗАКЛЮЧЕНИЕ ПО КАЧЕСТВУ СВЯЗИ ====================" -ForegroundColor Yellow

$VerdictLines = [System.Collections.Generic.List[string]]::new()
$VerdictLines.Add("")
$VerdictLines.Add("==================== ЗАКЛЮЧЕНИЕ ПО КАЧЕСТВУ СВЯЗИ ====================")

# Check target server hop
$targetHop = $null
foreach ($h in $discoveredHops) {
    if ($hopStats[$h.Hop].IsTarget) {
        $targetHop = $hopStats[$h.Hop]
        break
    }
}

if ($targetHop) {
    $tLoss = if ($targetHop.Sent -gt 0) { [Math]::Round((($targetHop.Sent - $targetHop.Recv) / $targetHop.Sent) * 100, 1) } else { 0.0 }
    if ($tLoss -eq 0 -and $targetHop.Recv -eq $targetHop.Sent) {
        $tAvg = if ($targetHop.Rtts.Count -gt 0) { [Math]::Round(($targetHop.Rtts | Measure-Object -Average).Average, 1) } else { 0.0 }
        $v1 = "[+] Игровой сервер SCP:SL отвечает стабильно (0% потерь из {0} пакетов на порту {1}, средний пинг: {2} ms)." -f $targetHop.Sent, $TargetPort, $tAvg
        Write-Host $v1 -ForegroundColor Green
        $VerdictLines.Add($v1)
    } else {
        $v1 = "[!] Внимание: На игровом порту {0} зафиксированы потери пакетов ({1}% из {2} пакетов)." -f $TargetPort, $tLoss, $targetHop.Sent
        Write-Host $v1 -ForegroundColor Red
        $VerdictLines.Add($v1)
    }
}

# Check hop 1 (home router/Wi-Fi)
$hop1 = $hopStats[1]
if ($hop1 -and $hop1.Rtts.Count -gt 0) {
    $hop1Avg = ($hop1.Rtts | Measure-Object -Average).Average
    if ($hop1Avg -gt 10.0) {
        $vWifi = "[!] Высокая задержка до домашнего роутера ({0} ms). Если используется Wi-Fi, рекомендуется подключить кабель Ethernet." -f $hop1Avg
        Write-Host $vWifi -ForegroundColor Yellow
        $VerdictLines.Add($vWifi)
    }
}

$VerdictLines | Out-File -FilePath $DesktopPath -Encoding utf8 -Append

if (Test-Path $DesktopPath) {
    Write-Host ""
    Write-Host "[OK] Диагностика успешно завершена!" -ForegroundColor Green
    Write-Host "Отчёт сохранён на рабочий стол: $DesktopPath" -ForegroundColor Yellow
    Write-Host "Отправьте этот файл администраторам для анализа проблемы с соединением." -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "[ERR] Что-то пошло не так при сохранении отчёта." -ForegroundColor Red
}

Write-Host ""
Write-Host "Нажмите Enter, чтобы закрыть окно..." -ForegroundColor Gray
Read-Host