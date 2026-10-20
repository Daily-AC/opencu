// Disposable Windows acceptance fixture. Its files are beside its temporary exe.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class AgentDesktopFixture : Form {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count, INPUT[] input, int size);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr window, ref POINT point);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int x,y; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTDATA data; }
    [StructLayout(LayoutKind.Explicit)] struct INPUTDATA { [FieldOffset(0)] public KEYBOARD keyboard; [FieldOffset(0)] public MOUSE mouse; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBOARD { public ushort vk, scan; public uint flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSE { public int dx, dy; public uint data, flags, time; public UIntPtr extra; }
    readonly TextBox edit = new TextBox { Name="FixtureText", AccessibleName="Fixture text", Location=new Point(20,60), Width=500 };
    readonly Button button = new Button { Text="Increment fixture", Location=new Point(20,110), Width=180 };
    readonly Label counter = new Label { Text="Clicks: 0", Location=new Point(220,115), AutoSize=true };
    readonly string file = Application.ExecutablePath + ".json";
    readonly string command = Application.ExecutablePath + ".command";
    int clicks, chunks, foreignForeground, injectedFailures, unexpectedCursor, hoverMoves;
    Process hoverHost;
    bool parkRequest, parkPending, parked;
    POINT parkedCursor;
    bool monitor, injecting, parentMode;
    string expected = "";
    DateTime next = DateTime.MinValue;
    POINT lastCursor;
    bool hasCursor;
    [STAThread] static void Main(string[] args) {
        SetProcessDpiAwarenessContext(new IntPtr(-4));
        Application.EnableVisualStyles(); Application.Run(new AgentDesktopFixture(args.Length == 1 && args[0] == "parent"));
    }
    AgentDesktopFixture(bool parent) {
        parentMode = parent;
        Text = "OpenCU disposable " + Path.GetFileNameWithoutExtension(Application.ExecutablePath);
        StartPosition = FormStartPosition.Manual; Location = new Point(30,30); ClientSize = new Size(560,220);
        Controls.Add(edit); Controls.Add(button); Controls.Add(counter);
        button.Click += delegate { clicks++; counter.Text="Clicks: " + clicks; };
        Shown += delegate { Activate(); edit.Focus(); };
        var timer = new Timer { Interval=40 };
        timer.Tick += delegate { Tick(); }; timer.Start();
    }
    void Tick() {
        if (File.Exists(command)) {
            string action;
            try { action = File.ReadAllText(command).Trim(); File.Delete(command); }
            catch (IOException) { return; } // Command publication may overlap a reader.
            if (action == "close") { Close(); return; }
            if (action == "monitor" && parentMode) { monitor=true; }
            if (action == "begin" && parentMode) { injecting=true; next=DateTime.UtcNow; }
            if (action == "end") { monitor=false; injecting=false; }
            if (action == "hover-stop") { if (hoverHost != null) hoverHost.Dispose(); hoverHost=null; }
            if (parentMode && (action.StartsWith("hover:") || action.StartsWith("park:"))) {
                parkRequest = action.StartsWith("park:"); parked=false; parkPending=false;
                hoverHost = Process.GetProcessById(Int32.Parse(action.Substring(action.IndexOf(':') + 1)));
                if (hoverHost.SessionId != Process.GetCurrentProcess().SessionId || hoverHost.MainWindowTitle != "OpenCU agent desktop") {
                    hoverHost.Dispose(); hoverHost=null; injectedFailures++;
                }
            }
        }
        if (monitor && GetForegroundWindow() != Handle) foreignForeground++;
        POINT cursor; GetCursorPos(out cursor);
        if (monitor && hasCursor && (Math.Abs(cursor.x-lastCursor.x) > 2 || Math.Abs(cursor.y-lastCursor.y) > 2)) unexpectedCursor++;
        if (parkPending) {
            // Sample the actual pixel after the one SendInput move has settled.
            // No further move is sent during the parked-pointer check.
            parkedCursor=cursor; lastCursor=cursor; parked=true; parkPending=false;
        }
        if (hoverHost != null) {
            RECT bounds;
            if (hoverHost.HasExited || GetForegroundWindow() != Handle || !GetClientRect(hoverHost.MainWindowHandle, out bounds)) {
                injectedFailures++; hoverHost.Dispose(); hoverHost=null;
            } else {
                var point = new POINT { x=bounds.right/2 + hoverMoves%20, y=bounds.bottom*3/4 };
                if (!ClientToScreen(hoverHost.MainWindowHandle, ref point) || GetAncestor(WindowFromPoint(point), 2) != hoverHost.MainWindowHandle) injectedFailures++;
                else {
                    MovePointer(point); hoverMoves++;
                    if (parkRequest) { parkPending=true; hoverHost.Dispose(); hoverHost=null; }
                }
            }
        }
        if (injecting && DateTime.UtcNow >= next && chunks < 20) {
            next = DateTime.UtcNow.AddMilliseconds(300);
            // Never knowingly send a stimulus into any other window. A focus
            // violation fails the test; do not repair foreground or replay input.
            if (GetForegroundWindow() != Handle || !edit.Focused) { injecting=false; injectedFailures++; }
            else {
                string chunk = "p" + chunks.ToString("D2") + ";";
                foreach (char ch in chunk) {
                    var inputs = new INPUT[] {
                        new INPUT { type=1, data=new INPUTDATA { keyboard=new KEYBOARD { scan=ch, flags=4 } } },
                        new INPUT { type=1, data=new INPUTDATA { keyboard=new KEYBOARD { scan=ch, flags=6 } } }
                    };
                    if (SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT))) != 2) injectedFailures++;
                }
                expected += chunk; chunks++;
                // Move inside the parent fixture. Absolute coordinates are normalized
                // to its primary desktop; use only the primary-monitor fixture region.
                var point = edit.PointToScreen(new Point(20 + chunks, 10));
                MovePointer(new POINT { x=point.X, y=point.Y });
            }
        }
        var state = new { pid=Process.GetCurrentProcess().Id, sessionId=Process.GetCurrentProcess().SessionId, text=edit.Text, clicks=clicks,
            chunks=chunks, expected=expected, foreignForeground=foreignForeground, injectedFailures=injectedFailures, unexpectedCursor=unexpectedCursor,
            foreground=GetForegroundWindow()==Handle, title=Text, hoverMoves=hoverMoves,
            cursor=cursor, parked=parked, parkedCursor=parkedCursor };
        string temp=file + ".tmp";
        try {
            File.WriteAllText(temp, new JavaScriptSerializer().Serialize(state), new UTF8Encoding(false));
            if (File.Exists(file)) File.Replace(temp,file,null); else File.Move(temp,file);
        } catch (IOException) { /* Sharing violation: publish the latest state on the next tick. */ }
    }
    void MovePointer(POINT point) {
        var screen = Screen.PrimaryScreen.Bounds;
        if (!screen.Contains(point.x, point.y)) { injectedFailures++; return; }
        var movement = new INPUT { type=0, data=new INPUTDATA { mouse=new MOUSE { dx=point.x*65535/(screen.Width-1), dy=point.y*65535/(screen.Height-1), flags=0x8001 } } };
        if (SendInput(1, new INPUT[] { movement }, Marshal.SizeOf(typeof(INPUT))) != 1) injectedFailures++;
        lastCursor = point; hasCursor=true;
    }
}
