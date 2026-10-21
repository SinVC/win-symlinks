# WinSymlinksBroker Runtime

This archive contains only the privileged broker runtime for projects that want
to depend on `WinSymlinksBroker` without bundling the user-facing CLI tools.

## Contents

- `win-symlinks-broker.exe`
- `install-broker.ps1`
- `uninstall-broker.ps1`
- `README-broker.md`

The archive intentionally does not include `ln.exe` or `win-symlinks.exe`.

## Verify

Download broker runtime releases by fixed tag, not by a floating `latest` URL.
For example:

```powershell
$Version = "v0.0.4"
$BaseUrl = "https://github.com/winddxr/win-symlinks/releases/download/$Version"
$Asset = "win-symlinks-broker-$Version-x86_64-windows.zip"

Invoke-WebRequest "$BaseUrl/$Asset" -OutFile $Asset
Invoke-WebRequest "$BaseUrl/checksums-sha256.txt" -OutFile checksums-sha256.txt

$line = Get-Content checksums-sha256.txt |
    Where-Object { $_.EndsWith("  $Asset") } |
    Select-Object -First 1
if (-not $line) {
    throw "No checksum found for $Asset"
}

$expected = ($line -split "\s+", 2)[0]
$actual = (Get-FileHash $Asset -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expected) {
    throw "SHA256 mismatch for $Asset"
}
```

## Install

Run PowerShell as Administrator from the extracted runtime directory:

```powershell
.\install-broker.ps1
```

The installer copies `win-symlinks-broker.exe` to
`C:\Program Files\win-symlinks-broker` by default, registers the
`WinSymlinksBroker` Windows service as `LocalSystem`, configures delayed
automatic startup, and starts the service.

To install to a project-managed runtime directory:

```powershell
.\install-broker.ps1 -InstallDir "C:\Program Files\AgentLinker\Broker"
```

## Uninstall

Run PowerShell as Administrator:

```powershell
.\uninstall-broker.ps1
```

The uninstaller stops and deletes the `WinSymlinksBroker` service, removes the
installed broker executable, and removes the install directory only if it is
empty.
