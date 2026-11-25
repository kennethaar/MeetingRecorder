# MeetingRecorder

Windows meeting recorder: an AutoHotkey v2 app (panel, tray menu, settings)
that starts a PowerShell/C# WASAPI capture helper and saves stereo WAV files.
It ships as source from the private GitHub repo `kennethaar/MeetingRecorder`;
there is no build artifact.

## Source and navigation

- Source lives in the repository root: `MeetingRecorder.ahk` (app and help
  topics), `Backend.ps1` (dependency bootstrap, compile, recovery),
  `Capture.cs` (capture engine), `Transcribe.py` (WhisperX transcription,
  run by the portable Python it finds). Tools live in `tools/`.
  Generated files: `WhatsNew.generated.ahk`. Never edit generated files directly.
  Their diffs after a generator run are expected: check them with
  `git diff --stat`, not in full.
- The tree sits in OneDrive. `.gitattributes` normalizes line endings, so
  `LF will be replaced by CRLF` warnings are harmless noise; do not try to
  fix them. Never commit OneDrive conflict copies (`*-LG2375JTB.*`,
  `*-HY-*.*`; `.gitignore` hides them).
- Build with: nothing to build. `Backend.ps1` compiles `Capture.cs` in memory
  at each launch. The test suite checks that the AHK script loads.
- Run with: `& "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe" MeetingRecorder.ahk`
  (PowerShell). Run AutoHotkey from PowerShell, not Git Bash: piping an AHK
  process in Git Bash hangs.

Use symbol, reference or text search first. Read only the relevant source,
its direct dependencies, its test and its help/docs topic. Expand only when
necessary. Do not explore directories recursively to learn the architecture.
Reuse findings already made in the session.

Known entry points:

- `Toggle()` / `StopRecording()` in `MeetingRecorder.ahk`: start and stop a
  recording. They drive `Backend.ps1 -Mode Record` through `status.ini` and
  `stop.signal`; state names must match `Poll()` and `CaptureEngine.Status`.
- `Poll()`: reads `status.ini` every 200 ms and moves the UI between states
  (`Installing`, `Manual only`, `Starting`, `Recording`, `Saving`,
  `Attention required`).
- `Settings()`, `SavedNotice()`, the `Panel`: the three screens. Their
  control v-names (`vStatus`, `vAction`, ...) are the help legend selectors.
- `CaptureEngine.Run` in `Capture.cs`: capture, mixing, WAV writing. The WAV
  header layout must stay in step with `Backend.ps1 -Mode Recover`.
- `HelpTopics()` at the end of `MeetingRecorder.ahk`: help topic data.
  Changelog items name these titles. `tests\Run-Tests.ps1` copies this
  function to a temp file for the tests, so run the tests through it.

Write source files with Write or Edit, not with shell heredocs or ad hoc
rewrite scripts. Heredocs eat backslashes in source code.

## Versioning

Semantic Versioning `MAJOR.MINOR.PATCH`:

- PATCH for fixes and small behavior adjustments.
- MINOR for new user-facing capabilities, resetting PATCH to `0`.
- MAJOR only when existing user data or settings become incompatible.

The version lives in `AppVersion` near the top of `MeetingRecorder.ahk`.
If it appears in several places, they must match, and a test checks this.

Every pushed change bumps the version and adds the matching entry at the top
of `CHANGELOG.md` in the same commit. A test checks that the newest changelog
version equals the app version.

Changelog format (the app parses it, so keep it exact):

```markdown
## 1.4.0 - 2026-11-12

- Help topic name: one plain sentence that says what is new. More detail
  after it (#42).
```

- One `## X.Y.Z - YYYY-MM-DD` heading per version, newest first.
- One `- ` item per change. Start it with the name of the help topic it
  belongs to, then a colon. What's new links the item to that topic, and a
  test fails if the name matches no topic.
- The first sentence after the colon says what the new thing is, for the user.
  End the item with its issue number `(#N)`.

End every reply about a completed change with:

    Now at **vX.Y.Z**

## Updates and what's new

The app checks for a newer version and tells the user what changed. Keep this
behavior when changing related code; each rule below has a test.

**Status.** Done: `AppVersion`, `CHANGELOG.md`, the generated
in-app copy, help topic data and their tests. Not built yet: the update check,
the Help pane with Show me, and the What's new screens. They are new UI, so
they start with mockups (see Working agreements). The repo is private, so the
raw URL below needs authentication; decide how the app reads it (token, public
repo, or a public release feed) before building the update check.

**Source of truth.** `CHANGELOG.md` on the `main` branch is the release feed.
The app reads `https://raw.githubusercontent.com/kennethaar/MeetingRecorder/main/CHANGELOG.md`.
Pushing a version bump plus changelog entry to `main` releases it.

