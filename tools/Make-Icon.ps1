# Draws MeetingRecorder.ico: a red record dot in a white ring on a dark circle.
# Usage: powershell -NoProfile -File tools\Make-Icon.ps1
# Each size is drawn on its own (not scaled down) and stored as PNG inside the .ico.
param([string]$Output = (Join-Path $PSScriptRoot '..\MeetingRecorder.ico'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$sizes = 16, 20, 24, 32, 40, 48, 64, 256
$images = foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $edge = [Math]::Max(0.5, $s / 64)
    $dark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 31, 41, 55))
    $g.FillEllipse($dark, $edge, $edge, $s - 2 * $edge, $s - 2 * $edge)
    $ringWidth = [Math]::Max(1.0, $s / 14)
    $ringInset = $s * 0.16
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), $ringWidth
    $g.DrawEllipse($pen, $ringInset, $ringInset, $s - 2 * $ringInset, $s - 2 * $ringInset)
    $dotInset = $s * 0.29
    $red = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 239, 68, 68))
    $g.FillEllipse($red, $dotInset, $dotInset, $s - 2 * $dotInset, $s - 2 * $dotInset)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    , $ms.ToArray()
}
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $images[$i].Length
    $w.Write([byte]($s % 256)); $w.Write([byte]($s % 256)); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([UInt16]1); $w.Write([UInt16]32); $w.Write([UInt32]$len); $w.Write([UInt32]$offset)
    $offset += $len
}
foreach ($img in $images) { $w.Write($img) }
$w.Flush()
[IO.File]::WriteAllBytes([IO.Path]::GetFullPath($Output), $out.ToArray())
