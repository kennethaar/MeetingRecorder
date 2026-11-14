using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
using System.Collections.Generic;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using NAudio.CoreAudioApi;

public static class CaptureEngine {
 static volatile bool stopping;
 static volatile string failure = "";
 static string stateFile;
 static void Status(string state, string detail) {
  string text="[Capture]\r\nState="+state+"\r\nDetail="+detail.Replace("\r"," ").Replace("\n"," ")+"\r\n";
  string tmp=stateFile+".tmp"; File.WriteAllText(tmp,text,System.Text.Encoding.Unicode);
  if(File.Exists(stateFile)) File.Replace(tmp,stateFile,null); else File.Move(tmp,stateFile);
 }
 sealed class Mono : ISampleProvider {
  ISampleProvider source; float[] scratch=new float[0];
  public Mono(ISampleProvider s){source=s;WaveFormat=WaveFormat.CreateIeeeFloatWaveFormat(s.WaveFormat.SampleRate,1);}
  public WaveFormat WaveFormat {get;private set;}
  public int Read(float[] b,int o,int n){int ch=source.WaveFormat.Channels; if(scratch.Length<n*ch)scratch=new float[n*ch]; int got=source.Read(scratch,0,n*ch)/ch; for(int i=0;i<got;i++){float sum=0;for(int c=0;c<ch;c++)sum+=scratch[i*ch+c];b[o+i]=sum/ch;}return got;}
 }
 static ISampleProvider Provider(BufferedWaveProvider b){return new WdlResamplingSampleProvider(new Mono(b.ToSampleProvider()),48000);}
 // One active speaker or headset (#13). Others is the mix of all of them, because Teams may play
 // the call on any of them, not only on the Windows default communication device.
 sealed class Output {
  public MMDevice Device; public WasapiLoopbackCapture Capture; public ISampleProvider Samples; public volatile bool Gone;
 }
 static List<Output> OpenOutputs(MMDeviceEnumerator devices){
  var outs=new List<Output>();
  foreach(var d in devices.EnumerateAudioEndPoints(DataFlow.Render,DeviceState.Active)){
   var o=new Output{Device=d};
   try{
    o.Capture=new WasapiLoopbackCapture(d);
    var buffer=new BufferedWaveProvider(o.Capture.WaveFormat){BufferDuration=TimeSpan.FromSeconds(10),ReadFully=true};
    o.Capture.DataAvailable+=(s,e)=>{try{buffer.AddSamples(e.Buffer,0,e.BytesRecorded);}catch(Exception ex){failure="Output buffer: "+ex.Message;}};
    // A speaker that drops out (a headset going to sleep) leaves the others recording.
    o.Capture.RecordingStopped+=(s,e)=>{if(!stopping)o.Gone=true;};
    o.Samples=Provider(buffer);
    outs.Add(o);
   }catch{try{if(o.Capture!=null)o.Capture.Dispose();}catch{} d.Dispose();}
  }
  return outs;
 }
 // The microphone for Me (#14): the one chosen in Settings, or the Windows default when it is not
 // there. If it drops out during a recording, the Windows default takes over instead of stopping.
 sealed class Mic {
  public MMDevice Device; public WasapiCapture Capture; public ISampleProvider Samples; public volatile bool Gone;
 }
 static MMDevice PickMic(MMDeviceEnumerator devices,string id,string notId){
  if(!string.IsNullOrEmpty(id)){
   try{var d=devices.GetDevice(id);if(d.State==DeviceState.Active)return d;d.Dispose();}catch{}
  }
  try{var d=devices.GetDefaultAudioEndpoint(DataFlow.Capture,Role.Communications);if(d.State==DeviceState.Active && d.ID!=notId)return d;d.Dispose();}catch{}
  // Windows may still name the one that just dropped out as default: take any other one.
  try{foreach(var d in devices.EnumerateAudioEndPoints(DataFlow.Capture,DeviceState.Active)){if(d.ID!=notId)return d;d.Dispose();}}catch{}
  return null;
 }
 static void ReadMic(Mic m,float[] right,int n){if(m==null)Array.Clear(right,0,n);else m.Samples.Read(right,0,n);}
 static bool Active(MMDevice d){try{return d.State==DeviceState.Active;}catch{return false;}}
 static Mic OpenMic(MMDevice d){
  var m=new Mic{Device=d};
  m.Capture=new WasapiCapture(d);
  var buffer=new BufferedWaveProvider(m.Capture.WaveFormat){BufferDuration=TimeSpan.FromSeconds(10),ReadFully=true};
  m.Capture.DataAvailable+=(s,e)=>{try{buffer.AddSamples(e.Buffer,0,e.BytesRecorded);}catch(Exception ex){failure="Microphone buffer: "+ex.Message;}};
  m.Capture.RecordingStopped+=(s,e)=>{if(!stopping)m.Gone=true;};
  m.Samples=Provider(buffer);
  return m;
 }
 static void CloseMic(Mic m){
  if(m==null)return;
  try{m.Capture.StopRecording();}catch{}
  try{m.Capture.Dispose();}catch{}
  try{m.Device.Dispose();}catch{}
 }
 static void Header(FileStream f,long bytes){
  long pos=f.Position; f.Position=0;
  using(var w=new BinaryWriter(f,System.Text.Encoding.ASCII,true)){
   w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));w.Write((uint)(36+bytes));w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
   w.Write(16);w.Write((short)1);w.Write((short)2);w.Write(48000);w.Write(192000);w.Write((short)4);w.Write((short)16);
   w.Write(System.Text.Encoding.ASCII.GetBytes("data"));w.Write((uint)bytes);
  } f.Position=Math.Max(44,pos);f.Flush(true);
 }
 // Others = the sum of every speaker. Each one is read every time, also after it is gone, so all
 // keep the same pace; a gone one gives silence.
 static void Mix(List<Output> outs,float[] left,float[] one,int n){
  Array.Clear(left,0,n);
  foreach(var o in outs){o.Samples.Read(one,0,n);for(int i=0;i<n;i++)left[i]+=one[i];}
 }
 public static void Run(string output,string status,string stop,int parent){Run(output,status,stop,parent,"");}
 public static void Run(string output,string status,string stop,int parent,string micId){
  stateFile=status; stopping=false; failure="";
  Mic mic=null;List<Output> outs=new List<Output>();MMDeviceEnumerator devices=null;
  FileStream file=null; long bytes=0; bool started=false; Stopwatch clock=new Stopwatch();
  try{
   devices=new MMDeviceEnumerator();
   var md=PickMic(devices,micId,null);
   if(md==null)throw new Exception("No microphone is on. Turn one on and try again.");
   mic=OpenMic(md);
   outs=OpenOutputs(devices);
   if(outs.Count==0)throw new Exception("No speaker or headset is on. Turn one on and try again.");
   file=new FileStream(output,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read);Header(file,0);
   mic.Capture.StartRecording();
   foreach(var o in outs){try{o.Capture.StartRecording();}catch{o.Gone=true;}}
   var startup=Stopwatch.StartNew();
   while(mic.Capture.CaptureState!=CaptureState.Capturing || outs.Exists(o=>!o.Gone && o.Capture.CaptureState!=CaptureState.Capturing)){
    if(failure!="")throw new Exception(failure);
    if(startup.ElapsedMilliseconds>5000){
     if(mic.Capture.CaptureState!=CaptureState.Capturing)throw new Exception("Capture did not confirm startup.");
     foreach(var o in outs)if(o.Capture.CaptureState!=CaptureState.Capturing)o.Gone=true;
    }
    Thread.Sleep(10);
   }
   if(outs.TrueForAll(o=>o.Gone))throw new Exception("Capture did not confirm startup.");
   var names=new List<string>();foreach(var o in outs)if(!o.Gone)names.Add(o.Device.FriendlyName);
   string speakers=string.Join(", ",names.ToArray());
   started=true;clock.Start();Status("Recording",mic.Device.FriendlyName+" / "+speakers);
   float[] left=new float[4800],right=new float[4800],one=new float[4800];byte[] pcm=new byte[19200];long frames=0;long checkpoint=0;
   Stopwatch noMic=null,lastTry=null; string goneId=null;
   while(!File.Exists(stop)){
    if(failure!="")throw new Exception(failure);
    try{if(Process.GetProcessById(parent).HasExited)throw new Exception();}catch{failure="Controller exited; audio preserved.";break;}
    // The microphone dropped out: Me stays silent until the Windows default takes over (#14).
    if(mic!=null && (mic.Gone || !Active(mic.Device))){goneId=mic.Device.ID;CloseMic(mic);mic=null;noMic=Stopwatch.StartNew();lastTry=null;}
    if(mic==null && (lastTry==null || lastTry.ElapsedMilliseconds>=500)){
     lastTry=Stopwatch.StartNew();
     var d=PickMic(devices,null,goneId);
     if(d!=null){try{mic=OpenMic(d);mic.Capture.StartRecording();Status("Recording",d.FriendlyName+" / "+speakers);}catch{CloseMic(mic);mic=null;}}
     else if(noMic.Elapsed.TotalSeconds>=30)throw new Exception("The microphone disconnected.");
    }
    foreach(var o in outs)if(!Active(o.Device))o.Gone=true;
    if(outs.TrueForAll(o=>o.Gone))throw new Exception("An audio device disconnected.");
    if(clock.Elapsed.TotalHours>=5){failure="Five-hour draft limit reached. Start a new recording.";break;}
    // Clock-paced output keeps silence in the file. Device-clock drift remains a validation gate.
    long target=(long)(Math.Max(0,clock.Elapsed.TotalSeconds-0.30)*48000);
    int n=(int)Math.Min(4800,target-frames);
    if(n<=0){Thread.Sleep(10);continue;}
    Mix(outs,left,one,n);ReadMic(mic,right,n);
    for(int i=0;i<n;i++){
     short l=(short)(Math.Max(-1,Math.Min(1,left[i]))*32767);short r=(short)(Math.Max(-1,Math.Min(1,right[i]))*32767);
     pcm[i*4]=(byte)l;pcm[i*4+1]=(byte)(l>>8);pcm[i*4+2]=(byte)r;pcm[i*4+3]=(byte)(r>>8);
    }
    file.Write(pcm,0,n*4);bytes+=n*4;frames+=n;
    if(clock.ElapsedMilliseconds-checkpoint>=1000){Header(file,bytes);checkpoint=clock.ElapsedMilliseconds;}
   }
   clock.Stop();
   stopping=true;if(mic!=null){try{mic.Capture.StopRecording();}catch{}}foreach(var o in outs){try{o.Capture.StopRecording();}catch{}}
   var drain=Stopwatch.StartNew();while(((mic!=null && mic.Capture.CaptureState!=CaptureState.Stopped) || outs.Exists(o=>o.Capture.CaptureState!=CaptureState.Stopped))&&drain.ElapsedMilliseconds<3000)Thread.Sleep(10);
   // Drain queued audio up to elapsed capture duration, preserving the latency tail.
   long remaining=(long)(clock.Elapsed.TotalSeconds*48000)-frames;
   while(remaining>0){int n=(int)Math.Min(4800,remaining);Mix(outs,left,one,n);ReadMic(mic,right,n);
    for(int i=0;i<n;i++){short l=(short)(Math.Max(-1,Math.Min(1,left[i]))*32767);short r=(short)(Math.Max(-1,Math.Min(1,right[i]))*32767);pcm[i*4]=(byte)l;pcm[i*4+1]=(byte)(l>>8);pcm[i*4+2]=(byte)r;pcm[i*4+3]=(byte)(r>>8);}file.Write(pcm,0,n*4);bytes+=n*4;remaining-=n;}
  }catch(Exception ex){failure=ex.Message;}
  finally{
   stopping=true;
   CloseMic(mic);
   foreach(var o in outs){try{o.Capture.Dispose();}catch{} try{o.Device.Dispose();}catch{}}
   try{if(file!=null){Header(file,bytes);file.Dispose();}}catch(Exception ex){failure="Write/finalization failed: "+ex.Message;try{file.Dispose();}catch{}}
   if(devices!=null)devices.Dispose();
  }
  try{
   if(!started || bytes==0){Status("Error",failure==""?"No audio saved.":failure);return;}
   using(var check=new WaveFileReader(output)){if(check.Length!=bytes || check.WaveFormat.Channels!=2)throw new Exception("WAV validation failed.");}
   string final=output.Replace(".partial.wav",failure==""?".wav":" - Incomplete.wav");File.Move(output,final);
   Status(failure==""?"Saved":"Incomplete",final+(failure==""?"":" | "+failure));
  }catch(Exception ex){Status("Error","Recovery audio remains at "+output+" | "+ex.Message);}
 }
}
