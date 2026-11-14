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
 public static void Run(string output,string status,string stop,int parent){
  stateFile=status; stopping=false; failure="";
  WasapiCapture mic=null;List<Output> outs=new List<Output>();MMDeviceEnumerator devices=null;MMDevice md=null;
  FileStream file=null; long bytes=0; bool started=false; Stopwatch clock=new Stopwatch();
  try{
   devices=new MMDeviceEnumerator();md=devices.GetDefaultAudioEndpoint(DataFlow.Capture,Role.Communications);
   mic=new WasapiCapture(md);
   outs=OpenOutputs(devices);
   if(outs.Count==0)throw new Exception("No speaker or headset is on. Turn one on and try again.");
   var mb=new BufferedWaveProvider(mic.WaveFormat){BufferDuration=TimeSpan.FromSeconds(10),ReadFully=true};
   mic.DataAvailable+=(s,e)=>{try{mb.AddSamples(e.Buffer,0,e.BytesRecorded);}catch(Exception ex){failure="Microphone buffer: "+ex.Message;}};
   mic.RecordingStopped+=(s,e)=>{if(!stopping)failure="Microphone stopped"+(e.Exception==null?"":": "+e.Exception.Message);};
   var mp=Provider(mb);
   file=new FileStream(output,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read);Header(file,0);
   mic.StartRecording();
   foreach(var o in outs){try{o.Capture.StartRecording();}catch{o.Gone=true;}}
   var startup=Stopwatch.StartNew();
   while(mic.CaptureState!=CaptureState.Capturing || outs.Exists(o=>!o.Gone && o.Capture.CaptureState!=CaptureState.Capturing)){
    if(failure!="")throw new Exception(failure);
    if(startup.ElapsedMilliseconds>5000){
     if(mic.CaptureState!=CaptureState.Capturing)throw new Exception("Capture did not confirm startup.");
     foreach(var o in outs)if(o.Capture.CaptureState!=CaptureState.Capturing)o.Gone=true;
    }
    Thread.Sleep(10);
   }
   if(outs.TrueForAll(o=>o.Gone))throw new Exception("Capture did not confirm startup.");
   var names=new List<string>();foreach(var o in outs)if(!o.Gone)names.Add(o.Device.FriendlyName);
   started=true;clock.Start();Status("Recording",md.FriendlyName+" / "+string.Join(", ",names.ToArray()));
   float[] left=new float[4800],right=new float[4800],one=new float[4800];byte[] pcm=new byte[19200];long frames=0;long checkpoint=0;
   while(!File.Exists(stop)){
    if(failure!="")throw new Exception(failure);
    try{if(Process.GetProcessById(parent).HasExited)throw new Exception();}catch{failure="Controller exited; audio preserved.";break;}
    if(md.State!=DeviceState.Active)throw new Exception("An audio device disconnected.");
    foreach(var o in outs)if(o.Device.State!=DeviceState.Active)o.Gone=true;
    if(outs.TrueForAll(o=>o.Gone))throw new Exception("An audio device disconnected.");
    if(clock.Elapsed.TotalHours>=5){failure="Five-hour draft limit reached. Start a new recording.";break;}
    // Clock-paced output keeps silence in the file. Device-clock drift remains a validation gate.
    long target=(long)(Math.Max(0,clock.Elapsed.TotalSeconds-0.30)*48000);
    int n=(int)Math.Min(4800,target-frames);
    if(n<=0){Thread.Sleep(10);continue;}
    Mix(outs,left,one,n);mp.Read(right,0,n);
    for(int i=0;i<n;i++){
     short l=(short)(Math.Max(-1,Math.Min(1,left[i]))*32767);short r=(short)(Math.Max(-1,Math.Min(1,right[i]))*32767);
     pcm[i*4]=(byte)l;pcm[i*4+1]=(byte)(l>>8);pcm[i*4+2]=(byte)r;pcm[i*4+3]=(byte)(r>>8);
    }
    file.Write(pcm,0,n*4);bytes+=n*4;frames+=n;
    if(clock.ElapsedMilliseconds-checkpoint>=1000){Header(file,bytes);checkpoint=clock.ElapsedMilliseconds;}
   }
   clock.Stop();
   stopping=true;mic.StopRecording();foreach(var o in outs){try{o.Capture.StopRecording();}catch{}}
   var drain=Stopwatch.StartNew();while((mic.CaptureState!=CaptureState.Stopped || outs.Exists(o=>o.Capture.CaptureState!=CaptureState.Stopped))&&drain.ElapsedMilliseconds<3000)Thread.Sleep(10);
   // Drain queued audio up to elapsed capture duration, preserving the latency tail.
   long remaining=(long)(clock.Elapsed.TotalSeconds*48000)-frames;
   while(remaining>0){int n=(int)Math.Min(4800,remaining);Mix(outs,left,one,n);mp.Read(right,0,n);
    for(int i=0;i<n;i++){short l=(short)(Math.Max(-1,Math.Min(1,left[i]))*32767);short r=(short)(Math.Max(-1,Math.Min(1,right[i]))*32767);pcm[i*4]=(byte)l;pcm[i*4+1]=(byte)(l>>8);pcm[i*4+2]=(byte)r;pcm[i*4+3]=(byte)(r>>8);}file.Write(pcm,0,n*4);bytes+=n*4;remaining-=n;}
  }catch(Exception ex){failure=ex.Message;}
  finally{
   stopping=true;
   try{if(mic!=null)mic.Dispose();}catch{}
   foreach(var o in outs){try{o.Capture.Dispose();}catch{} try{o.Device.Dispose();}catch{}}
   try{if(file!=null){Header(file,bytes);file.Dispose();}}catch(Exception ex){failure="Write/finalization failed: "+ex.Message;try{file.Dispose();}catch{}}
   if(md!=null)md.Dispose();if(devices!=null)devices.Dispose();
  }
  try{
   if(!started || bytes==0){Status("Error",failure==""?"No audio saved.":failure);return;}
   using(var check=new WaveFileReader(output)){if(check.Length!=bytes || check.WaveFormat.Channels!=2)throw new Exception("WAV validation failed.");}
   string final=output.Replace(".partial.wav",failure==""?".wav":" - Incomplete.wav");File.Move(output,final);
   Status(failure==""?"Saved":"Incomplete",final+(failure==""?"":" | "+failure));
  }catch(Exception ex){Status("Error","Recovery audio remains at "+output+" | "+ex.Message);}
 }
}