**Copy of the changelog in the app.** A generator script copies the newest
changelog entries (enough to bridge several versions) into the app
(`WhatsNew.generated.ahk`, function `WhatsNewSource()`), so What's new works
offline. Run `pwsh -NoProfile -File tools\Build-WhatsNew.ps1` after editing
`CHANGELOG.md`; never edit the generated value by hand.

**Startup check (quiet).**
- About 5 s after start, without blocking, and at most once per day (store the
  date checked). Check again hourly if the app stays open past midnight.
- Skip when offline, in a demo build, or when the user turned updates off.
- Compare versions by number, never as text (`1.10.0 > 1.9.9`).
- Nothing newer: say nothing. Network error: say nothing.
- Newer found: show a toast plus a lasting badge beside the app name, such as
  "New v1.5.0 is ready", so a toast closed in a hurry is not the only way back.
  The badge goes away when no newer version exists.

**Manual check (answers always).**
- A "Look for a newer one" button in Help › What's new (and the tray/app menu
  where there is one).
- Newer found: same toast and badge as above.
- Up to date: "You have the newest version, vX.Y.Z."
- Network error: "Could not reach GitHub just now. Try again when you are
  online."

**The update itself.** Show the changes in every version since the current one,
then one primary action to get it. If the download fails, open the GitHub
page instead. After download, give at most 3 plain steps and say the user's
data stays as it is.

**"New since vX" window on first start of a new version.**
- Store the last version run on this device; update it on every start.
- On the first start of a newer version, show a lasting toast:
  "Welcome to v1.5.0! 3 new things since v1.2.0. Take a look:" with a short
  list and a "See what's new" button.
- "See what's new" opens a dialog listing each version since the last one run,
  newest first. Each item links to its help topic when the name matches one
  clearly (a wrong link is worse than none), and the dialog ends with a way to
  give feedback.
- A first start ever shows onboarding instead, not news.
- A device that ran an older app before the version was stored hears about
  the current version only.
- Same or older version: show nothing.

**Help › What's new** shows "This is vX.Y.Z." with the manual check button,
then every version in the in-app changelog copy.

## Tests

- Suite: `tests/RunTests.ahk` (AutoHotkey v2, started by `tests/Run-Tests.ps1`).
  Run from the repository root in PowerShell:
  `pwsh -NoProfile -File tests\Run-Tests.ps1 -Filter "<part of test name>"` while developing,
  `pwsh -NoProfile -File tests\Run-Tests.ps1 -FailuresOnly` before every push.
- Tests use temporary data, never the user's real data or settings. The
  recovery test points `LOCALAPPDATA` at a temp folder.
- A test that opens a dialog hangs the run. Make AHK warnings print
  (`#Warn ..., StdOut`) instead of showing a MsgBox.
- Known timing-flaky tests: none. If they pass alone, report it
  and move on.

Test first. For every behavioral change, write or update the test before the
code, from the requirement or the bug report, never from the implementation.
Run it and see it fail for the expected reason. Then write the code until it
passes. Do not edit the test afterwards to fit the code; change it only if the
requirement itself changed. A bug test includes its issue number.

Test what the user sees, not only that something exists.

Keep the suite lean:

- Search the suite for an existing test of the same behavior first. Extend or
  tighten it instead of adding a near-duplicate.
- One test per behavior. Cover each rule once, with the cases that can fail
  differently (edge, error, regression). Skip cases that follow the same path.
- When touching an area, merge or delete redundant tests you find there.
  Deleting a duplicate is allowed; weakening a test is not.

Never weaken or bypass a test to make it pass. Fix the application unless the
expectation is demonstrably obsolete.

Run the targeted test first. Widen only if it fails. Run the full suite once
before every push. Do not repeat full runs to be sure; if a test fails, rerun
only that test. Do not rerun the full suite for changelog, version or
docs-only edits after a passing run. Changes to CLAUDE.md alone need no test
run.

Do not use `git stash` to check whether a failure is pre-existing. Rerun the
failing test alone instead.

## Help

Help lives in the app as topics in `MeetingRecorder.ahk` (`HelpTopics()`; the More fold
is the `more` field). There are no
screenshots: help explains the live screen itself.

Each topic has an id, a `title`, everyday search `words`, and these fields:

- `what`: one or two sentences on what the feature is and why to use it.
- `steps`: how to use it, one short action per step.
- `keys`: keyboard shortcuts.
- `legend`: numbered list of `[selector, text]` pairs. Each one names a
  thing on the screen and says what it is. A `?` before the selector marks
  something that is not always on the screen.
- `view` / `sub`: the screen (and sub-screen) the topic is about. Only for
  topics about one specific screen.
