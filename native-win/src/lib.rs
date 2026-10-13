//! Platform-independent parts of the inherited-stdio engine contract.
use serde_json::{json, Value};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
}
pub type Result<T> = std::result::Result<T, Error>;
impl Error {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
    pub fn json(&self) -> Value {
        json!({"code": self.code, "message": self.message})
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}
impl std::error::Error for Error {}
pub fn hresult_code(code: u32) -> &'static str {
    match code {
        0x80040201 => "STALE_ELEMENT", // UIA_E_ELEMENTNOTAVAILABLE
        0x80040200 => "ELEMENT_DISABLED",
        0x80070005 => "ACCESS_DENIED",
        0x80131505 | 0x800705b4 => "UIA_TIMEOUT",
        0x80040204 => "UNSUPPORTED_ACTION",
        _ => "WINDOWS_API_ERROR",
    }
}
#[cfg(windows)]
impl From<windows::core::Error> for Error {
    fn from(e: windows::core::Error) -> Self {
        Self::new(hresult_code(e.code().0 as u32), e.to_string())
    }
}
pub fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.contains('\0'))
        .ok_or_else(|| {
            Error::new(
                "INVALID_ARGUMENT",
                format!("{key} must be a string without NUL"),
            )
        })
}
pub fn number(v: &Value, key: &str) -> Result<f64> {
    v[key]
        .as_f64()
        .filter(|n| n.is_finite())
        .ok_or_else(|| Error::new("INVALID_ARGUMENT", format!("{key} must be a finite number")))
}
pub fn duration(v: &Value) -> Result<f64> {
    let n = if v.get("duration").is_some() {
        number(v, "duration")?
    } else {
        0.04
    };
    if !(0.0..=30.0).contains(&n) {
        return Err(Error::new(
            "INVALID_ARGUMENT",
            "duration must be between 0 and 30 seconds",
        ));
    }
    Ok(n)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}
