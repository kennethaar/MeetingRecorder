#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off
#Include %A_ScriptDir%\..\Help.ahk
#Include %A_ScriptDir%\..\WhatsNew.generated.ahk

; Usage: AutoHotkey64.exe /ErrorStdOut tests\RunTests.ahk [part of a test name]
Root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
Filter := A_Args.Length ? A_Args[1] : ""
Tests := [
    ["Version matches newest changelog entry", TestVersion],
    ["Changelog format", TestChangelogFormat],
    ["Changelog items name a help topic", TestChangelogTopics],
    ["Help topics stay short", TestHelpLimits],
    ["Help legend selectors name real controls", TestLegendSelectors],
    ["In-app changelog copy is current", TestWhatsNewCurrent],
    ["Recovery repairs partial recordings", TestRecovery],
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
