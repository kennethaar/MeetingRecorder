# Changelog

## 0.12.0 - 2026-11-25

- Tray menu: Open log file shows what the app did and when, to find out what
  went wrong. Recordings, Teams calls, microphones, transcripts and errors are
  all in it. Older lines move to MeetingRecorder.1.log to .3.log (#21).

## 0.11.0 - 2026-11-17

- Tray menu: Restart closes the app and starts it again. A recording that is
  running is saved first (#19).

## 0.10.1 - 2026-11-17

- Transcribe a recording: A recording saved while another one is being
  transcribed no longer shows "Gui has no window" errors (#18).

## 0.10.0 - 2026-11-16

- Teams calls: Recording starts as soon as a Teams call starts, so you get the
  whole call even if you see the panel late. Click Keep recording, or Discard
  to move it to the Recycle Bin. If you do nothing, it is kept (#17).

## 0.9.2 - 2026-11-16

- Transcribe a recording: Transcribing starts at once, while the word-timing
  model for a new language downloads in the background. Until it is there, the
  times are less exact. A model download shows how much is done, the time
  left, and that it happens only the first time (#16).

## 0.9.1 - 2026-11-16

- Transcribe a recording: When a speech model has to be downloaded first, the
  window says so and shows how much is done, instead of "Loading the speech
  model" for half an hour. If the word-timing model download stops, the
  transcript is made without it. Each try is logged with times in
  transcribe.ini.log (#16).

## 0.9.0 - 2026-11-14

- Transcribe a recording: Transcribing is about twice as fast and uses less
  memory, with a speech model that also misses fewer words (#15).
- Settings: Pick Fast or Accurate under Transcribe with. Accurate is slower
  and suits meetings in other languages than English (#15).

## 0.8.0 - 2026-11-14

- Settings: Pick the microphone that records you. A bar moves when it hears
  you, so you can check it before a call, and it says so when Windows has
  muted the microphone (#14).
- Record a meeting: If your microphone stops during a call, recording goes
  on with the Windows default instead of stopping (#14).

## 0.7.1 - 2026-11-14

- Record a meeting: What others say is now recorded from every speaker and
  headset that is on, not only from the Windows default one. Before, a call
  played on the laptop speakers while a headset was connected was saved
  silent (#13).

## 0.7.0 - 2026-11-13

- Transcribe a recording: If transcribing stops, Try again picks up where it
  stopped. What others said is kept once it is done, so it is not done
  twice (#12).
- Transcribe a recording: The window lists the steps and ticks them off, and
  the bar moves while it gets ready instead of sitting at 0% (#12).
- Tray menu: A ring round the tray icon fills as transcribing goes on, and
  spins while it gets ready. Hover to see the percent and the step (#12).

## 0.6.1 - 2026-11-13

- Transcribe a recording: A long transcription no longer stops halfway with
  "Access denied" on transcribe.ini. That happened when the app checked the
  progress just as the transcriber updated it (#7).

## 0.6.0 - 2026-11-13

- Tray menu: Recordings lists your 8 newest recordings, so you can open an
  older one, not just the latest. It shows when each was recorded and if it
  has a transcript. Other recording... opens any earlier one (#11).

## 0.5.0 - 2026-11-13

- Transcribe a recording: Names from the Outlook meeting are spelled right in
  the transcript. The app keeps the meeting title and the people invited when
  recording starts, and gives them to the transcriber as a hint (#10).
- Transcribe a recording: A long turn is split into paragraphs. A pause of
  2 seconds starts a new one with its own time, so the text is easier to
  scan (#10).
- Transcribe a recording: Transcribing uses half of the PC's processor, so
  the PC stays quick while it runs. It is just as fast as before (#10).

## 0.4.1 - 2026-11-13

- Tray menu: Click the red dot to open the panel. Right-click still opens the
  menu (#9).
- Record a meeting: The panel says plainly what is happening, such as Ready to
  record, with the shortcut below it, and has no empty space beside the
  buttons (#9).
- Transcribe a recording: The Recording saved window shows the meeting name and
  when it was recorded, and keeps no empty gap above its buttons (#9).
- Settings: The folder fits on one line with Browse beside it, Cancel closes
  without saving, and the buttons sit at the bottom right like in other
  Windows apps (#9).

## 0.4.0 - 2026-11-13

- Transcribe a recording: Hide now tucks the window away while transcribing
  goes on, and the tray menu shows how far it has come. The window heading
  says what is new, such as Transcript ready (#8).
- Transcribe a recording: Transcribe again makes a new transcript, and
  Transcribe a recording in the tray menu works for any earlier recording (#8).
- Tray menu: Latest recording opens the recording and its transcript instead
  of the folder, and Help and About are new in the menu (#8).
- Tray menu: The app has its own icon, a red record dot, on the tray, in its
  windows and in its messages (#8).

## 0.3.0 - 2026-11-13

- Transcribe a recording: Click Transcribe when a recording is saved to get it
  as text, made on this PC with WhisperX instead of in Word. Nothing is
  uploaded. Lines are marked Others and Me, and a subtitle file is saved too
  (#7).

## 0.2.1 - 2026-11-13

- Transcribe a recording: The question about uploading to OneDrive now shows on top of
  the Recording saved window, instead of hidden behind it (#6).

## 0.2.0 - 2026-11-12

- Teams calls: When a Teams call starts, the panel offers to record it. Click
  Record or Not now; it never records by itself (#5).
- Teams calls: While classic Outlook is open, recordings are named after the
  meeting that is on now (#5).

## 0.1.2 - 2026-11-12

- Audio backend: Setup now finishes on PCs with .NET Framework 4.8, instead
  of asking you to install it again or staying at Installing (#4).

## 0.1.1 - 2026-11-12

- Record a meeting: The app now starts, and Start records instead of failing
  with an error (#2).

## 0.1.0 - 2026-11-12

- Record a meeting: Record a call to a stereo WAV file, with what you hear on
  the left and your microphone on the right (#1).
- Settings: Choose the recording folder and the keys that start and stop a
  recording (#1).
- Transcribe a recording: Send a saved recording to Word Transcribe to get it as text
  (#1).
- Recovered recordings: Audio from a recording that was cut off is rescued the
  next time the app starts (#1).
- Audio backend: The audio library is downloaded once, checked, and can be
  repaired from the tray menu (#1).
