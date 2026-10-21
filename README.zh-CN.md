# win-symlinks

> [English](README.md) | **简体中文**

`win-symlinks` 为 Windows 11 提供类似 Linux 的 `ln -s TARGET LINK_NAME` 体验，使用真实的 Windows 符号链接。本项目不需要每次创建符号链接时都以管理员权限运行 `ln.exe`，同时确保安全性。

本项目不使用 Junction (目录联接)、Hard Link (硬链接)、文件复制或 `.lnk` 快捷方式来模拟符号链接。如果无法创建真正的符号链接，命令将失败并给出清晰的诊断信息。

## 概述 (Overview)

该软件包构建三个可执行文件：

| 可执行文件 | 用途 |
| --- | --- |
| `ln.exe` | 面向用户的 Linux 兼容命令，用于创建符号链接。 |
| `win-symlinks.exe` | 管理和诊断命令。 |
| `win-symlinks-broker.exe` | `WinSymlinksBroker` 的特权 Windows Service (Windows 服务) 宿主。 |

正常工作流：

```text
User shell -> ln.exe -> Named Pipe -> WinSymlinksBroker -> CreateSymbolicLinkW
```

`ln.exe` 可能会先尝试直接创建真正的符号链接。如果由于权限原因直接创建失败，它将使用 Broker Service (代理服务)。这两条路径都保留真正的 Windows 符号链接语义。

## 系统要求 (Requirements)

- Windows 11（预编译版本目前支持 x64），Windows PowerShell 5.1 或 PowerShell 7。
- 需要管理员权限以进行服务安装、服务启动/停止以及服务卸载。
- 支持符号链接的文件系统和 Windows 策略配置。

只有从源码构建时才需要 Rust 1.82 或更高版本及 Cargo。

代理服务适用于禁用了 Developer Mode (开发者模式) 或当前用户没有 `SeCreateSymbolicLinkPrivilege` 权限的计算机。

## 构建 (Build)

构建所有二进制文件：

```powershell
cargo build --release
```

发布版本的可执行文件将生成在：

```text
target\release\
```

有用的开发检查命令：

```powershell
cargo fmt -- --check
cargo test
cargo check
```

在构建目录运行 CLI 命令：

```powershell
cargo run --bin ln -- --help
cargo run --bin win-symlinks -- --help
```

本地打包和发布步骤见 [Release 工作流](dev-docs/releasing.md)。

## 快速安装 (Quick Install)

在 PowerShell 中运行下面一行命令，批准 Windows 管理员授权提示后等待安装完成：

```powershell
irm https://github.com/winddxr/win-symlinks/releases/latest/download/install.ps1 | iex
```

命令会获取最新 Release 中的安装脚本；脚本每次运行都会重新查询、下载并校验最新 Release，
安装到 `C:\Program Files\win-symlinks`，启动代理服务并配置 `PATH`。
无需安装 Rust。

普通版本标签（包括 `v0.x.y`）会发布为最新 Release；
`v0.1.0-beta.1` 等明确的预发布版本不会覆盖此入口。

**升级：** 再运行同一条命令即可。升级前请退出仍在运行的 `ln.exe` 或 `win-symlinks.exe` 进程。

指定版本安装：

```powershell
& ([scriptblock]::Create((irm https://github.com/winddxr/win-symlinks/releases/latest/download/install.ps1))) -Version v0.0.4
```

