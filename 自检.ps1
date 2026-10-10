
$ErrorActionPreference = 'Continue'
$OutFile = "$PSScriptRoot\_test_result.txt"
if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
function Say([string]$t) {
    [System.IO.File]::AppendAllText($OutFile, $t + "`r`n", [System.Text.Encoding]::UTF8)
    Write-Host $t
}
function T([string]$n, $ok, [string]$d) {
    $mark = if ($ok) { '通过' } else { '失败' }
    Say ('{0,-30} {1}   {2}' -f $n, $mark, $d)
}
function Pad([string]$s, [int]$n) { if ($s.Length -gt $n) { return $s.Substring(0,$n) + '…' } else { return $s } }

# 保护：自检绝不破坏真实数据 —— 先备份，跑完还原
$CredFileSafe = Join-Path $env:LOCALAPPDATA 'UPCNet-AutoLogin\account.dat'
$StartupSafe  = Join-Path ([Environment]::GetFolderPath('Startup')) 'UPCNet-AutoLogin.vbs'
$Backup = $null; $HadReal = $false
if (Test-Path $CredFileSafe) { $Backup = [System.IO.File]::ReadAllBytes($CredFileSafe); $HadReal = $true }
$BackupVbs = $null; $HadVbs = $false
if (Test-Path $StartupSafe) { $BackupVbs = [System.IO.File]::ReadAllBytes($StartupSafe); $HadVbs = $true }
$RunKeySafe   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueSafe = 'UPCNet-AutoLogin'
$HadRun = $false; $BackupRun = $null
if (Test-Path $RunKeySafe) {
    try { $BackupRun = (Get-ItemProperty -Path $RunKeySafe -Name $RunValueSafe -ErrorAction Stop).$RunValueSafe; $HadRun = $true } catch { }
}

Say '=== UPCNet 部件自检 ==='
. "$PSScriptRoot\upcnet.ps1" -Action status
Say ('脚本路径: ' + $ScriptPath)
Say ''

try {
    $u = 'test12345'; $pw = 'Dummy!@#中文密码'
    Save-Account $u $pw
    $a = Load-Account
    T '1 账号加密存取' ($a -and $a.userId -eq $u -and $a.password -eq $pw) ('读回学号=' + $(if($a){$a.userId}else{'空'}))
    T '2 密码完整读回(含中文/符号)' ($a -and $a.password -eq $pw) ''
    $bytes = [System.IO.File]::ReadAllBytes($CredFile)
    $txt = [System.Text.Encoding]::UTF8.GetString($bytes)
    T '3 密文里看不到明文' (($txt -notlike '*test12345*') -and ($txt -notlike '*Dummy*')) ('密文文件 ' + $bytes.Length + ' 字节')
} catch { T '账号存取' $false $_.Exception.Message }

try {
    T '4 在线检测' (Test-Online) '（当前应为“能上网”）'
    $q = Get-PortalQuery
    T '5 取登录参数(已在线时为空)' ($null -eq $q) ('结果=' + $(if($q){Pad $q 30}else{'空（符合预期）'}))
    $r = Do-Login @{userId='x'; password='y'}
    T '6 已在线时自动跳过登录' ($r -eq $true) ''
} catch { T '在线相关' $false $_.Exception.Message }

try {
    Install-Autostart
    T '7 注册开机自启' (Test-Autostart) ''
    Remove-Autostart
    T '8 卸载开机自启' (-not (Test-Autostart)) ''
} catch { T '开机自启' $false $_.Exception.Message }

if (Test-Path $CredFile) { Remove-Item $CredFile -Force }
T '9 清理测试账号' (-not (Test-Path $CredFile)) ''

# 还原真实数据（如果本来就有）
if ($HadReal) {
    [System.IO.File]::WriteAllBytes($CredFileSafe, $Backup)
    T '10 还原真实账号' (Test-Path $CredFileSafe) '（自检不动你的数据）'
} else {
    T '10 真实账号保护' $true '（本来就没存，无需还原）'
}
if ($HadVbs) {
    [System.IO.File]::WriteAllBytes($StartupSafe, $BackupVbs)
    T '11 还原自启(旧位置)' (Test-Path $StartupSafe) '（自检不会卸掉你的自启）'
} else {
    T '11 自启保护(旧位置)' $true '（本来就没装，无需还原）'
}
if ($HadRun) {
    Set-ItemProperty -Path $RunKeySafe -Name $RunValueSafe -Value $BackupRun
    T '12 还原自启(注册表)' (Test-Autostart) '（自检不会卸掉你的自启）'
} else {
    T '12 自启保护(注册表)' $true '（本来就没装，无需还原）'
}
Say ''
Say '（以上全部使用测试用假账号，与你的真实账号无关）'
