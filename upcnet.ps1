<#
=====================================================================
 UPCNet 校园网自动登录   ——  中国石油大学（华东）

 用途：连上校园网后自动帮你填学号密码，掉线了自动重连。
       设置过开机自启以后，你就不用再管这件事了。

 安全说明：
   * 全程只在你自己的电脑上运行。
   * 账号密码用 Windows 系统自带的加密功能锁住，存在你自己电脑里，
     文件是 account.dat，拷到别的电脑上打不开。
   * 除了学校的认证服务器，程序不会把任何东西发到别的地方。

 用法：双击同目录下的 .bat 文件即可，不用看这个文件。
=====================================================================
#>

[CmdletBinding()]
param(
    [ValidateSet('status','login','install','uninstall','daemon','logout','demo','service','reset','diag','panel')]
    [string]$Action = 'login'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Security

# ============================ 固定设置 ============================
$AppName  = 'UPCNet-AutoLogin'
$DataDir  = Join-Path $env:LOCALAPPDATA $AppName
$CredFile = Join-Path $DataDir 'account.dat'
$LogFile  = Join-Path $DataDir 'log.txt'
$TaskName = 'UPCNet-AutoLogin'

# 学校认证服务器（IP 不需要 DNS，断网时也能用）
$PortalIp  = '121.251.251.217'

# 上网方式对照表（学生在安装时选，存进账号文件；以后可随时改）
$ServiceMap = [ordered]@{
    '1' = @{ code = 'default'; name = '校园网' }
    '2' = @{ code = 'cmcc';    name = '中国移动' }
    '3' = @{ code = 'unicom';  name = '中国联通' }
    '4' = @{ code = 'ctcc';    name = '中国电信' }
    '5' = @{ code = 'local';   name = '校园内网' }
}
$Service = 'default'   # 默认值；实际以账号文件里存的为准

# 判断“现在能不能上网”用的测试地址
$OnlineUrl  = 'http://www.msftconnecttest.com/connecttest.txt'
$OnlineWord = 'Microsoft Connect Test'

# 用来触发认证页跳转、从而拿到登录参数的地址（依次尝试）
$RedirectProbes = @(
    'http://121.251.251.217/',                                    # 纯 IP，不需要 DNS —— 最关键的一个
    'http://connectivitycheck.platform.hicloud.com/generate_204',  # 华为
    'http://connect.rom.miui.com/generate_204',                    # 小米
    'http://www.msftconnecttest.com/redirect',                     # 微软
    'http://captive.apple.com/hotspot-detect.html'                 # 苹果
)

# 认证服务器地址：先用 IP（不需要 DNS），失败再用域名。
# ★ 必须 HTTPS 优先！登录时密码是明文放在请求体里的，
#   走 HTTP 的话，同一个开放 WiFi（比如 UPC）下抓包就能看到学号密码。
#   （曾经把纯 IP 的 http 放前面，理由是“断网时 DNS 失效”，
#     后来实测发现未认证状态下 wlan.upc.edu.cn 解析正常，那个理由不成立。）
$PortalBases = @(
    'https://wlan.upc.edu.cn/eportal/InterFace.do?method=',
    'http://121.251.251.217/eportal/InterFace.do?method='    # 仅作最后退路，会记警告
)

$ScriptPath = $PSCommandPath

# ============================ 基础工具 ============================
function Initialize-DataDir {
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
}

function Write-Log([string]$Message) {
    Initialize-DataDir
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", [System.Text.Encoding]::UTF8) } catch { }
    Write-Host $line
}

function Read-Text([System.IO.Stream]$Stream) {
    $sr = New-Object System.IO.StreamReader($Stream, [System.Text.Encoding]::UTF8)
    $t = $sr.ReadToEnd(); $sr.Close()
    return $t
}

# ============================ 联网检测 ============================
# 直接问认证服务器（只用 IP，不需要 DNS），它自己会告诉我们状态：
#   跳到 success.jsp -> 已经认证好了
#   跳到 index.jsp   -> 有校园网，但还没认证
#   连不上           -> 根本没网
$script:LastPortalLoc = ''
function Get-PortalState {
    $r = Get-HttpProbe "http://$PortalIp/"
    $script:LastPortalLoc = $r.loc
    if ($r.err) { return 'unreachable' }
    if ($r.code -eq 0) { return 'unreachable' }
    # 注意：这个状态只用来“提示”，不作为最终依据。
    # 因为在线时跳的是 redirectortosuccess.jsp，而它里面也含有 success.jsp。
    if ($r.loc -like '*success.jsp*') { return 'online' }
    if ($r.loc -like '*index.jsp*')   { return 'portal' }
    return 'unknown'
}

function Get-HttpProbe([string]$Url) {
    # 拿一个地址的原始反应：状态码 + 有没有跳转 + 正文
    $res = @{ code = 0; loc = ''; body = ''; err = '' }
    try {
        $rq = [System.Net.HttpWebRequest]::Create($Url)
        $rq.AllowAutoRedirect = $false        # 关键：不许它自己跟着跳
        $rq.Timeout = 6000
        $rq.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        $rs = $rq.GetResponse()
        $res.code = [int]$rs.StatusCode
        $res.loc  = ([string]$rs.Headers['Location']).Trim()
        if ($res.code -eq 200) {
            $sr = New-Object System.IO.StreamReader($rs.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $res.body = $sr.ReadToEnd(); $sr.Close()
        }
        $rs.Close()
    } catch [System.Net.WebException] {
        $rr = $_.Exception.Response
        if ($rr) {
            $res.code = [int]$rr.StatusCode
            $res.loc  = ([string]$rr.Headers['Location']).Trim()
            $rr.Close()
        } else { $res.err = $_.Exception.Message }
    } catch { $res.err = $_.Exception.Message }
    return $res
}

function Test-Online {
    # 只有“确定已联网”的信号才算数：204，或 200 + 正文完全等于约定内容
    # （绝不能只用“包含某词”，否则认证页里的 success 会骗过我们）
    $probes = @(
        @{ u = 'http://connectivitycheck.platform.hicloud.com/generate_204'; want = '' },
        @{ u = 'http://connect.rom.miui.com/generate_204';                   want = '' },
        @{ u = 'http://www.msftconnecttest.com/connecttest.txt';             want = 'Microsoft Connect Test' },
        @{ u = 'http://captive.apple.com/hotspot-detect.html';               want = 'Success' }
    )
    foreach ($pb in $probes) {
        $r = Get-HttpProbe $pb.u
        if ($r.code -eq 204) { return $true }
        if ($r.code -eq 200 -and $r.loc -eq '') {
            if ($pb.want -eq '') { return $true }
            # -ceq = 区分大小写的完全相等
            if ($r.body.Trim() -ceq $pb.want) { return $true }
        }
    }
    return $false
}

# ============================ 拿登录参数 ============================
function Extract-PortalQuery([string]$Text) {
    if (-not $Text) { return $null }
    $i = $Text.IndexOf('eportal/index.jsp?')
    if ($i -lt 0) { return $null }
    $q = $Text.Substring($i + 'eportal/index.jsp?'.Length)
    $cut = $q.Length
    foreach ($ch in @('"', "'", ' ', "`r", "`n", '<')) {
        $k = $q.IndexOf($ch)
        if ($k -ge 0 -and $k -lt $cut) { $cut = $k }
    }
    $q = $q.Substring(0, $cut).Replace('&amp;', '&')
    if ($q.Length -gt 0) { return $q }
    return $null
}

function Get-PortalQuery {
    foreach ($url in $RedirectProbes) {

        # 方式 A：一路跟着跳转走，读“最终落到的地址”——和浏览器行为一致
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.AllowAutoRedirect = $true
            $req.MaximumAutomaticRedirections = 12
            $req.Timeout = 8000
            $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            $resp = $req.GetResponse()
            $final = $resp.ResponseUri.AbsoluteUri
            $q = Extract-PortalQuery $final
            $resp.Close()
            if ($q) { Write-Log "已从 $url 取到登录参数"; return $q }
        } catch [System.Net.WebException] {
            $r = $_.Exception.Response
            if ($r) {
                $q = Extract-PortalQuery $r.ResponseUri.AbsoluteUri
                $r.Close()
                if ($q) { Write-Log "已从 $url 取到登录参数"; return $q }
            }
        } catch { }

        # 方式 B：不跟随，只看 Location 头
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.AllowAutoRedirect = $false
            $req.Timeout = 6000
            $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            $resp = $req.GetResponse()
            $q = Extract-PortalQuery $resp.Headers['Location']
            if (-not $q) { $q = Extract-PortalQuery (Read-Text $resp.GetResponseStream()) }
            $resp.Close()
            if ($q) { Write-Log "已从 $url 取到登录参数"; return $q }
        } catch [System.Net.WebException] {
            $r = $_.Exception.Response
            if ($r) {
                $q = Extract-PortalQuery $r.Headers['Location']
                $r.Close()
                if ($q) { Write-Log "已从 $url 取到登录参数"; return $q }
            }
        } catch { }
    }
    return $null
}

