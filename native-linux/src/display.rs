//! X11 connection, EWMH window inventory, activation and window capture.
use opencu_engine::{Error, Rect, Result};
use std::time::{Duration, Instant};
use x11rb::connection::{Connection, RequestConnection};
use x11rb::protocol::composite::{ConnectionExt as _, Redirect};
use x11rb::protocol::xproto::*;
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

x11rb::atom_manager! {
    pub Atoms: AtomsCookie {
        _NET_CLIENT_LIST,
        _NET_CLIENT_LIST_STACKING,
        _NET_ACTIVE_WINDOW,
        _NET_WM_PID,
        _NET_WM_NAME,
        _NET_WM_STATE,
        _NET_WM_STATE_HIDDEN,
        _NET_WM_WINDOW_TYPE,
        _NET_WM_WINDOW_TYPE_DESKTOP,
        _NET_WM_WINDOW_TYPE_DOCK,
        _NET_WM_WINDOW_TYPE_TOOLBAR,
        _NET_WM_WINDOW_TYPE_MENU,
        _NET_WM_WINDOW_TYPE_UTILITY,
        _NET_WM_WINDOW_TYPE_SPLASH,
        _NET_WM_WINDOW_TYPE_DIALOG,
        _NET_WM_WINDOW_TYPE_NOTIFICATION,
        _NET_SUPPORTING_WM_CHECK,
        _NET_WM_DESKTOP,
        _NET_CURRENT_DESKTOP,
        _NET_CLOSE_WINDOW,
        WM_STATE,
        UTF8_STRING,
        AT_SPI_BUS,
        CLIPBOARD,
        TARGETS,
        OPENCU_TIME,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Normal,
    Dialog,
    Tool,
    Panel,
}

/// A managed top-level client window.
#[derive(Debug, Clone)]
pub struct WindowInfo {
    pub id: Window,
    /// The root child holding the window (the WM frame, or the client itself).
    pub frame: Window,
    pub pid: Option<u32>,
    pub title: String,
    pub instance: String,
    pub class: String,
    /// Client area in root coordinates.
    pub client: Rect,
    /// Frame (client plus decorations) in root coordinates.
    pub rect: Rect,
    pub viewable: bool,
    pub hidden: bool,
    pub kind: Kind,
    pub transient_for: Option<Window>,
    /// Index in bottom-to-top stacking order.
    pub stack: usize,
}

impl WindowInfo {
    pub fn summary(&self, state: &str) -> serde_json::Value {
        serde_json::json!({"title": self.title, "class": self.class, "window": format!("0x{:x}", self.id), "state": state})
    }
}

pub struct Display {
    pub conn: RustConnection,
    pub root: Window,
    pub atoms: Atoms,
    pub screen: Rect,
    pub composite: bool,
    time_window: Window,
}

fn x_error<E: std::fmt::Display>(error: E) -> Error {
    Error::new("X11_ERROR", error.to_string())
}

impl Display {
    pub fn connect() -> Result<Self> {
        if std::env::var_os("DISPLAY").map_or(true, |d| d.is_empty()) {
            let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
            return Err(Error::new("DISPLAY_UNAVAILABLE", if wayland {
                "Only X11 is supported. This is a Wayland session without DISPLAY; Wayland is not supported."
            } else {
                "DISPLAY is not set. Start OpenCU in the X11 desktop session, for example with DISPLAY=:1."
            }));
        }
        let (conn, screen_num) = x11rb::connect(None)
            .map_err(|e| Error::new("DISPLAY_UNAVAILABLE", format!("Cannot connect to the X server: {e}")))?;
        // Under XWayland a person's input to native Wayland windows is invisible
        // to the safety monitor, so Wayland sessions are refused even with DISPLAY.
        if conn.extension_information("XWAYLAND").ok().flatten().is_some() {
            return Err(Error::new("DISPLAY_UNAVAILABLE", "This is XWayland inside a Wayland session. Only X11 sessions are supported."));
        }
        let screen = &conn.setup().roots[screen_num];
        let root = screen.root;
        let rect = Rect { x: 0, y: 0, width: screen.width_in_pixels as i32, height: screen.height_in_pixels as i32 };
        let atoms = Atoms::new(&conn).map_err(x_error)?.reply().map_err(x_error)?;
        // Automatic redirection keeps a private copy of every top-level window,
        // so covered windows can be captured by their own pixels. It coexists
        // with a compositing manager's manual redirection and ends with this connection.
        let composite = conn.composite_query_version(0, 4).ok()
            .and_then(|c| c.reply().ok())
            .is_some_and(|v| v.major_version > 0 || v.minor_version >= 2)
            && conn.composite_redirect_subwindows(root, Redirect::AUTOMATIC).ok()
                .is_some_and(|c| c.check().is_ok());
        let time_window = conn.generate_id().map_err(x_error)?;
        conn.create_window(0, time_window, root, -10, -10, 1, 1, 0, WindowClass::INPUT_ONLY, 0,
            &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE).override_redirect(1))
            .map_err(x_error)?.check().map_err(x_error)?;
        Ok(Self { conn, root, atoms, screen: rect, composite, time_window })
    }

    pub fn has_extension(&self, name: &'static str) -> bool {
        self.conn.extension_information(name).ok().flatten().is_some()
    }

    pub fn vendor(&self) -> String {
        String::from_utf8_lossy(&self.conn.setup().vendor).into_owned()
    }

    /// A server timestamp, as required by focus-stealing prevention.
    pub fn server_time(&self) -> u32 {
        let ok = self.conn.change_property8(PropMode::APPEND, self.time_window, self.atoms.OPENCU_TIME,
            AtomEnum::STRING, &[]).is_ok() && self.conn.flush().is_ok();
        let deadline = Instant::now() + Duration::from_millis(300);
        while ok && Instant::now() < deadline {
            match self.conn.poll_for_event() {
                Ok(Some(Event::PropertyNotify(e))) if e.window == self.time_window => return e.time,
                Ok(Some(_)) => {}
                Ok(None) => std::thread::sleep(Duration::from_millis(2)),
                Err(_) => break,
            }
        }
        x11rb::CURRENT_TIME
    }

    pub fn property(&self, window: Window, atom: Atom, kind: impl Into<Atom>) -> Option<GetPropertyReply> {
        self.conn.get_property(false, window, atom, kind, 0, 1 << 20).ok()?.reply().ok()
            .filter(|r| r.type_ != x11rb::NONE)
    }

    pub fn property_u32(&self, window: Window, atom: Atom, kind: impl Into<Atom>) -> Vec<u32> {
        self.property(window, atom, kind)
            .and_then(|r| r.value32().map(|v| v.collect()))
            .unwrap_or_default()
    }

    pub fn text_property(&self, window: Window, atom: Atom) -> Option<String> {
        let reply = self.property(window, atom, AtomEnum::ANY)?;
        Some(String::from_utf8_lossy(&reply.value).trim_end_matches('\0').to_owned())
    }

    pub fn title(&self, window: Window) -> String {
        self.text_property(window, self.atoms._NET_WM_NAME)
            .filter(|t| !t.is_empty())
            .or_else(|| self.text_property(window, AtomEnum::WM_NAME.into()))
            .unwrap_or_default()
    }

    pub fn pid(&self, window: Window) -> Option<u32> {
        self.property_u32(window, self.atoms._NET_WM_PID, AtomEnum::CARDINAL).first().copied().filter(|p| *p > 0)
    }

    pub fn active_window(&self) -> Option<Window> {
        self.property_u32(self.root, self.atoms._NET_ACTIVE_WINDOW, AtomEnum::WINDOW).first().copied().filter(|w| *w != 0)
    }

    pub fn window_manager(&self) -> Option<String> {
        let check = *self.property_u32(self.root, self.atoms._NET_SUPPORTING_WM_CHECK, AtomEnum::WINDOW).first()?;
        Some(self.title(check)).filter(|n| !n.is_empty())
    }

    /// The root child that contains `window` (its WM frame when reparented).
    pub fn frame_of(&self, window: Window) -> Window {
        let mut current = window;
        for _ in 0..16 {
            let Ok(Ok(tree)) = self.conn.query_tree(current).map(|c| c.reply()) else { return current };
            if tree.parent == self.root || tree.parent == x11rb::NONE { return current; }
            current = tree.parent;
        }
        current
    }

    pub fn root_rect(&self, window: Window) -> Option<Rect> {
        let geometry = self.conn.get_geometry(window).ok()?.reply().ok()?;
        let origin = self.conn.translate_coordinates(window, self.root, 0, 0).ok()?.reply().ok()?;
        Some(Rect { x: origin.dst_x as i32, y: origin.dst_y as i32, width: geometry.width as i32, height: geometry.height as i32 })
    }

    fn kind(&self, window: Window) -> Kind {
        let types = self.property_u32(window, self.atoms._NET_WM_WINDOW_TYPE, AtomEnum::ATOM);
        let a = &self.atoms;
        if types.iter().any(|t| *t == a._NET_WM_WINDOW_TYPE_DESKTOP || *t == a._NET_WM_WINDOW_TYPE_DOCK) {
            Kind::Panel
        } else if types.iter().any(|t| [a._NET_WM_WINDOW_TYPE_TOOLBAR, a._NET_WM_WINDOW_TYPE_MENU,
            a._NET_WM_WINDOW_TYPE_UTILITY, a._NET_WM_WINDOW_TYPE_SPLASH, a._NET_WM_WINDOW_TYPE_NOTIFICATION].contains(t)) {
            Kind::Tool
        } else if types.contains(&a._NET_WM_WINDOW_TYPE_DIALOG) {
            Kind::Dialog
        } else {
            Kind::Normal
        }
    }

    pub fn window(&self, id: Window, stack: usize) -> Option<WindowInfo> {
        let attributes = self.conn.get_window_attributes(id).ok()?.reply().ok()?;
        let class = self.property(id, AtomEnum::WM_CLASS.into(), AtomEnum::STRING)
            .map(|r| r.value).unwrap_or_default();
        let mut parts = class.split(|b| *b == 0).map(|s| String::from_utf8_lossy(s).into_owned());
        let instance = parts.next().unwrap_or_default();
        let class = parts.next().unwrap_or_default();
        let states = self.property_u32(id, self.atoms._NET_WM_STATE, AtomEnum::ATOM);
        let frame = self.frame_of(id);
        let client = self.root_rect(id)?;
        let rect = if frame == id { client } else { self.root_rect(frame).unwrap_or(client) };
        let viewable = attributes.map_state == MapState::VIEWABLE;
        Some(WindowInfo {
            id,
            frame,
            pid: self.pid(id),
            title: self.title(id),
            instance,
            class,
            client,
            rect,
            viewable,
            hidden: states.contains(&self.atoms._NET_WM_STATE_HIDDEN) || !viewable,
            kind: self.kind(id),
            transient_for: self.property_u32(id, AtomEnum::WM_TRANSIENT_FOR.into(), AtomEnum::WINDOW).first().copied().filter(|w| *w != 0),
            stack,
        })
    }

    /// Managed client windows, bottom to top. Without a window manager, falls
    /// back to viewable, titled root children.
    pub fn windows(&self) -> Vec<WindowInfo> {
        let mut ids = self.property_u32(self.root, self.atoms._NET_CLIENT_LIST_STACKING, AtomEnum::WINDOW);
        if ids.is_empty() {
            ids = self.property_u32(self.root, self.atoms._NET_CLIENT_LIST, AtomEnum::WINDOW);
        }
        if ids.is_empty() {
            if let Ok(Ok(tree)) = self.conn.query_tree(self.root).map(|c| c.reply()) {
                ids = tree.children.into_iter().filter(|w| {
                    self.conn.get_window_attributes(*w).ok().and_then(|c| c.reply().ok())
                        .is_some_and(|a| a.map_state == MapState::VIEWABLE && !a.override_redirect)
                        && !self.title(*w).is_empty()
                }).collect();
            }
        }
        ids.into_iter().enumerate().filter_map(|(stack, id)| self.window(id, stack)).collect()
    }

    /// The top-level window (frame, client or override-redirect popup) at a root point.
    pub fn top_at(&self, x: i32, y: i32) -> Option<Window> {
        let reply = self.conn.translate_coordinates(self.root, self.root, x as i16, y as i16).ok()?.reply().ok()?;
        Some(reply.child).filter(|w| *w != x11rb::NONE)
    }

    /// PID of whatever owns a root child: a managed client inside a frame,
    /// or an override-redirect popup.
    pub fn owner_pid(&self, top: Window, windows: &[WindowInfo]) -> Option<u32> {
        if let Some(w) = windows.iter().find(|w| w.frame == top || w.id == top) {
            return w.pid;
        }
        if let Some(pid) = self.pid(top) { return Some(pid); }
        // Popups often keep the PID on their only child.
        let tree = self.conn.query_tree(top).ok()?.reply().ok()?;
        tree.children.iter().find_map(|child| self.pid(*child))
    }

    /// A full-screen override-redirect window of another program above every
    /// managed window: a screen locker or screen saver (i3lock, xscreensaver,
    /// xfce4-screensaver, KDE). Keyboard input would go to it.
    pub fn covering_window(&self, target_pid: u32) -> Option<String> {
        let tree = self.conn.query_tree(self.root).ok()?.reply().ok()?;
        for id in tree.children.into_iter().rev() {
            let Some(a) = self.conn.get_window_attributes(id).ok().and_then(|c| c.reply().ok()) else { continue };
            if a.map_state != MapState::VIEWABLE || a.class != WindowClass::INPUT_OUTPUT { continue; }
            if !a.override_redirect { return None; }
            let Some(r) = self.root_rect(id) else { continue };
            let covers = r.x <= self.screen.x && r.y <= self.screen.y
                && r.x + r.width >= self.screen.x + self.screen.width && r.y + r.height >= self.screen.y + self.screen.height;
            if covers && self.owner_pid(id, &[]) != Some(target_pid) {
                let class = self.property(id, AtomEnum::WM_CLASS.into(), AtomEnum::STRING)
                    .map(|r| String::from_utf8_lossy(&r.value).split('\0').next().unwrap_or("").to_owned()).unwrap_or_default();
                return Some(if class.is_empty() { format!("window 0x{id:x}") } else { class });
            }
        }
        None
    }

    /// A key or pointer button that is down right now (a person holding it,
    /// or one left pressed by a killed client).
    pub fn held_input(&self) -> Option<String> {
        let keys = self.conn.query_keymap().ok()?.reply().ok()?.keys;
        if let Some(code) = keys.iter().enumerate().find_map(|(i, byte)| (0..8).find(|b| byte & (1 << b) != 0).map(|b| i * 8 + b)) {
            return Some(format!("keycode {code} is held down"));
        }
        let pointer = self.conn.query_pointer(self.root).ok()?.reply().ok()?;
        let buttons = u16::from(pointer.mask) & (u16::from(KeyButMask::BUTTON1) | u16::from(KeyButMask::BUTTON2)
            | u16::from(KeyButMask::BUTTON3) | u16::from(KeyButMask::BUTTON4) | u16::from(KeyButMask::BUTTON5));
        (buttons != 0).then(|| "a mouse button is held down".to_owned())
    }

    pub fn focus(&self) -> Option<Window> {
        self.conn.get_input_focus().ok()?.reply().ok().map(|r| r.focus)
    }

    pub fn is_ancestor(&self, ancestor: Window, mut window: Window) -> bool {
        for _ in 0..32 {
            if window == ancestor { return true; }
            let Ok(Ok(tree)) = self.conn.query_tree(window).map(|c| c.reply()) else { return false };
            if tree.parent == x11rb::NONE || window == self.root { return false; }
            window = tree.parent;
        }
        false
    }

    /// Ask the window manager to activate a window (de-iconifying it), and set
    /// keyboard focus as `xdotool windowactivate` does. Waits for confirmation.
    /// `accept` also takes the window's own dialogs; `check` runs before each request.
    pub fn activate(&self, window: &WindowInfo, budget: Duration, accept: &dyn Fn(Option<Window>) -> bool,
        check: &dyn Fn() -> Result<()>) -> Result<()> {
        let started = Instant::now();
        let mut sent = 0;
        loop {
            let current = self.active_window();
            let active = current == Some(window.id) || accept(current);
            let focused = self.focus().is_some_and(|f| self.is_ancestor(window.id, f) || f == window.frame
                || current.is_some_and(|c| c != window.id && accept(Some(c)) && self.is_ancestor(c, f)));
            let viewable = self.conn.get_window_attributes(window.id).ok().and_then(|c| c.reply().ok())
                .is_some_and(|a| a.map_state == MapState::VIEWABLE);
            if active && focused && viewable { return Ok(()); }
            let elapsed = started.elapsed();
            if elapsed >= budget {
                return Err(Error::new("ACTIVATION_FAILED", "The window manager did not bring the target window to the front; no input was sent."));
            }
            if sent == 0 || (sent == 1 && elapsed >= budget * 2 / 5) {
                check()?;
                sent += 1;
                let time = self.server_time();
                let prior = self.active_window().unwrap_or(0);
                let event = ClientMessageEvent::new(32, window.id, self.atoms._NET_ACTIVE_WINDOW, [2, time, prior, 0, 0]);
                let _ = self.conn.send_event(false, self.root,
                    EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY, event);
                if self.active_window().is_none() {
                    // No EWMH window manager: map and raise directly.
                    let _ = self.conn.map_window(window.id);
                    let _ = self.conn.configure_window(window.frame, &ConfigureWindowAux::new().stack_mode(StackMode::ABOVE));
                }
                let _ = self.conn.flush();
                std::thread::sleep(Duration::from_millis(30));
                // Focus-stealing prevention can treat the request as raise-only.
                if let Ok(cookie) = self.conn.set_input_focus(InputFocus::PARENT, window.id, time) {
                    let _ = cookie.check();
                }
            }
            std::thread::sleep(Duration::from_millis(15));
        }
    }

    /// PNG of a top-level window (including WM decorations) and its root rectangle.
    pub fn capture(&self, window: &WindowInfo) -> Result<(Vec<u8>, u32, u32, Rect)> {
        if !window.viewable {
            return Err(Error::new("SCREENSHOT_FAILED", "The window is minimized or unmapped; activate it first."));
        }
        let rect = self.root_rect(window.frame).ok_or_else(|| Error::new("STALE_WINDOW", "The window no longer exists."))?;
        if rect.width <= 0 || rect.height <= 0 {
            return Err(Error::new("SCREENSHOT_FAILED", "The window has no size."));
        }
        if rect.width as i64 * rect.height as i64 > 32_000_000 {
            return Err(Error::new("SCREENSHOT_TOO_LARGE", "The window is larger than 32 million pixels."));
        }
        let (w, h) = (rect.width as u16, rect.height as u16);
        let image = if self.composite {
            let pixmap = self.conn.generate_id().map_err(x_error)?;
            let named = self.conn.composite_name_window_pixmap(window.frame, pixmap).map_err(x_error)?.check();
            let image = named.ok().and_then(|_| self.conn.get_image(ImageFormat::Z_PIXMAP, pixmap, 0, 0, w, h, !0).ok())
                .and_then(|c| c.reply().ok());
            let _ = self.conn.free_pixmap(pixmap);
            image
        } else { None };
        let (image, visual_owner) = match image {
            Some(image) => (image, window.frame),
            // Screen pixels could show other windows covering the target.
            None if self.composite => return Err(Error::new("SCREENSHOT_FAILED", "The window's pixels could not be read; read state again.")),
            None => {
                // Without Composite, read what is on screen in the window's area.
                let clip = intersect(rect, self.screen).ok_or_else(|| Error::new("SCREENSHOT_FAILED", "The window is off screen."))?;
                if clip != rect {
                    return Err(Error::new("SCREENSHOT_FAILED", "The window is partly off screen and the X server has no Composite extension."));
                }
                let reply = self.conn.get_image(ImageFormat::Z_PIXMAP, self.root, rect.x as i16, rect.y as i16, w, h, !0)
                    .map_err(x_error)?.reply().map_err(|e| Error::new("SCREENSHOT_FAILED", e.to_string()))?;
                (reply, self.root)
            }
        };
        let visual = if image.visual != 0 { image.visual } else {
            self.conn.get_window_attributes(visual_owner).ok().and_then(|c| c.reply().ok()).map(|a| a.visual).unwrap_or(0)
        };
        let rgb = self.to_rgb(&image.data, image.depth, visual, w as usize, h as usize)?;
        Ok((encode_png(&rgb, w as u32, h as u32)?, w as u32, h as u32, rect))
    }

    fn to_rgb(&self, data: &[u8], depth: u8, visual: Visualid, width: usize, height: usize) -> Result<Vec<u8>> {
        let setup = self.conn.setup();
        let format = setup.pixmap_formats.iter().find(|f| f.depth == depth)
            .ok_or_else(|| Error::new("SCREENSHOT_FAILED", format!("No pixmap format for depth {depth}")))?;
        let bpp = format.bits_per_pixel as usize;
        if ![16, 24, 32].contains(&bpp) {
            return Err(Error::new("SCREENSHOT_FAILED", format!("Unsupported {bpp} bits per pixel")));
        }
        let pad = format.scanline_pad as usize;
        let stride = (width * bpp).div_ceil(pad) * pad / 8;
        let (mut red, mut green, mut blue) = (0xff0000u32, 0xff00u32, 0xffu32);
        for screen in &setup.roots {
            for d in &screen.allowed_depths {
                if let Some(v) = d.visuals.iter().find(|v| v.visual_id == visual) {
                    (red, green, blue) = (v.red_mask, v.green_mask, v.blue_mask);
                }
            }
        }
        if data.len() < stride * height {
            return Err(Error::new("SCREENSHOT_FAILED", "The X server returned a short image."));
        }
        let lsb = setup.image_byte_order == ImageOrder::LSB_FIRST;
        let channel = |pixel: u32, mask: u32| -> u8 {
            if mask == 0 { return 0; }
            let shift = mask.trailing_zeros();
            let bits = (mask >> shift).count_ones();
            let value = (pixel & mask) >> shift;
            if bits >= 8 { (value >> (bits - 8)) as u8 } else { ((value * 255) / ((1 << bits) - 1)) as u8 }
        };
        let mut out = Vec::with_capacity(width * height * 3);
        for row in 0..height {
            let line = &data[row * stride..];
            for col in 0..width {
                let bytes = &line[col * bpp / 8..col * bpp / 8 + bpp / 8];
                let mut pixel = 0u32;
                for (i, b) in bytes.iter().enumerate() {
                    let shift = if lsb { i * 8 } else { (bytes.len() - 1 - i) * 8 };
                    pixel |= (*b as u32) << shift;
                }
                out.extend_from_slice(&[channel(pixel, red), channel(pixel, green), channel(pixel, blue)]);
            }
        }
        Ok(out)
    }

    pub fn close(&self) {
        let _ = self.conn.destroy_window(self.time_window);
        let _ = self.conn.flush();
    }
}

