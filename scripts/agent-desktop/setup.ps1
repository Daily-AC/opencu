param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::Is64BitProcess -ne $true) { throw 'Use 64-bit Windows PowerShell.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ((New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run opencu setup agent-desktop from a normal, non-elevated terminal. Setup requests UAC separately.'
}
$Root = [IO.Path]::GetFullPath($Root)
$source = Join-Path $Root 'scripts\agent-desktop'
$output = Join-Path $Root '.build\win\agent-desktop'
$compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { throw 'AGENT_DESKTOP_UNAVAILABLE: Built-in .NET Framework compiler is missing.' }
New-Item -ItemType Directory -Force -Path $output | Out-Null
# The local derivative contains no elevated code or credentials. Restrict its ACL
# before generating files; the task always runs at the caller's normal integrity.
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner($identity.User)
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity.User, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl -LiteralPath $output -AclObject $acl
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Reflection;
using System.Reflection.Emit;
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
    throw ('AGENT_DESKTOP_UNAVAILABLE: Child-session query failed: ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
}
if (!$enabled) {
    # Constant payload only. Do not elevate a user-writable helper, task, engine,
    # descriptor or compiler. UAC credentials, if required, stay with Windows.
    $enable = @'
$ErrorActionPreference='Stop'
Add-Type 'using System; using System.Runtime.InteropServices; public class EnableOpenCUChild { [DllImport("wtsapi32.dll", SetLastError=true)] public static extern bool WTSEnableChildSessions(bool enabled); }'
if (![EnableOpenCUChild]::WTSEnableChildSessions($true)) { exit 1 }
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($enable))
    $powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $admin = Start-Process -FilePath $powershell -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
    if ($admin.ExitCode -ne 0) { throw 'AGENT_DESKTOP_UNAVAILABLE: Windows did not enable child sessions.' }
    if (![OpenCUTypeLibrary]::WTSIsChildSessionsEnabled([ref]$enabled) -or !$enabled) { throw 'Child sessions are still disabled.' }
}
$library = Join-Path $output 'OpenCU.Rdp.dll'
$helper = Join-Path $output 'OpenCU.AgentDesktop.exe'
# Compile into staging filenames so an old receipt cannot validate partial output.
Remove-Item -LiteralPath (Join-Path $output 'receipt.json') -Force -ErrorAction SilentlyContinue
Push-Location $output
try {
    [OpenCUTypeLibrary]::Import((Join-Path ([Environment]::SystemDirectory) 'mstscax.dll'), $library)
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ "/out:$helper" "/reference:$library" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:Microsoft.CSharp.dll (Join-Path $source 'Host.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Agent desktop helper compilation failed.' }
} finally { Pop-Location }
$registration = Start-Process -FilePath $helper -ArgumentList 'register' -Wait -PassThru
if ($registration.ExitCode -ne 0) { throw 'Agent desktop task registration failed.' }
$sources = @{}
foreach ($name in @('Host.cs', 'setup.ps1')) { $sources[$name] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $source $name)).Hash.ToLowerInvariant() }
$files = @{}
foreach ($name in @('OpenCU.AgentDesktop.exe', 'OpenCU.Rdp.dll')) { $files[$name] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $output $name)).Hash.ToLowerInvariant() }
$version = (Get-Content -Raw -LiteralPath (Join-Path $Root 'package.json') | ConvertFrom-Json).version
$receipt = @{ version=$version; sources=$sources; files=$files } | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $output 'receipt.json'), $receipt, (New-Object Text.UTF8Encoding($false)))
Write-Output 'Agent desktop setup completed. Sign out of Windows and back in once if this sign-in predates enabling child sessions. Smart-card-only sign-in is unsupported. OpenCU never requests a session password.'