# ============================ 执行登录 ============================
function Invoke-PortalLogin([string]$UserId, [string]$Password, [string]$Query, [string]$Svc) {
    if (-not $Svc) { $Svc = 'default' }
    $kv = [ordered]@{
        userId          = $UserId
        password        = $Password
        service         = $Svc
        queryString     = $Query
        operatorPwd     = ''
        operatorUserId  = ''
        validcode       = ''
        passwordEncrypt = 'false'
    }
    $pairs = @()
    foreach ($k in $kv.Keys) { $pairs += ('{0}={1}' -f [Uri]::EscapeDataString($k), [Uri]::EscapeDataString([string]$kv[$k])) }
    $body = $pairs -join '&'

    $lastErr = ''
    foreach ($base in $PortalBases) {
        if ($base -like 'http://*') {
            Write-Log '⚠ 警告：HTTPS 走不通，退回不加密的 HTTP 发送密码（同一网络下可能被监听）'
        }
        try {
            $resp = Invoke-WebRequest -Uri ($base + 'login') -Method POST -Body $body `
                    -ContentType 'application/x-www-form-urlencoded; charset=UTF-8' `
                    -UseBasicParsing -TimeoutSec 15
            return (Read-Text $resp.RawContentStream)
        } catch { $lastErr = $_.Exception.Message }
    }
    throw "所有认证服务器都连不上：$lastErr"
}

