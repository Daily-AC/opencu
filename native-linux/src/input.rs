//! Guarded input. Pointer and keyboard input use XTest and therefore need the
//! target window in front; accessibility actions and value setting do not.
use crate::a11y::{state, A11y};
use crate::apps::process_start;
use crate::display::{Display, WindowInfo};
use crate::keys::{self, Keymap, SHIFT_L};
use crate::monitor::Guard;
use crate::observe::{Element, Snapshot};
use opencu_engine::{number, string, Drag, Error, Result, Screenshot};
use serde_json::{json, Value};
use std::time::Duration;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{BUTTON_PRESS_EVENT, BUTTON_RELEASE_EVENT, KEY_PRESS_EVENT, KEY_RELEASE_EVENT, MOTION_NOTIFY_EVENT};
use x11rb::protocol::xproto::ConnectionExt as _;
use x11rb::protocol::xtest::ConnectionExt as _;

pub const UNKNOWN: &str = "The app did not confirm the action. Read state before continuing; do not repeat the action automatically.";
const ACTIVATIONS: &[&str] = &["click", "press", "activate", "jump", "toggle", "invoke", "open", "select", "switch"];

pub struct Ctx<'a> {
    pub display: &'a Display,
    pub keymap: &'a mut Keymap,
    pub a11y: Option<&'a A11y>,
    pub guard: &'a Guard<'a>,
    pub snapshot: &'a Snapshot,
    held_keys: Vec<u8>,
    held_buttons: Vec<u8>,
}

fn x_error<E: std::fmt::Display>(e: E) -> Error { Error::new("INPUT_FAILED", e.to_string()) }

impl<'a> Ctx<'a> {
    pub fn new(display: &'a Display, keymap: &'a mut Keymap, a11y: Option<&'a A11y>, guard: &'a Guard<'a>, snapshot: &'a Snapshot) -> Self {
        Self { display, keymap, a11y, guard, snapshot, held_keys: vec![], held_buttons: vec![] }
    }

    fn fake(&self, kind: u8, detail: u8, x: i16, y: i16) -> Result<()> {
        self.display.conn.xtest_fake_input(kind, detail, 0, self.display.root, x, y, 0).map_err(x_error)?;
        self.display.conn.flush().map_err(x_error)
    }

    fn sync(&self) -> Result<()> {
        self.display.conn.get_input_focus().map_err(x_error)?.reply().map_err(x_error)?;
        Ok(())
    }

    fn key(&mut self, code: u8, press: bool) -> Result<()> {
        if press { self.guard.check()?; self.keyboard_target()?; self.not_covered()?; }
        self.fake(if press { KEY_PRESS_EVENT } else { KEY_RELEASE_EVENT }, code, 0, 0)?;
        if press { self.held_keys.push(code); } else { self.held_keys.retain(|c| *c != code); }
        Ok(())
    }

    fn button(&mut self, button: u8, press: bool, x: i32, y: i32) -> Result<()> {
        if press { self.guard.check()?; self.owns_point(x, y)?; }
        self.fake(if press { BUTTON_PRESS_EVENT } else { BUTTON_RELEASE_EVENT }, button, 0, 0)?;
        if press { self.held_buttons.push(button); } else { self.held_buttons.retain(|b| *b != button); }
        Ok(())
    }

    fn move_to(&self, x: i32, y: i32) -> Result<()> {
        self.guard.check()?;
        self.fake(MOTION_NOTIFY_EVENT, 0, x as i16, y as i16)
    }

    /// Release anything this call still holds, after success or failure.
    pub fn release_all(&mut self) {
        for b in std::mem::take(&mut self.held_buttons) { let _ = self.fake(BUTTON_RELEASE_EVENT, b, 0, 0); }
        for k in std::mem::take(&mut self.held_keys).into_iter().rev() { let _ = self.fake(KEY_RELEASE_EVENT, k, 0, 0); }
        let _ = self.sync();
    }

