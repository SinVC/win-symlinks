# win-symlinks

> **English** | [简体中文](README.zh-CN.md)

`win-symlinks` provides a Linux-like `ln -s TARGET LINK_NAME` experience on Windows 11 using real Windows symbolic links. It eliminates the need to run `ln.exe` with administrator privileges every time a symbolic link is created, while ensuring security.

The project does not emulate symlinks with junctions, hardlinks, file copies, or
`.lnk` shortcuts. If a real symbolic link cannot be created, the command fails
with a clear diagnostic.

## Overview

The package builds three executables:

| Executable | Purpose |
| --- | --- |
| `ln.exe` | User-facing Linux-compatible command for creating symbolic links. |
| `win-symlinks.exe` | Management and diagnostic command. |
| `win-symlinks-broker.exe` | Privileged Windows service host for `WinSymlinksBroker`. |

Normal operation:

```text
User shell -> ln.exe -> Named Pipe -> WinSymlinksBroker -> CreateSymbolicLinkW
```

`ln.exe` may try direct true symlink creation first. If direct creation fails
because of privilege, it uses the broker service. Both paths preserve true
Windows symbolic link semantics.

## Requirements

- Windows 11 (x64 for prebuilt releases), with Windows PowerShell 5.1 or PowerShell 7.
- Administrator rights for service installation, service start/stop, and service
  removal.
- A filesystem and Windows policy configuration that support symbolic links.

Rust 1.82 or newer and Cargo are only needed when building from source.

The broker service is intended for machines where Developer Mode is disabled or
the current user does not have `SeCreateSymbolicLinkPrivilege`.

## Build

Build all binaries:

```powershell
cargo build --release
```

The release executables will be created under:

```text
target\release\
```

Useful development checks:

```powershell
cargo fmt -- --check
cargo test
cargo check
```

Run the CLIs from the build directory:

```powershell
cargo run --bin ln -- --help
cargo run --bin win-symlinks -- --help
```

See [Release workflow](dev-docs/releasing.md) for local packaging and publication.

## Quick Install

Run this in PowerShell, approve the Windows administrator prompt, and wait for
installation to finish:

```powershell
irm https://github.com/winddxr/win-symlinks/releases/latest/download/install.ps1 | iex
```

The command fetches the latest released installer. The script resolves and
verifies the latest release on each run, then installs it in
`C:\Program Files\win-symlinks`, starts the broker service, and configures `PATH`.
No Rust toolchain is required.

Normal version tags, including `v0.x.y`, publish as the latest release.
Explicit prerelease tags such as `v0.1.0-beta.1` do not replace it.

**Upgrade:** run the same command again. Close any running `ln.exe` or
`win-symlinks.exe` processes first.

To install a specific version:

```powershell
& ([scriptblock]::Create((irm https://github.com/winddxr/win-symlinks/releases/latest/download/install.ps1))) -Version v0.0.4
```

