use opencu_engine::{Error, Result};
use windows::{
    core::*,
    Win32::{
        Foundation::*,
        System::{DataExchange::*, Memory::*},
        UI::WindowsAndMessaging::*,
    },
};
struct Global(HGLOBAL);
impl Drop for Global {
    fn drop(&mut self) {
        unsafe {
            if !self.0.is_invalid() {
                let _ = GlobalFree(Some(self.0));
            }
        }
    }
}
struct Open;
impl Drop for Open {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseClipboard();
        }
    }
}
unsafe fn open(hwnd: HWND) -> Result<Open> {
    OpenClipboard(Some(hwnd)).map_err(|_| {
        Error::new(
            "CLIPBOARD_UNAVAILABLE",
            "Clipboard is busy; paste was not retried",
        )
    })?;
    Ok(Open)
}
unsafe fn alloc(bytes: &[u8]) -> Result<Global> {
    let h = Global(GlobalAlloc(GMEM_MOVEABLE, bytes.len())?);
    let p = GlobalLock(h.0);
    if p.is_null() {
        return Err(Error::new(
            "CLIPBOARD_UNAVAILABLE",
            "Cannot allocate clipboard snapshot",
        ));
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, bytes.len());
    let _ = GlobalUnlock(h.0);
    Ok(h)
}
unsafe fn put(format: u32, mut data: Global) -> Result<()> {
    SetClipboardData(format, Some(HANDLE(data.0 .0)))?;
    data.0 = HGLOBAL::default();
    Ok(())
}
/// Preserve all HGLOBAL formats before mutation. Refuse opaque/GDI handles.
pub struct Clipboard {
    hwnd: HWND,
    original: Vec<(u32, Global)>,
    sequence: u32,
    changed: bool,
}
impl Clipboard {
    pub unsafe fn replace(text: &str) -> Result<Self> {
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("STATIC"),
            w!(""),
            WINDOW_STYLE(0),
            0,
            0,
            0,
            0,
            Some(HWND_MESSAGE),
            None,
            None,
            None,
        )?;
        let mut this = Self {
            hwnd,
            original: vec![],
            sequence: 0,
            changed: false,
        };
        let opened = open(hwnd)?;
        let before = GetClipboardSequenceNumber();
        let mut format = 0;
        let mut total = 0usize;
        loop {
            SetLastError(WIN32_ERROR(0));
            format = EnumClipboardFormats(format);
            if format == 0 {
                if GetLastError().0 != 0 {
                    return Err(Error::new(
                        "CLIPBOARD_UNAVAILABLE",
                        "Cannot enumerate all clipboard formats",
                    ));
                }
                break;
            }
            if [2, 3, 9, 14, 0x80, 0x81, 0x82, 0x83, 0x8e].contains(&format)
                || (0x200..0x400).contains(&format)
            {
                return Err(Error::new("CLIPBOARD_UNAVAILABLE","Clipboard contains a handle-based/private format that cannot be safely restored; no paste was sent"));
            }
            let handle = GetClipboardData(format).map_err(|_| {
                Error::new(
                    "CLIPBOARD_UNAVAILABLE",
                    "Cannot preserve a clipboard format",
                )
            })?;
            let global = HGLOBAL(handle.0);
            let size = GlobalSize(global);
            total = total.saturating_add(size);
            if size == 0 || total > 64 * 1024 * 1024 {
                return Err(Error::new(
                    "CLIPBOARD_UNAVAILABLE",
                    "Clipboard is opaque/empty or exceeds 64 MiB",
                ));
            }
            let p = GlobalLock(global);
            if p.is_null() {
                return Err(Error::new(
                    "CLIPBOARD_UNAVAILABLE",
                    "Clipboard data cannot be preserved",
                ));
            }
            let copied = alloc(std::slice::from_raw_parts(p as *const u8, size));
            let _ = GlobalUnlock(global);
            this.original.push((format, copied?));
        }
        let bytes: Vec<u8> = text
            .encode_utf16()
            .chain(Some(0))
            .flat_map(u16::to_le_bytes)
            .collect();
        let data = alloc(&bytes)?;
        if GetClipboardSequenceNumber() != before {
            return Err(Error::new(
                "CLIPBOARD_CHANGED",
                "Clipboard changed while being preserved; paste was not sent",
            ));
        }
        EmptyClipboard()?;
        this.changed = true;
        this.sequence = GetClipboardSequenceNumber();
        let result = put(13, data);
        this.sequence = GetClipboardSequenceNumber();
        drop(opened);
        if let Err(e) = result {
            this.restore()?;
            return Err(e);
        }
        Ok(this)
    }
    pub unsafe fn restore(&mut self) -> Result<()> {
        if !self.changed {
            return Ok(());
        }
        let _open = open(self.hwnd).map_err(|_| {
            Error::new(
                "CLIPBOARD_RESTORE_FAILED",
                "Paste may have run, but the clipboard is busy and could not be restored",
            )
        })?;
        if GetClipboardSequenceNumber() != self.sequence {
            self.changed = false;
            return Ok(());
        }
        EmptyClipboard()?;
        self.sequence = GetClipboardSequenceNumber();
        for (format, data) in self.original.drain(..) {
            put(format, data).map_err(|e| Error::new("CLIPBOARD_RESTORE_FAILED", e.message))?;
        }
        self.changed = false;
        Ok(())
    }
}
impl Drop for Clipboard {
    fn drop(&mut self) {
        unsafe {
            if let Err(e) = self.restore() {
                eprintln!("{e}");
            }
            let _ = DestroyWindow(self.hwnd);
        }
    }
}