- More fold: detail beyond the basics goes below it.

How help works for the user:

- **Help beside the screen.** Help opens in a side pane next to the screen,
  so the user reads and tries at the same time. "This page" shows the topic
  for the screen they are on.
- **Show me.** Lays a numbered badge on each thing in the topic's `legend`,
  on the live screen. Clicking a number, a legend row, or the thing itself
  while Show me is on explains it instead of doing it: the thing lights up,
  a short bubble says "2. What it is", and its legend row is highlighted.
  Legend rows whose thing is not on the screen are dimmed. Esc or Done ends
  Show me; on a phone the pane steps aside and Done ends it.
- **From full help.** A topic with a `view` has Show me: it goes to that
  screen, opens "This page" beside it and points at the number.
- **Search.** Finds topics by title, words and text. What's new items link to
  their topic by name.
- If a thing is not on the screen just now, say so plainly instead of
  pointing at nothing.

When user-facing behavior changes, update the matching help topic in the same
commit. Update the relevant `what`, `steps`, `keys` and `legend` fields. Use
`view` and `sub` only for view-specific topics.

Use short, plain language and keep LIX below 30 when practical.

A topic has at most 6 `steps` and under 90 words before its More fold. A test
enforces both. Count them before building, and when a topic grows, merge steps
instead of adding one.

When a screen changes, check its topic's `legend`: every selector must still
find its thing. Keep a test that opens each topic's screen and checks that
every legend selector without `?` matches something there. Renumbering is automatic, so add or remove legend rows
freely; keep them in reading order (top left to bottom right).

Selectors are `View.ControlName`: the topic's `view` (`Panel`, `Settings`,
`Saved`) and the control's v-name. Until the Help pane exists, the test checks
that each selector's view matches the topic and that the v-name is declared.

## GitHub workflow

Every user-requested change needs an issue in `kennethaar/MeetingRecorder`.

0. Write issues and comments in generic text: no real names, people,
   employers, meeting titles, places or words copied from the user's
   recordings, transcripts, calendar, logs or screenshots. Use neutral
   stand-ins such as "a long meeting name" or "Person A".
1. Search existing issues first. Before creating an issue or adding to one,
   show the user its title and body and wait for their OK, so they can see
   the request was understood.
2. Reopen and reuse an issue for a follow-up, regression or related
   correction.
3. Create a new issue only for distinct new behavior (label `enhancement` or
   `bug`).
4. Each commit references one issue with `Fixes #N`.
5. Commit locally. Push to `main` only after the full test run passes. This
   holds in cloud sessions too, even when the session names a branch of its
   own.
6. Comment `Fixed in <short-sha>.` (or `Fixed in vX.Y.Z.`) on the issue.

Use `gh` if it is installed (on this PC it is not yet). Otherwise use the
GitHub REST API with Git's stored token. Never print or commit the token.

```bash
TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill | sed -n 's/^password=//p')
H=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json")
API=https://api.github.com/repos/kennethaar/MeetingRecorder
SCRATCH="${TMPDIR:-/tmp}/MeetingRecorder-claude"
mkdir -p "$SCRATCH"
```

Build issue and comment payloads with `JSON.stringify()` (or `json.dumps`).
Store temporary JSON only in `$SCRATCH`, never in the repository.

## Working agreements

- **Mockups first.** Before implementing a new feature or changing
  user-facing text or UX, show 3 different ASCII mockups of the UI or flow
  and let the user pick one. Write no implementation code until a mockup is
  chosen.
- **Focused changes.** Do not redesign unrelated parts during a focused
  change.
- **Suggest UX fixes.** When a task touches a screen, briefly list the UI/UX
  problems you see there and the fix you recommend. Suggestions outside the
  task stay suggestions: build them only after the user agrees.
- **Ask, don't assume.** When setup depends on the user's own conventions,
  ask. Do not preselect personal conventions.
- **Offer only what works.** Show a choice only when it can work. Let users
  pick known values from a list instead of typing them.

## Product and design rules

Apply Steve Krug's "Don't Make Me Think", progressive disclosure,
accessibility and management by exception:

- Make things self-evident. Labels, buttons and actions are obvious without
  explanation. If something needs an explanation, fix the design before
  adding text.
- Use plain, familiar wording. No jargon or clever names.
- Reduce choices and noise. Cut words in half, then cut half of what's left.
  No happy talk, no body text that repeats the title.
- Make clickable things look clickable. Users click the first reasonable
  option, so make the right one the most obvious. Use one clear control per
  action. Doubt per click matters more than the number of clicks.
- Always show where the user is and how to get back. Keep their goodwill:
  no hidden needed info, no forced formats, easy recovery from mistakes.