    fn live_window(&self) -> Result<WindowInfo> {
        let w = &self.snapshot.window;
        let live = self.display.window(w.id, w.stack).ok_or_else(|| Error::new("STALE_WINDOW", "The observed window no longer exists; read state again."))?;
        if live.pid != w.pid || process_start(self.snapshot.app.pid) != Some(self.snapshot.app.started) {
            return Err(Error::new("STALE_WINDOW", "The observed process changed; read state again."));
        }
        Ok(live)
    }

    /// The active window belongs to the target: the observed window, a window
    /// transient for it, or the window it is transient for, in the same process.
    fn in_family(&self, active: Option<u32>) -> bool {
        let Some(active) = active else { return false };
        let target = &self.snapshot.window;
        if active == target.id { return true; }
        let Some(info) = self.display.window(active, 0) else { return false };
        if info.pid != target.pid { return false; }
        let mut current = Some(info);
        for _ in 0..16 {
            let Some(w) = current else { break };
            if w.transient_for == Some(target.id) || target.transient_for == Some(w.id) { return true; }
            current = w.transient_for.and_then(|t| self.display.window(t, 0));
        }
        false
    }

    /// A screen locker or saver over the display would receive the keys.
    pub fn not_covered(&self) -> Result<()> {
        match self.display.covering_window(self.snapshot.app.pid) {
            Some(by) => Err(Error::new("SCREEN_LOCKED", format!("A full-screen window of another program ({by}) covers the display, such as a screen locker; no input was sent."))),
            None => Ok(()),
        }
    }

    fn keyboard_target(&self) -> Result<()> {
        if self.in_family(self.display.active_window()) { Ok(()) } else {
            Err(Error::new("WINDOW_FOCUS_CHANGED", "The target window lost the foreground during input; remaining input was not sent."))
        }
    }

    fn owns_point(&self, x: i32, y: i32) -> Result<()> {
        let windows = self.display.windows();
        let top = self.display.top_at(x, y).ok_or_else(|| Error::new("TARGET_OCCLUDED", "No window is at that point."))?;
        if self.display.owner_pid(top, &windows) == Some(self.snapshot.app.pid) { Ok(()) } else {
            Err(Error::new("TARGET_OCCLUDED", "Another window covers that point; no click was sent there."))
        }
    }

    /// Bring the target forward, honouring the ten-second rule.
    pub fn front(&self) -> Result<()> {
        let live = self.live_window()?;
        if self.in_family(self.display.active_window()) && live.viewable && !live.hidden { return Ok(()); }
        self.guard.require_idle()?;
        self.display.activate(&live, Duration::from_millis(1500), &|active| self.in_family(active), &|| self.guard.check())?;
        self.guard.check()?;
        if !self.in_family(self.display.active_window()) {
            return Err(Error::new("ACTIVATION_FAILED", "The target window did not become active; no input was sent."));
        }
        Ok(())
    }

    fn element(&self, args: &Value) -> Result<&Element> {
        let index = args["element_index"].as_u64().filter(|n| *n > 0)
            .ok_or_else(|| Error::new("INVALID_ARGUMENT", "element_index must be a positive integer"))? as usize;
        let element = self.snapshot.elements.get(index - 1)
            .ok_or_else(|| Error::new("STALE_ELEMENT", "That element index is not in the latest state; read state again."))?;
        let a11y = self.a11y.ok_or_else(|| Error::new("A11Y_UNAVAILABLE", "Accessibility is unavailable; use screenshot coordinates."))?;
        let (states, role, name) = a11y.identity(&element.obj)?;
        if states & (1 << state::DEFUNCT) != 0 {
            return Err(Error::new("STALE_ELEMENT", "The element no longer exists; read state again."));
        }
        // Toolkits reuse object paths for new controls (Qt ids, recycled list rows).
        if role != element.role || name != element.name {
            return Err(Error::new("STALE_ELEMENT", "The element at that index changed since the last state; read state again."));
        }
        if states & (1 << state::ENABLED | 1 << state::SENSITIVE) == 0 {
            return Err(Error::new("ELEMENT_DISABLED", "The element is disabled; no input was sent."));
        }
        Ok(element)
    }

