param([Parameter(Mandatory=$true)][string]$Root, [switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = [IO.Path]::GetFullPath($Root)
$setupCommand = "& '" + (Join-Path $Root 'bin\opencu.cmd').Replace("'", "''") + "' setup agent-desktop"

function Invoke-PreparedHelper([string]$Helper, [string]$Mode) {
    $process = New-Object Diagnostics.Process
    try {
        $process.StartInfo.FileName = $Helper
        $process.StartInfo.Arguments = $Mode
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.StartInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(15000)) { $process.Kill(); throw 'Agent desktop helper timed out.' }
        $result = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json
        if ($process.ExitCode -ne 0) {
            $failure = New-Object InvalidOperationException($result.message)
            if ($result.setupRequired) { $failure.Data['setupRequired'] = $true }
            throw $failure
        }
        return $result
    } finally { $process.Dispose() }
}

function Prepare-AgentDesktop {
    if (![Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ((New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Agent desktop preparation requires a normal, non-elevated terminal. Run in PowerShell: $setupCommand"
    }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Reflection;
public class OpenCUTypeLibrary : ITypeLibImporterNotifySink {
    [DllImport("oleaut32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
    static extern void LoadTypeLibEx(string file, int kind, out System.Runtime.InteropServices.ComTypes.ITypeLib library);
    [DllImport("wtsapi32.dll", SetLastError=true)]
    public static extern bool WTSIsChildSessionsEnabled(out bool enabled);
    public void ReportEvent(ImporterEventKind kind, int code, string text) {
        if (kind == ImporterEventKind.ERROR_REFTOINVALIDTYPELIB) throw new Exception("Invalid system RDP type library.");
    }
    public Assembly ResolveRef(object library) { throw new Exception("Unexpected external type library dependency."); }
    public static void Import(string systemLibrary, string destination) {
        System.Runtime.InteropServices.ComTypes.ITypeLib library;
        LoadTypeLibEx(systemLibrary, 2, out library);
        try {
            var builder = new TypeLibConverter().ConvertTypeLibToAssembly(library, destination,
                TypeLibImporterFlags.None, new OpenCUTypeLibrary(), null, null, "MSTSCLib", null);
            builder.Save(System.IO.Path.GetFileName(destination));
        } finally { Marshal.ReleaseComObject(library); }
    }
}
'@
    $enabled = $false
    if (![OpenCUTypeLibrary]::WTSIsChildSessionsEnabled([ref]$enabled)) {
        throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error()))
    }
    if (!$enabled) {
        # This branch must refuse before any elevation when called by the runtime.
        if ($PrepareOnly) {
            $missing = New-Object InvalidOperationException("Windows child sessions are disabled; one-time setup is required. Run in PowerShell: $setupCommand")
            $missing.Data['setupRequired'] = $true
            throw $missing
        }
        # Constant payload only: no user-writable helper, engine or compiler is elevated.
        $enable = @'
$ErrorActionPreference='Stop'
Add-Type 'using System; using System.Runtime.InteropServices; public class EnableOpenCUChild { [DllImport("wtsapi32.dll", SetLastError=true)] public static extern bool WTSEnableChildSessions(bool enabled); }'
if (![EnableOpenCUChild]::WTSEnableChildSessions($true)) { exit 1 }
'@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($enable))
        $powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        Write-Host 'Windows will now ask to let Windows PowerShell make changes; this only turns on child sessions.'
        $admin = Start-Process -FilePath $powershell -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
        if ($admin.ExitCode -ne 0) { throw 'Windows did not enable child sessions.' }
        if (![OpenCUTypeLibrary]::WTSIsChildSessionsEnabled([ref]$enabled) -or !$enabled) { throw 'Child sessions are still disabled.' }
    }
    $source = Join-Path $Root 'scripts\agent-desktop'
    $output = Join-Path $Root '.build\win\agent-desktop'
    $compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    if (!(Test-Path -LiteralPath $compiler)) { throw 'Built-in .NET Framework compiler is missing.' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $rootHash = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Root.ToUpperInvariant()))).Replace('-', '').Substring(0, 16) }
    finally { $hash.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Global\OpenCU-AgentDesktop-Setup-' + $identity.User.Value + '-' + $rootHash))
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (!$acquired) { throw 'Another agent desktop preparation is still running.' }
        [void][IO.Directory]::CreateDirectory($output)
        if (([IO.File]::GetAttributes($output) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Agent desktop helper directory must not be a reparse point.' }
        # Change only the DACL. Set-Acl on a new descriptor also writes owner/group
        # and requires privileges the ordinary user does not have on a second run.
        $acl = [IO.Directory]::GetAccessControl($output, [Security.AccessControl.AccessControlSections]::Access)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { $acl.RemoveAccessRuleSpecific($rule) }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity.User, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        [IO.Directory]::SetAccessControl($output, $acl)
        $library = Join-Path $output 'OpenCU.Rdp.dll'
        $helper = Join-Path $output 'OpenCU.AgentDesktop.exe'
        # Another process may have finished preparation while we held the mutex.
        # Do not rebuild a current helper (which may now be serving a desktop).
        $currentMatches = $false
        $version = (Get-Content -Raw -LiteralPath (Join-Path $Root 'package.json') | ConvertFrom-Json).version
        try {
            $current = Get-Content -Raw -LiteralPath (Join-Path $output 'receipt.json') | ConvertFrom-Json
            $currentMatches = $current.version -eq $version
            foreach ($name in @('Host.cs', 'setup.ps1')) {
                if ($current.sources.$name -ne (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $source $name)).Hash) { $currentMatches = $false }
            }
            foreach ($name in @('OpenCU.AgentDesktop.exe', 'OpenCU.Rdp.dll')) {
                if ($current.files.$name -ne (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $output $name)).Hash) { $currentMatches = $false }
            }
        } catch { $currentMatches = $false }
        if ($currentMatches) {
            try {
                $existing = Invoke-PreparedHelper $helper 'probe'
                if (!$existing.available) { throw 'Prepared helper did not confirm availability.' }
                return @{ prepared=$true; taskName=$existing.taskName }
            } catch {
                if (!$_.Exception.GetBaseException().Data.Contains('setupRequired')) { throw }
            }
        }
        Remove-Item -LiteralPath (Join-Path $output 'receipt.json') -Force -ErrorAction SilentlyContinue
        Push-Location $output
        try {
            [OpenCUTypeLibrary]::Import((Join-Path ([Environment]::SystemDirectory) 'mstscax.dll'), $library)
            $build = & $compiler /nologo /target:winexe /platform:x64 /optimize+ "/out:$helper" "/reference:$library" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:Microsoft.CSharp.dll (Join-Path $source 'Host.cs')
            if ($LASTEXITCODE -ne 0) { throw ('Agent desktop compilation failed: ' + ($build -join "`n")) }
        } finally { Pop-Location }
        $result = Invoke-PreparedHelper $helper 'register'
        if (!$result.ok) { throw 'Agent desktop task registration was not confirmed.' }
        $sources = @{}
        foreach ($name in @('Host.cs', 'setup.ps1')) { $sources[$name] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $source $name)).Hash.ToLowerInvariant() }
        $files = @{}
        foreach ($name in @('OpenCU.AgentDesktop.exe', 'OpenCU.Rdp.dll')) { $files[$name] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $output $name)).Hash.ToLowerInvariant() }
        $version = (Get-Content -Raw -LiteralPath (Join-Path $Root 'package.json') | ConvertFrom-Json).version
        $receipt = @{ version=$version; sources=$sources; files=$files; taskName=$result.taskName } | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText((Join-Path $output 'receipt.json'), $receipt, (New-Object Text.UTF8Encoding($false)))
        return @{ prepared=$true; taskName=$result.taskName }
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
try {
    $prepared = Prepare-AgentDesktop
    if ($PrepareOnly) { $prepared | ConvertTo-Json -Compress }
    else { Write-Output 'Agent desktop is ready. If this sign-in predates enabling child sessions, sign out and back in once. Smart-card-only sign-in is unsupported. OpenCU never requests a session password.' }
} catch {
    $cause = $_.Exception.GetBaseException()
    if ($PrepareOnly) {
        @{ event='failure'; code='AGENT_DESKTOP_UNAVAILABLE'; setupRequired=$cause.Data.Contains('setupRequired'); message=$cause.Message } | ConvertTo-Json -Compress
    } else { [Console]::Error.WriteLine($cause.Message) }
    exit 1
}
