//! Person-activity monitor. A dedicated X connection receives XInput2 raw
//! events for every device. Events from the XTEST slave devices are synthetic
//! (OpenCU's own input, or another client's XTest); any other device is a person,
//! for example the keyboard and pointer of a VNC viewer. Physical Escape latches
//! a stop for this engine connection.
use opencu_engine::{Error, Result};
use std::collections::BTreeSet;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::xinput::{self, ConnectionExt as _};
use x11rb::protocol::xproto::ConnectionExt as _;
use x11rb::protocol::screensaver::ConnectionExt as _;
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;

pub const IDLE_REQUIRED: Duration = Duration::from_secs(10);

#[derive(Default)]
struct State {
    last_person: Option<Instant>,
    stopped: bool,
    interrupted: bool,
    guarding: bool,
    devices: Vec<String>,
    failed: Option<String>,
}

pub struct Monitor {
    state: Arc<Mutex<State>>,
    fence: Sender<Sender<()>>,
}

pub fn user_stopped() -> Error {
    Error::new("USER_STOPPED", "The person pressed Escape on a physical keyboard. OpenCU input is disabled for this connection; do not reconnect or retry without their explicit permission.")
}

fn person_active() -> Error {
    Error::new("PERSON_ACTIVE", "Someone used the keyboard or mouse of this desktop during the call. Stop and ask the person before continuing; do not retry automatically. Earlier input in this call may have run.")
}

pub fn is_xtest_device(name: &str) -> bool {
    name.contains("XTEST")
}

impl Monitor {
    pub fn new() -> Result<Self> {
        let (conn, screen) = x11rb::connect(None)
            .map_err(|e| Error::new("SAFETY_MONITOR_UNAVAILABLE", format!("Cannot open the monitor X connection: {e}")))?;
        let root = conn.setup().roots[screen].root;
        let version = conn.xinput_xi_query_version(2, 2).ok().and_then(|c| c.reply().ok());
        if version.is_none_or(|v| v.major_version < 2) {
            return Err(Error::new("SAFETY_MONITOR_UNAVAILABLE", "The X server has no XInput 2; OpenCU cannot tell a person's input from its own."));
        }
        let raw = xinput::XIEventMask::RAW_KEY_PRESS | xinput::XIEventMask::RAW_BUTTON_PRESS | xinput::XIEventMask::RAW_MOTION;
        // Hierarchy changes can only be selected for all devices.
        conn.xinput_xi_select_events(root, &[
            xinput::EventMask { deviceid: xinput::Device::ALL_MASTER.into(), mask: vec![raw] },
            xinput::EventMask { deviceid: xinput::Device::ALL.into(), mask: vec![xinput::XIEventMask::HIERARCHY] },
        ])
            .and_then(|c| Ok(c.check()))
            .map_err(|e| Error::new("SAFETY_MONITOR_UNAVAILABLE", e.to_string()))?
            .map_err(|e| Error::new("SAFETY_MONITOR_UNAVAILABLE", e.to_string()))?;
        // Input before this connection existed cannot be attributed; the
        // screensaver idle counter conservatively includes synthetic input.
        let idle = conn.screensaver_query_info(root).ok().and_then(|c| c.reply().ok())
            .map(|i| Duration::from_millis(i.ms_since_user_input as u64));
        let state = Arc::new(Mutex::new(State {
            last_person: idle.and_then(|d| Instant::now().checked_sub(d)),
            ..Default::default()
        }));
        let (fence, requests) = channel();
        let thread_state = state.clone();
        std::thread::Builder::new().name("opencu-monitor".into()).spawn(move || run(conn, thread_state, requests))
            .map_err(|e| Error::new("SAFETY_MONITOR_UNAVAILABLE", e.to_string()))?;
        let monitor = Self { state, fence };
        monitor.sync()?;
        Ok(monitor)
    }

    /// Wait until every event the server generated before now has been seen.
    fn sync(&self) -> Result<()> {
        let (tx, rx) = channel();
        self.fence.send(tx).map_err(|_| self.failure())?;
        rx.recv_timeout(Duration::from_millis(500)).map_err(|_| self.failure())
    }

    fn failure(&self) -> Error {
        let reason = self.state.lock().unwrap().failed.clone().unwrap_or_else(|| "it did not respond".into());
        Error::new("SAFETY_MONITOR_UNAVAILABLE", format!("The input monitor failed ({reason}); no further input was sent."))
    }

    pub fn stopped(&self) -> bool {
        let _ = self.sync();
        self.state.lock().unwrap().stopped
    }

    pub fn devices(&self) -> Vec<String> {
        self.state.lock().unwrap().devices.clone()
    }

    /// True when a person used the desktop within the idle window.
    pub fn recently_active(&self) -> bool {
        self.state.lock().unwrap().last_person.is_some_and(|t| t.elapsed() < IDLE_REQUIRED)
    }

    pub fn begin(&self) -> Result<Guard<'_>> {
        self.sync()?;
        let mut state = self.state.lock().unwrap();
        if state.stopped { return Err(user_stopped()); }
        state.guarding = true;
        state.interrupted = false;
        drop(state);
        Ok(Guard { monitor: self, done: false })
    }
}

pub struct Guard<'a> {
    monitor: &'a Monitor,
    done: bool,
}