    /// A usable on-screen centre for pointer input.
    fn centre(&self, element: &Element) -> Option<(i32, i32)> {
        let live = self.a11y?.extents(&element.obj).ok()?;
        let (x, y) = (live.x + element.offset.0 + live.width / 2, live.y + element.offset.1 + live.height / 2);
        (live.width > 0 && live.height > 0 && self.display.screen.contains(x, y)).then_some((x, y))
    }

    /// The element's own window is on top at its centre. Menus and other
    /// override-redirect popups of the same process also qualify.
    fn element_owns_point(&self, element: &Element, x: i32, y: i32) -> Result<()> {
        let top = self.display.top_at(x, y).ok_or_else(|| Error::new("TARGET_OCCLUDED", "No window is at the element's centre."))?;
        let windows = self.display.windows();
        if let Some(w) = windows.iter().find(|w| w.frame == top || w.id == top) {
            return if w.id == element.window { Ok(()) } else {
                Err(Error::new("TARGET_OCCLUDED", format!("The window {:?} covers the element.", w.title)))
            };
        }
        if self.display.owner_pid(top, &windows) == Some(self.snapshot.app.pid) { Ok(()) } else {
            Err(Error::new("TARGET_OCCLUDED", "Another window covers the element."))
        }
    }

    fn point(&self, image: Option<Screenshot>, args: &Value) -> Result<(i32, i32)> {
        let image = image.ok_or_else(|| Error::new("SCREENSHOT_REQUIRED", "Coordinate input requires the latest successful screenshot from this connection"))?;
        let live = self.live_window()?;
        image.point(live.rect, 96, number(args, "x")?, number(args, "y")?)
    }

    fn chord(&mut self, key: Option<&str>) -> Result<Vec<u8>> {
        let Some(key) = key else { return Ok(vec![]) };
        let chord = opencu_engine::parse_key(key)?;
        if chord.key.is_some() { return Err(Error::new("INVALID_ARGUMENT", "click.key accepts modifiers only")); }
        let (mods, _) = keys::chord_keysyms(&chord)?;
        mods.into_iter().map(|m| self.keymap.stroke(&self.display.conn, m).map(|s| s.keycode)).collect()
    }

    fn unknown(&self) -> Value {
        json!({"ok": true, "outcome": "unknown", "message": UNKNOWN, "app": self.snapshot.app.json()})
    }

    fn action(&self, element: &Element, name: Option<&str>) -> Result<Value> {
        let a11y = self.a11y.unwrap();
        let actions = a11y.actions(&element.obj)?;
        let index = match name {
            Some(name) => actions.iter().position(|a| a == name)
                .ok_or_else(|| Error::new("UNSUPPORTED_ACTION", format!("The element does not expose {name:?}; available: {actions:?}")))?,
            None => actions.iter().position(|a| ACTIVATIONS.contains(&a.to_lowercase().as_str()))
                .ok_or_else(|| Error::new("ELEMENT_NOT_VISIBLE", "The element has no usable on-screen centre and no click action."))?,
        };
        self.guard.check()?;
        match a11y.do_action(&element.obj, index as i32)? {
            Some(true) => Ok(json!({"ok": true, "app": self.snapshot.app.json()})),
            Some(false) => Err(Error::new("UNSUPPORTED_ACTION", format!("The app declined the {:?} action.", actions[index]))),
            None => Ok(self.unknown()),
        }
    }

    pub fn perform(&mut self, method: &str, args: &Value, image: Option<Screenshot>) -> Result<Value> {
        self.not_covered()?;
        let result = self.dispatch(method, args, image);
        self.release_all();
        result
    }