- Follow conventions users already know.
- Design for scanning: clear visual hierarchy, short text.
- Prevent errors. When they happen, say plainly what went wrong and how to
  fix it.
- Show secondary details on focus, hover or demand. Hover-only information
  must also be reachable by keyboard focus or a touch action.
- Use strong color only for states and true exceptions. Render structural
  metadata quietly.
- The recording panel never takes focus (`+E0x08000000`, `NoActivate`) and
  cannot be closed while recording. Keep it that way: the user is typing in a
  call.
- Recording is always visible. Never start a recording silently. The only
  automatic start is a Teams call (#17): the panel shows Recording with Keep
  recording and Discard while the call is on, and no answer keeps it.

## Technical constraints

1. No external runtime dependencies unless agreed.
2. Preserve compatibility with existing user data. Add migration and
   regression coverage when changing stored data.
3. Maintain WCAG AA contrast in every theme.
4. Prefer native interactive elements and platform conventions (standard
   shortcuts, native controls, consistent spacing and fonts).
5. Support pointer, keyboard and touch where the platform has them.

6. AutoHotkey v2 syntax only. Windows PowerShell 5.1 and .NET Framework 4.8
   for `Backend.ps1` and `Capture.cs` (C# 5, no newer language features).
7. Runtime dependencies: NAudio.Core and NAudio.Wasapi 2.2.1, downloaded
   from NuGet and checked against NuGet's SHA-512. For transcription (#7),
   WhisperX 3.8.6 in a portable Python 3.11 plus FFmpeg 7.1 shared DLLs
   (torchcodec loads them from its own folder), installed on demand by
   `Backend.ps1 -Mode Transcriber`. `Transcribe.py` reads the WAV itself, so
   WhisperX never needs `ffmpeg.exe`.
8. Keep `MeetingRecorder.ahk` and `Backend.ps1` UTF-8 with BOM.

## Behavior and data

- Default shortcut `^!r` (Ctrl+Alt+R) toggles recording. Configurable.
- Settings: `%LOCALAPPDATA%\MeetingRecorder\settings.ini`.
  `[Settings]` `Folder`, `Shortcut`, `Latest` (last saved file),
  `CloudNotice` (obsolete, from the removed Word handoff; ignored), `Detect` (record
  Teams calls when they start, default 1), `Calendar` (name files after the classic Outlook
  meeting, default 1), `Startup` (keep `Meeting Recorder.lnk` in the Startup folder, checked at
  every start, default 1; #20); `[UI]` `X`, `Y` (panel).
- Log: `%LOCALAPPDATA%\MeetingRecorder\MeetingRecorder.log`, written by the app (`AppLog()`),
  `Backend.ps1` (`Write-Log`) and `Capture.cs` (`Log`) as `yyyy-MM-dd HH:mm:ss.fff [source] text`.
  The app rotates it at 1 MB to `.1.log`..`.3.log` (#21).
  Missing keys fall back to defaults; add new keys the same way.
- IPC, also in `%LOCALAPPDATA%\MeetingRecorder`: `status.ini`
  (`[Capture]` `State`, `Detail`; replaced atomically, UTF-16) and
  `stop.signal` (its presence asks the helper to stop).
- Dependencies: `%LOCALAPPDATA%\MeetingRecorder\backend-2.2.1`.
- Transcription: `FindTranscriber()` uses `%LOCALAPPDATA%\MeetingRecorder\transcriber`,
  else PodcastClipper's `%LOCALAPPDATA%\PodcastEditorTools\whisperx-python`.
  `Transcribe.py` reports in `transcribe.ini` (`[Transcribe]` `State`,
  `Percent`, `Detail`; UTF-16) and writes `transcribe.tsv`; the app turns that
  into `<recording>.txt` and `.srt` next to the WAV (left = Others,
  right = Me). Transcripts may be rewritten; recordings never.
- Teams calls: `DetectCall()` runs every 2 s. A call is active when Windows'
  microphone ConsentStore shows Teams with `LastUsedTimeStop = 0`. It starts
  a recording at once when the app is ready (`CallPhase` "Started"; #17). Meeting names come from classic Outlook via
  `ComObjActive` (never started by the app; new Outlook has no COM).
- Recordings: `<Folder>\yyyy-MM-dd HHmmss - <meeting or Recording> - <8 hex>.partial.wav`
  while recording, then renamed to `.wav`, ` - Incomplete.wav`, or (startup
  recovery) ` - Recovered incomplete.wav`. Format: 44-byte PCM header,
  48 kHz, 16-bit, stereo (left = output, right = microphone), max 5 hours.
- Never delete or overwrite a recording. Recovery keeps the original when it
  cannot repair it. The one exception: Discard on a recording started for a
  Teams call moves that file to the Recycle Bin (#17).
