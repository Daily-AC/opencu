//! AT-SPI2 accessibility over D-Bus.
//!
//! Only explicit `Properties.Get` calls are used: Qt5's bridge crashes on a
//! one-argument `GetAll`. Every call has a two-second timeout and a tree read
//! has an overall budget, so an unresponsive application cannot hang a read.
use crate::session::SessionEnv;
use futures_util::future::{join, join3, join5, join_all};
use opencu_engine::{Error, Rect, Result};
use serde::de::DeserializeOwned;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use zbus::zvariant::{DynamicType, OwnedObjectPath, OwnedValue, Type, Value};
use zbus::Connection;

pub const ACCESSIBLE: &str = "org.a11y.atspi.Accessible";
const COMPONENT: &str = "org.a11y.atspi.Component";
const ACTION: &str = "org.a11y.atspi.Action";
const TEXT: &str = "org.a11y.atspi.Text";
const EDITABLE: &str = "org.a11y.atspi.EditableText";
const VALUE: &str = "org.a11y.atspi.Value";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";

pub mod state {
    pub const ACTIVE: u32 = 1;
    pub const CHECKED: u32 = 4;
    pub const DEFUNCT: u32 = 6;
    pub const EDITABLE: u32 = 7;
    pub const ENABLED: u32 = 8;
    pub const EXPANDABLE: u32 = 9;
    pub const EXPANDED: u32 = 10;
    pub const FOCUSABLE: u32 = 11;
    pub const FOCUSED: u32 = 12;
    pub const MULTI_LINE: u32 = 17;
    pub const PRESSED: u32 = 20;
    pub const SELECTABLE: u32 = 22;
    pub const SELECTED: u32 = 23;
    pub const SENSITIVE: u32 = 24;
    pub const SHOWING: u32 = 25;
    pub const VISIBLE: u32 = 30;
    pub const MANAGES_DESCENDANTS: u32 = 31;
    pub const INDETERMINATE: u32 = 32;
    pub const CHECKABLE: u32 = 41;
    pub const READ_ONLY: u32 = 43;
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ObjRef {
    pub bus: String,
    pub path: String,
}

#[derive(Debug, Clone, Default)]
pub struct Node {
    pub obj: Option<ObjRef>,
    pub role: String,
    pub name: String,
    pub description: String,
    pub states: u64,
    pub component: bool,
    pub action: bool,
    pub text: bool,
    pub editable: bool,
    pub value: bool,
    pub child_count: i32,
    pub children: Vec<usize>,
    pub bounds: Option<Rect>,
    pub actions: Vec<String>,
    pub content: Option<String>,
    pub range: Option<(f64, f64, f64, f64)>,
    pub depth: usize,
}

impl Node {
    pub fn has(&self, bit: u32) -> bool {
        self.states & (1u64 << bit) != 0
    }
}

pub struct Tree {
    pub nodes: Vec<Node>,
    pub roots: Vec<usize>,
    pub inspected: usize,
    pub truncated: Option<String>,
}

pub struct Budget {
    pub nodes: usize,
    pub depth: usize,
    pub deadline: Instant,
}

pub struct A11y {
    conn: Connection,
    session: Option<Connection>,
    restore: bool,
    pub via: String,
    pids: Mutex<HashMap<String, Option<u32>>>,
}

fn dbus_error(e: zbus::Error) -> Error {
    let text = e.to_string();
    if text.contains("UnknownObject") || text.contains("UnknownMethod") || text.contains("ServiceUnknown") || text.contains("NoReply") && text.contains("disconnected") {
        Error::new("STALE_ELEMENT", format!("The accessible element is no longer available: {text}"))
    } else if text.contains("Timeout") || text.contains("timed out") || text.contains("NoReply") {
        Error::new("A11Y_TIMEOUT", format!("The application did not answer an accessibility call in time: {text}"))
    } else {
        Error::new("A11Y_ERROR", text)
    }
}

/// Role names become PascalCase words such as `PushButton`.
pub fn role_label(role: &str) -> String {
    role.split(|c: char| c == ' ' || c == '_' || c == '-')
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut chars = w.chars();
            chars.next().map(|c| c.to_uppercase().collect::<String>() + chars.as_str()).unwrap_or_default()
        })
        .collect()
}

