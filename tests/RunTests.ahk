#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off
; A warning dialog would hang the run; print warnings instead.
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off
; Run-Tests.ps1 copies the app functions the tests call out of MeetingRecorder.ahk to this temp file.
#Include %A_Temp%\MeetingRecorder-tests\AppFunctions.ahk
#Include %A_ScriptDir%\..\WhatsNew.generated.ahk

; Usage: pwsh -NoProfile -File tests\Run-Tests.ps1 [-Filter "part of a test name"]
Root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
Filter := A_Args.Length ? A_Args[1] : ""
Tests := [
    ["App script loads without errors or warnings (#2)", TestAppLoads],
    ["Version matches newest changelog entry", TestVersion],
    ["Changelog format", TestChangelogFormat],
    ["Changelog items name a help topic", TestChangelogTopics],
    ["Help topics stay short", TestHelpLimits],
    ["Help legend selectors name real controls", TestLegendSelectors],
    ["In-app changelog copy is current", TestWhatsNewCurrent],
    ["Recovery repairs partial recordings", TestRecovery],
    ["Audio backend setup reaches Ready on .NET 4.8 (#4)", TestBackendSetup],
    ["Others is recorded from whichever speaker plays the call (#13)", TestOthersFromAnySpeaker],
    ["Settings lets you pick the microphone and shows how loud it is (#14)", TestMicSettings],
    ["Recording uses the chosen microphone, or the Windows default when it is missing (#14)", TestMicRecording],
    ["Settings lets you pick the speech model, Fast by default, and Transcribe uses it (#15)", TestModelSettings],
    ["Teams call is found from microphone use (#5)", TestTeamsDetection],
    ["Recording is named after the meeting running now (#5)", TestMeetingName],
    ["Outlook dates are read in any locale (#5)", TestComDate],
    ["Questions from the Recording saved window show on top of it (#6)", TestNoticeBoxOnTop],
    ["Transcript says who spoke when, as text and subtitles (#7)", TestTranscriptText],
    ["Meeting title and attendees become the transcript hint (#10)", TestMeetingHint],
    ["WhisperX is found in this app's or PodcastClipper's install (#7)", TestFindTranscriber],
    ["Transcribing goes on while the app reads its progress (#7)", TestStatusWhileRead],
    ["A recording is transcribed on this PC into Others and Me, and picks up where it stopped (#7, #12)", TestTranscribeSpeech],
    ["Transcribing shows its steps, a moving bar while getting ready, and a ring on the tray icon (#12)", TestTranscribeProgress],
    ["Recording saved window says what is new and offers to transcribe again (#8)", TestNoticeView],
    ["Tray menu shows transcribing, recordings, Help and About (#8)", TestTrayMenu],
    ["Tray menu › Recordings lists the newest recordings to open (#11)", TestRecentRecordings],
    ["Help and About windows show the topic and the version (#8)", TestHelpAndAbout],
    ["App icon is used on the tray, windows and toasts (#8)", TestAppIcon],
    ["Every window is laid out cleanly: no clipped text, gaps or stray buttons (#9)", TestWindowLayout],
    ["Panel and Recording saved window speak plainly (#9)", TestPlainWords],
]
Failures := 0, Ran := 0
for t in Tests {
    if Filter != "" && !InStr(t[1], Filter)
        continue
    Ran++
    try {
        t[2]()
        Out("PASS  " t[1])
    } catch as e {
        Failures++
        Out("FAIL  " t[1] "`n      " e.Message)
    }
}
Out(Format("`n{} run, {} failed", Ran, Failures))
ExitApp(Failures ? 1 : 0)

; ---------------------------------------------------------------- tests

; Bug #2: a syntax error kept the app from starting, and an unknown function
; (DriveSpaceFree) made every recording fail. /validate loads without running;
; a temp copy gets #Warn ... StdOut so warnings print instead of opening a dialog.
TestAppLoads() {
    base := A_Temp "\MeetingRecorder-validate-" A_TickCount
    try {
        FileAppend("#Warn VarUnset, StdOut`n" FileRead(Root "\MeetingRecorder.ahk", "UTF-8"), base ".ahk", "UTF-8")
        code := RunWait(A_ComSpec ' /c "' Q(A_AhkPath) " /ErrorStdOut /validate " Q(base ".ahk") " > " Q(base ".txt") ' 2>&1"', Root, "Hide")
        text := Trim(FileRead(base ".txt"), " `r`n")
        Check(code = 0 && text = "", "Exit " code ": " text)
    } finally {
        try FileDelete(base ".*")
    }
}

TestVersion() {
    src := FileRead(Root "\MeetingRecorder.ahk", "UTF-8")
    pos := 1, found := []
    while pos := RegExMatch(src, 'm)^AppVersion := "([^"]*)"', &m, pos) {
        found.Push(m[1])
        pos += m.Len
    }
    Check(found.Length = 1, "Expected one AppVersion in MeetingRecorder.ahk, found " found.Length)
    Check(RegExMatch(found[1], "^\d+\.\d+\.\d+$"), "AppVersion is not X.Y.Z: " found[1])
    newest := ReadChangelog()[1].version
    Check(found[1] = newest, "AppVersion " found[1] " differs from newest changelog " newest)
}

TestChangelogFormat() {
    versions := ReadChangelog()
    Check(versions.Length, "CHANGELOG.md has no versions")
    for i, v in versions {
        Check(RegExMatch(v.version, "^\d+\.\d+\.\d+$"), "Bad version: " v.version)
        Check(RegExMatch(v.date, "^\d{4}-\d{2}-\d{2}$") && IsTime(StrReplace(v.date, "-")), "Bad date for " v.version ": " v.date)
        Check(v.items.Length, v.version " has no items")
        for item in v.items
            Check(RegExMatch(item, "^- [^:]+: \S.* \(#\d+\)\.?$"), "Item must be '- Topic: text (#N)': " item)
        if i > 1
            Check(CompareVersions(versions[i - 1].version, v.version) > 0, "Not newest first: " versions[i - 1].version " before " v.version)
    }
}

TestChangelogTopics() {
    titles := Map()
    titles.CaseSense := false
    for topic in HelpTopics()
        titles[topic.title] := true
    for v in ReadChangelog()
        for item in v.items {
            RegExMatch(item, "^- ([^:]+):", &m)
            Check(m && titles.Has(m[1]), "No help topic named '" (m ? m[1] : item) "' (" v.version ")")
        }
}

TestHelpLimits() {
    ids := Map()
    for topic in HelpTopics() {
        for field in ["id", "title", "words", "what", "steps", "keys", "legend"]
            Check(topic.HasOwnProp(field), "Topic " (topic.HasOwnProp("id") ? topic.id : "?") " lacks " field)
        Check(!ids.Has(topic.id), "Duplicate topic id " topic.id)
        ids[topic.id] := true
        Check(topic.steps.Length <= 6, topic.id ": " topic.steps.Length " steps, max 6")
        words := WordCount(topic.what)
        for s in topic.steps
            words += WordCount(s)
        for k in topic.keys
            words += WordCount(k[1]) + WordCount(k[2])
        for l in topic.legend
            words += WordCount(l[2])
        Check(words < 90, topic.id ": " words " words before More, must be under 90")
    }
}

TestLegendSelectors() {
    src := FileRead(Root "\MeetingRecorder.ahk", "UTF-8")
    for topic in HelpTopics()
        for l in topic.legend {
            sel := l[1]
            if SubStr(sel, 1, 1) = "?"
                continue
            Check(RegExMatch(sel, "^(\w+)\.(\w+)$", &m), topic.id ": selector must be Window.Control: " sel)
            Check(topic.HasOwnProp("view") && topic.view = m[1], topic.id ": selector " sel " is not on view " (topic.HasOwnProp("view") ? topic.view : "(none)"))
            Check(RegExMatch(src, "\bv" m[2] "\b"), topic.id ": no control named v" m[2])
        }
}

