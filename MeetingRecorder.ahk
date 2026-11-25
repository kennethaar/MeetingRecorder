#Requires AutoHotkey v2.0
#SingleInstance Ignore
Persistent
; Set before the first window: windows, message boxes and toasts use the tray icon (#8).
TraySetIcon(A_ScriptDir "\MeetingRecorder.ico")
AppVersion := "0.13.0"
AppDir := EnvGet("LOCALAPPDATA") "\MeetingRecorder"
DirCreate(AppDir)
; What the app, Backend.ps1 and the capture engine did, to find out what went wrong (#21).
LogPath := AppDir "\MeetingRecorder.log"
AppLog("Started v" AppVersion " (AutoHotkey " A_AhkVersion ", Windows " A_OSVersion ") from " A_ScriptFullPath)
OnError((e, *) => (AppLog("Error: " e.Message (e.Extra = "" ? "" : " (" e.Extra ")") " in " e.What " at line " e.Line), 0))
Config := AppDir "\settings.ini"
Folder := IniRead(Config, "Settings", "Folder", A_MyDocuments "\Meeting Recordings")
Shortcut := IniRead(Config, "Settings", "Shortcut", "^!r")
Latest := IniRead(Config, "Settings", "Latest", "")
DetectOn := IniRead(Config, "Settings", "Detect", 1) = 1
CalendarOn := IniRead(Config, "Settings", "Calendar", 1) = 1
; Start with Windows (#20): a shortcut in the Startup folder, checked at every start.
StartupOn := IniRead(Config, "Settings", "Startup", 1) = 1
StartupLink := A_Startup "\Meeting Recorder.lnk"
; Microphone for Me (#14): device id, or "" for the Windows default. The name is kept to show it
; while it is not connected.
Microphone := IniRead(Config, "Settings", "Microphone", "")
MicrophoneName := IniRead(Config, "Settings", "MicrophoneName", "")
; Speech model for Transcribe (#15): large-v3-turbo (Fast) or large-v3 (Accurate).
SpeechModel := IniRead(Config, "Settings", "Model", "large-v3-turbo") = "large-v3" ? "large-v3" : "large-v3-turbo"
InCall := false        ; a Teams call is using the microphone
; The recording and the Teams call (#17): "Started" = started for a call, Keep recording or
; Discard; "Ended" = the call ended while recording, Stop or Keep recording; "" = no question.
CallPhase := ""
Discarding := false    ; Discard was clicked; the saved file goes to the Recycle Bin
MeetingTitle := ""     ; the Outlook meeting for the current call, or ""
MeetingPeople := ""    ; its attendees, for the transcript hint (#10)
PanelWasVisible := false
State := "Manual only"
Child := 0
StatusPath := AppDir "\status.ini"
StopPath := AppDir "\stop.signal"
StartTick := 0
Closing := false
Restarting := false   ; Tray menu › Restart: start again once Closing is done
Completion := 0
CompletionWav := ""    ; the recording the Recording saved window is about
CompletionKind := ""   ; "Saved" or "Incomplete"
; Transcription on this PC (#7). TxState: "", "Installing", "Working", "Error".
TxState := "", TxWav := "", TxPid := 0, TxStart := 0, TxPercent := 0, TxDetail := ""
TxStep := 0, TxResumed := false   ; step 1-4 and whether an earlier try's part was kept (#12)
TxDownload := ""   ; a model download's progress, from the transcriber (#16)
TxStatusPath := AppDir "\transcribe.ini"
TxSegmentsPath := AppDir "\transcribe.tsv"
TxSetupPath := AppDir "\transcriber-setup.ini"
Panel := MakePanel()
Action := Panel["Action"]
Action.OnEvent("Click", ActionClick)
SettingsButton := Panel["Settings"]
SettingsButton.OnEvent("Click", Settings)
NotNow := Panel["NotNow"]
NotNow.OnEvent("Click", NotNowClick)
Panel.OnEvent("Close", (*) => Panel.Hide())
OnMessage(0x0010, PreventRecordingClose)
OnMessage(0x0232, RememberPosition)
OnMessage(0x0218, PowerEvent)
OnMessage(0x0404, TrayIconEvent)
OnExit(ExitHandler)
A_TrayMenu.Delete()
BuildTrayMenu(A_TrayMenu)
; One click on the tray icon opens the panel (#9).
A_TrayMenu.ClickCount := 1
try Hotkey(Shortcut, Toggle)
catch as e {
 AppLog("Shortcut " Shortcut " is unavailable: " e.Message)
 MsgBox("Shortcut unavailable. Choose another in Settings.", "Meeting Recorder")
}
try {
 if (change := SetStartWithWindows(StartupOn, StartupLink)) != ""
  AppLog(change)
} catch as e
 AppLog("Start with Windows could not be set: " e.Message)
DirCreate(Folder)
; Recover before starting another capture. Recovery never deletes the source on failure.
RunWait(PSCommand("Recover") " -Output " Q(Folder),, "Hide")
Repair()
SetTimer(Poll, 200)
SetTimer(DetectCall, 2000)
if !FileExist(Config) {
 MsgBox("Meeting Recorder records your calls on this PC. Start or stop with " ShortcutText() ".`n`nWhen a Teams call starts, it starts recording at once. Click Discard if you do not want it.`n`nMuting yourself in the call may not mute the recording. Others are not told that you record, so follow the rules where you work.", "Welcome to Meeting Recorder", "Iconi")
 Settings()
}

; ---------------------------------------------------------------- windows (#9)
; Layout rules, checked by the layout test: the same margin all round, buttons at the bottom
; right, and no space held for hidden controls. Text that may be too long ends in "..." (0x4000).
; The panel: what is happening, a quiet hint below it, and two buttons. Discard / Keep recording
; (vNotNow) takes the place of Settings while the panel asks about a Teams call.
MakePanel() {
 g := Gui("+AlwaysOnTop +ToolWindow +E0x08000000", "Meeting Recorder")
 g.MarginX := 14, g.MarginY := 12
 g.SetFont("s11 w600", "Segoe UI")
 g.AddText("vStatus w280 +0x4000", "Getting ready...")
 g.SetFont("s9 w400 c595959")
 g.AddText("vHint y+2 w280 +0x4000", "")
 g.SetFont("s10 cDefault")
 g.AddButton("vAction xm y+10 w136 Default", "Start")
 g.AddButton("vSettings x+8 w136", "Settings")
 g.AddButton("vNotNow xp yp w136 Hidden", "Not now")
 return g
}
; The two lines of the panel in a steady state.
PanelLines(state, shortcut) {
 if state = "Installing"
  return {status: "Getting ready...", hint: "The first start takes a minute."}
 if state = "Manual only"
  return {status: "Ready to record", hint: "Start or stop: " shortcut}
 if state = "Starting"
  return {status: "Starting...", hint: "Start or stop: " shortcut}
 if state = "Saving"
  return {status: "Saving...", hint: "Keep the app open until it is saved."}
 return {status: state, hint: ""}
}
Q(s) => Chr(34) s Chr(34)
PSCommand(mode) {
 return Q(A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe") " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " Q(A_ScriptDir "\Backend.ps1") " -Mode " mode
}
; The panel's two lines: what is happening, and a quiet hint below it.
SetStatus(status, hint := "") {
 global Panel
 Panel["Status"].Text := status
 Panel["Hint"].Text := hint
}
ShowState() {
 global State
 v := PanelLines(State, ShortcutText())
 SetStatus(v.status, v.hint)
}
ShowPanel(*) {
 global Panel, Config
 x := IniRead(Config,"UI","X",20), y := IniRead(Config,"UI","Y",20)
 if (x < 0 || x > A_ScreenWidth - 100 || y < 0 || y > A_ScreenHeight - 60)
  x := 20, y := 20
 Panel.Show("NoActivate x" x " y" y)
}
Repair(*) {
 global State, Child, StatusPath
 if Child && ProcessExist(Child)
  return
 try FileDelete(StatusPath)
 AppLog("Audio backend setup started")
 State := "Installing"
 ShowState()
 ShowPanel()
 Run(PSCommand("Setup") " -Status " Q(StatusPath),, "Hide", &Child)
}
Toggle(*) {
 global State, Child, Folder, StatusPath, StopPath, StartTick, Action, InCall, MeetingTitle, MeetingPeople
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
 SetCallPhase("")
 try {
  DirCreate(Folder)
  if DriveGetSpaceFree(Folder) < 512
   throw Error("Less than 512 MB free. Choose another folder.")
  probe := Folder "\.write-test-" A_TickCount
  FileAppend("test",probe), FileDelete(probe)
  try FileDelete(StopPath)
  try FileDelete(StatusPath)
  id := SubStr(CreateGuid(),1,8), title := InCall ? MeetingTitle : ""
  name := RecordingName(Folder, title, FormatTime(,"yyyy-MM-dd HHmmss"), id)
  if title != ""
   try SaveMeetingHint(AppDir "\meetings.ini", id, title, MeetingPeople)   ; never blocks a recording
  AppLog("Start recording" (InCall ? " for a Teams call" : "") ": " name (Microphone = "" ? "" : ", microphone " MicrophoneName))
  State := "Starting"
  ShowState()
  Action.Text := "Stop"
  ShowPanel()
  Run(PSCommand("Record") " -Output " Q(name) " -Status " Q(StatusPath) " -Stop " Q(StopPath) " -ParentId " DllCall("GetCurrentProcessId") (Microphone = "" ? "" : " -Microphone " Q(Microphone)),, "Hide", &Child)
  StartTick := A_TickCount
 } catch as e {
  AppLog("Cannot start recording: " e.Message)
  State := "Attention required"
  SetStatus("Cannot start recording", e.Message)
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
 global State, StopPath
 if State != "Recording" && State != "Starting"
  return
 AppLog("Stop recording")
 FileAppend("stop",StopPath)
 SetCallPhase("")
 State := "Saving"
 ShowState()
}
Poll() {
 global State, Child, StatusPath, StartTick, Action, Latest, Config, Closing, CallPhase, MeetingTitle, Discarding, PanelWasVisible, Panel, TxState, TxPercent, TxStep, TxDetail
 if FileExist(StatusPath) {
  s := IniRead(StatusPath,"Capture","State","")
  detail := IniRead(StatusPath,"Capture","Detail","")
  if s = "Recording" && State = "Starting" {
   State := "Recording"
   StartTick := A_TickCount
  }
  if (s = "Saved" || s = "Incomplete") && (State = "Recording" || State = "Saving" || State = "Starting") {
   separator := InStr(detail," | ")
   wav := separator ? SubStr(detail,1,separator-1) : detail
   SetCallPhase("")
   ; Discard (#17): to the Recycle Bin, and the panel goes back to how it was. If that fails,
   ; the recording is kept and shown as saved.
   discard := Discarding
   Discarding := false
   if discard
    AppLog("Discard: " wav)
   if discard && DiscardRecording(wav) {
    AppLog("Discarded: moved to the Recycle Bin")
    State := "Manual only"
    ShowState()
    Action.Text := "Start"
    if !PanelWasVisible
     Panel.Hide()
    return
   }
   Latest := wav
   IniWrite(Latest,Config,"Settings","Latest")
   State := "Manual only"
   SetStatus(s = "Saved" ? "Recording saved" : "Recording incomplete", "Start or stop: " ShortcutText())
   Action.Text := "Start"
   OpenNotice(Latest, s, separator ? SubStr(detail,separator+3) : "")
  } else if s = "Error" && State != "Attention required" {
   SetCallPhase(""), Discarding := false
   State := "Attention required"
   SetStatus("Recording failed", "Look in the recording folder for rescued audio.")
   Action.Text := "Start"
   ShowPanel()
   MsgBox(detail "`n`nCheck the recording folder for recovery audio. Use Repair audio backend if setup failed.","Recording needs attention")
  } else if s = "Ready" && State = "Installing" {
   State := "Manual only"
   ShowState()
   Action.Text := "Start"
  }
 }
 if State = "Recording" {
  seconds := (A_TickCount-StartTick)//1000
  elapsed := Format("{:02}:{:02}:{:02}",seconds//3600,Mod(seconds//60,60),Mod(seconds,60))
  v := RecordingLines(elapsed, ShortcutText(), CallPhase, MeetingTitle)
  SetStatus(v.status, v.hint)
  A_IconTip := "Meeting Recorder`nRecording: " elapsed
 } else A_IconTip := "Meeting Recorder`n" State (TxState = "Working" ? "`n" TranscribeTip(TxPercent, TxStep, TxDetail) : "")
 if Child && !ProcessExist(Child) {
  Child := 0
  if State = "Recording" || State = "Starting" || State = "Saving" || State = "Installing" {
   AppLog("The audio helper closed while " State ", without saying why")
   SetCallPhase(""), Discarding := false
   State := "Attention required"
   SetStatus("Recording stopped", "Look in the recording folder for rescued audio.")
   Action.Text := "Start"
   ShowPanel()
  }
 }
 static logged := ""
 if State != logged
  AppLog("State: " (logged := State))
 if Closing && !Child
  Leave()
}
ShortcutText() {
 global Shortcut
 return Shortcut = "^!r" ? "Ctrl + Alt + R" : Shortcut
}
; The Recording saved window: one recording and its transcript. kind is "Saved" or "Incomplete";
; note is why it is incomplete. Hide keeps transcribing; the tray menu brings it back (#8).
OpenNotice(wav,kind,note:="") {
 global Completion
 ReplaceNotice(wav,kind,note)
 Completion["Transcribe"].OnEvent("Click",TranscribeClick)
 Completion["ShowFile"].OnEvent("Click",(*) => ShowInExplorer(CompletionWav))
 Completion["Again"].OnEvent("Click",TranscribeAgain)
 Completion["Hide"].OnEvent("Click",HideNotice)
 Completion.OnEvent("Close",HideNotice)
 Completion.OnEvent("Escape",HideNotice)
 ShowTranscribeState()
 Completion.Show("AutoSize NoActivate")
}
; Makes the new window before closing the old one, so the transcribing timer, which can run at any
; moment, never updates a closed window (#18).
ReplaceNotice(wav,kind,note) {
 global Completion, CompletionWav, CompletionKind
 n := MakeNotice(wav,kind,note)
 old := Completion
 Completion := n, CompletionWav := wav, CompletionKind := kind
 if IsObject(old)
  old.Destroy()
 return n
}
; Heading, the meeting name, when it was recorded (and why it is incomplete), the transcribing
; status and progress when there is any, then the buttons with Hide at the right.
MakeNotice(wav,kind,note) {
 t := RecordingTitle(wav)
 when := Trim(t.when "`n" note, "`n")
 g := Gui("+AlwaysOnTop +ToolWindow +E0x08000000","Meeting Recorder")
 g.MarginX := 16, g.MarginY := 14
 g.SetFont("s12 w600","Segoe UI")
 g.AddText("vHeading w480",NoticeView(kind,"").heading)
 g.SetFont("s10 w400")
 g.AddText("vFileName w480",t.name)
 g.SetFont("s9 c595959")
 g.AddText("vWhen w480" (when = "" ? " Hidden" : ""),when)
 g.SetFont("s10 cDefault")
 loop 4
  g.AddText("vStep" A_Index " w480 Hidden")
 g.AddProgress("vTranscribeProgress w480 h8 Hidden")
 g.AddText("vTranscribeStatus w480 Hidden")
 g.AddButton("vTranscribe w130 Default","Transcribe")
 g.AddButton("vShowFile x+8 w100","Show file")
 g.AddButton("vAgain x+8 w130 Hidden","Transcribe again")
 g.AddButton("vHide x416 yp w80","Hide")
 LayoutNotice(g)
 return g
}
; Stacks the visible rows with no space for hidden ones. Returns true when the buttons moved.
LayoutNotice(g) {
 g["Heading"].GetPos(,&y,,&h)
 y += h
 started := false   ; the transcribing rows start 12 px below the recording's name and time
 for row in [["FileName",6],["When",2],["Step1",2],["Step2",2],["Step3",2],["Step4",2],["TranscribeProgress",8],["TranscribeStatus",6]] {
  c := g[row[1]]
  if !c.Visible
   continue
  gap := row[2]
  if !started && row[1] != "FileName" && row[1] != "When"
   gap := 12, started := true
  if c.Type = "Text"
   FitHeight(c)
  c.GetPos(,,,&h)
  c.Move(,y += gap)
  y += h
 }
 y += 16
 g["Transcribe"].GetPos(,&was)
 for name in ["Transcribe","ShowFile","Again","Hide"]
  g[name].Move(,y)
 return was != y
}
; Makes a text control as tall as its wrapped text.
FitHeight(c) {
 r := Buffer(16,0)
 DllCall("GetClientRect","Ptr",c.Hwnd,"Ptr",r)
 hdc := DllCall("GetDC","Ptr",c.Hwnd,"Ptr")
 old := DllCall("SelectObject","Ptr",hdc,"Ptr",SendMessage(0x31,0,0,c),"Ptr")
 DllCall("DrawTextW","Ptr",hdc,"Str",c.Text = "" ? " " : c.Text,"Int",-1,"Ptr",r,"UInt",0x400|0x800|0x10)
 DllCall("SelectObject","Ptr",hdc,"Ptr",old)
 DllCall("ReleaseDC","Ptr",c.Hwnd,"Ptr",hdc)
 c.Move(,,,Ceil(NumGet(r,12,"Int")*96/A_ScreenDPI))
}
; The meeting name and when it was recorded, from <stamp> - <name> - <id>[ - Incomplete].wav.
; Any other file name is shown as it is.
RecordingTitle(wav) {
 SplitPath(wav,,,,&base)
 base := RegExReplace(base,"i) - (Recovered incomplete|Incomplete)$")
 if !RegExMatch(base,"i)^(\d{4})-(\d\d)-(\d\d) (\d{6}) - (.+) - [0-9A-F]{8}$",&m) || !IsTime(m[1] m[2] m[3] m[4])
  return {name: base, when: ""}
 stamp := m[1] m[2] m[3] m[4]
 return {name: m[5], when: FormatTime(stamp,"LongDate") ", " FormatTime(stamp,"HH:mm")}
}
; What the window says for a recording: tx is "", "busy", "ready" or "failed".
NoticeView(kind,tx) {
 if tx = "busy"
  return {heading: "Transcribing", primary: "Cancel", again: false}
 if tx = "ready"
  return {heading: "Transcript ready", primary: "Open transcript", again: true}
 if tx = "failed"
  return {heading: "Transcription failed", primary: "Try again", again: false}
 return {heading: kind = "Incomplete" ? "Recording saved, but incomplete" : "Recording saved", primary: "Transcribe", again: false}
}
RecordingKind(wav) {
 return RegExMatch(wav,"i) incomplete\.wav$") ? "Incomplete" : "Saved"
}
HideNotice(*) {
 global Completion, TxState
 static told := false
 Completion.Hide()
 if !told && (TxState = "Working" || TxState = "Installing") {
  told := true
  TrayTip("Transcribing goes on. Right-click the tray icon to see how far it has come.","Meeting Recorder",0x24)
 }
 return true
}
; The Recording saved window is always on top; messages opened from it must be too (#6).
NoticeBox(text,title,options:="") {
 return MsgBox(text,title,options " 0x40000")
}
ShowInExplorer(wav) {
 if FileExist(wav)
  Run("explorer.exe /select," Q(wav))
 else NoticeBox("The recording is no longer in its folder.","Meeting Recorder")
}
; Tray menu › Recordings › Other recording...: any saved recording, also an older one (#11).
PickRecording(*) {
 global Folder
 path := FileSelect(1,Folder "\","Open a recording","Recordings (*.wav)")
 if path = ""
  return
 if RegExMatch(path,"i)\.partial\.wav$") {
  NoticeBox("This recording is still being made. Open it when it is saved.","Meeting Recorder")
  return
 }
 OpenRecording(path)
}
OpenRecording(wav,*) {
 if FileExist(wav)
  OpenNotice(wav,RecordingKind(wav))
 else NoticeBox("The recording is no longer in its folder.","Meeting Recorder")
}
; Tray menu › Recordings: the 8 newest saved recordings, newest first, then Other recording... (#11).
BuildRecordingsMenu(sub,folder,now:="") {
 sub.Delete()
 used := Map()
 for wav in RecentRecordings(folder,8) {
  label := StrReplace(RecentLabel(wav,now),"&","&&")
  n := 1
  while used.Has(label (n > 1 ? " (" n ")" : ""))
   n++
  label .= n > 1 ? " (" n ")" : ""
  used[label] := true
  sub.Add(label (FileExist(TranscriptPath(wav,"txt")) ? "`tTranscript" : ""),OpenRecording.Bind(wav))
 }
 if !used.Count {
  sub.Add("No recordings yet",(*) => 0)
  sub.Disable("No recordings yet")
 }
 sub.Add()
 sub.Add("Other recording...",PickRecording)
}
; Saved recordings in the folder, newest first: by the time in the name, else when last changed.
RecentRecordings(folder,count) {
 list := ""
 if folder = ""
  return []
 loop files folder "\*.wav" {
  if RegExMatch(A_LoopFileName,"i)\.partial\.wav$")
   continue
  stamp := RegExMatch(A_LoopFileName,"^(\d{4})-(\d\d)-(\d\d) (\d{6}) - ",&m) && IsTime(m[1] m[2] m[3] m[4])
   ? m[1] m[2] m[3] m[4] : A_LoopFileTimeModified
  list .= stamp "`t" A_LoopFileFullPath "`n"
 }
 recent := []
 for line in StrSplit(Sort(RTrim(list,"`n"),"R"),"`n") {
  if line = "" || recent.Length >= count
   break
  recent.Push(SubStr(line,InStr(line,"`t")+1))
 }
 return recent
}
; "Today 14:02 - Weekly sync": the day (Today, Yesterday, weekday, date), the time and the name.
RecentLabel(wav,now:="") {
 now := now = "" ? A_Now : now
 SplitPath(wav,&file)
 stamp := RegExMatch(file,"^(\d{4})-(\d\d)-(\d\d) (\d{6}) - ",&m) && IsTime(m[1] m[2] m[3] m[4])
  ? m[1] m[2] m[3] m[4] : FileGetTime(wav,"M")
 days := DateDiff(SubStr(now,1,8),SubStr(stamp,1,8),"Days")
 day := days = 0 ? "Today" : days = 1 ? "Yesterday" : days > 1 && days < 7 ? FormatTime(stamp,"ddd")
  : SubStr(stamp,1,4) = SubStr(now,1,4) ? FormatTime(stamp,"d MMM") : FormatTime(stamp,"d MMM yyyy")
 return day " " FormatTime(stamp,"HH:mm") " - " RecordingTitle(wav).name
}
; Fills Recordings again just before the tray menu opens, so it shows what is in the folder now.
TrayIconEvent(wParam,lParam,*) {
 global RecentMenu, Folder
 if lParam = 0x205 || lParam = 0x7B
  BuildRecordingsMenu(RecentMenu,Folder)
}
ShowTranscribing(*) {
 global Completion, CompletionWav, TxWav
 if IsObject(Completion) && CompletionWav = TxWav
  Completion.Show("AutoSize NoActivate")
 else OpenNotice(TxWav,RecordingKind(TxWav))
}
BuildTrayMenu(m) {
 m.Add("Open Meeting Recorder",ShowPanel)
 m.Default := "Open Meeting Recorder"
 m.Add()
 m.Add("Start / stop recording",Toggle)
 global RecentMenu := Menu()
 BuildRecordingsMenu(RecentMenu,"")
 m.Add("Recordings",RecentMenu)
 m.Add("Open recordings folder",OpenFolder)
 m.Add()
 m.Add("Settings",Settings)
 help := Menu()
 for topic in HelpTopics()
  help.Add(topic.title,ShowHelp.Bind(topic))
 m.Add("Help",help)
 m.Add("About Meeting Recorder",ShowAbout)
 m.Add()
 m.Add("Repair audio backend",Repair)
 m.Add("Open log file",OpenLog)
 m.Add("Restart",Restart)
 m.Add("Exit",Quit)
}
; The top line of the tray menu while transcribing; "" when there is nothing to show.
; Steps 1 and 2 have no percent yet, so they say getting ready instead of 0% (#12).
TrayStatusText(state,percent,step:=3) {
 if state = "Installing"
  return "Getting the transcriber ready..."
 if state = "Working"
  return step <= 2 ? "Transcribing: getting ready..." : "Transcribing: " percent "% done"
 return ""
}
; The tray icon's tooltip line while transcribing: how far, and what it is doing (#12).
TranscribeTip(percent,step,detail) {
 doing := StrLower(SubStr(detail,1,1)) SubStr(detail,2)
 return "Transcribing: " (step <= 2 ? "getting ready" : Round(IsNumber(percent) ? percent : 0) "%") (doing = "" ? "" : ", " doing)
}
; The Recording saved window while transcribing: the steps, the finished ones ticked and the one
; now in bold, and a bar that moves by itself until there is a percent to show (#12).
ShowSteps(g,step,resumed,percent,downloading:=false) {
 names := [(downloading ? "Download" : "Load") " the speech model","Find where people speak","Write down what others said","Write down what you said"]
 loop 4 {
  c := g["Step" A_Index]
  done := A_Index < step || (resumed && A_Index = 3)
  c.Text := (A_Index = step ? "●" : done ? "✓" : "○") " " names[A_Index] (resumed && A_Index = 3 ? " (saved earlier)" : "")
  c.SetFont(A_Index = step ? "w600" : "w400")
  c.Visible := true
 }
 bar := g["TranscribeProgress"]
 SetMarquee(bar, step <= 2)
 if step > 2
  bar.Value := percent
 bar.Visible := true
}
SetMarquee(bar,on) {
 if on = !!(ControlGetStyle(bar) & 0x8)
  return
 if on {
  bar.Opt("+0x8")
  SendMessage(0x40A,1,30,bar)   ; PBM_SETMARQUEE
 } else {
  SendMessage(0x40A,0,0,bar)
  bar.Opt("-0x8")
 }
}
; The tray icon while transcribing: a ring round the red dot that fills as it goes, or an arc
; that spins round it while getting ready (#12). Back to the plain icon when done.
UpdateTrayIcon() {
 global TxState, TxStep, TxPercent
 static shown := ""
 want := TxState = "Working" && TxStep > 2 ? "ring " Round(IsNumber(TxPercent) ? TxPercent : 0)
  : TxState = "Working" || TxState = "Installing" ? "spin" : ""
 if want = shown
  return
 shown := want
 SetTimer(SpinTray, want = "spin" ? 120 : 0)
 if want = "spin"
  SpinTray()
 else SetTrayIcon(want = "" ? 0 : TrayRingIcon(TxPercent))
}
SpinTray() {
 static angle := 0
 angle := Mod(angle + 30, 360)
 SetTrayIcon(TrayRingIcon(0, angle))
}
SetTrayIcon(h) {
 static last := 0
 TraySetIcon(h ? "HICON:*" h : A_ScriptDir "\MeetingRecorder.ico")
 if last
  DllCall("DestroyIcon","Ptr",last)
 last := h
}
TrayRingIcon(percent,spin:=-1) {
 bmp := RingBitmap(DllCall("GetSystemMetrics","Int",49), IsNumber(percent) ? percent : 0, spin)
 DllCall("gdiplus\GdipCreateHICONFromBitmap","Ptr",bmp,"Ptr*",&h:=0)
 DllCall("gdiplus\GdipDisposeImage","Ptr",bmp)
 return h
}
; The app icon (dark circle, red dot) with a grey ring that turns white as it fills to percent,
; or, with spin 0-359, a white quarter arc starting at that angle. Returns a GDI+ bitmap.
RingBitmap(size,percent,spin:=-1) {
 StartGdiplus()
 DllCall("gdiplus\GdipCreateBitmapFromScan0","Int",size,"Int",size,"Int",0,"Int",0x26200A,"Ptr",0,"Ptr*",&bmp:=0)
 DllCall("gdiplus\GdipGetImageGraphicsContext","Ptr",bmp,"Ptr*",&g:=0)
 DllCall("gdiplus\GdipSetSmoothingMode","Ptr",g,"Int",4)
 DllCall("gdiplus\GdipCreateSolidFill","UInt",0xFF1F2937,"Ptr*",&brush:=0)
 edge := Max(0.5,size/64)
 DllCall("gdiplus\GdipFillEllipse","Ptr",g,"Ptr",brush,"Float",edge,"Float",edge,"Float",size-2*edge,"Float",size-2*edge)
 width := Max(2,size/8), inset := size*0.17, d := size-2*inset
 DllCall("gdiplus\GdipCreatePen1","UInt",0xFF6B7280,"Float",width,"Int",2,"Ptr*",&pen:=0)
 DllCall("gdiplus\GdipDrawEllipse","Ptr",g,"Ptr",pen,"Float",inset,"Float",inset,"Float",d,"Float",d)
 sweep := spin >= 0 ? 90 : 360*Min(Max(percent,0),100)/100
 if sweep > 0 {
  DllCall("gdiplus\GdipSetPenColor","Ptr",pen,"UInt",0xFFFFFFFF)
  DllCall("gdiplus\GdipDrawArc","Ptr",g,"Ptr",pen,"Float",inset,"Float",inset,"Float",d,"Float",d,"Float",spin >= 0 ? spin : -90,"Float",sweep)
 }
 DllCall("gdiplus\GdipSetSolidFillColor","Ptr",brush,"UInt",0xFFEF4444)
 dot := size*0.33
 DllCall("gdiplus\GdipFillEllipse","Ptr",g,"Ptr",brush,"Float",dot,"Float",dot,"Float",size-2*dot,"Float",size-2*dot)
 DllCall("gdiplus\GdipDeletePen","Ptr",pen)
 DllCall("gdiplus\GdipDeleteBrush","Ptr",brush)
 DllCall("gdiplus\GdipDeleteGraphics","Ptr",g)
 return bmp
}
StartGdiplus() {
 static token := 0
 if !token {
  DllCall("LoadLibrary","Str","gdiplus","Ptr")
  si := Buffer(24,0)
  NumPut("UInt",1,si)
  DllCall("gdiplus\GdiplusStartup","Ptr*",&token,"Ptr",si,"Ptr",0)
 }
 return token
}
; Adds, renames or removes the status line (and its separator) at the top of menu m.
SetTrayStatus(m,text) {
 static shown := Map()
 had := shown.Has(m.Handle) ? shown[m.Handle] : ""
 if text = had
  return
 if had = "" {
  m.Insert("1&")
  m.Insert("1&",text,ShowTranscribing)
 } else if text = "" {
  m.Delete("1&")
  m.Delete("1&")
 } else m.Rename("1&",text)
 shown[m.Handle] := text
}
ShowHelp(topic,*) {
 static g := 0
 if IsObject(g)
  try g.Destroy()
 g := MakeHelp(topic)
 g["Close"].OnEvent("Click",(*) => g.Hide())
 g.OnEvent("Escape",(*) => g.Hide())
 g.Show()
}
MakeHelp(topic) {
 g := Gui("-MinimizeBox","Meeting Recorder help")
 g.MarginX := 16, g.MarginY := 14
 g.SetFont("s12 w600","Segoe UI")
 g.AddText("w480",topic.title)
 g.SetFont("s10 w400")
 g.AddText("y+8 w480",HelpText(topic))
 g.AddButton("vClose x406 y+16 w90 Default","Close")
 return g
}
; A help topic as plain text: what, numbered steps, keys, then the More fold.
HelpText(topic) {
 parts := [topic.what]
 steps := ""
 for s in topic.steps
  steps .= (A_Index > 1 ? "`n" : "") A_Index ". " s
 if steps != ""
  parts.Push(steps)
 keys := ""
 for k in topic.keys
  keys .= (A_Index > 1 ? "`n" : "") k[1] ": " k[2]
 if keys != ""
  parts.Push(keys)
 if topic.HasOwnProp("more") && topic.more != ""
  parts.Push(topic.more)
 text := ""
 for p in parts
  text .= (A_Index > 1 ? "`n`n" : "") p
 return text
}
AboutText(version) {
 return "Meeting Recorder`nVersion " version "`n`nRecords your calls and turns them into text, all on this PC."
}
ShowAbout(*) {
 global AppVersion
 static g := 0
 if IsObject(g)
  try g.Destroy()
 g := MakeAbout(AppVersion,A_ScriptDir "\MeetingRecorder.ico")
 g["OK"].OnEvent("Click",(*) => g.Hide())
 g.OnEvent("Escape",(*) => g.Hide())
 g.Show()
}
MakeAbout(version,icon) {
 g := Gui("-MinimizeBox","About Meeting Recorder")
 g.MarginX := 16, g.MarginY := 14
 g.SetFont("s10","Segoe UI")
 g.AddPicture("w48 h48",icon)
 g.AddText("x+16 yp w380",AboutText(version))
 g.AddLink("xp y+8 w380",'<a href="https://github.com/kennethaar/MeetingRecorder">Project page on GitHub</a>')
 g.AddButton("vOK x370 y+16 w90 Default","OK")
 return g
}
OpenFolder(*) {
 global Folder
 Run("explorer.exe " Q(Folder))
}
; Start with Windows (#20): keeps the Startup folder shortcut to this script, or removes it.
; Returns what it changed, or "" when the shortcut was already right.
SetStartWithWindows(on, link, script := A_ScriptFullPath) {
 if !on {
  if !FileExist(link)
   return ""
  FileDelete(link)
  return "Start with Windows: shortcut removed"
 }
 SplitPath(script,, &dir)
 if FileExist(link) {
  FileGetShortcut(link, &target, &workDir, &args)
  if target = A_AhkPath && args = Q(script) && workDir = dir
   return ""
 }
 FileCreateShortcut(A_AhkPath, link, dir, Q(script), "Meeting Recorder", dir "\MeetingRecorder.ico")
 return "Start with Windows: shortcut set to " script
}
; ---------------------------------------------------------------- log file (#21)
AppLog(text) => WriteLog(LogPath, text)
OpenLog(*) {
 global LogPath
 if !FileExist(LogPath)
  AppLog("Log opened")
 Run("notepad.exe " Q(LogPath))
}
; One timed line per event; Backend.ps1 and Capture.cs append to the same file in the same form.
; Past maxBytes the log moves to .1.log, .1 to .2 and so on, and the oldest of keep is dropped.
; Never throws: a log that cannot be written must not stop a recording.
WriteLog(path, text, maxBytes := 1048576, keep := 3, source := "app") {
 line := FormatTime(,"yyyy-MM-dd HH:mm:ss") "." Format("{:03}",A_MSec) " [" source "] " RegExReplace(Trim(text," `t`r`n"),"\s*[\r\n]+\s*"," ") "`r`n"
 try {
  if FileExist(path) && FileGetSize(path) >= maxBytes {
   older := (n) => RegExReplace(path,"\.log$","." n ".log")
   try FileDelete(older(keep))
   loop keep - 1
    try FileMove(older(keep - A_Index), older(keep - A_Index + 1))
   FileMove(path, older(1))
  }
  FileAppend(line, path, "UTF-8-RAW")
 }
}
Settings(*) {
 global Folder, Config, Shortcut, DetectOn, CalendarOn
 static open := 0
 if open && WinExist(open) {   ; one Settings window at a time
  WinActivate(open)
  return
 }
 ; Only offered when classic Outlook is installed; new Outlook has no local calendar access.
 g := MakeSettings(Folder,Shortcut,DetectOn,CalendarOn,OutlookInstalled(),MicList(),Microphone,MicrophoneName,SpeechModel,StartupOn)
 open := g.Hwnd
 f := g["Folder"], h := g["Shortcut"], d := g["Detect"], st := g["Startup"]
 c := 0
 try c := g["Calendar"]
 ; The level bar (#14) follows the microphone picked in the list.
 meter := MicMeterOpen(MicChoice(g).id)
 g["Microphone"].OnEvent("Change",(*) => (MicMeterClose(meter), meter := MicMeterOpen(MicChoice(g).id)))
 SetTimer(LevelTick,50)
 g["Browse"].OnEvent("Click",(*) => BrowseFolder(f))
 g["Save"].OnEvent("Click",SaveSettings)
 g["Cancel"].OnEvent("Click",CloseSettings)
 g.OnEvent("Escape",CloseSettings)
 g.OnEvent("Close",CloseSettings)
 g.Show()
 LevelTick() {
  try ShowLevel(g,MicMeterPeak(meter),MicMuted(meter))
 }
 CloseSettings(*) {
  SetTimer(LevelTick,0)
  MicMeterClose(meter)
  g.Destroy()
 }
 SaveSettings(*) {
  global Folder, Shortcut, Config, DetectOn, CalendarOn, Microphone, MicrophoneName, SpeechModel, StartupOn
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
   m := MicChoice(g)
   Microphone := m.id, MicrophoneName := m.id = "" ? "" : m.name
   IniWrite(Microphone,Config,"Settings","Microphone")
   IniWrite(MicrophoneName,Config,"Settings","MicrophoneName")
   SpeechModel := ModelChoice(g)
   IniWrite(SpeechModel,Config,"Settings","Model")
   StartupOn := st.Value = 1
   IniWrite(StartupOn ? 1 : 0,Config,"Settings","Startup")
   if (change := SetStartWithWindows(StartupOn,StartupLink)) != ""
    AppLog(change)
   AppLog("Settings saved: folder " Folder ", shortcut " Shortcut ", start with Windows " StartupOn ", Teams " DetectOn ", Outlook " CalendarOn ", microphone " (Microphone = "" ? "Windows default" : MicrophoneName) ", model " SpeechModel)
   CloseSettings()
  } catch as e {
   AppLog("Settings not saved: " e.Message)
   MsgBox(e.Message,"Settings not saved")
  }
 }
}
; Folder with Browse beside it, the shortcut, the Teams choices, then Save and Cancel.
MakeSettings(folder,shortcut,detect,calendar,outlook,mics := "",mic := "",micName := "",model := "",startup := true) {
 ; Microphones (#14): a stored one that is not connected now stays listed, so Save keeps it.
 list := IsObject(mics) ? mics.Clone() : [{id: "", name: "Windows default"}]
 pick := 1
 for m in list
  if m.id = mic
   pick := A_Index
 if mic != "" && pick = 1 {
  list.InsertAt(2, {id: mic, name: micName, missing: true})
  pick := 2
 }
 names := []
 for m in list
  names.Push(m.HasOwnProp("missing") ? m.name " (not connected)" : m.name)
 g := Gui("-MinimizeBox","Meeting Recorder settings")
 g.Mics := list
 g.MarginX := 16, g.MarginY := 14
 g.SetFont("s10","Segoe UI")
 g.AddText("w440","Save recordings in")
 f := g.AddEdit("vFolder y+4 w340 r1 -Wrap",folder)
 f.GetPos(,,,&h)
 g.AddButton("vBrowse x+8 yp w92 h" h,"Browse...")
 g.AddText("xm y+14 w440","Shortcut to start and stop")
 g.AddHotkey("vShortcut y+4 w200",shortcut)
 g.AddText("xm y+14 w440","Microphone")
 g.AddDropDownList("vMicrophone y+4 w440 Choose" pick,names)
 g.AddProgress("vLevel y+8 w300 h10 Range0-100",0)
 g.AddText("vLevelHint x+8 yp-4 w132","Talk to test it")
 ; Speech model (#15): Fast (turbo) unless Accurate (large-v3) is stored.
 g.AddText("xm y+12 w440","Transcribe with")
 g.AddDropDownList("vModel y+4 w440 Choose" (model = "large-v3" ? 2 : 1),["Fast - best for English","Accurate - slower, best for other languages"])
 g.AddCheckbox("vStartup xm y+14 Checked" startup,"Start with Windows")
 g.AddCheckbox("vDetect y+8 Checked" detect,"Record when a Teams call starts")
 if outlook
  g.AddCheckbox("vCalendar y+8 Checked" calendar,"Name recordings after the meeting in classic Outlook")
 g.AddButton("vSave x264 y+18 w92 Default","Save")
 g.AddButton("vCancel x+8 w92","Cancel")
 return g
}
; ---------------------------------------------------------------- microphone choice (#14)
; Windows Core Audio through COM: IMMDeviceEnumerator, IMMDevice, IAudioClient, IAudioMeterInformation.
; Windows default first (with the device's name), then every connected microphone.
MicList() {
 list := [{id: "", name: "Windows default"}]
 try {
  e := ComObject("{BCDE0395-E52F-467C-8E3D-C4579291692E}", "{A95664D2-9614-4F35-A746-DE8DB63617E6}")
  try {
   ComCall(4, e, "int", 1, "int", 2, "ptr*", &dev := 0)   ; capture, communications
   list[1].name := "Windows default (" MicName(dev) ")"
   ObjRelease(dev)
  }
  ComCall(3, e, "int", 1, "uint", 1, "ptr*", &all := 0)   ; capture, active
  ComCall(3, all, "uint*", &n := 0)
  loop n {
   ComCall(4, all, "uint", A_Index - 1, "ptr*", &dev := 0)
   ComCall(5, dev, "ptr*", &p := 0)
   id := StrGet(p, "UTF-16"), DllCall("ole32\CoTaskMemFree", "ptr", p)
   list.Push({id: id, name: MicName(dev)})
   ObjRelease(dev)
  }
  ObjRelease(all)
 }
 return list
}
; The name Windows shows for a device, such as "Microphone (Sennheiser Profile)".
MicName(dev) {
 name := ""
 ComCall(4, dev, "uint", 0, "ptr*", &store := 0)
 key := Buffer(20), DllCall("ole32\CLSIDFromString", "wstr", "{A45C254E-DF1C-4EFD-8020-67D146A850E0}", "ptr", key)
 NumPut("uint", 14, key, 16)   ; PKEY_Device_FriendlyName
 pv := Buffer(24, 0)
 try {
  ComCall(5, store, "ptr", key, "ptr", pv)
  if NumGet(pv, 0, "ushort") = 31   ; VT_LPWSTR
   name := StrGet(NumGet(pv, 8, "ptr"), "UTF-16")
  DllCall("ole32\PropVariantClear", "ptr", pv)
 }
 ObjRelease(store)
 return name
}
; Opens a microphone so its level can be read; "" = the Windows default. Windows measures the
; level only while something listens, so this starts a capture stream that is never read.
MicMeterOpen(id) {
 m := {dev: 0, client: 0, meter: 0, volume: 0}
 try {
  e := ComObject("{BCDE0395-E52F-467C-8E3D-C4579291692E}", "{A95664D2-9614-4F35-A746-DE8DB63617E6}")
  if id = ""
   ComCall(4, e, "int", 1, "int", 2, "ptr*", &dev := 0)
  else
   ComCall(5, e, "wstr", id, "ptr*", &dev := 0)
  m.dev := dev
  iid := Buffer(16)
  DllCall("ole32\CLSIDFromString", "wstr", "{1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}", "ptr", iid)
  ComCall(3, dev, "ptr", iid, "uint", 23, "ptr", 0, "ptr*", &client := 0)
  m.client := client
  ComCall(8, client, "ptr*", &fmt := 0)
  try ComCall(3, client, "int", 0, "uint", 0, "int64", 10000000, "int64", 0, "ptr", fmt, "ptr", 0)
  DllCall("ole32\CoTaskMemFree", "ptr", fmt)
  try ComCall(10, client)
  DllCall("ole32\CLSIDFromString", "wstr", "{C02216F6-8C67-4B5B-9D00-D008E73E0064}", "ptr", iid)
  ComCall(3, dev, "ptr", iid, "uint", 23, "ptr", 0, "ptr*", &meter := 0)
  m.meter := meter
  DllCall("ole32\CLSIDFromString", "wstr", "{5CDF2C82-841E-4546-9722-0CF74078229A}", "ptr", iid)
  ComCall(3, dev, "ptr", iid, "uint", 23, "ptr", 0, "ptr*", &volume := 0)   ; IAudioEndpointVolume
  m.volume := volume
 }
 return m
}
; True when the microphone is muted in Windows: it then records only silence.
MicMuted(m) {
 muted := 0
 if m.HasOwnProp("volume") && m.volume
  try ComCall(15, m.volume, "int*", &muted)
 return muted ? 1 : 0
}
; The level bar under the microphone in Settings, and the words beside it.
ShowLevel(g, peak, muted) {
 g["Level"].Value := muted ? 0 : Round(Min(1, peak) * 100)
 hint := muted ? "Muted in Windows" : "Talk to test it"
 if g["LevelHint"].Text != hint
  g["LevelHint"].Text := hint
}
; Loudest sound just now, 0 to 1.
MicMeterPeak(m) {
 peak := 0.0
 if m.meter
  try ComCall(3, m.meter, "float*", &peak)
 return peak
}
MicMeterClose(m) {
 if m.client {
  try ComCall(11, m.client)
  ObjRelease(m.client)
 }
 if m.meter
  ObjRelease(m.meter)
 if m.volume
  ObjRelease(m.volume)
 if m.dev
  ObjRelease(m.dev)
 m.dev := m.client := m.meter := m.volume := 0
}
; The microphone picked in Settings: {id, name}; id "" = Windows default.
MicChoice(g) {
 return g.Mics[g["Microphone"].Value]
}
; The speech model picked in Settings (#15).
ModelChoice(g) {
 return g["Model"].Value = 2 ? "large-v3" : "large-v3-turbo"
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
 if wParam = 4 {
  AppLog("Windows is going to sleep")
  StopRecording()
 }
}
Quit(*) {
 global Closing, Child
 AppLog("Exit asked")
 Closing := true
 StopRecording()
 if !Child
  Leave()
}
; Tray menu › Restart: like Exit (a recording is saved first), then the app starts again.
Restart(*) {
 global Restarting := true
 Quit()
}
Leave() => Restarting ? Reload() : ExitApp()
ExitHandler(reason,code) {
 global State, StopPath, Child
 AppLog("Closing (" reason ") while " State)
 if State = "Recording" || State = "Starting" || State = "Saving" {
  try FileAppend("stop",StopPath)
  if Child
   try ProcessWaitClose(Child,8)
 }
 StopTranscriber()
}

; ---------------------------------------------------------------- transcription on this PC (#7)
; Transcribe.py runs WhisperX on the saved WAV and reports through transcribe.ini; the app then
; writes <recording>.txt and .srt next to the WAV. Left channel = Others, right = Me.
TranscribeClick(*) {
 global CompletionWav
 tx := NoticeTx()
 if tx = "busy" {
  StopTranscriber()
  ShowTranscribeState()
 } else if tx = "ready" {
  Run(Q(TranscriptPath(CompletionWav,"txt")))
 } else StartChecked(CompletionWav)
}
; A transcript can be made again; the new one replaces it (#8).
TranscribeAgain(*) {
 global CompletionWav
 if NoticeBox("Make a new transcript? It replaces the one you have now.","Transcribe again","YesNo") = "Yes"
  StartChecked(CompletionWav)
}
StartChecked(wav) {
 global TxState
 if TxState = "Working" || TxState = "Installing"
  NoticeBox("Another recording is being transcribed. Try again when it is done.","Transcribe")
 else if !FileExist(wav)
  NoticeBox("The recording is no longer in its folder, so it cannot be transcribed.","Transcribe")
 else StartTranscribe(wav)
}
; The transcript state of the recording the window is about: "", "busy", "ready" or "failed".
NoticeTx() {
 global CompletionWav, TxWav, TxState
 if TxWav = CompletionWav && (TxState = "Working" || TxState = "Installing")
  return "busy"
 if TxWav = CompletionWav && TxState = "Error"
  return "failed"
 return FileExist(TranscriptPath(CompletionWav,"txt")) ? "ready" : ""
}
StartTranscribe(wav) {
 global TxState, TxWav, TxPid, TxStart, TxPercent, TxDetail, TxStatusPath, TxSegmentsPath, TxSetupPath
 py := FindTranscriber(EnvGet("LOCALAPPDATA"))
 if py = "" && TxState = "Installing" {
  TranscribeFailed("Setup finished, but the transcriber was not found. Try again.")
  return
 }
 if py = "" && NoticeBox("Transcribing runs on this PC, so nothing is uploaded. It needs a one-time download of about 5 GB.`n`nDownload now?","Get the transcriber","YesNo") != "Yes"
  return
 for path in [TxStatusPath, TxSegmentsPath, TxSetupPath]
  try FileDelete(path)
 global TxStep, TxResumed, TxDownload
 TxWav := wav, TxStart := A_TickCount, TxPercent := 0, TxStep := 1, TxResumed := false, TxDownload := ""
 try {
  AppLog((py = "" ? "Transcriber setup started for " : "Transcribe with " SpeechModel ": ") wav)
  if py = "" {
   TxState := "Installing", TxDetail := "Getting the transcriber ready", TxStep := 0
   Run(PSCommand("Transcriber") " -Status " Q(TxSetupPath),, "Hide", &TxPid)
  } else {
   TxState := "Working", TxDetail := "Loading the speech model"
   Run(TranscribeCommand(py, A_ScriptDir, wav, TxStatusPath, TxSegmentsPath, MeetingHint(AppDir "\meetings.ini", wav), SpeechModel),, "Hide", &TxPid)
  }
 } catch as e {
  TranscribeFailed(e.Message)
  return
 }
 SetTimer(TranscribePoll, 500)
 ShowTranscribeState()
}
TranscribePoll() {
 global TxState, TxWav, TxPid, TxPercent, TxDetail, TxStatusPath, TxSegmentsPath, TxSetupPath, TxStep, TxResumed, TxDownload
 alive := TxPid && ProcessExist(TxPid)   ; checked before the status, so a final status is never missed
 if TxState = "Installing" {
  s := IniRead(TxSetupPath,"Capture","State","")
  if s = "Ready" {
   TxPid := 0
   StartTranscribe(TxWav)
  } else if s = "Error" || !alive
   TranscribeFailed(s = "Error" ? IniRead(TxSetupPath,"Capture","Detail","") : "Setup stopped before it was done.")
 } else if TxState = "Working" {
  s := IniRead(TxStatusPath,"Transcribe","State","")
  TxPercent := IniRead(TxStatusPath,"Transcribe","Percent",TxPercent)
  TxDetail := IniRead(TxStatusPath,"Transcribe","Detail",TxDetail)
  step := IniRead(TxStatusPath,"Transcribe","Step","")
  TxStep := IsInteger(step) && step >= 1 ? Integer(step) : TxStep
  TxResumed := IniRead(TxStatusPath,"Transcribe","Resumed",TxResumed ? 1 : 0) = 1
  TxDownload := IniRead(TxStatusPath,"Transcribe","Download","")
  if s = "Done" {
   try {
    WriteTranscript(TxWav, TxSegmentsPath)
    AppLog("Transcript ready: " TranscriptPath(TxWav,"txt"))
    TxState := "", TxPid := 0
    SetTimer(TranscribePoll, 0)
    AnnounceTranscript()
   } catch as e
    TranscribeFailed("The transcript could not be saved next to the recording. " e.Message)
  } else if s = "Error" || !alive
   TranscribeFailed(s = "Error" ? IniRead(TxStatusPath,"Transcribe","Detail","") : "The transcriber stopped before it was done.")
 }
 ShowTranscribeState()
}
TranscribeFailed(detail) {
 global TxState, TxDetail, TxPid
 AppLog("Transcribe failed: " detail " (details: " TxStatusPath ".log)")
 SetTimer(TranscribePoll, 0)
 TxState := "Error", TxDetail := detail, TxPid := 0
 AnnounceTranscript()
}
; Bring back the Recording saved window if it is about this recording; otherwise a tray message.
AnnounceTranscript() {
 global Completion, CompletionWav, TxWav, TxState
 ShowTranscribeState()
 if IsObject(Completion) && CompletionWav = TxWav
  Completion.Show("AutoSize NoActivate")
 else {
  SplitPath(TxWav,,,,&name)
  TrayTip(name, TxState = "Error" ? "Transcription failed" : "Transcript ready", 0x24)
 }
}
; The line under the steps while transcribing. Setup says what it is doing; a model download
; (download, from the transcriber) says how far it is and the time left, since it can take long (#16).
TranscribeStatusText(state, detail, minutes, download := "") {
 return (state = "Installing" ? detail "...  " : "") (download != "" ? download "`n" : "") minutes " min so far. Click Hide to keep working."
}
StopTranscriber() {
 global TxState, TxPid
 SetTimer(TranscribePoll, 0)
 if TxPid && ProcessExist(TxPid)
  RunWait(A_ComSpec " /c taskkill /PID " TxPid " /T /F",, "Hide")
 TxState := "", TxPid := 0
}
; Shows the transcription state in the tray menu, and in the Recording saved window for the
; recording it is about.
ShowTranscribeState() {
 global Completion, CompletionKind, TxState, TxStart, TxPercent, TxDetail, TxStep, TxResumed, TxDownload
 percent := Round(IsNumber(TxPercent) ? TxPercent : 0)
 SetTrayStatus(A_TrayMenu, TrayStatusText(TxState, percent, TxStep))
 UpdateTrayIcon()
 if !IsObject(Completion)
  return
 tx := NoticeTx()
 v := NoticeView(CompletionKind, tx)
 Completion["Heading"].Text := v.heading
 Completion["Transcribe"].Text := v.primary
 Completion["Again"].Visible := v.again
 status := Completion["TranscribeStatus"], bar := Completion["TranscribeProgress"]
 busy := tx = "busy"
 if busy && TxState = "Working"
  ShowSteps(Completion, TxStep, TxResumed, percent, InStr(TxDetail, "Downloading the speech model") = 1)
 else {
  loop 4
   Completion["Step" A_Index].Visible := false
  SetMarquee(bar, busy)
  bar.Visible := busy
 }
 if busy
  status.Text := TranscribeStatusText(TxState, TxDetail, (A_TickCount - TxStart)//60000, TxState = "Working" ? TxDownload : "")
 else if tx = "failed"
  status.Text := TxDetail
 status.Visible := busy || tx = "failed"
 if LayoutNotice(Completion) && DllCall("IsWindowVisible","Ptr",Completion.Hwnd)
  Completion.Show("AutoSize NoActivate")
}

; WhisperX in a portable Python: this app's own install, else the one PodcastClipper made.
FindTranscriber(appData) {
 for dir in [appData "\MeetingRecorder\transcriber", appData "\PodcastEditorTools\whisperx-python"]
  if FileExist(dir "\python.exe") && DirExist(dir "\Lib\site-packages\whisperx")
   return dir "\python.exe"
 return ""
}
; hint: meeting title and names for the speech model (#10). Quotes and backslashes would break
; the command line, so they are left out.
; model: the speech model picked in Settings (#15).
TranscribeCommand(py, appDir, wav, status, segments, hint := "", model := "large-v3-turbo") {
 return Q(py) " -u " Q(appDir "\Transcribe.py") " " Q(wav) " " Q(status) " " Q(segments) " " Q(RegExReplace(hint,'["\\]')) " " Q(model)
}
TranscriptPath(wav, ext) {
 return RegExReplace(wav,"i)\.wav$") "." ext
}
; Transcribe.py output: one start<TAB>end<TAB>speaker<TAB>text line per segment.
ReadSegments(path) {
 segments := []
 for line in StrSplit(FileRead(path,"UTF-8"),"`n","`r") {
  f := StrSplit(line,"`t",,4)
  if f.Length = 4 && IsNumber(f[1]) && IsNumber(f[2])
   segments.Push({start: Number(f[1]), end: Number(f[2]), speaker: f[3], text: f[4]})
 }
 return segments
}
WriteTranscript(wav, segmentsPath) {
 segments := ReadSegments(segmentsPath)
 for ext, text in Map("txt",TranscriptText(segments),"srt",SubtitleText(segments)) {
  f := FileOpen(TranscriptPath(wav,ext),"w","UTF-8")
  f.Write(text)
  f.Close()
 }
}
; In time order; lines in a row from the same person become one turn. A pause of 2 s or more
; in a turn starts a new paragraph with its own time (#10).
TranscriptText(segments) {
 text := "", speaker := "", last := 0
 for s in SortSegments(segments) {
  if s.speaker !== speaker
   text .= (text = "" ? "" : "`r`n`r`n") "[" Clock(s.start,false) "] " s.speaker ": " s.text
  else if s.start - last >= 2
   text .= "`r`n`r`n[" Clock(s.start,false) "] " s.text
  else text .= " " s.text
  speaker := s.speaker, last := s.end
 }
 return text = "" ? "No speech was found in this recording.`r`n" : text "`r`n"
}
SubtitleText(segments) {
 text := ""
 for s in SortSegments(segments)
  text .= (A_Index > 1 ? "`r`n" : "") A_Index "`r`n" Clock(s.start,true) " --> " Clock(s.end,true) "`r`n" s.speaker ": " s.text "`r`n"
 return text
}
; Stable sort by start time.
SortSegments(segments) {
 sorted := []
 for s in segments {
  i := sorted.Length
  while i >= 1 && sorted[i].start > s.start
   i--
  sorted.InsertAt(i+1,s)
 }
 return sorted
}
; HH:MM:SS, or HH:MM:SS,mmm for subtitles.
Clock(seconds, withMs) {
 ms := Round(seconds*1000)
 t := Format("{:02}:{:02}:{:02}",ms//3600000,Mod(ms//60000,60),Mod(ms//1000,60))
 return withMs ? t "," Format("{:03}",Mod(ms,1000)) : t
}

; ---------------------------------------------------------------- Teams calls and Outlook meetings
; Every 2 s. A Teams call starts a recording at once, in view on the panel, so a late look at the
; panel loses nothing (#17). Keep recording or Discard while the call is on; no answer keeps it.
DetectCall() {
 global InCall, MeetingTitle, MeetingPeople, State, DetectOn, CalendarOn, PanelWasVisible, Panel
 active := DetectOn && TeamsCallActive()
 if active = InCall
  return
 InCall := active
 if active {
  MeetingTitle := "", MeetingPeople := ""
  if CalendarOn
   MeetingTitle := PickMeeting(OutlookMeetings(), A_Now, &MeetingPeople)
 }
 AppLog(active ? "Teams call started" (MeetingTitle = "" ? "" : ": " MeetingTitle) : "Teams call ended")
 switch CallAction(active, State) {
  case "Start":
   PanelWasVisible := DllCall("IsWindowVisible","Ptr",Panel.Hwnd)
   Toggle()
   if State = "Starting"
    SetCallPhase("Started")
  case "Ended":
   SetCallPhase("Ended")
   ShowPanel()
 }
}
; What a Teams call starting or ending does: "Start" a recording, tell the panel the call
; "Ended", or nothing ("") when the app is busy or not recording.
CallAction(active, state) {
 if active
  return state = "Manual only" ? "Start" : ""
 return state = "Recording" || state = "Starting" ? "Ended" : ""
}
; The panel while recording. phase is CallPhase; other is the second button (Settings, or the
; Discard / Keep recording button that takes its place).
RecordingLines(elapsed, shortcut, phase, title) {
 status := "Recording  " elapsed
 if phase = "Started"
  return {status: status, hint: "Started for the Teams call" (title = "" ? "" : " · " title), action: "Keep recording", other: "Discard"}
 if phase = "Ended"
  return {status: status, hint: "The Teams call ended. Stop to save.", action: "Stop", other: "Keep recording"}
 return {status: status, hint: "Stop: " shortcut, action: "Stop", other: "Settings"}
}
SetCallPhase(phase) {
 global CallPhase, Action, NotNow, SettingsButton
 CallPhase := phase
 v := RecordingLines("", "", phase, "")
 Action.Text := v.action
 NotNow.Text := v.other
 NotNow.Visible := phase != ""
 SettingsButton.Visible := phase = ""
}
ActionClick(*) {
 global CallPhase
 if CallPhase = "Started"
  SetCallPhase("")   ; Keep recording
 else Toggle()
}
NotNowClick(*) {
 global CallPhase, Discarding
 if CallPhase != "Started" {
  SetCallPhase("")   ; Keep recording after the call ended
  return
 }
 AppLog("Discard clicked")
 Discarding := true
 StopRecording()
 SetStatus("Discarding...", "")
}
; Moves a discarded recording to the Recycle Bin. True when it is gone from the folder.
DiscardRecording(wav) {
 if !FileExist(wav)
  return false
 try FileRecycle(wav)
 catch
  return false
 return !FileExist(wav)
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
; people gets its attendees ("Name; Name", as Outlook gives them).
PickMeeting(meetings, now, &people := "") {
 best := "", bestGap := -1, people := ""
 soon := DateAdd(now,10,"Minutes")
 for m in meetings {
  if m.allDay || m.start = "" || m.end = "" || m.start > soon || m.end <= now
   continue
  gap := Abs(DateDiff(m.start,now,"Seconds"))
  if bestGap < 0 || gap < bestGap
   best := m.subject, bestGap := gap, people := m.HasProp("people") ? m.people : ""
 }
 return best
}

; #10: the meeting title and attendees, kept when a recording starts, so a transcript made
; later can spell names right. Keyed by the recording's 8-hex id; UTF-16 for names like Ø.
SaveMeetingHint(ini, id, title, people) {
 if !FileExist(ini)
  FileAppend("", ini, "UTF-16")
 IniWrite(title, ini, id, "Title")
 IniWrite(people, ini, id, "People")
}
; The hint for the speech model: "Title. First Last, First Last." at most 400 characters.
; Without stored details, the title in the file name; "Recording" (no meeting) gives "".
MeetingHint(ini, wav) {
 SplitPath(wav,,,,&base)
 if !RegExMatch(base,"i)^(?:\d{4}-\d\d-\d\d \d{6} - )?(.*) - ([0-9a-f]{8})(?: - .*)?$",&m)
  return ""
 title := m[1] = "Recording" ? "" : m[1], people := ""
 try title := IniRead(ini, m[2], "Title", title), people := IniRead(ini, m[2], "People", "")
 title := RegExReplace(Trim(title),"[.\s]+$")
 if title = ""
  return ""
 hint := title ".", names := ""
 for p in StrSplit(people, ";") {
  p := Trim(p)
  if p = "" || InStr(p,"@")
   continue
  if RegExMatch(p,"^([^,]+),\s*([^,]+)$",&n)   ; "Last, First"
   p := n[2] " " n[1]
  if InStr(", " names ",", ", " p ",")
   continue
  if StrLen(hint) + StrLen(names) + StrLen(p) + 4 > 400
   break
  names .= (names = "" ? "" : ", ") p
 }
 return names = "" ? hint : hint " " names "."
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
   meetings.Push({subject: item.Subject, start: ComDateToStamp(item.Start), end: ComDateToStamp(item.End), allDay: item.AllDayEvent,
    people: item.RequiredAttendees "; " item.OptionalAttendees})
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
            words: "start stop record call meeting audio shortcut panel timer microphone speaker headset sound others silent",
            what: "Records your call to a WAV file. The left channel is what you hear, from every speaker and headset that is on. The right channel is your microphone.",
            steps: [
                "Press Ctrl + Alt + R, or click Start.",
                "Wait until the timer runs. Then the recording has begun.",
                "Press the shortcut again, or click Stop, to save.",
            ],
            keys: [["Ctrl + Alt + R", "Start or stop. You can change it in Settings."]],
            legend: [
                ["Panel.Status", "Status and recording time"],
                ["Panel.Hint", "The shortcut, or what to do next"],
                ["Panel.Action", "Start or stop recording"],
                ["Panel.Settings", "Open settings"],
            ],
            view: "Panel",
            more: "Muting yourself in the call may not mute this recording. Other people are not told that you record. Follow the recording rules where you work. A recording stops by itself after five hours.",
        },
        {
            id: "teams",
            title: "Teams calls",
            words: "teams call meeting detect automatic start discard throw away delete keep outlook calendar name file",
            what: "When a Teams call starts, recording starts at once, so you get the whole call. Click Discard if you do not want it.",
            steps: [
                "Join a Teams call. The panel shows Recording.",
                "Click Keep recording, or Discard to throw it away.",
                "If you do nothing, the recording is kept.",
                "When the call ends, click Stop to save, or Keep recording.",
            ],
            keys: [],
            legend: [
                ["Panel.Status", "Recording and how long"],
                ["Panel.Hint", "The meeting name"],
                ["Panel.Action", "Keep the recording, or Stop to save it"],
                ["?Panel.NotNow", "Discard the recording, or keep recording after the call ends"],
            ],
            view: "Panel",
            more: "Discard moves the file to the Recycle Bin. A call is found when Teams uses your microphone. If classic Outlook is open, the file is named after the meeting that is on now. The app never starts Outlook. You can turn both off in Settings.",
        },
        {
            id: "settings",
            title: "Settings",
            words: "settings folder shortcut hotkey save location options teams outlook calendar microphone mic headset level start startup windows sign in boot automatic",
            what: "Choose how the app records and transcribes, and whether it starts with Windows.",
            steps: [
                "Open Settings from the panel or tray menu.",
                "Type a folder, or click Browse.",
                "Click the shortcut box and press the new keys.",
                "Pick your microphone. The bar moves when it hears you.",
                "Click Save.",
            ],
            keys: [],
            legend: [
                ["Settings.Folder", "Where recordings are saved"],
                ["Settings.Browse", "Pick a folder"],
                ["Settings.Shortcut", "Keys that start and stop"],
                ["Settings.Microphone", "Your microphone"],
                ["Settings.Level", "Moves when it hears you"],
                ["Settings.Model", "Fast or accurate"],
                ["Settings.Startup", "Start with Windows"],
                ["Settings.Detect", "Record Teams calls when they start"],
                ["?Settings.Calendar", "Name files after Outlook meetings"],
                ["Settings.Save", "Save changes"],
                ["Settings.Cancel", "Close without saving"],
            ],
            view: "Settings",
            more: "Changes apply to the next recording. Start with Windows is on unless you turn it off. It puts a Meeting Recorder shortcut in your Startup folder. If your microphone is not connected when you record, or stops during a call, the Windows default records you instead. The Outlook choice is shown only when classic Outlook is installed. Settings are kept in %LOCALAPPDATA%\MeetingRecorder\settings.ini.",
        },
        {
            id: "transcribe",
            title: "Transcribe a recording",
            words: "transcribe transcript text subtitles srt whisper whisperx word notes minutes saved again redo older hide progress fast accurate model language",
            what: "Turns a saved recording into text on this PC. Nothing is uploaded. Lines are marked Others or Me.",
            steps: [
                "Click Transcribe when a recording is saved.",
                "Click Hide to keep working. The tray icon's ring fills as it goes.",
                "Click Open transcript when it is ready.",
                "Older recordings are under Recordings in the tray menu.",
            ],
            keys: [],
            legend: [
                ["Saved.Heading", "What is new"],
                ["Saved.FileName", "The recording"],
                ["?Saved.Step1", "The steps"],
                ["?Saved.TranscribeProgress", "Progress"],
                ["?Saved.TranscribeStatus", "Time so far, or the error"],
                ["Saved.Transcribe", "Transcribe, cancel, or open the transcript"],
                ["Saved.ShowFile", "Show it in Explorer"],
                ["?Saved.Again", "Make a new transcript"],
                ["Saved.Hide", "Hide. Transcribing goes on."],
            ],
            view: "Saved",
            more: "Others is what you heard. Me is your microphone. Getting ready takes a few minutes, so the bar moves by itself until there is a percent. If transcribing stops, Try again picks up where it stopped: a finished part is kept. Transcribe again replaces the transcript you have. To get this window back, choose the recording under Recordings in the tray menu. The transcript is saved next to the recording, as a .txt file and as an .srt subtitle file for a media player. A pause of 2 seconds starts a new paragraph with its own time. If the recording is named after an Outlook meeting, its title and the names of the people invited help spell names right. They are kept in %LOCALAPPDATA%\MeetingRecorder\meetings.ini. The first time, the app downloads the transcriber, about 5 GB. If PodcastClipper's WhisperX is on this PC, that one is used. Each speech model is downloaded the first time it is used; the window shows how much is done and the time left. A meeting in a new language also needs a word-timing model. It downloads in the background while the transcript is made, so until it is there, the times are less exact. Each try is written down in %LOCALAPPDATA%\MeetingRecorder\transcribe.ini.log. Fast suits English and takes about as long as the meeting lasted. For a meeting in another language, pick Accurate under Transcribe with in Settings; it takes about twice as long and needs more memory. With speakers instead of a headset, your microphone also hears the others, so some of their words can show up as Me.",
        },
        {
            id: "tray",
            title: "Tray menu",
            words: "tray icon menu notification area clock red dot open panel show window latest older earlier recent recordings help about version progress restart reload start again exit quit log file error problem wrong troubleshoot",
            what: "The red dot in the notification area, by the clock, is the app. Click it to open the panel. Right-click it for everything else.",
            steps: [
                "Click the red dot to open the panel, or right-click it for the menu.",
                "Point to Recordings and choose one to see it and its transcript.",
                "Choose Help to read a topic, or About to see the version.",
            ],
            keys: [],
            legend: [],
            more: "Recordings lists the 8 newest recordings, newest first. Transcript at the right means it has one. For an older one, choose Other recording. While a recording is transcribed, the top line of the menu shows how far it has come. Click it to see the transcript window. Restart closes the app and starts it again. A recording that is running is saved first. Open log file shows what the app did and when, to find out what went wrong. Older lines move to MeetingRecorder.1.log, .2 and .3 next to it. If the red dot is hidden, click the arrow by the clock.",
        },
        {
            id: "recovery",
            title: "Recovered recordings",
            words: "recover recovered incomplete crash lost broken partial",
            what: "If the app or PC stopped during a recording, the audio is rescued the next time the app starts.",
            steps: [
                "Start Meeting Recorder.",
                "Right-click the tray icon and choose Open recordings folder.",
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
                "Wait until the panel says Ready to record.",
            ],
            keys: [],
            legend: [],
            more: "The library is NAudio 2.2.1 from NuGet. Its checksum is checked after download. To download it again, close the app, delete %LOCALAPPDATA%\MeetingRecorder\backend-2.2.1 and start the app.",
        },
    ]
}
