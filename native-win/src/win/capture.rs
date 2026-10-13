use super::apps::Window;
use opencu_engine::{Error, Rect, Result};
use windows::Win32::{
    Foundation::*,
    Graphics::{Gdi::*, Imaging::*},
    Storage::Xps::*,
    System::{
        Com::{StructuredStorage::*, *},
        Memory::*,
    },
};
struct Surface {
    dc: HDC,
    bitmap: HBITMAP,
    old: HGDIOBJ,
}
impl Drop for Surface {
    fn drop(&mut self) {
        unsafe {
            let _ = SelectObject(self.dc, self.old);
            let _ = DeleteObject(self.bitmap.into());
            let _ = DeleteDC(self.dc);
        }
    }
}
pub unsafe fn capture(window: &Window, bounds: Rect) -> Result<(Vec<u8>, u32, u32)> {
    let fail = || {
        Error::new("SCREENSHOT_FAILED","Windows could not capture this window (PrintWindow); minimized, protected or GPU surfaces may be unavailable")
    };
    let (w, h) = (bounds.width, bounds.height);
    if w <= 0 || h <= 0 || w as i64 * h as i64 > 32_000_000 {
        return Err(Error::new(
            "SCREENSHOT_TOO_LARGE",
            "Window has invalid dimensions or exceeds 32 million pixels",
        ));
    }
    let dc = CreateCompatibleDC(None);
    if dc.is_invalid() {
        return Err(fail());
    }
    let info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: -h,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut bits = std::ptr::null_mut();
    let bitmap = match CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0) {
        Ok(b) => b,
        Err(e) => {
            let _ = DeleteDC(dc);
            return Err(e.into());
        }
    };
    let old = SelectObject(dc, bitmap.into());
    let surface = Surface { dc, bitmap, old };
    if !PrintWindow(window.hwnd, dc, PRINT_WINDOW_FLAGS(2)).as_bool() {
        return Err(fail());
    }
    let pixels = std::slice::from_raw_parts_mut(bits as *mut u8, w as usize * h as usize * 4);
    // GDI alpha is unspecified. Encode opaque BGRA, preserving capture pixel size.
    for p in pixels.chunks_exact_mut(4) {
        p[3] = 255;
    }
    let factory: IWICImagingFactory =
        CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
    let stream = CreateStreamOnHGlobal(HGLOBAL::default(), true)?;
    let encoder = factory.CreateEncoder(&GUID_ContainerFormatPng, std::ptr::null())?;
    encoder.Initialize(&stream, WICBitmapEncoderNoCache)?;
    let (mut frame, mut properties) = (None, None);
    encoder.CreateNewFrame(&mut frame, &mut properties)?;
    let frame = frame.ok_or_else(fail)?;
    frame.Initialize(properties.as_ref())?;
    frame.SetSize(w as u32, h as u32)?;
    let mut format = GUID_WICPixelFormat32bppBGRA;
    frame.SetPixelFormat(&mut format)?;
    if format != GUID_WICPixelFormat32bppBGRA {
        return Err(fail());
    }
    frame.WritePixels(h as u32, w as u32 * 4, pixels)?;
    frame.Commit()?;
    encoder.Commit()?;
    let mut stat = STATSTG::default();
    stream.Stat(&mut stat, STATFLAG_NONAME)?;
    let global = GetHGlobalFromStream(&stream)?;
    let data = GlobalLock(global);
    if data.is_null() {
        return Err(fail());
    }
    let bytes = std::slice::from_raw_parts(data as *const u8, stat.cbSize as usize).to_vec();
    let _ = GlobalUnlock(global);
    drop(surface);
    Ok((bytes, w as u32, h as u32))
}
