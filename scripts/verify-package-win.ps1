# Read-only acceptance. Requires the user's unlocked Windows desktop, no network.
[CmdletBinding(DefaultParameterSetName='Zip')]
param(
    [Parameter(Mandatory=$true, ParameterSetName='Zip')][string]$Zip,
    [Parameter(ParameterSetName='Zip')][string]$Installer,
    [Parameter(Mandatory=$true, ParameterSetName='Installed')][string]$InstallDirectory
)
$ErrorActionPreference = 'Stop'
$previousLocalAppData = $env:LOCALAPPDATA
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ocu-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$process = $null
$summary = [ordered]@{ test = 'windows-package-read-only'; ok = $false; networkUsed = $false; inputCalls = 0 }
$failure = $null

function Read-McpResponse([int]$Id) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($true) {
        $read = $process.StandardOutput.ReadLineAsync()
        $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $read.Wait($remaining)) { throw "MCP response $Id timed out." }
        $line = $read.GetAwaiter().GetResult()
        if ($null -eq $line) { throw "MCP closed stdout before response $Id." }
        $reply = $line | ConvertFrom-Json
        if ($reply.id -eq $Id) {
            if ($reply.error) { throw ('MCP error: ' + ($reply.error | ConvertTo-Json -Compress)) }
            return $reply.result
        }
        if ([DateTime]::UtcNow -ge $deadline) { throw "MCP response $Id timed out." }
    }
}
function Send-Mcp($Message) {
    # Process.StandardInput follows the console code page; under UTF-8 (chcp 65001)
    # Windows PowerShell would prefix a BOM that makes the first JSON line invalid.
    if (-not $script:mcpInput) {
        $script:mcpInput = New-Object IO.StreamWriter($process.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
    }
    $script:mcpInput.WriteLine(($Message | ConvertTo-Json -Depth 12 -Compress))
    $script:mcpInput.Flush()
}
function Assert-Keys($Object, [string[]]$Expected) {
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    if (($actual -join ',') -ne (($Expected | Sort-Object) -join ',')) { throw 'Unexpected install manifest keys.' }
}
try {
    if ($env:OS -ne 'Windows_NT') { throw 'This verifier requires Windows.' }
    New-Item -ItemType Directory -Path $temporary | Out-Null
    if ($PSCmdlet.ParameterSetName -eq 'Zip') {
        $Zip = (Resolve-Path -LiteralPath $Zip).Path
        if (-not $Installer) { $Installer = Join-Path (Split-Path -Parent $Zip) 'install.ps1' }
        $Installer = (Resolve-Path -LiteralPath $Installer).Path
        $env:LOCALAPPDATA = Join-Path $temporary 'Local AppData'
        # Exercise spaces and a non-ASCII username without non-ASCII script bytes.
        $env:LOCALAPPDATA += '-' + [char]0x6D4B
        $installerText = [IO.File]::ReadAllText($Installer)
        if (@([IO.File]::ReadAllBytes($Installer) | Where-Object { $_ -gt 127 }).Count) { throw 'Installer is not ASCII.' }
        # Identical code to irm | iex, with the offline parameter supplied to the scriptblock.
        & ([ScriptBlock]::Create($installerText)) -LocalZip $Zip
        $InstallDirectory = Join-Path $env:LOCALAPPDATA 'OpenCU'
        $summary.installedFromLocalZip = $true
    } else {
        $InstallDirectory = (Resolve-Path -LiteralPath $InstallDirectory).Path
        $summary.installedFromLocalZip = $false
    }
    $manifestPath = Join-Path $InstallDirectory 'opencu.json'
    if ($PSCmdlet.ParameterSetName -eq 'Zip') {
        $before = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        $corrupt = Join-Path $temporary 'corrupt.zip'
        Copy-Item -LiteralPath $Zip -Destination $corrupt
        [IO.File]::AppendAllText($corrupt, 'fixture corruption')
        $rejected = $false
        try { & ([ScriptBlock]::Create($installerText)) -LocalZip $corrupt }
        catch {
            if ($_.Exception.Message -notmatch 'SHA-256 mismatch') { throw }
            $rejected = $true
        }
        if (-not $rejected -or (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $before) {
            throw 'Hash mismatch did not preserve the existing install.'
        }
        $summary.hashMismatchPreservesInstall = $true
    }
    $bytes = [IO.File]::ReadAllBytes($manifestPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'Manifest must be UTF-8 without BOM.' }
    $manifest = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    Assert-Keys $manifest @('name', 'version', 'platform', 'mcp')
    Assert-Keys $manifest.mcp @('command', 'args')
    if ($manifest.name -ne 'opencu' -or $manifest.platform -ne 'win32' -or $manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid manifest identity/version/platform.' }
    if ($manifest.mcp.args -isnot [Array] -or $manifest.mcp.args.Count -ne 1) { throw 'Expected one absolute MCP server argument.' }
    foreach ($file in @($manifest.mcp.command, $manifest.mcp.args[0])) {
        if (-not [IO.Path]::IsPathRooted($file) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'Manifest paths must be absolute existing files.' }
    }
    if ($manifest.mcp.command -ne (Join-Path $InstallDirectory 'node\node.exe') -or $manifest.mcp.args[0] -ne (Join-Path $InstallDirectory 'src\server.mjs')) { throw 'Manifest does not refer to this installation.' }
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $manifest.mcp.command
    # Windows command-line quoting for one file path, with no shell. A Windows
    # filename cannot contain a quote, and the server filename cannot end in '\'.
    $process.StartInfo.Arguments = '"' + $manifest.mcp.args[0] + '"'
    $process.StartInfo.WorkingDirectory = $temporary
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $process.StartInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    # Use a fresh home and no PATH tools, NODE_PATH, or inherited Node startup hooks.
    foreach ($name in @('NODE_OPTIONS', 'NODE_PATH')) { $process.StartInfo.EnvironmentVariables.Remove($name) }
    $process.StartInfo.EnvironmentVariables['HOME'] = $temporary
    $process.StartInfo.EnvironmentVariables['USERPROFILE'] = $temporary
    $process.StartInfo.EnvironmentVariables['PATH'] = "$env:SystemRoot\System32;$env:SystemRoot"
    [void]$process.Start()
    $diagnostics = $process.StandardError.ReadToEndAsync()
    Send-Mcp @{ jsonrpc='2.0'; id=1; method='initialize'; params=@{protocolVersion='2024-11-05'; capabilities=@{}; clientInfo=@{name='opencu-package-verifier'; version='1.0'}} }
    $initialized = Read-McpResponse 1
    if ($initialized.serverInfo.version -ne $manifest.version) { throw 'MCP serverInfo.version differs from install manifest.' }
    if ($initialized.serverInfo.name -ne 'opencu') { throw 'Unexpected MCP server name.' }
    Send-Mcp @{jsonrpc='2.0'; method='notifications/initialized'}
    Send-Mcp @{jsonrpc='2.0'; id=2; method='tools/list'; params=@{}}
    $listing = Read-McpResponse 2
    if ($listing.tools.Count -ne 13 -or 'drag' -notin $listing.tools.name) { throw 'Expected 13 MCP tools including drag.' }
    if (($listing.tools | Where-Object name -eq 'drag').description -match 'Not yet supported on Windows') { throw 'Drag is still marked unsupported.' }
    Send-Mcp @{jsonrpc='2.0'; id=3; method='tools/call'; params=@{name='list_apps'; arguments=@{}}}
    $apps = Read-McpResponse 3
    if ($apps.isError -or -not $apps.content) { throw 'Read-only list_apps did not succeed.' }
    $summary.version = $manifest.version
    $summary.toolCount = $listing.tools.Count
    $summary.listAppsSucceeded = $true
    $summary.serverVersionMatches = $true
    if ($PSCmdlet.ParameterSetName -eq 'Zip') {
        $rejected = $false
        try { & ([ScriptBlock]::Create($installerText)) -LocalZip $Zip }
        catch {
            if ($_.Exception.Message -notmatch 'Close agent sessions') { throw }
            $rejected = $true
        }
        if (-not $rejected -or (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $before) {
            throw 'An update with the runtime in use did not preserve the old install.'
        }
        Send-Mcp @{jsonrpc='2.0'; id=4; method='tools/list'; params=@{}}
        if ((Read-McpResponse 4).tools.Count -ne 13) { throw 'Old MCP session stopped working after refused update.' }
        $summary.inUseUpdatePreservesInstall = $true
    }
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(10000)) { throw 'MCP did not shut down after EOF.' }
    if ($process.ExitCode -ne 0) { throw 'MCP exited unsuccessfully.' }
    if ($PSCmdlet.ParameterSetName -eq 'Zip') {
        & ([ScriptBlock]::Create($installerText)) -LocalZip $Zip
        if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $before) { throw 'Reinstall changed the manifest unexpectedly.' }
        $summary.closedSessionUpdateSucceeded = $true
    }
    $summary.ok = $true
} catch {
    $failure = $_
    $summary.error = $_.Exception.Message
} finally {
    if ($process) {
        try {
            if (-not $process.HasExited) {
                $process.StandardInput.Close()
                if (-not $process.WaitForExit(5000)) { $process.Kill(); [void]$process.WaitForExit(5000) }
            }
        } catch { }
        $process.Dispose()
    }
    $env:LOCALAPPDATA = $previousLocalAppData
    if (Test-Path -LiteralPath $temporary) {
        try { Remove-Item -LiteralPath $temporary -Recurse -Force } catch {
            $summary.ok = $false
            $summary.cleanupError = $_.Exception.Message
            if (-not $failure) { $failure = $_ }
        }
    }
}
$summary | ConvertTo-Json -Depth 5
if ($failure) { throw $failure }
