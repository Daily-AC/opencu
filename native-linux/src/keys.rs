//! Keysyms, the core keyboard mapping and spare-keycode binding.
//!
//! Key names are parsed by the shared Windows parser so both engines accept
//! the same xdotool-style syntax; virtual-key codes are translated to keysyms.
//! A keysym missing from the keymap (most non-ASCII text) is bound to an unused
//! keycode. Bindings stay in place for the connection and are removed on exit,
//! so a client never reads a keycode whose meaning changed under it.
use opencu_engine::{Chord, Error, Key, Result};
use std::collections::HashMap;
use std::time::Duration;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{ConnectionExt as _, Keycode, Keysym};
use x11rb::rust_connection::RustConnection;

pub const SHIFT_L: Keysym = 0xffe1;

pub fn virtual_keysym(vk: u16) -> Option<Keysym> {
    Some(match vk {
        0xa2 => 0xffe3, // Control_L
        0xa3 => 0xffe4,
        0xa0 => SHIFT_L,
        0xa1 => 0xffe2,
        0xa4 => 0xffe9, // Alt_L
        0xa5 => 0xfe03, // ISO_Level3_Shift (AltGr)
        0x5b => 0xffeb, // Super_L
        0x5c => 0xffec,
        0x0d => 0xff0d, // Return
        0x09 => 0xff09,
        0x20 => 0x20,
        0x08 => 0xff08,
        0x1b => 0xff1b,
        0x14 => 0xffe5,
        0x2e => 0xffff, // Delete
        0x24 => 0xff50,
        0x23 => 0xff57,
        0x21 => 0xff55,
        0x22 => 0xff56,
        0x25 => 0xff51,
        0x26 => 0xff52,
        0x27 => 0xff53,
        0x28 => 0xff54,
        0x2d => 0xff63,
        0x2f => 0xff6a,
        0x0c => 0xff0b,
        0x6e => 0xffae,
        0x6a => 0xffaa,
        0x6b => 0xffab,
        0x6f => 0xffaf,
        0x6d => 0xffad,
        0x60..=0x69 => 0xffb0 + (vk - 0x60) as u32,
        0x70..=0x87 => 0xffbe + (vk - 0x70) as u32,
        _ => return None,
    })
}

pub fn char_keysym(c: char) -> Keysym {
    match c {
        '\n' | '\r' => 0xff0d,
        '\t' => 0xff09,
        c if (0x20..0x7f).contains(&(c as u32)) || (0xa0..0x100).contains(&(c as u32)) => c as u32,
        c => 0x0100_0000 | c as u32,
    }
}

/// Keysyms for a chord: modifiers first, then the key.
pub fn chord_keysyms(chord: &Chord) -> Result<(Vec<Keysym>, Option<Keysym>)> {
    let modifiers = chord.modifiers.iter()
        .map(|m| virtual_keysym(*m).ok_or_else(|| Error::new("UNSUPPORTED_KEY", "Unsupported modifier")))
        .collect::<Result<Vec<_>>>()?;
    let key = match &chord.key {
        None => None,
        Some(Key::Virtual(vk)) => Some(virtual_keysym(*vk).ok_or_else(|| Error::new("UNSUPPORTED_KEY", format!("Unsupported key code {vk:#x}")))?),
        Some(Key::Character(c)) => Some(char_keysym(*c)),
    };
    Ok((modifiers, key))
}

pub struct Keymap {
    min: Keycode,
    per: usize,
    syms: Vec<Keysym>,
    /// Keysym -> spare keycode bound by this connection, with the original keysyms.
    bound: HashMap<Keysym, Keycode>,
    order: Vec<Keysym>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stroke {
    pub keycode: Keycode,
    pub shift: bool,
}

impl Keymap {
    pub fn load(conn: &RustConnection) -> Result<Self> {
        let setup = conn.setup();
        let (min, max) = (setup.min_keycode, setup.max_keycode);
        let map = conn.get_keyboard_mapping(min, max - min + 1)
            .map_err(|e| Error::new("X11_ERROR", e.to_string()))?
            .reply().map_err(|e| Error::new("X11_ERROR", e.to_string()))?;
        Ok(Self { min, per: (map.keysyms_per_keycode as usize).max(1), syms: map.keysyms, bound: HashMap::new(), order: vec![] })
    }

