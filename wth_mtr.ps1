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
$MtrCycles = 20
$Timestamp = Get-Date -f 'yyyy-MM-dd_HH-mm-ss'
$DesktopPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "WTH_Report_$Timestamp.txt"

# 3. Compile High-Speed Parallel MTR Engine (Compatible with PS 5.1 and PS 7+)
if (-not ("WthMtrEngine" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

public class HopProbeResult {
    public int Hop;
    public bool Success;
    public string Address;
    public double RttMs;
}

public static class WthMtrEngine {
    private static readonly byte[] Payload = new byte[] { 1, 2, 3 };
    private static readonly Regex PrivateIpRegex = new Regex(
        @"^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.|169\.254\.|198\.18\.)",
        RegexOptions.Compiled);

    static WthMtrEngine() {
        int minWorker, minIocp;
        ThreadPool.GetMinThreads(out minWorker, out minIocp);
        if (minWorker < 64) {
            ThreadPool.SetMinThreads(64, Math.Max(minIocp, 64));
        }
    }

    public static HopProbeResult ProbeHopCustom(string targetIp, string hopIp, int hopNum, bool direct, int timeoutMs) {
        HopProbeResult res = new HopProbeResult { Hop = hopNum, Success = false, Address = hopIp, RttMs = 0.0 };
        if (timeoutMs <= 0) return res;

        try {
            using (Ping p = new Ping()) {
                Stopwatch sw = Stopwatch.StartNew();
                PingReply reply;
                if (direct) {
                    PingOptions opt = new PingOptions(64, true);
                    reply = p.Send(hopIp, timeoutMs, Payload, opt);
                } else {
                    PingOptions opt = new PingOptions(hopNum, true);
                    reply = p.Send(targetIp, timeoutMs, Payload, opt);
                }
                sw.Stop();
                if (reply != null && (reply.Status == IPStatus.Success || reply.Status == IPStatus.TtlExpired)) {
                    res.Success = true;
                    if (reply.Address != null) res.Address = reply.Address.ToString();
                    res.RttMs = Math.Round(sw.Elapsed.TotalMilliseconds, 1);
                }
            }
        } catch {}
        return res;
    }

    public static HopProbeResult ProbeSingleHop(string targetIp, int ttl, int timeoutMs) {
        HopProbeResult res = new HopProbeResult { Hop = ttl, Success = false, Address = "???", RttMs = 0.0 };
        if (timeoutMs <= 0) return res;

        try {
            using (Ping p = new Ping()) {
                PingOptions opt = new PingOptions(ttl, true);
                Stopwatch sw = Stopwatch.StartNew();
                PingReply reply = p.Send(targetIp, timeoutMs, Payload, opt);
                sw.Stop();
                if (reply != null && (reply.Status == IPStatus.TtlExpired || reply.Status == IPStatus.Success)) {
                    res.Success = true;
                    res.Address = reply.Address != null ? reply.Address.ToString() : "???";
                    res.RttMs = Math.Round(sw.Elapsed.TotalMilliseconds, 1);
                }
            }
        } catch {}
        return res;
    }

    public static HopProbeResult[] ProbeHopsParallel(string targetIp, int[] ttls, int[] timeouts) {
        int n = ttls.Length;
        Task<HopProbeResult>[] tasks = new Task<HopProbeResult>[n];
        for (int i = 0; i < n; i++) {
            int idx = i;
            tasks[i] = Task.Run(() => ProbeSingleHop(targetIp, ttls[idx], timeouts[idx]));
        }
        Task.WaitAll(tasks);
        HopProbeResult[] results = new HopProbeResult[n];
        for (int i = 0; i < n; i++) {
            results[i] = tasks[i].Result;
        }
        return results;
    }

    public static string ResolveFastHostName(string ip, int timeoutMs) {
        if (string.IsNullOrWhiteSpace(ip) || ip == "???") return "???";
        if (PrivateIpRegex.IsMatch(ip)) return ip;
        try {
            Task<IPHostEntry> t = Dns.GetHostEntryAsync(ip);
            if (t.Wait(timeoutMs) && t.Result != null && !string.IsNullOrEmpty(t.Result.HostName)) {
                return t.Result.HostName;
            }
        } catch {}
        return ip;
    }

    public static string[] ResolveHostsParallel(string[] ips, int timeoutMs) {
        int n = ips.Length;
        Task<string>[] tasks = new Task<string>[n];
        for (int i = 0; i < n; i++) {
            string currentIp = ips[i];
            tasks[i] = Task.Run(() => ResolveFastHostName(currentIp, timeoutMs));
        }
        Task.WaitAll(tasks);
        string[] results = new string[n];
        for (int i = 0; i < n; i++) {
            results[i] = tasks[i].Result;
        }
        return results;
    }
}
"@
}

# 4. Resolve Target IP
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

# 5. Fetch Public IP
$DateStr = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$PublicIpText = "Публичный IP адрес: Не удалось определить"
try {
    $UserIP = (curl.exe -s --max-time 3 https://2ip.io).Trim()
    if (-not $UserIP) {
        $UserIP = (curl.exe -s --max-time 3 https://icanhazip.com).Trim()
    }
    if ($UserIP) {
        $PublicIpText = "Публичный IP адрес: $UserIP"
    }
} catch {}

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

# =========================================================================
# ПАРАЛЛЕЛЬНОЕ ОПРЕДЕЛЕНИЕ МАРШРУТА К СЕРВЕРУ (~0.5 СЕК ВМЕСТО 15 СЕК)
# =========================================================================
Write-Host "[*] Определение маршрута к серверу (параллельная трассировка хопов)..." -ForegroundColor Cyan

$maxHops = 25
$ttlsToDiscover = 1..$maxHops
$discoverTimeouts = @(for ($i = 0; $i -lt $maxHops; $i++) { 350 })

# Одновременный опрос всех 25 TTL
$rawDiscovery = [WthMtrEngine]::ProbeHopsParallel($TargetIp, [int[]]$ttlsToDiscover, [int[]]$discoverTimeouts)

$discoveredHops = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($res in $rawDiscovery) {
    if ($res.Success) {
        if ($res.Address -eq $TargetIp) {
            $discoveredHops.Add([PSCustomObject]@{ Hop = $res.Hop; Ip = $res.Address; Host = "${Target}:${TargetPort} [Game Port]"; IsTarget = $true })
            break
        } else {
            $discoveredHops.Add([PSCustomObject]@{ Hop = $res.Hop; Ip = $res.Address; Host = $res.Address; IsTarget = $false })
        }
    } else {
        $discoveredHops.Add([PSCustomObject]@{ Hop = $res.Hop; Ip = "???"; Host = "???"; IsTarget = $false })
    }
}

# Удаляем хвостовые пустые хопы (???), так как сервер защищен и не отвечает на ICMP Echo
while ($discoveredHops.Count -gt 0 -and $discoveredHops[$discoveredHops.Count - 1].Ip -eq "???") {
    $discoveredHops.RemoveAt($discoveredHops.Count - 1)
}

# Параллельный Reverse DNS для всех найденных узлов сразу (~300 мс на все хопы)
if ($discoveredHops.Count -gt 0) {
    $ipArray = [string[]]@($discoveredHops | ForEach-Object { $_.Ip })
    $resolvedHosts = [WthMtrEngine]::ResolveHostsParallel($ipArray, 300)
    for ($i = 0; $i -lt $discoveredHops.Count; $i++) {
        if (-not $discoveredHops[$i].IsTarget) {
            $discoveredHops[$i].Host = $resolvedHosts[$i]
        }
    }
}

# Определение узлов, отвечающих на прямой Echo Request (как в WinMTR / ping)
foreach ($h in $discoveredHops) {
    $canDirect = $false
    if (-not $h.IsTarget -and $h.Ip -ne "???") {
        $check = [WthMtrEngine]::ProbeHopCustom($TargetIp, $h.Ip, $h.Hop, $true, 150)
        $canDirect = $check.Success
    }
    $h | Add-Member -NotePropertyName "DirectPing" -NotePropertyValue $canDirect
}

# Добавляем игровой порт сразу следующим хопом после последнего ответившего узла
if ($discoveredHops.Count -eq 0 -or -not $discoveredHops[$discoveredHops.Count - 1].IsTarget) {
    $nextHopNum = if ($discoveredHops.Count -gt 0) { $discoveredHops[$discoveredHops.Count - 1].Hop + 1 } else { 1 }
    $discoveredHops.Add([PSCustomObject]@{ Hop = $nextHopNum; Ip = $TargetIp; Host = "${Target}:${TargetPort} [Game Port]"; IsTarget = $true })
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

Write-Host "[*] Маршрут определен ($($discoveredHops.Count) хопов)." -ForegroundColor Green
Write-Host "[*] Запуск параллельных MTR замеров ($MtrCycles циклов по маршруту и игровому порту)..." -ForegroundColor Cyan

# Подготовка UDP-сокета и полезной нагрузки
$pingPayload = [System.Text.Encoding]::ASCII.GetBytes("WTH_PING_DIAGNOSTIC_DATA")
$udp = [System.Net.Sockets.UdpClient]::new()
$udp.Client.ReceiveTimeout = 350
try {
    $udp.Connect($TargetIp, $TargetPort)
} catch {}

# Холостой прогрев UDP-сокета и JIT-компиляции
try {
    $null = $udp.Send($pingPayload, $pingPayload.Length)
    $warmupEp = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
    $null = $udp.Receive([ref]$warmupEp)
} catch {}

$ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
$sw = New-Object System.Diagnostics.Stopwatch

# Отделяем список промежуточных ICMP-хопов от финального UDP-хопа
$intermediateHops = @($discoveredHops | Where-Object { -not $_.IsTarget })
$targetHopObj = $discoveredHops | Where-Object { $_.IsTarget } | Select-Object -First 1

# =========================================================================
# ЦИКЛ MTR ЗАМЕРОВ (ГИБРИДНЫЙ ДЕСИНХРОНИЗИРОВАННЫЙ ОПРОС)
# =========================================================================
for ($c = 1; $c -le $MtrCycles; $c++) {
    $pct = [Math]::Round(($c / $MtrCycles) * 100)
    Write-Host -NoNewline ("`r  [*] Прогресс MTR: {0}% ({1}/{2})" -f $pct, $c, $MtrCycles)

    # 1. Опрос промежуточных хопов магистрали (1..N-1)
    foreach ($h in $intermediateHops) {
        $st = $hopStats[$h.Hop]
        $st.Sent++

        if ($st.IP -eq "???" -and $st.Sent -gt 3 -and $st.Recv -eq 0) {
            continue
        }

        $timeout = if ($st.IP -eq "???") { 100 } else { 400 }
        $res = [WthMtrEngine]::ProbeHopCustom($TargetIp, $h.Ip, $h.Hop, $h.DirectPing, $timeout)
        if ($res.Success) {
            $st.Recv++
            $st.Rtts.Add($res.RttMs)
            if ($st.IP -eq "???" -and $res.Address -ne "???") {
                $st.IP = $res.Address
                $st.Host = [WthMtrEngine]::ResolveFastHostName($st.IP, 200)
            }
        }
        [System.Threading.Thread]::Sleep(20) # Десинхронизация: защищает роутеры от одновременных залпов
    }

    # 2. Опрос игрового UDP-порта сервера
    if ($null -ne $targetHopObj) {
        $tStat = $hopStats[$targetHopObj.Hop]
        $tStat.Sent++

        while ($udp.Available -gt 0) {
            try { $null = $udp.Receive([ref]$ep) } catch { break }
        }

        $sw.Restart()
        try {
            $null = $udp.Send($pingPayload, $pingPayload.Length)
            $resp = $udp.Receive([ref]$ep)
            $sw.Stop()
            if ($resp.Length -ge 8 -and [System.Text.Encoding]::ASCII.GetString($resp[0..7]) -eq "WTH_PING") {
                $tStat.Recv++
                $tStat.Rtts.Add([Math]::Round($sw.Elapsed.TotalMilliseconds, 1))
            }
        } catch {
            $sw.Stop()
        }
    }

    Start-Sleep -Milliseconds 350
}


$udp.Close()
Write-Host "`r  [+] MTR замеры из $MtrCycles пакетов успешно завершены!                    " -ForegroundColor Green

# =========================================================================
# ВЫВОД И ФОРМАТИРОВАНИЕ ТАБЛИЦЫ РЕЗУЛЬТАТОВ
# =========================================================================
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

        # Проверяем наличие единичных сбросов на транзитных роутерах при нулевых потерях на игре
        $hasIntermediateDrops = $false
        foreach ($h in $discoveredHops) {
            if (-not $h.IsTarget) {
                $st = $hopStats[$h.Hop]
                if ($st.IP -ne "???" -and $st.Sent -gt 0) {
                    $loss = [Math]::Round((($st.Sent - $st.Recv) / $st.Sent) * 100, 1)
                    if ($loss -gt 0 -and $loss -le 25) {
                        $hasIntermediateDrops = $true
                        break
                    }
                }
            }
        }
        if ($hasIntermediateDrops) {
            $VerdictLines.Add($vCopp)
        }
    } else {
        $v1 = "[!] Внимание: На игровом порту {0} зафиксированы потери пакетов ({1}% из {2} пакетов)." -f $TargetPort, $tLoss, $targetHop.Sent
        Write-Host $v1 -ForegroundColor Red
        $VerdictLines.Add($v1)
    }
}

$hop1 = $hopStats[1]
if ($hop1 -and $hop1.Rtts.Count -gt 0) {
    $hop1Avg = ($hop1.Rtts | Measure-Object -Average).Average
    if ($hop1Avg -gt 10.0) {
        $vWifi = "[!] Высокая задержка до домашнего роутера ({0:F1} ms). Если используется Wi-Fi, рекомендуется подключить кабель Ethernet." -f $hop1Avg
        Write-Host $vWifi -ForegroundColor Yellow
        $VerdictLines.Add($vWifi)
    }
}

$VerdictLines | Out-File -FilePath $DesktopPath -Encoding utf8 -Append

if (Test-Path $DesktopPath) {
    Write-Host ""
    Write-Host "[OK] Диагностика успешно завершена!" -ForegroundColor Green
    Write-Host "Отчёт сохранён на рабочий стол: $DesktopPath" -ForegroundColor Yellow
    Write-Host "Отправьте этот файл администратору или прикрепите в тикет." -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "[ERR] Что-то пошло не так при сохранении отчёта." -ForegroundColor Red
}

Write-Host ""
Write-Host "Нажмите Enter, чтобы закрыть окно..." -ForegroundColor Gray
Read-Host
