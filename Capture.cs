using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
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
 static void Header(FileStream f,long bytes){
  long pos=f.Position; f.Position=0;
  using(var w=new BinaryWriter(f,System.Text.Encoding.ASCII,true)){
   w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));w.Write((uint)(36+bytes));w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
   w.Write(16);w.Write((short)1);w.Write((short)2);w.Write(48000);w.Write(192000);w.Write((short)4);w.Write((short)16);
   w.Write(System.Text.Encoding.ASCII.GetBytes("data"));w.Write((uint)bytes);
  } f.Position=Math.Max(44,pos);f.Flush(true);
 }
 public static void Run(string output,string status,string stop,int parent){
  stateFile=status; stopping=false; failure="";
  WasapiCapture mic=null;WasapiLoopbackCapture loop=null;MMDeviceEnumerator devices=null;MMDevice md=null,od=null;
  FileStream file=null; long bytes=0; bool started=false; Stopwatch clock=new Stopwatch();
  try{
   devices=new MMDeviceEnumerator();md=devices.GetDefaultAudioEndpoint(DataFlow.Capture,Role.Communications);od=devices.GetDefaultAudioEndpoint(DataFlow.Render,Role.Communications);
   mic=new WasapiCapture(md);loop=new WasapiLoopbackCapture(od);
   var mb=new BufferedWaveProvider(mic.WaveFormat){BufferDuration=TimeSpan.FromSeconds(10),ReadFully=true};
   var lb=new BufferedWaveProvider(loop.WaveFormat){BufferDuration=TimeSpan.FromSeconds(10),ReadFully=true};
   mic.DataAvailable+=(s,e)=>{try{mb.AddSamples(e.Buffer,0,e.BytesRecorded);}catch(Exception ex){failure="Microphone buffer: "+ex.Message;}};
   loop.DataAvailable+=(s,e)=>{try{lb.AddSamples(e.Buffer,0,e.BytesRecorded);}catch(Exception ex){failure="Output buffer: "+ex.Message;}};
   mic.RecordingStopped+=(s,e)=>{if(!stopping)failure="Microphone stopped"+(e.Exception==null?"":": "+e.Exception.Message);};
   loop.RecordingStopped+=(s,e)=>{if(!stopping)failure="Output stopped"+(e.Exception==null?"":": "+e.Exception.Message);};
   var mp=Provider(mb);var lp=Provider(lb);
   file=new FileStream(output,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read);Header(file,0);
   mic.StartRecording();loop.StartRecording();
   var startup=Stopwatch.StartNew();
   while(mic.CaptureState!=CaptureState.Capturing || loop.CaptureState!=CaptureState.Capturing){
    if(failure!="")throw new Exception(failure);if(startup.ElapsedMilliseconds>5000)throw new Exception("Capture did not confirm startup.");Thread.Sleep(10);
   }
   started=true;clock.Start();Status("Recording",md.FriendlyName+" / "+od.FriendlyName);
   float[] left=new float[4800],right=new float[4800];byte[] pcm=new byte[19200];long frames=0;long checkpoint=0;
   while(!File.Exists(stop)){
    if(failure!="")throw new Exception(failure);
    try{if(Process.GetProcessById(parent).HasExited)throw new Exception();}catch{failure="Controller exited; audio preserved.";break;}
    if(md.State!=DeviceState.Active || od.State!=DeviceState.Active)throw new Exception("An audio device disconnected.");
    if(clock.Elapsed.TotalHours>=5){failure="Five-hour draft limit reached. Start a new recording.";break;}
    // Clock-paced output keeps silence in the file. Device-clock drift remains a validation gate.
    long target=(long)(Math.Max(0,clock.Elapsed.TotalSeconds-0.30)*48000);
    int n=(int)Math.Min(4800,target-frames);
    if(n<=0){Thread.Sleep(10);continue;}
    lp.Read(left,0,n);mp.Read(right,0,n);
    for(int i=0;i<n;i++){
     short l=(short)(Math.Max(-1,Math.Min(1,left[i]))*32767);short r=(short)(Math.Max(-1,Math.Min(1,right[i]))*32767);
     pcm[i*4]=(byte)l;pcm[i*4+1]=(byte)(l>>8);pcm[i*4+2]=(byte)r;pcm[i*4+3]=(byte)(r>>8);
    }
    file.Write(pcm,0,n*4);bytes+=n*4;frames+=n;
    if(clock.ElapsedMilliseconds-checkpoint>=1000){Header(file,bytes);checkpoint=clock.ElapsedMilliseconds;}
   }
   clock.Stop();
   stopping=true;mic.StopRecording();loop.StopRecording();
   var drain=Stopwatch.StartNew();while((mic.CaptureState!=CaptureState.Stopped || loop.CaptureState!=CaptureState.Stopped)&&drain.ElapsedMilliseconds<3000)Thread.Sleep(10);
   // Drain queued audio up to elapsed capture duration, preserving the latency tail.
   long remaining=(long)(clock.Elapsed.TotalSeconds*48000)-frames;
   while(remaining>0){int n=(int)Math.Min(4800,remaining);lp.Read(left,0,n);mp.Read(right,0,n);
    for(int i=0;i<n;i++){short l=(short)(Math.Max(-1,Math.Min(1,left[i]))*32767);short r=(short)(Math.Max(-1,Math.Min(1,right[i]))*32767);pcm[i*4]=(byte)l;pcm[i*4+1]=(byte)(l>>8);pcm[i*4+2]=(byte)r;pcm[i*4+3]=(byte)(r>>8);}file.Write(pcm,0,n*4);bytes+=n*4;remaining-=n;}
  }catch(Exception ex){failure=ex.Message;}
  finally{
   stopping=true;
   try{if(mic!=null)mic.Dispose();}catch{}
   try{if(loop!=null)loop.Dispose();}catch{}
   try{if(file!=null){Header(file,bytes);file.Dispose();}}catch(Exception ex){failure="Write/finalization failed: "+ex.Message;try{file.Dispose();}catch{}}
   if(md!=null)md.Dispose();if(od!=null)od.Dispose();if(devices!=null)devices.Dispose();
  }
  try{
   if(!started || bytes==0){Status("Error",failure==""?"No audio saved.":failure);return;}
   using(var check=new WaveFileReader(output)){if(check.Length!=bytes || check.WaveFormat.Channels!=2)throw new Exception("WAV validation failed.");}
   string final=output.Replace(".partial.wav",failure==""?".wav":" - Incomplete.wav");File.Move(output,final);
   Status(failure==""?"Saved":"Incomplete",final+(failure==""?"":" | "+failure));
  }catch(Exception ex){Status("Error","Recovery audio remains at "+output+" | "+ex.Message);}
 }
}