impl A11y {
    pub fn connect(env: &SessionEnv, root_property: Option<String>) -> Result<Self> {
        zbus::block_on(async {
            let session_address = env.get("DBUS_SESSION_BUS_ADDRESS");
            let session = match &session_address {
                Some(address) => match zbus::connection::Builder::address(address.as_str()) {
                    Ok(builder) => builder.method_timeout(Duration::from_secs(2)).build().await.ok(),
                    Err(_) => None,
                },
                None => None,
            };
            let mut via = String::new();
            let mut address = env.get("AT_SPI_BUS_ADDRESS").filter(|a| !a.is_empty());
            if address.is_some() { via = "AT_SPI_BUS_ADDRESS".into(); }
            if address.is_none() {
                if let Some(value) = root_property.filter(|a| !a.is_empty()) { address = Some(value); via = "X root AT_SPI_BUS".into(); }
            }
            if address.is_none() {
                if let Some(session) = &session {
                    if let Ok(reply) = session.call_method(Some("org.a11y.Bus"), "/org/a11y/bus", Some("org.a11y.Bus"), "GetAddress", &()).await {
                        address = reply.body().deserialize::<String>().ok();
                        via = "org.a11y.Bus.GetAddress".into();
                    }
                }
            }
            let address = address.ok_or_else(|| Error::new("A11Y_UNAVAILABLE", if session.is_none() {
                "No accessibility bus was found and no D-Bus session bus is reachable. Run the desktop session with at-spi2-core (dbus-launch starts it)."
            } else {
                "The session has no accessibility bus (org.a11y.Bus). Install at-spi2-core in the desktop."
            }))?;
            let conn = zbus::connection::Builder::address(address.as_str()).map_err(dbus_error)?
                .method_timeout(Duration::from_secs(2)).build().await
                .map_err(|e| Error::new("A11Y_UNAVAILABLE", format!("Cannot connect to the accessibility bus: {e}")))?;
            // Toolkits build their trees only while assistive technology is
            // announced, as Orca does. Restore the previous value on exit.
            let mut restore = false;
            if let Some(session) = &session {
                let enabled = session.call_method(Some("org.a11y.Bus"), "/org/a11y/bus", Some(PROPERTIES), "Get", &("org.a11y.Status", "IsEnabled")).await
                    .ok().and_then(|r| r.body().deserialize::<OwnedValue>().ok()).and_then(|v| bool::try_from(v).ok());
                if enabled == Some(false) {
                    restore = session.call_method(Some("org.a11y.Bus"), "/org/a11y/bus", Some(PROPERTIES), "Set",
                        &("org.a11y.Status", "IsEnabled", Value::from(true))).await.is_ok();
                }
            }
            Ok(Self { conn, session, restore, via, pids: Mutex::new(HashMap::new()) })
        })
    }

    pub fn enabled_by_opencu(&self) -> bool { self.restore }

    async fn call<B, R>(&self, obj: &ObjRef, iface: &str, method: &str, body: &B) -> Result<R>
    where B: serde::Serialize + DynamicType, R: DeserializeOwned + Type {
        let reply = self.conn.call_method(Some(obj.bus.as_str()), obj.path.as_str(), Some(iface), method, body).await.map_err(dbus_error)?;
        reply.body().deserialize::<R>().map_err(dbus_error)
    }

    async fn prop<R: TryFrom<OwnedValue>>(&self, obj: &ObjRef, iface: &str, name: &str) -> Result<R> {
        let value: OwnedValue = self.call(obj, PROPERTIES, "Get", &(iface, name)).await?;
        R::try_from(value).map_err(|_| Error::new("A11Y_ERROR", format!("Unexpected type for {iface}.{name}")))
    }