    pub fn reload(&mut self, conn: &RustConnection) -> Result<()> {
        let fresh = Self::load(conn)?;
        self.per = fresh.per;
        self.syms = fresh.syms;
        // Keep only bindings the server still holds.
        let syms = &self.syms;
        let (min, per) = (self.min, self.per);
        self.bound.retain(|sym, code| syms.get((*code - min) as usize * per) == Some(sym));
        let bound = &self.bound;
        self.order.retain(|s| bound.contains_key(s));
        Ok(())
    }

    fn row(&self, code: Keycode) -> &[Keysym] {
        let start = (code - self.min) as usize * self.per;
        &self.syms[start..start + self.per]
    }

    pub fn find(&self, keysym: Keysym) -> Option<Stroke> {
        let count = self.syms.len() / self.per;
        let codes = (0..count).map(|i| self.min + i as u8);
        // Prefer an unshifted position; level 2 needs Shift.
        for code in codes.clone() {
            if self.row(code).first() == Some(&keysym) { return Some(Stroke { keycode: code, shift: false }); }
        }
        for code in codes {
            if self.row(code).get(1) == Some(&keysym) { return Some(Stroke { keycode: code, shift: true }); }
        }
        None
    }

    fn spare(&self) -> Option<Keycode> {
        let count = self.syms.len() / self.per;
        (0..count).rev().map(|i| self.min + i as u8)
            .find(|code| self.row(*code).iter().all(|s| *s == 0))
    }

    /// Resolve a keysym, binding a spare keycode if needed.
    pub fn stroke(&mut self, conn: &RustConnection, keysym: Keysym) -> Result<Stroke> {
        if let Some(stroke) = self.find(keysym) { return Ok(stroke); }
        let code = match self.spare() {
            Some(code) => code,
            None => {
                // Reuse the least recently bound keycode after letting clients
                // finish with it.
                let oldest = *self.order.first().ok_or_else(|| Error::new("UNSUPPORTED_KEY", "No free keycode is available for this character."))?;
                std::thread::sleep(Duration::from_millis(150));
                let code = self.bound.remove(&oldest).unwrap();
                self.order.remove(0);
                code
            }
        };
        let row = vec![keysym; self.per.min(2)];
        conn.change_keyboard_mapping(1, code, row.len() as u8, &row)
            .map_err(|e| Error::new("X11_ERROR", e.to_string()))?
            .check().map_err(|e| Error::new("UNSUPPORTED_KEY", format!("The X server refused a key mapping: {e}")))?;
        // Wait for the server, then give clients a moment to read MappingNotify.
        conn.get_input_focus().map_err(|e| Error::new("X11_ERROR", e.to_string()))?
            .reply().map_err(|e| Error::new("X11_ERROR", e.to_string()))?;
        std::thread::sleep(Duration::from_millis(30));
        let start = (code - self.min) as usize * self.per;
        for (i, slot) in self.syms[start..start + self.per].iter_mut().enumerate() {
            *slot = if i < row.len() { keysym } else { 0 };
        }
        self.bound.insert(keysym, code);
        self.order.push(keysym);
        Ok(Stroke { keycode: code, shift: false })
    }

    /// Remove every binding this connection added.
    pub fn restore(&mut self, conn: &RustConnection) {
        for code in self.bound.values() {
            let empty = vec![0; self.per];
            let _ = conn.change_keyboard_mapping(1, *code, self.per as u8, &empty);
        }
        self.bound.clear();
        self.order.clear();
        let _ = conn.flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shared_key_names_map_to_keysyms() {
        let chord = opencu_engine::parse_key("ctrl+shift+Page_Down").unwrap();
        let (mods, key) = chord_keysyms(&chord).unwrap();
        assert_eq!(mods, vec![0xffe3, 0xffe1]);
        assert_eq!(key, Some(0xff56));
        let (_, key) = chord_keysyms(&opencu_engine::parse_key("F12").unwrap()).unwrap();
        assert_eq!(key, Some(0xffc9));
        let (mods, key) = chord_keysyms(&opencu_engine::parse_key("super").unwrap()).unwrap();
        assert_eq!((mods, key), (vec![0xffeb], None));
        let (_, key) = chord_keysyms(&opencu_engine::parse_key("Return").unwrap()).unwrap();
        assert_eq!(key, Some(0xff0d));
    }
    #[test]
    fn characters_use_latin1_or_unicode_keysyms() {
        assert_eq!(char_keysym('a'), 0x61);
        assert_eq!(char_keysym('é'), 0xe9);
        assert_eq!(char_keysym('你'), 0x0100_4f60);
        assert_eq!(char_keysym('\n'), 0xff0d);
    }
}