    fn dispatch(&mut self, method: &str, args: &Value, image: Option<Screenshot>) -> Result<Value> {
        let ok = json!({"ok": true, "app": self.snapshot.app.json()});
        match method {
            "click" => {
                let button = match args["mouse_button"].as_str().unwrap_or("left") {
                    "left" | "l" => 1, "middle" | "m" => 2, "right" | "r" => 3,
                    _ => return Err(Error::new("INVALID_ARGUMENT", "mouse_button must be left, right or middle")),
                };
                let count = args["click_count"].as_u64().unwrap_or(1);
                if !(1..=3).contains(&count) { return Err(Error::new("INVALID_ARGUMENT", "click_count must be 1 to 3")); }
                let hold = if args.get("duration").is_some() { opencu_engine::duration(args)? } else { 0.035 };
                let plain = button == 1 && count == 1 && args.get("key").is_none() && args.get("duration").is_none();
                let mods = self.chord(args["key"].as_str())?;
                let point = if args.get("element_index").is_some() {
                    let element = self.element(args)?.clone();
                    let Some(point) = self.centre(&element) else {
                        if plain { return self.action(&element, None); }
                        return Err(Error::new("ELEMENT_NOT_VISIBLE", "The element has no usable on-screen centre."));
                    };
                    self.front()?;
                    if let Err(e) = self.element_owns_point(&element, point.0, point.1) {
                        // A covered control keeps its accessibility action for a plain click.
                        if plain && !element.actions.is_empty() { return self.action(&element, None); }
                        return Err(e);
                    }
                    point
                } else {
                    self.point(image, args)?;
                    self.front()?;
                    // Recheck the geometry after activation.
                    let point = self.point(image, args)?;
                    self.owns_point(point.0, point.1)?;
                    point
                };
                for m in &mods { self.key(*m, true)?; }
                self.move_to(point.0, point.1)?;
                for i in 0..count {
                    if i > 0 { self.guard.pause(0.06)?; }
                    self.button(button, true, point.0, point.1)?;
                    self.guard.pause(hold)?;
                    self.button(button, false, point.0, point.1)?;
                }
                for m in mods.iter().rev() { self.key(*m, false)?; }
                self.sync()?;
                Ok(ok)
            }
            "drag" => {
                let drag = Drag::parse(args)?;
                let live = self.live_window()?;
                let [from, to] = drag.points(image, live.rect, 96)?;
                self.front()?;
                self.owns_point(from.0, from.1)?;
                self.owns_point(to.0, to.1)?;
                self.move_to(from.0, from.1)?;
                self.button(1, true, from.0, from.1)?;
                for step in 1..=20 {
                    self.guard.pause(0.015)?;
                    let x = from.0 + (to.0 - from.0) * step / 20;
                    let y = from.1 + (to.1 - from.1) * step / 20;
                    self.move_to(x, y)?;
                }
                self.button(1, false, to.0, to.1)?;
                self.sync()?;
                Ok(ok)
            }
            "scroll" => {
                let (up, down, left, right) = (4, 5, 6, 7);
                let button = match args["direction"].as_str().unwrap_or("") {
                    "up" | "u" => up, "down" | "d" => down, "left" | "l" => left, "right" | "r" => right,
                    _ => return Err(Error::new("INVALID_ARGUMENT", "direction must be up, down, left or right")),
                };
                let pages = if args.get("pages").is_some() { number(args, "pages")? } else { 1.0 };
                if !(pages > 0.0 && pages <= 100.0) { return Err(Error::new("INVALID_ARGUMENT", "pages must be greater than 0 and at most 100")); }
                let point = if args.get("element_index").is_some() {
                    let element = self.element(args)?.clone();
                    self.centre(&element).ok_or_else(|| Error::new("ELEMENT_NOT_VISIBLE", "The element has no usable on-screen centre."))?
                } else { self.point(image, args)? };
                self.front()?;
                self.move_to(point.0, point.1)?;
                for _ in 0..((pages * 3.0).ceil() as u32).max(1) {
                    self.button(button, true, point.0, point.1)?;
                    self.button(button, false, point.0, point.1)?;
                    self.guard.pause(0.01)?;
                }
                self.sync()?;
                Ok(ok)
            }
            "press_key" => {
                let chord = opencu_engine::parse_key(string(args, "key")?)?;
                let hold = opencu_engine::key_duration(args)?;
                let (mods, key) = keys::chord_keysyms(&chord)?;
                let mut codes = vec![];
                for m in &mods { codes.push(self.keymap.stroke(&self.display.conn, *m)?.keycode); }
                if let Some(k) = key {
                    let stroke = self.keymap.stroke(&self.display.conn, k)?;
                    if stroke.shift && !mods.contains(&SHIFT_L) { codes.push(self.keymap.stroke(&self.display.conn, SHIFT_L)?.keycode); }
                    codes.push(stroke.keycode);
                }
                self.front()?;
                for c in &codes { self.key(*c, true)?; }
                self.guard.pause(hold)?;
                for c in codes.iter().rev() { self.key(*c, false)?; }
                self.sync()?;
                Ok(ok)
            }
            "type_text" => {
                let text = string(args, "text")?;
                self.front()?;
                let shift = self.keymap.stroke(&self.display.conn, SHIFT_L)?.keycode;
                for (i, c) in text.chars().enumerate() {
                    let stroke = self.keymap.stroke(&self.display.conn, keys::char_keysym(c))?;
                    if stroke.shift { self.key(shift, true)?; }
                    self.key(stroke.keycode, true)?;
                    self.key(stroke.keycode, false)?;
                    if stroke.shift { self.key(shift, false)?; }
                    if i % 16 == 15 { self.sync()?; std::thread::sleep(Duration::from_millis(5)); }
                }
                self.sync()?;
                Ok(ok)
            }
            "set_value" => {
                let element = self.element(args)?.clone();
                let value = string(args, "value")?;
                let a11y = self.a11y.unwrap();
                self.guard.check()?;
                if element.editable {
                    if !a11y.set_text(&element.obj, value)? {
                        return Err(Error::new("ATTRIBUTE_NOT_SETTABLE", "The app refused the new text."));
                    }
                } else if element.value {
                    let number: f64 = value.trim().parse().map_err(|_| Error::new("INVALID_ARGUMENT", "This element takes a number"))?;
                    a11y.set_number(&element.obj, number)?;
                } else {
                    return Err(Error::new("ATTRIBUTE_NOT_SETTABLE", "The element is not marked settable."));
                }
                Ok(ok)
            }
            "perform_secondary_action" => {
                let element = self.element(args)?.clone();
                self.action(&element, Some(string(args, "action")?))
            }
            "select_text" => {
                let element = self.element(args)?.clone();
                if !element.text {
                    return Err(Error::new("TEXT_SELECTION_UNSUPPORTED", "This element has no text interface. Get a fresh screenshot and click at the text position instead."));
                }
                let a11y = self.a11y.unwrap();
                let content = a11y.text(&element.obj)?;
                let target = string(args, "text")?;
                let prefix = args["prefix"].as_str().unwrap_or("");
                let suffix = args["suffix"].as_str().unwrap_or("");
                let needle = format!("{prefix}{target}{suffix}");
                let byte = content.find(&needle).ok_or_else(|| Error::new("INVALID_ARGUMENT", "The text was not found in the element."))?;
                let start = content[..byte].chars().count() as i32 + prefix.chars().count() as i32;
                let end = start + target.chars().count() as i32;
                let (s, e) = match args["selection_type"].as_str().unwrap_or("text") {
                    "cursor_before" => (start, start),
                    "cursor_after" => (end, end),
                    _ => (start, end),
                };
                self.guard.check()?;
                if !a11y.select(&element.obj, s, e)? {
                    return Err(Error::new("TEXT_SELECTION_UNSUPPORTED", "The app refused the selection. Get a fresh screenshot and click at the text position instead."));
                }
                Ok(ok)
            }
            "paste" => Err(Error::new("METHOD_NOT_FOUND", "paste is handled by the engine")),
            _ => Err(Error::new("METHOD_NOT_FOUND", format!("Unknown OpenCU operation: {method}"))),
        }
    }

}

impl Drop for Ctx<'_> {
    // Nothing stays pressed on an early return or a panic.
    fn drop(&mut self) { self.release_all(); }
}

impl Ctx<'_> {
    /// Ctrl+V into the target, for paste.
    pub fn ctrl_v(&mut self) -> Result<()> {
        let ctrl = self.keymap.stroke(&self.display.conn, 0xffe3)?.keycode;
        let v = self.keymap.stroke(&self.display.conn, 'v' as u32)?.keycode;
        self.front()?;
        self.key(ctrl, true)?;
        self.key(v, true)?;
        self.guard.pause(0.03)?;
        self.key(v, false)?;
        self.key(ctrl, false)?;
        self.sync()
    }
}