For offline installation, download and verify the full ZIP from
[Releases](https://github.com/winddxr/win-symlinks/releases), extract it, and run
`.\install.ps1` from the extracted directory.

Each release also publishes a broker-only runtime asset named
`win-symlinks-broker-v<VERSION>-x86_64-windows.zip`. It contains only
`win-symlinks-broker.exe`, broker service install/uninstall scripts, and a
broker runtime README for downstream projects that do not want to bundle
`ln.exe` or `win-symlinks.exe`.

## Manual Install

The manual setup copies the three release executables to a
stable installation directory, adds that directory to `PATH`, then registers and
starts the broker service from that same directory.

### 1. Build Release Binaries

```powershell
cargo build --release
```

### 2. Copy Binaries To A Stable Directory

Run PowerShell as Administrator:

```powershell
$install = "C:\Program Files\win-symlinks"
New-Item -ItemType Directory -Force $install
Copy-Item target\release\ln.exe $install -Force
Copy-Item target\release\win-symlinks.exe $install -Force
Copy-Item target\release\win-symlinks-broker.exe $install -Force
```

Do not use `target\release` as the long-term installation directory. The Windows
service registration stores the broker executable path, so it should point at a
stable location.

### 3. Add The Install Directory To PATH

Machine-wide PATH, from an Administrator PowerShell:

```powershell
$install = "C:\Program Files\win-symlinks"
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if (($machinePath -split ";") -notcontains $install) {
    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$install", "Machine")
}
```

Open a new terminal after changing `PATH`.

`ln.exe` should appear before Git for Windows, MSYS2, Cygwin, BusyBox, or other
coreutils `ln.exe` entries on `PATH`.

### 4. Install And Start The Broker Service

Run from an Administrator PowerShell:

```powershell
& "C:\Program Files\win-symlinks\win-symlinks.exe" service install
& "C:\Program Files\win-symlinks\win-symlinks.exe" service start
& "C:\Program Files\win-symlinks\win-symlinks.exe" service status
```

`service install` registers the `WinSymlinksBroker` Windows service and resolves
`win-symlinks-broker.exe` from the same directory as `win-symlinks.exe`.

### 5. Verify The Installation

Open a new non-admin terminal:

```powershell
where.exe ln
win-symlinks.exe doctor
```

Create a file symlink:

```powershell
"hello" | Set-Content target.txt
ln -s target.txt link.txt
Get-Item link.txt | Format-List FullName,LinkType,Target
```

Create a directory symlink:

```powershell
New-Item -ItemType Directory target-dir
ln -s target-dir link-dir
Get-Item link-dir | Format-List FullName,LinkType,Target
```

When the target does not exist yet, provide the Windows link kind explicitly:

```powershell
ln -s --win-kind=file future-target.txt future-link.txt
ln -s --win-kind=dir future-target-dir future-link-dir
```

## PowerShell Alias Note

PowerShell environments may define `ln` as an alias. If `ln` does not resolve to
this project's executable, use `ln.exe` explicitly or remove the alias in your
PowerShell profile:

```powershell
Remove-Item Alias:ln -Force -ErrorAction SilentlyContinue
```

To inspect command resolution:

```powershell
Get-Command ln -All
where.exe ln
```

## Usage

Supported forms include:

```powershell
ln -s TARGET LINK_NAME
ln -sf TARGET LINK_NAME
ln -sT TARGET LINK_NAME
ln -s --win-kind=file TARGET LINK_NAME
ln -s --win-kind=dir TARGET LINK_NAME
```

Notes:

- `-s` is required. Hardlink mode is intentionally unsupported.
- `-f` may replace an existing symbolic link at `LINK_NAME`.
- `-f` must not replace a real file or real directory.
- `-T` treats `LINK_NAME` as the link path instead of placing the link inside an
  existing destination directory.
- `--win-kind=file|dir` is needed when the target does not exist and Windows
  cannot infer the symbolic link type.

## Integration

Other Rust projects and AI coding agents should use the public client API rather
than copying `ln.exe` internals. The lightweight SDK crate is
`win-symlinks-client`; see [Integration Guide](docs/win-symlinks-integration.md) for
dependency snippets, Rust API examples, broker-only usage, and the raw Named
Pipe JSON schema.

## Management Commands

```powershell
win-symlinks.exe service install
win-symlinks.exe service uninstall
win-symlinks.exe service start
win-symlinks.exe service stop
win-symlinks.exe service status
win-symlinks.exe doctor
win-symlinks.exe config show
```

## Uninstall

Run PowerShell as Administrator:

```powershell
win-symlinks.exe service uninstall
```

Then remove the installation directory from `PATH` and delete the installed
files:

```powershell
$install = "C:\Program Files\win-symlinks"
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$newPath = (($machinePath -split ";") | Where-Object { $_ -and $_ -ne $install }) -join ";"
[Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
Remove-Item $install -Recurse -Force
```

Open a new terminal after removing the PATH entry.

## Security Model

`WinSymlinksBroker` runs as `LocalSystem`, so it treats every request as
security-sensitive. The broker validates local-only IPC, caller identity, request
schema, caller permission to create in the link parent directory, and source
blacklist policy before creating a link.

The broker creates only real Windows symbolic links.

### Blocked Source Directories (Blacklist)

To ensure system safety, the broker intentionally blocks creating symbolic links in certain sensitive directories (the source path for `ln`). The default source blacklist includes:

- `C:\Windows` (and paths derived from `SystemRoot` / `WINDIR`)
- `C:\Program Files` and `C:\Program Files (x86)`
- `C:\ProgramData`
- `C:\System Volume Information`
- `C:\$Recycle.Bin`
- Volume roots (e.g., `C:\`, `D:\`)
- Other users' profile directories under `C:\Users`
- UNC administrative shares (e.g., `\\server\C$`)

Users can extend this blacklist by editing the configuration file at `%ProgramData%\win-symlinks\config.json`.
