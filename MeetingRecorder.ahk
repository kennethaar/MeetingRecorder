#Requires AutoHotkey v2.0
#SingleInstance Ignore
Persistent
AppVersion := "0.1.2"
AppDir := EnvGet("LOCALAPPDATA") "\MeetingRecorder"
DirCreate(AppDir)
Config := AppDir "\settings.ini"
Folder := IniRead(Config, "Settings", "Folder", A_MyDocuments "\Meeting Recordings")
Shortcut := IniRead(Config, "Settings", "Shortcut", "^!r")
Latest := IniRead(Config, "Settings", "Latest", "")
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
Panel.OnEvent("Close", (*) => Panel.Hide())
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
if !FileExist(Config) {
 MsgBox("This draft records manually.`n`nLeft: all audio on your Windows communications output.`nRight: your communications microphone.`n`nMuting in a call may NOT mute this recording.`nThe app does not notify participants. Follow your organization's recording rules.`n`nFiles: " Folder "`n`nFirst launch downloads NAudio 2.2.1. Later recording works offline.`nAutomatic detection and calendars are not enabled in this draft.", "Set up Meeting Recorder")
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
 global State, Child, Folder, StatusPath, StopPath, StartTick, Label, Action
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
 try {
  DirCreate(Folder)
  if DriveGetSpaceFree(Folder) < 512
   throw Error("Less than 512 MB free. Choose another folder.")
  probe := Folder "\.write-test-" A_TickCount
  FileAppend("test",probe), FileDelete(probe)
  try FileDelete(StopPath)
  try FileDelete(StatusPath)
  name := Folder "\" FormatTime(,"yyyy-MM-dd HHmmss") " - Recording - " SubStr(CreateGuid(),1,8) ".partial.wav"
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
 State := "Saving"
 Label.Text := "Saving recording..."
}
Poll() {
 global State, Child, StatusPath, StartTick, Label, Action, Latest, Config, Closing
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
   State := "Manual only"
   Label.Text := s = "Saved" ? "Recording saved" : "Attention: recording incomplete"
   Action.Text := "Start"
   SavedNotice(s,detail)
  } else if s = "Error" && State != "Attention required" {
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
  Label.Text := "Recording  " elapsed
  A_IconTip := "Meeting Recorder`nRecording: " elapsed
 } else A_IconTip := "Meeting Recorder`n" State
 if Child && !ProcessExist(Child) {
  Child := 0
  if State = "Recording" || State = "Starting" || State = "Saving" || State = "Installing" {
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
 global Folder, Config, Shortcut
 g := Gui(,"Meeting Recorder settings")
 g.SetFont("s10","Segoe UI")
 g.AddText("w510","Manual recording draft. Uses Windows communications devices.`nChanges apply to the next recording.")
 g.AddText(,"Recording folder")
 f := g.AddEdit("vFolder w510",Folder)
 g.AddButton("vBrowse w100","Browse").OnEvent("Click",(*) => BrowseFolder(f))
 g.AddText(,"Shortcut")
 h := g.AddHotkey("vShortcut w220",Shortcut)
 g.AddText("w510","Automatic call detection and calendar naming are not available yet.`nAudio test: start a short recording, speak while playing audio, then play the saved WAV. Left = output; right = microphone.")
 g.AddButton("vSave w100 Default","Save").OnEvent("Click",SaveSettings)
 g.Show()
 SaveSettings(*) {
  global Folder, Shortcut, Config
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
            id: "settings",
            title: "Settings",
            words: "settings folder shortcut hotkey save location options",
            what: "Choose where recordings are saved and which keys start and stop them.",
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
                ["Settings.Save", "Save changes"],
            ],
            view: "Settings",
            more: "Settings are kept in %LOCALAPPDATA%\MeetingRecorder\settings.ini.",
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
