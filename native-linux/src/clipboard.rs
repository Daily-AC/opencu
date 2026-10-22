//! Paste through the X CLIPBOARD selection. An owner thread serves the text
//! while Ctrl+V runs, then serves the previous contents again. X selections
//! live in the owning process: restored contents persist only while this
//! engine runs, unless a clipboard manager takes them over.
use opencu_engine::{Error, Result};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::*;
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

#[derive(Clone)]
pub struct Item {
    pub target: Atom,
    pub kind: Atom,
    pub format: u8,
    pub data: Vec<u8>,
}

const LIMIT: usize = 16 << 20;

fn err<E: std::fmt::Display>(e: E) -> Error { Error::new("CLIPBOARD_UNAVAILABLE", e.to_string()) }

fn atom(conn: &RustConnection, name: &str) -> Result<Atom> {
    Ok(conn.intern_atom(false, name.as_bytes()).map_err(err)?.reply().map_err(err)?.atom)
}

fn open() -> Result<(RustConnection, Window, Atom, Atom)> {
    let (conn, screen) = x11rb::connect(None).map_err(err)?;
    let root = conn.setup().roots[screen].root;
    let window = conn.generate_id().map_err(err)?;
    conn.create_window(0, window, root, -10, -10, 1, 1, 0, WindowClass::INPUT_ONLY, 0,
        &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE)).map_err(err)?.check().map_err(err)?;
    let clipboard = atom(&conn, "CLIPBOARD")?;
    let property = atom(&conn, "OPENCU_SELECTION")?;
    Ok((conn, window, clipboard, property))
}

fn convert(conn: &RustConnection, window: Window, selection: Atom, target: Atom, property: Atom) -> Result<Option<Item>> {
    conn.convert_selection(window, selection, target, property, x11rb::CURRENT_TIME).map_err(err)?;
    conn.flush().map_err(err)?;
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        match conn.poll_for_event().map_err(err)? {
            Some(Event::SelectionNotify(e)) if e.requestor == window && e.target == target => {
                if e.property == x11rb::NONE { return Ok(None); }
                let reply = conn.get_property(true, window, property, AtomEnum::ANY, 0, (LIMIT / 4) as u32)
                    .map_err(err)?.reply().map_err(err)?;
                let incr = atom(conn, "INCR")?;
                if reply.type_ == incr || reply.bytes_after > 0 {
                    return Err(Error::new("CLIPBOARD_UNAVAILABLE", "The current clipboard is too large to preserve; nothing was pasted."));
                }
                return Ok(Some(Item { target, kind: reply.type_, format: reply.format, data: reply.value }));
            }
            Some(_) => {}
            None if Instant::now() >= deadline => {
                return Err(Error::new("CLIPBOARD_UNAVAILABLE", "The clipboard owner did not answer; nothing was pasted."));
            }
            None => std::thread::sleep(Duration::from_millis(5)),
        }
    }
}

/// The current CLIPBOARD contents, all readable targets, or None if unowned.
pub fn read_current() -> Result<Option<Vec<Item>>> {
    let (conn, window, clipboard, property) = open()?;
    let owner = conn.get_selection_owner(clipboard).map_err(err)?.reply().map_err(err)?.owner;
    if owner == x11rb::NONE { return Ok(None); }
    let targets_atom = atom(&conn, "TARGETS")?;
    let targets = convert(&conn, window, clipboard, targets_atom, property)?
        .ok_or_else(|| Error::new("CLIPBOARD_UNAVAILABLE", "The clipboard owner lists no formats; nothing was pasted."))?;
    let mut skip = vec![targets_atom];
    for name in ["MULTIPLE", "TIMESTAMP", "SAVE_TARGETS", "DELETE", "INSERT_SELECTION", "INSERT_PROPERTY"] { skip.push(atom(&conn, name)?); }
    let mut items = vec![];
    let mut total = 0;
    for target in targets.data.chunks_exact(4).map(|c| u32::from_ne_bytes(c.try_into().unwrap())) {
        if skip.contains(&target) || items.iter().any(|i: &Item| i.target == target) { continue; }
        if let Some(item) = convert(&conn, window, clipboard, target, property)? {
            total += item.data.len();
            if total > LIMIT {
                return Err(Error::new("CLIPBOARD_UNAVAILABLE", "The current clipboard is larger than 16 MiB; nothing was pasted."));
            }
            items.push(item);
        }
    }
    let _ = conn.destroy_window(window);
    Ok(Some(items))
}

#[derive(Default)]
struct Shared {
    content: Vec<Item>,
    owned: bool,
    served: u64,
}

enum Command {
    Own(Vec<Item>, Sender<Result<()>>),
    Disown(Sender<()>),
}