# ============================ 注销（下线） ============================
function Invoke-PortalLogout([string]$UserId, [string]$Password) {
    $pairs = 'userId={0}&pass={1}' -f [Uri]::EscapeDataString($UserId), [Uri]::EscapeDataString($Password)
    $lastErr = ''
    foreach ($base in $PortalBases) {
        try {
            $resp = Invoke-WebRequest -Uri ($base + 'logoutByUserIdAndPass') -Method POST -Body $pairs `
                    -ContentType 'application/x-www-form-urlencoded; charset=UTF-8' `
                    -UseBasicParsing -TimeoutSec 15
            $t = Read-Text $resp.RawContentStream
            try { return (($t | ConvertFrom-Json).result) } catch { return $t }
        } catch { $lastErr = $_.Exception.Message }
    }
    return ('请求失败：' + $lastErr)
}

# ============================ 账号存储 ============================
function Get-ServiceName([string]$Code) {
    foreach ($k in $ServiceMap.Keys) { if ($ServiceMap[$k].code -eq $Code) { return $ServiceMap[$k].name } }
    return $Code
}

function Save-Account([string]$UserId, [string]$Password, [string]$Svc) {
    Initialize-DataDir
    if (-not $Svc) { $Svc = 'default' }
    $plain = "$UserId`n$Password`n$Svc"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $enc   = [System.Security.Cryptography.ProtectedData]::Protect(
                $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes($CredFile, $enc)
}

function Load-Account {
    if (-not (Test-Path $CredFile)) { return $null }
    try {
        $enc   = [System.IO.File]::ReadAllBytes($CredFile)
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                    $enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $plain = [System.Text.Encoding]::UTF8.GetString($bytes)
        $parts = $plain -split "`n"
        if ($parts.Count -lt 2) { return $null }
        $svc = if ($parts.Count -ge 3 -and $parts[2].Trim()) { $parts[2].Trim() } else { 'default' }
        return @{ userId = $parts[0].Trim(); password = $parts[1]; service = $svc }
    } catch { return $null }
}

function Find-WorkingService([string]$UserId, [string]$Password) {
    # 逐个试五种上网方式，返回第一个能登录成功的。都失败返回 $null。
    foreach ($k in $ServiceMap.Keys) {
        $code = $ServiceMap[$k].code
        $name = $ServiceMap[$k].name
        Write-Host ('  正在试：' + $name + ' …') -NoNewline
        $q = Get-PortalQuery
        if (-not $q) { Write-Host '（拿不到登录参数，无法试）'; return $null }
        try { $text = Invoke-PortalLogin $UserId $Password $q $code } catch { Write-Host '（请求失败）'; Start-Sleep -Seconds 3; continue }
        $ok = $false; $msg = ''
        try { $o = $text | ConvertFrom-Json; $ok = ($o.result -eq 'success'); $msg = $o.message } catch { $msg = $text }
        if ($ok -or (Test-Online)) { Write-Host ('  成功 ✅') -ForegroundColor Green; return $code }
        Write-Host ('  不行：' + $msg)
        Start-Sleep -Seconds 3
    }
    return $null
}

function Ask-Service {
    Write-Host ''
    Write-Host '请选择你的上网方式：' -ForegroundColor Cyan
    Write-Host '   1) 校园网        （最常见。不确定就直接回车）'
    Write-Host '   2) 中国移动'
    Write-Host '   3) 中国联通'
    Write-Host '   4) 中国电信'
    Write-Host '   5) 校园内网'
    Write-Host '   6) 我不确定 —— 自动一个个试出来（需要此刻处于未认证状态）'
    Write-Host ''
    while ($true) {
        $ans = Read-Host '  请输入序号 [1]'
        if ([string]::IsNullOrWhiteSpace($ans)) { return 'default' }
        $ans = $ans.Trim()
        if ($ans -eq '6') { return 'auto' }
        if ($ServiceMap.Contains($ans)) { return $ServiceMap[$ans].code }
        Write-Host '  输入不对，请填 1 到 6 之间的数字。' -ForegroundColor Yellow
    }
}

function Ask-Account {
    Write-Host ''
    Write-Host '首次使用，请输入你的校园网账号。' -ForegroundColor Cyan
    Write-Host '（就是连校园网时网页上要填的那个学号和密码，也用于统一身份认证）'
    $u = Read-Host '  学号'
    $sec = Read-Host '  密码（输入时不会显示）' -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $p = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    $svc = Ask-Service
    if ($svc -eq 'auto') {
        Write-Host ''
        if (Test-Online) {
            Write-Host '  你现在已经能上网，没法试。先按「校园网」保存，' -ForegroundColor Yellow
            Write-Host '  等下次没认证时用「6-改上网方式.bat」选 6 自动试。' -ForegroundColor Yellow
            $svc = 'default'
        } else {
            Write-Host '  开始逐个试，找出你能用的上网方式…' -ForegroundColor Cyan
            $found = Find-WorkingService $u.Trim() $p
            if ($found) { $svc = $found }
            else {
                Write-Host ''
                Write-Host '  五种都试过了，没有一个成功。' -ForegroundColor Yellow
                Write-Host '  常见原因：账号真的没余额、密码不对、或者上网方式不在列表里。' -ForegroundColor Yellow
                Write-Host '  先按「校园网」保存，你可以之后用「6-改上网方式.bat」再改。' -ForegroundColor Yellow
                $svc = 'default'
            }
        }
    }
    return @{ userId = $u.Trim(); password = $p; service = $svc }
}

# ============================ 开机自启 ============================
# 做法参照 CUP-Login：写注册表 HKCU 的 Run 键（同样不需要管理员权限）。
# 启动器 upcnet.vbs 就放在程序旁边，它自己算路径，不会再出路径空格的错。
$RunKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue = 'UPCNet-AutoLogin'
$Launcher      = Join-Path (Split-Path -Parent $ScriptPath) 'upcnet.vbs'
$LegacyStartup = Join-Path ([Environment]::GetFolderPath('Startup')) 'UPCNet-AutoLogin.vbs'

function Install-Autostart {
    if (-not (Test-Path $RunKey)) { New-Item -Path $RunKey -Force | Out-Null }
    Set-ItemProperty -Path $RunKey -Name $RunValue -Value ('wscript.exe //B //Nologo "{0}"' -f $Launcher)
    if (Test-Path $LegacyStartup) { Remove-Item $LegacyStartup -Force -ErrorAction SilentlyContinue }
}

function Remove-Autostart {
    Remove-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue
    if (Test-Path $LegacyStartup) { Remove-Item $LegacyStartup -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*upcnet.ps1*' -and $_.CommandLine -like '*daemon*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Test-Autostart {
    try {
        $v = (Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction Stop).$RunValue
        return ($v -like '*upcnet.vbs*')
    } catch { return $false }
}

# ============================ 一次登录 ============================
function Do-Login([hashtable]$Acct) {
    if (Test-Online) {
        Write-Log '当前已经能上网，无需登录。'
        return $true
    }
    Write-Log '检测到未登录，正在获取登录参数…'
    $q = Get-PortalQuery
    if (-not $q) {
        Write-Log '拿不到登录参数 —— 可能你根本没连上校园网（没开 WiFi / 没插网线），或学校改了认证方式。'
        return $false
    }
    $svc = if ($Acct.service) { $Acct.service } else { 'default' }
    Write-Log ('正在登录…（上网方式：' + (Get-ServiceName $svc) + '）')
    try {
        $text = Invoke-PortalLogin $Acct.userId $Acct.password $q $svc
    } catch {
        Write-Log ('登录请求失败：' + $_.Exception.Message)
        return $false
    }
    $ok = $false; $msg = ''
    try {
        $obj = $text | ConvertFrom-Json
        $ok  = ($obj.result -eq 'success')
        $msg = $obj.message
    } catch { $msg = $text }

    if ($ok -or (Test-Online)) {
        Write-Log ('登录成功。' + $(if ($msg) { "（$msg）" } else { '' }))
        return $true
    }
    Write-Log ('登录失败：' + $msg)
    return $false
}

# ============================ 后台守护 ============================
function Start-Daemon {
    $acct = Load-Account
    if (-not $acct) { Write-Log '没有保存的账号，无法后台运行。请先双击“1-首次设置.bat”。'; return }

    Write-Log '自动登录服务已启动（后台运行中）'
    $diagDone = $false
    while ($true) {
        try {
            if (Test-Online) {
                $diagDone = $false
            } else {
                Write-Log '检测到掉线，尝试重新登录…'
                $ok = Do-Login $acct
                if (-not $ok -and -not $diagDone) {
                    $diagDone = $true
                    $f = Write-DiagFile
                    Write-Log ('本次掉线已自动留档：' + $f)
                }
            }
        } catch { Write-Log ('发生错误：' + $_.Exception.Message) }
        Start-Sleep -Seconds 20
    }
}

# ============================ 主流程 ============================
# ============================ 诊断（收集断网时的真实情况）============================
function Write-DiagFile {
    Initialize-DataDir
        $out = Join-Path $DataDir 'diag.txt'
        $L = @()
        $L += ('诊断时间 : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        $L += ('能否上网 : ' + (Test-Online))
        $L += ''

        $L += '--- 0. 所有网卡（重点看 WLAN 是不是 Connected）---'
        try {
            foreach ($a in (Get-NetAdapter -ErrorAction SilentlyContinue)) {
                $L += ('  {0,-22} 状态={1,-14} 速率={2}' -f $a.Name, $a.Status, $a.LinkSpeed)
            }
        } catch { $L += ('  读取失败: ' + $_.Exception.Message) }
        $L += ''

        $L += '--- 1. 本机网络配置 ---'
        try {
            foreach ($c in (Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' })) {
                $L += ('  网卡     : ' + $c.InterfaceAlias)
                $L += ('  本机IP   : ' + (($c.IPv4Address | ForEach-Object { $_.IPAddress }) -join ','))
                $L += ('  网关     : ' + (($c.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ','))
                $L += ('  DNS      : ' + (($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ','))
            }
        } catch { $L += ('  读取失败: ' + $_.Exception.Message) }
        $L += ''

        $L += '--- 1b. Windows 认为的网络类型（关键）---'
        try {
            $pf = Get-NetConnectionProfile -ErrorAction SilentlyContinue
            if ($pf) {
                foreach ($x in $pf) {
                    $L += ('  ' + $x.Name + '  |  ' + $x.InterfaceAlias + '  |  Windows判定=' + $x.IPv4Connectivity)
                }
            } else { $L += '  没有活动网络' }
        } catch { $L += ('  读取失败: ' + $_.Exception.Message) }
        $L += '  （Internet=真的能上网；LocalNetwork/NoTraffic=连上了但没认证）'
        $L += ''

        $L += '--- 2. 域名解析 ---'
        foreach ($h in @('wlan.upc.edu.cn','www.msftconnecttest.com','www.baidu.com','self.upc.edu.cn')) {
            try {
                $ips = ([System.Net.Dns]::GetHostAddresses($h) | ForEach-Object { $_.IPAddressToString }) -join ','
                $L += ('  {0,-28} -> {1}' -f $h, $ips)
            } catch { $L += ('  {0,-28} -> 解析失败：{1}' -f $h, $_.Exception.Message) }
        }
        $L += ''

        $L += '--- 3. 各探测地址的真实反应 ---'
        $all = @()
        $all += $RedirectProbes
        $all += $PortalBases
        foreach ($u in $all) {
            $L += ('  [' + $u + ']')
            # 不跟随
            try {
                $rq = [System.Net.HttpWebRequest]::Create($u); $rq.AllowAutoRedirect = $false
                $rq.Timeout = 6000; $rq.UserAgent = 'Mozilla/5.0'
                $rs = $rq.GetResponse()
                $L += ('     不跟随 : 状态=' + [int]$rs.StatusCode + ' | Location=' + $rs.Headers['Location'])
                $rs.Close()
            } catch [System.Net.WebException] {
                $rr = $_.Exception.Response
                if ($rr) { $L += ('     不跟随 : 状态=' + [int]$rr.StatusCode + ' | Location=' + $rr.Headers['Location']); $rr.Close() }
                else { $L += ('     不跟随 : 失败 → ' + $_.Exception.Message) }
            } catch { $L += ('     不跟随 : 失败 → ' + $_.Exception.Message) }
            # 跟随到底
            try {
                $rq = [System.Net.HttpWebRequest]::Create($u); $rq.AllowAutoRedirect = $true
                $rq.MaximumAutomaticRedirections = 12
                $rq.Timeout = 8000; $rq.UserAgent = 'Mozilla/5.0'
                $rs = $rq.GetResponse()
                $L += ('     跟随到底: ' + $rs.ResponseUri.AbsoluteUri)
                $rs.Close()
            } catch [System.Net.WebException] {
                $rr = $_.Exception.Response
                if ($rr) { $L += ('     跟随到底: ' + $rr.ResponseUri.AbsoluteUri); $rr.Close() }
                else { $L += ('     跟随到底: 失败 → ' + $_.Exception.Message) }
            } catch { $L += ('     跟随到底: 失败 → ' + $_.Exception.Message) }
        }
        $L += ''

        $L += '--- 4. 能不能取到登录参数 ---'
        $q = Get-PortalQuery
        if ($q) { $L += ('  成功：' + $q) } else { $L += '  失败：一个探测地址都没能拿到参数' }

        [System.IO.File]::WriteAllLines($out, $L, [System.Text.Encoding]::UTF8)
        Write-Host ('  诊断结果已写入：' + $out) -ForegroundColor Green
        return $out
}

# ============================ 主面板（唯一入口）============================
function Show-Panel {

        Write-Host ''
        Write-Host '==============================================' -ForegroundColor Cyan
        Write-Host '         UPCNet 校园网自动登录' -ForegroundColor Cyan
        Write-Host '   中国石油大学（华东）· 连上就自动登录' -ForegroundColor Cyan
        Write-Host '==============================================' -ForegroundColor Cyan
        Write-Host ''

        $acct = Load-Account

        # ---------- 第一次用：直接带他装完 ----------
        if (-not $acct) {
            Write-Host '  看你像是第一次用，我带你装一下，只需要走这一次。' -ForegroundColor Cyan
            Write-Host ''
            $acct = Ask-Account
            Save-Account $acct.userId $acct.password $acct.service
            Write-Host ''
            Write-Host '  账号已保存到你自己电脑上（已加密）。' -ForegroundColor Green
            Write-Host ''
            $null = Do-Login $acct
            Install-Autostart
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('//B //Nologo "{0}"' -f $Launcher) -WindowStyle Hidden
            Write-Host ''
            Write-Host '  装好了 ✅  已开启开机自动登录。' -ForegroundColor Green
            Write-Host ''
            Write-Host '  以后你什么都不用点 ——' -ForegroundColor Cyan
            Write-Host '  连上校园网就会自动登录，掉线了也会自动重连。' -ForegroundColor Cyan
            Write-Host ''
            return
        }

        # ---------- 已经装过：显示面板 ----------
        $online  = Test-Online
        $svcName = Get-ServiceName $acct.service
        $uid     = $acct.userId
        $masked  = if ($uid.Length -gt 6) { $uid.Substring(0,4) + '****' + $uid.Substring($uid.Length-2) } else { $uid }

        Write-Host ('  现在能上网    : ' + $(if ($online) { '能 ✅' } else { '不能 ❌' }))
        Write-Host ('  你的账号      : ' + $masked + '（' + $svcName + '）')
        Write-Host ('  开机自动登录  : ' + $(if (Test-Autostart) { '已开启 ✅' } else { '未开启 ❌' }))
        Write-Host ''
        Write-Host '  要做什么？'
        Write-Host '    1) 没事，退出'
        Write-Host '    2) 现在检查并登录一次'
        Write-Host '    3) 改上网方式（校园网 / 移动 / 联通 / 电信）'
        Write-Host '    4) 重新输入账号密码'
        Write-Host '    5) 生成一份诊断报告（出问题时用）'
        Write-Host '    6) 完全卸载（删掉账号和开机自启）'
        Write-Host ''
        $ans = Read-Host '  请输入序号 [1]'
        if ([string]::IsNullOrWhiteSpace($ans)) { $ans = '1' }
        Write-Host ''
        switch ($ans.Trim()) {
            '2' { & $ScriptPath -Action demo }
            '3' { & $ScriptPath -Action service }
            '4' { & $ScriptPath -Action reset }
            '5' { & $ScriptPath -Action diag }
            '6' { & $ScriptPath -Action uninstall }
            default { Write-Host '  好的，没做事。' }
        }
        Write-Host ''
}

# 只有被“直接运行”时才执行主流程；被其它脚本载入时只提供函数，不执行。
if ($MyInvocation.InvocationName -ne '.') {
switch ($Action) {

    'status' {
        Write-Host ''
        Write-Host '========== UPCNet 自动登录 · 当前状态 ==========' -ForegroundColor Cyan
        $online = Test-Online
        Write-Host ('  现在能上网吗 : ' + $(if ($online) { '能 ✅' } else { '不能 ❌' }))
        $acct = Load-Account
        Write-Host ('  有没有存账号 : ' + $(if ($acct) { '有 ✅（' + $acct.userId + '）' } else { '没有 ❌' }))
        Write-Host ('  开机自启装了没: ' + $(if (Test-Autostart) { '装了 ✅' } else { '没装 ❌' }))
        $svcNow = if ($acct) { $acct.service } else { $Service }
        Write-Host ('  上网方式      : ' + $svcNow + '（' + (Get-ServiceName $svcNow) + '）')
        Write-Host ('  数据目录      : ' + $DataDir)
        Write-Host '================================================' -ForegroundColor Cyan
        Write-Host ''
    }

    'login' {
        $acct = Load-Account
        if (-not $acct) {
            $acct = Ask-Account
            Save-Account $acct.userId $acct.password $acct.service
            Write-Host ''
            Write-Host '账号已保存到你本机（已加密）。' -ForegroundColor Green
        }
        $null = Do-Login $acct
        Write-Host ''
    }

    'install' {
        $acct = Load-Account
        if (-not $acct) {
            $acct = Ask-Account
            Save-Account $acct.userId $acct.password $acct.service
            Write-Host '账号已保存到你本机（已加密）。' -ForegroundColor Green
        }
        $null = Do-Login $acct
        Install-Autostart
        Write-Host '已设置开机自动登录。以后开机就会在后台自动连网。' -ForegroundColor Green
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('//B //Nologo "{0}"' -f $Launcher) -WindowStyle Hidden
        Write-Host '后台守护已启动。' -ForegroundColor Green
        Write-Host ''
    }

    'uninstall' {
        Remove-Autostart
        if (Test-Path $CredFile) { Remove-Item $CredFile -Force }
        Write-Host '已取消开机自启，并删除了保存的账号。' -ForegroundColor Green
        Write-Host ''
    }

    'logout' {
        $acct = Load-Account
        if (-not $acct) { Write-Host '还没有保存账号，请先运行“1-安装并自动登录.bat”。' -ForegroundColor Yellow; break }
        Write-Log '正在下线…'
        Write-Log ('下线结果：' + (Invoke-PortalLogout $acct.userId $acct.password))
        Write-Host ''
    }

    'demo' {
        $acct = Load-Account
        if (-not $acct) { Write-Host '还没有保存账号，请先运行“1-安装并自动登录.bat”。' -ForegroundColor Yellow; break }

        Write-Host ''
        Write-Host '====== 检查并尝试登录 ======' -ForegroundColor Cyan

        $st = Get-PortalState
        if ($script:LastPortalLoc) { Write-Host ('  [参考] 认证服务器跳转到: ' + $script:LastPortalLoc) }
        else { Write-Host '  [参考] 认证服务器没有响应' }

        if (Test-Online) {
            Write-Host '  结论：现在能上网（已认证），不需要登录。' -ForegroundColor Green
        }
        elseif ($st -eq 'unreachable') {
            Write-Host '  结论：连不上认证服务器 —— 你现在根本没连上校园网。' -ForegroundColor Yellow
            Write-Host '  请先连上 UPC 的 WiFi 或插好网线。' -ForegroundColor Yellow
        }
        else {
            Write-Host '  结论：连上了校园网，但还不能上网 —— 正在登录…' -ForegroundColor Yellow
            if (Do-Login $acct) {
                Write-Host '★ 登录成功，现在应该能上网了。' -ForegroundColor Green
            } else {
                Write-Host '★ 登录失败。' -ForegroundColor Yellow
                $f = Write-DiagFile
                Write-Host ('  已自动留档：' + $f) -ForegroundColor Yellow
                Write-Host '  把这个文件发给我。' -ForegroundColor Yellow
            }
        }
        Write-Host ''
    }

    'service' {
        $acct = Load-Account
        if (-not $acct) { Write-Host '还没有保存账号，请先运行“1-安装并自动登录.bat”。' -ForegroundColor Yellow; break }
        Write-Host ''
        Write-Host ('  当前上网方式：' + '（' + (Get-ServiceName $acct.service) + '）') -ForegroundColor Cyan
        $newSvc = Ask-Service
        if ($newSvc -eq 'auto') {
            if (Test-Online) {
                Write-Host '  你现在已经能上网，没法试。请等没认证时再来。' -ForegroundColor Yellow
                break
            }
            Write-Host ''
            Write-Host '  开始逐个试…' -ForegroundColor Cyan
            $found = Find-WorkingService $acct.userId $acct.password
            if (-not $found) {
                Write-Host '  五种都试过了，没有一个成功。上网方式保持不变。' -ForegroundColor Yellow
                break
            }
            $newSvc = $found
        }
        Save-Account $acct.userId $acct.password $newSvc
        Write-Host ''
        Write-Host ('已改成：' + (Get-ServiceName $newSvc)) -ForegroundColor Green
        Write-Host '（下次后台登录就会用这个）' -ForegroundColor Green
        Write-Host ''
        # 立刻试一次
        if (-not (Test-Online)) {
            Write-Host '现在正好没认证，马上试一次登录…'
            $null = Do-Login (Load-Account)
            Write-Host ''
        }
    }

    'reset' {
        Write-Host ''
        Write-Host '重新输入账号密码（原来的会被覆盖）：' -ForegroundColor Cyan
        $acct = Ask-Account
        Save-Account $acct.userId $acct.password $acct.service
        Write-Host '已更新。' -ForegroundColor Green
        Write-Host ''
        $null = Do-Login $acct
        Write-Host ''
    }

    'diag' {
        Write-Host ''
        Write-Host '====== 网络诊断 ======' -ForegroundColor Cyan
        $f = Write-DiagFile
        Write-Host ''
    }

    'panel' { Show-Panel }

    'daemon' { Start-Daemon }
}
}
