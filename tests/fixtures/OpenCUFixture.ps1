param([Parameter(Mandatory=$true)][string]$Output, [Parameter(Mandatory=$true)][string]$CommandFile, [Parameter(Mandatory=$true)][string]$Title)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.IO;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
public class OpenCUFixture : Form {
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd,int command);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr w, int a, out RECT r, int size);
    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr w);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern uint EnumClipboardFormats(uint f);
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint f);
    [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr h);
    struct RECT { public int Left, Top, Right, Bottom; }
    readonly string output, command;
    readonly TextBox notes = new TextBox();
    readonly Button counter = new Button();
    readonly CheckBox check = new CheckBox();
    readonly TextBox password = new TextBox();
    readonly Panel marker = new Panel();
    Form cover;
    readonly TrackBar slider = new TrackBar();
    readonly Panel scrolling = new Panel();
    readonly Timer timer = new Timer();
    bool ready;
    int clicks, moves, wheel; string digest = "", error = "";
    public OpenCUFixture(string o, string c, string title) {
        output=o; command=c; Text=title; Name="OpenCUFixture";
        StartPosition=FormStartPosition.Manual; Location=new Point(120,100); ClientSize=new Size(680,560);
        AutoScaleMode=AutoScaleMode.Dpi;
        counter.Name="counterButton"; counter.AccessibleName="Fixture counter"; counter.Text="Fixture counter";
        counter.SetBounds(20,20,220,45); counter.Click += delegate { clicks++; Save(); };
        notes.Name="notes"; notes.AccessibleName="Fixture notes"; notes.Multiline=true; notes.SetBounds(20,90,620,100); notes.TextChanged += delegate { Save(); };
        password.Name="password";password.AccessibleName="Fixture password";password.UseSystemPasswordChar=true;password.Text="OpenCU-Fixture-Secret-7391";password.SetBounds(320,215,250,30);
        marker.BackColor=Color.Magenta;marker.SetBounds(590,20,50,45);
        check.Name="checkbox"; check.AccessibleName="Fixture checkbox"; check.Text="Fixture checkbox";check.SetBounds(20,215,260,40);check.CheckedChanged += delegate { Save(); };
        slider.Name="slider"; slider.AccessibleName="Fixture slider";slider.Minimum=0;slider.Maximum=100;slider.SetBounds(20,275,620,50);slider.ValueChanged += delegate { Save(); };
        scrolling.Name="scrollArea";scrolling.AccessibleName="Fixture scroll area";scrolling.SetBounds(20,355,620,170);scrolling.AutoScroll=true;
        var content=new Label();content.Text="Fixture scroll content";content.SetBounds(10,10,500,1500);scrolling.Controls.Add(content);
        scrolling.MouseWheel += delegate { wheel++; }; content.MouseWheel += delegate { wheel++; };
        Controls.AddRange(new Control[]{counter,notes,check,password,marker,slider,scrolling});
        timer.Interval=100;timer.Tick += delegate {
            if(File.Exists(command)) { var cmd=File.ReadAllText(command).Trim();File.Delete(command);
                if(cmd=="move") { Location=new Point(Location.X+40,Location.Y+30);moves++; }
                else if(cmd=="digest") { try{digest=ClipboardDigest();}catch(Exception e){error=e.Message;} }
                else if(cmd=="cover") { cover=new Form();cover.Text=Text+" Cover";cover.FormBorderStyle=FormBorderStyle.None;cover.StartPosition=FormStartPosition.Manual;cover.Bounds=Bounds;cover.BackColor=Color.Lime;cover.Show(this); }
                else if(cmd=="uncover") { if(cover!=null){cover.Close();cover.Dispose();cover=null;} }
                else if(cmd=="close") { Close();return; }
            }
            Save();
        };
        Shown += delegate {ShowWindow(Handle,1);ready=true;timer.Start();Save();};FormClosed += delegate{timer.Stop();};
    }
    static string Q(string s) {var b=new StringBuilder("\"");foreach(char c in s){if(c=='"'||c=='\\'){b.Append('\\');b.Append(c);}else if(c<32){b.Append("\\u");b.Append(((int)c).ToString("x4"));}else b.Append(c);}return b.Append('"').ToString();}
    void Save() {
        if(!ready || !IsHandleCreated || !IsWindowVisible(Handle))return;
        RECT r;DwmGetWindowAttribute(Handle,9,out r,16);Point p=counter.PointToScreen(new Point(counter.Width/2,counter.Height/2));Point m=marker.PointToScreen(new Point(marker.Width/2,marker.Height/2));
        var json="{\"pid\":"+System.Diagnostics.Process.GetCurrentProcess().Id+",\"clicks\":"+clicks+",\"notes\":"+Q(notes.Text)+",\"checked\":"+(check.Checked?"true":"false")+",\"slider\":"+slider.Value+",\"scroll\":"+(-scrolling.AutoScrollPosition.Y)+",\"wheel\":"+wheel+",\"moves\":"+moves+",\"x\":"+(p.X-r.Left)+",\"y\":"+(p.Y-r.Top)+",\"markerX\":"+(m.X-r.Left)+",\"markerY\":"+(m.Y-r.Top)+",\"width\":"+(r.Right-r.Left)+",\"height\":"+(r.Bottom-r.Top)+",\"clipboardDigest\":"+Q(digest)+",\"error\":"+Q(error)+"}";
        try{File.WriteAllText(output,json,new UTF8Encoding(false));}catch(IOException){}
    }
    static string ClipboardDigest(){
        if(!OpenClipboard(IntPtr.Zero))throw new Exception("Clipboard busy during digest");
        try{using(var data=new MemoryStream()){
            uint f=0;while((f=EnumClipboardFormats(f))!=0){
                if(f==2||f==3||f==9||f==14||f>=0x80&&f<0x400)throw new Exception("Clipboard contains an opaque handle format; preserve it and skip acceptance paste");
                var h=GetClipboardData(f);var n=GlobalSize(h).ToUInt64();if(n==0||n>67108864)throw new Exception("Unsupported clipboard format");
                var p=GlobalLock(h);if(p==IntPtr.Zero)throw new Exception("Cannot read clipboard digest");
                try{var b=new byte[(int)n];Marshal.Copy(p,b,0,b.Length);var id=BitConverter.GetBytes(f);data.Write(id,0,id.Length);data.Write(b,0,b.Length);}finally{GlobalUnlock(h);}
            }
            using(var hash=SHA256.Create()){return Convert.ToBase64String(hash.ComputeHash(data.ToArray()));}
        }}finally{CloseClipboard();}
    }
    public static void Run(string output,string command,string title){SetProcessDpiAwarenessContext(new IntPtr(-4));Application.EnableVisualStyles();Application.Run(new OpenCUFixture(output,command,title));}
}
'@
[OpenCUFixture]::Run($Output, $CommandFile, $Title)
