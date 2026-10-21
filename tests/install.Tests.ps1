# No Pester dependency. All SCM, UAC, network and Machine PATH operations are
# replaced below; real filesystem operations exercise installation and rollback.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$installer = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$Binaries = @('ln.exe', 'win-symlinks.exe', 'win-symlinks-broker.exe')
$ServiceName = 'WinSymlinksBroker'
$Repository = 'winddxr/win-symlinks'
$testParent = Join-Path (Split-Path -Parent $PSScriptRoot) 'target'
New-Item -ItemType Directory -Path $testParent -Force | Out-Null
$testRoot = Join-Path $testParent ('.win-symlinks-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
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
function Reset-Scenario([bool]$Existing = $true, [bool]$Running = $true) {
    $script:caseRoot = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
    $script:source = Join-Path $caseRoot 'source'
    $script:destination = Join-Path $caseRoot "install [test] O'Brien"
    $script:work = Join-Path $caseRoot 'work'
    New-Item -ItemType Directory -Path $source, $destination, $work | Out-Null
    foreach ($name in $Binaries) {
        [IO.File]::WriteAllText((Join-Path $source $name), "new $name")
        if ($Existing) { [IO.File]::WriteAllText((Join-Path $destination $name), "old $name") }
    }
    $script:registration = $null
    if ($Existing) {
        $script:registration = [pscustomobject]@{ PathName = '"' + (Join-Path $destination 'win-symlinks-broker.exe') + '"'; State = 'Stopped' }
        if ($Running) { $script:registration.State = 'Running' }
    }
    $script:machinePath = 'C:\Windows;C:\Other'
    $script:actions = New-Object 'Collections.Generic.List[string]'
    $script:failAction = ''
    $script:failCount = 0
    $script:apiMode = 'stable'
    $script:stableTag = 'v1.2.3'
    $script:apiCalls = New-Object 'Collections.Generic.List[string]'
}
function Assert-InstalledFiles([string]$Prefix) {
    foreach ($name in $Binaries) { Assert-Equal ([IO.File]::ReadAllText((Join-Path $destination $name))) "$Prefix $name" }
}

# Mock every external mutation, including UAC. An unexpected Start-Process must
# fail instead of displaying an administrator prompt on a developer's machine.
$elevationMode = ''
function Start-Process([string]$FilePath, [string]$Verb, [string]$WindowStyle, [string]$ArgumentList, [switch]$Wait, [switch]$PassThru) {
    if (-not $script:elevationMode) { throw 'Unexpected process launch in installer tests.' }
    Assert-Equal $Verb 'RunAs'
    Assert-Equal $WindowStyle 'Hidden'
    if ($script:elevationMode -eq 'cancel') { throw 'UAC canceled' }
    if ($script:elevationMode -eq 'tamper') {
        $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($ArgumentList -split ' ')[-1]))
        $payload = [regex]::Match($command, "FromBase64String\('([^']+)'\)").Groups[1].Value
        $data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        [IO.File]::WriteAllText($data.Source, "throw 'Unverified script executed'")
    }
    # Exercise the real child protocol without elevation or privileged payloads.
    return Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
        -WindowStyle Hidden -Wait -PassThru
}
function Get-BrokerRegistration { return $script:registration }
function Get-MachinePath { return $script:machinePath }
function Set-MachinePath([string]$Value) { $script:machinePath = $Value }
function Send-EnvironmentChange { $script:actions.Add('broadcast') }
function Set-Acl([string]$LiteralPath, $AclObject) { $script:capturedAcl = $AclObject }
function Stop-Broker { $script:actions.Add('stop'); $script:registration.State = 'Stopped' }
function Invoke-ManagementCommand([string]$Executable, [string[]]$Arguments) {
    $action = $Arguments -join ' '
    $script:actions.Add($action)
    if ($action -eq 'service install') {
        $script:registration = [pscustomobject]@{ PathName = Join-Path $destination 'win-symlinks-broker.exe'; State = 'Stopped' }
    }
    if ($action -eq $script:failAction -and $script:failCount -gt 0) {
        $script:failCount--
        throw "Simulated $action failure"
    }
    if ($action -eq 'service start') { $script:registration.State = 'Running' }
    if ($action -eq 'service uninstall') { $script:registration = $null }
}
function Invoke-RestMethod([string]$Uri, $Headers, $TimeoutSec) {
    $script:apiCalls.Add($Uri)
    if ($script:apiMode -eq 'network-error') { throw 'Network unavailable' }
    if ($Uri.EndsWith('/latest')) {
        if ($script:apiMode -eq 'stable') { return [pscustomobject]@{ tag_name = $script:stableTag } }
        $errorObject = New-Object Exception 'HTTP error'
        $status = 404
        if ($script:apiMode -eq 'rate-limit') { $status = 403 }
        Add-Member -InputObject $errorObject -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $status })
        throw $errorObject
    }
    if ($script:apiMode -eq 'empty') { return ,@() }
    # Match Invoke-RestMethod's single pipeline object containing a JSON array.
    return ,@(
        [pscustomobject]@{ tag_name = 'v0.0.2'; draft = $false; published_at = '2026-10-01' },
        [pscustomobject]@{ tag_name = 'v0.0.4'; draft = $true; published_at = '2026-10-21' },
        [pscustomobject]@{ tag_name = 'v0.0.3'; draft = $false; published_at = '2026-10-20' }
    )
}
function Invoke-WebRequest([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile, $Headers, $TimeoutSec) {
    $script:apiCalls.Add($Uri)
    if ($Uri.EndsWith('.zip')) { Copy-Item -LiteralPath $script:fixtureArchive -Destination $OutFile }
    else { Copy-Item -LiteralPath $script:fixtureChecksums -Destination $OutFile }
}
function New-TestArchive([string[]]$Entries) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:fixtureArchive = Join-Path $caseRoot 'fixture.zip'
    $script:fixtureChecksums = Join-Path $caseRoot 'checksums.txt'
    $zip = [IO.Compression.ZipFile]::Open($fixtureArchive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries) {
            $entry = $zip.CreateEntry($name)
            $writer = New-Object IO.StreamWriter($entry.Open())
            try { $writer.Write("new $name") } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
    $hash = (Get-FileHash -LiteralPath $fixtureArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($fixtureChecksums, "$hash  win-symlinks-v1.2.3-x86_64-windows.zip`n")
}

try {
    Test-Case 'fresh install registers and starts the service, then prepends PATH' {
        Reset-Scenario $false
        Install-Binaries $source $destination $work
        Assert-InstalledFiles 'new'
        Assert-Equal ($actions -join ',') 'service install,service start,service status,broadcast'
        Assert-Equal $machinePath "$destination;C:\Windows;C:\Other"
    }
    Test-Case 'upgrade stops before replacing and does not register twice' {
        Reset-Scenario
        Install-Binaries $source $destination $work
        Assert-InstalledFiles 'new'
        Assert-Equal ($actions -join ',') 'stop,service start,service status,broadcast'
        Assert-Equal $registration.State 'Running'
    }
    Test-Case 'failed upgrade restores all previous binaries, PATH and running state' {
        Reset-Scenario
        $script:failAction = 'service start'; $script:failCount = 1
        Assert-Throws { Install-Binaries $source $destination $work } 'previous files, PATH and service state were restored'
        Assert-InstalledFiles 'old'
        Assert-Equal $machinePath 'C:\Windows;C:\Other'
        Assert-Equal $registration.State 'Running'
    }
    Test-Case 'failed upgrade preserves an originally stopped service' {
        Reset-Scenario $true $false
        $script:failAction = 'service start'; $script:failCount = 1
        Assert-Throws { Install-Binaries $source $destination $work } 'were restored'
        Assert-InstalledFiles 'old'
        Assert-Equal $registration.State 'Stopped'
    }
    Test-Case 'failed first install removes newly registered service and binaries' {
        Reset-Scenario $false
        $script:failAction = 'service start'; $script:failCount = 1
        Assert-Throws { Install-Binaries $source $destination $work } 'were restored'
        Assert-Equal ($null -eq $registration) $true
        foreach ($name in $Binaries) { Assert-Equal (Test-Path -LiteralPath (Join-Path $destination $name)) $false }
    }
    Test-Case 'partial service registration failure is also rolled back' {
        Reset-Scenario $false
        $script:failAction = 'service install'; $script:failCount = 1
        Assert-Throws { Install-Binaries $source $destination $work } 'were restored'
        Assert-Equal ($null -eq $registration) $true
    }
    Test-Case 'locked executable rolls back earlier replacements' {
        Reset-Scenario
        $handle = [IO.File]::Open((Join-Path $destination 'win-symlinks.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { Assert-Throws { Install-Binaries $source $destination $work } 'were restored' }
        finally { $handle.Dispose() }
        Assert-InstalledFiles 'old'
        Assert-Equal $registration.State 'Running'
    }
    Test-Case 'recovery failure preserves backups outside temporary work directory' {
        Reset-Scenario
        $script:failAction = 'service start'; $script:failCount = 2
        Assert-Throws { Install-Binaries $source $destination $work } 'Previous binaries are in'
        $saved = @(Get-ChildItem -LiteralPath $destination -Directory -Filter 'recovery-*')
        Assert-Equal $saved.Count 1
        foreach ($name in $Binaries) { Assert-Equal ([IO.File]::ReadAllText((Join-Path $saved[0].FullName $name))) "old $name" }
    }
    Test-Case 'another broker installation is never taken over' {
        Reset-Scenario
        $registration.PathName = 'C:\Elsewhere\win-symlinks-broker.exe'
        Assert-Throws { Install-Binaries $source $destination $work } 'belongs to another installation'
        Assert-InstalledFiles 'old'
        Assert-Equal $actions.Count 0
    }
    Test-Case 'incomplete source is rejected before service changes' {
        Reset-Scenario
        Remove-Item -LiteralPath (Join-Path $source 'ln.exe')
        Assert-Throws { Install-Binaries $source $destination $work } 'Missing ln.exe'
        Assert-InstalledFiles 'old'
        Assert-Equal $actions.Count 0
    }
    Test-Case 'PATH prepending removes case, slash, quote and environment duplicates' {
        $directory = Join-Path $env:ProgramFiles 'win-symlinks'
        $path = 'C:\Git;"' + $directory.ToUpperInvariant() + '\";%ProgramFiles%\win-symlinks;C:\Tools'
        Assert-Equal (Get-UpdatedPath $path $directory) "$directory;C:\Git;C:\Tools"
        Assert-Equal (Get-UpdatedPath (Get-UpdatedPath $path $directory) $directory) "$directory;C:\Git;C:\Tools"
    }
    Test-Case 'fixed tag requires no release API call' {
        Reset-Scenario
        Assert-Equal (Get-ReleaseTag '0.0.3') 'v0.0.3'
        Assert-Equal $apiCalls.Count 0
    }
    Test-Case 'latest stable release is preferred' {
        Reset-Scenario
        Assert-Equal (Get-ReleaseTag 'latest') 'v1.2.3'
        Assert-Equal $apiCalls.Count 1
    }
    Test-Case 'repeated runs resolve a newly published release instead of reusing the old version' {
        Reset-Scenario
        Assert-Equal (Get-ReleaseTag 'latest') 'v1.2.3'
        $script:stableTag = 'v1.2.4'
        Assert-Equal (Get-ReleaseTag 'latest') 'v1.2.4'
        Assert-Equal $apiCalls.Count 2
        foreach ($uri in $apiCalls) { Assert-Equal $uri 'https://api.github.com/repos/winddxr/win-symlinks/releases/latest' }
    }
    Test-Case 'prerelease-only repositories work and drafts are ignored' {
        Reset-Scenario
        $script:apiMode = 'prerelease'
        Assert-Equal (Get-ReleaseTag 'latest') 'v0.0.3'
        Assert-Equal $apiCalls.Count 2
    }
    Test-Case 'rate limits and network failures do not trigger prerelease fallback' {
        Reset-Scenario
        $script:apiMode = 'rate-limit'
        Assert-Throws { Get-ReleaseTag 'latest' } 'HTTP error'
        Assert-Equal $apiCalls.Count 1
        $script:apiMode = 'network-error'
        Assert-Throws { Get-ReleaseTag 'latest' } 'Network unavailable'
        Assert-Equal $apiCalls.Count 2
    }
    Test-Case 'empty releases produce an actionable error' {
        Reset-Scenario
        $script:apiMode = 'empty'
        Assert-Throws { Get-ReleaseTag 'latest' } 'No supported release found'
    }
    Test-Case 'verified download extracts only the binaries, ignoring archive paths and scripts' {
        Reset-Scenario
        New-TestArchive ($Binaries + @('../escaped.exe', 'install.ps1'))
        Get-ReleaseBinaries $work 'latest'
        foreach ($name in $Binaries) { Assert-Equal ([IO.File]::ReadAllText((Join-Path $work $name))) "new $name" }
        Assert-Equal (Test-Path -LiteralPath (Join-Path $caseRoot 'escaped.exe')) $false
        Assert-Equal (Test-Path -LiteralPath (Join-Path $work 'install.ps1')) $false
        Assert-Equal $apiCalls[1] 'https://github.com/winddxr/win-symlinks/releases/download/v1.2.3/win-symlinks-v1.2.3-x86_64-windows.zip'
    }
    Test-Case 'tampered archive fails before extraction' {
        Reset-Scenario
        New-TestArchive $Binaries
        [IO.File]::AppendAllText($fixtureArchive, 'tampered')
        Assert-Throws { Get-ReleaseBinaries $work 'latest' } 'SHA-256 mismatch'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $work 'ln.exe')) $false
        Assert-Equal $actions.Count 0
    }
    Test-Case 'missing and duplicate checksum entries are refused' {
        Reset-Scenario
        New-TestArchive $Binaries
        $line = [IO.File]::ReadAllText($fixtureChecksums)
        [IO.File]::WriteAllText($fixtureChecksums, $line + $line)
        Assert-Throws { Assert-ArchiveChecksum $fixtureArchive $fixtureChecksums 'win-symlinks-v1.2.3-x86_64-windows.zip' } 'exactly one'
        Assert-Throws { Assert-ArchiveChecksum $fixtureArchive $fixtureChecksums 'other.zip' } 'exactly one'
    }
    Test-Case 'missing and duplicate binary entries are refused before extraction' {
        Reset-Scenario
        New-TestArchive @('ln.exe', 'win-symlinks.exe')
        Assert-Throws { Get-ReleaseBinaries $work 'latest' } 'exactly one nonempty'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $work 'ln.exe')) $false
        Reset-Scenario
        New-TestArchive ($Binaries + @('ln.exe'))
        Assert-Throws { Get-ReleaseBinaries $work 'latest' } 'exactly one nonempty'
    }
    Test-Case 'unsafe installation and cleanup locations are rejected' {
        Assert-Throws { Initialize-InstallDirectory 'C:\Users\Public\win-symlinks' 'C:\Program Files' } 'direct child'
        Assert-Throws { Remove-WorkDirectory $testParent $testParent } 'unexpected directory'
        Assert-Throws { Remove-WorkDirectory $testRoot 'C:\Windows' } 'unexpected directory'
    }
    Test-Case 'install directory ACL grants writes only to SYSTEM and Administrators' {
        Reset-Scenario
        Initialize-InstallDirectory $destination $caseRoot
        Assert-Equal $capturedAcl.AreAccessRulesProtected $true
        Assert-Equal ($capturedAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value) 'S-1-5-32-544'
        $rules = @($capturedAcl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
        Assert-Equal $rules.Count 3
        foreach ($rule in $rules) {
            if ($rule.IdentityReference.Value -eq 'S-1-5-32-545') {
                Assert-Equal ([bool]($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write)) $false
            } else {
                Assert-Equal ([string]$rule.FileSystemRights) 'FullControl'
            }
        }
    }
    Test-Case 'file and iex entry points preserve parameters, offline detection and scoped preferences' {
        Reset-Scenario
        $text = [IO.File]::ReadAllText($installer)
        # Force the UAC branch even on elevated CI runners, then replace its
        # launcher with a terminating observer. No real install can occur.
        $launcher = $ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ElevatedInstall'
        }, $true)[0]
        $observer = @'
function Invoke-ElevatedInstall($SourceText, $Parameters, $PowerShellExe) {
    if ($SourceText -notmatch 'function Install-Binaries') { throw 'Missing captured installer source' }
    throw ('ENTRY|' + $Parameters.Version + '|' + $Parameters.InstallDir + '|' + $Parameters.SourceDir)
}
'@
        $text = $text.Remove($launcher.Extent.StartOffset, $launcher.Extent.Text.Length).Insert($launcher.Extent.StartOffset, $observer)
        $text = $text.Replace('if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {', 'if ($true) {')
        $entryFile = Join-Path $source 'install.ps1'
        [IO.File]::WriteAllText($entryFile, $text)
        $previousPreference = $ErrorActionPreference
        $previousProgress = $ProgressPreference
        $chosenDirectory = Join-Path $env:ProgramFiles 'custom-install'
        Assert-Throws { & $entryFile -InstallDir $chosenDirectory } ([regex]::Escape("ENTRY|latest|$chosenDirectory|$source"))
        Assert-Throws { & $entryFile -Version v1.2.3 -InstallDir $chosenDirectory } ([regex]::Escape("ENTRY|v1.2.3|$chosenDirectory|" ) + '$')
        Assert-Throws { & $entryFile -Version latest -InstallDir $chosenDirectory } ([regex]::Escape("ENTRY|latest|$chosenDirectory|") + '$')
        Assert-Throws { Invoke-Expression $text } 'ENTRY\|latest\|'
        Assert-Equal $ErrorActionPreference $previousPreference
        Assert-Equal $ProgressPreference $previousProgress
    }
    Test-Case 'iex rejects invalid versions without changing caller preferences or launching UAC' {
        $previousPreference = $ErrorActionPreference
        $previousProgress = $ProgressPreference
        $text = [IO.File]::ReadAllText($installer)
        Assert-Throws { & ([scriptblock]::Create($text)) -Version '../invalid' } 'Version'
        Assert-Equal $ErrorActionPreference $previousPreference
        Assert-Equal $ProgressPreference $previousProgress
    }
    Test-Case 'elevation protocol preserves quoted and Unicode arguments without shell interpolation' {
        $script:elevationMode = 'success'
        $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $payload = 'param($Version, $InstallDir, $SourceDir) if ($InstallDir -cne $SourceDir) { throw "Argument changed" }'
        $specialPath = "C:\Program Files\O'Brien [test] ``dollar`$value"
        Invoke-ElevatedInstall $payload @{ Version = 'v1.2.3'; InstallDir = $specialPath; SourceDir = $specialPath } $powerShellExe
        $script:elevationMode = ''
    }
    Test-Case 'elevation protocol returns the child error to the original terminal' {
        $script:elevationMode = 'success'
        $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Assert-Throws { Invoke-ElevatedInstall "throw 'Specific installation failure'" @{} $powerShellExe } 'Specific installation failure'
        $script:elevationMode = ''
    }
    Test-Case 'elevation rejects source tampering while waiting for UAC' {
        $script:elevationMode = 'tamper'
        $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Assert-Throws { Invoke-ElevatedInstall "throw 'Original source'" @{} $powerShellExe } 'Installer changed while waiting'
        $script:elevationMode = ''
    }
    Test-Case 'canceled UAC propagates an error without success' {
        $script:elevationMode = 'cancel'
        Assert-Throws { Invoke-ElevatedInstall '' @{} 'unused.exe' } 'UAC canceled'
        $script:elevationMode = ''
    }
} finally {
    Remove-WorkDirectory $testRoot $testParent
}
Write-Host "Installer tests: $passed passed, $failed failed (PowerShell $($PSVersionTable.PSVersion))."
if ($failed) { exit 1 }
