//! Screen-lock detection. Input is refused while the session is locked or a
//! screen saver is active: logind's LockedHint (GNOME, KDE, Cinnamon),
//! org.freedesktop.ScreenSaver.GetActive on the session bus, and, in the input
//! path, a full-screen override-redirect window of another program on top
//! (i3lock, xscreensaver, xfce4-screensaver). The X server's own blanking is
//! not a lock: the first input event just wakes the screen.
use crate::session::SessionEnv;
use std::time::Duration;
use zbus::zvariant::{OwnedObjectPath, OwnedValue};
use zbus::Connection;

const PROPERTIES: &str = "org.freedesktop.DBus.Properties";

#[derive(Default)]
pub struct LockProbe {
    started: bool,
    session: Option<Connection>,
    system: Option<Connection>,
    logind_session: Option<OwnedObjectPath>,
}

fn connect(address: Option<String>) -> Option<Connection> {
    let address = address.filter(|a| !a.is_empty())?;
    // A bus that never answers must not hold up input checks.
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let conn = zbus::block_on(async {
            zbus::connection::Builder::address(address.as_str()).ok()?.method_timeout(Duration::from_millis(500)).build().await.ok()
        });
        let _ = tx.send(conn);
    });
    rx.recv_timeout(Duration::from_secs(2)).ok().flatten()
}

impl LockProbe {
    fn start(&mut self, env: &SessionEnv) {
        if self.started { return; }
        self.started = true;
        self.session = connect(env.get("DBUS_SESSION_BUS_ADDRESS"));
        self.system = connect(Some(std::env::var("DBUS_SYSTEM_BUS_ADDRESS")
            .unwrap_or_else(|_| "unix:path=/run/dbus/system_bus_socket".into())));
        if let (Some(system), Some(id)) = (&self.system, env.get("XDG_SESSION_ID")) {
            self.logind_session = zbus::block_on(system.call_method(Some("org.freedesktop.login1"), "/org/freedesktop/login1",
                Some("org.freedesktop.login1.Manager"), "GetSession", &(id,))).ok()
                .and_then(|r| r.body().deserialize::<OwnedObjectPath>().ok());
        }
    }

    /// Why the session counts as locked, or None.
    pub fn locked(&mut self, env: &SessionEnv) -> Option<String> {
        self.start(env);
        if let (Some(system), Some(path)) = (&self.system, &self.logind_session) {
            let get = |name: &str| zbus::block_on(system.call_method(Some("org.freedesktop.login1"), path.as_str(), Some(PROPERTIES), "Get",
                &("org.freedesktop.login1.Session", name))).ok()
                .and_then(|r| r.body().deserialize::<OwnedValue>().ok()).and_then(|v| bool::try_from(v).ok());
            if get("LockedHint") == Some(true) { return Some("logind reports the session as locked".into()); }
            if get("Active") == Some(false) { return Some("logind reports the session as inactive (another session is in front)".into()); }
        }
        if let Some(session) = &self.session {
            // Only ask a running service; calling an absent name could start one.
            let owned = zbus::block_on(session.call_method(Some("org.freedesktop.DBus"), "/org/freedesktop/DBus", Some("org.freedesktop.DBus"),
                "NameHasOwner", &("org.freedesktop.ScreenSaver",))).ok()
                .and_then(|r| r.body().deserialize::<bool>().ok()).unwrap_or(false);
            if owned {
                for path in ["/org/freedesktop/ScreenSaver", "/ScreenSaver"] {
                    let active = zbus::block_on(session.call_method(Some("org.freedesktop.ScreenSaver"), path, Some("org.freedesktop.ScreenSaver"),
                        "GetActive", &())).ok().and_then(|r| r.body().deserialize::<bool>().ok());
                    if active == Some(true) { return Some("the screen saver or lock screen is active".into()); }
                    if active.is_some() { break; }
                }
            }
        }
        None
    }
}
