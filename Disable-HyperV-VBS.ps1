#Requires -RunAsAdministrator
<#
.SYNOPSIS
    交互式关闭或开启 Hyper-V 与「基于虚拟化的安全性」（VBS）。

.DESCRIPTION
    运行后先检查当前状态（BCD、可选功能、注册表、VBS 与 Hypervisor 运行状态），
    再让选择：1=关闭、2=开启（恢复）、3=仅查看状态、0=退出；直接回车按当前状态取默认项。
    关闭模式优先使用系统自带的直接开关，注册表只作兜底：
      1) BCD：hypervisorlaunchtype / vsmlaunchtype = off
      2) 可选功能：Hyper-V 全套 / HypervisorPlatform / VirtualMachinePlatform
      3) 注册表：VBS、内存完整性、Credential Guard、Windows Hello 的 VBS 场景
         没有 PowerShell 直接开关，只能写注册表；仅当当前值非 0 时才改为 0，
         键或值不存在、或已经是 0 的一律不动。
    开启模式执行相反操作：
      1) BCD：hypervisorlaunchtype / vsmlaunchtype = auto
      2) 可选功能：重新启用上述六项
      3) 注册表：写入启用值（键或值不存在时创建）：
         VBS=1、HVCI=1、Credential Guard=2（启用但不加 UEFI 锁）、Windows Hello=1
    两种模式都不触碰组策略（HKLM\SOFTWARE\Policies）。

.NOTES
    需管理员权限；执行后必须重启才生效；可重复执行（幂等）。
    关闭时不记录原值，开启按固定推荐值写入；UEFI 锁定设备需先在 UEFI 中解锁。
    开启后，硬件不支持虚拟化或 VBS 的机器上相关功能仍可能不可用。
#>

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$log   = Join-Path $env:TEMP ('HyperV-VBS_' + $stamp + '.log')
$enable = $null

$dg   = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
$hvci = Join-Path $dg 'Scenarios\HypervisorEnforcedCodeIntegrity'
$wh   = Join-Path $dg 'Scenarios\WindowsHello'
$lsa  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'

$features = @(
    'Microsoft-Hyper-V-All'
    'Microsoft-Hyper-V-Hypervisor'
    'Microsoft-Hyper-V-Services'
    'Microsoft-Hyper-V-Management-Clients'
    'HypervisorPlatform'
    'VirtualMachinePlatform'
)

$regChecks = @(
    @{ Path = $dg;   Name = 'EnableVirtualizationBasedSecurity'; Label = 'DeviceGuard\EnableVirtualizationBasedSecurity' }
    @{ Path = $hvci; Name = 'Enabled';  Label = 'HVCI\Enabled' }
    @{ Path = $hvci; Name = 'Locked';   Label = 'HVCI\Locked' }
    @{ Path = $lsa;  Name = 'LsaCfgFlags'; Label = 'Lsa\LsaCfgFlags' }
    @{ Path = $wh;   Name = 'Enabled';  Label = 'WindowsHello\Enabled' }
)

function Log([string]$m) {
    Write-Host $m
    Add-Content -LiteralPath $log -Value $m -Encoding UTF8
}
function Section([string]$t) { Log ''; Log ('===== ' + $t + ' =====') }

function Get-BcdValue([string]$name) {
    $line = $script:bdLines | Where-Object { $_ -match ('^\s*' + [regex]::Escape($name) + '\s+') } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -split '\s+')[-1]
}

function Get-Dword([string]$path, [string]$name) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $key = Get-Item -LiteralPath $path
    if ($key.GetValueNames() -notcontains $name) { return $null }
    return [int]$key.GetValue($name)
}

function Set-Bcd([string]$element, [string]$value) {
    $out = & "$env:SystemRoot\System32\bcdedit.exe" /set $element $value 2>&1
    if ($LASTEXITCODE -eq 0) {
        Log ('  [OK]   ' + $element + ' ' + $value)
    } else {
        Log ('  [WARN] ' + $element + ' ' + $value + ' 失败: ' + (($out | Out-String).Trim()))
    }
}

function Set-Dword([string]$path, [string]$name, [int]$value, [string]$label) {
    $cur = Get-Dword $path $name
    if ($enable) {
        if ($cur -eq $value) { Log ('  [OK]   ' + $label + ' 已是 ' + $value); return }
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -LiteralPath $path -Name $name -PropertyType DWord -Value $value -Force | Out-Null
        Log ('  [OK]   ' + $label + ' ' + $(if ($null -eq $cur) { '不存在' } else { [string]$cur }) + ' -> ' + $value)
    } else {
        if ($null -eq $cur) { Log ('  [SKIP] ' + $label + ' 不存在'); return }
        if ($cur -eq 0)     { Log ('  [OK]   ' + $label + ' 已是 0'); return }
        New-ItemProperty -LiteralPath $path -Name $name -PropertyType DWord -Value 0 -Force | Out-Null
        Log ('  [OK]   ' + $label + ' ' + $cur + ' -> 0')
    }
}

