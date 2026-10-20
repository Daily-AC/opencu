use super::apps::{Handle, Window};
use opencu_engine::{foreground, Error, Result};
use std::{
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering::SeqCst},
        mpsc, OnceLock,
    },
    thread,
    time::{Duration, Instant},
};
use windows::{
    core::*,
    Win32::{
        Foundation::*,
        Security::*,
        System::{
            LibraryLoader::*, RemoteDesktop::*, StationsAndDesktops::*, SystemInformation::*,
            Threading::*,
        },
        UI::{
            Input::{KeyboardAndMouse::*, *},
            WindowsAndMessaging::*,
        },
    },
};
static STOPPED: AtomicBool = AtomicBool::new(false);
static NEEDS_OBSERVATION: AtomicBool = AtomicBool::new(false);
static ACTING: AtomicBool = AtomicBool::new(false);
static EVENTS: AtomicU64 = AtomicU64::new(0);
static FAILED: AtomicBool = AtomicBool::new(false);
static HEARTBEAT: AtomicU64 = AtomicU64::new(0);
static QUIET_UNTIL: AtomicU64 = AtomicU64::new(0);
static AGENT_PARENT_SESSION: OnceLock<u32> = OnceLock::new();
pub use foreground::INPUT_TAG;
pub fn agent_parent_session() -> Option<u32> {
    AGENT_PARENT_SESSION.get().copied()
}
pub unsafe fn configure_agent_parent(session: u32) -> Result<()> {
    let mut own = 0;
    ProcessIdToSessionId(GetCurrentProcessId(), &mut own)?;
    if session == 0 || session == u32::MAX || session == own || own == 0 {
        return Err(Error::new("INVALID_ARGUMENT", "Agent parent must be a different interactive session"));
    }
    AGENT_PARENT_SESSION.set(session)
        .map_err(|_| Error::new("INVALID_ARGUMENT", "Agent parent session is already configured"))
}
unsafe fn parent_input_allowed(before_input: bool) -> Result<()> {
    let parent = agent_parent_session();
    let locked = parent.and_then(|id| super::session_locked(id));
    opencu_engine::agent_parent_input_policy(parent.is_some(), locked, before_input)
}
pub unsafe fn parent_input_error(error: Error) -> Error {
    // A lock can happen between a guard and the OS/provider call. Do not replay
    // it or claim that the already-attempted action sent no input.
    if agent_parent_session().is_none() { return error; }
    if STOPPED.load(SeqCst) && matches!(error.code, "SCREEN_LOCKED" | "PERSON_ACTIVE" | "ACTIVATION_FAILED" | "WINDOW_FOCUS_CHANGED") {
        return user_stopped();
    }
    if matches!(error.code, "PERSON_ACTIVE" | "ACTIVATION_FAILED" | "WINDOW_FOCUS_CHANGED") {
        if let Err(locked) = parent_input_allowed(false) { return locked; }
    }
    error
}
pub fn person() -> Error {
    Error::new(
        "PERSON_ACTIVE",
        "Someone is using the computer. Remaining input was stopped; nothing will be retried.",
    )
}
fn monitor_error() -> Error {
    Error::new(
        "SAFETY_MONITOR_UNAVAILABLE",
        "The desktop safety monitor is not responding; no further input was sent",
    )
}
pub unsafe fn desktop() -> Result<()> {
    let locked = || {
        Error::new("SCREEN_LOCKED","The screen is locked or the interactive desktop is unavailable. Unlock it before using OpenCU.")
    };
    let mut session = 0;
    ProcessIdToSessionId(GetCurrentProcessId(), &mut session).map_err(|_| locked())?;
    if session == 0 {
        return Err(locked());
    }
    let mut buffer = PWSTR::null();
    let mut len = 0;
    WTSQuerySessionInformationW(None, session, WTSSessionInfoEx, &mut buffer, &mut len)
        .map_err(|_| locked())?;
    let valid = if len as usize >= std::mem::size_of::<WTSINFOEXW>() && !buffer.is_null() {
        let info = &*(buffer.0 as *const WTSINFOEXW);
        info.Level == 1
            && info.Data.WTSInfoExLevel1.SessionId == session
            && info.Data.WTSInfoExLevel1.SessionState == WTSActive
            && info.Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_UNLOCK as i32
    } else {
        false
    };
    WTSFreeMemory(buffer.0 as _);
    if !valid {
        return Err(locked());
    }
    let input = OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_READOBJECTS)
        .map_err(|_| locked())?;
    let name = |handle: HANDLE| -> Result<String> {
        let mut buf = [0u16; 256];
        GetUserObjectInformationW(handle, UOI_NAME, Some(buf.as_mut_ptr() as _), 512, None)
            .map_err(|_| locked())?;
        Ok(super::from_wide(&buf))
    };
    let input_name = name(HANDLE(input.0));
    let _ = CloseDesktop(input);
    let current = GetThreadDesktop(GetCurrentThreadId()).map_err(|_| locked())?;
    if !input_name?.eq_ignore_ascii_case("Default")
        || !name(HANDLE(current.0))?.eq_ignore_ascii_case("Default")
    {
        return Err(locked());
    }
    Ok(())
}
unsafe fn integrity(pid: u32) -> Result<u32> {
    let process = Handle(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)?);
    let mut token = HANDLE::default();
    OpenProcessToken(process.0, TOKEN_QUERY, &mut token)?;
    let token = Handle(token);
    let mut needed = 0;
    let _ = GetTokenInformation(token.0, TokenIntegrityLevel, None, 0, &mut needed);
    let mut data = vec![0usize; (needed as usize).div_ceil(std::mem::size_of::<usize>())];
    GetTokenInformation(
        token.0,
        TokenIntegrityLevel,
        Some(data.as_mut_ptr() as _),
        needed,
        &mut needed,
    )?;
    let sid = (*(data.as_ptr() as *const TOKEN_MANDATORY_LABEL)).Label.Sid;
    let count = *GetSidSubAuthorityCount(sid);
    if count == 0 {
        return Err(Error::new(
            "ELEVATED_TARGET",
            "Cannot inspect target integrity",
        ));
    }
    Ok(*GetSidSubAuthority(sid, count as u32 - 1))
}
pub unsafe fn target(w: &Window) -> Result<()> {
    let err = || {
        Error::new("ELEVATED_TARGET","Target privilege cannot be driven by this engine; use a non-elevated app in the signed-in user's session")
    };
    if integrity(w.pid).map_err(|_| err())? > integrity(GetCurrentProcessId()).map_err(|_| err())? {
        return Err(err());
    }
    w.validate()?;
    Ok(())
}
unsafe extern "system" fn escape_hook(code: i32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if code >= 0 {
        let event = &*(lp.0 as *const KBDLLHOOKSTRUCT);
        if opencu_engine::physical_escape(event.vkCode, event.flags.0, wp.0 as u32) {
            STOPPED.store(true, SeqCst);
        }
    }
    CallNextHookEx(None, code, wp, lp)
}
fn user_stopped() -> Error {
    Error::new("USER_STOPPED", "A person stopped OpenCU with Escape. All later input and activation on this connection are disabled; do not reconnect automatically.")
}
unsafe extern "system" fn proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_INPUT {
        let mut header = RAWINPUTHEADER::default();
        let mut size = std::mem::size_of::<RAWINPUTHEADER>() as u32;
        let n = GetRawInputData(
            HRAWINPUT(lp.0 as _),
            RID_HEADER,
            Some(&mut header as *mut _ as _),
            &mut size,
            size,
        );
        if n != std::mem::size_of::<RAWINPUTHEADER>() as u32 {
            FAILED.store(true, SeqCst);
        } else if header.dwType <= 1 && GetMessageExtraInfo().0 as usize != INPUT_TAG {
            let mut raw = RAWINPUT::default();
            let mut size = std::mem::size_of::<RAWINPUT>() as u32;
            let copied = GetRawInputData(
                HRAWINPUT(lp.0 as _),
                RID_INPUT,
                Some(&mut raw as *mut _ as _),
                &mut size,
                std::mem::size_of::<RAWINPUTHEADER>() as u32,
            );
            let payload_size = if header.dwType == RIM_TYPEKEYBOARD.0 {
                std::mem::size_of::<RAWKEYBOARD>()
            } else {
                std::mem::size_of::<RAWMOUSE>()
            };
            if copied == u32::MAX
                || (copied as usize) < std::mem::size_of::<RAWINPUTHEADER>() + payload_size
            {
                FAILED.store(true, SeqCst);
            } else {
                let extra = if header.dwType == RIM_TYPEKEYBOARD.0 {
                    raw.data.keyboard.ExtraInformation
                } else {
                    raw.data.mouse.ulExtraInformation
                };
                // Exempt tagged keyboard AND mouse packets before updating any
                // activity state, including the physical Escape fallback.
                if !foreground::engine_input(GetMessageExtraInfo().0 as usize, extra as usize) {
                    if header.dwType == RIM_TYPEKEYBOARD.0
                        && raw.data.keyboard.VKey == 0x1b
                        && raw.data.keyboard.Flags & RI_KEY_BREAK as u16 == 0
                    {
                        STOPPED.store(true, SeqCst);
                    }
                    QUIET_UNTIL.store(GetTickCount64() + foreground::HUMAN_IDLE_MS, SeqCst);
                    EVENTS.fetch_add(1, SeqCst);
                    if ACTING.load(SeqCst) {
                        NEEDS_OBSERVATION.store(true, SeqCst);
                    }
                }
            }
        }
    }
    DefWindowProcW(hwnd, msg, wp, lp)
}
enum Command {
    Fence(mpsc::Sender<()>),
    Stop,
}
pub struct Monitor {
    tx: mpsc::Sender<Command>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Monitor {
    pub unsafe fn new() -> Result<Self> {
        let (tx, rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::channel();
        let thread = thread::spawn(move || unsafe {
            let result = (|| -> Result<()> {
                desktop()?;
                let module = GetModuleHandleW(None)?;
                let keyboard =
                    SetWindowsHookExW(WH_KEYBOARD_LL, Some(escape_hook), Some(module.into()), 0)?;
                let class = w!("OpenCUInputMonitor");
                let wc = WNDCLASSW {
                    lpfnWndProc: Some(proc),
                    hInstance: module.into(),
                    lpszClassName: class,
                    ..Default::default()
                };
                if RegisterClassW(&wc) == 0 {
                    return Err(monitor_error());
                }
                let hwnd = CreateWindowExW(
                    WINDOW_EX_STYLE(0),
                    class,
                    w!(""),
                    WINDOW_STYLE(0),
                    0,
                    0,
                    0,
                    0,
                    Some(HWND_MESSAGE),
                    None,
                    Some(module.into()),
                    None,
                )?;
                let devices = [
                    RAWINPUTDEVICE {
                        usUsagePage: 1,
                        usUsage: 2,
                        dwFlags: RIDEV_INPUTSINK,
                        hwndTarget: hwnd,
                    },
                    RAWINPUTDEVICE {
                        usUsagePage: 1,
                        usUsage: 6,
                        dwFlags: RIDEV_INPUTSINK,
                        hwndTarget: hwnd,
                    },
                ];
                RegisterRawInputDevices(&devices, std::mem::size_of::<RAWINPUTDEVICE>() as u32)?;
                // Register first so events during initialization are queued. Seed
                // before reporting ready: no input from this connection exists yet.
                // Do not poll LASTINPUTINFO later: SendInput also updates it.
                let mut last = LASTINPUTINFO {
                    cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
                    ..Default::default()
                };
                if !GetLastInputInfo(&mut last).as_bool() {
                    return Err(monitor_error());
                }
                let now = GetTickCount64();
                QUIET_UNTIL.store(foreground::initial_quiet_until(now, last.dwTime), SeqCst);
                HEARTBEAT.store(now, SeqCst);
                let _ = ready_tx.send(Ok(()));
                let pump = || -> bool {
                    for _ in 0..256 {
                        let mut msg = MSG::default();
                        if !PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                            return true;
                        }
                        if msg.message == WM_QUIT {
                            return false;
                        }
                        DispatchMessageW(&msg);
                    }
                    true
                };
                loop {
                    if !pump() {
                        FAILED.store(true, SeqCst);
                        break;
                    }
                    HEARTBEAT.store(GetTickCount64(), SeqCst);
                    match rx.recv_timeout(Duration::from_millis(5)) {
                        Ok(Command::Fence(reply)) => {
                            if !pump() {
                                FAILED.store(true, SeqCst);
                            }
                            HEARTBEAT.store(GetTickCount64(), SeqCst);
                            let _ = reply.send(());
                        }
                        Ok(Command::Stop) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        Err(mpsc::RecvTimeoutError::Timeout) => {}
                    }
                }
                let remove = devices.map(|d| RAWINPUTDEVICE {
                    dwFlags: RIDEV_REMOVE,
                    hwndTarget: HWND::default(),
                    ..d
                });
                let _ =
                    RegisterRawInputDevices(&remove, std::mem::size_of::<RAWINPUTDEVICE>() as u32);
                let _ = UnhookWindowsHookEx(keyboard);
                let _ = DestroyWindow(hwnd);
                let _ = UnregisterClassW(class, Some(module.into()));
                Ok(())
            })();
            if let Err(e) = result {
                FAILED.store(true, SeqCst);
                let _ = ready_tx.send(Err(e));
            }
        });
        ready_rx
            .recv_timeout(Duration::from_secs(3))
            .map_err(|_| monitor_error())??;
        Ok(Self {
            tx,
            thread: Some(thread),
        })
    }
    pub fn fence(&self) -> Result<()> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .send(Command::Fence(tx))
            .map_err(|_| monitor_error())?;
        rx.recv_timeout(Duration::from_millis(500))
            .map_err(|_| monitor_error())?;
        if FAILED.load(SeqCst) {
            return Err(monitor_error());
        }
        Ok(())
    }
    pub fn stopped(&self) -> bool {
        STOPPED.load(SeqCst)
    }
    pub fn observed(&self) {
        NEEDS_OBSERVATION.store(false, SeqCst);
    }
    pub unsafe fn begin<'a>(
        &'a self,
        indicator: &'a super::indicator::Indicator,
    ) -> Result<Guard<'a>> {
        if self.stopped() {
            indicator.hide();
            return Err(user_stopped());
        }
        parent_input_allowed(true)?;
        if NEEDS_OBSERVATION.load(SeqCst) {
            return Err(Error::new(
                "OBSERVATION_REQUIRED",
                "Human activity interrupted input; read the app state before new input",
            ));
        }
        let epoch = EVENTS.load(SeqCst);
        self.fence()?;
        if EVENTS.load(SeqCst) != epoch {
            return Err(person());
        }
        for key in 1..256 {
            if GetAsyncKeyState(key) < 0 {
                return Err(person());
            }
        }
        let visible = indicator.begin()?;
        ACTING.store(true, SeqCst);
        Ok(Guard {
            visible: Some(visible),
            indicator,
            monitor: self,
            epoch,
            target: None,
        })
    }
}
impl Drop for Monitor {
    fn drop(&mut self) {
        let _ = self.tx.send(Command::Stop);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
pub struct Guard<'a> {
    visible: Option<super::indicator::Active<'a>>,
    indicator: &'a super::indicator::Indicator,
    monitor: &'a Monitor,
    epoch: u64,
    target: Option<Window>,
}
impl Guard<'_> {
    pub unsafe fn check(&self) -> Result<()> {
        // Drain queued device events before every new input, independent of UIA
        // provider or capture latency on the engine thread.
        self.monitor.fence()?;
        if STOPPED.load(SeqCst) {
            self.indicator.hide();
            return Err(user_stopped());
        }
        parent_input_allowed(false)?;
        if EVENTS.load(SeqCst) != self.epoch {
            return Err(person());
        }
        if FAILED.load(SeqCst) || GetTickCount64().saturating_sub(HEARTBEAT.load(SeqCst)) > 500 {
            return Err(monitor_error());
        }
        self.indicator.check()?;
        desktop()?;
        if let Some(w) = &self.target {
            w.validate()?;
            if !w.contains(GetForegroundWindow()) {
                return Err(Error::new(
                    "WINDOW_FOCUS_CHANGED",
                    "Foreground window changed; remaining input stopped",
                ));
            }
        }
        if EVENTS.load(SeqCst) != self.epoch {
            return Err(person());
        }
        Ok(())
    }
    pub unsafe fn activate(&mut self, w: &Window) -> Result<()> {
        self.check()?;
        target(w)?;
        let plan = foreground::activation_plan(
            w.contains(GetForegroundWindow()),
            IsIconic(w.hwnd).as_bool(),
            GetTickCount64(),
            QUIET_UNTIL.load(SeqCst),
        )?;
        // A minimized foreground window still needs restoration. Only acquiring
        // another family's foreground requires idle time; decide before restoring.
        if plan.restore {
            self.check()?;
            w.validate()?;
            let _ = ShowWindowAsync(w.hwnd, SW_RESTORE);
            let deadline = Instant::now() + Duration::from_millis(500);
            while IsIconic(w.hwnd).as_bool() && Instant::now() < deadline {
                self.check()?;
                w.validate()?;
                thread::sleep(Duration::from_millis(10));
            }
            self.check()?;
            if IsIconic(w.hwnd).as_bool() {
                return foreground::verify_activation(w.contains(GetForegroundWindow()), true);
            }
        }
        if plan.acquire {
            self.check()?;
            let _ = SetForegroundWindow(w.hwnd);
            if !w.contains(GetForegroundWindow()) {
                self.check()?;
                // Port wanctl's Focus fallback: create this OS thread's queue,
                // temporarily share input state, raise the target, then detach.
                // No synthetic key or pointer input is needed for activation.
                let attached = AttachedInput::new(w.hwnd);
                self.check()?;
                w.validate()?;
                let _ = BringWindowToTop(w.hwnd);
                self.check()?;
                let _ = SetForegroundWindow(w.hwnd);
                drop(attached);
            }
            let deadline = Instant::now() + Duration::from_millis(500);
            while !w.contains(GetForegroundWindow()) && Instant::now() < deadline {
                self.check()?;
                thread::sleep(Duration::from_millis(10));
            }
        }
        self.check()?;
        w.validate()?;
        foreground::verify_activation(
            w.contains(GetForegroundWindow()),
            IsIconic(w.hwnd).as_bool(),
        )?;
        self.target = Some(w.clone());
        self.check()
    }
    pub unsafe fn pause(&self, seconds: f64) -> Result<()> {
        let end = Instant::now() + Duration::from_secs_f64(seconds);
        loop {
            self.check()?;
            if Instant::now() >= end {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(5));
        }
    }
    pub unsafe fn finish(&mut self) -> Result<()> {
        self.monitor.fence()?;
        self.check()
    }
}

