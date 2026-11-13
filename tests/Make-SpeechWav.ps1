# Writes a short meeting-like stereo WAV in the app's format (48 kHz, 16-bit, left = others,
# right = me) from Windows' built-in voice. Others speak first, then me.
# Usage: powershell -File tests\Make-SpeechWav.ps1 -Output <file.wav> -Others "<text>" -Me "<text>"
param([Parameter(Mandatory)][string]$Output, [string]$Others, [string]$Me)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
function Speak([string]$text) {
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $stream = New-Object IO.MemoryStream
    try {
        $format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(48000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
        $synth.SetOutputToAudioStream($stream, $format)
        $synth.Speak($text)
        $synth.SetOutputToNull()
        return , $stream.ToArray()
    } finally { $synth.Dispose(); $stream.Dispose() }
}
Add-Type -TypeDefinition @'
public static class StereoWav {
    // left starts at leftAt, right at rightAt (in samples); returns 16-bit stereo PCM.
    public static byte[] Mix(byte[] left, int leftAt, byte[] right, int rightAt, int frames) {
        byte[] pcm = new byte[frames * 4];
        for (int i = 0; i < left.Length / 2 && leftAt + i < frames; i++) {
            pcm[(leftAt + i) * 4] = left[i * 2]; pcm[(leftAt + i) * 4 + 1] = left[i * 2 + 1];
        }
        for (int i = 0; i < right.Length / 2 && rightAt + i < frames; i++) {
            pcm[(rightAt + i) * 4 + 2] = right[i * 2]; pcm[(rightAt + i) * 4 + 3] = right[i * 2 + 1];
        }
        return pcm;
    }
}
'@
$left = Speak $Others
$right = Speak $Me
$rate = 48000
$leftAt = [int]($rate * 0.5)
$rightAt = $leftAt + $left.Length / 2 + [int]($rate * 0.8)
$frames = $rightAt + $right.Length / 2 + [int]($rate * 0.5)
$pcm = [StereoWav]::Mix($left, $leftAt, $right, $rightAt, $frames)
$f = [IO.File]::Create($Output)
try {
    $w = New-Object IO.BinaryWriter($f)
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([uint32](36 + $pcm.Length))
    $w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $w.Write([uint32]16)
    $w.Write([uint16]1); $w.Write([uint16]2); $w.Write([uint32]$rate); $w.Write([uint32]($rate * 4))
    $w.Write([uint16]4); $w.Write([uint16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([uint32]$pcm.Length); $w.Write($pcm)
    $w.Flush()
} finally { $f.Dispose() }
