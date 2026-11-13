#Requires AutoHotkey v2.0
#SingleInstance Ignore
Persistent
; Set before the first window: windows, message boxes and toasts use the tray icon (#8).
TraySetIcon(A_ScriptDir "\MeetingRecorder.ico")
AppVersion := "0.4.0"
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
CompletionWav := ""    ; the recording the Recording saved window is about
CompletionKind := ""   ; "Saved" or "Incomplete"
; Transcription on this PC (#7). TxState: "", "Installing", "Working", "Error".
TxState := "", TxWav := "", TxPid := 0, TxStart := 0, TxPercent := 0, TxDetail := ""
TxStatusPath := AppDir "\transcribe.ini"
TxSegmentsPath := AppDir "\transcribe.tsv"
TxSetupPath := AppDir "\transcriber-setup.ini"
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
BuildTrayMenu(A_TrayMenu)
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
 global State, Child, StatusPath, StartTick, Label, Action, Latest, Config, Closing, CallEnded, TxState, TxPercent
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
   OpenNotice(Latest, s, separator ? SubStr(detail,separator+3) : "")
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
 } else A_IconTip := "Meeting Recorder`n" State (TxState = "Working" ? "`nTranscribing " TxPercent "%" : "")
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
; The Recording saved window: one recording and its transcript. kind is "Saved" or "Incomplete";
; note is why it is incomplete. Hide keeps transcribing; the tray menu brings it back (#8).
OpenNotice(wav,kind,note:="") {
 global Completion, CompletionWav, CompletionKind
 if IsObject(Completion)
  Completion.Destroy()
 CompletionWav := wav, CompletionKind := kind
 SplitPath(wav,&name)
 Completion := Gui("+AlwaysOnTop +ToolWindow +E0x08000000","Meeting Recorder")
 Completion.SetFont("s12 bold","Segoe UI")
 Completion.AddText("vHeading w480")
 Completion.SetFont("s10 norm")
 Completion.AddText("vFileName w480",name (note != "" ? "`n" note : ""))
 Completion.AddText("vTranscribeStatus w480 Hidden")
 Completion.AddProgress("vTranscribeProgress w480 h10 Hidden")
 Completion.AddButton("vTranscribe w130","Transcribe").OnEvent("Click",TranscribeClick)
 Completion.AddButton("vShowFile x+8 w110","Show file").OnEvent("Click",(*) => ShowInExplorer(CompletionWav))
 Completion.AddButton("vAgain x+8 w130 Hidden","Transcribe again").OnEvent("Click",TranscribeAgain)
 Completion.AddButton("vHide x415 yp w80","Hide").OnEvent("Click",HideNotice)
 Completion.OnEvent("Close",HideNotice)
 Completion.OnEvent("Escape",HideNotice)
 ShowTranscribeState()
 Completion.Show("NoActivate")
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
ShowLatest(*) {
 global Latest
 if Latest != "" && FileExist(Latest)
  OpenNotice(Latest,RecordingKind(Latest))
 else NoticeBox("No saved recording is available yet.","Meeting Recorder")
}
ShowInExplorer(wav) {
 if FileExist(wav)
  Run("explorer.exe /select," Q(wav))
 else NoticeBox("The recording is no longer in its folder.","Meeting Recorder")
}
; Tray menu › Transcribe a recording...: any saved recording, also an older one.
PickRecording(*) {
 global Folder
 path := FileSelect(1,Folder "\","Transcribe a recording","Recordings (*.wav)")
 if path = ""
  return
 if RegExMatch(path,"i)\.partial\.wav$") {
  NoticeBox("This recording is still being made. Transcribe it when it is saved.","Transcribe")
  return
 }
 OpenNotice(path,RecordingKind(path))
 if NoticeTx() = ""
  StartChecked(path)
}
ShowTranscribing(*) {
 global Completion, CompletionWav, TxWav
 if IsObject(Completion) && CompletionWav = TxWav
  Completion.Show("NoActivate")
 else OpenNotice(TxWav,RecordingKind(TxWav))
}
BuildTrayMenu(m) {
 m.Add("Start / stop recording",Toggle)
 m.Add("Latest recording",ShowLatest)
 m.Add("Transcribe a recording...",PickRecording)
 m.Add("Open recordings",OpenFolder)
 m.Add()
 m.Add("Settings",Settings)
 help := Menu()
 for topic in HelpTopics()
  help.Add(topic.title,ShowHelp.Bind(topic))
 m.Add("Help",help)
 m.Add("About Meeting Recorder",ShowAbout)
 m.Add()
 m.Add("Repair audio backend",Repair)
 m.Add("Exit",Quit)
}
; The top line of the tray menu while transcribing; "" when there is nothing to show.
TrayStatusText(state,percent) {
 if state = "Installing"
  return "Getting the transcriber ready..."
 if state = "Working"
  return "Transcribing: " percent "% done"
 return ""
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
 g := Gui(,"Meeting Recorder help")
 g.SetFont("s12 bold","Segoe UI")
 g.AddText("w480",topic.title)
 g.SetFont("s10 norm")
 g.AddText("w480",HelpText(topic))
 g.AddButton("w90 Default","Close").OnEvent("Click",(*) => g.Hide())
 g.OnEvent("Escape",(*) => g.Hide())
 g.Show()
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
 g := Gui(,"About Meeting Recorder")
 g.SetFont("s10","Segoe UI")
 g.AddPicture("w48 h48",A_ScriptDir "\MeetingRecorder.ico")
 g.AddText("x+16 yp w340",AboutText(AppVersion))
 g.AddLink("xp w340",'<a href="https://github.com/kennethaar/MeetingRecorder">Project page on GitHub</a>')
 g.AddButton("xp w90 Default","OK").OnEvent("Click",(*) => g.Hide())
 g.OnEvent("Escape",(*) => g.Hide())
 g.Show()
}
OpenFolder(*) {
 global Folder
 Run("explorer.exe " Q(Folder))
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
 TxWav := wav, TxStart := A_TickCount, TxPercent := 0
 try {
  if py = "" {
   TxState := "Installing", TxDetail := "Getting the transcriber ready"
   Run(PSCommand("Transcriber") " -Status " Q(TxSetupPath),, "Hide", &TxPid)
  } else {
   TxState := "Working", TxDetail := "Loading the speech model"
   Run(TranscribeCommand(py, A_ScriptDir, wav, TxStatusPath, TxSegmentsPath),, "Hide", &TxPid)
  }
 } catch as e {
  TranscribeFailed(e.Message)
  return
 }
 SetTimer(TranscribePoll, 500)
 ShowTranscribeState()
}
TranscribePoll() {
 global TxState, TxWav, TxPid, TxPercent, TxDetail, TxStatusPath, TxSegmentsPath, TxSetupPath
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
  if s = "Done" {
   try {
    WriteTranscript(TxWav, TxSegmentsPath)
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
 SetTimer(TranscribePoll, 0)
 TxState := "Error", TxDetail := detail, TxPid := 0
 AnnounceTranscript()
}
; Bring back the Recording saved window if it is about this recording; otherwise a tray message.
AnnounceTranscript() {
 global Completion, CompletionWav, TxWav, TxState
 ShowTranscribeState()
 if IsObject(Completion) && CompletionWav = TxWav
  Completion.Show("NoActivate")
 else {
  SplitPath(TxWav,,,,&name)
  TrayTip(name, TxState = "Error" ? "Transcription failed" : "Transcript ready", 0x24)
 }
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
 global Completion, CompletionKind, TxState, TxStart, TxPercent, TxDetail
 SetTrayStatus(A_TrayMenu, TrayStatusText(TxState, Round(IsNumber(TxPercent) ? TxPercent : 0)))
 if !IsObject(Completion)
  return
 tx := NoticeTx()
 v := NoticeView(CompletionKind, tx)
 Completion["Heading"].Text := v.heading
 Completion["Transcribe"].Text := v.primary
 Completion["Again"].Visible := v.again
 status := Completion["TranscribeStatus"], bar := Completion["TranscribeProgress"]
 if tx = "busy" {
  status.Text := TxDetail "...  " (A_TickCount - TxStart)//60000 " min. Click Hide to keep working."
  bar.Value := TxPercent
 } else if tx = "failed"
  status.Text := TxDetail
 status.Visible := tx = "busy" || tx = "failed"
 bar.Visible := tx = "busy"
}

; WhisperX in a portable Python: this app's own install, else the one PodcastClipper made.
FindTranscriber(appData) {
 for dir in [appData "\MeetingRecorder\transcriber", appData "\PodcastEditorTools\whisperx-python"]
  if FileExist(dir "\python.exe") && DirExist(dir "\Lib\site-packages\whisperx")
   return dir "\python.exe"
 return ""
}
TranscribeCommand(py, appDir, wav, status, segments) {
 return Q(py) " -u " Q(appDir "\Transcribe.py") " " Q(wav) " " Q(status) " " Q(segments)
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
; In time order; lines in a row from the same person become one turn.
TranscriptText(segments) {
 text := "", speaker := ""
 for s in SortSegments(segments) {
  if s.speaker == speaker
   text .= " " s.text
  else text .= (text = "" ? "" : "`r`n`r`n") "[" Clock(s.start,false) "] " s.speaker ": " s.text
  speaker := s.speaker
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
            id: "transcribe",
            title: "Transcribe a recording",
            words: "transcribe transcript text subtitles srt whisper whisperx word notes minutes saved again redo older hide progress",
            what: "Turns a saved recording into text on this PC. Nothing is uploaded. Lines are marked Others or Me.",
            steps: [
                "Click Transcribe when a recording is saved.",
                "Click Hide to keep working. The tray icon shows how far it has come.",
                "Click Open transcript when it is ready.",
                "For an older recording, use Transcribe a recording in the tray menu.",
            ],
            keys: [],
            legend: [
                ["Saved.Heading", "What is new"],
                ["Saved.FileName", "The recording"],
                ["?Saved.TranscribeStatus", "What it is doing"],
                ["?Saved.TranscribeProgress", "Progress"],
                ["Saved.Transcribe", "Transcribe, cancel, or open the transcript"],
                ["Saved.ShowFile", "Show it in Explorer"],
                ["?Saved.Again", "Make a new transcript"],
                ["Saved.Hide", "Hide. Transcribing goes on."],
            ],
            view: "Saved",
            more: "Others is what you heard. Me is your microphone. Transcribe again replaces the transcript you have. To get this window back, choose Latest recording in the tray menu. The transcript is saved next to the recording, as a .txt file and as an .srt subtitle file for a media player. The first time, the app downloads the transcriber, about 5 GB. If PodcastClipper's WhisperX is on this PC, that one is used. A long meeting can take about as long to transcribe as it lasted. With speakers instead of a headset, your microphone also hears the others, so some of their words can show up as Me.",
        },
        {
            id: "tray",
            title: "Tray menu",
            words: "tray icon menu notification area clock red dot latest recording help about version progress",
            what: "The red dot in the notification area, by the clock, is the app. Right-click it for everything the app can do.",
            steps: [
                "Right-click the red dot.",
                "Choose Latest recording to see the last recording and its transcript.",
                "Choose Help to read a topic, or About to see the version.",
            ],
            keys: [],
            legend: [],
            more: "While a recording is transcribed, the top line of the menu shows how far it has come. Click it to see the transcript window. If the red dot is hidden, click the arrow by the clock.",
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
