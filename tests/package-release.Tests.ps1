[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$packager = Join-Path $workspace 'scripts\package-release.ps1'
$binaryDir = Join-Path $workspace 'target\release'
$testParent = Join-Path $workspace 'target'
$testRoot = Join-Path $testParent ('release-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$output = Join-Path $testRoot 'assets'
$passed = 0
$failed = 0

function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected [$Expected], got [$Actual]." }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected failure: $($_.Exception.Message)" }
        return
    }
    throw "Expected an error matching $Pattern."
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Archive([string]$Path, [hashtable]$ExpectedFiles) {
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        Assert-Equal $archive.Entries.Count $ExpectedFiles.Count
        foreach ($entry in $archive.Entries) {
            if (-not $ExpectedFiles.ContainsKey($entry.FullName)) { throw "Unexpected ZIP entry: $($entry.FullName)" }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $actualHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
            } finally {
                $sha.Dispose()
                $stream.Dispose()
            }
            Assert-Equal $actualHash (Get-FileHash -LiteralPath $ExpectedFiles[$entry.FullName] -Algorithm SHA256).Hash
        }
    } finally {
        $archive.Dispose()
    }
}

try {
    Test-Case 'tag mismatch fails before creating release assets' {
        Assert-Throws { & $packager -Version 'v999999.0.0' -OutputDir $output } 'does not match Cargo package version'
        Assert-Equal (Test-Path -LiteralPath $output) $false
    }
    Test-Case 'missing binaries fail before creating release assets' {
        Assert-Throws { & $packager -BinaryDir (Join-Path $testRoot 'missing') -OutputDir $output } 'Required release file'
        Assert-Equal (Test-Path -LiteralPath $output) $false
    }
    Test-Case 'wrong executable identity is rejected before packaging' {
        $wrongBinaries = Join-Path $testRoot 'wrong-binaries'
        New-Item -ItemType Directory -Path $wrongBinaries | Out-Null
        foreach ($name in @('ln.exe', 'win-symlinks.exe', 'win-symlinks-broker.exe')) {
            Copy-Item -LiteralPath (Join-Path $binaryDir 'ln.exe') -Destination (Join-Path $wrongBinaries $name)
        }
        Assert-Throws { & $packager -BinaryDir $wrongBinaries -OutputDir $output } 'Binary version mismatch'
        Assert-Equal (Test-Path -LiteralPath $output) $false
    }
    Test-Case 'full ZIP, broker ZIP and standalone installer contain exactly the intended files' {
        & $packager -OutputDir $output
        Assert-Equal @(Get-ChildItem -LiteralPath $output).Count 4
        $fullArchive = @(Get-ChildItem -LiteralPath $output -Filter 'win-symlinks-v*.zip')
        $brokerArchive = @(Get-ChildItem -LiteralPath $output -Filter 'win-symlinks-broker-v*.zip')
        Assert-Equal $fullArchive.Count 1
        Assert-Equal $brokerArchive.Count 1
        Assert-Archive $fullArchive[0].FullName @{
            'ln.exe' = Join-Path $binaryDir 'ln.exe'
            'win-symlinks.exe' = Join-Path $binaryDir 'win-symlinks.exe'
            'win-symlinks-broker.exe' = Join-Path $binaryDir 'win-symlinks-broker.exe'
            'install.ps1' = Join-Path $workspace 'install.ps1'
        }
        Assert-Archive $brokerArchive[0].FullName @{
            'win-symlinks-broker.exe' = Join-Path $binaryDir 'win-symlinks-broker.exe'
            'install-broker.ps1' = Join-Path $workspace 'packaging\broker-runtime\install-broker.ps1'
            'uninstall-broker.ps1' = Join-Path $workspace 'packaging\broker-runtime\uninstall-broker.ps1'
            'README-broker.md' = Join-Path $workspace 'packaging\broker-runtime\README-broker.md'
        }
        Assert-Equal (Get-FileHash -LiteralPath (Join-Path $output 'install.ps1')).Hash (Get-FileHash -LiteralPath (Join-Path $workspace 'install.ps1')).Hash
    }
    Test-Case 'all asset checksums are accepted by the actual installer verifier' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $workspace 'install.ps1'), [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
        $definition = $ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-ArchiveChecksum'
        }, $true)[0]
        . ([scriptblock]::Create($definition.Extent.Text))
        $checksums = Join-Path $output 'checksums-sha256.txt'
        $lines = @(Get-Content -LiteralPath $checksums)
        Assert-Equal $lines.Count 3
        foreach ($line in $lines) {
            $name = ($line -split '  ', 2)[1]
            Assert-ArchiveChecksum (Join-Path $output $name) $checksums $name
        }
    }
    Test-Case 'repacking the same version succeeds without accumulating files' {
        & $packager -OutputDir $output
        Assert-Equal @(Get-ChildItem -LiteralPath $output).Count 4
    }
    Test-Case 'unrelated or stale output files are preserved and block publication' {
        $sentinel = Join-Path $output 'old-release.zip'
        [IO.File]::WriteAllText($sentinel, 'keep this file')
        Assert-Throws { & $packager -OutputDir $output } 'Unexpected output entry'
        Assert-Equal ([IO.File]::ReadAllText($sentinel)) 'keep this file'
    }
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    if ([IO.Path]::GetDirectoryName($resolvedRoot) -ine [IO.Path]::GetFullPath($testParent) -or
        [IO.Path]::GetFileName($resolvedRoot) -notmatch '^release-tests-[0-9a-f]{32}$') {
        throw 'Refusing to clean up an unexpected test directory.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
Write-Host "Release packaging tests: $passed passed, $failed failed."
if ($failed) { exit 1 }