Log ('日志文件: ' + $log)
Log ('开始时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# ================================================================ 状态检查
Section '当前状态检查'

$script:bdLines = (& "$env:SystemRoot\System32\bcdedit.exe" /enum '{current}' 2>&1 | Out-String) -split "`r?`n"
$bcdHyper = Get-BcdValue 'hypervisorlaunchtype'
$bcdVsm   = Get-BcdValue 'vsmlaunchtype'
Log ('  BCD hypervisorlaunchtype = ' + $(if ($bcdHyper) { $bcdHyper } else { '未找到' }))
Log ('  BCD vsmlaunchtype = ' + $(if ($bcdVsm) { $bcdVsm } else { '不支持/未找到' }))

foreach ($f in $features) {
    try {
        Log ('  功能 ' + $f + ' = ' + (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop).State)
    } catch {
        Log ('  功能 ' + $f + ' = 不存在')
    }
}

foreach ($c in $regChecks) {
    $v = Get-Dword $c.Path $c.Name
    Log ('  注册表 ' + $c.Label + ' = ' + $(if ($null -eq $v) { '不存在' } else { $v }))
}

$hvPresent = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
Log ('  Hypervisor 是否在运行 = ' + $hvPresent)

try {
    $d = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
    Log ('  VBS 状态码 = ' + $d.VirtualizationBasedSecurityStatus +
         ' | 已配置 = [' + ($d.SecurityServicesConfigured -join ',') +
         '] | 运行中 = [' + ($d.SecurityServicesRunning -join ',') + ']')
} catch {
    Log '  DeviceGuard 状态查询失败'
}

if ($hvPresent -eq $true) {
    $stateKind = 'enabled';  $stateText = '已开启（Hypervisor 正在运行）'
} elseif ($bcdHyper -eq 'Auto') {
    $stateKind = 'enabled';  $stateText = '已开启（等待重启生效）'
} elseif ($bcdHyper -eq 'Off') {
    $stateKind = 'disabled'; $stateText = '已关闭'
} else {
    $stateKind = 'mixed';    $stateText = '状态未知或混合'
}
Log ('  当前判断: ' + $stateText)

# ================================================================ 选择操作
$default = if ($stateKind -eq 'enabled') { '1' } else { '2' }
Write-Host ''
Write-Host ('请选择操作（当前判断：' + $stateText + '）：') -ForegroundColor Yellow
Write-Host '  [1] 关闭 Hyper-V 与 VBS'
Write-Host '  [2] 开启（恢复）Hyper-V 与 VBS'
Write-Host '  [3] 仅查看状态，不修改'
Write-Host '  [0] 退出'
do {
    $choice = (Read-Host ('输入 1/2/3/0（直接回车默认 ' + $default + '）')).Trim()
    if ($choice -eq '') { $choice = $default }
} while ($choice -notin @('0', '1', '2', '3'))

if ($choice -eq '0') {
    Log '  用户选择: 退出'
    Log ('结束时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    exit
}
if ($choice -eq '3') {
    Log '  用户选择: 仅查看状态'
    Log ('结束时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    exit
}

$enable = ($choice -eq '2')
Log ('  用户选择: ' + $(if ($enable) { '开启（恢复）' } else { '关闭' }))

if (($enable -and $stateKind -eq 'enabled') -or (-not $enable -and $stateKind -eq 'disabled')) {
    Log '  [提示] 当前已处于目标状态，本次执行仅做幂等校验。'
}

# ================================================================ 1. BCD
$bcdValue = if ($enable) { 'auto' } else { 'off' }
Section $(if ($enable) { '1/4 BCD：恢复 hypervisor 与 VSM 启动' } else { '1/4 BCD：关闭 hypervisor 与 VSM 启动' })

Set-Bcd 'hypervisorlaunchtype' $bcdValue
Set-Bcd 'vsmlaunchtype' $bcdValue

# ================================================================ 2. 可选功能
Section $(if ($enable) { '2/4 可选功能：重新启用 Hyper-V 与虚拟机平台' } else { '2/4 可选功能：关闭 Hyper-V 与虚拟机平台' })

foreach ($f in $features) {
    try {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop).State
    } catch {
        Log ('  [SKIP] ' + $f + ' -> 本机不存在该功能')
        continue
    }

    if ($enable) {
        if ($state -in @('Enabled', 'EnablePending')) {
            Log ('  [OK]   ' + $f + ' -> 已是 ' + $state)
            continue
        }
        try {
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -ErrorAction Stop
            Log ('  [OK]   ' + $f + ' -> Enabled (RestartNeeded=' + $r.RestartNeeded + ')')
        } catch {
            Log ('  [ERR]  ' + $f + ' -> ' + $_.Exception.Message)
        }
    } else {
        if ($state -notin @('Enabled', 'EnablePending')) {
            Log ('  [OK]   ' + $f + ' -> 已是 ' + $state)
            continue
        }
        try {
            $r = Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -ErrorAction Stop
            Log ('  [OK]   ' + $f + ' -> Disabled (RestartNeeded=' + $r.RestartNeeded + ')')
        } catch {
            Log ('  [ERR]  ' + $f + ' -> ' + $_.Exception.Message)
        }
    }
}

# ================================================================ 3. 注册表兜底
Section $(if ($enable) { '3/4 注册表：写入 VBS 相关启用值' } else { '3/4 注册表：仅关闭没有直接开关的 VBS 相关项' })

if ($enable) {
    Set-Dword $dg 'EnableVirtualizationBasedSecurity' 1 'DeviceGuard\EnableVirtualizationBasedSecurity'
    Set-Dword $hvci 'Enabled' 1 'HVCI\Enabled'
    Set-Dword $lsa 'LsaCfgFlags' 2 'Lsa\LsaCfgFlags'
    Set-Dword $wh 'Enabled' 1 'WindowsHello\Enabled'
} else {
    $vbs = Get-Dword $dg 'EnableVirtualizationBasedSecurity'
    if ($null -ne $vbs -and $vbs -ne 0) {
        Set-Dword $dg 'Locked' 0 'DeviceGuard\Locked'
        Set-Dword $dg 'EnableVirtualizationBasedSecurity' 0 'DeviceGuard\EnableVirtualizationBasedSecurity'
    } else {
        Log '  [OK]   DeviceGuard\EnableVirtualizationBasedSecurity 未开启，不写入'
    }

    if ((Get-Dword $hvci 'Enabled') -in @(1, 2)) {
        Set-Dword $hvci 'Locked' 0 'HVCI\Locked'
        Set-Dword $hvci 'Enabled' 0 'HVCI\Enabled'
    } else {
        Log '  [OK]   HVCI 未开启，不写入'
    }

    Set-Dword $lsa 'LsaCfgFlags' 0 'Lsa\LsaCfgFlags'
    Set-Dword $wh 'Enabled' 0 'WindowsHello\Enabled'
}

# ================================================================ 4. 验证
Section '4/4 验证结果'

$bd = (& "$env:SystemRoot\System32\bcdedit.exe" /enum '{current}' 2>&1 | Out-String) -split "`r?`n"
foreach ($l in ($bd | Where-Object { $_ -match 'hypervisorlaunchtype|vsmlaunchtype' })) {
    Log ('  BCD: ' + $l.Trim())
}

foreach ($f in $features) {
    try {
        Log ('  功能 ' + $f + ' = ' + (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop).State)
    } catch {
        Log ('  功能 ' + $f + ' = 不存在')
    }
}

foreach ($c in $regChecks) {
    $v = Get-Dword $c.Path $c.Name
    Log ('  注册表 ' + $c.Label + ' = ' + $(if ($null -eq $v) { '不存在' } else { $v }))
}

try {
    $d = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
    Log ('  VBS 状态码 = ' + $d.VirtualizationBasedSecurityStatus +
         ' | 已配置 = [' + ($d.SecurityServicesConfigured -join ',') +
         '] | 运行中 = [' + ($d.SecurityServicesRunning -join ',') + ']')
} catch {
    Log '  DeviceGuard 状态查询失败'
}
Log ('  Hypervisor 是否在运行 = ' + (Get-CimInstance Win32_ComputerSystem).HypervisorPresent)

Section '完成'
if ($enable) {
    Log '  启用配置已写入，需重启生效；重启后 Hyper-V 与 VBS 才恢复运行。'
    Log '  重启后可运行 msinfo32，确认「基于虚拟化的安全性」为「正在运行」。'
} else {
    Log '  配置已写入，需重启生效；重启前仍显示开启属正常。'
    Log '  重启后可运行 msinfo32，确认「基于虚拟化的安全性」为「未启用」。'
}
Log ('结束时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host ''
Write-Host ('日志: ' + $log) -ForegroundColor Cyan
