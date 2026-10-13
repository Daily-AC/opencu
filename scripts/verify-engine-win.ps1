# Standalone JSON-lines acceptance. No Node or MCP is used in this script.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path $root ('.cache\direct-' + [Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$env:TEMP = $temp
$env:TMP = $temp
$title = 'OpenCU Direct Fixture ' + [Guid]::NewGuid().ToString()
$output = Join-Path $temp 'state.json'
$command = Join-Path $temp 'command.txt'
$fixture = $null
$engine = $null
$sequence = 0
$checks = [Collections.Generic.List[string]]::new()
$receipt = @{ test='windows-direct-stdio'; ok=$false; checks=$checks }
function State {
    for ($attempt=0; $attempt -lt 40; $attempt++) {
        try { return ([IO.File]::ReadAllText($output) | ConvertFrom-Json) } catch { Start-Sleep -Milliseconds 100 }
    }
    throw 'Fixture state unavailable'
}
function Request([string]$method, [hashtable]$params, [string]$expectedError='') {
    $script:sequence++
    $engine.StandardInput.WriteLine((@{id=$script:sequence;method=$method;params=$params}|ConvertTo-Json -Compress))
    $engine.StandardInput.Flush()
    $reading=$engine.StandardOutput.ReadLineAsync()
    if(-not $reading.Wait(30000)){throw 'Engine request timed out; input was not retried'}
    $response=$reading.Result|ConvertFrom-Json
    if($response.id -ne $script:sequence){throw 'Response id mismatch'}
    if($expectedError){if($response.error.code -ne $expectedError){throw ('Expected '+$expectedError+', got '+($response|ConvertTo-Json -Compress -Depth 6))}}
    elseif($response.error){throw ($response.error.code+': '+$response.error.message)}
    return $response.result
}
try {
    $info=[Diagnostics.ProcessStartInfo]::new('powershell.exe')
    $info.Arguments='-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+$root+'\tests\fixtures\OpenCUFixture.ps1" -Output "'+$output+'" -CommandFile "'+$command+'" -Title "'+$title+'"'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $fixture=[Diagnostics.Process]::Start($info)
    $initial=State
    $binary=Join-Path $root '.build\win\opencu-engine.exe'
    $receipt.engine_sha256=(Get-FileHash $binary -Algorithm SHA256).Hash.ToLowerInvariant()
    $info=[Diagnostics.ProcessStartInfo]::new($binary,'serve')
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $engine=[Diagnostics.Process]::Start($info)
    $state=Request 'get_app_state' @{app=$title;includeScreenshot=$true}
    if(-not $state.screenshot){throw ('Missing screenshot: '+$state.text)}
    $index=[regex]::Match($state.text,'(?m)^\s*\[(\d+)\] Button title="Fixture counter"').Groups[1].Value
    if(-not $index){throw 'Missing indexed fixture button'}
    $null=Request 'click' @{app=$title;element_index=[int]$index}
    $state=Request 'get_app_state' @{app=$title;includeScreenshot=$true}
    Start-Sleep -Milliseconds 150
    if((State).clicks -ne 1){throw 'Indexed click did not reach fixture'}
    $checks.Add('observe, indexed click, observe via direct stdio')
    $null=Request 'click' @{app=$title;x=$state.screenshot.width;y=0} 'INVALID_COORDINATE'
    if((State).clicks -ne 1){throw 'Out-of-bounds request delivered input'}
    $checks.Add('engine rejects out-of-bounds screenshot coordinates')
    $state=Request 'get_app_state' @{app=$title;includeScreenshot=$true}
    [IO.File]::WriteAllText($command,'move')
    for($i=0;$i -lt 40 -and (State).moves -eq 0;$i++){Start-Sleep -Milliseconds 100}
    if((State).moves -ne 1){throw 'Fixture did not move'}
    $null=Request 'click' @{app=$title;x=$initial.x;y=$initial.y} 'STALE_SCREENSHOT'
    $null=Request 'click' @{app=$title;x=$initial.x;y=$initial.y} 'SCREENSHOT_REQUIRED'
    $checks.Add('engine rejects moved-window and consumed screenshots')
    $null=Request 'get_app_state' @{app=$title;includeScreenshot=$false}
    $null=Request 'click' @{app=$title;x=0;y=0} 'SCREENSHOT_REQUIRED'
    $checks.Add('text-only observation grants no coordinates')
    if((State).clicks -ne 1){throw 'Refused requests changed fixture click count'}
    $receipt.ok=$true
} catch {
    $receipt.error=$_.Exception.Message
} finally {
    if($engine -and -not $engine.HasExited){$engine.StandardInput.Close();if(-not $engine.WaitForExit(5000)){$engine.Kill();$engine.WaitForExit();$receipt.ok=$false;$receipt.cleanupError='Engine did not exit on EOF'}}
    if($fixture -and -not $fixture.HasExited){[IO.File]::WriteAllText($command,'close');if(-not $fixture.WaitForExit(5000)){$fixture.Kill();$fixture.WaitForExit();$receipt.ok=$false;$receipt.cleanupError='Fixture required forced cleanup'}}
    Remove-Item -LiteralPath $temp -Recurse -Force
    $receipt | ConvertTo-Json -Depth 6
}
if(-not $receipt.ok){exit 1}