pub struct Owner {
    shared: Arc<Mutex<Shared>>,
    commands: Sender<Command>,
    pub utf8: Atom,
    pub text_targets: Vec<Atom>,
}

impl Owner {
    pub fn start() -> Result<Self> {
        let (conn, window, clipboard, _) = open()?;
        let utf8 = atom(&conn, "UTF8_STRING")?;
        let mut text_targets = vec![utf8];
        for name in ["STRING", "TEXT", "text/plain;charset=utf-8", "text/plain"] { text_targets.push(atom(&conn, name)?); }
        let targets = atom(&conn, "TARGETS")?;
        let shared = Arc::new(Mutex::new(Shared::default()));
        let (commands, receive) = channel::<Command>();
        let state = shared.clone();
        std::thread::Builder::new().name("opencu-clipboard".into()).spawn(move || loop {
            while let Ok(Some(event)) = conn.poll_for_event() {
                match event {
                    Event::SelectionRequest(e) if e.selection == clipboard => {
                        let property = if e.property == x11rb::NONE { e.target } else { e.property };
                        let mut s = state.lock().unwrap();
                        let ok = if !s.owned { false } else if e.target == targets {
                            let mut list: Vec<u32> = s.content.iter().map(|i| i.target).collect();
                            list.push(targets);
                            conn.change_property32(PropMode::REPLACE, e.requestor, property, AtomEnum::ATOM, &list).is_ok()
                        } else if let Some(item) = s.content.iter().find(|i| i.target == e.target) {
                            let sent = conn.change_property(PropMode::REPLACE, e.requestor, property, item.kind, item.format,
                                (item.data.len() / (item.format.max(8) as usize / 8)) as u32, &item.data).is_ok();
                            if sent { s.served += 1; }
                            sent
                        } else { false };
                        let notify = SelectionNotifyEvent {
                            response_type: SELECTION_NOTIFY_EVENT, sequence: 0, time: e.time, requestor: e.requestor,
                            selection: e.selection, target: e.target, property: if ok { property } else { x11rb::NONE },
                        };
                        let _ = conn.send_event(false, e.requestor, EventMask::NO_EVENT, notify);
                        let _ = conn.flush();
                    }
                    Event::SelectionClear(e) if e.selection == clipboard => {
                        let mut s = state.lock().unwrap();
                        s.owned = false;
                        s.content.clear();
                    }
                    _ => {}
                }
            }
            match receive.recv_timeout(Duration::from_millis(5)) {
                Ok(Command::Own(items, reply)) => {
                    let result = conn.set_selection_owner(window, clipboard, x11rb::CURRENT_TIME).map_err(err)
                        .and_then(|_| conn.get_selection_owner(clipboard).map_err(err))
                        .and_then(|c| c.reply().map_err(err))
                        .and_then(|r| if r.owner == window { Ok(()) } else {
                            Err(Error::new("CLIPBOARD_UNAVAILABLE", "Another program kept the clipboard; nothing was pasted."))
                        });
                    if result.is_ok() {
                        let mut s = state.lock().unwrap();
                        s.content = items;
                        s.owned = true;
                    }
                    let _ = reply.send(result);
                }
                Ok(Command::Disown(reply)) => {
                    let mut s = state.lock().unwrap();
                    if s.owned {
                        let _ = conn.set_selection_owner(x11rb::NONE, clipboard, x11rb::CURRENT_TIME);
                        let _ = conn.flush();
                    }
                    s.owned = false;
                    s.content.clear();
                    let _ = reply.send(());
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(_) => return,
            }
        }).map_err(err)?;
        Ok(Self { shared, commands, utf8, text_targets })
    }

    pub fn own(&self, items: Vec<Item>) -> Result<()> {
        let (tx, rx) = channel();
        self.commands.send(Command::Own(items, tx)).map_err(err)?;
        rx.recv_timeout(Duration::from_secs(2)).map_err(err)?
    }

    pub fn disown(&self) {
        let (tx, rx) = channel();
        if self.commands.send(Command::Disown(tx)).is_ok() { let _ = rx.recv_timeout(Duration::from_secs(2)); }
    }

    pub fn owned(&self) -> bool { self.shared.lock().unwrap().owned }
    pub fn served(&self) -> u64 { self.shared.lock().unwrap().served }
    pub fn content(&self) -> Vec<Item> { self.shared.lock().unwrap().content.clone() }

    pub fn text_items(&self, text: &str) -> Vec<Item> {
        self.text_targets.iter().map(|t| Item { target: *t, kind: if *t == self.text_targets[1] { *t } else { self.utf8 }, format: 8, data: text.as_bytes().to_vec() }).collect()
    }
}