impl Rect {
    pub fn contains(self, x: i32, y: i32) -> bool {
        x >= self.x
            && y >= self.y
            && (x as i64) < self.x as i64 + self.width as i64
            && (y as i64) < self.y as i64 + self.height as i64
    }
}
#[derive(Debug, Clone, Copy)]
pub struct Screenshot {
    pub bounds: Rect,
    pub width: u32,
    pub height: u32,
    pub dpi: u32,
}
impl Screenshot {
    pub fn point(self, current: Rect, dpi: u32, x: f64, y: f64) -> Result<(i32, i32)> {
        if current != self.bounds || dpi != self.dpi {
            return Err(Error::new(
                "STALE_SCREENSHOT",
                "The window moved, resized or changed DPI; get a new screenshot before input",
            ));
        }
        if self.width == 0
            || self.height == 0
            || !x.is_finite()
            || !y.is_finite()
            || x < 0.0
            || y < 0.0
            || x >= self.width as f64
            || y >= self.height as f64
        {
            return Err(Error::new(
                "INVALID_COORDINATE",
                "Coordinates must be inside the latest screenshot",
            ));
        }
        Ok((
            self.bounds.x + (x * self.bounds.width as f64 / self.width as f64).floor() as i32,
            self.bounds.y + (y * self.bounds.height as f64 / self.height as f64).floor() as i32,
        ))
    }
}
/// SendInput absolute coordinates address pixel centres across the virtual screen.
pub fn absolute_point(screen: Rect, x: i32, y: i32) -> Result<(i32, i32)> {
    if !screen.contains(x, y) {
        return Err(Error::new(
            "INVALID_COORDINATE",
            "Point is outside the current virtual desktop",
        ));
    }
    let nx = ((x as i64 - screen.x as i64) * 2 + 1) * 65536 / (screen.width as i64 * 2);
    let ny = ((y as i64 - screen.y as i64) * 2 + 1) * 65536 / (screen.height as i64 * 2);
    Ok((nx as i32, ny as i32))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Key {
    Virtual(u16),
    Character(char),
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chord {
    pub modifiers: Vec<u16>,
    pub key: Option<Key>,
}
pub fn parse_key(input: &str) -> Result<Chord> {
    let raw = if input == " " {
        "space".into()
    } else if input == "+" {
        "plus".into()
    } else if let Some(s) = input.strip_suffix("++") {
        format!("{s}+plus")
    } else {
        input.trim().to_owned()
    };
    let mut chord = Chord {
        modifiers: vec![],
        key: None,
    };
    for token in raw.split('+') {
        let token = token.trim();
        let lower = token.to_lowercase();
        let name = lower.as_str();
        let modifier = match name {
            "ctrl" | "control" | "ctrl_l" | "control_l" => Some(0xa2),
            "ctrl_r" | "control_r" => Some(0xa3),
            "shift" | "shift_l" => Some(0xa0),
            "shift_r" => Some(0xa1),
            "alt" | "alt_l" | "option" | "option_l" => Some(0xa4),
            "alt_r" | "option_r" | "iso_level3_shift" => Some(0xa5),
            "super" | "super_l" | "meta" | "meta_l" | "cmd" | "command" | "win" => Some(0x5b),
            "super_r" | "meta_r" | "command_r" => Some(0x5c),
            _ => None,
        };
        if let Some(m) = modifier {
            if !chord.modifiers.contains(&m) {
                chord.modifiers.push(m);
            }
            continue;
        }
        if token.is_empty() || chord.key.is_some() {
            return Err(Error::new(
                "INVALID_ARGUMENT",
                "A chord requires modifiers and at most one key; use plus for +",
            ));
        }
        let vk = match name {
            "return" | "enter" | "kp_enter" => Some(0x0d),
            "tab" | "iso_left_tab" => Some(9),
            "space" => Some(0x20),
            "backspace" | "back_space" => Some(8),
            "escape" | "esc" => Some(0x1b),
            "caps_lock" => Some(0x14),
            "delete" | "forwarddelete" => Some(0x2e),
            "home" => Some(0x24),
            "end" => Some(0x23),
            "prior" | "page_up" | "pageup" => Some(0x21),
            "next" | "page_down" | "pagedown" => Some(0x22),
            "left" => Some(0x25),
            "up" => Some(0x26),
            "right" => Some(0x27),
            "down" => Some(0x28),
            "insert" => Some(0x2d),
            "help" => Some(0x2f),
            "clear" => Some(0x0c),
            "kp_decimal" => Some(0x6e),
            "kp_multiply" => Some(0x6a),
            "kp_add" => Some(0x6b),
            "kp_divide" => Some(0x6f),
            "kp_subtract" => Some(0x6d),
            _ if name.starts_with('f') => name[1..]
                .parse::<u16>()
                .ok()
                .filter(|n| (1..=24).contains(n))
                .map(|n| 0x6f + n),
            _ if name.starts_with("kp_") => name[3..]
                .parse::<u16>()
                .ok()
                .filter(|n| *n <= 9)
                .map(|n| 0x60 + n),
            _ => None,
        };
        if name == "iso_left_tab" && !chord.modifiers.contains(&0xa0) {
            chord.modifiers.push(0xa0);
        }
        if let Some(vk) = vk {
            chord.key = Some(Key::Virtual(vk));
            continue;
        }
        let punctuation = [
            ("exclam", '!'),
            ("quotedbl", '"'),
            ("numbersign", '#'),
            ("dollar", '$'),
            ("percent", '%'),
            ("ampersand", '&'),
            ("apostrophe", '\''),
            ("quoteright", '\''),
            ("parenleft", '('),
            ("parenright", ')'),
            ("asterisk", '*'),
            ("plus", '+'),
            ("comma", ','),
            ("minus", '-'),
            ("period", '.'),
            ("slash", '/'),
            ("colon", ':'),
            ("semicolon", ';'),
            ("less", '<'),
            ("equal", '='),
            ("greater", '>'),
            ("question", '?'),
            ("at", '@'),
            ("bracketleft", '['),
            ("backslash", '\\'),
            ("bracketright", ']'),
            ("asciicircum", '^'),
            ("underscore", '_'),
            ("grave", '`'),
            ("quoteleft", '`'),
            ("braceleft", '{'),
            ("bar", '|'),
            ("braceright", '}'),
            ("asciitilde", '~'),
            ("kp_equal", '='),
        ];
        let c = punctuation
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, c)| *c)
            .or_else(|| {
                token
                    .strip_prefix('U')
                    .and_then(|s| u32::from_str_radix(s, 16).ok())
                    .and_then(char::from_u32)
            })
            .or_else(|| {
                if token.chars().count() == 1 {
                    token.chars().next()
                } else {
                    None
                }
            });
        chord.key = Some(Key::Character(c.ok_or_else(|| {
            Error::new("UNSUPPORTED_KEY", format!("Unknown key name: {token}"))
        })?));
    }
    Ok(chord)
}