    async fn pid_of(&self, bus: &str) -> Option<u32> {
        if let Some(pid) = self.pids.lock().unwrap().get(bus) { return *pid; }
        let pid = self.conn.call_method(Some("org.freedesktop.DBus"), "/org/freedesktop/DBus", Some("org.freedesktop.DBus"),
            "GetConnectionUnixProcessID", &(bus,)).await.ok().and_then(|r| r.body().deserialize::<u32>().ok());
        self.pids.lock().unwrap().insert(bus.to_owned(), pid);
        pid
    }

    /// Registered applications whose connection belongs to `pid`. An empty
    /// placeholder registered before the real one is ordered last.
    pub fn applications(&self, pid: u32) -> Result<Vec<ObjRef>> {
        zbus::block_on(async {
            let root = ObjRef { bus: "org.a11y.atspi.Registry".into(), path: "/org/a11y/atspi/accessible/root".into() };
            let apps: Vec<(String, OwnedObjectPath)> = self.call(&root, ACCESSIBLE, "GetChildren", &()).await?;
            let mut matched = vec![];
            for (bus, path) in apps {
                if self.pid_of(&bus).await == Some(pid) {
                    let obj = ObjRef { bus, path: path.as_str().to_owned() };
                    let count: i32 = self.prop(&obj, ACCESSIBLE, "ChildCount").await.unwrap_or(0);
                    matched.push((count, obj));
                }
            }
            matched.sort_by_key(|(count, _)| std::cmp::Reverse(*count > 0));
            Ok(matched.into_iter().map(|(_, o)| o).collect())
        })
    }

    pub fn children(&self, obj: &ObjRef) -> Result<Vec<ObjRef>> {
        zbus::block_on(async {
            let children: Vec<(String, OwnedObjectPath)> = self.call(obj, ACCESSIBLE, "GetChildren", &()).await?;
            Ok(children.into_iter().map(|(bus, path)| ObjRef { bus, path: path.as_str().to_owned() }).collect())
        })
    }

    /// A top-level frame's role, name, states and screen extents.
    pub fn frame(&self, obj: &ObjRef) -> Option<(String, String, u64, Option<Rect>)> {
        zbus::block_on(async {
            let (role, name, states, extents) = {
                let (a, b) = join(self.call::<_, String>(obj, ACCESSIBLE, "GetRoleName", &()), self.prop::<String>(obj, ACCESSIBLE, "Name")).await;
                let (c, d) = join(self.call::<_, Vec<u32>>(obj, ACCESSIBLE, "GetState", &()), self.call::<_, (i32, i32, i32, i32)>(obj, COMPONENT, "GetExtents", &(0u32,))).await;
                (a.ok()?, b.unwrap_or_default(), c.ok()?, d.ok())
            };
            Some((role, name, bits(&states), extents.map(|(x, y, width, height)| Rect { x, y, width, height })))
        })
    }

