//! Capture-excluded status UI, isolated from the physical-input monitor.
use opencu_engine::{Error, Result};
use std::{
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use windows::{
    core::*,
    Win32::{
        Foundation::*, Graphics::Gdi::*, System::LibraryLoader::*, UI::WindowsAndMessaging::*,
    },
};
fn unavailable() -> Error {
    Error::new(
        "INDICATOR_UNAVAILABLE",
        "The visible operation indicator could not be shown; input was refused",
    )
}
unsafe extern "system" fn paint(hwnd: HWND, msg: u32, w: WPARAM, l: LPARAM) -> LRESULT {
    match msg {
        WM_NCHITTEST => LRESULT(HTTRANSPARENT as isize),
        WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let dc = BeginPaint(hwnd, &mut ps);
            let mut rect = RECT::default();
            let _ = GetClientRect(hwnd, &mut rect);
            let brush = CreateSolidBrush(COLORREF(0x00302920));
            FillRect(dc, &rect, brush);
            let _ = DeleteObject(brush.into());
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, COLORREF(0x00ffffff));
            let mut text = super::wide("OpenCU is operating  -  Esc to stop");
            text.pop();
            DrawTextW(
                dc,
                &mut text,
                &mut rect,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            );
            let _ = EndPaint(hwnd, &ps);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, w, l),
    }
}
enum Command {
    Show(mpsc::Sender<bool>),
    Check(mpsc::Sender<bool>),
    Idle,
    Hide,
    Close,
}
pub struct Indicator {
    tx: mpsc::Sender<Command>,
    thread: Option<thread::JoinHandle<()>>,
}
pub struct Active<'a> {
    indicator: &'a Indicator,
}
impl Drop for Active<'_> {
    fn drop(&mut self) {
        let _ = self.indicator.tx.send(Command::Idle);
    }
}
impl Indicator {
    pub fn new() -> Result<Self> {
        let (tx, rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::channel();
        let thread = thread::spawn(move || unsafe {
            let run = (|| -> Result<()> {
                let module = GetModuleHandleW(None)?;
                let class = w!("OpenCUOperationIndicator");
                let wc = WNDCLASSW {
                    hInstance: module.into(),
                    lpszClassName: class,
                    lpfnWndProc: Some(paint),
                    ..Default::default()
                };
                if RegisterClassW(&wc) == 0 {
                    return Err(unavailable());
                }
                let hwnd = CreateWindowExW(
                    WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
                    class,
                    w!("OpenCU is operating - Esc to stop"),
                    WS_POPUP | WS_DISABLED,
                    (GetSystemMetrics(SM_CXSCREEN) - 420) / 2,
                    12,
                    420,
                    44,
                    None,
                    None,
                    Some(module.into()),
                    None,
                )?;
                let setup = (|| -> Result<()> {
                    SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)?;
                    let mut affinity = 0;
                    GetWindowDisplayAffinity(hwnd, &mut affinity)?;
                    if affinity != WDA_EXCLUDEFROMCAPTURE.0 {
                        return Err(unavailable());
                    }
                    Ok(())
                })();
                if setup.is_err() {
                    let _ = DestroyWindow(hwnd);
                    let _ = UnregisterClassW(class, Some(module.into()));
                    return setup;
                }
                let _ = ready_tx.send(Ok(()));
                let mut until = None;
                loop {
                    for _ in 0..64 {
                        let mut msg = MSG::default();
                        if !PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                            break;
                        }
                        DispatchMessageW(&msg);
                    }
                    if until.is_some_and(|t| Instant::now() >= t) {
                        let _ = ShowWindow(hwnd, SW_HIDE);
                        until = None;
                    }
                    match rx.recv_timeout(Duration::from_millis(10)) {
                        Ok(Command::Show(reply)) => {
                            until = None;
                            let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
                            let shown = SetWindowPos(
                                hwnd,
                                Some(HWND_TOPMOST),
                                0,
                                0,
                                0,
                                0,
                                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                            )
                            .is_ok()
                                && IsWindowVisible(hwnd).as_bool();
                            let _ = InvalidateRect(Some(hwnd), None, true);
                            let _ = UpdateWindow(hwnd);
                            let _ = reply.send(shown);
                        }
                        Ok(Command::Check(reply)) => {
                            let _ = reply.send(IsWindowVisible(hwnd).as_bool());
                        }
                        Ok(Command::Idle) => until = Some(Instant::now() + Duration::from_secs(2)),
                        Ok(Command::Hide) => {
                            let _ = ShowWindow(hwnd, SW_HIDE);
                            until = None;
                        }
                        Ok(Command::Close) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        Err(mpsc::RecvTimeoutError::Timeout) => {}
                    }
                }
                let _ = DestroyWindow(hwnd);
                let _ = UnregisterClassW(class, Some(module.into()));
                Ok(())
            })();
            if let Err(e) = run {
                let _ = ready_tx.send(Err(e));
            }
        });
        ready_rx
            .recv_timeout(Duration::from_secs(3))
            .map_err(|_| unavailable())??;
        Ok(Self {
            tx,
            thread: Some(thread),
        })
    }
    pub fn begin(&self) -> Result<Active<'_>> {
        let (tx, rx) = mpsc::channel();
        self.tx.send(Command::Show(tx)).map_err(|_| unavailable())?;
        if !rx
            .recv_timeout(Duration::from_secs(1))
            .map_err(|_| unavailable())?
        {
            return Err(unavailable());
        }
        Ok(Active { indicator: self })
    }
    pub fn check(&self) -> Result<()> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .send(Command::Check(tx))
            .map_err(|_| unavailable())?;
        if !rx
            .recv_timeout(Duration::from_secs(1))
            .map_err(|_| unavailable())?
        {
            return Err(unavailable());
        }
        Ok(())
    }
    pub fn hide(&self) {
        let _ = self.tx.send(Command::Hide);
    }
}
impl Drop for Indicator {
    fn drop(&mut self) {
        let _ = self.tx.send(Command::Close);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
