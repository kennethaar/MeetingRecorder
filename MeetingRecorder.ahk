#Requires AutoHotkey v2.0
#SingleInstance Ignore
Persistent
AppVersion := "0.2.0"
AppDir := EnvGet("LOCALAPPDATA") "\MeetingRecorder"
DirCreate(AppDir)
Config := AppDir "\settings.ini"
Folder := IniRead(Config, "Settings", "Folder", A_MyDocuments "\Meeting Recordings")
Shortcut := IniRead(Config, "Settings", "Shortcut", "^!r")
Latest := IniRead(Config, "Settings", "Latest", "")
DetectOn := IniRead(Config, "Settings", "Detect", 1) = 1
CalendarOn := IniRead(Config, "Settings", "Calendar", 1) = 1
InCall := false        ; a Teams call is using the microphone
Offering := false      ; the panel offers to record that call
CallEnded := false     ; the call ended while recording; the panel offers Stop or Keep recording
MeetingTitle := ""     ; the Outlook meeting for the current call, or ""
PanelWasVisible := false
State := "Manual only"
Child := 0
StatusPath := AppDir "\status.ini"
StopPath := AppDir "\stop.signal"
StartTick := 0
Closing := false
Completion := 0
Panel := Gui("+AlwaysOnTop +ToolWindow +E0x08000000", "Meeting Recorder")
Panel.SetFont("s10", "Segoe UI")
Label := Panel.AddText("vStatus w350", "Preparing audio backend...")
Action := Panel.AddButton("vAction w100", "Start")
Action.OnEvent("Click", Toggle)
Panel.AddButton("vSettings x+8 w100", "Settings").OnEvent("Click", Settings)
NotNow := Panel.AddButton("vNotNow x+8 w120 Hidden", "Not now")
NotNow.OnEvent("Click", NotNowClick)
Panel.OnEvent("Close", (*) => Offering ? EndOffer() : Panel.Hide())
OnMessage(0x0010, PreventRecordingClose)
OnMessage(0x0232, RememberPosition)
OnMessage(0x0218, PowerEvent)
OnExit(ExitHandler)
A_TrayMenu.Delete()
A_TrayMenu.Add("Start / stop recording", Toggle)
A_TrayMenu.Add("Show latest recording", ShowLatest)
A_TrayMenu.Add("Open recordings", OpenFolder)
A_TrayMenu.Add("Settings", Settings)
A_TrayMenu.Add("Repair audio backend", Repair)
A_TrayMenu.Add("Exit", Quit)
try Hotkey(Shortcut, Toggle)
catch {
 MsgBox("Shortcut unavailable. Choose another in Settings.", "Meeting Recorder")
}
DirCreate(Folder)
; Recover before starting another capture. Recovery never deletes the source on failure.
RunWait(PSCommand("Recover") " -Output " Q(Folder),, "Hide")
Repair()
SetTimer(Poll, 200)
SetTimer(DetectCall, 2000)
if !FileExist(Config) {
 MsgBox("This draft records manually.`n`nLeft: all audio on your Windows communications output.`nRight: your communications microphone.`n`nMuting in a call may NOT mute this recording.`nThe app does not notify participants. Follow your organization's recording rules.`n`nFiles: " Folder "`n`nFirst launch downloads NAudio 2.2.1. Later recording works offline.`nWhen a Teams call starts, the panel offers to record it. It never records by itself.", "Set up Meeting Recorder")
 Settings()
}

