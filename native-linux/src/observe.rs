//! Observation: choose the app's window, read its accessibility tree, format
//! indexed element lines and optionally capture the window.
use crate::a11y::{self, state, A11y, Budget, Node, ObjRef};
use crate::apps::App;
use crate::display::{Display, Kind, WindowInfo};
use opencu_engine::{Error, Rect, Result, Screenshot};
use serde_json::{json, Value};
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct Element {
    pub obj: ObjRef,
    pub role: String,
    pub name: String,
    pub bounds: Option<Rect>,
    /// Offset from the reported extents to root coordinates for this frame.
    pub offset: (i32, i32),
    pub actions: Vec<String>,
    pub editable: bool,
    pub value: bool,
    pub text: bool,
    pub window: u32,
}

pub struct Snapshot {
    pub app: App,
    pub window: WindowInfo,
    pub elements: Vec<Element>,
    pub image: Option<Screenshot>,
}

const STRUCTURAL: &[&str] = &[
    "filler", "panel", "section", "grouping", "scroll pane", "viewport", "layered pane", "root pane", "glass pane",
    "html container", "redundant object", "unknown", "invalid", "split pane", "form", "landmark", "table row",
    "block quote", "article", "tool bar", "status bar", "page tab list", "menu bar", "list", "tree", "table", "description list",
];
const DEFAULT_ACTIONS: &[&str] = &["click", "press", "activate", "jump", "toggle", "select", "invoke", "switch", "open", "showmenu", "expand or contract", "clickancestor", "dodefault", "showcontextmenu"];
const TOGGLES: &[&str] = &["check box", "toggle button", "radio button", "check menu item", "radio menu item", "switch"];

/// Pick the capture window: the app's active window, otherwise its topmost
/// visible non-tool window, then a visible tool window, then a minimized one.
pub fn primary(app: &App, active: Option<u32>) -> usize {
    let ws = &app.windows;
    let visible = |w: &WindowInfo| w.viewable && !w.hidden;
    if let Some(i) = ws.iter().position(|w| Some(w.id) == active && visible(w) && w.kind != Kind::Tool) { return i; }
    let top = |pred: &dyn Fn(&WindowInfo) -> bool| ws.iter().enumerate().filter(|(_, w)| pred(w)).max_by_key(|(_, w)| w.stack).map(|(i, _)| i);
    top(&|w| visible(w) && w.kind != Kind::Tool).or_else(|| top(&|w| visible(w))).or_else(|| top(&|_| true)).unwrap_or(0)
}

/// Windows transient for the primary window (its dialogs), recursively.
pub fn family(app: &App, primary: &WindowInfo) -> Vec<WindowInfo> {
    let mut out = vec![primary.clone()];
    let mut i = 0;
    while i < out.len() && out.len() < 16 {
        let owner = out[i].id;
        for w in &app.windows {
            if w.transient_for == Some(owner) && w.viewable && !out.iter().any(|o| o.id == w.id) { out.push(w.clone()); }
        }
        i += 1;
    }
    out
}

fn distance(a: Rect, b: Rect) -> i64 {
    ((a.x - b.x).abs() + (a.y - b.y).abs() + (a.width - b.width).abs() + (a.height - b.height).abs()) as i64
}

struct Frame { obj: ObjRef, name: String, states: u64, extents: Option<Rect> }

fn match_frame(window: &WindowInfo, frames: &[Frame], used: &[usize]) -> Option<usize> {
    let free: Vec<usize> = (0..frames.len()).filter(|i| !used.contains(i)).collect();
    let titled: Vec<usize> = free.iter().copied().filter(|i| !window.title.is_empty() && frames[*i].name == window.title).collect();
    let nearest = |set: &[usize]| set.iter().copied()
        .filter_map(|i| frames[i].extents.map(|e| (distance(e, window.client), i)))
        .min().map(|(_, i)| i);
    if titled.len() == 1 { return Some(titled[0]); }
    if titled.len() > 1 { return nearest(&titled).or(Some(titled[0])); }
    if let Some(i) = free.iter().copied().filter_map(|i| frames[i].extents.map(|e| (distance(e, window.client), i)))
        .filter(|(d, _)| *d < 200).min().map(|(_, i)| i) { return Some(i); }
    let showing: Vec<usize> = free.into_iter().filter(|i| frames[*i].states & (1 << state::SHOWING) != 0).collect();
    (showing.len() == 1).then(|| showing[0])
}

