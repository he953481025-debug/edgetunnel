# 扫描 Cloudflare IP 实际落地的机房（colo），按地区输出可直接粘贴到 ADD.txt 的节点行
# 原理：对每个 IP 发 TLS + GET /cdn-cgi/trace，读回包里的 colo= 字段，同时记录 TCP 握手耗时。
# 同一个 IP 在不同运营商/不同网络下可能落到不同机房，所以要在"实际使用节点的那张网"上跑。
#
# 用法（先关掉代理软件，含 TUN 模式）：
#   powershell -ExecutionPolicy Bypass -File .\scan-colo.ps1 -Regions SG
#   powershell -ExecutionPolicy Bypass -File .\scan-colo.ps1 -Regions SG,TPE -Ports 443,2053,2083,2087,8443 -Threads 128
#   powershell -ExecutionPolicy Bypass -File .\scan-colo.ps1 -Source official -PerRange 100   # 只扫官方大段
#   powershell -ExecutionPolicy Bypass -File .\scan-colo.ps1 -Domain 你的.pages.dev -OutDir D:\scan
param(
	[string]$Domain = 'cdnjs.cloudflare.com',  # 任意 Cloudflare 站点即可；填自己的节点域名可顺带验证该域名可达
	[string]$OutDir = '',         # 结果 CSV / 网段缓存的输出目录，默认与脚本同目录
	[ValidateSet('asn', 'official')]
	[string]$Source = 'asn',      # asn: Cloudflare 全部宣告网段(AS13335+AS209242)；official: 官方公布的 15 个大段
	[int]$PerPrefix = 2,          # asn 模式：每个 /24 抽几个，更大的段按大小加倍（/22 x2，/20 x4 …）
	[int]$PerRange = 40,          # official 模式：每个大段抽几个
	[int]$Expand = 24,            # 命中目标地区后，在同一个 /24 里再测几个（0 关闭）
	[int]$Threads = 64,
	[int]$Timeout = 3,            # 单个 IP 超时秒数
	[string[]]$Ports = @('443'),  # 可加 2053,2083,2087,2096,8443
	[string[]]$Regions = @('TPE', 'SG', 'US'),
	[int]$Top = 5,                # 每个地区输出延迟最低的前几个
	[switch]$Refresh              # 重新拉取 ASN 网段（默认复用 7 天内的缓存）
)
# powershell -File 传参时 "a,b" 会被当成一个字符串，这里统一按逗号拆开
$Ports = @($Ports -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { [int]$_ })
$Regions = @($Regions -split ',' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
$outDir = if ($OutDir) { (New-Item -ItemType Directory -Force $OutDir).FullName } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$officialRanges = @(
	'104.16.0.0/13', '104.24.0.0/14', '172.64.0.0/13', '162.158.0.0/15', '108.162.192.0/18',
	'188.114.96.0/20', '141.101.64.0/18', '190.93.240.0/20', '197.234.240.0/22', '198.41.128.0/17',
	'173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22', '131.0.72.0/22'
)

# 机房代码 -> 地区标签（备注以地区标签开头，订阅里 region=sg / region=tpe 等才能筛到）
$coloRegion = @{ SIN = 'SG'; NRT = 'JP'; KIX = 'JP'; FUK = 'JP'; OKA = 'JP'; TPE = 'TPE'; KHH = 'TPE'; HKG = 'HK' }
'LAX SJC SEA DFW ORD IAD EWR ATL MIA DEN PHX LAS SLC SAN PDX BOS IAH MSP DTW CLT JAX MCI STL BNA SMF OMA ABQ AUS SAT IND CMH PIT PHL RIC ORF TPA MCO RDU BUF CLE HNL ANC MEM MSY OKC TUL BOI FSD' -split ' ' | ForEach-Object { $coloRegion[$_] = 'US' }

function Get-CfPrefixes {
	$cache = Join-Path $outDir 'cf-prefixes.txt'
	if (-not $Refresh -and (Test-Path $cache) -and ((Get-Date) - (Get-Item $cache).LastWriteTime).TotalDays -lt 7) {
		return @(Get-Content $cache | Where-Object { $_ })
	}
	try {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
		$list = foreach ($as in 'AS13335', 'AS209242') {
			$d = Invoke-RestMethod -TimeoutSec 60 "https://stat.ripe.net/data/announced-prefixes/data.json?resource=$as"
			$d.data.prefixes.prefix | Where-Object { $_ -notmatch ':' }
		}
		$list = @($list | Sort-Object -Unique)
		if ($list.Count -gt 0) { Set-Content -Path $cache -Value $list -Encoding ASCII; return $list }
	} catch { Write-Host "拉取 ASN 网段失败：$($_.Exception.Message)" -ForegroundColor Yellow }
	if (Test-Path $cache) { Write-Host '使用旧缓存' -ForegroundColor Yellow; return @(Get-Content $cache | Where-Object { $_ }) }
	Write-Host '退回官方网段列表' -ForegroundColor Yellow
	return $officialRanges
}

function ConvertTo-UInt32([string]$ip) { $b = ([Net.IPAddress]::Parse($ip)).GetAddressBytes(); [Array]::Reverse($b); [BitConverter]::ToUInt32($b, 0) }
function ConvertTo-IP([uint32]$n) { $o = [BitConverter]::GetBytes($n); [Array]::Reverse($o); ([Net.IPAddress]$o).ToString() }

# 在网段内随机取 count 个不重复的主机地址（跳过网络号和广播地址）
function Get-RandomIPs([string]$cidr, [int]$count) {
	$base, $bits = $cidr -split '/'
	$start = ConvertTo-UInt32 $base
	$size = [int64][math]::Pow(2, 32 - [int]$bits)
	if ($size -le 2) { return @(ConvertTo-IP $start) }
	$count = [int][math]::Min($count, $size - 2)
	$picked = @{}
	while ($picked.Count -lt $count) { $picked[[int64](Get-Random -Minimum 1 -Maximum ($size - 1))] = $true }
	$picked.Keys | ForEach-Object { ConvertTo-IP ([uint32]($start + $_)) }
}

$probe = {
	param($ip, $port, $domain, $timeout)
	# 用 .NET 直接连 TCP + TLS，每一步都自己卡超时（有些机器上 curl.exe 的 -m 超时不生效，会卡死并发名额）
	$deadline = [DateTime]::UtcNow.AddSeconds($timeout)
	$left = { [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds) }
	$tcp = New-Object Net.Sockets.TcpClient
	try {
		$sw = [Diagnostics.Stopwatch]::StartNew()
		if (-not $tcp.ConnectAsync($ip, $port).Wait((& $left))) { return }
		$connectMs = [int]$sw.Elapsed.TotalMilliseconds
		$ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false)
		if (-not $ssl.AuthenticateAsClientAsync($domain, $null, [Security.Authentication.SslProtocols]::Tls12, $false).Wait((& $left))) { return }
		$req = [Text.Encoding]::ASCII.GetBytes("GET /cdn-cgi/trace HTTP/1.1`r`nHost: $domain`r`nUser-Agent: curl/8.0`r`nConnection: close`r`n`r`n")
		if (-not $ssl.WriteAsync($req, 0, $req.Length).Wait((& $left))) { return }
		$read = (New-Object IO.StreamReader($ssl)).ReadToEndAsync()
		if (-not $read.Wait((& $left))) { return }
		$m = [regex]::Match($read.Result, '(?m)^colo=(\w+)')
		if ($m.Success) { [pscustomobject]@{ IP = $ip; Port = $port; Colo = $m.Groups[1].Value; Ms = $connectMs } }
	} catch { } finally { $tcp.Close() }
}