pub fn intersect(a: Rect, b: Rect) -> Option<Rect> {
    let x = a.x.max(b.x);
    let y = a.y.max(b.y);
    let right = (a.x + a.width).min(b.x + b.width);
    let bottom = (a.y + a.height).min(b.y + b.height);
    (right > x && bottom > y).then(|| Rect { x, y, width: right - x, height: bottom - y })
}

pub fn encode_png(rgb: &[u8], width: u32, height: u32) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    let mut encoder = png::Encoder::new(&mut bytes, width, height);
    encoder.set_color(png::ColorType::Rgb);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);
    let mut writer = encoder.write_header().map_err(|e| Error::new("SCREENSHOT_FAILED", e.to_string()))?;
    writer.write_image_data(rgb).map_err(|e| Error::new("SCREENSHOT_FAILED", e.to_string()))?;
    writer.finish().map_err(|e| Error::new("SCREENSHOT_FAILED", e.to_string()))?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn intersection_clips_and_rejects_disjoint() {
        let screen = Rect { x: 0, y: 0, width: 100, height: 100 };
        assert_eq!(intersect(Rect { x: 90, y: -5, width: 20, height: 20 }, screen), Some(Rect { x: 90, y: 0, width: 10, height: 15 }));
        assert_eq!(intersect(Rect { x: 100, y: 0, width: 5, height: 5 }, screen), None);
    }
    #[test]
    fn png_has_signature_and_size() {
        let png = encode_png(&[255, 0, 0, 0, 255, 0], 2, 1).unwrap();
        assert_eq!(&png[..8], &[137, 80, 78, 71, 13, 10, 26, 10]);
        assert_eq!(u32::from_be_bytes(png[16..20].try_into().unwrap()), 2);
    }
}
