# Lists the active output devices, or plays a quiet tone on one of them (#13).
# Usage: powershell -File tests\Play-Tone.ps1 -Deps <backend-2.2.1 folder> [-Device <id> -Seconds 2]
# Without -Device it prints one line per active output device: <id><TAB><name>, the Windows
# default communication device marked with a * before the name.
param([Parameter(Mandatory)][string]$Deps, [string]$Device, [double]$Seconds = 2)
$ErrorActionPreference = 'Stop'
[Reflection.Assembly]::LoadFrom((Join-Path $Deps 'NAudio.core.dll')) | Out-Null
[Reflection.Assembly]::LoadFrom((Join-Path $Deps 'NAudio.wasapi.dll')) | Out-Null
$devices = New-Object NAudio.CoreAudioApi.MMDeviceEnumerator
if (!$Device) {
    $default = $devices.GetDefaultAudioEndpoint('Render', 'Communications').ID
    foreach ($d in $devices.EnumerateAudioEndPoints('Render', 'Active')) {
        [Console]::Out.WriteLine($d.ID + "`t" + $(if ($d.ID -eq $default) { '*' } else { '' }) + $d.FriendlyName)
    }
    exit 0
}
$d = $devices.GetDevice($Device)
$mix = $d.AudioClient.MixFormat
$tone = New-Object NAudio.Wave.SampleProviders.SignalGenerator($mix.SampleRate, $mix.Channels)
$tone.Frequency = 440; $tone.Gain = 0.2
$out = New-Object NAudio.Wave.WasapiOut($d, [NAudio.CoreAudioApi.AudioClientShareMode]::Shared, $false, 100)
try {
    $out.Init((New-Object NAudio.Wave.SampleProviders.SampleToWaveProvider($tone)))
    $out.Play()
    Start-Sleep -Milliseconds ([int]($Seconds * 1000))
    $out.Stop()
} finally { $out.Dispose(); $d.Dispose(); $devices.Dispose() }
