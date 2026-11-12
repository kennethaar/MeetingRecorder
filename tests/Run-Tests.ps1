# Runs tests\RunTests.ahk with AutoHotkey v2 and prints its results.
# Usage: pwsh -File tests\Run-Tests.ps1 [-Filter "part of a test name"] [-FailuresOnly]
param([string]$Filter = '', [switch]$FailuresOnly)
$ErrorActionPreference = 'Stop'
$ahk = Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'
if (!(Test-Path $ahk)) { throw "AutoHotkey v2 not found at $ahk" }
# MeetingRecorder.ahk cannot be included without starting the app. Copy the functions the tests
# call to a temp file; RunTests.ahk includes it from there. A function must start at column 0
# with "Name(...) {" and end with the first "}" at column 0.
$testDir = Join-Path ([IO.Path]::GetTempPath()) 'MeetingRecorder-tests'
New-Item -ItemType Directory -Force $testDir | Out-Null
$app = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\MeetingRecorder.ahk'))
$functions = 'HelpTopics', 'TeamsCallActive', 'RegQword', 'PickMeeting', 'ComDateToStamp', 'RecordingName'
$code = foreach ($name in $functions) {
    $m = [regex]::Match($app, "(?ms)^$name\([^)\r\n]*\) \{.*?^\}")
    if ($m.Success) { $m.Value } else { "$name(*) {`n    throw Error(`"No $name() function in MeetingRecorder.ahk`")`n}" }
}
[IO.File]::WriteAllText((Join-Path $testDir 'AppFunctions.ahk'), ($code -join "`n`n"), [Text.UTF8Encoding]::new($true))
$out = [IO.Path]::GetTempFileName()
$err = [IO.Path]::GetTempFileName()
try {
    $p = Start-Process $ahk -ArgumentList '/ErrorStdOut', "`"$PSScriptRoot\RunTests.ahk`"", "`"$Filter`"" `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $lines = @(Get-Content $out -Encoding UTF8) + @(Get-Content $err -Encoding UTF8)
    if ($FailuresOnly) { $lines = $lines | Where-Object { $_ -notmatch '^PASS  ' } }
    $lines | Where-Object { $_ -ne $null }
    exit $p.ExitCode
} finally {
    Remove-Item $out, $err -ErrorAction SilentlyContinue
}