$csv = Join-Path $outDir ("scan-colo-{0:yyyyMMdd-HHmm}.csv" -f (Get-Date))
# 边测边写：中途 Ctrl+C 已测通的结果也保留在 CSV 里
[IO.File]::WriteAllText($csv, "IP,Port,Colo,Ms`r`n", (New-Object Text.UTF8Encoding($true)))
$results = New-Object System.Collections.ArrayList
$tested = @{}

function Invoke-Scan([object[]]$targets, [string]$label) {
	$targets = @($targets | Where-Object { -not $tested.ContainsKey("$($_.IP):$($_.Port)") })
	if ($targets.Count -eq 0) { return }
	$targets | ForEach-Object { $tested["$($_.IP):$($_.Port)"] = $true }
	Write-Host "[$label] 共 $($targets.Count) 个待测，$Threads 并发，单个超时 ${Timeout}s，预计最多 $([math]::Ceiling($targets.Count / $Threads) * $Timeout)s ..."
	$pool = [runspacefactory]::CreateRunspacePool(1, $Threads); $pool.Open()
	$pending = New-Object System.Collections.Generic.List[object]
	foreach ($t in $targets) {
		$ps = [powershell]::Create(); $ps.RunspacePool = $pool
		[void]$ps.AddScript($probe).AddArgument($t.IP).AddArgument($t.Port).AddArgument($Domain).AddArgument($Timeout)
		$pending.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
	}
	$total = $pending.Count; $hits = 0
	$sw = [Diagnostics.Stopwatch]::StartNew(); $lastReport = 0
	try {
		while ($pending.Count -gt 0) {
			foreach ($j in @($pending | Where-Object { $_.Handle.IsCompleted })) {
				$r = $j.PS.EndInvoke($j.Handle); $j.PS.Dispose(); [void]$pending.Remove($j)
				if (-not $r) { continue }
				$x = $r[0]; [void]$results.Add($x)
				[IO.File]::AppendAllText($csv, "$($x.IP),$($x.Port),$($x.Colo),$($x.Ms)`r`n")
				if ($Regions -contains $coloRegion[$x.Colo]) { $hits++; Write-Host ("  命中 {0}:{1} {2} {3}ms" -f $x.IP, $x.Port, $x.Colo, $x.Ms) -ForegroundColor Green }
			}
			if ($sw.Elapsed.TotalSeconds - $lastReport -ge 5) {
				$lastReport = $sw.Elapsed.TotalSeconds
				Write-Host ("  进度 {0}/{1}，已通 {2}，命中 {3}，用时 {4:N0}s" -f ($total - $pending.Count), $total, $results.Count, $hits, $lastReport)
			}
			Start-Sleep -Milliseconds 200
		}
	} finally {
		$pending | ForEach-Object { try { $_.PS.Stop(); $_.PS.Dispose() } catch { } }
		$pool.Close()
	}
}

