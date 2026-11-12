#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off
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
    ["Teams call is found from microphone use (#5)", TestTeamsDetection],
    ["Recording is named after the meeting running now (#5)", TestMeetingName],
    ["Outlook dates are read in any locale (#5)", TestComDate],
    ["Questions from the Recording saved window show on top of it (#6)", TestNoticeBoxOnTop],
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

; ---------------------------------------------------------------- helpers

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