TestWhatsNewCurrent() {
    code := RunWait(PowerShell() " -File " Q(Root "\tools\Build-WhatsNew.ps1") " -Check", Root, "Hide")
    Check(code = 0, "WhatsNew.generated.ahk is out of date. Run tools\Build-WhatsNew.ps1")
    newest := ReadChangelog()[1]
    heading := "## " newest.version " - " newest.date "`n"
    Check(SubStr(WhatsNewSource(), 1, StrLen(heading)) = heading, "WhatsNewSource() does not start with " heading)
}

TestRecovery() {
    tmp := A_Temp "\MeetingRecorder-test-" A_TickCount
    DirCreate(tmp "\rec")
    DirCreate(tmp "\appdata")
    oldAppData := EnvGet("LOCALAPPDATA")
    try {
        ; 44-byte header with zero sizes, then 10 bytes: recovery keeps 8 bytes (whole frames).
        f := FileOpen(tmp "\rec\a.partial.wav", "w")
        f.RawWrite(Buffer(54, 0))
        f.Close()
        ; Too small to hold a header: must be left as it is.
        FileAppend("x", tmp "\rec\b.partial.wav")
        EnvSet("LOCALAPPDATA", tmp "\appdata")
        code := RunWait(PowerShell() " -File " Q(Root "\Backend.ps1") " -Mode Recover -Output " Q(tmp "\rec"), , "Hide")
        Check(code = 0, "Recover exited with " code)
        fixed := tmp "\rec\a - Recovered incomplete.wav"
        Check(FileExist(fixed), "Recovered file was not created")
        Check(!FileExist(tmp "\rec\a.partial.wav"), "Partial file was not renamed")
        Check(FileExist(tmp "\rec\b.partial.wav"), "Unrecoverable original was removed")
        f := FileOpen(fixed, "r")
        size := f.Length, f.Pos := 4, riff := f.ReadUInt(), f.Pos := 40, data := f.ReadUInt()
        f.Close()
        Check(size = 52 && riff = 44 && data = 8, Format("Header wrong: size {} riff {} data {}", size, riff, data))
    } finally {
        EnvSet("LOCALAPPDATA", oldAppData)
        try DirDelete(tmp, true)
    }
}

; Bug #4: setup looked for netstandard.dll in a Facades folder that .NET 4.7.1+ does not have,
; so the panel said "Install or repair .NET Framework 4.8" on PCs that had it.
; Also #4: once status.ini existed (after "Downloading..."), every later status write failed,
; so a first setup stayed at Installing. The status file starts out existing to cover that.
; Uses a temp LOCALAPPDATA that is kept between runs, so NAudio is downloaded only once.
TestBackendSetup() {
    appData := A_Temp "\MeetingRecorder-tests\appdata"
    status := A_Temp "\MeetingRecorder-tests\status-" A_TickCount ".ini"
    DirCreate(appData)
    FileAppend("[Capture]`r`nState=Installing`r`nDetail=Downloading`r`n", status, "UTF-16")
    oldAppData := EnvGet("LOCALAPPDATA")
    try {
        EnvSet("LOCALAPPDATA", appData)
        RunWait(PowerShell() " -File " Q(Root "\Backend.ps1") " -Mode Setup -Status " Q(status), , "Hide")
        state := IniRead(status, "Capture", "State", "(no status)")
        detail := IniRead(status, "Capture", "Detail", "")
        Check(state = "Ready", "Panel would show " state ": " detail)
    } finally {
        EnvSet("LOCALAPPDATA", oldAppData)
        try FileDelete(status)
    }
}

; Bug #13: Others was recorded only from the Windows default communication output. Teams played
; the call on the laptop speakers while that default was a headset, so Others was silent for a
; whole meeting. Records while a quiet tone plays on each active output device in turn; Others
; must hear it every time. Fails for the right reason only with two or more output devices.
TestOthersFromAnySpeaker() {
    appData := A_Temp "\MeetingRecorder-tests\appdata"
    deps := appData "\MeetingRecorder\backend-2.2.1"
    tmp := A_Temp "\MeetingRecorder-tests\speakers-" A_TickCount
    DirCreate(tmp)
    oldAppData := EnvGet("LOCALAPPDATA")
    pid := 0
    try {
        EnvSet("LOCALAPPDATA", appData)
        RunWait(PowerShell() " -File " Q(Root "\Backend.ps1") " -Mode Setup", , "Hide")
        list := RunOut(PowerShell() " -File " Q(Root "\tests\Play-Tone.ps1") " -Deps " Q(deps))
        speakers := []
        loop parse Trim(list, "`r`n"), "`n", "`r"
            if RegExMatch(A_LoopField, "^(\S+)`t(.+)$", &m)
                speakers.Push({id: m[1], name: m[2]})
        Check(speakers.Length, "No output devices found:`n" list)
        for s in speakers {
            status := tmp "\status" A_Index ".ini", stop := tmp "\stop" A_Index ".signal"
            wav := tmp "\rec" A_Index ".partial.wav"
            Run(PowerShell() " -File " Q(Root "\Backend.ps1") " -Mode Record -Output " Q(wav) " -Status " Q(status)
                . " -Stop " Q(stop) " -ParentId " DllCall("GetCurrentProcessId"), , "Hide", &pid)
            state := WaitState(status, "Recording", 30000)
            Check(state = "Recording", s.name ": recording did not start: " state " " IniRead(status, "Capture", "Detail", ""))
            RunWait(PowerShell() " -File " Q(Root "\tests\Play-Tone.ps1") " -Deps " Q(deps) " -Device " Q(s.id) " -Seconds 2", , "Hide")
            FileAppend("", stop)
            state := WaitState(status, "Saved", 15000)
            Check(state = "Saved", s.name ": recording was not saved: " state " " IniRead(status, "Capture", "Detail", ""))
            peak := ChannelPeak(StrReplace(wav, ".partial.wav", ".wav"), 0)
            Check(peak > 1000, "Others was silent (peak " peak ") while " s.name " played a tone")
        }
    } finally {
        EnvSet("LOCALAPPDATA", oldAppData)
        if pid && ProcessExist(pid)
            ProcessClose(pid)
        try DirDelete(tmp, true)
    }
}

; #14: Windows moved its default microphone to a Bluetooth headset when it connected, so Me was
; recorded from the headset while Teams used the Sennheiser. Settings must offer every connected
; microphone, keep a choice that is not connected just now, and show a level bar.
TestMicSettings() {
    mics := [{id: "", name: "Windows default (Headset (Sudio C8))"}, {id: "{s}", name: "Sennheiser Profile"},
        {id: "{m}", name: "Microphone Array (Intel)"}]
    cases := [
        ; stored id, stored name, what the dropdown shows, the items, what Save keeps
        ["{s}", "Sennheiser Profile", "Sennheiser Profile", 3, "{s}"],
        ["", "", "Windows default (Headset (Sudio C8))", 3, ""],
        ["{gone}", "Poly headset", "Poly headset (not connected)", 4, "{gone}"],
    ]
    for c in cases {
        g := MakeSettings("C:\Rec", "^!r", true, true, false, mics, c[1], c[2])
        try {
            items := ControlGetItems(g["Microphone"])
            Check(items.Length = c[4], "Microphone list for '" c[1] "' has " items.Length " items, expected " c[4])
            Check(items[1] = mics[1].name && items[-1] = mics[3].name, "Microphone list must start with Windows default and list each microphone")
            Check(g["Microphone"].Text = c[3], "Microphone shows '" g["Microphone"].Text "', expected '" c[3] "'")
            Check(g["Level"].Type = "Progress", "No level bar under the microphone")
            Check(MicChoice(g).id = c[5], "Save would keep '" MicChoice(g).id "', expected '" c[5] "'")
            if c[1] = "{gone}"
                Check(MicChoice(g).name = "Poly headset", "A microphone that is not connected must keep its own name")
            g["Microphone"].Value := items.Length
            Check(MicChoice(g).id = "{m}", "Picking the last microphone must save it")
            ; All microphones were muted in Windows and the bar just stayed still: say so.
            ShowLevel(g, 0.5, false)
            Check(g["Level"].Value = 50 && g["LevelHint"].Text = "Talk to test it", "Level 0.5 must fill half the bar, got " g["Level"].Value " '" g["LevelHint"].Text "'")
            ShowLevel(g, 0, true)
            Check(g["Level"].Value = 0 && g["LevelHint"].Text = "Muted in Windows", "A muted microphone must say 'Muted in Windows', got '" g["LevelHint"].Text "'")
        } finally g.Destroy()
    }
    real := MicList()
    Check(real.Length >= 1 && real[1].id = "" && RegExMatch(real[1].name, "^Windows default \(.+\)$"), "MicList must start with 'Windows default (<name>)'")
    for m in real {
        if A_Index > 1
            Check(InStr(m.id, "{0.0.1.") = 1 && m.name != "", "Not a microphone: '" m.id "' '" m.name "'")
        meter := MicMeterOpen(m.id)
        try {
            Sleep(100)
            peak := MicMeterPeak(meter)
            Check(peak >= 0 && peak <= 1, m.name ": level must be 0 to 1, got " peak)
            muted := MicMuted(meter)
            Check(muted == 0 || muted == 1, m.name ": muted must be true or false, got '" muted "'")
        } finally MicMeterClose(meter)
    }
}

