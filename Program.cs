using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

static class Native {
    [StructLayout(LayoutKind.Sequential)] public struct Interface { public int Size; public Guid Guid; public int Flags; public UIntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential, Pack=1)] public struct Descriptor { public byte Length,Type,Number,Alt,Endpoints,Class,Subclass,Protocol,String; }
    [StructLayout(LayoutKind.Sequential)] public struct Pipe { public int Type; public byte Id; public ushort MaxPacket; public byte Interval; }
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr SetupDiGetClassDevs(ref Guid guid,IntPtr enumerator,IntPtr parent,uint flags);
    [DllImport("setupapi.dll",SetLastError=true)] public static extern bool SetupDiEnumDeviceInterfaces(IntPtr set,IntPtr dev,ref Guid guid,uint index,ref Interface data);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set,ref Interface data,IntPtr detail,uint size,out uint required,IntPtr dev);
    [DllImport("setupapi.dll")] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("winusb.dll",SetLastError=true)] public static extern bool WinUsb_Initialize(SafeFileHandle file,out IntPtr usb);
    [DllImport("winusb.dll")] public static extern bool WinUsb_Free(IntPtr usb);
    [DllImport("winusb.dll",SetLastError=true)] public static extern bool WinUsb_QueryInterfaceSettings(IntPtr usb,byte alt,out Descriptor desc);
    [DllImport("winusb.dll",SetLastError=true)] public static extern bool WinUsb_QueryPipe(IntPtr usb,byte alt,byte index,out Pipe pipe);
    [DllImport("winusb.dll",SetLastError=true)] public static extern bool WinUsb_SetPipePolicy(IntPtr usb,byte pipe,uint policy,uint size,ref uint value);
    [DllImport("winusb.dll",SetLastError=true)] public static extern bool WinUsb_WritePipe(IntPtr usb,byte pipe,byte[] data,uint length,out uint written,IntPtr overlapped);
    [DllImport("winusb.dll",SetLastError=true)] public static extern bool WinUsb_ReadPipe(IntPtr usb,byte pipe,byte[] data,uint length,out uint read,IntPtr overlapped);
    static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public static List<string> Paths() {
        Guid guid=new("8F60D3B2-3D44-4D15-8F28-5A46D65E0F31"); List<string> paths=[];
        IntPtr set=SetupDiGetClassDevs(ref guid,IntPtr.Zero,IntPtr.Zero,0x12);
        if(set==new IntPtr(-1)) return paths;
        try { for(uint i=0;;i++) {
            Interface data=new(){Size=Marshal.SizeOf<Interface>()};
            if(!SetupDiEnumDeviceInterfaces(set,IntPtr.Zero,ref guid,i,ref data)) { if(Marshal.GetLastWin32Error()==259) break; Check(false); }
            SetupDiGetDeviceInterfaceDetail(set,ref data,IntPtr.Zero,0,out uint needed,IntPtr.Zero);
            IntPtr memory=Marshal.AllocHGlobal((int)needed);
            try { Marshal.WriteInt32(memory,IntPtr.Size==8?8:6); Check(SetupDiGetDeviceInterfaceDetail(set,ref data,memory,needed,out _,IntPtr.Zero)); paths.Add(Marshal.PtrToStringUni(memory+4)!); }
            finally { Marshal.FreeHGlobal(memory); }
        }} finally { SetupDiDestroyDeviceInfoList(set); }
        return paths;
    }
    public static void Ensure(bool value)=>Check(value);
}