离线安装：从 [Releases](https://github.com/winddxr/win-symlinks/releases) 下载并校验完整 ZIP，
解压后在该目录运行 `.\install.ps1`。

每个 release 还会发布名为
`win-symlinks-broker-v<VERSION>-x86_64-windows.zip` 的 broker-only runtime
asset。它只包含 `win-symlinks-broker.exe`、Broker 服务安装/卸载脚本和
Broker runtime README，供不想打包 `ln.exe` 或 `win-symlinks.exe` 的下游项目使用。

## 手动安装 (Manual Install)

手动安装会将三个发布版本的可执行文件复制到一个固定的安装目录，将该目录添加到 `PATH`，然后从同一个目录注册并启动 Broker Service (代理服务)。

### 1. 构建发布版本二进制文件

```powershell
cargo build --release
```

### 2. 将二进制文件复制到固定目录

以管理员身份运行 PowerShell：

```powershell
$install = "C:\Program Files\win-symlinks"
New-Item -ItemType Directory -Force $install
Copy-Item target\release\ln.exe $install -Force
Copy-Item target\release\win-symlinks.exe $install -Force
Copy-Item target\release\win-symlinks-broker.exe $install -Force
```

请勿将 `target\release` 用作长期的安装目录。Windows 服务注册会存储代理执行文件的路径，因此它应指向一个固定的位置。

### 3. 将安装目录添加到 PATH

从管理员 PowerShell 中配置系统范围的 PATH：

```powershell
$install = "C:\Program Files\win-symlinks"
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if (($machinePath -split ";") -notcontains $install) {
    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$install", "Machine")
}
```

更改 `PATH` 后，请打开一个新的终端。

在 `PATH` 中，`ln.exe` 应出现在 Git for Windows、MSYS2、Cygwin、BusyBox 或其他 coreutils `ln.exe` 条目之前。

### 4. 安装并启动代理服务 (Broker Service)

从管理员 PowerShell 中运行：

```powershell
& "C:\Program Files\win-symlinks\win-symlinks.exe" service install
& "C:\Program Files\win-symlinks\win-symlinks.exe" service start
& "C:\Program Files\win-symlinks\win-symlinks.exe" service status
```

`service install` 会注册 `WinSymlinksBroker` Windows 服务，并从 `win-symlinks.exe` 所在的同一目录解析 `win-symlinks-broker.exe`。

### 5. 验证安装 (Verify The Installation)

打开一个新的非管理员终端：

```powershell
where.exe ln
win-symlinks.exe doctor
```

创建一个文件符号链接：

```powershell
"hello" | Set-Content target.txt
ln -s target.txt link.txt
Get-Item link.txt | Format-List FullName,LinkType,Target
```

创建一个目录符号链接：

```powershell
New-Item -ItemType Directory target-dir
ln -s target-dir link-dir
Get-Item link-dir | Format-List FullName,LinkType,Target
```

当目标尚未存在时，显式提供 Windows 链接类型：

```powershell
ln -s --win-kind=file future-target.txt future-link.txt
ln -s --win-kind=dir future-target-dir future-link-dir
```

## PowerShell 别名说明 (PowerShell Alias Note)

PowerShell 环境可能将 `ln` 定义为一个别名。如果 `ln` 未解析到本项目的可执行文件，请明确使用 `ln.exe`，或者在你的 PowerShell 配置文件中移除该别名：

```powershell
Remove-Item Alias:ln -Force -ErrorAction SilentlyContinue
```

要检查命令解析结果：

```powershell
Get-Command ln -All
where.exe ln
```

## 用法 (Usage)

支持的形式包括：

```powershell
ln -s TARGET LINK_NAME
ln -sf TARGET LINK_NAME
ln -sT TARGET LINK_NAME
ln -s --win-kind=file TARGET LINK_NAME
ln -s --win-kind=dir TARGET LINK_NAME
```

注意事项：

- 必须提供 `-s`。故意不支持硬链接模式。
- `-f` 可以替换 `LINK_NAME` 处现有的符号链接。
- `-f` 不得替换真实的文件或真实的目录。
- `-T` 将 `LINK_NAME` 视为链接路径，而不是将链接放在现有的目标目录中。
- 当目标不存在且 Windows 无法推断符号链接类型时，需要使用 `--win-kind=file|dir`。

## 集成 (Integration)

其他 Rust 项目和 AI 开发代理应使用公开的 client API，而不是复制 `ln.exe` 内部实现。轻量 SDK crate 是 `win-symlinks-client`；参见 [Integration Guide](docs/win-symlinks-integration.md)，了解依赖配置、Rust API 示例、broker-only 用法和原始 Named Pipe JSON schema。

## 管理命令 (Management Commands)

```powershell
win-symlinks.exe service install
win-symlinks.exe service uninstall
win-symlinks.exe service start
win-symlinks.exe service stop
win-symlinks.exe service status
win-symlinks.exe doctor
win-symlinks.exe config show
```

## 卸载 (Uninstall)

以管理员身份运行 PowerShell：

```powershell
win-symlinks.exe service uninstall
```

然后从 `PATH` 中移除安装目录，并删除已安装的文件：

```powershell
$install = "C:\Program Files\win-symlinks"
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$newPath = (($machinePath -split ";") | Where-Object { $_ -and $_ -ne $install }) -join ";"
[Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
Remove-Item $install -Recurse -Force
```

移除 PATH 条目后，请打开一个新的终端。

## 安全模型 (Security Model)

`WinSymlinksBroker` 以 `LocalSystem` 身份运行，因此它将每个请求都视为安全敏感的。在创建链接之前，Broker 会验证本地唯一的 IPC (进程间通信)、调用者身份、请求 Schema (模式)、调用者在链接父目录中的创建权限，以及源路径 Blacklist (黑名单) 策略。

Broker 仅创建真实的 Windows 符号链接。

### 被阻断的源目录 (Source Blacklist)

为了确保系统安全，Broker 故意阻断在某些敏感目录中创建符号链接（即 `ln` 的源路径）。默认的源路径黑名单 (Source Blacklist) 包括：

- `C:\Windows`（以及从 `SystemRoot` / `WINDIR` 派生的路径）
- `C:\Program Files` 和 `C:\Program Files (x86)`
- `C:\ProgramData`
- `C:\System Volume Information`
- `C:\$Recycle.Bin`
- 卷根目录 (Volume roots，例如 `C:\`, `D:\`)
- `C:\Users` 下其他用户的配置文件目录
- UNC 管理共享 (例如 `\\server\C$`)

用户可以通过编辑 `%ProgramData%\win-symlinks\config.json` 配置文件来扩展此黑名单。