    async fn info(&self, obj: ObjRef, depth: usize) -> std::result::Result<Node, bool> {
        let (role, name, st, ifaces, count) = join5(
            self.call::<_, String>(&obj, ACCESSIBLE, "GetRoleName", &()),
            self.prop::<String>(&obj, ACCESSIBLE, "Name"),
            self.call::<_, Vec<u32>>(&obj, ACCESSIBLE, "GetState", &()),
            self.call::<_, Vec<String>>(&obj, ACCESSIBLE, "GetInterfaces", &()),
            self.prop::<i32>(&obj, ACCESSIBLE, "ChildCount"),
        ).await;
        let timed_out = |r: &Result<String>| r.as_ref().err().is_some_and(|e| e.code == "A11Y_TIMEOUT");
        if timed_out(&role) { return Err(true); }
        let Ok(role) = role else { return Err(false) };
        let interfaces = ifaces.unwrap_or_default();
        let mut node = Node {
            role,
            name: name.unwrap_or_default().trim().to_owned(),
            states: st.map(|s| bits(&s)).unwrap_or(0),
            component: interfaces.iter().any(|i| i == COMPONENT),
            action: interfaces.iter().any(|i| i == ACTION),
            text: interfaces.iter().any(|i| i == TEXT),
            editable: interfaces.iter().any(|i| i == EDITABLE),
            value: interfaces.iter().any(|i| i == VALUE),
            child_count: count.unwrap_or(0).max(0),
            depth,
            ..Default::default()
        };
        if node.has(state::DEFUNCT) { return Err(false); }
        let showing = node.has(state::SHOWING) || depth == 0;
        let password = node.role == "password text";
        let wants_text = node.text && !password && showing && wants_content(&node);
        let extents = async {
            if node.component && showing { self.call::<_, (i32, i32, i32, i32)>(&obj, COMPONENT, "GetExtents", &(0u32,)).await.ok() } else { None }
        };
        let actions = async {
            if node.action && showing { self.action_names(&obj).await.ok() } else { None }
        };
        let content = async {
            if !wants_text { return None; }
            let length: i32 = self.prop(&obj, TEXT, "CharacterCount").await.ok()?;
            let terminal = node.role == "terminal";
            let limit = if terminal || node.has(state::EDITABLE) { 4000 } else { 600 };
            let (start, end) = if terminal { ((length - limit).max(0), length) } else { (0, length.min(limit)) };
            let text: String = self.call(&obj, TEXT, "GetText", &(start, end)).await.ok()?;
            Some(display_text(&text, terminal, (length - (end - start)).max(0) as usize))
        };
        let (bounds, (acts, text), range) = join3(extents, join(actions, content), async {
            if !node.value || !showing { return None; }
            let (c, a, b, i) = futures_util::future::join4(
                self.prop::<f64>(&obj, VALUE, "CurrentValue"), self.prop::<f64>(&obj, VALUE, "MinimumValue"),
                self.prop::<f64>(&obj, VALUE, "MaximumValue"), self.prop::<f64>(&obj, VALUE, "MinimumIncrement")).await;
            Some((c.ok()?, a.unwrap_or(0.0), b.unwrap_or(0.0), i.unwrap_or(0.0)))
        }).await;
        node.bounds = bounds.map(|(x, y, width, height)| Rect { x, y, width, height });
        node.actions = acts.unwrap_or_default();
        node.content = text.filter(|t| !t.is_empty());
        node.range = range;
        if node.name.is_empty() && (node.action || node.has(state::FOCUSABLE)) {
            node.description = self.prop::<String>(&obj, ACCESSIBLE, "Description").await.unwrap_or_default().trim().to_owned();
        }
        node.obj = Some(obj);
        Ok(node)
    }

    async fn child_refs(&self, node: &Node) -> Result<(Vec<ObjRef>, bool)> {
        let obj = node.obj.as_ref().unwrap();
        if node.child_count as usize > 2048 || node.has(state::MANAGES_DESCENDANTS) && node.child_count > 400 {
            // Huge lazy containers (spreadsheets, long lists): read the first rows only.
            let refs = join_all((0..node.child_count.min(200)).map(|i| async move { self.call::<_, (String, OwnedObjectPath)>(obj, ACCESSIBLE, "GetChildAtIndex", &(i,)).await })).await;
            return Ok((refs.into_iter().flatten().map(|(bus, path)| ObjRef { bus, path: path.as_str().to_owned() }).collect(), true));
        }
        let children: Vec<(String, OwnedObjectPath)> = self.call(obj, ACCESSIBLE, "GetChildren", &()).await?;
        Ok((children.into_iter().map(|(bus, path)| ObjRef { bus, path: path.as_str().to_owned() }).collect(), false))
    }