# 第一轮：按网段抽样
if ($Source -eq 'asn') {
	$prefixes = Get-CfPrefixes
	Write-Host "网段数 $($prefixes.Count)（来源：$(if ($prefixes.Count -gt $officialRanges.Count) { 'Cloudflare ASN 宣告' } else { '官方列表' })）"
	$plan = foreach ($p in $prefixes) {
		$len = [int]($p -split '/')[1]
		@{ Cidr = $p; N = [int][math]::Max(1, [math]::Round($PerPrefix * [math]::Pow(2, [math]::Max(0, 24 - $len) / 2))) }
	}
} else {
	$plan = foreach ($p in $officialRanges) { @{ Cidr = $p; N = $PerRange } }
}
$targets = foreach ($x in $plan) { foreach ($ip in (Get-RandomIPs $x.Cidr $x.N)) { foreach ($port in $Ports) { [pscustomobject]@{ IP = $ip; Port = $port } } } }
Invoke-Scan $targets '抽样'

# 第二轮：命中目标地区的 /24 段里再多测一些，同一 /24 路由通常一致
if ($Expand -gt 0) {
	$hit24 = @($results | Where-Object { $Regions -contains $coloRegion[$_.Colo] } | ForEach-Object { ($_.IP -replace '\.\d+$', '.0') + '/24' } | Sort-Object -Unique)
	if ($hit24.Count -gt 0) {
		$targets = foreach ($c in $hit24) { foreach ($ip in (Get-RandomIPs $c $Expand)) { foreach ($port in $Ports) { [pscustomobject]@{ IP = $ip; Port = $port } } } }
		Invoke-Scan $targets "扩展 $($hit24.Count) 个命中的 /24"
	}
}

if ($results.Count -gt 0) { $results | Sort-Object Colo, Ms | Export-Csv -NoTypeInformation -Encoding UTF8 $csv }

Write-Host "`n===== 机房分布（连通 $($results.Count) / $($tested.Count)）====="
$results | Group-Object Colo | Sort-Object Count -Descending | ForEach-Object { "{0,-5} {1,4} 个  最低 {2}ms" -f $_.Name, $_.Count, ($_.Group | Measure-Object Ms -Minimum).Minimum }

Write-Host "`n===== 复制到 ADD.txt（每个地区延迟最低的 $Top 个）====="
foreach ($reg in $Regions) {
	$i = 0
	$results | Where-Object { $coloRegion[$_.Colo] -eq $reg } | Sort-Object Ms | Select-Object -First $Top | ForEach-Object { $i++; "{0}:{1}#{2}-{3} {4} {5}ms" -f $_.IP, $_.Port, $reg, $i, $_.Colo, $_.Ms }
	if ($i -eq 0) { "# $reg：本次没有扫到落在该地区机房的 IP" }
}
Write-Host "`n完整结果：$csv"
