use super::{
    clipboard::Clipboard,
    observe::{actions, pattern, Element, Snapshot},
    safety::{Guard, INPUT_TAG},
};
use opencu_engine::{
    absolute_point, duration, number, parse_key, string, Chord, Error, Key, Rect, Result,
    Screenshot,
};
use serde_json::Value;
use windows::{
    core::*,
    Win32::{
        Foundation::*,
        UI::{Accessibility::*, Input::KeyboardAndMouse::*, WindowsAndMessaging::*},
    },
};
fn invalid(message: &str) -> Error {
    Error::new("INVALID_ARGUMENT", message)
}
unsafe fn indexed<'a>(args: &Value, s: &'a Snapshot) -> Result<&'a Element> {
    let i = args["element_index"]
        .as_u64()
        .filter(|i| *i > 0)
        .ok_or_else(|| invalid("element_index must be a positive integer"))?;
    let e = s.elements.get(i as usize - 1).ok_or_else(|| {
        Error::new(
            "STALE_ELEMENT",
            "Element index is not in the latest observation",
        )
    })?;
    super::safety::target(&e.window)?;
    if !e.element.CurrentIsEnabled()?.as_bool() {
        return Err(Error::new(
            "ELEMENT_DISABLED",
            "The target element is disabled",
        ));
    }
    Ok(e)
}
unsafe fn secondary(e: &IUIAutomationElement, action: &str) -> Result<()> {
    let unavailable = || Error::new("UNSUPPORTED_ACTION", "Action is no longer available");
    match action {
        "Invoke" => pattern::<IUIAutomationInvokePattern>(e, UIA_InvokePatternId)
            .ok_or_else(unavailable)?
            .Invoke()?,
        "Toggle" => pattern::<IUIAutomationTogglePattern>(e, UIA_TogglePatternId)
            .ok_or_else(unavailable)?
            .Toggle()?,
        "Expand" | "Collapse" => {
            let p = pattern::<IUIAutomationExpandCollapsePattern>(e, UIA_ExpandCollapsePatternId)
                .ok_or_else(unavailable)?;
            if action == "Expand" {
                p.Expand()?
            } else {
                p.Collapse()?
            }
        }
        "Select" | "AddToSelection" | "RemoveFromSelection" => {
            let p = pattern::<IUIAutomationSelectionItemPattern>(e, UIA_SelectionItemPatternId)
                .ok_or_else(unavailable)?;
            match action {
                "Select" => p.Select()?,
                "AddToSelection" => p.AddToSelection()?,
                _ => p.RemoveFromSelection()?,
            }
        }
        "DoDefaultAction" => {
            pattern::<IUIAutomationLegacyIAccessiblePattern>(e, UIA_LegacyIAccessiblePatternId)
                .ok_or_else(unavailable)?
                .DoDefaultAction()?
        }
        _ => return Err(unavailable()),
    }
    Ok(())
}
fn key_input(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(vk),
                wScan: scan,
                dwFlags: flags,
                dwExtraInfo: INPUT_TAG,
                ..Default::default()
            },
        },
    }
}
fn mouse(flags: MOUSE_EVENT_FLAGS, data: u32, dx: i32, dy: i32) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx,
                dy,
                mouseData: data,
                dwFlags: flags,
                dwExtraInfo: INPUT_TAG,
                ..Default::default()
            },
        },
    }
}
unsafe fn send(input: INPUT) -> Result<()> {
    if SendInput(&[input], std::mem::size_of::<INPUT>() as i32) != 1 {
        return Err(Error::new(
            "INPUT_FAILED",
            "Windows did not deliver input; no operation was retried",
        ));
    }
    Ok(())
}
struct Held {
    release: Vec<INPUT>,
}
impl Held {
    fn new() -> Self {
        Self { release: vec![] }
    }
    unsafe fn down(&mut self, down: INPUT, up: INPUT, g: &Guard<'_>) -> Result<()> {
        g.check()?;
        send(down)?;
        self.release.push(up);
        Ok(())
    }
    unsafe fn release(&mut self) -> Result<()> {
        let mut failure = None;
        for event in self.release.drain(..).rev() {
            if let Err(e) = send(event) {
                failure = Some(e);
            }
        }
        failure.map_or(Ok(()), Err)
    }
}
impl Drop for Held {
    fn drop(&mut self) {
        unsafe {
            let _ = self.release();
        }
    }
}
unsafe fn physical(vk: u16, hwnd: HWND) -> Result<(INPUT, INPUT)> {
    let thread = GetWindowThreadProcessId(hwnd, None);
    let layout = GetKeyboardLayout(thread);
    let scan = MapVirtualKeyExW(vk as u32, MAPVK_VK_TO_VSC_EX, Some(layout));
    if scan == 0 {
        return Err(Error::new(
            "UNSUPPORTED_KEY",
            "Key has no scan code in the target keyboard layout",
        ));
    }
    let flags = KEYEVENTF_SCANCODE
        | if scan & 0xff00 != 0 {
            KEYEVENTF_EXTENDEDKEY
        } else {
            KEYBD_EVENT_FLAGS(0)
        };
    Ok((
        key_input(0, (scan & 0xff) as u16, flags),
        key_input(0, (scan & 0xff) as u16, flags | KEYEVENTF_KEYUP),
    ))
}
unsafe fn chord_keys(mut chord: Chord, hwnd: HWND) -> Result<(Vec<u16>, Option<char>)> {
    let key = match chord.key {
        Some(Key::Virtual(v)) => Some(v),
        Some(Key::Character(c)) => {
            let thread = GetWindowThreadProcessId(hwnd, None);
            let layout = GetKeyboardLayout(thread);
            let code = if c as u32 <= 0xffff {
                VkKeyScanExW(c as u16, layout)
            } else {
                -1
            };
            if code == -1 {
                if !chord.modifiers.is_empty() {
                    return Err(Error::new(
                        "UNSUPPORTED_KEY_CHORD",
                        "Character has no physical key; use type_text",
                    ));
                }
                return Ok((vec![], Some(c)));
            }
            for (bit, vk) in [(1, 0xa0), (2, 0xa2), (4, 0xa4)] {
                if (code >> 8) & bit != 0 && !chord.modifiers.contains(&vk) {
                    chord.modifiers.push(vk);
                }
            }
            Some(code as u16 & 255)
        }
        None => None,
    };
    if let Some(key) = key {
        chord.modifiers.push(key);
    }
    Ok((chord.modifiers, None))
}
unsafe fn hold(keys: &[u16], hwnd: HWND, g: &Guard<'_>) -> Result<Held> {
    let mut held = Held::new();
    for vk in keys {
        let (down, up) = physical(*vk, hwnd)?;
        held.down(down, up, g)?;
    }
    Ok(held)
}
unsafe fn unicode(text: &str, g: &Guard<'_>) -> Result<()> {
    for unit in text.encode_utf16() {
        let mut held = Held::new();
        held.down(
            key_input(0, unit, KEYEVENTF_UNICODE),
            key_input(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP),
            g,
        )?;
        held.release()?;
    }
    g.check()
}
unsafe fn press(chord: Chord, hwnd: HWND, seconds: f64, g: &Guard<'_>) -> Result<()> {
    let (keys, c) = chord_keys(chord, hwnd)?;
    if let Some(c) = c {
        return unicode(&c.to_string(), g);
    }
    let mut held = hold(&keys, hwnd, g)?;
    g.pause(seconds)?;
    held.release()?;
    g.check()
}
unsafe fn pointer(point: (i32, i32), window: &super::apps::Window, g: &Guard<'_>) -> Result<()> {
    let (x, y) = point;
    let screen = Rect {
        x: GetSystemMetrics(SM_XVIRTUALSCREEN),
        y: GetSystemMetrics(SM_YVIRTUALSCREEN),
        width: GetSystemMetrics(SM_CXVIRTUALSCREEN),
        height: GetSystemMetrics(SM_CYVIRTUALSCREEN),
    };
    let (dx, dy) = absolute_point(screen, x, y)?;
    g.check()?;
    if GetAncestor(WindowFromPoint(POINT { x, y }), GA_ROOT) != window.hwnd {
        return Err(Error::new(
            "TARGET_OCCLUDED",
            "Another window covers the input point; no pointer input was sent",
        ));
    }
    send(mouse(
        MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
        0,
        dx,
        dy,
    ))?;
    g.check()
}
pub unsafe fn perform(
    method: &str,
    args: &Value,
    s: &mut Snapshot,
    image: Option<Screenshot>,
    g: &mut Guard<'_>,
) -> Result<()> {
    let indexed_arg = args.get("element_index").is_some();
    let coordinate = args.get("x").is_some() || args.get("y").is_some();
    if ["click", "scroll"].contains(&method) && indexed_arg == coordinate {
        return Err(invalid("Supply either element_index or both x and y"));
    }
    let e = if indexed_arg {
        Some(indexed(args, s)?.clone())
    } else {
        None
    };
    if ["set_value", "perform_secondary_action"].contains(&method) && e.is_none() {
        return Err(invalid("element_index is required"));
    }
    let target = e
        .as_ref()
        .map(|e| &e.window)
        .unwrap_or_else(|| {
            if coordinate {
                &s.app.windows[0]
            } else {
                &s.keyboard_window
            }
        })
        .clone();
    let window = &target;
    // Validate before activation (which may move/restore the window), and again after.
    let screenshot_point = || -> Result<Option<(i32, i32)>> {
        if coordinate {
            let shot=image.ok_or_else(||Error::new("SCREENSHOT_REQUIRED","Coordinate input requires the latest successful screenshot from this engine connection"))?;
            Ok(Some(shot.point(
                window.capture_rect()?,
                window.dpi(),
                number(args, "x")?,
                number(args, "y")?,
            )?))
        } else {
            Ok(None)
        }
    };
    screenshot_point()?;
    let seconds = duration(args)?;
    let chord = if method == "press_key" || args.get("key").is_some() {
        Some(parse_key(string(args, "key")?)?)
    } else {
        None
    };
    if method == "click" && chord.as_ref().is_some_and(|c| c.key.is_some()) {
        return Err(invalid("click.key must contain only modifiers"));
    }
    let count = args
        .get("click_count")
        .map(|v| {
            v.as_u64()
                .filter(|n| (1..=3).contains(n))
                .ok_or_else(|| invalid("click_count must be 1 to 3"))
        })
        .transpose()?
        .unwrap_or(1);
    let button = args
        .get("mouse_button")
        .map(|_| string(args, "mouse_button"))
        .transpose()?
        .unwrap_or("left");
    let (down, up) = match button {
        "left" | "l" => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
        "right" | "r" => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
        "middle" | "m" => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
        _ => return Err(invalid("Unknown mouse_button")),
    };
    let pages = args
        .get("pages")
        .map(|_| number(args, "pages"))
        .transpose()?
        .unwrap_or(1.0);
    if !(0.0..=100.0).contains(&pages) || pages == 0.0 {
        return Err(invalid("pages must be positive and at most 100"));
    }
    if ["paste", "type_text"].contains(&method) {
        string(args, "text")?;
    }
    if method == "paste"
        && args
            .get("format")
            .map(|v| v.as_str() != Some("text"))
            .unwrap_or(false)
    {
        return Err(Error::new(
            "UNSUPPORTED_ON_WINDOWS",
            "Windows phase 1 paste accepts only format=text",
        ));
    }
    if method == "scroll"
        && !matches!(
            string(args, "direction")?,
            "up" | "u" | "down" | "d" | "left" | "l" | "right" | "r"
        )
    {
        return Err(invalid("Unknown scroll direction"));
    }
    g.activate(window)?;
    s.keyboard_window = target.clone();
    screenshot_point()?;
    g.check()?;
    match method {
        "click" => {
            if let Some(e) = &e {
                if down == MOUSEEVENTF_LEFTDOWN
                    && count == 1
                    && chord.is_none()
                    && args.get("duration").is_none()
                {
                    let available = actions(&e.element);
                    if let Some(a) = ["Invoke", "Toggle", "Select", "DoDefaultAction"]
                        .iter()
                        .find(|a| available.iter().any(|s| s == **a))
                    {
                        g.check()?;
                        return secondary(&e.element, a);
                    }
                }
            }
            let mut modifiers = hold(
                &chord.map(|c| c.modifiers).unwrap_or_default(),
                window.hwnd,
                g,
            )?;
            for i in 0..count {
                let point = if let Some(p) = screenshot_point()? {
                    p
                } else {
                    element_point(e.as_ref().unwrap())?
                };
                pointer(point, window, g)?;
                screenshot_point()?;
                let mut held = Held::new();
                held.down(mouse(down, 0, 0, 0), mouse(up, 0, 0, 0), g)?;
                g.pause(seconds)?;
                held.release()?;
                if i + 1 < count {
                    g.pause(0.05)?;
                }
            }
            modifiers.release()?;
        }
        "press_key" => press(chord.unwrap(), window.hwnd, seconds, g)?,
        "type_text" => unicode(string(args, "text")?, g)?,
        "paste" => {
            g.check()?;
            let mut clipboard = Clipboard::replace(string(args, "text")?)?;
            let outcome = (|| {
                press(parse_key("ctrl+v")?, window.hwnd, 0.04, g)?;
                g.pause(0.2)
            })();
            let restore = clipboard.restore();
            outcome?;
            restore?;
        }
        "scroll" => {
            let direction = string(args, "direction")?;
            let horizontal = matches!(direction, "left" | "l" | "right" | "r");
            let positive = matches!(direction, "up" | "u" | "right" | "r");
            let delta = (pages * 360.0).round().max(1.0) as i32 * if positive { 1 } else { -1 };
            let point = if let Some(p) = screenshot_point()? {
                p
            } else {
                element_point(e.as_ref().unwrap())?
            };
            pointer(point, window, g)?;
            g.check()?;
            send(mouse(
                if horizontal {
                    MOUSEEVENTF_HWHEEL
                } else {
                    MOUSEEVENTF_WHEEL
                },
                delta as u32,
                0,
                0,
            ))?;
        }
        "set_value" => {
            let element = &e.unwrap().element;
            let value = string(args, "value")?;
            if let Some(p) = pattern::<IUIAutomationValuePattern>(element, UIA_ValuePatternId) {
                if p.CurrentIsReadOnly()?.as_bool() {
                    return Err(Error::new("ATTRIBUTE_NOT_SETTABLE", "Value is read-only"));
                }
                g.check()?;
                p.SetValue(&BSTR::from(value))?;
            } else if let Some(p) =
                pattern::<IUIAutomationRangeValuePattern>(element, UIA_RangeValuePatternId)
            {
                if p.CurrentIsReadOnly()?.as_bool() {
                    return Err(Error::new(
                        "ATTRIBUTE_NOT_SETTABLE",
                        "Range value is read-only",
                    ));
                }
                let n = value
                    .parse::<f64>()
                    .ok()
                    .filter(|n| n.is_finite())
                    .ok_or_else(|| invalid("Range value must be a finite number"))?;
                if n < p.CurrentMinimum()? || n > p.CurrentMaximum()? {
                    return Err(invalid(
                        "Range value is outside the control's minimum/maximum",
                    ));
                }
                g.check()?;
                p.SetValue(n)?;
            } else {
                return Err(Error::new(
                    "ATTRIBUTE_NOT_SETTABLE",
                    "Element has no writable Value or RangeValue pattern",
                ));
            }
        }
        "perform_secondary_action" => {
            let e = e.unwrap();
            let a = string(args, "action")?;
            if !e.actions.iter().any(|v| v == a) || !actions(&e.element).iter().any(|v| v == a) {
                return Err(Error::new(
                    "UNSUPPORTED_ACTION",
                    "Action is not listed in the latest observation",
                ));
            }
            g.check()?;
            secondary(&e.element, a)?;
        }
        _ => return Err(Error::new("METHOD_NOT_FOUND", "Unknown input method")),
    }
    g.check()
}
unsafe fn element_point(e: &Element) -> Result<(i32, i32)> {
    let r = super::observe::rect(e.element.CurrentBoundingRectangle()?);
    if e.element.CurrentIsOffscreen()?.as_bool() || r.width <= 0 || r.height <= 0 {
        return Err(Error::new(
            "ELEMENT_NOT_VISIBLE",
            "Element has no visible bounds; use a supported accessibility action",
        ));
    }
    Ok((r.x + r.width / 2, r.y + r.height / 2))
}