; #15: large-v3 was slow and ran out of memory; turbo was twice as fast and missed fewer words.
; Fast (turbo) is the default; Accurate (large-v3) stays for meetings in other languages.
TestModelSettings() {
    fast := "Fast - best for English", accurate := "Accurate - slower, best for other languages"
    cases := [["", fast, "large-v3-turbo"], ["large-v3-turbo", fast, "large-v3-turbo"], ["large-v3", accurate, "large-v3"]]
    for c in cases {
        g := MakeSettings("C:\Rec", "^!r", true, true, false, "", "", "", c[1])
        try {
            items := ControlGetItems(g["Model"])
            Check(items.Length = 2 && items[1] = fast && items[2] = accurate, "Transcribe with must offer Fast, then Accurate")
            Check(g["Model"].Text = c[2], "Stored '" c[1] "' shows '" g["Model"].Text "', expected '" c[2] "'")
            Check(ModelChoice(g) = c[3], "Save would keep '" ModelChoice(g) "', expected '" c[3] "'")
        } finally g.Destroy()
    }
    cmd := TranscribeCommand("py.exe", "C:\App", "C:\Rec\a.wav", "s.ini", "t.tsv", "Budget.", "large-v3")
    Check(SubStr(cmd, -11) = ' "large-v3"', "The model must be the last argument: " cmd)
    cmd := TranscribeCommand("py.exe", "C:\App", "C:\Rec\a.wav", "s.ini", "t.tsv")
    Check(SubStr(cmd, -17) = ' "large-v3-turbo"', "Without a choice, Transcribe must use turbo: " cmd)
}

TestMicRecording() {
    real := MicList()
    RegExMatch(real[1].name, "^Windows default \((.+)\)$", &d)
    cases := [["{0.0.1.00000000}.{00000000-0000-0000-0000-000000000000}", d[1]]]
    if real.Length >= 2
        cases.Push([real[-1].id, real[-1].name])
    appData := A_Temp "\MeetingRecorder-tests\appdata"
    tmp := A_Temp "\MeetingRecorder-tests\mic-" A_TickCount
    DirCreate(tmp)
    oldAppData := EnvGet("LOCALAPPDATA")
    pid := 0
    try {
        EnvSet("LOCALAPPDATA", appData)
        RunWait(PowerShell() " -File " Q(Root "\Backend.ps1") " -Mode Setup", , "Hide")
        for c in cases {
            status := tmp "\status" A_Index ".ini", stop := tmp "\stop" A_Index ".signal"
            Run(PowerShell() " -File " Q(Root "\Backend.ps1") " -Mode Record -Output " Q(tmp "\rec" A_Index ".partial.wav") " -Status " Q(status)
                . " -Stop " Q(stop) " -ParentId " DllCall("GetCurrentProcessId") " -Microphone " Q(c[1]), , "Hide", &pid)
            state := WaitState(status, "Recording", 30000)
            detail := IniRead(status, "Capture", "Detail", "")
            Check(state = "Recording", "Microphone '" c[2] "': recording did not start: " state " " detail)
            Check(InStr(detail, c[2] " / ") = 1, "Expected recording from '" c[2] "', got '" detail "'")
            Sleep(1000)
            FileAppend("", stop)
            state := WaitState(status, "Saved", 15000)
            Check(state = "Saved", "Microphone '" c[2] "': recording was not saved: " state " " IniRead(status, "Capture", "Detail", ""))
        }
    } finally {
        EnvSet("LOCALAPPDATA", oldAppData)
        if pid && ProcessExist(pid)
            ProcessClose(pid)
        try DirDelete(tmp, true)
    }
}

WaitState(status, want, ms) {
    start := A_TickCount, state := "(no status)"
    while A_TickCount - start < ms {
        try state := IniRead(status, "Capture", "State", "(no status)")
        if state = want || state = "Error"
            break
        Sleep(200)
    }
    return state
}

; Highest absolute sample on one channel (0 = left = Others, 1 = right = Me) of a 16-bit stereo WAV.
ChannelPeak(file, channel) {
    data := FileRead(file, "RAW")
    peak := 0
    loop (data.Size - 44) // 4 {
        v := Abs(NumGet(data, 44 + (A_Index - 1) * 4 + channel * 2, "Short"))
        if v > peak
            peak := v
    }
    return peak
}

RunOut(cmd) {
    out := A_Temp "\MeetingRecorder-tests\out-" A_TickCount ".txt"
    RunWait(A_ComSpec ' /c "' cmd ' > ' Q(out) ' 2>&1"', , "Hide")
    text := FileRead(out, "UTF-8")
    FileDelete(out)
    return text
}

; Windows notes microphone use per app; LastUsedTimeStop = 0 means the app is using it now.
; Uses a temp registry key instead of the real ConsentStore.
TestTeamsDetection() {
    base := "HKCU\Software\MeetingRecorder-tests\microphone"
    newTeams := base "\MSTeams_8wekyb3d8bbwe"
    try {
        Check(!TeamsCallActive(base), "No Teams key, but a call was reported")
        SetMic(newTeams, 134389553262391587, 134389563469946077)
        Check(!TeamsCallActive(base), "New Teams finished its call, but a call was reported")
        SetMic(newTeams, 134389553262391587, 0)
        Check(TeamsCallActive(base), "New Teams is using the microphone, but no call was found")
        SetMic(newTeams, 1, 2)
        SetMic(base "\NonPackaged\C:#Program Files#Zoom#bin#Zoom.exe", 1, 0)
        Check(!TeamsCallActive(base), "Another app using the microphone counted as a Teams call")
        SetMic(base "\NonPackaged\C:#Users#x#AppData#Local#Microsoft#Teams#current#Teams.exe", 1, 0)
        Check(TeamsCallActive(base), "Classic Teams is using the microphone, but no call was found")
    } finally {
        RunWait(A_ComSpec ' /c reg delete "HKCU\Software\MeetingRecorder-tests" /f', , "Hide")
    }
}

SetMic(key, start, stop) {
    for name, value in Map("LastUsedTimeStart", start, "LastUsedTimeStop", stop)
        RunWait(A_ComSpec ' /c reg add "' key '" /v ' name ' /t REG_QWORD /d ' value ' /f', , "Hide")
}

