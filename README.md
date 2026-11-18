# Disable-HyperV-VBS

在 Windows 10/11 上关闭或重新开启（交互式选择）Hyper-V、虚拟机平台与
「基于虚拟化的安全性」（VBS），适合需要 VMware/VirtualBox 性能、或排查虚拟化冲突的场景。
运行后会先检查当前状态，再在菜单里选择操作。

脚本可重复执行（幂等）：已经处于目标状态的项只记日志，不会重复改写。

目录、脚本文件与日志前缀统一使用 ASCII 名称，避免中文路径在 cmd / Windows PowerShell
下的编码问题；日志形如 `%TEMP%\HyperV-VBS_yyyyMMdd_HHmmss.log`。

## 文件

| 文件 | 用途 |
| --- | --- |
| `Disable-HyperV-VBS.ps1` | 交互式主脚本，必须管理员运行 |
| `Disable-HyperV-VBS.cmd` | 双击启动器，自动提权并运行同名 `.ps1` |
| `README.md` | 使用说明 |
| `LICENSE` | MIT 许可证 |

两个脚本必须放在同一目录且保持同名，启动器通过 `%~dpn0.ps1` 定位主脚本。

## 下载

直接下载 ZIP（无需 git，Windows PowerShell 中执行，下载后解压）：

```powershell
# GitHub
Invoke-WebRequest -Uri "https://github.com/jntm667/Disable-Hyper-V-VBS/archive/refs/heads/main.zip" -OutFile Disable-HyperV-VBS.zip -UseBasicParsing

# Gitee（国内加速，可选，内容与 GitHub 同步）
Invoke-WebRequest -Uri "https://gitee.com/jntm667/disable-hyper-v-vbs/repository/archive/main.zip" -OutFile Disable-HyperV-VBS.zip -UseBasicParsing
```

或用 git 克隆：

```bash
git clone https://github.com/jntm667/Disable-Hyper-V-VBS.git

# Gitee 加速（可选）
git clone https://gitee.com/jntm667/disable-hyper-v-vbs.git
```

解压后进入目录，两个脚本必须放在同一目录。GitHub 访问不畅时优先用 Gitee 地址。

## 使用

1. 双击 `Disable-HyperV-VBS.cmd`，UAC 提示选「是」。
2. 脚本先显示当前状态（BCD、可选功能、注册表、VBS/Hypervisor 运行状态），再提示选择：
   `[1]` 关闭、`[2]` 开启（恢复）、`[3]` 仅查看状态、`[0]` 退出；
   直接回车使用按当前状态给出的默认项（已开启默认关闭，已关闭默认开启）。
3. 操作完成后窗口停留，日志路径形如 `%TEMP%\HyperV-VBS_yyyyMMdd_HHmmss.log`。
4. 重启电脑生效。

也可以在管理员 PowerShell 中手动运行（交互流程相同）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Disable-HyperV-VBS.ps1"
```

## 脚本做了什么

运行后先检查状态，再选择关闭或开启；下列动作为关闭模式，开启模式执行相反操作。

1. BCD：`hypervisorlaunchtype off`、`vsmlaunchtype off`。
2. 可选功能：关闭 `Microsoft-Hyper-V-All`、`Microsoft-Hyper-V-Hypervisor`、
   `Microsoft-Hyper-V-Services`、`Microsoft-Hyper-V-Management-Clients`、
   `HypervisorPlatform`、`VirtualMachinePlatform`。
   已是 Disabled 的跳过；本机不存在的（如家庭版没有 Hyper-V）记录 `[SKIP]`。
3. 注册表兜底（仅这几项没有 PowerShell 直接开关）：
   - `DeviceGuard\EnableVirtualizationBasedSecurity`（VBS 主开关）
   - `HVCI\Enabled`、`HVCI\Locked`（内存完整性）
   - `Lsa\LsaCfgFlags`（Credential Guard）
   - `Scenarios\WindowsHello\Enabled`（Windows Hello 触发的 VBS 场景）

   仅当当前值非 0 时才写入 0；键/值不存在或已经为 0 时，不创建也不修改。

开启模式执行相反操作：BCD 两项设为 `Auto`；重新启用上述六项功能；
注册表写入启用值（值或键不存在时创建）：`EnableVirtualizationBasedSecurity=1`、
`HVCI\Enabled=1`、`LsaCfgFlags=2`（启用 Credential Guard，不加 UEFI 锁）、
`WindowsHello\Enabled=1`。

两种模式都不触碰组策略（`HKLM\SOFTWARE\Policies`）。需要管理员权限。

## 验证

用管理员 PowerShell 检查目标状态：

```powershell
bcdedit /enum "{current}" | findstr /i "hypervisor vsm"

Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform

Get-CimInstance Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard |
    Select-Object VirtualizationBasedSecurityStatus,SecurityServicesConfigured,SecurityServicesRunning

(Get-CimInstance Win32_ComputerSystem).HypervisorPresent
```

也可以运行 `msinfo32`，确认「基于虚拟化的安全性」为「未启用」。

关闭模式目标状态：BCD 两项为 `Off`，相关功能为 `Disabled`，`VirtualizationBasedSecurityStatus = 0`，
`HypervisorPresent = False`。

开启模式目标状态：BCD 两项为 `Auto`，相关功能为 `Enabled`，重启后
`VirtualizationBasedSecurityStatus = 2`、`HypervisorPresent = True`（需要硬件支持）。

## 注意事项

- 配置在重启后生效；重启前状态可能保持原样。
- 会同时破坏以下依赖 Hyper-V 的功能：WSL2、Docker Desktop（WSL2 后端）、
  Windows 沙盒、Windows 安卓子系统、Hyper-V 虚拟机。
- 关闭 VBS / 内存完整性会降低内核安全防护，抵御内核级恶意代码的能力下降。
  受企业策略或合规要求管理的设备不要运行。
- 如果启用了 BitLocker，修改 BCD 后小概率要求恢复密钥，重启前先确认密钥可用。
- `vsmlaunchtype` 在个别版本可能不被 BCD 支持，脚本会记录 `[WARN]` 并继续。
- 早期版本的 `-RestoreWindowsHello` 参数已移除：VBS 依赖 hypervisor 启动，
  单独恢复 Windows Hello 场景值无法恢复增强型安全登录。
- 开启模式按固定推荐值写入，不还原关闭前的原值；Credential Guard 使用
  `LsaCfgFlags=2`（无 UEFI 锁），需要 UEFI 锁请按 Microsoft 文档另行配置。
- 设备若被 UEFI 锁定（`DeviceGuard\Locked=1`），需先在 UEFI 中清除锁定，
  否则开启值不生效。
- 硬件不支持虚拟化（VT-x/AMD-V）或 VBS 时，开启后相关状态仍可能为未启用。

## 恢复（重新开启）

推荐直接运行启动器，在菜单中选择 `[2] 开启（恢复）`，重启后生效。
也可以手动执行以下步骤：

1. 恢复启动项：`bcdedit /set hypervisorlaunchtype auto`
2. 按需重新启用功能：

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
```

3. 打开 Windows 安全中心 → 设备安全性 → 内核隔离，按提示开启内存完整性。
4. 重启。

关闭时不记录注册表原值；开启模式按固定推荐值写入，功能开关与注册表值都会恢复。
若需要 UEFI 锁定或其他自定义配置，请按 Microsoft 文档另行设置。

## 许可

本项目采用 [MIT 许可证](LICENSE)，Copyright (c) 2026 jntm667。

本项目由 AI 辅助创建：脚本与 README 由 AI 生成初稿，经作者审核、修改并实测后发布。
AI 工具不主张本项目版权；复制、修改与再分发均按 MIT 许可证执行。
软件按「按原样」提供，不附带任何担保，使用风险自负。