    /// Breadth-first read with pipelined calls, then the caller prints it in tree order.
    pub fn tree(&self, roots: &[ObjRef], budget: &Budget) -> Tree {
        zbus::block_on(async {
            let mut tree = Tree { nodes: vec![], roots: vec![], inspected: 0, truncated: None };
            let mut timeouts = 0;
            let mut level = vec![];
            for (root, info) in roots.iter().zip(join_all(roots.iter().map(|r| self.info(r.clone(), 0))).await) {
                let _ = root;
                if let Ok(node) = info {
                    tree.roots.push(tree.nodes.len());
                    level.push(tree.nodes.len());
                    tree.nodes.push(node);
                }
            }
            while !level.is_empty() {
                let expand: Vec<usize> = level.iter().copied().filter(|i| {
                    let n = &tree.nodes[*i];
                    n.child_count > 0 && (n.has(state::SHOWING) || n.depth == 0) && n.depth < budget.depth
                }).collect();
                let mut next = vec![];
                for chunk in expand.chunks(48) {
                    if Instant::now() >= budget.deadline { tree.truncated.get_or_insert("time budget".into()); break; }
                    let refs = join_all(chunk.iter().map(|i| self.child_refs(&tree.nodes[*i]))).await;
                    let mut pending = vec![];
                    for (parent, result) in chunk.iter().zip(refs) {
                        match result {
                            Ok((children, partial)) => {
                                if partial { tree.truncated.get_or_insert("a container with too many children shows its first 200".into()); }
                                pending.extend(children.into_iter().map(|c| (*parent, c)));
                            }
                            Err(e) if e.code == "A11Y_TIMEOUT" => timeouts += 1,
                            Err(_) => {}
                        }
                    }
                    for batch in pending.chunks(64) {
                        if tree.inspected >= budget.nodes { tree.truncated.get_or_insert("node limit".into()); break; }
                        if Instant::now() >= budget.deadline { tree.truncated.get_or_insert("time budget".into()); break; }
                        if timeouts >= 3 { tree.truncated.get_or_insert("the application stopped answering".into()); break; }
                        let infos = join_all(batch.iter().map(|(parent, obj)| self.info(obj.clone(), tree.nodes[*parent].depth + 1))).await;
                        for ((parent, _), info) in batch.iter().zip(infos) {
                            tree.inspected += 1;
                            match info {
                                Ok(node) => {
                                    let index = tree.nodes.len();
                                    tree.nodes.push(node);
                                    tree.nodes[*parent].children.push(index);
                                    next.push(index);
                                }
                                Err(true) => timeouts += 1,
                                Err(false) => {}
                            }
                        }
                    }
                    if tree.truncated.is_some() { break; }
                }
                if tree.truncated.is_some() { break; }
                level = next;
            }
            tree
        })
    }

    pub fn extents(&self, obj: &ObjRef) -> Result<Rect> {
        zbus::block_on(async {
            let (x, y, width, height): (i32, i32, i32, i32) = self.call(obj, COMPONENT, "GetExtents", &(0u32,)).await?;
            Ok(Rect { x, y, width, height })
        })
    }

    pub fn states(&self, obj: &ObjRef) -> Result<u64> {
        zbus::block_on(async { Ok(bits(&self.call::<_, Vec<u32>>(obj, ACCESSIBLE, "GetState", &()).await?)) })
    }

    /// Action names by position. Firefox's bridge returns placeholder text
    /// from GetActions, so names are read one by one.
    async fn action_names(&self, obj: &ObjRef) -> Result<Vec<String>> {
        let count: i32 = self.prop(obj, ACTION, "NActions").await?;
        let names = join_all((0..count.clamp(0, 32)).map(|i| async move {
            self.call::<_, String>(obj, ACTION, "GetName", &(i,)).await.unwrap_or_default()
        })).await;
        Ok(names)
    }

    pub fn actions(&self, obj: &ObjRef) -> Result<Vec<String>> {
        zbus::block_on(self.action_names(obj))
    }

    /// Returns Ok(Some(true/false)) when the app replied, Ok(None) on timeout.
    pub fn do_action(&self, obj: &ObjRef, index: i32) -> Result<Option<bool>> {
        zbus::block_on(async {
            match self.call::<_, bool>(obj, ACTION, "DoAction", &(index,)).await {
                Ok(done) => Ok(Some(done)),
                Err(e) if e.code == "A11Y_TIMEOUT" => Ok(None),
                Err(e) => Err(e),
            }
        })
    }

    pub fn set_text(&self, obj: &ObjRef, value: &str) -> Result<bool> {
        zbus::block_on(self.call::<_, bool>(obj, EDITABLE, "SetTextContents", &(value,)))
    }