/// Actions of the element itself; Firefox gives every descendant of a
/// clickable element a `clickAncestor` action.
fn own_actions(node: &Node) -> bool {
    node.actions.iter().any(|a| !a.is_empty() && !["clickancestor", "showcontextmenu"].contains(&a.to_lowercase().as_str()))
        && !(STRUCTURAL.contains(&node.role.as_str()) && node.actions.iter().all(|a| ["dodefault", "showcontextmenu"].contains(&a.to_lowercase().as_str())))
}

fn toggle(node: &Node) -> Option<&'static str> {
    if !(node.has(state::CHECKABLE) || TOGGLES.contains(&node.role.as_str())) { return None; }
    Some(if node.has(state::INDETERMINATE) { "mixed" } else if node.has(state::CHECKED) || node.has(state::PRESSED) { "on" } else { "off" })
}

fn settable(node: &Node) -> bool {
    !node.has(state::READ_ONLY) && ((node.editable && node.has(state::EDITABLE))
        || node.range.is_some_and(|(_, min, max, _)| max > min))
}

fn listed(node: &Node) -> bool {
    if node.depth == 0 { return true; }
    if !node.has(state::SHOWING) && !node.has(state::FOCUSED) { return false; }
    if node.bounds.is_some_and(|b| b.width <= 0 || b.height <= 0) && !node.has(state::FOCUSED) { return false; }
    let interesting = !node.name.is_empty() || node.content.is_some() || node.has(state::FOCUSED)
        || node.has(state::FOCUSABLE) || node.has(state::SELECTABLE) || node.has(state::EXPANDABLE)
        || toggle(node).is_some() || settable(node) || node.range.is_some()
        || node.actions.iter().any(|a| !a.is_empty() && !DEFAULT_ACTIONS.contains(&a.to_lowercase().as_str()));
    if STRUCTURAL.contains(&node.role.as_str()) || node.role == "separator" { return interesting; }
    if ["image", "icon", "label", "static", "text", "paragraph", "heading", "caption"].contains(&node.role.as_str()) {
        return interesting || own_actions(node);
    }
    interesting || own_actions(node) || !node.description.is_empty()
}

pub fn line(node: &Node, index: usize, depth: usize, offset: (i32, i32)) -> String {
    let mut line = format!("{}[{index}] {}", "  ".repeat(depth.min(40)), a11y::role_label(&node.role));
    if !node.name.is_empty() { line += &format!(" title={}", json!(node.name)); }
    else if !node.description.is_empty() { line += &format!(" description={}", json!(node.description)); }
    let actionable = own_actions(node) || node.editable;
    if let Some(b) = node.bounds.filter(|_| node.name.is_empty() || !actionable
        || ["slider", "scroll bar", "spin button", "terminal", "canvas", "drawing area"].contains(&node.role.as_str())
        || node.role.starts_with("document")) {
        line += &format!(" bounds=({},{},{},{})", b.x + offset.0, b.y + offset.1, b.width, b.height);
    }
    if let Some(text) = &node.content { line += &format!(" value={}", json!(text)); }
    else if let Some((current, _, _, _)) = node.range { line += &format!(" value={current}"); }
    if (actionable || node.has(state::FOCUSABLE)) && !node.has(state::ENABLED) && !node.has(state::SENSITIVE) { line += " disabled"; }
    if settable(node) { line += " settable"; }
    if node.has(state::FOCUSED) { line += " focused"; }
    if let Some(t) = toggle(node) { line += &format!(" toggle={t}"); }
    if node.has(state::SELECTABLE) { line += &format!(" selected={}", node.has(state::SELECTED)); }
    if node.has(state::EXPANDABLE) { line += &format!(" expanded={}", node.has(state::EXPANDED)); }
    if let Some((_, min, max, step)) = node.range { line += &format!(" range=({min},{max}) step={step}"); }
    let named: Vec<&String> = node.actions.iter().filter(|a| !a.is_empty()).collect();
    if named.iter().any(|a| !DEFAULT_ACTIONS.contains(&a.to_lowercase().as_str())) {
        line += &format!(" actions={}", json!(named));
    }
    line
}

pub struct Observer<'a> {
    pub display: &'a Display,
    pub a11y: Option<&'a A11y>,
    pub a11y_error: Option<&'a Error>,
}

