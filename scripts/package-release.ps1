[CmdletBinding()]
param(
    [ValidatePattern('^(|v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$')]
    [string]$Version = '',
    [string]$BinaryDir = '',
    [string]$OutputDir = '',
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot

Push-Location $workspace
try {
    $metadataText = & cargo metadata --locked --no-deps --format-version 1
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read Cargo package metadata.' }
    $metadata = $metadataText | ConvertFrom-Json
} finally {
    Pop-Location
}
$package = @($metadata.packages | Where-Object { $_.name -eq 'win-symlinks' })
if ($package.Count -ne 1) { throw 'Expected exactly one win-symlinks package.' }
$packageVersion = $package[0].version
if (-not $Version) { $Version = "v$packageVersion" }
if ($Version -cne "v$packageVersion") {
    throw "Release tag $Version does not match Cargo package version v$packageVersion. Update the package version and Cargo.lock before tagging."
}
if ($ValidateOnly) {
    Write-Host "Validated release tag $Version."
    return
}

if (-not $BinaryDir) { $BinaryDir = Join-Path $workspace 'target\release' }
if (-not $OutputDir) { $OutputDir = Join-Path $workspace 'dist' }
$BinaryDir = [IO.Path]::GetFullPath($BinaryDir)
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$installer = Join-Path $workspace 'install.ps1'
$brokerRuntime = Join-Path $workspace 'packaging\broker-runtime'
$fullFiles = @{
    'ln.exe' = Join-Path $BinaryDir 'ln.exe'
    'win-symlinks.exe' = Join-Path $BinaryDir 'win-symlinks.exe'
    'win-symlinks-broker.exe' = Join-Path $BinaryDir 'win-symlinks-broker.exe'
    'install.ps1' = $installer
}
$brokerFiles = @{
    'win-symlinks-broker.exe' = Join-Path $BinaryDir 'win-symlinks-broker.exe'
    'install-broker.ps1' = Join-Path $brokerRuntime 'install-broker.ps1'
    'uninstall-broker.ps1' = Join-Path $brokerRuntime 'uninstall-broker.ps1'
    'README-broker.md' = Join-Path $brokerRuntime 'README-broker.md'
}
foreach ($source in @($fullFiles.Values) + @($brokerFiles.Values)) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-Item -LiteralPath $source).Length -eq 0) {
        throw "Required release file is missing or empty: $source"
    }
}
foreach ($command in @('ln', 'win-symlinks')) {
    $actualVersion = & (Join-Path $BinaryDir "$command.exe") --version
    if ($LASTEXITCODE -ne 0 -or "$actualVersion".Trim() -cne "$command $packageVersion") {
        throw "Binary version mismatch for $command.exe: expected '$command $packageVersion', got '$actualVersion'. Run cargo build --locked --release --workspace first."
    }
}

$fullArchive = "win-symlinks-$Version-x86_64-windows.zip"
$brokerArchive = "win-symlinks-broker-$Version-x86_64-windows.zip"
$assets = @($fullArchive, $brokerArchive, 'install.ps1')
$allowedNames = $assets + @('checksums-sha256.txt')
if (Test-Path -LiteralPath $OutputDir) {
    if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) { throw 'OutputDir must be a directory.' }
    if ((Get-Item -LiteralPath $OutputDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'OutputDir must not be a symbolic link or junction.'
    }
    foreach ($item in Get-ChildItem -LiteralPath $OutputDir -Force) {
        if ($item.Name -cnotin $allowedNames -or $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unexpected output entry: $($item.FullName). Choose an empty -OutputDir to avoid mixing release assets."
        }
    }
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-ReleaseArchive([string]$Path, [hashtable]$Files) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($name in ($Files.Keys | Sort-Object)) {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive, $Files[$name], $name, [IO.Compression.CompressionLevel]::Optimal)
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

Write-ReleaseArchive (Join-Path $OutputDir $fullArchive) $fullFiles
Write-ReleaseArchive (Join-Path $OutputDir $brokerArchive) $brokerFiles
Copy-Item -LiteralPath $installer -Destination (Join-Path $OutputDir 'install.ps1') -Force
$checksums = foreach ($asset in $assets) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $OutputDir $asset) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $asset"
}
[IO.File]::WriteAllLines((Join-Path $OutputDir 'checksums-sha256.txt'), $checksums, (New-Object Text.UTF8Encoding($false)))
Write-Host "Packaged $Version in $OutputDir."