sealed class Link : IDisposable {
    readonly SafeFileHandle file; IntPtr usb; byte input,output;
    public Link(string path) {
        file=Native.CreateFile(path,0xC0000000,3,IntPtr.Zero,3,0x40000000,IntPtr.Zero);
        try {
            Native.Ensure(!file.IsInvalid); Native.Ensure(Native.WinUsb_Initialize(file,out usb));
            Native.Ensure(Native.WinUsb_QueryInterfaceSettings(usb,0,out var descriptor));
            for(byte i=0;i<descriptor.Endpoints;i++) { Native.Ensure(Native.WinUsb_QueryPipe(usb,0,i,out var pipe)); if(pipe.Type!=2)continue; if((pipe.Id&128)!=0)input=pipe.Id;else output=pipe.Id; uint timeout=5000; Native.Ensure(Native.WinUsb_SetPipePolicy(usb,pipe.Id,3,4,ref timeout)); }
            if(input==0||output==0)throw new IOException("USB Authenticate endpoints unavailable");
        } catch { Dispose(); throw; }
    }
    public string Exchange(string text) {
        byte[] frame=new byte[4096], payload=Encoding.ASCII.GetBytes(text); if(payload.Length>=frame.Length)throw new IOException("frame too large"); payload.CopyTo(frame,0);
        Native.Ensure(Native.WinUsb_WritePipe(usb,output,frame,(uint)frame.Length,out uint written,IntPtr.Zero)); if(written!=frame.Length)throw new IOException("short USB write");
        byte[] reply=new byte[4096]; int offset=0;
        while(offset<reply.Length) { byte[] part=new byte[reply.Length-offset]; Native.Ensure(Native.WinUsb_ReadPipe(usb,input,part,(uint)part.Length,out uint read,IntPtr.Zero)); if(read==0)throw new IOException("USB closed"); Array.Copy(part,0,reply,offset,read); offset+=(int)read; }
        int end=Array.IndexOf(reply,(byte)0); return Encoding.ASCII.GetString(reply,0,end<0?reply.Length:end);
    }
    public void Dispose(){if(usb!=IntPtr.Zero){Native.WinUsb_Free(usb);usb=IntPtr.Zero;}file?.Dispose();}
}

static class Protocol {
    static string B64(byte[] value)=>Convert.ToBase64String(value);
    static byte[] Hkdf(byte[] secret,byte[] salt,byte[] info,int length) {
        using var hmac=new HMACSHA256(salt); byte[] prk=hmac.ComputeHash(secret),result=new byte[length],previous=[]; int offset=0,counter=1;
        while(offset<length){using var round=new HMACSHA256(prk); previous=round.ComputeHash([..previous,..info,(byte)counter++]); int copy=Math.Min(previous.Length,length-offset);Array.Copy(previous,0,result,offset,copy);offset+=copy;} CryptographicOperations.ZeroMemory(prk);return result;
    }
    public static string Authenticate(Link link,ECDsa identity,string label) {
        using ECDiffieHellman ephemeral=ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        string identityPublic=B64(identity.ExportSubjectPublicKeyInfo()),ephemeralPublic=B64(ephemeral.ExportSubjectPublicKeyInfo()),pcNonce=B64(RandomNumberGenerator.GetBytes(32)),label64=B64(Encoding.UTF8.GetBytes(label));
        string challenge=link.Exchange($"HELLO2 {identityPublic} {ephemeralPublic} {pcNonce} {label64}");
        string[] fields=challenge.Split(' '); if(fields.Length!=3||fields[0]!="CHALLENGE2")throw new IOException(challenge);
        string transcriptText=$"USBMANAGER/2\n{identityPublic}\n{ephemeralPublic}\n{fields[1]}\n{pcNonce}\n{fields[2]}\n{label64}"; byte[] transcript=Encoding.ASCII.GetBytes(transcriptText);
        using ECDiffieHellman phone=ECDiffieHellman.Create();phone.ImportSubjectPublicKeyInfo(Convert.FromBase64String(fields[1]),out _);
        byte[] salt=SHA256.HashData(Encoding.ASCII.GetBytes(pcNonce+fields[2])); byte[] key=Hkdf(ephemeral.DeriveKeyMaterial(phone.PublicKey),salt,Encoding.ASCII.GetBytes("USBManager Auth v2"),32);
        const string action="PAIR"; byte[] signed=[..transcript,(byte)'\n',..Encoding.ASCII.GetBytes(action)]; byte[] signature=identity.SignData(signed,HashAlgorithmName.SHA256,DSASignatureFormat.Rfc3279DerSequence);
        byte[] iv=RandomNumberGenerator.GetBytes(12),clear=Encoding.ASCII.GetBytes(action),cipher=new byte[clear.Length],tag=new byte[16]; using(var aes=new AesGcm(key,16))aes.Encrypt(iv,clear,cipher,tag,transcript);
        string response=link.Exchange($"AUTH2 {B64(signature)} {B64(iv)} {B64([..cipher,..tag])}"); fields=response.Split(' '); if(fields.Length!=3||fields[0]!="RESULT2")throw new IOException(response);
        byte[] encrypted=Convert.FromBase64String(fields[2]),plain=new byte[encrypted.Length-16]; using(var aes=new AesGcm(key,16))aes.Decrypt(Convert.FromBase64String(fields[1]),encrypted[..^16],encrypted[^16..],plain,transcript); CryptographicOperations.ZeroMemory(key);
        return Encoding.UTF8.GetString(plain);
    }
}