#[derive(Default, Debug)]
pub struct Node {
    pub role: String,
    pub name: String,
    pub automation_id: String,
    pub class_name: String,
    pub bounds: Rect,
    pub value: Option<String>,
    pub enabled: bool,
    pub offscreen: bool,
    pub settable: bool,
    pub actions: Vec<String>,
    pub has_children: bool,
}
impl Node {
    pub fn visible_in_tree(&self) -> bool {
        // Only omit empty structural containers. Never omit unnamed leaf controls.
        !(self.has_children
            && ["Pane", "Group", "Custom"].contains(&self.role.as_str())
            && self.name.is_empty()
            && self.automation_id.is_empty()
            && self.value.is_none()
            && self.actions.is_empty()
            && !self.settable)
    }
    pub fn line(&self, index: usize, depth: usize) -> String {
        let mut line = format!("{}[{index}] {}", "  ".repeat(depth.min(40)), self.role);
        if !self.name.is_empty() {
            line += &format!(" title={}", json!(self.name));
        }
        if !self.automation_id.is_empty() {
            line += &format!(" ID={}", json!(self.automation_id));
        }
        if !self.class_name.is_empty() {
            line += &format!(" class={}", json!(self.class_name));
        }
        if self.name.is_empty() {
            line += &format!(
                " bounds=({},{},{},{})",
                self.bounds.x, self.bounds.y, self.bounds.width, self.bounds.height
            );
        }
        if let Some(value) = &self.value {
            line += &format!(" value={}", json!(value));
        }
        if !self.enabled {
            line += " disabled";
        }
        if self.offscreen {
            line += " offscreen";
        }
        if self.settable {
            line += " settable";
        }
        if !self.actions.is_empty() {
            line += &format!(" actions={}", self.actions.join(","));
        }
        line
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn key_aliases() {
        assert_eq!(
            parse_key("Control_L+ctrl+a").unwrap(),
            Chord {
                modifiers: vec![0xa2],
                key: Some(Key::Character('a'))
            }
        );
        assert_eq!(parse_key("super+a").unwrap().modifiers, vec![0x5b]);
        for name in ["Escape", "esc"] {
            assert_eq!(parse_key(name).unwrap().key, Some(Key::Virtual(0x1b)));
        }
        assert_eq!(parse_key("ISO_Left_Tab").unwrap().modifiers, vec![0xa0]);
        assert_eq!(parse_key("F24").unwrap().key, Some(Key::Virtual(0x87)));
        assert_eq!(parse_key("ctrl++").unwrap().key, Some(Key::Character('+')));
        assert_eq!(parse_key("U1F600").unwrap().key, Some(Key::Character('😀')));
        for name in ["", "ctrl+", "a+b"] {
            assert_eq!(parse_key(name).unwrap_err().code, "INVALID_ARGUMENT");
        }
        assert_eq!(parse_key("nonsense").unwrap_err().code, "UNSUPPORTED_KEY");
    }
    #[test]
    fn physical_pixels_at_125_percent_and_negative_monitor() {
        let r = Rect {
            x: -1920,
            y: 25,
            width: 1000,
            height: 750,
        };
        let s = Screenshot {
            bounds: r,
            width: 1000,
            height: 750,
            dpi: 120,
        };
        assert_eq!(s.point(r, 120, 500., 375.).unwrap(), (-1420, 400));
        for (x, y) in [(-1., 0.), (1000., 0.), (0., 750.), (f64::NAN, 0.)] {
            assert_eq!(
                s.point(r, 120, x, y).unwrap_err().code,
                "INVALID_COORDINATE"
            );
        }
        assert_eq!(
            s.point(Rect { x: -1919, ..r }, 120, 0., 0.)
                .unwrap_err()
                .code,
            "STALE_SCREENSHOT"
        );
        assert_eq!(
            s.point(r, 144, 0., 0.).unwrap_err().code,
            "STALE_SCREENSHOT"
        );
        let a = absolute_point(r, -1420, 400).unwrap();
        assert!((a.0 - 32768).abs() < 40);
        assert!((a.1 - 32768).abs() < 50);
    }
    #[test]
    fn unnamed_qt_and_layout_filter() {
        let mut n = Node {
            role: "Button".into(),
            class_name: "IconButton".into(),
            bounds: Rect {
                x: 10,
                y: 20,
                width: 30,
                height: 40,
            },
            enabled: true,
            ..Default::default()
        };
        assert!(n.visible_in_tree());
        assert_eq!(
            n.line(1, 0),
            "[1] Button class=\"IconButton\" bounds=(10,20,30,40)"
        );
        n.role = "Pane".into();
        n.has_children = true;
        assert!(!n.visible_in_tree());
        n.has_children = false;
        assert!(n.visible_in_tree());
        n.name = "Chrome Legacy Window".into();
        n.has_children = true;
        assert!(n.visible_in_tree());
        n.name = "x\n[99] spoof".into();
        assert!(!n.line(1, 0).contains('\n'));
    }
    #[test]
    fn stable_errors_and_numeric_validation() {
        assert_eq!(hresult_code(0x80040201), "STALE_ELEMENT");
        assert_eq!(hresult_code(0x80070005), "ACCESS_DENIED");
        assert_eq!(hresult_code(0x80131505), "UIA_TIMEOUT");
        assert_eq!(hresult_code(0x80040204), "UNSUPPORTED_ACTION");
        assert_eq!(
            Error::new("PERSON_ACTIVE", "Someone is using the computer").json()["code"],
            "PERSON_ACTIVE"
        );
        assert!(number(&json!({"x":true}), "x").is_err());
        assert!(duration(&json!({"duration":31})).is_err());
    }
}

pub fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let n = ((c[0] as u32) << 16)
            | ((c.get(1).copied().unwrap_or(0) as u32) << 8)
            | c.get(2).copied().unwrap_or(0) as u32;
        out.push(TABLE[(n >> 18) as usize] as char);
        out.push(TABLE[((n >> 12) & 63) as usize] as char);
        out.push(if c.len() > 1 {
            TABLE[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            TABLE[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}
#[cfg(test)]
mod encoding_tests {
    #[test]
    fn rfc4648() {
        for (s, b) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(super::base64(s.as_bytes()), b);
        }
    }
}
