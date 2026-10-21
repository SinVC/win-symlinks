<#
.SYNOPSIS
    Install or upgrade win-symlinks from GitHub Releases (PowerShell 5.1+).
.EXAMPLE
    irm https://github.com/winddxr/win-symlinks/releases/latest/download/install.ps1 | iex
.EXAMPLE
    & ([scriptblock]::Create((irm https://github.com/winddxr/win-symlinks/releases/latest/download/install.ps1))) -Version v0.0.4
.EXAMPLE
    .\install.ps1
    # Offline when the three executables are next to this script.
#>
# Isolate preferences, functions and temporary variables from an iex caller.
& {
    [CmdletBinding()]
    param(
        [ValidatePattern('^(latest|v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$')]
        [string]$Version = 'latest',
        [string]$InstallDir = '',
        [Parameter(DontShow = $true)]
        [string]$SourceDir = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $Binaries = @('ln.exe', 'win-symlinks.exe', 'win-symlinks-broker.exe')
    $ServiceName = 'WinSymlinksBroker'
    $Repository = 'winddxr/win-symlinks'

    function Write-Step([string]$Message) {
        Write-Host "==> $Message" -ForegroundColor Cyan
    }

    function Get-ReleaseTag([string]$RequestedVersion) {
        if ($RequestedVersion -ne 'latest') { return 'v' + $RequestedVersion.TrimStart('v') }
        $api = "https://api.github.com/repos/$Repository/releases"
        $headers = @{ 'User-Agent' = 'win-symlinks-installer'; Accept = 'application/vnd.github+json' }
        try {
            $release = Invoke-RestMethod "$api/latest" -Headers $headers -TimeoutSec 30
        } catch {
            # /latest excludes prereleases. Older v0 tags were all prereleases.
            # Only fall back on 404, never on rate limits or network errors.
            $response = $_.Exception.PSObject.Properties['Response']
            if ($null -eq $response -or $null -eq $response.Value -or [int]$response.Value.StatusCode -ne 404) { throw }
            # Invoke-RestMethod emits a JSON array as one pipeline object.
            # Assign it directly so the following pipeline enumerates releases.
            $releases = Invoke-RestMethod "$api`?per_page=100" -Headers $headers -TimeoutSec 30
            $release = $releases | Where-Object { -not $_.draft } |
                Sort-Object published_at -Descending | Select-Object -First 1
            Write-Warning 'No stable release exists yet; selecting the newest published prerelease.'
        }
        if ($null -eq $release -or $release.tag_name -cnotmatch '^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
            throw 'No supported release found. Specify a published tag with -Version v<VERSION>.'
        }
        return [string]$release.tag_name
    }

    function Assert-ArchiveChecksum([string]$Archive, [string]$Checksums, [string]$Asset) {
        $matchesForAsset = @(Get-Content -LiteralPath $Checksums | Where-Object {
            $_ -cmatch ('^[0-9a-fA-F]{64}  ' + [regex]::Escape($Asset) + '$')
        })
        if ($matchesForAsset.Count -ne 1) { throw "Expected exactly one SHA-256 checksum for $Asset. Nothing was installed." }
        $expected = $matchesForAsset[0].Substring(0, 64)
        if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ine $expected) {
            throw "SHA-256 mismatch for $Asset. Nothing was installed."
        }
    }

    function Get-ReleaseBinaries([string]$Directory, [string]$RequestedVersion) {
        $tag = Get-ReleaseTag $RequestedVersion
        $asset = "win-symlinks-$tag-x86_64-windows.zip"
        $baseUrl = "https://github.com/$Repository/releases/download/$tag"
        $archive = Join-Path $Directory $asset
        $checksums = Join-Path $Directory 'checksums-sha256.txt'
        Write-Step "Downloading $tag (x64)"
        foreach ($name in @($asset, 'checksums-sha256.txt')) {
            Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$name" -OutFile (Join-Path $Directory $name) `
                -Headers @{ 'User-Agent' = 'win-symlinks-installer' } -TimeoutSec 120
        }
        Assert-ArchiveChecksum $archive $checksums $asset
        # Extract only exact root entries, never archive paths or bundled scripts.
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            foreach ($name in $Binaries) {
                $entries = @($zip.Entries | Where-Object { $_.FullName -ceq $name })
                if ($entries.Count -ne 1 -or $entries[0].Length -eq 0) {
                    throw "Release archive must contain exactly one nonempty $name at its root."
                }
            }
            foreach ($name in $Binaries) {
                $entry = $zip.Entries | Where-Object { $_.FullName -ceq $name }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $Directory $name))
            }
        } finally { $zip.Dispose() }
    }

    function Assert-NotReparsePoint([string]$Path) {
        if (Test-Path -LiteralPath $Path) {
            if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing a symbolic link or junction in the installation path: $Path"
            }
        }
    }

    function Initialize-InstallDirectory([string]$Directory, [string]$ProgramFilesDirectory) {
        # The LocalSystem executable needs administrator-controlled ancestors.
        if ([IO.Path]::GetDirectoryName($Directory) -ine $ProgramFilesDirectory) {
            throw '-InstallDir must be a direct child of the native Program Files directory.'
        }
        Assert-NotReparsePoint $ProgramFilesDirectory
        Assert-NotReparsePoint $Directory
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
        $acl.SetOwner($admins)
        foreach ($rule in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
            $sid = New-Object Security.Principal.SecurityIdentifier $rule[0]
            $access = New-Object Security.AccessControl.FileSystemAccessRule(
                $sid, $rule[1], 'ContainerInherit, ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($access)
        }
        Set-Acl -LiteralPath $Directory -AclObject $acl
        foreach ($name in $Binaries) { Assert-NotReparsePoint (Join-Path $Directory $name) }
    }

    function Remove-WorkDirectory([string]$Directory, [string]$Parent) {
        $fullPath = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($fullPath) -ine [IO.Path]::GetFullPath($Parent).TrimEnd('\') -or
            [IO.Path]::GetFileName($fullPath) -notmatch '^\.win-symlinks-[0-9a-f]{32}$') {
            throw "Refusing to clean up an unexpected directory: $Directory"
        }
        Assert-NotReparsePoint $fullPath
        if (Test-Path -LiteralPath $fullPath) { Remove-Item -LiteralPath $fullPath -Recurse -Force }
    }

    function Get-UpdatedPath([string]$CurrentPath, [string]$Directory) {
        $otherEntries = @($CurrentPath -split ';' | Where-Object {
            $_ -and [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')).TrimEnd('\') -ine $Directory.TrimEnd('\')
        })
        return (@($Directory) + $otherEntries) -join ';'
    }

    function Send-EnvironmentChange {
        try {
            if (-not ('WinSymlinks.InstallerEnvironment' -as [type])) {
                Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace WinSymlinks {
    public static class InstallerEnvironment {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr window, uint message,
            UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
    }
}
'@
            }
            $result = [UIntPtr]::Zero
            [void][WinSymlinks.InstallerEnvironment]::SendMessageTimeout(
                [IntPtr]0xffff, 0x001a, [UIntPtr]::Zero, 'Environment', 2, 1000, [ref]$result)
        } catch {
            Write-Warning "PATH was saved; sign out and back in if new terminals still use the old PATH. $($_.Exception.Message)"
        }
    }

    function Invoke-ManagementCommand([string]$Executable, [string[]]$Arguments) {
        & $Executable @Arguments
        if ($LASTEXITCODE -ne 0) { throw "win-symlinks $($Arguments -join ' ') failed (exit $LASTEXITCODE)." }
    }

    function Get-BrokerRegistration {
        return Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    }

    function Get-MachinePath { return [Environment]::GetEnvironmentVariable('Path', 'Machine') }
    function Set-MachinePath([string]$Value) { [Environment]::SetEnvironmentVariable('Path', $Value, 'Machine') }

    function Stop-Broker {
        $service = Get-Service -Name $ServiceName
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
    }

    function Install-Binaries([string]$Source, [string]$Destination, [string]$WorkDirectory) {
        foreach ($name in $Binaries) {
            if (-not (Test-Path -LiteralPath (Join-Path $Source $name) -PathType Leaf)) { throw "Missing $name in $Source." }
        }
        $broker = Join-Path $Destination 'win-symlinks-broker.exe'
        $cli = Join-Path $Destination 'win-symlinks.exe'
        $registration = Get-BrokerRegistration
        if ($null -ne $registration -and $registration.PathName.Trim('"') -ine $broker) {
            throw "$ServiceName belongs to another installation ($($registration.PathName)). Uninstall that service first."
        }
        $wasRunning = $null -ne $registration -and $registration.State -ne 'Stopped'
        $oldPath = Get-MachinePath
        $changed = @()
        $createdService = $false
        $backup = Join-Path $WorkDirectory 'backup'
        New-Item -ItemType Directory -Path $backup | Out-Null
        # Save every backup before stopping the broker or modifying any binary.
        foreach ($name in $Binaries) {
            $path = Join-Path $Destination $name
            if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $backup $name) }
        }
        try {
            if ($null -ne $registration) { Stop-Broker }
            foreach ($name in $Binaries) {
                $path = Join-Path $Destination $name
                # New files inherit the protected directory ACL. A running CLI
                # may lock a file; fail and roll back instead of forcing it closed.
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                $changed += $name
                Copy-Item -LiteralPath (Join-Path $Source $name) -Destination $path
            }
            if ($null -eq $registration) {
                # CreateService can succeed before later configuration fails.
                $createdService = $true
                Invoke-ManagementCommand $cli @('service', 'install')
            }
            Invoke-ManagementCommand $cli @('service', 'start')
            Invoke-ManagementCommand $cli @('service', 'status')
            Set-MachinePath (Get-UpdatedPath $oldPath $Destination)
        } catch {
            $failure = $_
            try {
                if ($createdService -and $null -ne (Get-BrokerRegistration)) {
                    Invoke-ManagementCommand $cli @('service', 'uninstall')
                }
                elseif ($null -ne $registration) { Stop-Broker }
                foreach ($name in $changed) {
                    $path = Join-Path $Destination $name
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                    $saved = Join-Path $backup $name
                    if (Test-Path -LiteralPath $saved) { Copy-Item -LiteralPath $saved -Destination $path }
                }
                Set-MachinePath $oldPath
                if ($wasRunning) { Invoke-ManagementCommand $cli @('service', 'start') }
            } catch {
                # Keep recovery files outside the caller's temporary work tree.
                $recovery = Join-Path $Destination ('recovery-' + [Guid]::NewGuid().ToString('N'))
                Copy-Item -LiteralPath $backup -Destination $recovery -Recurse
                throw "Installation failed: $($failure.Exception.Message) Recovery also failed: $($_.Exception.Message) Previous binaries are in $recovery."
            }
            throw "Installation failed; previous files, PATH and service state were restored. $($failure.Exception.Message)"
        }
        Send-EnvironmentChange
    }

    function Invoke-ElevatedInstall([string]$SourceText, [hashtable]$Parameters, [string]$PowerShellExe) {
        $tempRoot = [IO.Path]::GetTempPath()
        $work = Join-Path $tempRoot ('.win-symlinks-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work | Out-Null
        $sourceFile = Join-Path $work 'installer.ps1'
        $resultFile = Join-Path $work 'result.json'
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($SourceText)
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
            [IO.File]::WriteAllBytes($sourceFile, $bytes)
            $data = @{ Source = $sourceFile; Result = $resultFile; Hash = $hash; Parameters = $Parameters } | ConvertTo-Json -Compress
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($data))
            # Verify and execute the same in-memory bytes. Never directly execute
            # a user-writable temporary script from the administrator process.
            $command = @'
$ErrorActionPreference = 'Stop'
$data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
$result = @{ Success = $false; Message = '' }
try {
    $bytes = [IO.File]::ReadAllBytes($data.Source)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
    if ($hash -cne $data.Hash) { throw 'Installer changed while waiting for administrator approval. Run the command again.' }
    $parameters = @{}
    foreach ($property in $data.Parameters.PSObject.Properties) { $parameters[$property.Name] = $property.Value }
    & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString($bytes))) @parameters
    $result.Success = $true
} catch { $result.Message = $_.Exception.Message }
# CreateNew refuses existing files, including symlinks, in the user's temp dir.
$stream = [IO.File]::Open($data.Result, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$writer = New-Object IO.StreamWriter($stream, [Text.Encoding]::UTF8)
try { $writer.Write(($result | ConvertTo-Json -Compress)) } finally { $writer.Dispose() }
if (-not $result.Success) { exit 1 }
'@
            $command = $command.Replace('__PAYLOAD__', $payload)
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            Write-Step 'Approve the Windows administrator prompt to install the broker service'
            $process = Start-Process -FilePath $PowerShellExe -Verb RunAs -WindowStyle Hidden `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -Wait -PassThru
            if (-not (Test-Path -LiteralPath $resultFile)) {
                throw "Administrator process exited without a result (exit $($process.ExitCode)). Run this command in an Administrator PowerShell for diagnostics."
            }
            $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
            if ($process.ExitCode -ne 0 -or -not $result.Success) { throw $result.Message }
        } finally {
            # This directory is user-writable: never recursively traverse it
            # from an elevated caller, even when cleaning up after failure.
            foreach ($file in @($sourceFile, $resultFile)) {
                if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force }
            }
            if (Test-Path -LiteralPath $work) {
                try { [IO.Directory]::Delete($work) } catch { Write-Warning "Temporary files remain in $work" }
            }
        }
    }

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        [Environment]::OSVersion.Version.Build -lt 22000 -or $PSVersionTable.PSVersion -lt [version]'5.1') {
        throw 'win-symlinks requires Windows 11 and PowerShell 5.1 or newer.'
    }
    $architecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')
    if ($architecture -ne 'AMD64') { throw "No native release is published for $architecture. This installer currently supports x64 Windows 11." }
    $programFilesDirectory = [Environment]::GetEnvironmentVariable('ProgramW6432')
    if (-not $programFilesDirectory) { $programFilesDirectory = $env:ProgramFiles }
    $programFilesDirectory = [IO.Path]::GetFullPath($programFilesDirectory).TrimEnd('\')
    if (-not $InstallDir) { $InstallDir = Join-Path $programFilesDirectory 'win-symlinks' }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    if (-not $SourceDir -and -not $PSBoundParameters.ContainsKey('Version') -and $PSCommandPath) {
        $localRoot = Split-Path -Parent $PSCommandPath
        $localFiles = @($Binaries | Where-Object { Test-Path -LiteralPath (Join-Path $localRoot $_) -PathType Leaf })
        if ($localFiles.Count -gt 0 -and $localFiles.Count -ne $Binaries.Count) {
            throw 'Incomplete offline package: all three executables must be next to install.ps1.'
        }
        if ($localFiles.Count -eq $Binaries.Count) { $SourceDir = $localRoot }
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not [Environment]::Is64BitProcess) { $powerShellExe = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe' }
        Invoke-ElevatedInstall $MyInvocation.MyCommand.ScriptBlock.ToString() @{
            Version = $Version; InstallDir = $InstallDir; SourceDir = $SourceDir
        } $powerShellExe
    } else {
        $mutex = New-Object Threading.Mutex($false, 'Global\WinSymlinksInstaller')
        $locked = $false
        $work = $null
        try {
            try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
            if (-not $locked) { throw 'Another win-symlinks installer is running. Wait for it to finish.' }
            Initialize-InstallDirectory $InstallDir $programFilesDirectory
            $work = Join-Path $InstallDir ('.win-symlinks-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $work | Out-Null
            if (-not $SourceDir) {
                Get-ReleaseBinaries $work $Version
            } else {
                foreach ($name in $Binaries) {
                    Copy-Item -LiteralPath (Join-Path $SourceDir $name) -Destination (Join-Path $work $name)
                }
            }
            $SourceDir = $work
            Write-Step "Installing to $InstallDir"
            Install-Binaries $SourceDir $InstallDir $work
        } finally {
            if ($work) { Remove-WorkDirectory $work $InstallDir }
            if ($locked) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
    $env:Path = Get-UpdatedPath $env:Path $InstallDir
    Write-Host "Installed win-symlinks in $InstallDir. The broker is running." -ForegroundColor Green
    Write-Host 'Ready in this terminal. Open a new terminal in other applications, then run: win-symlinks.exe doctor'
    $resolved = Get-Command ln -ErrorAction SilentlyContinue
    if ($resolved -and $resolved.Source -ine (Join-Path $InstallDir 'ln.exe')) {
        Write-Warning "'ln' resolves to $($resolved.Definition). Use ln.exe explicitly and check Get-Command ln -All."
    }
} @args