static class Identity {
    public static ECDsa Load(string path) {
        ECDsa key=ECDsa.Create(ECCurve.NamedCurves.nistP256);
        if(File.Exists(path))key.ImportPkcs8PrivateKey(Dpapi.Unprotect(File.ReadAllBytes(path)),out _);
        else {byte[] secret=key.ExportPkcs8PrivateKey();try{File.WriteAllBytes(path,Dpapi.Protect(secret));}finally{CryptographicOperations.ZeroMemory(secret);}}
        return key;
    }
}

static class Dpapi {
    [StructLayout(LayoutKind.Sequential)] struct Blob{public int Size;public IntPtr Data;}
    [DllImport("crypt32.dll",SetLastError=true,CharSet=CharSet.Unicode)]static extern bool CryptProtectData(ref Blob input,string? description,IntPtr entropy,IntPtr reserved,IntPtr prompt,uint flags,out Blob output);
    [DllImport("crypt32.dll",SetLastError=true)]static extern bool CryptUnprotectData(ref Blob input,IntPtr description,IntPtr entropy,IntPtr reserved,IntPtr prompt,uint flags,out Blob output);
    [DllImport("kernel32.dll")]static extern IntPtr LocalFree(IntPtr memory);
    static byte[] Transform(byte[] bytes,bool protect){var pin=GCHandle.Alloc(bytes,GCHandleType.Pinned);Blob input=new(){Size=bytes.Length,Data=pin.AddrOfPinnedObject()},output=default;try{Native.Ensure(protect?CryptProtectData(ref input,"USBManager computer identity",IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,1,out output):CryptUnprotectData(ref input,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,1,out output));byte[] result=new byte[output.Size];Marshal.Copy(output.Data,result,0,result.Length);return result;}finally{if(output.Data!=IntPtr.Zero)LocalFree(output.Data);pin.Free();}}
    public static byte[] Protect(byte[] value)=>Transform(value,true); public static byte[] Unprotect(byte[] value)=>Transform(value,false);
}

static class Program {
    const string RunName="USBManagerWinBackEnd";
    static readonly string Data=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),RunName);
    static void Log(string text){Directory.CreateDirectory(Data);File.AppendAllText(Path.Combine(Data,"backend.log"),$"{DateTimeOffset.Now:O} {text}{Environment.NewLine}");}
    static int Main(string[] args) {
        Directory.CreateDirectory(Data);
        if(args.Contains("--install")){using RegistryKey key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");key.SetValue(RunName,$"\"{Environment.ProcessPath}\" --background");return 0;}
        if(args.Contains("--uninstall")){using RegistryKey? key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run",true);key?.DeleteValue(RunName,false);return 0;}
        using var mutex=new Mutex(true,@"Local\USBManagerWinBackEnd",out bool owner);if(!owner)return 0;
        using ECDsa identity=Identity.Load(Path.Combine(Data,"identity.dpapi")); string label=Environment.MachineName; string? last=null;
        while(true){try{var paths=Native.Paths();if(paths.Count==1&&paths[0]!=last){using var link=new Link(paths[0]);string result=Protocol.Authenticate(link,identity,label);Log(result);if(result.StartsWith("KNOWN ")||result.StartsWith("PAIRED "))last=paths[0];else Thread.Sleep(2000);}else if(paths.Count==0)last=null;}catch(Exception error){Log("ERROR "+error.Message);last=null;}Thread.Sleep(500);}
    }
}
