use super::apps::Window;
use opencu_engine::{Error, Rect, Result};
use windows::Win32::{
    Foundation::*,
    Graphics::Imaging::*,
    System::{
        Com::{StructuredStorage::*, *},
        Memory::*,
    },
};
struct CaptureSession {
    session: windows::Graphics::Capture::GraphicsCaptureSession,
    pool: windows::Graphics::Capture::Direct3D11CaptureFramePool,
}
impl Drop for CaptureSession {
    fn drop(&mut self) {
        let _ = self.session.Close();
        let _ = self.pool.Close();
    }
}

/// Windows.Graphics.Capture samples the selected HWND's compositor surface, so
/// covering windows never substitute their pixels for the target's content.
pub unsafe fn capture(window: &Window, bounds: Rect) -> Result<(Vec<u8>, u32, u32)> {
    use windows::{
        core::Interface,
        Graphics::{
            Capture::*,
            DirectX::{Direct3D11::IDirect3DDevice, DirectXPixelFormat},
        },
        Win32::{
            Graphics::{Direct3D::*, Direct3D11::*, Dxgi::*},
            System::WinRT::{Direct3D11::*, Graphics::Capture::*},
        },
    };
    let fail = || {
        Error::new(
            "SCREENSHOT_FAILED",
            "Windows Graphics Capture did not return a usable window frame",
        )
    };
    let (w, h) = (bounds.width, bounds.height);
    if w <= 0 || h <= 0 || w as i64 * h as i64 > 32_000_000 {
        return Err(Error::new(
            "SCREENSHOT_TOO_LARGE",
            "Window dimensions are invalid or exceed 32 million pixels",
        ));
    }
    if !GraphicsCaptureSession::IsSupported()? {
        return Err(fail());
    }
    let interop: IGraphicsCaptureItemInterop =
        windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
    let item: GraphicsCaptureItem = interop.CreateForWindow(window.hwnd)?;
    let size = item.Size()?;
    if size.Width != w || size.Height != h {
        return Err(Error::new(
            "WINDOW_CHANGED",
            format!(
                "Capture surface is {}x{}, observed frame is {w}x{h}; read state again",
                size.Width, size.Height
            ),
        ));
    }
    let create = |driver| -> windows::core::Result<(ID3D11Device, ID3D11DeviceContext)> {
        let (mut device, mut context) = (None, None);
        D3D11CreateDevice(
            None,
            driver,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )?;
        Ok((device.unwrap(), context.unwrap()))
    };
    let (device, context) =
        create(D3D_DRIVER_TYPE_HARDWARE).or_else(|_| create(D3D_DRIVER_TYPE_WARP))?;
    let dxgi: IDXGIDevice = device.cast()?;
    let direct: IDirect3DDevice = CreateDirect3D11DeviceFromDXGIDevice(&dxgi)?.cast()?;
    let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
        &direct,
        DirectXPixelFormat::B8G8R8A8UIntNormalized,
        1,
        size,
    )?;
    let session = pool.CreateCaptureSession(&item)?;
    let capture = CaptureSession { session, pool };
    capture.session.SetIsCursorCaptureEnabled(false)?;
    // Retain the OS capture border. Border suppression can require a separate
    // permission prompt and is not needed for correctness.
    capture.session.StartCapture()?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    let frame = loop {
        if let Ok(frame) = capture.pool.TryGetNextFrame() {
            break frame;
        }
        if std::time::Instant::now() >= deadline {
            return Err(fail());
        }
        super::safety::desktop()?;
        std::thread::sleep(std::time::Duration::from_millis(10));
    };
    let pixels_result = (|| -> Result<Vec<u8>> {
        let actual = frame.ContentSize()?;
        if actual.Width != w || actual.Height != h {
            return Err(Error::new("WINDOW_CHANGED", "Capture content changed size"));
        }
        let surface: IDirect3DDxgiInterfaceAccess = frame.Surface()?.cast()?;
        let texture: ID3D11Texture2D = surface.GetInterface()?;
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        texture.GetDesc(&mut desc);
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.MiscFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
        let mut staging = None;
        device.CreateTexture2D(&desc, None, Some(&mut staging))?;
        let staging = staging.unwrap();
        context.CopyResource(&staging, &texture);
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
        let mut pixels = vec![0u8; w as usize * h as usize * 4];
        for y in 0..h as usize {
            std::ptr::copy_nonoverlapping(
                (mapped.pData as *const u8).add(y * mapped.RowPitch as usize),
                pixels.as_mut_ptr().add(y * w as usize * 4),
                w as usize * 4,
            );
        }
        context.Unmap(&staging, 0);
        for p in pixels.chunks_exact_mut(4) {
            p[3] = 255;
        }
        Ok(pixels)
    })();
    let _ = frame.Close();
    drop(capture);
    let pixels = pixels_result?;
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
    frame.WritePixels(h as u32, w as u32 * 4, &pixels)?;
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
    Ok((bytes, w as u32, h as u32))
}
