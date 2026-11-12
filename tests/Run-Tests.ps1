# Runs tests\RunTests.ahk with AutoHotkey v2 and prints its results.
# Usage: pwsh -File tests\Run-Tests.ps1 [-Filter "part of a test name"] [-FailuresOnly]
param([string]$Filter = '', [switch]$FailuresOnly)
$ErrorActionPreference = 'Stop'
$ahk = Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'
if (!(Test-Path $ahk)) { throw "AutoHotkey v2 not found at $ahk" }
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
