//! Pure observation policy. None of these predicates authorize input.
use crate::Rect;
use serde_json::json;

#[derive(Clone, Debug, Default)]
pub struct WindowInfo {
    pub hwnd: usize,
    pub owner: Option<usize>,
    pub title: String,
    pub class_name: String,
    pub bounds: Rect,
    pub visible: bool,
    pub minimized: bool,
    pub tool: bool,
    /// Only ordinary, non-layered, non-transparent windows count as covers.
    pub opaque: bool,
}

/// Input is in desktop Z order (front to back); area is deliberately irrelevant.
pub fn capture_target(windows: &[WindowInfo], foreground: usize) -> Option<usize> {
    let usable = |w: &&WindowInfo| w.visible && !w.minimized;
    windows
        .iter()
        .position(|w| w.hwnd == foreground && usable(&w) && !w.tool)
        .or_else(|| windows.iter().position(|w| usable(&w) && !w.tool))
        .or_else(|| windows.iter().position(|w| usable(&w)))
        .or_else(|| windows.iter().position(|w| w.visible))
}

/// Descendants only, never the target's owner or unrelated ownership siblings.
pub fn owned_by(windows: &[WindowInfo], hwnd: usize, target: usize) -> bool {
    let mut current = hwnd;
    for _ in 0..64 {
        if current == target {
            return true;
        }
        let Some(owner) = windows
            .iter()
            .find(|w| w.hwnd == current)
            .and_then(|w| w.owner)
        else {
            return false;
        };
        current = owner;
    }
    false
}

impl Rect {
    pub fn intersects(self, other: Self) -> bool {
        self.width > 0
            && self.height > 0
            && other.width > 0
            && other.height > 0
            && (self.x as i64) < other.x as i64 + other.width as i64
            && (other.x as i64) < self.x as i64 + self.width as i64
            && (self.y as i64) < other.y as i64 + other.height as i64
            && (other.y as i64) < self.y as i64 + self.height as i64
    }
}

/// Conservative rectangle coverage by higher opaque desktop windows, including
/// unions of covers. This is an observation hint, never an input hit test.
pub fn covered(bounds: Rect, above: &[WindowInfo]) -> bool {
    if bounds.width <= 0 || bounds.height <= 0 {
        return false;
    }
    let mut remaining = vec![bounds];
    for w in above
        .iter()
        .filter(|w| w.visible && !w.minimized && w.opaque)
    {
        let mut next = vec![];
        for r in remaining {
            if !r.intersects(w.bounds) {
                next.push(r);
                continue;
            }
            let x = r.x.max(w.bounds.x);
            let y = r.y.max(w.bounds.y);
            let right =
                (r.x as i64 + r.width as i64).min(w.bounds.x as i64 + w.bounds.width as i64) as i32;
            let bottom = (r.y as i64 + r.height as i64)
                .min(w.bounds.y as i64 + w.bounds.height as i64) as i32;
            for piece in [
                Rect {
                    x: r.x,
                    y: r.y,
                    width: r.width,
                    height: y - r.y,
                },
                Rect {
                    x: r.x,
                    y: bottom,
                    width: r.width,
                    height: (r.y as i64 + r.height as i64 - bottom as i64) as i32,
                },
                Rect {
                    x: r.x,
                    y,
                    width: x - r.x,
                    height: bottom - y,
                },
                Rect {
                    x: right,
                    y,
                    width: (r.x as i64 + r.width as i64 - right as i64) as i32,
                    height: bottom - y,
                },
            ] {
                if piece.width > 0 && piece.height > 0 {
                    next.push(piece);
                }
            }
        }
        remaining = next;
        if remaining.is_empty() {
            return true;
        }
        // Pathological desktop geometry must not make observation unbounded.
        if remaining.len() > 4096 {
            return false;
        }
    }
    false
}

pub fn window_line(w: &WindowInfo, is_covered: bool, summary: bool) -> String {
    let status = if !w.visible {
        "hidden"
    } else if w.minimized {
        "minimized"
    } else if is_covered {
        "covered"
    } else {
        "visible"
    };
    format!(
        "Window{}: {} class={} hwnd={:x} {}\n",
        if summary { " summary" } else { "" },
        json!(w.title),
        json!(w.class_name),
        w.hwnd,
        status
    )
}

pub fn chromium_context(parent: bool, role: &str, class: &str, framework: &str) -> bool {
    parent
        || (role == "Document"
            && (framework.eq_ignore_ascii_case("Chrome") || class.starts_with("Chrome_")))
}

pub fn outside_chromium(chromium: bool, bounds: Rect, client: Option<Rect>) -> bool {
    chromium && client.is_some_and(|r| r.width > 0 && r.height > 0 && !bounds.intersects(r))
}

pub fn omitted_line(count: usize) -> String {
    if count == 0 {
        String::new()
    } else {
        format!("Chromium: {count} elements outside the visible client area omitted; scrolling reveals them.\n")
    }
}

/// Snapshot-local UIA runtime identities; labels/bounds are never identity keys.
#[derive(Default)]
pub struct ElementIdentities(std::collections::HashMap<Vec<i32>, usize>);
impl ElementIdentities {
    pub fn index(&self, id: &[i32]) -> Option<usize> {
        self.0.get(id).copied()
    }
    pub fn remember(&mut self, id: Vec<i32>, index: usize) {
        if !id.is_empty() {
            self.0.entry(id).or_insert(index);
        }
    }
}
pub fn hidden_windows_line(count: usize) -> String {
    if count == 0 {
        String::new()
    } else {
        format!("Hidden windows: {count} (summaries omitted).\n")
    }
}

/// Omit only the node, never its descendants; focus must remain observable.
pub fn zero_size_omitted(bounds: Rect, focused: bool) -> bool {
    !focused && (bounds.width <= 0 || bounds.height <= 0)
}
pub fn zero_size_line(count: usize) -> String {
    if count == 0 { String::new() }
    else { format!("Zero-size: {count} elements omitted; descendants are still inspected.\n") }
}

/// Validate a retained object, never resolve an old index in a new tree.
/// Missing, detached, or unreadable roots all select the whole-window fallback.
pub fn live_scope<T>(retained: Option<T>, attached: impl FnOnce(&T) -> bool) -> Option<T> {
    retained.filter(attached)
}
pub fn scope_gone_line(requested: bool, live: bool) -> &'static str {
    if requested && !live { "Scope element is gone; showing the whole window.\n" } else { "" }
}

pub fn ime_warning(open: Option<usize>, conversion: Option<usize>) -> &'static str {
    if open.is_some_and(|v| v != 0) && conversion.is_some_and(|v| v & 1 != 0) {
        "IME: Native conversion mode is open; letter keys from press_key may go to the input method instead of the app. type_text and paste are unaffected.\n"
    } else { "" }
}