Q(s) => Chr(34) s Chr(34)
PSCommand(mode) {
 return Q(A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe") " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " Q(A_ScriptDir "\Backend.ps1") " -Mode " mode
}
ShowPanel() {
 global Panel, Config
 x := IniRead(Config,"UI","X",20), y := IniRead(Config,"UI","Y",20)
 if (x < 0 || x > A_ScreenWidth - 100 || y < 0 || y > A_ScreenHeight - 60)
  x := 20, y := 20
 Panel.Show("NoActivate x" x " y" y)
}
Repair(*) {
 global State, Child, StatusPath, Label
 if Child && ProcessExist(Child)
  return
 try FileDelete(StatusPath)
 State := "Installing"
 Label.Text := "Preparing audio backend..."
 ShowPanel()
 Run(PSCommand("Setup") " -Status " Q(StatusPath),, "Hide", &Child)
}
Toggle(*) {
 global State, Child, Folder, StatusPath, StopPath, StartTick, Label, Action, InCall, MeetingTitle
 if State = "Recording" || State = "Starting" {
  StopRecording()
  return
 }
 if State = "Saving" || State = "Installing" {
  ShowPanel()
  return
 }
 if Child && ProcessExist(Child)
  return
 HideCallChoice()
 try {
  DirCreate(Folder)
  if DriveGetSpaceFree(Folder) < 512
   throw Error("Less than 512 MB free. Choose another folder.")
  probe := Folder "\.write-test-" A_TickCount
  FileAppend("test",probe), FileDelete(probe)
  try FileDelete(StopPath)
  try FileDelete(StatusPath)
  name := RecordingName(Folder, InCall ? MeetingTitle : "", FormatTime(,"yyyy-MM-dd HHmmss"), SubStr(CreateGuid(),1,8))
  State := "Starting"
  Label.Text := "Starting capture..."
  Action.Text := "Stop"
  ShowPanel()
  Run(PSCommand("Record") " -Output " Q(name) " -Status " Q(StatusPath) " -Stop " Q(StopPath) " -ParentId " DllCall("GetCurrentProcessId"),, "Hide", &Child)
  StartTick := A_TickCount
 } catch as e {
  State := "Attention required"
  Label.Text := e.Message
  ShowPanel()
 }
}
CreateGuid() {
 b := Buffer(16), s := Buffer(78)
 DllCall("ole32\CoCreateGuid","Ptr",b)
 DllCall("ole32\StringFromGUID2","Ptr",b,"Ptr",s,"Int",39)
 return StrReplace(StrReplace(StrGet(s),"{"),"}")
}
StopRecording(*) {
 global State, StopPath, Label
 if State != "Recording" && State != "Starting"
  return
 FileAppend("stop",StopPath)
 HideCallChoice()
 State := "Saving"
 Label.Text := "Saving recording..."
}
Poll() {
 global State, Child, StatusPath, StartTick, Label, Action, Latest, Config, Closing, CallEnded
 if FileExist(StatusPath) {
  s := IniRead(StatusPath,"Capture","State","")
  detail := IniRead(StatusPath,"Capture","Detail","")
  if s = "Recording" && State = "Starting" {
   State := "Recording"
   StartTick := A_TickCount
  }
  if (s = "Saved" || s = "Incomplete") && (State = "Recording" || State = "Saving" || State = "Starting") {
   separator := InStr(detail," | ")
   Latest := separator ? SubStr(detail,1,separator-1) : detail
   IniWrite(Latest,Config,"Settings","Latest")
   HideCallChoice()
   State := "Manual only"
   Label.Text := s = "Saved" ? "Recording saved" : "Attention: recording incomplete"
   Action.Text := "Start"
   SavedNotice(s,detail)
  } else if s = "Error" && State != "Attention required" {
   HideCallChoice()
   State := "Attention required"
   Label.Text := "Capture failed. Check details."
   Action.Text := "Start"
   ShowPanel()
   MsgBox(detail "`n`nCheck the recording folder for recovery audio. Use Repair audio backend if setup failed.","Recording needs attention")
  } else if s = "Ready" && State = "Installing" {
   State := "Manual only"
   Label.Text := "Manual only | " ShortcutText()
   Action.Text := "Start"
  }
 }
 if State = "Recording" {
  seconds := (A_TickCount-StartTick)//1000
  elapsed := Format("{:02}:{:02}:{:02}",seconds//3600,Mod(seconds//60,60),Mod(seconds,60))
  Label.Text := (CallEnded ? "Teams call ended. Recording  " : "Recording  ") elapsed
  A_IconTip := "Meeting Recorder`nRecording: " elapsed
 } else A_IconTip := "Meeting Recorder`n" State
 if Child && !ProcessExist(Child) {
  Child := 0
  if State = "Recording" || State = "Starting" || State = "Saving" || State = "Installing" {
   HideCallChoice()
   State := "Attention required"
   Label.Text := "Backend stopped. Recovery audio may remain."
   Action.Text := "Start"
   ShowPanel()
  }
 }
 if Closing && !Child
  ExitApp()
}
ShortcutText() {
 global Shortcut
 return Shortcut = "^!r" ? "Ctrl + Alt + R" : Shortcut
}
SavedNotice(kind,detail) {
 global Completion
 if IsObject(Completion)
  Completion.Destroy()
 Completion := Gui("+AlwaysOnTop +ToolWindow +E0x08000000","Recording saved")
 Completion.SetFont("s10","Segoe UI")
 Completion.AddText("w480",kind = "Saved" ? "Recording saved" : "Recording saved, but incomplete")
 Completion.AddText("w480",detail)
 Completion.AddButton("vWord w130","Open in Word").OnEvent("Click",WordHandoff)
 Completion.AddButton("vShowFile x+8 w110","Show file").OnEvent("Click",ShowLatest)
 Completion.AddButton("vDismiss x+8 w80","Dismiss").OnEvent("Click",(*) => Completion.Hide())
 Completion.Show("NoActivate")
}
ShowLatest(*) {
 global Latest
 if Latest != "" && FileExist(Latest)
  Run("explorer.exe /select," Q(Latest))
 else MsgBox("No saved recording is available yet.","Meeting Recorder")
}
OpenFolder(*) {
 global Folder
 Run("explorer.exe " Q(Folder))
}
WordHandoff(*) {
 global Config
 if IniRead(Config,"Settings","CloudNotice",0) != 1 {
  if MsgBox("Word Transcribe uploads audio to OneDrive. This app does not upload anything.`n`nContinue to Word?","Word handoff","YesNo") != "Yes"
   return
  IniWrite(1,Config,"Settings","CloudNotice")
 }
 ShowLatest()
 try Run("winword.exe")
 catch {
  MsgBox("Word could not open. Your recording is still saved and selected in Explorer.","Word unavailable")
  return
 }
 MsgBox("In Word: Home > Dictate > Transcribe > Upload audio.`nSelect the WAV file shown in Explorer. Access to Transcribe depends on your account.","Upload your recording")
}
Settings(*) {
 global Folder, Config, Shortcut, DetectOn, CalendarOn
 g := Gui(,"Meeting Recorder settings")
 g.SetFont("s10","Segoe UI")
 g.AddText("w510","Manual recording draft. Uses Windows communications devices.`nChanges apply to the next recording.")
 g.AddText(,"Recording folder")
 f := g.AddEdit("vFolder w510",Folder)
 g.AddButton("vBrowse w100","Browse").OnEvent("Click",(*) => BrowseFolder(f))
 g.AddText(,"Shortcut")
 h := g.AddHotkey("vShortcut w220",Shortcut)
 d := g.AddCheckbox("vDetect Checked" DetectOn,"Offer to record when a Teams call starts")
 ; Only offered when classic Outlook is installed; new Outlook has no local calendar access.
 c := OutlookInstalled() ? g.AddCheckbox("vCalendar Checked" CalendarOn,"Name recordings after the meeting in classic Outlook") : 0
 g.AddText("w510","Audio test: start a short recording, speak while playing audio, then play the saved WAV. Left = output; right = microphone.")
 g.AddButton("vSave w100 Default","Save").OnEvent("Click",SaveSettings)
 g.Show()
 SaveSettings(*) {
  global Folder, Shortcut, Config, DetectOn, CalendarOn
  try {
   newKey := h.Value
   if newKey = ""
    throw Error("Choose a shortcut.")
   if newKey != Shortcut {
    Hotkey(newKey,Toggle,"On")
    Hotkey(Shortcut,"Off")
   }
   DirCreate(f.Value)
   Folder := f.Value, Shortcut := newKey
   IniWrite(Folder,Config,"Settings","Folder")
   IniWrite(Shortcut,Config,"Settings","Shortcut")
   DetectOn := d.Value = 1
   IniWrite(DetectOn ? 1 : 0,Config,"Settings","Detect")
   if c {
    CalendarOn := c.Value = 1
    IniWrite(CalendarOn ? 1 : 0,Config,"Settings","Calendar")
   }
   g.Destroy()
  } catch as e {
   MsgBox(e.Message,"Settings not saved")
  }
 }
}
BrowseFolder(ctrl) {
 p := DirSelect(ctrl.Value,3,"Recording folder")
 if p != ""
  ctrl.Value := p
}
RememberPosition(wParam,lParam,msg,hwnd) {
 global Panel, Config
 if hwnd = Panel.Hwnd {
  Panel.GetPos(&x,&y)
  IniWrite(x,Config,"UI","X"), IniWrite(y,Config,"UI","Y")
 }
}
PreventRecordingClose(wParam,lParam,msg,hwnd) {
 global Panel, State
 if hwnd = Panel.Hwnd && (State = "Recording" || State = "Starting" || State = "Saving")
  return 0
}
PowerEvent(wParam,*) {
 if wParam = 4
  StopRecording()
}
Quit(*) {
 global Closing, Child
 Closing := true
 StopRecording()
 if !Child
  ExitApp()
}
ExitHandler(reason,code) {
 global State, StopPath, Child
 if State = "Recording" || State = "Starting" || State = "Saving" {
  try FileAppend("stop",StopPath)
  if Child
   try ProcessWaitClose(Child,8)
 }
}

; ---------------------------------------------------------------- Teams calls and Outlook meetings
; Every 2 s. Offers to record when a Teams call starts; never starts a recording by itself.
DetectCall() {
 global InCall, CallEnded, MeetingTitle, State, DetectOn, CalendarOn, Offering, NotNow
 active := DetectOn && TeamsCallActive()
 if active = InCall
  return
 InCall := active
 if active {
  MeetingTitle := CalendarOn ? PickMeeting(OutlookMeetings(), A_Now) : ""
  if State = "Manual only"
   OfferCall()
 } else if Offering {
  EndOffer()
 } else if State = "Recording" || State = "Starting" {
  CallEnded := true
  NotNow.Text := "Keep recording"
  NotNow.Visible := true
  ShowPanel()
 }
}
OfferCall() {
 global Offering, PanelWasVisible, Panel, Label, Action, NotNow, MeetingTitle
 PanelWasVisible := DllCall("IsWindowVisible","Ptr",Panel.Hwnd)
 Offering := true
 Label.Text := "Teams call started" (MeetingTitle != "" ? ": " MeetingTitle : "")
 Action.Text := "Record"
 NotNow.Text := "Not now"
 NotNow.Visible := true
 ShowPanel()
}
; Not now, or the call ended before recording: back to how the panel was.
EndOffer(*) {
 global Offering, PanelWasVisible, Panel, Label, Action
 HideCallChoice()
 Action.Text := "Start"
 Label.Text := "Manual only | " ShortcutText()
 if !PanelWasVisible
  Panel.Hide()
}
NotNowClick(*) {
 global CallEnded
 if CallEnded
  HideCallChoice()   ; Keep recording
 else EndOffer()
}
HideCallChoice() {
 global Offering, CallEnded, NotNow
 Offering := false, CallEnded := false
 NotNow.Visible := false
}

; Teams is in a call when Windows says it is using the microphone now (LastUsedTimeStop = 0).
; New Teams is a packaged app; classic Teams is listed under NonPackaged by its exe path.
TeamsCallActive(base := "HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone") {
 InUse(key) => RegQword(key,"LastUsedTimeStart") > 0 && RegQword(key,"LastUsedTimeStop") = 0
 if InUse(base "\MSTeams_8wekyb3d8bbwe")
  return true
 loop reg, base "\NonPackaged", "K"
  if RegExMatch(A_LoopRegName,"i)#(ms-)?teams\.exe$") && InUse(base "\NonPackaged\" A_LoopRegName)
   return true
 return false
}

; RegRead cannot read REG_QWORD. Returns -1 when the key or value is missing.
RegQword(key, name) {
 roots := Map("HKCU",0x80000001,"HKEY_CURRENT_USER",0x80000001,"HKLM",0x80000002,"HKEY_LOCAL_MACHINE",0x80000002)
 if !RegExMatch(key,"^([^\\]+)\\(.+)$",&m) || !roots.Has(m[1])
  return -1
 value := 0, size := 8
 if DllCall("advapi32\RegGetValueW","Ptr",roots[m[1]],"Str",m[2],"Str",name,"UInt",0x40,"Ptr",0,"Int64*",&value,"UInt*",&size,"Int")
  return -1
 return value
}

; The meeting that names the recording: running now or starting within 10 minutes, not
; all-day; when several fit, the one whose start is closest to now. "" when none fits.
PickMeeting(meetings, now) {
 best := "", bestGap := -1
 soon := DateAdd(now,10,"Minutes")
 for m in meetings {
  if m.allDay || m.start = "" || m.end = "" || m.start > soon || m.end <= now
   continue
  gap := Abs(DateDiff(m.start,now,"Seconds"))
  if bestGap < 0 || gap < bestGap
   best := m.subject, bestGap := gap
 }
 return best
}

; Today's meetings from classic Outlook, only while it is running. Never starts Outlook.
OutlookMeetings() {
 meetings := []
 try {
  items := ComObjActive("Outlook.Application").GetNamespace("MAPI").GetDefaultFolder(9).Items
  items.Sort("[Start]")
  items.IncludeRecurrences := true
  ; The %today% macro needs no date text, so it works in every locale.
  found := items.Restrict('@SQL=%today("urn:schemas:calendar:dtstart")%')
  item := found.GetFirst()
  while IsObject(item) && A_Index <= 200 {
   meetings.Push({subject: item.Subject, start: ComDateToStamp(item.Start), end: ComDateToStamp(item.End), allDay: item.AllDayEvent})
   item := found.GetNext()
  }
 }
 return meetings
}
OutlookInstalled() {
 try return RegRead("HKEY_CLASSES_ROOT\Outlook.Application\CLSID") != ""
 return false
}

; COM dates reach AHK as text in the user's date format. VarDateFromStr reads it back the same
; way. Returns YYYYMMDDHH24MISS, or "" when the text is not a date.
ComDateToStamp(text) {
 date := 0.0
 if DllCall("oleaut32\VarDateFromStr","Str",text,"UInt",0x400,"UInt",0,"Double*",&date,"Int")
  return ""
 return DateAdd("18991230",Round(date*86400),"Seconds")
}

; <folder>\<stamp> - <meeting or Recording> - <id>.partial.wav. Characters Windows does not
; allow in file names become spaces; the title is kept to 60 characters.
RecordingName(folder, title, stamp, id) {
 title := RegExReplace(title,'[\\/:*?"<>|\x00-\x1F]'," ")
 title := Trim(SubStr(Trim(RegExReplace(title,"\s+"," ")," ."),1,60)," .")
 return folder "\" stamp " - " (title = "" ? "Recording" : title) " - " id ".partial.wav"
}

; ---------------------------------------------------------------- help topics
; Rules (enforced by tests\RunTests.ahk, which copies this function out via tests\Run-Tests.ps1):
; - at most 6 steps and under 90 words before the More fold (what, steps, keys, legend)
; - legend: [selector, text] in reading order; selector is View.ControlName (the control's v-name);
;   a leading ? marks something that is not always on screen
; - view: the window the topic is about (Panel, Settings, Saved); only for screen-specific topics
; - more: detail shown below the More fold
; CHANGELOG.md items must start with one of these titles.
; Keep the closing brace of HelpTopics() as the first "}" at the start of a line in this function.

HelpTopics() {
    return [
        {
            id: "record",
            title: "Record a meeting",
            words: "start stop record call meeting audio shortcut panel timer microphone",
            what: "Records your call to a WAV file. The left channel is what you hear. The right channel is your microphone.",
            steps: [
                "Press Ctrl + Alt + R, or click Start.",
                "Wait until the timer runs. Then the recording has begun.",
                "Press the shortcut again, or click Stop, to save.",
            ],
            keys: [["Ctrl + Alt + R", "Start or stop. You can change it in Settings."]],
            legend: [
                ["Panel.Status", "Status and recording time"],
                ["Panel.Action", "Start or stop recording"],
                ["Panel.Settings", "Open settings"],
            ],
            view: "Panel",
            more: "Muting yourself in the call may not mute this recording. Other people are not told that you record. Follow the recording rules where you work. A recording stops by itself after five hours.",
        },
        {
            id: "teams",
            title: "Teams calls",
            words: "teams call meeting detect automatic offer outlook calendar name file",
            what: "When a Teams call starts, the panel offers to record it. It never records by itself.",
            steps: [
                "Join a Teams call. The panel says Teams call started.",
                "Click Record, or press Ctrl + Alt + R. Click Not now to skip this call.",
                "When the call ends, click Stop to save, or Keep recording.",
            ],
            keys: [],
            legend: [
                ["Panel.Status", "The call and its meeting name"],
                ["Panel.Action", "Record the call"],
                ["?Panel.NotNow", "Skip this call, or keep recording after it ends"],
            ],
            view: "Panel",
            more: "A call is found when Teams uses your microphone. If classic Outlook is open, the file is named after the meeting that is on now. The app never starts Outlook. You can turn both off in Settings.",
        },
        {
            id: "settings",
            title: "Settings",
            words: "settings folder shortcut hotkey save location options teams outlook calendar",
            what: "Choose where recordings are saved, which keys start and stop them, and what happens in Teams calls.",
            steps: [
                "Open Settings from the panel or the tray menu.",
                "Type a folder, or click Browse.",
                "Click the shortcut box and press the new keys.",
                "Click Save. Changes apply to the next recording.",
            ],
            keys: [],
            legend: [
                ["Settings.Folder", "Where recordings are saved"],
                ["Settings.Browse", "Pick a folder"],
                ["Settings.Shortcut", "Keys that start and stop"],
                ["Settings.Detect", "Offer to record Teams calls"],
                ["?Settings.Calendar", "Name files after classic Outlook meetings"],
                ["Settings.Save", "Save changes"],
            ],
            view: "Settings",
            more: "The Outlook choice is shown only when classic Outlook is installed. Settings are kept in %LOCALAPPDATA%\MeetingRecorder\settings.ini.",
        },
        {
            id: "word",
            title: "Open in Word",
            words: "word transcribe transcript text onedrive upload saved",
            what: "Send a saved recording to Word Transcribe to get it as text.",
            steps: [
                "When a recording is saved, click Open in Word.",
                "In Word, choose Home, Dictate, Transcribe, Upload audio.",
                "Pick the WAV file shown in Explorer.",
            ],
            keys: [],
            legend: [
                ["Saved.Word", "Open Word and show the file"],
                ["Saved.ShowFile", "Show the file in Explorer"],
                ["Saved.Dismiss", "Close this message"],
            ],
            view: "Saved",
            more: "Word uploads the audio to OneDrive. This app uploads nothing. Whether you can use Transcribe depends on your Microsoft account.",
        },
        {
            id: "recovery",
            title: "Recovered recordings",
            words: "recover recovered incomplete crash lost broken partial",
            what: "If the app or PC stopped during a recording, the audio is rescued the next time the app starts.",
            steps: [
                "Start Meeting Recorder.",
                "Right-click the tray icon and choose Open recordings.",
                "Look for files that end in Recovered incomplete.",
            ],
            keys: [],
            legend: [],
            more: "Only the current recording folder is checked. If a file cannot be repaired, the original stays as it is. Nothing is ever deleted.",
        },
        {
            id: "backend",
            title: "Audio backend",
            words: "repair backend download naudio install setup offline error",
            what: "The first time it starts, the app downloads a small audio library. After that it works offline.",
            steps: [
                "If recording will not start, right-click the tray icon.",
                "Choose Repair audio backend.",
                "Wait until the panel says Manual only.",
            ],
            keys: [],
            legend: [],
            more: "The library is NAudio 2.2.1 from NuGet. Its checksum is checked after download. To download it again, close the app, delete %LOCALAPPDATA%\MeetingRecorder\backend-2.2.1 and start the app.",
        },
    ]
}