; The meeting that names the file: running now or starting within 10 minutes, not all-day,
; the one whose start is closest to now. No meeting or a bad title gives "Recording".
TestMeetingName() {
    now := "20261112100000"
    M(subject, start, end, allDay := false) => {subject: subject, start: "20261112" start "00", end: "20261112" end "00", allDay: allDay}
    cases := [
        [[], ""],
        [[M("Ended", "0900", "1000")], ""],
        [[M("Holiday", "0000", "2359", true)], ""],
        [[M("Later", "1015", "1100")], ""],
        [[M("Soon", "1008", "1030")], "Soon"],
        [[M("Long", "0930", "1130"), M("Weekly sync", "1005", "1030"), M("Ended", "0800", "0900")], "Weekly sync"],
    ]
    for c in cases {
        got := PickMeeting(c[1], now)
        Check(got = c[2], "Case " A_Index ": picked '" got "', expected '" c[2] "'")
    }
    ; #10: the attendees of the picked meeting come along, for the transcript hint.
    sync := M("Weekly sync", "1005", "1030"), sync.people := "Nordmann, Kari`; Ola Hansen"
    other := M("Long", "0930", "1130"), other.people := "Someone Else"
    PickMeeting([other, sync], now, &people)
    Check(people = "Nordmann, Kari`; Ola Hansen","Attendees of the picked meeting were '" people "'")
    PickMeeting([], now, &people)
    Check(people = "", "No meeting must give no attendees, got '" people "'")
    stamp := "2026-11-12 100212", id := "1a2b3c4d"
    names := [
        ["Weekly sync", "2026-11-12 100212 - Weekly sync - 1a2b3c4d.partial.wav"],
        ["", "2026-11-12 100212 - Recording - 1a2b3c4d.partial.wav"],
        ['Q4: "Plan" / review?', "2026-11-12 100212 - Q4 Plan review - 1a2b3c4d.partial.wav"],
        [" ... ", "2026-11-12 100212 - Recording - 1a2b3c4d.partial.wav"],
        [StrReplace(Format("{:70}", ""), " ", "a"), "2026-11-12 100212 - " StrReplace(Format("{:60}", ""), " ", "a") " - 1a2b3c4d.partial.wav"],
    ]
    for n in names {
        got := RecordingName("C:\Rec", n[1], stamp, id)
        Check(got = "C:\Rec\" n[2], "Title '" n[1] "' gave " got)
    }
}

; Outlook dates reach AHK as text in the user's date format. Make that text the same way COM does.
TestComDate() {
    for oaDate, stamp in Map(46338.4375, "20261112103000", 46338.0, "20261112000000", 46024.9999884259, "20260102235959") {
        DllCall("oleaut32\VarBstrFromDate", "Double", oaDate, "UInt", 0x400, "UInt", 0, "Ptr*", &bstr := 0)
        text := StrGet(bstr), DllCall("oleaut32\SysFreeString", "Ptr", bstr)
        Check(ComDateToStamp(text) = stamp, "'" text "' gave '" ComDateToStamp(text) "', expected " stamp)
    }
    Check(ComDateToStamp("not a date") = "", "Text that is not a date must give an empty result")
}

; Bug #6: the Recording saved window is always on top, so the Word handoff question opened
; behind it. Show a window like it, open a question, and check which one is in front.
; The T5 timeout closes the question even if the check cannot.
TestNoticeBoxOnTop() {
    title := "MeetingRecorder test question " A_TickCount
    notice := Gui("+AlwaysOnTop +ToolWindow +E0x08000000", "Recording saved")
    notice.AddText("w480 h300", "Recording saved")
    notice.Show("NoActivate")
    seen := {result: "No question appeared"}
    SetTimer(Inspect, -100)
    try NoticeBox("Continue to Word?", title, "YesNo T5")
    finally notice.Destroy()
    Check(seen.result = "", seen.result)

    Inspect() {
        if !box := WinWait(title " ahk_class #32770", , 3)
            return
        order := WinGetList()
        boxAt := noticeAt := 0
        for hwnd in order
            if hwnd = box
                boxAt := A_Index
            else if hwnd = notice.Hwnd
                noticeAt := A_Index
        seen.result := boxAt && noticeAt && boxAt < noticeAt ? "" : "The question opened behind the Recording saved window"
        ControlClick("Button2", box)
    }
}

; #7: the transcript reads as a conversation. The two channels come back one after the other;
; the text puts them in time order and joins lines in a row from the same person into one turn.
; The subtitles keep every line with its exact times.
TestTranscriptText() {
    S(start, end, speaker, text) => {start: start, end: end, speaker: speaker, text: text}
    ; As Transcribe.py returns them: all of Others first, then all of Me.
    segs := [
        S(0.5, 2.0, "Others", "Good morning."),
        S(2.2, 4.0, "Others", "Shall we start?"),
        S(3725.04, 3727.5, "Others", "Thanks, bye."),
        S(4.5, 6.0, "Me", "Yes, go ahead."),
    ]
    text := "[00:00:00] Others: Good morning. Shall we start?`r`n`r`n"
        . "[00:00:04] Me: Yes, go ahead.`r`n`r`n"
        . "[01:02:05] Others: Thanks, bye.`r`n"
    Check(TranscriptText(segs) = text, "Transcript text was:`n" TranscriptText(segs))
    srt := "1`r`n00:00:00,500 --> 00:00:02,000`r`nOthers: Good morning.`r`n`r`n"
        . "2`r`n00:00:02,200 --> 00:00:04,000`r`nOthers: Shall we start?`r`n`r`n"
        . "3`r`n00:00:04,500 --> 00:00:06,000`r`nMe: Yes, go ahead.`r`n`r`n"
        . "4`r`n01:02:05,040 --> 01:02:07,500`r`nOthers: Thanks, bye.`r`n"
    Check(SubtitleText(segs) = srt, "Subtitles were:`n" SubtitleText(segs))
    Check(TranscriptText([]) = "No speech was found in this recording.`r`n", "Silent recording gave: " TranscriptText([]))
    ; #10: a pause of 2 s or more in one person's turn starts a paragraph with its own time.
    pauses := [
        S(10.0, 12.0, "Me", "First."),
        S(13.9, 15.0, "Me", "Same paragraph."),
        S(17.0, 18.0, "Me", "After a pause."),
        S(19.0, 20.0, "Others", "Reply."),
    ]
    text := "[00:00:10] Me: First. Same paragraph.`r`n`r`n"
        . "[00:00:17] After a pause.`r`n`r`n"
        . "[00:00:19] Others: Reply.`r`n"
    Check(TranscriptText(pauses) = text, "Transcript with pauses was:`n" TranscriptText(pauses))
    Check(TranscriptPath("C:\Rec\a - Incomplete.wav", "txt") = "C:\Rec\a - Incomplete.txt", "Transcript must sit next to the WAV with the same name")
}

; #10: the meeting title and attendees kept when recording starts become the hint for the
; speech model, so names come out spelled right. "Last, First" reads as "First Last"; e-mail
; addresses are left out. Older recordings use the title in the file name; "Recording" gives none.
TestMeetingHint() {
    tmp := A_Temp "\MeetingRecorder-test-" A_TickCount
    ini := tmp "\meetings.ini"
    try {
        DirCreate(tmp)
        old := "C:\Rec\2026-11-12 100212 - Q4 budget - 0a0b0c0d - Incomplete.wav"
        Check(MeetingHint(ini, old) = "Q4 budget.", "No stored details gave '" MeetingHint(ini, old) "'")
        Check(MeetingHint(ini, "C:\Rec\2026-11-12 100212 - Recording - 0a0b0c0d.wav") = "", "A recording without a meeting must give no hint")
        SaveMeetingHint(ini, "1a2b3c4d", 'Weekly "sync"', "Nordmann, Kari`; Øyvind Ås`; kari@example.com`; `; Ola Hansen")
        wav := "C:\Rec\2026-11-12 100212 - Weekly sync - 1a2b3c4d.wav"
        hint := MeetingHint(ini, wav)
        Check(hint = 'Weekly "sync". Kari Nordmann, Øyvind Ås, Ola Hansen.', "Stored details gave '" hint "'")
        Check(MeetingHint(ini, old) = "Q4 budget.", "Another recording's details were used")
        many := ""
        loop 80
            many .= "Person Number" A_Index "`; "
        SaveMeetingHint(ini, "2a2b3c4d", "Town hall", many)
        long := MeetingHint(ini, "C:\Rec\x - Town hall - 2a2b3c4d.wav")
        Check(StrLen(long) <= 400 && InStr(long, "Town hall. Person Number1, "), "A long attendee list must be cut to 400 characters, got " StrLen(long))
        cmd := TranscribeCommand("py.exe", "C:\App", wav, "s.ini", "t.tsv", hint)
        Check(InStr(cmd, ' "t.tsv" "Weekly sync. Kari Nordmann, Øyvind Ås, Ola Hansen." '), "The hint must follow the transcript file, without inner quotes: " cmd)
    } finally {
        try DirDelete(tmp, true)
    }
}

; #7: reuse PodcastClipper's portable WhisperX; this app's own install wins when both exist.
; A Python without the whisperx package does not count.
TestFindTranscriber() {
    tmp := A_Temp "\MeetingRecorder-test-" A_TickCount
    own := tmp "\MeetingRecorder\transcriber"
    clipper := tmp "\PodcastEditorTools\whisperx-python"
    try {
        DirCreate(tmp)
        Check(FindTranscriber(tmp) = "", "Nothing installed, but found " FindTranscriber(tmp))
        DirCreate(clipper), FileAppend("", clipper "\python.exe")
        Check(FindTranscriber(tmp) = "", "Python without WhisperX was accepted")
        DirCreate(clipper "\Lib\site-packages\whisperx")
        Check(FindTranscriber(tmp) = clipper "\python.exe", "PodcastClipper's WhisperX was not found")
        DirCreate(own "\Lib\site-packages\whisperx"), FileAppend("", own "\python.exe")
        Check(FindTranscriber(tmp) = own "\python.exe", "This app's own install must win, got " FindTranscriber(tmp))
    } finally {
        try DirDelete(tmp, true)
    }
}

; #7: end to end with the real WhisperX on this PC. Windows' voice speaks for Others on the left,
; then for Me on the right; the transcript next to the WAV must say who said what, in order.
; Uses the cached large-v3 model, so it takes a minute or two.
; #7: transcribing failed at 72% with "[WinError 5] Access denied: ...transcribe.ini" because the
; app was reading the status file just when the transcriber replaced it. The transcriber must wait
; for the read to end instead of failing.
TestStatusWhileRead() {
    py := FindTranscriber(EnvGet("LOCALAPPDATA"))
    if py = "" {
        Out("      skipped: WhisperX is not installed on this PC")
        return
    }
    tmp := A_Temp "\MeetingRecorder-test-" A_TickCount
    DirCreate(tmp)
    status := tmp "\transcribe.ini"
    FileAppend("[Transcribe]`r`nState=Working`r`nPercent=70`r`n", status, "UTF-16")
    ; Open the way the app's IniRead does: others may read and write, but not replace it.
    h := DllCall("CreateFileW", "Str", status, "UInt", 0x80000000, "UInt", 0x3, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
    try {
        Check(h != -1, "Could not open the status file for the test")
        code := "import sys; sys.path.insert(0, sys.argv[1]); import Transcribe; Transcribe.set_state(sys.argv[2], 'Working', 72, 'Finding who said what')"
        job := ComObject("WScript.Shell").Exec(Q(py) " -I -c " Q(code) " " Q(Root) " " Q(status))
        Sleep(1500)
        DllCall("CloseHandle", "Ptr", h), h := -1
        start := A_TickCount
        while !job.Status && A_TickCount - start < 15000
            Sleep(100)
        Check(job.Status && job.ExitCode = 0, "Writing the status while it was being read failed: " job.StdErr.ReadAll())
        Check(IniRead(status, "Transcribe", "Percent", "") = "72", "The status was not updated after the read ended")
    } finally {
        if h != -1
            DllCall("CloseHandle", "Ptr", h)
        try DirDelete(tmp, true)
    }
}
TestTranscribeSpeech() {
    py := FindTranscriber(EnvGet("LOCALAPPDATA"))
    if py = "" {
        Out("      skipped: WhisperX is not installed on this PC")
        return
    }
    tmp := A_Temp "\MeetingRecorder-test-" A_TickCount
    DirCreate(tmp)
    wav := tmp "\2026-11-13 093000 - Budget - 1a2b3c4d.wav"
    status := tmp "\transcribe.ini", segments := tmp "\transcribe.tsv"
    try {
        RunWait(PowerShell() " -File " Q(Root "\tests\Make-SpeechWav.ps1") " -Output " Q(wav)
            . ' -Others "Good morning everyone. Shall we look at the budget with Kenneth Aar?" -Me "Yes. Let us begin with the numbers."', , "Hide")
        Check(FileExist(wav), "Test speech was not generated")
        ; #12: stopped while writing down what you said, a new try keeps what others said and picks
        ; up there. The steps are reported as they go, so the app can say what it is doing.
        cmd := TranscribeCommand(py, Root, wav, status, segments, "Budget. Kenneth Aar.")
        Run(cmd, , "Hide", &pid)
        seen := Map(), start := A_TickCount
        while ProcessExist(pid) && A_TickCount - start < 600000 {
            step := IniRead(status, "Transcribe", "Step", "")
            seen[step] := true
            if step = "4" {
                ProcessClose(pid)
                break
            }
            Sleep(50)
        }
        Check(seen.Has("4"), "The transcriber never reached step 4 (writing down what you said); steps seen: " MapKeys(seen))
        Check(seen.Has("1") || seen.Has("2"), "Getting ready was not reported as step 1 or 2; steps seen: " MapKeys(seen))
        ProcessWaitClose(pid, 10)
        ; #10: the meeting hint makes the speech model spell the name right.
        RunWait(cmd, , "Hide")
        log := FileRead(status ".log", "UTF-8")
        Check(InStr(log, "Picking up where it stopped"), "The second try did not pick up where the first stopped:`n" SubStr(log, 1, 1500))
        Check(IniRead(status, "Transcribe", "Resumed", "") = "1", "The status does not say it picked up where it stopped")
        Check(!DirExist(tmp "\parts") || !FileExist(tmp "\parts\*"), "Saved parts were left behind after the transcript was done")
        state := IniRead(status, "Transcribe", "State", "(no status)")
        Check(state = "Done", "Transcriber ended in " state ": " IniRead(status, "Transcribe", "Detail", "") "`n" (FileExist(status ".log") ? SubStr(FileRead(status ".log"), -1500) : ""))
        WriteTranscript(wav, segments)
        text := FileRead(TranscriptPath(wav, "txt"), "UTF-8")
        Check(RegExMatch(text, "is)^\[00:00:0\d\] Others: [^\r\n]*budget.*\R\R\[00:00:\d\d\] Me: [^\r\n]*numbers"), "Transcript was:`n" text)
        Check(InStr(text, "Kenneth Aar", true), "The name from the hint was not spelled right:`n" text)
        Check(InStr(FileRead(TranscriptPath(wav, "srt"), "UTF-8"), "Me: "), "Subtitles were not written")
        ; #10: half the logical cores is as fast as all but one, and leaves the PC free for the call.
        threads := Max(1, EnvGet("NUMBER_OF_PROCESSORS") // 2)
        Check(RegExMatch(FileRead(status ".log", "UTF-8"), "m)^Threads: " threads "$"), "The transcriber did not use " threads " threads")
    } finally {
        try DirDelete(tmp, true)
    }
}

; #8: the window came back as "Recording saved" when the news was the transcript. Its heading
; says what is new now, and a finished transcript can be made again.
TestNoticeView() {
    cases := [
        ["Saved", "", "Recording saved", "Transcribe", false],
        ["Incomplete", "", "Recording saved, but incomplete", "Transcribe", false],
        ["Saved", "busy", "Transcribing", "Cancel", false],
        ["Saved", "ready", "Transcript ready", "Open transcript", true],
        ["Incomplete", "ready", "Transcript ready", "Open transcript", true],
        ["Saved", "failed", "Transcription failed", "Try again", false],
    ]
    for c in cases {
        v := NoticeView(c[1], c[2])
        Check(v.heading = c[3] && v.primary = c[4] && v.again = c[5],
            Format("{} / '{}': heading '{}', button '{}', again {}", c[1], c[2], v.heading, v.primary, v.again))
    }
    for name, kind in Map("C:\Rec\a - Recording - 1a2b3c4d.wav", "Saved", "C:\Rec\a - Recording - 1a2b3c4d - Incomplete.wav", "Incomplete"
        , "C:\Rec\a - Recording - 1a2b3c4d - Recovered incomplete.wav", "Incomplete")
        Check(RecordingKind(name) = kind, name " was taken as " RecordingKind(name))
}

; #8: Dismiss looked like it ended the transcription, and the tray showed no way back to it.
; While transcribing, a status line at the top of the tray menu says how far it has come.
; #9: clicking the tray icon did nothing. One click opens the panel, the menu's bold default item.
TestTrayMenu() {
    m := Menu()
    BuildTrayMenu(m)
    items := ["Open Meeting Recorder", "", "Start / stop recording", "Recordings", "Open recordings folder", ""
        , "Settings", "Help", "About Meeting Recorder", "", "Repair audio backend", "Exit"]
    Check(Join(MenuLabels(m.Handle)) = Join(items), "Tray menu was: " Join(MenuLabels(m.Handle)))
    Check(DllCall("GetMenuDefaultItem", "Ptr", m.Handle, "UInt", 1, "UInt", 0, "Int") = 0, "Open Meeting Recorder is not the default (click) item")
    Check(RegExMatch(FileRead(Root "\MeetingRecorder.ahk", "UTF-8"), "m)^A_TrayMenu\.ClickCount := 1\s*$"), "A single click on the tray icon must open the panel")
    titles := []
    for topic in HelpTopics()
        titles.Push(topic.title)
    help := DllCall("GetSubMenu", "Ptr", m.Handle, "Int", 7, "Ptr")
    Check(help && Join(MenuLabels(help)) = Join(titles), "Help submenu was: " (help ? Join(MenuLabels(help)) : "(none)"))

    Check(TrayStatusText("", 0) = "", "Idle must show no status line")
    Check(TrayStatusText("Error", 0) = "", "A failed transcription must show no status line")
    Check(TrayStatusText("Installing", 0) = "Getting the transcriber ready...", "Setup: " TrayStatusText("Installing", 0))
    Check(TrayStatusText("Working", 42) = "Transcribing: 42% done", "Working: " TrayStatusText("Working", 42))
    SetTrayStatus(m, "Transcribing: 5% done")
    Check(Join(MenuLabels(m.Handle)) = Join(["Transcribing: 5% done", ""]) "|" Join(items), "With status: " Join(MenuLabels(m.Handle)))
    SetTrayStatus(m, "Transcribing: 42% done")
    Check(Join(MenuLabels(m.Handle)) = Join(["Transcribing: 42% done", ""]) "|" Join(items), "After progress: " Join(MenuLabels(m.Handle)))
    SetTrayStatus(m, "")
    Check(Join(MenuLabels(m.Handle)) = Join(items), "After done: " Join(MenuLabels(m.Handle)))
    SetTrayStatus(m, "")
    Check(Join(MenuLabels(m.Handle)) = Join(items), "Removing twice changed the menu: " Join(MenuLabels(m.Handle)))
}

; #11: only the latest recording could be opened. Tray menu › Recordings lists the 8 newest
; saved recordings, newest first, with when, the meeting name and whether it has a transcript,
; then Other recording... for any older one.
TestRecentRecordings() {
    dir := A_Temp "\MeetingRecorder-tests\recent"
    try DirDelete(dir, true)
    DirCreate(dir)
    try {
        now := "20261113150000"
        files := ["2026-11-13 140200 - Weekly sync - 0000000A.wav", "2026-11-13 140200 - Weekly sync - 0000000A.txt"
            , "2026-11-13 150000 - Recording - 0000000F.partial.wav"
            , "2026-11-13 093000 - Recording - 0000000B - Incomplete.wav"
            , "2026-11-12 110000 - Budget & plan - 0000000C.wav", "2026-11-12 110000 - Budget & plan - 0000000E.wav"
            , "2026-11-10 151500 - 1-1 Anna - 0000000D.wav"
            , "2026-10-02 100000 - Retro - 00000010.wav", "2026-10-01 100000 - Kickoff - 00000011.wav"
            , "2025-12-01 083000 - Old review - 00000012.wav", "2025-11-30 083000 - Too old - 00000013.wav"
            , "notes.wav", "notes.txt"]
        for f in files
            FileAppend("", dir "\" f)
        FileSetTime("20261113120000", dir "\notes.wav")
        sub := Menu()
        BuildRecordingsMenu(sub, dir, now)
        expected := ["Today 14:02 - Weekly sync`tTranscript", "Today 12:00 - notes`tTranscript", "Today 09:30 - Recording"
            , "Yesterday 11:00 - Budget && plan", "Yesterday 11:00 - Budget && plan (2)"
            , FormatTime("20261110", "ddd") " 15:15 - 1-1 Anna"
            , FormatTime("20261002", "d MMM") " 10:00 - Retro", FormatTime("20261001", "d MMM") " 10:00 - Kickoff"
            , "", "Other recording..."]
        Check(Join(MenuLabels(sub.Handle)) = Join(expected), "Recordings menu was: " Join(MenuLabels(sub.Handle)))

        FileAppend("", dir "\2026-11-13 145900 - Standup - 00000014.wav")
        BuildRecordingsMenu(sub, dir, now)
        Check(MenuLabels(sub.Handle)[1] = "Today 14:59 - Standup" && MenuLabels(sub.Handle).Length = 10
            , "After a new recording, the menu was: " Join(MenuLabels(sub.Handle)))

        BuildRecordingsMenu(sub, dir "\missing", now)
        Check(Join(MenuLabels(sub.Handle)) = Join(["No recordings yet", "", "Other recording..."]), "Empty folder: " Join(MenuLabels(sub.Handle)))
        state := DllCall("GetMenuState", "Ptr", sub.Handle, "UInt", 0, "UInt", 0x400, "UInt")
        Check(state & 0x3, "No recordings yet must be greyed out")

        Check(InStr(FormatTime("20251201", "d MMM yyyy"), "2025") && RecentLabel(dir "\2025-12-01 083000 - Old review - 00000012.wav", now)
            = FormatTime("20251201", "d MMM yyyy") " 08:30 - Old review", "A recording from last year must show its year")
    } finally
        try DirDelete(dir, true)
}

; #12: transcribing sat at 0% for minutes with no sign of what it was doing. The window lists the
; steps, ticks off the finished ones and shows the one now in bold, with a moving bar while it
; gets ready. The tray icon has a ring that fills (or spins while getting ready).
TestTranscribeProgress() {
    names := ["Load the speech model", "Find where people speak", "Write down what others said", "Write down what you said"]
    n := MakeNotice("C:\Rec\2026-11-13 095900 - Market Demo MEPS - 1A2B3C4D.wav", "Saved", "")
    try {
        cases := [[1, false, 0, ["●", "○", "○", "○"], true], [2, false, 10, ["✓", "●", "○", "○"], true]
            , [3, false, 40, ["✓", "✓", "●", "○"], false], [4, true, 72, ["✓", "✓", "✓", "●"], false]]
        for c in cases {
            ShowSteps(n, c[1], c[2], c[3])
            for name in names {
                want := c[4][A_Index] " " name (c[2] && A_Index = 3 ? " (saved earlier)" : "")
                got := n["Step" A_Index]
                Check(got.Visible && got.Text = want, Format("Step {}: line {} was '{}', not '{}'", c[1], A_Index, got.Text, want))
                Check((FontWeight(got) >= 600) = (A_Index = c[1]), Format("Step {}: only the step now must be bold, line {} weight {}", c[1], A_Index, FontWeight(got)))
            }
            bar := n["TranscribeProgress"]
            marquee := !!(ControlGetStyle(bar) & 0x8)
            Check(marquee = c[5], Format("Step {}: the bar must {}move by itself", c[1], c[5] ? "" : "not "))
            if !c[5]
                Check(bar.Value = c[3], Format("Step {}: the bar shows {}, not {}%", c[1], bar.Value, c[3]))
        }
    } finally
        n.Destroy()

    Check(TrayStatusText("Working", 0, 1) = "Transcribing: getting ready...", "Tray menu while loading: " TrayStatusText("Working", 0, 1))
    Check(TrayStatusText("Working", 10, 2) = "Transcribing: getting ready...", "Tray menu while finding speech: " TrayStatusText("Working", 10, 2))
    Check(TrayStatusText("Working", 42, 4) = "Transcribing: 42% done", "Tray menu while writing: " TrayStatusText("Working", 42, 4))
    Check(TranscribeTip(0, 1, "Loading the speech model") = "Transcribing: getting ready, loading the speech model", "Tooltip while loading: " TranscribeTip(0, 1, "Loading the speech model"))
    Check(TranscribeTip(42.4, 4, "Writing down what you said") = "Transcribing: 42%, writing down what you said", "Tooltip while writing: " TranscribeTip(42.4, 4, "Writing down what you said"))

    ; The ring on the icon, read from its pixels: white where it has filled, grey where it has not.
    s := 32, right := [27, 16], left := [5, 16], bottomRight := [24, 24], topLeft := [8, 8]
    for c in [[0, -1, [right, left], []], [50, -1, [left], [right]], [100, -1, [], [right, left]], [0, 0, [topLeft], [bottomRight]]] {
        bmp := RingBitmap(s, c[1], c[2])
        try {
            for p in c[3]
                Check(PixelIs(bmp, p, "grey"), Format("{}% spin {}: ring at {},{} must be unfilled, was {:08X}", c[1], c[2], p[1], p[2], Pixel(bmp, p)))
            for p in c[4]
                Check(PixelIs(bmp, p, "white"), Format("{}% spin {}: ring at {},{} must be filled, was {:08X}", c[1], c[2], p[1], p[2], Pixel(bmp, p)))
            Check(PixelIs(bmp, [16, 16], "red"), Format("The red dot is gone at {}%, centre was {:08X}", c[1], Pixel(bmp, [16, 16])))
        } finally
            DllCall("gdiplus\GdipDisposeImage", "Ptr", bmp)
    }
    h := TrayRingIcon(42)
    Check(h, "No tray icon was made")
    DllCall("DestroyIcon", "Ptr", h)
}
Pixel(bmp, p) {
    DllCall("gdiplus\GdipBitmapGetPixel", "Ptr", bmp, "Int", p[1], "Int", p[2], "UInt*", &argb := 0)
    return argb
}
PixelIs(bmp, p, kind) {
    argb := Pixel(bmp, p), r := (argb >> 16) & 255, g := (argb >> 8) & 255, b := argb & 255
    if kind = "white"
        return r > 200 && g > 200 && b > 200
    if kind = "red"
        return r > 180 && g < 120 && b < 120
    return r < 140 && g < 140 && b < 140 && Abs(r - b) < 40
}
FontWeight(c) {
    lf := Buffer(92, 0)
    DllCall("GetObjectW", "Ptr", SendMessage(0x31, 0, 0, c), "Int", 92, "Ptr", lf)
    return NumGet(lf, 16, "Int")
}

; #8: Help opens a topic from the tray menu; About says which version this is.
TestHelpAndAbout() {
    topic := {title: "Demo", what: "What it is.", steps: ["Do this.", "Then that."], keys: [["Ctrl + Alt + R", "Start or stop."]], legend: [], more: "Extra detail."}
    expected := "What it is.`n`n1. Do this.`n2. Then that.`n`nCtrl + Alt + R: Start or stop.`n`nExtra detail."
    Check(HelpText(topic) = expected, "Help text was:`n" HelpText(topic))
    bare := {title: "Bare", what: "Only this.", steps: [], keys: [], legend: []}
    Check(HelpText(bare) = "Only this.", "Help text without steps was:`n" HelpText(bare))
    Check(InStr(AboutText("1.2.3"), "Version 1.2.3"), "About text was:`n" AboutText("1.2.3"))
}

; #8: the app has its own icon. It is set before the first window, so windows and message boxes
; get it too, and every toast uses it instead of a generic one.
TestAppIcon() {
    path := Root "\MeetingRecorder.ico"
    Check(FileExist(path), "MeetingRecorder.ico is missing")
    f := FileOpen(path, "r")
    reserved := f.ReadUShort(), type := f.ReadUShort(), count := f.ReadUShort(), sizes := Map()
    loop count {
        w := f.ReadUChar(), f.Pos += 15
        sizes[w = 0 ? 256 : w] := true
    }
    f.Close()
    Check(reserved = 0 && type = 1, "MeetingRecorder.ico is not an icon file")
    for size in [16, 32, 48, 256]
        Check(sizes.Has(size), "MeetingRecorder.ico has no " size " px image")
    src := FileRead(Root "\MeetingRecorder.ahk", "UTF-8")
    iconAt := RegExMatch(src, 'm)^TraySetIcon\(A_ScriptDir "\\MeetingRecorder\.ico"\)')
    Check(iconAt && iconAt < InStr(src, "Gui("), "TraySetIcon(MeetingRecorder.ico) must run before the first window is made")
    pos := 1
    while pos := RegExMatch(src, "TrayTip\(([^\r\n]*)\)", &m, pos) {
        Check(RegExMatch(m[1], ",\s*0x24$"), "Toast without the app icon: " m[0])
        pos += m.Len
    }
}

; #9: the windows looked broken: an empty half beside the panel buttons, a big gap above the
; Recording saved buttons, a folder box that wrapped with scroll arrows, buttons not where Windows
; puts them. Build each window as the user gets it and check what would show on screen.
TestWindowLayout() {
    wav := "C:\Rec\2026-11-13 082847 - Weekly planning with the product team and the design group - BFA76E00.wav"
    windows := []
    windows.Push(["Panel", MakePanel()])
    p := MakePanel()
    p["Settings"].Visible := false, p["NotNow"].Visible := true, p["NotNow"].Text := "Keep recording"
    windows.Push(["Panel offering a call", p])
    windows.Push(["Recording saved", MakeNotice(wav, "Saved", "")])
    n := MakeNotice(wav, "Incomplete", "The microphone stopped working.")
    ShowSteps(n, 4, true, 72)
    n["TranscribeStatus"].Text := "12 min so far. Click Hide to keep working."
    n["TranscribeStatus"].Visible := true, n["Again"].Visible := true
    n["Transcribe"].Text := "Open transcript"
    LayoutNotice(n)
    windows.Push(["Recording saved while transcribing", n])
    windows.Push(["Settings", MakeSettings("C:\Users\someone\OneDrive - A Long Company Name\Documents\Meeting Recordings", "^!r", true, true, false)])
    windows.Push(["Settings with Outlook", MakeSettings("C:\Rec", "^!r", true, true, true)])
    windows.Push(["About", MakeAbout("1.2.3", Root "\MeetingRecorder.ico")])
    for topic in HelpTopics()
        windows.Push(["Help: " topic.title, MakeHelp(topic)])
    try {
        problems := ""
        for w in windows {
            try CheckLayout(w[1], w[2])
            catch as e
                problems .= "`n      " e.Message
        }
        if DllCall("GetWindowLong", "Ptr", windows[5][2]["Folder"].Hwnd, "Int", -16, "Int") & 0x4
            problems .= "`n      Settings: the folder box must be one line"
        Check(problems = "", SubStr(problems, 8))
    } finally {
        for w in windows
            w[2].Destroy()
    }
}

; What the user sees in a window: margins the same all round, nothing overlapping, no row
; further than 20 px from the next, no text cut off, and the buttons at the bottom right.
CheckLayout(name, g) {
    g.Show("Hide AutoSize")
    g.GetClientPos(, , &cw, &ch)
    boxes := []
    for c in g {
        if !c.Visible
            continue
        c.GetPos(&x, &y, &w, &h)
        boxes.Push({c: c, x: x, y: y, r: x + w, b: y + h})
        Check(TextFits(c), name ": text is cut off in " c.Type " '" c.Text "'")
    }
    left := top := 9999, right := bottom := 0
    for b in boxes
        left := Min(left, b.x), top := Min(top, b.y), right := Max(right, b.r), bottom := Max(bottom, b.b)
    Check(left >= 8 && top >= 8, name ": controls touch the window edge")
    Check(Abs((cw - right) - left) <= 3, Format("{}: margin is {} on the left but {} on the right", name, left, cw - right))
    Check(Abs((ch - bottom) - top) <= 3, Format("{}: margin is {} at the top but {} at the bottom", name, top, ch - bottom))
    for a in boxes
        for b in boxes
            if a !== b && a.x < b.r && b.x < a.r && a.y < b.b && b.y < a.b
                Check(false, name ": '" a.c.Text "' overlaps '" b.c.Text "'")
    ; Rows: controls whose heights overlap. Then the gap between one row and the next.
    rows := []
    for b in SortBy(boxes, "y") {
        if rows.Length && b.y < rows[-1].b {
            rows[-1].b := Max(rows[-1].b, b.b), rows[-1].items.Push(b)
        } else rows.Push({y: b.y, b: b.b, items: [b]})
    }
    loop rows.Length - 1
        Check(rows[A_Index + 1].y - rows[A_Index].b <= 20, Format("{}: {} px of empty space above '{}'", name, rows[A_Index + 1].y - rows[A_Index].b, rows[A_Index + 1].items[1].c.Text))
    last := rows[-1].items
    edge := 0
    for b in last {
        Check(b.c.Type = "Button", name ": the bottom row must hold only buttons, found '" b.c.Text "'")
        Check(b.y = last[1].y && b.b = last[1].b, name ": buttons in the bottom row are not lined up")
        edge := Max(edge, b.r)
    }
    Check(Abs(edge - right) <= 1, name ": the last button does not line up with the right edge")
}
; True when the control's text fits in it at its own font.
TextFits(c) {
    if c.Type != "Text" && c.Type != "Button" && c.Type != "CheckBox" && c.Type != "Link"
        return true
    style := DllCall("GetWindowLong", "Ptr", c.Hwnd, "Int", -16, "Int")
    if c.Type = "Text" && (style & 0x1F) >= 3   ; icon or picture
        return true
    text := c.Type = "Link" ? RegExReplace(c.Text, "<[^>]+>") : c.Text
    rect := Buffer(16, 0)
    DllCall("GetClientRect", "Ptr", c.Hwnd, "Ptr", rect)
    w := NumGet(rect, 8, "Int"), h := NumGet(rect, 12, "Int")
    pad := c.Type = "Button" ? Round(16 * A_ScreenDPI / 96) : c.Type = "CheckBox" ? Round(20 * A_ScreenDPI / 96) : 0
    hdc := DllCall("GetDC", "Ptr", c.Hwnd, "Ptr")
    old := DllCall("SelectObject", "Ptr", hdc, "Ptr", SendMessage(0x31, 0, 0, c), "Ptr")
    calc := Buffer(16, 0)
    NumPut("Int", w - pad, calc, 8)
    single := c.Type != "Text" && c.Type != "Link"
    DllCall("DrawTextW", "Ptr", hdc, "Str", text, "Int", -1, "Ptr", calc, "UInt", 0x400 | 0x800 | (single ? 0x20 : 0x10))
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
    DllCall("ReleaseDC", "Ptr", c.Hwnd, "Ptr", hdc)
    needW := NumGet(calc, 8, "Int"), needH := NumGet(calc, 12, "Int")
    if c.Type = "Text" && style & 0xC000   ; ends in ... when too long: one line is enough
        return needH <= h || h >= Round(16 * A_ScreenDPI / 96)
    return needW <= w - pad && needH <= h
}
SortBy(list, key) {
    sorted := []
    for item in list {
        i := sorted.Length
        while i >= 1 && sorted[i].%key% > item.%key%
            i--
        sorted.InsertAt(i + 1, item)
    }
    return sorted
}

; #9: "Manual only" and "Preparing audio backend" meant nothing to users, and the Recording saved
; window showed the raw file name with its time stamp and id.
TestPlainWords() {
    for state in ["Installing", "Manual only", "Starting", "Saving"] {
        v := PanelLines(state, "Ctrl + Alt + R")
        Check(!RegExMatch(v.status v.hint, "i)manual only|backend|capture"), state " shows jargon: " v.status " / " v.hint)
    }
    v := PanelLines("Manual only", "Ctrl + Alt + R")
    Check(v.status = "Ready to record" && v.hint = "Start or stop: Ctrl + Alt + R", "Ready panel says: " v.status " / " v.hint)
    stamp := "20261113082847"
    when := FormatTime(stamp, "LongDate") ", " FormatTime(stamp, "HH:mm")
    cases := [
        ["C:\Rec\2026-11-13 082847 - Weekly planning - BFA76E00.wav", "Weekly planning", when],
        ["C:\Rec\2026-11-13 082847 - Recording - BFA76E00 - Incomplete.wav", "Recording", when],
        ["C:\Rec\2026-11-13 082847 - Budget - Q4 - 0A1B2C3D - Recovered incomplete.wav", "Budget - Q4", when],
        ["C:\Rec\my interview.wav", "my interview", ""],
    ]
    for c in cases {
        t := RecordingTitle(c[1])
        Check(t.name = c[2] && t.when = c[3], c[1] " showed '" t.name "' / '" t.when "'")
    }
}

; ---------------------------------------------------------------- helpers

; Labels of a menu as the user sees them, by position; separators are "".
MenuLabels(hMenu) {
    labels := []
    loop DllCall("GetMenuItemCount", "Ptr", hMenu, "Int") {
        buf := Buffer(512, 0)
        DllCall("GetMenuStringW", "Ptr", hMenu, "UInt", A_Index - 1, "Ptr", buf, "Int", 256, "UInt", 0x400)
        labels.Push(StrGet(buf))
    }
    return labels
}
MapKeys(m) {
    s := ""
    for k in m
        s .= (s = "" ? "" : ", ") (k = "" ? "(none)" : k)
    return s
}
Join(list) {
    s := ""
    for x in list
        s .= (A_Index > 1 ? "|" : "") x
    return s
}
; Stand-ins for the app's menu commands, so BuildTrayMenu() can be built here.
Toggle(*) => 0
PickRecording(*) => 0
OpenRecording(*) => 0
OpenFolder(*) => 0
Settings(*) => 0
ShowHelp(*) => 0
ShowAbout(*) => 0
Repair(*) => 0
Quit(*) => 0
ShowTranscribing(*) => 0
ShowPanel(*) => 0

Out(text) => FileAppend(text "`n", "*", "UTF-8")
Q(s) => '"' s '"'
PowerShell() => Q(A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe") " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass"

Check(condition, message) {
    if !condition
        throw Error(message)
}

WordCount(text) {
    text := Trim(RegExReplace(text, "\s+", " "))
    return text = "" ? 0 : StrSplit(text, " ").Length
}

CompareVersions(a, b) {
    pa := StrSplit(a, "."), pb := StrSplit(b, ".")
    loop 3 {
        if Integer(pa[A_Index]) != Integer(pb[A_Index])
            return Integer(pa[A_Index]) > Integer(pb[A_Index]) ? 1 : -1
    }
    return 0
}

; Returns [{version, date, items}] newest first as written. Wrapped item lines are joined.
ReadChangelog() {
    versions := [], current := ""
    for line in StrSplit(StrReplace(FileRead(Root "\CHANGELOG.md", "UTF-8"), "`r"), "`n") {
        if SubStr(line, 1, 3) = "## " {
            if !RegExMatch(line, "^## (\S+) - (\S+)$", &m)
                throw Error("Heading must be '## X.Y.Z - YYYY-MM-DD': " line)
            current := {version: m[1], date: m[2], items: []}
            versions.Push(current)
        } else if SubStr(line, 1, 2) = "- " {
            if !IsObject(current)
                throw Error("Item before the first version: " line)
            current.items.Push(line)
        } else if RegExMatch(line, "^  \S") && IsObject(current) && current.items.Length {
            current.items[-1] .= " " Trim(line)
        }
    }
    return versions
}