impl Observer<'_> {
    pub fn observe(&self, mut app: App, include_screenshot: bool) -> Result<(Value, Snapshot)> {
        if app.windows.is_empty() { return Err(Error::new("NO_ACCESSIBLE_WINDOW", "The app has no visible window.")); }
        let index = primary(&app, self.display.active_window());
        let window = app.windows.remove(index);
        app.windows.insert(0, window.clone());
        let windows = family(&app, &window);
        let mut text = format!("App: {} ({})\nWindow: {}\nLinux input requires foreground focus.\nCapture target: window=0x{:x} class={} (active window of the app, otherwise topmost visible window).\n",
            app.name, app.id, json!(window.title), window.id, json!(window.class));
        if window.hidden { text += "The window is minimized; input activates it first.\n"; }
        let mut elements = vec![];
        let mut omitted = 0usize;
        let mut notes = vec![];
        match (self.a11y, self.a11y_error) {
            (Some(a11y), _) => self.tree(a11y, &app, &windows, &mut text, &mut elements, &mut omitted, &mut notes),
            (None, Some(e)) => notes.push(format!("Accessibility unavailable: {}: {}. Use a screenshot and coordinates.", e.code, e.message)),
            (None, None) => notes.push("Accessibility unavailable. Use a screenshot and coordinates.".into()),
        }
        if omitted > 0 { text += &format!("Offscreen: {omitted} elements are not showing (scrolled away, hidden or in closed menus); scroll or open them to reveal.\n"); }
        for note in notes { text += &note; text.push('\n'); }
        for w in app.windows.iter().filter(|w| !windows.iter().any(|f| f.id == w.id)) {
            text += &format!("Window summary: {}\n", w.summary(if w.hidden { "minimized" } else { "visible" }));
        }
        let mut snapshot = Snapshot { app: app.clone(), window: window.clone(), elements, image: None };
        let mut result = json!({"text": text, "app": app.json()});
        if include_screenshot {
            match self.display.capture(&window) {
                Ok((png, width, height, bounds)) => {
                    if self.display.root_rect(window.frame) != Some(bounds) {
                        return Err(Error::new("WINDOW_CHANGED", "Window moved or resized during capture; read state again"));
                    }
                    snapshot.image = Some(Screenshot { bounds, width, height, dpi: 96 });
                    result["screenshot"] = json!({"data": opencu_engine::base64(&png), "mimeType": "image/png", "width": width, "height": height});
                    result["text"] = json!(format!("{text}Screenshot: {width} x {height} pixels; window origin ({},{}).\n", bounds.x, bounds.y));
                }
                Err(e) => result["text"] = json!(format!("{text}Screenshot unavailable: {}: {}\n", e.code, e.message)),
            }
        }
        Ok((result, snapshot))
    }

    #[allow(clippy::too_many_arguments)]
    fn tree(&self, a11y: &A11y, app: &App, windows: &[WindowInfo], text: &mut String, elements: &mut Vec<Element>, omitted: &mut usize, notes: &mut Vec<String>) {
        let roots = match a11y.applications(app.pid) {
            Ok(roots) if !roots.is_empty() => roots,
            Ok(_) => { notes.push("Accessibility tree unavailable: the app is not registered on the accessibility bus. Use a screenshot and coordinates.".into()); return; }
            Err(e) => { notes.push(format!("Accessibility tree unavailable: {}: {}", e.code, e.message)); return; }
        };
        let mut frames = vec![];
        for root in &roots {
            for child in a11y.children(root).unwrap_or_default() {
                if let Some((role, name, states, extents)) = a11y.frame(&child) {
                    if role == "tool tip" { continue; }
                    frames.push(Frame { obj: child, name, states, extents });
                }
            }
        }
        let mut used = vec![];
        let mut pairs = vec![];
        for w in windows {
            match match_frame(w, &frames, &used) {
                Some(i) => { used.push(i); pairs.push((w.clone(), i)); }
                None if w.id == windows[0].id => {
                    notes.push("Accessibility tree unavailable for this window: no matching accessible frame. Use a screenshot and coordinates.".into());
                    return;
                }
                None => {}
            }
        }
        let budget = Budget { nodes: 8000, depth: 120, deadline: Instant::now() + Duration::from_secs(8) };
        let objs: Vec<ObjRef> = pairs.iter().map(|(_, i)| frames[*i].obj.clone()).collect();
        let tree = a11y.tree(&objs, &budget);
        let mut listed_count = 0usize;
        let mut bytes = text.len();
        let mut capped = false;
        for (root_pos, root) in tree.roots.iter().enumerate() {
            let (window, frame) = &pairs[root_pos.min(pairs.len() - 1)];
            // Some toolkits report frame-relative "screen" extents; shift them
            // by the difference to the X client window when the sizes agree.
            let offset = frames[*frame].extents.filter(|e| (e.width - window.client.width).abs() < 8 && (e.height - window.client.height).abs() < 8)
                .map(|e| (window.client.x - e.x, window.client.y - e.y)).filter(|(dx, dy)| dx.abs() > 2 || dy.abs() > 2).unwrap_or((0, 0));
            let mut stack = vec![(*root, 0usize)];
            while let Some((i, depth)) = stack.pop() {
                let node = &tree.nodes[i];
                let show = listed(node);
                if !show && !node.has(state::SHOWING) && node.depth > 0 { *omitted += 1; }
                if show {
                    if listed_count >= 1200 || bytes >= 180_000 { capped = true; break; }
                    listed_count += 1;
                    let l = line(node, elements.len() + 1, depth, offset);
                    bytes += l.len() + 1;
                    text.push_str(&l);
                    text.push('\n');
                    elements.push(Element {
                        obj: node.obj.clone().unwrap(), role: node.role.clone(), name: node.name.clone(),
                        bounds: node.bounds, offset, actions: node.actions.clone(), editable: node.editable && node.has(state::EDITABLE),
                        value: node.range.is_some(), text: node.text, window: window.id,
                    });
                }
                for child in node.children.iter().rev() { stack.push((*child, depth + usize::from(show))); }
            }
            if capped { break; }
        }
        if capped || tree.truncated.is_some() {
            notes.push(format!("Tree truncated ({}): limit 1200 listed / 8000 inspected nodes, depth 120, 180000 bytes, or 8 seconds.",
                tree.truncated.as_deref().unwrap_or("listing limit")));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn node(role: &str, name: &str, states: &[u32]) -> Node {
        let mut n = Node { role: role.into(), name: name.into(), depth: 1, ..Default::default() };
        for s in states { n.states |= 1u64 << s; }
        n
    }
    #[test]
    fn structural_containers_are_omitted_but_controls_kept() {
        assert!(!listed(&node("panel", "", &[state::SHOWING, state::VISIBLE])));
        assert!(listed(&node("push button", "OK", &[state::SHOWING])));
        assert!(!listed(&node("push button", "Hidden", &[state::VISIBLE])));
        let mut text = node("paragraph", "", &[state::SHOWING]);
        text.content = Some("Hello".into());
        assert!(listed(&text));
    }
    #[test]
    fn lines_show_state_and_value() {
        let mut n = node("check box", "Bold", &[state::SHOWING, state::ENABLED, state::CHECKED, state::FOCUSED]);
        n.actions = vec!["toggle".into()];
        assert_eq!(line(&n, 3, 1, (0, 0)), "  [3] CheckBox title=\"Bold\" focused toggle=on");
        let mut e = node("entry", "", &[state::SHOWING, state::ENABLED, state::EDITABLE]);
        e.editable = true;
        e.content = Some("abc".into());
        e.bounds = Some(Rect { x: 1, y: 2, width: 30, height: 10 });
        assert_eq!(line(&e, 1, 0, (5, 0)), "[1] Entry bounds=(6,2,30,10) value=\"abc\" settable");
    }
    #[test]
    fn frame_matching_prefers_title_then_geometry() {
        let w = WindowInfo { id: 1, frame: 1, pid: Some(1), title: "Doc - Editor".into(), instance: "e".into(), class: "E".into(),
            client: Rect { x: 10, y: 40, width: 800, height: 600 }, rect: Rect { x: 10, y: 10, width: 800, height: 630 },
            viewable: true, hidden: false, kind: Kind::Normal, transient_for: None, stack: 0 };
        let f = |name: &str, x| Frame { obj: ObjRef { bus: ":1.1".into(), path: format!("/{name}") }, name: name.into(), states: 0,
            extents: Some(Rect { x, y: 40, width: 800, height: 600 }) };
        assert_eq!(match_frame(&w, &[f("Other", 10), f("Doc - Editor", 900)], &[]), Some(1));
        assert_eq!(match_frame(&w, &[f("Other", 500), f("Else", 12)], &[]), Some(1));
    }
}
