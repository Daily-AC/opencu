// Compiled offline with the Windows .NET Framework compiler during explicit setup.
// Application automation stays in the ordinary Rust engine. No credential APIs.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;

namespace OpenCUAgentDesktop {
    sealed class SetupRequiredException : IOException {
        internal SetupRequiredException(string reason) : base(reason + " Run in PowerShell: " + Tasks.SetupCommand) { }
    }
    static class ParentSessionPolicy {
        internal static bool EndsDesktop(int reason) {
            // Lock (7) and unlock (8) preserve the existing child and transport.
            // Console/remote disconnect (2/4) and logoff (6) still end ownership.
            return reason == 2 || reason == 4 || reason == 6;
        }
    }
    static class RdpPointerPolicy {
        internal const string Property = "IgnoreServerGeneratedMouseMoves";
        internal static void Configure(Action<string, bool> set, Func<string, object> get) {
            // This setting suppresses server Pointer Position Update PDUs. The
            // documented property cannot change after Connect, so keep it on in
            // interactive mode too; never reconnect just to toggle cursor warping.
            set(Property, true);
            object confirmed = get(Property);
            if (!(confirmed is bool) || !(bool)confirmed)
                throw new IOException("RDP did not confirm server pointer-move suppression; agent desktop was not connected.");
        }
    }
    static class Native {
        [DllImport("wtsapi32.dll", SetLastError=true)] internal static extern bool WTSIsChildSessionsEnabled(out bool enabled);
        [DllImport("wtsapi32.dll", SetLastError=true)] internal static extern bool WTSGetChildSessionId(out uint session);
        [DllImport("wtsapi32.dll", SetLastError=true)] internal static extern bool WTSLogoffSession(IntPtr server, uint session, bool wait);
        [DllImport("wtsapi32.dll", SetLastError=true)] internal static extern bool WTSRegisterSessionNotification(IntPtr window, uint flags);
        [DllImport("wtsapi32.dll")] internal static extern bool WTSUnRegisterSessionNotification(IntPtr window);
        [DllImport("kernel32.dll", SetLastError=true)] internal static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
        [DllImport("kernel32.dll", SetLastError=true)] internal static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);
        [DllImport("advapi32.dll", SetLastError=true)] internal static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true)] internal static extern bool GetTokenInformation(IntPtr token, int kind, out int value, int size, out int returned);
        [DllImport("kernel32.dll")] internal static extern bool CloseHandle(IntPtr handle);
        [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW", SetLastError=true)] static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
        [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW", SetLastError=true)] static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);
        [DllImport("user32.dll", SetLastError=true)] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
        internal static void AllowDeliberateActivation(IntPtr window) {
            long style = GetWindowLongPtr(window, -20).ToInt64();
            Check(SetWindowLongPtr(window, -20, new IntPtr(style & ~0x08000000L)) != IntPtr.Zero);
            // Topmost, no activation, movement, resize or owner reordering.
            Check(SetWindowPos(window, new IntPtr(-1), 0, 0, 0, 0, 0x1|0x2|0x10|0x20|0x200));
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] internal static extern SafePipeHandle CreateNamedPipe(string name, uint access, uint mode, uint instances, uint output, uint input, uint timeout, ref SecurityAttributes attributes);
        [StructLayout(LayoutKind.Sequential)] internal struct SecurityAttributes { internal int length; internal IntPtr descriptor; internal bool inherit; }
        [DllImport("kernel32.dll", SetLastError=true)] internal static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)] internal static extern bool SetInformationJobObject(IntPtr job, int kind, IntPtr data, uint size);
        [DllImport("kernel32.dll", SetLastError=true)] internal static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [StructLayout(LayoutKind.Sequential)] internal struct BasicLimits {
            internal long processTime, jobTime; internal uint flags; internal UIntPtr minWorkingSet, maxWorkingSet;
            internal uint activeProcesses; internal UIntPtr affinity; internal uint priority, scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct IoCounters { internal ulong readOperations, writeOperations, otherOperations, readBytes, writeBytes, otherBytes; }
        [StructLayout(LayoutKind.Sequential)] internal struct ExtendedLimits {
            internal BasicLimits basic; internal IoCounters io;
            internal UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
        }
        internal static void Check(bool ok) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
        internal static uint ChildResult(bool success, uint id, int error) {
            // Windows 11 also returns FALSE / ERROR_NOT_SUPPORTED with the
            // documented no-child sentinel. An actual ID on failure is not valid.
            if (!success && id != UInt32.MaxValue) throw new Win32Exception(error);
            return id;
        }
        internal static uint Child() {
            uint id; bool success = WTSGetChildSessionId(out id);
            return ChildResult(success, id, Marshal.GetLastWin32Error());
        }
        internal static uint? ReportedChild(uint id) { return id == UInt32.MaxValue ? (uint?)null : id; }
        internal static bool Elevated(Process process) {
            IntPtr token; Check(OpenProcessToken(process.Handle, 8, out token));
            try { int value, returned; Check(GetTokenInformation(token, 20, out value, 4, out returned)); return value != 0; }
            finally { CloseHandle(token); }
        }
        internal static string Sid(Process process) {
            IntPtr token; Check(OpenProcessToken(process.Handle, 8, out token));
            try { using (var identity = new WindowsIdentity(token)) return identity.User.Value; }
            finally { CloseHandle(token); }
        }
        internal static IntPtr EngineJob(Process process) {
            IntPtr job = CreateJobObject(IntPtr.Zero, null); Check(job != IntPtr.Zero);
            var info = new ExtendedLimits(); info.basic.flags = 0x2000; // KILL_ON_JOB_CLOSE
            int size = Marshal.SizeOf(info); IntPtr data = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(info, data, false);
                Check(SetInformationJobObject(job, 9, data, (uint)size));
                Check(AssignProcessToJobObject(job, process.Handle)); return job;
            } catch { CloseHandle(job); throw; }
            finally { Marshal.FreeHGlobal(data); }
        }
    }

    static class Protocol {
        internal static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        internal static readonly object OutputLock = new object();
        internal static string Json(object value) { return new JavaScriptSerializer { MaxJsonLength=64*1024*1024 }.Serialize(value); }
        internal static Dictionary<string, object> Parse(string line) {
            try { return new JavaScriptSerializer { MaxJsonLength=64*1024*1024 }.Deserialize<Dictionary<string, object>>(line); }
            catch (ArgumentException) { throw new IOException("Invalid protocol JSON."); }
        }
        internal static string Message(Exception error) {
            while ((error is TargetInvocationException || error is AggregateException) && error.InnerException != null) error = error.InnerException;
            return error.Message;
        }
        internal static void Output(object value) { lock (OutputLock) Console.Out.WriteLine(Json(value)); }
        internal static void Line(string value) { lock (OutputLock) Console.Out.WriteLine(value); }
        internal static void RequireReady(StreamWriter writer, bool ready, string message) {
            if (ready) return;
            writer.WriteLine(Json(new { failure=message }));
            throw new IOException(message);
        }
        internal static string Read(TextReader reader, int limit) {
            var text = new StringBuilder(); int ch;
            while ((ch = reader.Read()) != -1) {
                if (ch == '\n') return text.ToString();
                if (ch == '\r') {
                    if (reader.Read() != '\n') throw new IOException("A protocol CR must be followed by LF.");
                    return text.ToString();
                }
                if (text.Length >= limit) throw new IOException("Protocol line limit exceeded.");
                text.Append((char)ch);
            }
            if (text.Length != 0) throw new IOException("Truncated protocol line.");
            return null;
        }
        internal static StreamWriter Writer(Stream stream, int buffer = 65536) {
            return new StreamWriter(stream, Utf8, buffer) { AutoFlush=true, NewLine="\n" };
        }
        internal static T Deadline<T>(Func<T> action, int milliseconds) {
            var task = Task.Run(action);
            if (!task.Wait(milliseconds)) throw new TimeoutException("Agent desktop handshake timed out.");
            return task.GetAwaiter().GetResult();
        }
        internal static string Token() { var data = new byte[32]; using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(data); return BitConverter.ToString(data).Replace("-", "").ToLowerInvariant(); }
        internal static bool Equal(string a, string b) {
            if (a == null || b == null || a.Length != 64 || b.Length != 64) return false;
            int diff = 0; for (int i=0; i<64; i++) diff |= a[i] ^ b[i]; return diff == 0;
        }
        internal static string Quote(string text) {
            // All arguments here are absolute generated paths, without quotes or trailing slash.
            if (text.Contains("\"") || text.EndsWith("\\")) throw new ArgumentException("Invalid path argument.");
            return "\"" + text + "\"";
        }
    }

    public sealed class Connection {
        public string token, pipe, engine, sid;
        public int hostPid, parentSession, childSession;
        public long hostStarted;
    }

    static class Tasks {
        internal static string Executable { get { return Assembly.GetExecutingAssembly().Location; } }
        internal static string Root { get { return Path.GetFullPath(Path.Combine(Path.GetDirectoryName(Executable), "../../..")); } }
        internal static string SetupCommand { get { return "& '" + Path.Combine(Root, "bin/opencu.cmd").Replace("'", "''") + "' setup agent-desktop"; } }
        internal static string Name { get {
            // An offline verification install must not replace the real install's task.
            using (var hash = SHA256.Create()) return "OpenCU-AgentDesktop-" + WindowsIdentity.GetCurrent().User.Value + "-" +
                BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(Root.ToUpperInvariant()))).Replace("-", "").Substring(0, 16);
        } }
        internal static dynamic Service() { dynamic service = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", true)); service.Connect(); return service; }
        internal static void Register() {
            dynamic service = Service(); dynamic task = service.NewTask(0);
            task.RegistrationInfo.Description = "OpenCU child-session bridge. Demand only, current user, no elevation.";
            task.Principal.UserId = WindowsIdentity.GetCurrent().User.Value;
            task.Principal.LogonType = 3; task.Principal.RunLevel = 0;
            task.Settings.Enabled = true; task.Settings.AllowDemandStart = true;
            task.Settings.DisallowStartIfOnBatteries = false; task.Settings.StopIfGoingOnBatteries = false;
            task.Settings.ExecutionTimeLimit = "PT0S"; task.Settings.MultipleInstances = 0;
            dynamic action = task.Actions.Create(0); action.Path = Executable;
            action.Arguments = "bridge \"$(Arg0)\"";
            action.WorkingDirectory = Path.GetDirectoryName(Executable);
            service.GetFolder("\\").RegisterTaskDefinition(Name, task, 6, WindowsIdentity.GetCurrent().User.Value, null, 3, null);
        }
        internal static dynamic Verified() {
            dynamic task;
            try { task = Service().GetFolder("\\").GetTask(Name); }
            catch (COMException e) {
                if (e.ErrorCode == unchecked((int)0x80070002) || e.ErrorCode == unchecked((int)0x80070003)) throw new SetupRequiredException("Agent desktop task is missing.");
                throw;
            }
            dynamic definition = task.Definition;
            string registeredUser = (string)definition.Principal.UserId;
            string registeredSid = registeredUser.StartsWith("S-1-") ? registeredUser : ((SecurityIdentifier)new NTAccount(registeredUser).Translate(typeof(SecurityIdentifier))).Value;
            if ((int)definition.Principal.LogonType != 3 || (int)definition.Principal.RunLevel != 0 ||
                registeredSid != WindowsIdentity.GetCurrent().User.Value ||
                (int)definition.Actions.Count != 1 || (int)definition.Triggers.Count != 0 ||
                !String.Equals((string)definition.Actions[1].Path, Executable, StringComparison.OrdinalIgnoreCase) ||
                (string)definition.Actions[1].Arguments != "bridge \"$(Arg0)\"") throw new SetupRequiredException("Agent desktop task differs from this installation.");
            return task;
        }
    }

    static class Pipes {
        internal static NamedPipeServerStream Server(string name, string sid) {
            var security = new RawSecurityDescriptor("D:P(A;;GA;;;" + sid + ")");
            byte[] bytes = new byte[security.BinaryLength]; security.GetBinaryForm(bytes, 0);
            IntPtr data = Marshal.AllocHGlobal(bytes.Length);
            try {
                Marshal.Copy(bytes, 0, data, bytes.Length);
                var attributes = new Native.SecurityAttributes { length=Marshal.SizeOf(typeof(Native.SecurityAttributes)), descriptor=data, inherit=false };
                // DUPLEX | FIRST_PIPE_INSTANCE | OVERLAPPED; byte mode, reject remote clients.
                var handle = Native.CreateNamedPipe("\\\\.\\pipe\\" + name, 3|0x80000|0x40000000, 8, 1, 65536, 65536, 5000, ref attributes);
                if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
                return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle);
            } finally { Marshal.FreeHGlobal(data); }
        }
        internal static void Verify(PipeStream pipe, Connection connection, bool server) {
            uint pid;
            Native.Check(server ? Native.GetNamedPipeClientProcessId(pipe.SafePipeHandle, out pid) : Native.GetNamedPipeServerProcessId(pipe.SafePipeHandle, out pid));
            using (var peer = Process.GetProcessById((int)pid)) {
                if (peer.SessionId != (server ? connection.childSession : connection.parentSession) || Native.Sid(peer) != connection.sid || Native.Elevated(peer))
                    throw new IOException("Pipe peer user, session or integrity mismatch.");
                if (!server && (peer.Id != connection.hostPid || peer.StartTime.ToUniversalTime().Ticks != connection.hostStarted))
                    throw new IOException("Pipe server identity mismatch.");
            }
        }
    }

    sealed class RdpControl : AxHost {
        internal RdpControl() : base("8B918B82-7985-4C24-89DF-C33AD2BBFBCD") { }
        internal object Ocx { get { return GetOcx(); } }
    }

    sealed class Host : Form {
        readonly RdpControl control = new RdpControl();
        readonly Panel view = new Panel { Dock=DockStyle.Fill };
        // Disable the native ancestor of every ActiveX child HWND, rather than
        // filtering managed MouseMove events that do not see native RDP input.
        readonly Panel inputSurface = new Panel { Dock=DockStyle.Fill, Enabled=false };
        readonly Label mode = new Label { Text="Starting agent desktop. Close to stop.", Dock=DockStyle.Top, Height=44, Padding=new Padding(10) };
        readonly Process parent;
        readonly Process guardian;
        readonly Mutex ownership;
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly DateTime deadline = DateTime.UtcNow.AddSeconds(45);
        readonly string ownerSid = WindowsIdentity.GetCurrent().User.Value;
        uint child = UInt32.MaxValue;
        volatile bool closing, ready;
        bool launching, loggedOn, interactionClick, opening = true;
        string directory;
        NamedPipeServerStream pipe;
        StreamWriter pipeWriter;
        MSTSCLib.IMsRdpClient9 rdp;
        Delegate disconnected, logon, loginComplete;
        internal Host(int parentPid) {
            parent = Process.GetProcessById(parentPid);
            if (parent.SessionId != Process.GetCurrentProcess().SessionId || Native.Sid(parent) != ownerSid || Native.Elevated(parent)) throw new IOException("Invalid parent process.");
            bool created;
            ownership = new Mutex(true, "Global\\OpenCU.AgentDesktop", out created);
            if (!created) { ownership.Dispose(); throw new IOException("Another OpenCU agent desktop owns the machine slot."); }
            guardian = Process.Start(new ProcessStartInfo(Tasks.Executable, "guard " + Process.GetCurrentProcess().Id) {
                UseShellExecute=false, CreateNoWindow=true, RedirectStandardInput=true,
                RedirectStandardOutput=true, RedirectStandardError=true
            });
            guardian.StandardInput.NewLine = "\n";
            Text = "OpenCU agent desktop"; ClientSize = new Size(720, 500);
            TopMost = true;
            MinimizeBox = false; MaximizeBox = false; StartPosition = FormStartPosition.Manual;
            Location = new Point(Screen.PrimaryScreen.WorkingArea.Right - Width - 24, Screen.PrimaryScreen.WorkingArea.Bottom - Height - 24);
            inputSurface.Controls.Add(control); control.Dock = DockStyle.Fill;
            view.Controls.Add(inputSurface); Controls.Add(view); Controls.Add(mode);
            view.MouseDown += delegate(object sender, MouseEventArgs e) {
                if (!ready || closing || e.Button != MouseButtons.Left) return;
                interactionClick = true; view.Capture = true;
            };
            view.MouseUp += delegate(object sender, MouseEventArgs e) {
                if (!interactionClick || e.Button != MouseButtons.Left) return;
                interactionClick = false; view.Capture = false;
                if (!ready || closing || !view.ClientRectangle.Contains(e.Location)) return;
                // Consume both halves of the mode-selection click before native
                // RDP input is enabled. Do not forward even an unmatched button-up.
                try {
                    Activate();
                    if (Native.GetForegroundWindow() == Handle) { SetInteractive(true); control.Focus(); }
                } catch (Exception failure) { Fail("AGENT_DESKTOP_UNAVAILABLE", Protocol.Message(failure)); }
            };
            Shown += delegate { if (closing) { Close(); return; } try { Connect(); } catch (Exception e) { Fail("AGENT_DESKTOP_UNAVAILABLE", "Cannot initialize the child-session control: " + Protocol.Message(e)); } };
            timer.Interval = 100; timer.Tick += delegate { Tick(); }; timer.Start();
            // stdin EOF is observed even while connection or child startup is pending.
            Task.Run((Action)ReadRequests);
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get {
                var parameters = base.CreateParams;
                if (opening) parameters.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                parameters.ExStyle |= 0x00040000; // WS_EX_APPWINDOW: visible taskbar entry
                return parameters;
            }
        }
        void SetInteractive(bool interactive) {
            inputSurface.Enabled = interactive;
            mode.Text = interactive
                ? "Interactive - mouse and keyboard go to the agent desktop. Escape stops the agent."
                : "Watch only - click the view to interact. Close this window to stop the agent.";
        }
        protected override void OnDeactivate(EventArgs e) {
            interactionClick = false; view.Capture = false;
            SetInteractive(false);
            base.OnDeactivate(e);
        }
        protected override void OnHandleCreated(EventArgs e) {
            base.OnHandleCreated(e); Native.Check(Native.WTSRegisterSessionNotification(Handle, 0));
        }
        protected override void WndProc(ref Message message) {
            if (!closing && message.Msg == 0x2B1 && message.LParam.ToInt32() == parent.SessionId &&
                ParentSessionPolicy.EndsDesktop(message.WParam.ToInt32()))
                Fail("SCREEN_LOCKED", "The parent session disconnected or logged off. Agent desktop ended; it will not resume automatically.");
            base.WndProc(ref message);
        }
        void Connect() {
            if (Native.Child() != UInt32.MaxValue) { Fail("AGENT_DESKTOP_BUSY", "This parent already has a child session. OpenCU will not attach to it."); return; }
            rdp = (MSTSCLib.IMsRdpClient9)control.Ocx;
            var extended = (MSTSCLib.IMsRdpExtendedSettings)control.Ocx;
            object value = true; extended.set_Property("ConnectToChildSession", ref value);
            var nonScriptable = (MSTSCLib.IMsRdpClientNonScriptable5)control.Ocx;
            nonScriptable.AllowPromptingForCredentials = false;
            nonScriptable.PromptForCredentials = false;
            nonScriptable.PromptForCredsOnClient = false;
            nonScriptable.AllowCredentialSaving = false;
            nonScriptable.RedirectDynamicDevices = false;
            nonScriptable.RedirectDynamicDrives = false;
            rdp.AdvancedSettings9.EnableCredSspSupport = true;
            rdp.AdvancedSettings9.EnableAutoReconnect = false;
            rdp.AdvancedSettings9.RedirectClipboard = false;
            rdp.AdvancedSettings9.RedirectDrives = false;
            rdp.AdvancedSettings9.RedirectPrinters = false;
            rdp.AdvancedSettings9.RedirectPorts = false;
            rdp.AdvancedSettings9.RedirectSmartCards = false;
            rdp.AdvancedSettings9.AudioRedirectionMode = 2;
            rdp.AdvancedSettings9.AudioCaptureRedirectionMode = false;
            rdp.AdvancedSettings9.SmartSizing = true;
            rdp.SecuredSettings2.KeyboardHookMode = 0;
            rdp.Server = "localhost"; rdp.DesktopWidth = 1280; rdp.DesktopHeight = 900;
            Guid events = new Guid("336d5562-efa8-482e-8cb3-c5c0fc7a7db6");
            loginComplete = new Action(delegate { loggedOn = true; });
            disconnected = new Action<int>(delegate(int reason) {
                if (closing) return;
                if (!ready && (reason == 2055 || reason == 8455 || reason == 3847)) SignInRequired();
                else Fail("AGENT_DESKTOP_LOST", "Child session disconnected (" + reason + "). No reconnect was attempted.");
            });
            logon = new Action<int>(delegate(int code) {
                if (code == 0 || code == 1 || code == 2 || code == unchecked((int)0xC000006D) || code == unchecked((int)0xC0000224)) SignInRequired();
                else if (code != -2) Fail("AGENT_DESKTOP_UNAVAILABLE", "Windows refused child sign-in (" + code + ").");
            });
            ComEventsHelper.Combine(control.Ocx, events, 3, loginComplete);
            ComEventsHelper.Combine(control.Ocx, events, 4, disconnected);
            ComEventsHelper.Combine(control.Ocx, events, 22, logon);
            RdpPointerPolicy.Configure(
                delegate(string name, bool enabled) { object setting = enabled; extended.set_Property(name, ref setting); },
                name => extended.get_Property(name));
            rdp.Connect();
        }
        void SignInRequired() { Fail("AGENT_DESKTOP_SIGN_IN_REQUIRED", "Windows cannot sign in to the child session automatically. Sign out and back in once after setup. Smart-card-only sign-in is unsupported. OpenCU never requests a password."); }
        void Tick() {
            if (closing) return;
            try {
                if (parent.HasExited) { CloseOwned(); return; }
                if (WindowState == FormWindowState.Minimized) { Fail("USER_STOPPED", "The agent desktop was minimized; input stopped. Do not reconnect automatically."); return; }
                if (!ready && DateTime.UtcNow > deadline) { Fail("AGENT_DESKTOP_UNAVAILABLE", "Child startup timed out without an authenticated engine. No input was sent."); return; }
                if (child == UInt32.MaxValue && rdp != null) {
                    uint id = Native.Child();
                    if (id != UInt32.MaxValue && id != Process.GetCurrentProcess().SessionId && id != 0) {
                        child = id;
                        guardian.StandardInput.WriteLine(child); guardian.StandardInput.Flush();
                    }
                }
                if (!launching && loggedOn && child != UInt32.MaxValue) {
                    launching = true; BeginBridge();
                }
                if (ready && Native.Child() != child) Fail("AGENT_DESKTOP_LOST", "Child session ended. No reconnect was attempted.");
            } catch (Exception e) { Fail("AGENT_DESKTOP_UNAVAILABLE", "Child-session lifecycle failed: " + Protocol.Message(e)); }
        }
        void BeginBridge() {
            var own = Process.GetCurrentProcess();
            string root = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(Tasks.Executable), "../../.."));
            var connection = new Connection { token=Protocol.Token(), pipe="opencu-" + Protocol.Token(), sid=ownerSid,
                hostPid=own.Id, hostStarted=own.StartTime.ToUniversalTime().Ticks, parentSession=own.SessionId,
                childSession=(int)child, engine=Path.Combine(root, ".build/win/opencu-engine.exe") };
            directory = Path.Combine(Path.GetTempPath(), "opencu-agent-" + Guid.NewGuid().ToString("N"));
            var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
            var sid = new SecurityIdentifier(ownerSid); security.SetOwner(sid);
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.CreateDirectory(directory, security);
            string descriptor = Path.Combine(directory, "connection.json");
            File.WriteAllText(descriptor, Protocol.Json(connection), Protocol.Utf8);
            pipe = Pipes.Server(connection.pipe, connection.sid);
            // Same user, explicit child session. No automatic logon task or SYSTEM action.
            Tasks.Verified().RunEx(new string[] { descriptor }, 5, connection.childSession, null);
            Task.Run(delegate {
                try {
                    var waiting = pipe.BeginWaitForConnection(null, null);
                    if (!waiting.AsyncWaitHandle.WaitOne(20000)) throw new TimeoutException();
                    pipe.EndWaitForConnection(waiting);
                    Pipes.Verify(pipe, connection, true);
                    var reader = new StreamReader(pipe, Protocol.Utf8, false, 65536, true);
                    var writer = Protocol.Writer(pipe);
                    string token = Protocol.Deadline(() => Protocol.Read(reader, 64), 5000);
                    if (!Protocol.Equal(token, connection.token)) throw new IOException("Authentication failed.");
                    writer.WriteLine(connection.token);
                    string hello = Protocol.Deadline(() => Protocol.Read(reader, 16384), 15000);
                    var result = Protocol.Parse(hello);
                    object failure;
                    if (result.TryGetValue("failure", out failure)) throw new IOException(Convert.ToString(failure));
                    if (Convert.ToInt32(result["sessionId"]) != connection.childSession || !(bool)result["desktopAccessible"]) throw new IOException("Child engine is not ready.");
                    File.Delete(descriptor); Directory.Delete(directory); directory = null;
                    pipeWriter = writer;
                    Invoke((Action)delegate {
                        if (closing) throw new IOException("Host closed during startup.");
                        Native.AllowDeliberateActivation(Handle);
                        opening = false; ready = true; SetInteractive(false);
                    });
                    Protocol.Output(new { @event="ready", sessionId=connection.childSession, hostPid=own.Id });
                    string line;
                    while ((line = Protocol.Read(reader, 64*1024*1024)) != null) Protocol.Line(line);
                    if (!closing) Fail("AGENT_DESKTOP_LOST", "Child engine transport ended. No reconnect was attempted.");
                } catch (Exception e) { if (!closing) Fail("AGENT_DESKTOP_AUTH_FAILED", "Child bridge was not authenticated and ready: " + Protocol.Message(e)); }
            });
        }
        void ReadRequests() {
            try {
                string line;
                while ((line = Protocol.Read(Console.In, 8*1024*1024)) != null) {
                    if (!ready || closing) throw new IOException("Child engine is not ready.");
                    pipeWriter.WriteLine(line);
                }
                CloseOwned();
            } catch (Exception failure) { if (!closing) Fail("AGENT_DESKTOP_LOST", "Parent transport closed unexpectedly: " + Protocol.Message(failure)); }
        }
        void Fail(string code, string text) {
            if (closing) return;
            Protocol.Output(new { @event="failure", code=code, message=text });
            CloseOwned();
        }
        void CloseOwned() {
            if (!IsHandleCreated) { closing = true; return; }
            if (InvokeRequired) { BeginInvoke((Action)CloseOwned); return; }
            if (closing) return;
            closing = true; Close();
        }
        protected override void OnFormClosing(FormClosingEventArgs e) {
            if (!closing) Protocol.Output(new { @event="failure", code="USER_STOPPED", message="The person closed the agent desktop. Do not reconnect without explicit permission." });
            closing = true; timer.Stop();
            if (pipe != null) pipe.Dispose();
            // Only log off a session this connection created, and recheck the
            // current parent relationship so a reused numeric ID is not authority.
            bool loggedOff = false;
            try {
                if (child != UInt32.MaxValue && Native.Child() == child) Native.Check(Native.WTSLogoffSession(IntPtr.Zero, child, true));
                loggedOff = child == UInt32.MaxValue || Native.Child() != child;
            }
            catch (Exception failure) { Protocol.Output(new { @event="failure", code="AGENT_DESKTOP_CLEANUP_FAILED", message="Could not confirm child logoff: " + Protocol.Message(failure) + " Inspect Windows sessions before continuing." }); }
            try { if (rdp != null && rdp.Connected != 0) rdp.Disconnect(); } catch { }
            try { if (directory != null) Directory.Delete(directory, true); } catch { }
            guardian.StandardInput.Close(); guardian.Dispose();
            Native.WTSUnRegisterSessionNotification(Handle); parent.Dispose();
            ownership.ReleaseMutex(); ownership.Dispose();
            Protocol.Output(new { @event="closed", loggedOff=loggedOff });
            base.OnFormClosing(e);
        }
    }

    static class Program {
        [STAThread] static int Main(string[] args) {
            // GUI-subsystem processes may have pipes but no console code page.
            // Explicit streams also work for task modes with no standard handles.
            Console.SetIn(new StreamReader(Console.OpenStandardInput(), Protocol.Utf8));
            Console.SetOut(Protocol.Writer(Console.OpenStandardOutput()));
            try {
                if (Native.Elevated(Process.GetCurrentProcess())) throw new IOException("Agent desktop requires a non-elevated user process.");
                if (args.Length == 1 && args[0] == "register") { Tasks.Register(); Protocol.Output(new { ok=true, taskName=Tasks.Name }); return 0; }
                if (args.Length == 1 && args[0] == "self-test") { SelfTest(); return 0; }
                if (args.Length == 1 && args[0] == "probe") {
                    bool enabled; Native.Check(Native.WTSIsChildSessionsEnabled(out enabled));
                    if (!enabled) throw new SetupRequiredException("Windows child sessions are disabled; one-time setup is required.");
                    Tasks.Verified();
                    Protocol.Output(new { available=enabled, taskName=Tasks.Name,
                        childSessionsEnabled=enabled, existingChildSession=Native.ReportedChild(Native.Child()) }); return 0;
                }
                if (args.Length == 2 && args[0] == "bridge") { Bridge(args[1]); return 0; }
                if (args.Length == 2 && args[0] == "guard") { Guard(Int32.Parse(args[1])); return 0; }
                if (args.Length == 2 && args[0] == "host") {
                    bool enabled; Native.Check(Native.WTSIsChildSessionsEnabled(out enabled));
                    if (!enabled) throw new SetupRequiredException("Windows child sessions are disabled; one-time setup is required.");
                    Tasks.Verified(); Application.EnableVisualStyles(); Application.Run(new Host(Int32.Parse(args[1]))); return 0;
                }
                throw new ArgumentException("Unknown helper mode.");
            } catch (Exception e) {
                // Do not log descriptors, command lines, app input or pipe tokens.
                Protocol.Output(new { @event="failure", code="AGENT_DESKTOP_UNAVAILABLE", setupRequired=e is SetupRequiredException,
                    message=Protocol.Message(e) }); return 1;
            }
        }
        static void Guard(int hostPid) {
            using (var host = Process.GetProcessById(hostPid)) {
                if (host.SessionId != Process.GetCurrentProcess().SessionId || Native.Sid(host) != WindowsIdentity.GetCurrent().User.Value) throw new IOException("Invalid owner.");
                string line = Protocol.Read(Console.In, 12);
                uint child;
                if (line == null || !UInt32.TryParse(line, out child) || child == 0 || child == UInt32.MaxValue || Native.Child() != child) return;
                // The inherited pipe closes when the host dies, including forced termination.
                Protocol.Read(Console.In, 1);
                if (Native.Child() == child) Native.Check(Native.WTSLogoffSession(IntPtr.Zero, child, true));
            }
        }
        static void SelfTest() {
            // Real Windows named pipes, no window, task, child session or input.
            bool pointerSetting = false;
            RdpPointerPolicy.Configure((name, value) => { if (name != RdpPointerPolicy.Property) throw new Exception("Wrong RDP property."); pointerSetting=value; }, name => pointerSetting);
            foreach (object invalid in new object[] { false, null, "true", 1 }) {
                bool rejected = false;
                try { RdpPointerPolicy.Configure((name, value) => {}, name => invalid); } catch (IOException) { rejected = true; }
                if (!rejected) throw new Exception("Unconfirmed pointer suppression was accepted.");
            }
            bool unsupported = false;
            try { RdpPointerPolicy.Configure((name, value) => { throw new COMException("Unsupported property."); }, name => true); }
            catch (COMException) { unsupported = true; }
            if (!unsupported || Native.ReportedChild(UInt32.MaxValue) != null || Native.ReportedChild(7) != 7)
                throw new Exception("Pointer property refusal or absent-child reporting failed.");
            foreach (int reason in new int[] { 2, 4, 6 }) {
                if (!ParentSessionPolicy.EndsDesktop(reason)) throw new Exception("Disconnect/logoff must end the agent desktop.");
            }
            foreach (int reason in new int[] { 1, 3, 5, 7, 8, 9, 10, 11 }) {
                if (ParentSessionPolicy.EndsDesktop(reason)) throw new Exception("Lock/unlock or another notification must not end the agent desktop.");
            }
            string token = Protocol.Token();
            if (Native.ChildResult(false, UInt32.MaxValue, 50) != UInt32.MaxValue ||
                Native.ChildResult(true, UInt32.MaxValue, 0) != UInt32.MaxValue ||
                Native.ChildResult(true, 7, 0) != 7) throw new Exception("Child-session result mapping failed.");
            bool refused = false;
            try { Native.ChildResult(false, 7, 5); } catch (Win32Exception e) { refused = e.NativeErrorCode == 5; }
            if (!refused) throw new Exception("Failed session query was accepted.");
            foreach (string ending in new string[] { "\n", "\r\n" }) {
                var lines = new StringReader(token + ending + "next" + ending);
                if (Protocol.Read(lines, 64) != token || Protocol.Read(lines, 64) != "next" || Protocol.Read(lines, 64) != null)
                    throw new Exception("Protocol line endings lost or changed data.");
            }
            foreach (string invalid in new string[] { token + "x\r\n", token + "\r\r\n", token + "\r", "a\rb\n", token }) {
                refused = false;
                try { Protocol.Read(new StringReader(invalid), 64); } catch (IOException) { refused = true; }
                if (!refused) throw new Exception("Overlong or malformed protocol line was accepted.");
            }
            using (var bytes = new MemoryStream()) {
                Protocol.Writer(bytes).WriteLine(token);
                if (Protocol.Utf8.GetString(bytes.ToArray()) != token + "\n") throw new Exception("Writer is not LF-only.");
            }
            if (!Protocol.Equal(token, token) || Protocol.Equal(token, new string('x', 64)) || Protocol.Equal(token, token + "x") || Protocol.Equal(token, null)) throw new Exception("Token comparison failed.");
            try { Protocol.Read(new StringReader(new string('x', 65) + "\n"), 64); throw new Exception("Handshake size was not bounded."); } catch (IOException) { }
            var own = Process.GetCurrentProcess();
            var connection = new Connection { token=token, pipe="opencu-test-" + Protocol.Token(), sid=WindowsIdentity.GetCurrent().User.Value,
                hostPid=own.Id, hostStarted=own.StartTime.ToUniversalTime().Ticks, parentSession=own.SessionId, childSession=own.SessionId };
            using (var server = Pipes.Server(connection.pipe, connection.sid)) {
                // FIRST_PIPE_INSTANCE must reject a second server using this name.
                bool rejected = false;
                try { using (var duplicate = Pipes.Server(connection.pipe, connection.sid)) { } } catch (Win32Exception) { rejected = true; }
                if (!rejected) throw new Exception("Pipe name hijack not rejected.");
                var waiting = server.BeginWaitForConnection(null, null);
                using (var client = new NamedPipeClientStream(".", connection.pipe, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification)) {
                    client.Connect(3000); server.EndWaitForConnection(waiting);
                    Pipes.Verify(server, connection, true); Pipes.Verify(client, connection, false);
                    connection.childSession++;
                    rejected = false;
                    try { Pipes.Verify(server, connection, true); } catch (IOException) { rejected = true; }
                    if (!rejected) throw new Exception("Wrong session accepted."); connection.childSession--;
                    connection.hostStarted++;
                    rejected = false;
                    try { Pipes.Verify(client, connection, false); } catch (IOException) { rejected = true; }
                    if (!rejected) throw new Exception("Reused PID accepted."); connection.hostStarted--;
                    connection.sid = "S-1-5-18";
                    rejected = false;
                    try { Pipes.Verify(server, connection, true); } catch (IOException) { rejected = true; }
                    if (!rejected) throw new Exception("Wrong SID accepted.");
                    var writer = Protocol.Writer(client, 1024);
                    var reader = new StreamReader(server, Protocol.Utf8, false, 1024, true);
                    writer.WriteLine(new string('x', 64));
                    if (Protocol.Equal(token, Protocol.Deadline(() => Protocol.Read(reader, 64), 3000))) throw new Exception("Wrong wire token accepted.");
                    writer.WriteLine(token);
                    if (!Protocol.Equal(token, Protocol.Deadline(() => Protocol.Read(reader, 64), 3000))) throw new Exception("Valid wire token refused.");
                }
            }
            Protocol.Output(new { ok=true, checks=new string[] { "required-pointer-suppression", "no-child-null", "parent-session-policy", "no-child-result", "lf-crlf-bound", "lf-writer", "token-length-and-value", "handshake-bound", "first-pipe-instance", "peer-pid-lifetime", "peer-session", "peer-sid", "wire-token" } });
        }
        static void Bridge(string descriptor) {
            if (new FileInfo(descriptor).Length > 16384) throw new IOException("Descriptor too large.");
            Connection connection;
            try { connection = new JavaScriptSerializer().Deserialize<Connection>(File.ReadAllText(descriptor, Protocol.Utf8)); }
            catch (ArgumentException) { throw new IOException("Invalid connection descriptor JSON."); }
            var own = Process.GetCurrentProcess();
            if (own.SessionId == 0 || own.SessionId == connection.parentSession || own.SessionId != connection.childSession || WindowsIdentity.GetCurrent().User.Value != connection.sid)
                throw new IOException("Bridge started in the wrong session.");
            using (var pipe = new NamedPipeClientStream(".", connection.pipe, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification)) {
                pipe.Connect(10000); Pipes.Verify(pipe, connection, false);
                var reader = new StreamReader(pipe, Protocol.Utf8, false, 65536, true);
                var writer = Protocol.Writer(pipe);
                writer.WriteLine(connection.token);
                if (!Protocol.Equal(connection.token, Protocol.Deadline(() => Protocol.Read(reader, 64), 5000))) throw new IOException("Host authentication failed.");
                var start = new ProcessStartInfo(connection.engine, "serve --agent-parent-session " + connection.parentSession) { UseShellExecute=false, CreateNoWindow=true, RedirectStandardInput=true, RedirectStandardOutput=true, RedirectStandardError=true, StandardOutputEncoding=Protocol.Utf8, StandardErrorEncoding=Protocol.Utf8 };
                using (var engine = Process.Start(start)) {
                    IntPtr job = IntPtr.Zero;
                    try {
                        job = Native.EngineJob(engine);
                        if (engine.SessionId != connection.childSession || Native.Elevated(engine)) throw new IOException("Engine session/integrity mismatch.");
                        engine.ErrorDataReceived += delegate { }; engine.BeginErrorReadLine();
                        var input = Protocol.Writer(engine.StandardInput.BaseStream);
                        input.WriteLine("{\"id\":0,\"method\":\"doctor\",\"params\":{}}");
                        var doctor = Protocol.Parse(Protocol.Deadline(() => Protocol.Read(engine.StandardOutput, 16384), 10000));
                        var result = (Dictionary<string, object>)doctor["result"];
                        Protocol.RequireReady(writer, (bool)result["desktopAccessible"], "Child desktop inaccessible.");
                        Protocol.RequireReady(writer, result.ContainsKey("agentParentSession") && Convert.ToInt32(result["agentParentSession"]) == connection.parentSession,
                            "Child engine parent-session guard was not configured.");
                        Protocol.RequireReady(writer, result.ContainsKey("agentParentLocked") && result["agentParentLocked"] is bool,
                            "Child engine cannot query the parent session lock state.");
                        writer.WriteLine(Protocol.Json(new { sessionId=engine.SessionId, desktopAccessible=true }));
                        var inbound = Task.Run(delegate {
                            string request;
                            while ((request = Protocol.Read(reader, 8*1024*1024)) != null) input.WriteLine(request);
                            input.Close();
                        });
                        var outbound = Task.Run(delegate {
                            string response;
                            while ((response = Protocol.Read(engine.StandardOutput, 64*1024*1024)) != null) writer.WriteLine(response);
                        });
                        // Either endpoint ending ends ownership. Never start another engine.
                        Task.WaitAny(inbound, outbound);
                        try { input.Close(); } catch { }
                        if (!engine.WaitForExit(35000)) engine.Kill();
                    } finally {
                        if (job != IntPtr.Zero) Native.CloseHandle(job);
                        else { try { engine.Kill(); } catch { } }
                    }
                }
            }
        }
    }
}