    pub fn set_number(&self, obj: &ObjRef, value: f64) -> Result<()> {
        zbus::block_on(async {
            let _: () = self.call(obj, PROPERTIES, "Set", &(VALUE, "CurrentValue", Value::from(value))).await?;
            Ok(())
        })
    }

    pub fn text(&self, obj: &ObjRef) -> Result<String> {
        zbus::block_on(async {
            let length: i32 = self.prop(obj, TEXT, "CharacterCount").await?;
            self.call(obj, TEXT, "GetText", &(0i32, length)).await
        })
    }

    pub fn select(&self, obj: &ObjRef, start: i32, end: i32) -> Result<bool> {
        zbus::block_on(async {
            if start == end {
                return self.call::<_, bool>(obj, TEXT, "SetCaretOffset", &(start,)).await;
            }
            let count: i32 = self.call(obj, TEXT, "GetNSelections", &()).await.unwrap_or(0);
            if count > 0 { self.call::<_, bool>(obj, TEXT, "SetSelection", &(0i32, start, end)).await }
            else { self.call::<_, bool>(obj, TEXT, "AddSelection", &(start, end)).await }
        })
    }

    pub fn grab_focus(&self, obj: &ObjRef) -> Result<bool> {
        zbus::block_on(self.call::<_, bool>(obj, COMPONENT, "GrabFocus", &()))
    }

    pub fn close(&self) {
        if self.restore {
            if let Some(session) = &self.session {
                let _ = zbus::block_on(session.call_method(Some("org.a11y.Bus"), "/org/a11y/bus", Some(PROPERTIES), "Set",
                    &("org.a11y.Status", "IsEnabled", Value::from(false))));
            }
        }
    }
}

fn bits(states: &[u32]) -> u64 {
    states.first().copied().unwrap_or(0) as u64 | (states.get(1).copied().unwrap_or(0) as u64) << 32
}

/// Text worth showing: editable fields, terminals and unnamed text-bearing
/// leaves (paragraphs, labels, cells). Whole documents are read through their parts.
fn wants_content(node: &Node) -> bool {
    if node.role.starts_with("document") { return node.has(state::EDITABLE); }
    if node.has(state::EDITABLE) || node.role == "terminal" { return true; }
    node.name.is_empty() && !["frame", "window", "dialog", "application", "filler", "panel", "scroll pane", "viewport"].contains(&node.role.as_str())
}

/// Remove embedded-object characters and limit whitespace runs.
pub fn display_text(text: &str, terminal: bool, omitted: usize) -> String {
    let cleaned: String = text.chars().filter(|c| *c != '\u{fffc}').collect();
    let mut out = if terminal {
        let lines: Vec<&str> = cleaned.lines().map(|l| l.trim_end()).collect();
        let mut end = lines.len();
        while end > 0 && lines[end - 1].is_empty() { end -= 1; }
        lines[..end].join("\n")
    } else {
        cleaned.trim().to_owned()
    };
    if omitted > 0 {
        out = if terminal { format!("[{omitted} earlier characters omitted]\n{out}") } else { format!("{out} [{omitted} more characters]") };
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn role_labels_are_compact() {
        assert_eq!(role_label("push button"), "PushButton");
        assert_eq!(role_label("document web"), "DocumentWeb");
        assert_eq!(role_label("entry"), "Entry");
    }
    #[test]
    fn display_text_strips_embedded_objects_and_notes_omissions() {
        assert_eq!(display_text("a\u{fffc}b ", false, 0), "ab");
        assert_eq!(display_text("x", false, 5), "x [5 more characters]");
        assert_eq!(display_text("$ ls\nfile\n\n\n", true, 3), "[3 earlier characters omitted]\n$ ls\nfile");
    }
    #[test]
    fn state_bits_span_both_words() {
        let b = bits(&[1 << state::SHOWING, 1 << (state::READ_ONLY - 32)]);
        let node = Node { states: b, ..Default::default() };
        assert!(node.has(state::SHOWING) && node.has(state::READ_ONLY) && !node.has(state::FOCUSED));
    }
}
