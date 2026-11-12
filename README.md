# Meeting Recorder

A first native Windows draft. See [CHANGELOG.md](CHANGELOG.md) for what each version adds.

## Start
1. Install AutoHotkey v2 (64-bit recommended).
2. Clone or extract this entire folder to a stable location. Keep the files together.
3. Run MeetingRecorder.ahk. No administrator rights are required.
4. First launch downloads NAudio.Core and NAudio.Wasapi **2.2.1** from NuGet over HTTPS. Package SHA-512 is checked against the digest published by that same feed. This detects corrupt downloads, but is not an independently pinned trust anchor. The downloaded DLLs are reused locally. No FFmpeg is required.
5. Review setup, select a recording folder, then press Ctrl+Alt+R to record and again to stop.
6. Test with headphones: play audio and speak. Open the resulting WAV. Output must be left; microphone must be right.

Requirements: Windows 10/11, AutoHotkey v2, Windows PowerShell 5.1 and .NET Framework 4.8. Internet is needed for initial backend installation only. Managed Windows policy may block downloaded scripts or PowerShell compilation. ExecutionPolicy Bypass is process-scoped, not a machine policy change; it does not bypass enterprise controls.

## Implemented
- Native AHK v2 UI and shortcut, with a separate PowerShell/C# capture process.
- Backend auto-download, version pin, published package checksum check, repair/retry.
- Windows communications microphone and output selected at recording start.
- WASAPI microphone plus endpoint loopback, downmixed and resampled to stereo PCM WAV, 48 kHz/16-bit.
- Left = all selected output audio. Right = microphone. No named-speaker identification.
- Visible, movable, non-activating recording panel; status shown only after both capture streams report Capturing.
- Unique filenames, create-new semantics, disk-space preflight, incremental writes and WAV-header checkpoints.
- Device-state and process monitoring; incomplete recordings labelled separately.
- Stop-file IPC, safe normal exit, controller-loss handling, suspend stop attempt.
- Startup recovery of this draft's partial WAVs in the configured recording folder. Originals remain if recovery fails.
- Completion panel, latest recording, Explorer selection and optional Word handoff with cloud notice.
- Settings and dependencies under %LOCALAPPDATA%\MeetingRecorder, separate from source.

## Deliberately not implemented
- Automatic call detection, countdown, grace period and suppression. There are no tested supported calling apps yet, so automation is not offered.
- ICS calendars and naming. No calendar URLs are collected or stored.
- Fixed-device selection, level meters, automated channel test, reconnect, startup registration and automatic Word launch.
- Production-grade timestamp synchronization or drift correction. Clock-paced buffered mixing is a draft, not proof of two-hour synchronization. Capture start offset and silence-to-audio transitions need testing. The resampling queue can introduce gaps or offsets under scheduling/device-clock stress.
- A missing microphone callback without a device-state change may produce silence rather than a detected fault. Hardware mute, Bluetooth profiles, audio service restart and device-switch behaviour are unverified.
- Guaranteed recovery after storage failure, forced shutdown or physical disk failure.

## Important limitations
This is source code for a first manual-recording build, NOT a verified production recorder. It was not compiled or run on Windows in the authoring environment. No capture, mute, Bluetooth, recovery or long-duration acceptance test has passed yet.

The writer stops at five hours to stay below classic RIFF's 4 GB size limit. Start another recording for longer sessions. A startup recovery scans only the currently configured folder; changing folders does not scan old folders. Recovery of an empty header produces an incomplete file, not proof of useful audio. There is no automatic deletion.

Output includes unrelated media and notifications. Call mute may not mute the directly captured microphone. Participants receive no notification. Follow your organization's recording rules. The recorder does not upload audio. Word Transcribe uploads audio to OneDrive after the user chooses Upload audio.

A normal stop drains buffered audio. If capture fails, the saved incomplete file may omit queued tail audio. A forced termination can leave up to the last header checkpoint unreferenced until recovery. Recovery repairs the fixed 44-byte PCM header used by this writer, not arbitrary WAV files.

## First validation pass
- Launch with an empty backend folder; verify download, checksum handling and repair after a failed download.
- Restart offline; record both sources.
- Speak/play alternating test tones; verify left/right, startup offset, silence transitions and a two-hour drift test.
- Stop with shortcut, panel and Exit; check playback and duration.
- Unplug each device, stop the audio service, fill a test volume and kill the helper; verify warnings and recovery.
- Kill the controller; verify helper finalizes incomplete audio rather than recording indefinitely.
- Test suspend/resume and Windows shutdown. Suspend finalization is best effort.
- Test filename collisions and non-ASCII paths.
- Verify the panel does not steal typing focus and cannot be closed while recording.

## Architecture
MeetingRecorder.ahk: orchestration, UI, settings, handoff and in-app help topics. Holds `AppVersion`.
Backend.ps1: pinned dependency bootstrap, C# compilation, startup recovery.
Capture.cs: WASAPI capture, mono conversion, resampling, stereo writing and status IPC.
WhatsNew.generated.ahk: in-app copy of the changelog, made by `tools\Build-WhatsNew.ps1`.

## Development
Run the tests from the repository root in PowerShell:

    pwsh -NoProfile -File tests\Run-Tests.ps1

Each change bumps `AppVersion`, adds an entry at the top of CHANGELOG.md, then runs `tools\Build-WhatsNew.ps1`. Project rules are in CLAUDE.md.

No prebuilt executable is included. PowerShell compiles the helper in memory at each launch. Runtime dependencies are downloaded once, not silently upgraded. Repair retries missing dependencies; to redownload a damaged DLL, close the app and remove %LOCALAPPDATA%\MeetingRecorder\backend-2.2.1, then restart.

## References
- https://www.nuget.org/packages/NAudio.Core/2.2.1
- https://www.nuget.org/packages/NAudio.Wasapi/2.2.1
- https://github.com/naudio/NAudio/tree/v2.2.1
- https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording
- https://support.microsoft.com/en-us/word/transcribe-your-recordings

NAudio is a third-party MIT-licensed dependency. Review and include upstream license notices before redistributing binaries. This package contains original helper source, not NAudio binaries.