impl Guard<'_> {
    /// Check before sending each input event.
    pub fn check(&self) -> Result<()> {
        self.monitor.sync()?;
        let state = self.monitor.state.lock().unwrap();
        if state.stopped { return Err(user_stopped()); }
        if state.interrupted { return Err(person_active()); }
        Ok(())
    }

    /// Foreground changes need ten seconds without a person's input.
    pub fn require_idle(&self) -> Result<()> {
        self.check()?;
        if self.monitor.recently_active() {
            return Err(Error::new("PERSON_ACTIVE", "Someone used this desktop within the last 10 seconds, and the target window is not in front. No input was sent and the foreground did not change. Ask the person, or try again after they stop."));
        }
        Ok(())
    }

    /// Sleep in short steps, stopping on activity.
    pub fn pause(&self, seconds: f64) -> Result<()> {
        let end = Instant::now() + Duration::from_secs_f64(seconds);
        loop {
            self.check()?;
            let now = Instant::now();
            if now >= end { return Ok(()); }
            std::thread::sleep((end - now).min(Duration::from_millis(20)));
        }
    }

    pub fn finish(mut self) -> Result<()> {
        let result = self.check();
        self.done = true;
        self.monitor.state.lock().unwrap().guarding = false;
        result
    }
}

impl Drop for Guard<'_> {
    fn drop(&mut self) {
        if !self.done { self.monitor.state.lock().unwrap().guarding = false; }
    }
}

fn devices(conn: &RustConnection) -> (BTreeSet<u16>, Vec<String>) {
    let mut synthetic = BTreeSet::new();
    let mut people = vec![];
    if let Ok(Ok(reply)) = conn.xinput_xi_query_device(xinput::Device::ALL).map(|c| c.reply()) {
        for info in reply.infos {
            let name = String::from_utf8_lossy(&info.name).into_owned();
            if is_xtest_device(&name) {
                synthetic.insert(info.deviceid);
            } else if matches!(info.type_, xinput::DeviceType::SLAVE_KEYBOARD | xinput::DeviceType::SLAVE_POINTER
                | xinput::DeviceType::FLOATING_SLAVE) {
                people.push(name);
            }
        }
    }
    (synthetic, people)
}

fn escape_keycodes(conn: &RustConnection) -> BTreeSet<u32> {
    let setup = conn.setup();
    let (min, max) = (setup.min_keycode, setup.max_keycode);
    let mut codes = BTreeSet::new();
    if let Ok(Ok(map)) = conn.get_keyboard_mapping(min, max - min + 1).map(|c| c.reply()) {
        let per = map.keysyms_per_keycode as usize;
        for (i, syms) in map.keysyms.chunks(per.max(1)).enumerate() {
            if syms.contains(&0xff1b) { codes.insert(min as u32 + i as u32); }
        }
    }
    if codes.is_empty() { codes.insert(9); }
    codes
}

fn person(state: &Mutex<State>, synthetic: &BTreeSet<u16>, source: u16, escape: bool) {
    if synthetic.contains(&source) { return; }
    let mut s = state.lock().unwrap();
    s.last_person = Some(Instant::now());
    if s.guarding { s.interrupted = true; }
    if escape { s.stopped = true; }
}

/// Handle one event; false when the connection failed.
fn handle(conn: &RustConnection, state: &Mutex<State>, synthetic: &mut BTreeSet<u16>, escapes: &mut BTreeSet<u32>, event: Event) {
    match event {
        Event::XinputRawKeyPress(e) => person(state, synthetic, e.sourceid, escapes.contains(&e.detail)),
        Event::XinputRawButtonPress(e) => person(state, synthetic, e.sourceid, false),
        Event::XinputRawMotion(e) => person(state, synthetic, e.sourceid, false),
        Event::XinputHierarchy(_) => {
            let (s, p) = devices(conn);
            *synthetic = s;
            state.lock().unwrap().devices = p;
        }
        Event::MappingNotify(_) => *escapes = escape_keycodes(conn),
        _ => {}
    }
}

fn run(conn: RustConnection, state: Arc<Mutex<State>>, requests: Receiver<Sender<()>>) {
    let (mut synthetic, people) = devices(&conn);
    let mut escapes = escape_keycodes(&conn);
    state.lock().unwrap().devices = people;
    let fail = |reason: String| { state.lock().unwrap().failed = Some(reason); };
    let drain = |synthetic: &mut BTreeSet<u16>, escapes: &mut BTreeSet<u32>| -> std::result::Result<(), String> {
        loop {
            match conn.poll_for_event() {
                Ok(Some(event)) => handle(&conn, &state, synthetic, escapes, event),
                Ok(None) => return Ok(()),
                Err(e) => return Err(e.to_string()),
            }
        }
    };
    loop {
        if let Err(e) = drain(&mut synthetic, &mut escapes) { fail(e); return; }
        match requests.recv_timeout(Duration::from_millis(10)) {
            Ok(reply) => {
                // A round trip guarantees that events generated before the
                // fence are queued; drain them before acknowledging.
                if let Err(e) = conn.get_input_focus().map(|c| c.reply()) { fail(e.to_string()); return; }
                if let Err(e) = drain(&mut synthetic, &mut escapes) { fail(e); return; }
                let _ = reply.send(());
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn only_xtest_devices_are_synthetic() {
        assert!(super::is_xtest_device("Virtual core XTEST keyboard"));
        assert!(super::is_xtest_device("Virtual core XTEST pointer"));
        assert!(!super::is_xtest_device("TigerVNC keyboard"));
        assert!(!super::is_xtest_device("Virtual core keyboard"));
    }
}