impl Drop for Guard<'_> {
    fn drop(&mut self) {
        ACTING.store(false, SeqCst);
        self.visible.take();
        if STOPPED.load(SeqCst) {
            self.indicator.hide();
        }
    }
}

/// Scoped to the request's OS thread; detach on success and every early return.
struct AttachedInput {
    caller: u32,
    threads: Vec<u32>,
}
impl AttachedInput {
    unsafe fn new(target: HWND) -> Self {
        let mut msg = MSG::default();
        let _ = PeekMessageW(&mut msg, None, 0, 0, PM_NOREMOVE);
        let mut attached = Self {
            caller: GetCurrentThreadId(),
            threads: Vec::new(),
        };
        for thread in [
            GetWindowThreadProcessId(GetForegroundWindow(), None),
            GetWindowThreadProcessId(target, None),
        ] {
            if thread != 0
                && thread != attached.caller
                && !attached.threads.contains(&thread)
                && AttachThreadInput(attached.caller, thread, true).as_bool()
            {
                attached.threads.push(thread);
            }
        }
        attached
    }
}
impl Drop for AttachedInput {
    fn drop(&mut self) {
        for &thread in self.threads.iter().rev() {
            unsafe {
                let _ = AttachThreadInput(self.caller, thread, false);
            }
        }
    }
}
