param([ValidateSet('Setup','Record','Recover','Transcriber')][string]$Mode='Setup',[string]$Output,[string]$Status,[string]$Stop,[int]$ParentId)
$ErrorActionPreference='Stop'
$runtime=Join-Path $env:LOCALAPPDATA 'MeetingRecorder'
$deps=Join-Path $runtime 'backend-2.2.1'
New-Item -ItemType Directory -Force $deps | Out-Null
function Set-State($state,$detail) {
 if($Status){$tmp=$Status+'.tmp';[IO.File]::WriteAllText($tmp,"[Capture]`r`nState=$state`r`nDetail=$($detail -replace '[\r\n]',' ')`r`n",[Text.Encoding]::Unicode);if(Test-Path $Status){[IO.File]::Replace($tmp,$Status,[NullString]::Value)}else{[IO.File]::Move($tmp,$Status)}}
}
try {
 if($Mode -eq 'Recover') {
  Get-ChildItem -LiteralPath $Output -Filter '*.partial.wav' | ForEach-Object {
   $f=$null
   try {
    $f=[IO.File]::Open($_.FullName,'Open','ReadWrite','None')
    if($f.Length -lt 44){throw 'No recoverable WAV payload'}
    $n=[long]([Math]::Floor(($f.Length-44)/4)*4)
    if($n -gt [uint32]::MaxValue-36){throw 'File exceeds RIFF limit'}
    $f.SetLength($n+44);$w=New-Object IO.BinaryWriter($f)
    $f.Position=4;$w.Write([uint32]($n+36));$f.Position=40;$w.Write([uint32]$n);$f.Flush($true);$f.Dispose();$f=$null
    $target=$_.FullName.Replace('.partial.wav',' - Recovered incomplete.wav')
    [IO.File]::Move($_.FullName,$target)
   } catch { Write-Warning 'Recovery could not finish; original retained.' } finally {if($f){$f.Dispose()}}
  }
  exit 0
 }
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 if($Mode -eq 'Transcriber') {
  # One-time portable WhisperX for transcription on this PC (#7), the same steps as PodcastClipper:
  # embeddable Python with site enabled, pip, WhisperX, and FFmpeg 7.1 DLLs that torchcodec loads
  # from its own folder. Built in a .partial folder so the app never finds half an install.
  $ProgressPreference='SilentlyContinue'
  $target=Join-Path $runtime 'transcriber';$work="$target.partial";$log=Join-Path $runtime 'transcriber-setup.log'
  if(Test-Path $work){Remove-Item -Recurse -Force $work}
  New-Item -ItemType Directory -Force $work | Out-Null
  function Get-Archive($uri,$detail,$dest) {
   Set-State 'Installing' $detail
   $zip="$dest.zip"
   Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $zip -TimeoutSec 1800
   [IO.Compression.ZipFile]::ExtractToDirectory($zip,$dest);Remove-Item $zip
  }
  function Invoke-Python($arguments,$detail) {
   Set-State 'Installing' $detail
   $p=Start-Process (Join-Path $work 'python.exe') -ArgumentList $arguments -WorkingDirectory $work -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
   if($p.ExitCode -ne 0){throw "$detail failed. Details: $log.err"}
  }
  Get-Archive 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip' 'Downloading Python' $work
  $pth=Get-ChildItem $work -Filter 'python3*._pth' | Select-Object -First 1
  [IO.File]::WriteAllText($pth.FullName,([IO.File]::ReadAllText($pth.FullName) -replace '(?m)^#\s*import site','import site'))
  Invoke-WebRequest -UseBasicParsing -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile (Join-Path $work 'get-pip.py') -TimeoutSec 300
  Invoke-Python 'get-pip.py --no-warn-script-location' 'Installing pip'
  Invoke-Python '-m pip install --no-warn-script-location whisperx==3.8.6' 'Downloading WhisperX. This takes several minutes'
  Get-Archive 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n7.1-latest-win64-gpl-shared-7.1.zip' 'Downloading FFmpeg libraries' (Join-Path $work 'ffmpeg')
  $torchcodec=Join-Path $work 'Lib\site-packages\torchcodec'
  if(!(Test-Path (Join-Path $work 'Lib\site-packages\whisperx')) -or !(Test-Path $torchcodec)){throw "WhisperX did not install. Details: $log"}
  Get-ChildItem (Join-Path $work 'ffmpeg') -Recurse -Filter '*.dll' | ForEach-Object {Copy-Item $_.FullName $torchcodec -Force}
  if(Test-Path $target){Remove-Item -Recurse -Force $target}
  Move-Item $work $target
  Set-State 'Ready' 'Transcriber ready'
  exit 0
 }
 foreach($id in @('naudio.core','naudio.wasapi')) {
  $dll=Join-Path $deps (($id -replace '^naudio','NAudio')+'.dll')
  if(!(Test-Path $dll)) {
   Set-State 'Installing' 'Downloading pinned NAudio 2.2.1 backend from NuGet. Internet needed once.'
   $base="https://api.nuget.org/v3-flatcontainer/$id/2.2.1/$id.2.2.1.nupkg"
   $pkg=Join-Path $deps "$id.zip";$extract=Join-Path $deps "$id-extract"
   Invoke-WebRequest -UseBasicParsing -Uri $base -OutFile $pkg -TimeoutSec 60
   $registration=Invoke-RestMethod -Uri "https://api.nuget.org/v3/registration5-semver1/$id/2.2.1.json" -TimeoutSec 30
   $catalog=$registration.catalogEntry
   if($catalog -is [string]){$catalog=Invoke-RestMethod -Uri $catalog -TimeoutSec 30}
   if($catalog.packageHashAlgorithm -ne 'SHA512' -or !$catalog.packageHash){throw 'NuGet did not supply a SHA512 package digest.'}
   $expected=$catalog.packageHash.Trim()
   $sha=[Security.Cryptography.SHA512]::Create();$stream=[IO.File]::OpenRead($pkg)
   try{$actual=[Convert]::ToBase64String($sha.ComputeHash($stream))}finally{$stream.Dispose();$sha.Dispose()}
   if($actual -cne $expected){throw 'Backend package checksum mismatch.'}
   if(Test-Path $extract){Remove-Item -Recurse -Force $extract}
   [IO.Compression.ZipFile]::ExtractToDirectory($pkg,$extract)
   $source=Get-ChildItem (Join-Path $extract 'lib/netstandard2.0') -Filter '*.dll' | Select-Object -First 1
   Copy-Item $source.FullName $dll
   Remove-Item -Recurse -Force $extract;Remove-Item $pkg
  }
 }
 $core=Join-Path $deps 'NAudio.core.dll';$wasapi=Join-Path $deps 'NAudio.wasapi.dll'
 [Reflection.Assembly]::LoadFrom($core)|Out-Null;[Reflection.Assembly]::LoadFrom($wasapi)|Out-Null
 # .NET 4.7.1+ installs netstandard.dll in the runtime directory itself; older layouts used Facades (#4).
 $netRuntime=[Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
 $facade=@((Join-Path $netRuntime 'netstandard.dll'),(Join-Path $netRuntime 'Facades\netstandard.dll')) | Where-Object {Test-Path $_} | Select-Object -First 1
 if(!$facade){throw 'Install or repair .NET Framework 4.8, then retry.'}
 Add-Type -Path (Join-Path $PSScriptRoot 'Capture.cs') -ReferencedAssemblies @($core,$wasapi,$facade,'System.dll','System.Core.dll')
 if($Mode -eq 'Setup'){Set-State 'Ready' 'Backend ready';exit 0}
 [CaptureEngine]::Run($Output,$Status,$Stop,$ParentId)
} catch {Set-State 'Error' $_.Exception.Message;exit 1}
