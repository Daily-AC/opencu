//! The desktop session's environment. A host may start OpenCU outside the
//! session (for example `docker exec` with only DISPLAY set). Apps launched by
//! OpenCU should still join that session's D-Bus, so the environment of a
//! session process on the same display is used when ours lacks a session bus.
use std::collections::BTreeMap;
use std::os::unix::fs::MetadataExt;

pub struct SessionEnv {
    vars: BTreeMap<String, String>,
    pub source: String,
}

const SESSION_PROCESSES: &[&str] = &[
    "xfce4-session", "xfsettingsd", "xfwm4", "xfce4-panel", "xfdesktop", "gnome-session-b", "gnome-shell",
    "plasmashell", "ksmserver", "mate-session", "lxsession", "cinnamon-sessio", "openbox", "i3", "fluxbox",
];

fn same_display(a: &str, b: &str) -> bool {
    let norm = |d: &str| d.strip_suffix(".0").unwrap_or(d).to_owned();
    norm(a) == norm(b)
}

fn environ(pid: u32) -> Option<BTreeMap<String, String>> {
    let bytes = std::fs::read(format!("/proc/{pid}/environ")).ok()?;
    Some(bytes.split(|b| *b == 0).filter_map(|entry| {
        let entry = String::from_utf8_lossy(entry);
        let (k, v) = entry.split_once('=')?;
        Some((k.to_owned(), v.to_owned()))
    }).collect())
}

impl SessionEnv {
    pub fn discover() -> Self {
        let own: BTreeMap<String, String> = std::env::vars().collect();
        if own.get("DBUS_SESSION_BUS_ADDRESS").is_some_and(|a| !a.is_empty()) {
            return Self { vars: own, source: "engine environment".into() };
        }
        let display = own.get("DISPLAY").cloned().unwrap_or_default();
        let uid = unsafe { libc::getuid() };
        let mut fallback = None;
        if let Ok(entries) = std::fs::read_dir("/proc") {
            let mut pids: Vec<u32> = entries.flatten().filter_map(|e| e.file_name().to_str()?.parse().ok()).collect();
            pids.sort_unstable();
            for pid in pids {
                if std::fs::metadata(format!("/proc/{pid}")).map_or(true, |m| m.uid() != uid) { continue; }
                let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
                let Some(vars) = environ(pid) else { continue };
                let matches = vars.get("DISPLAY").is_some_and(|d| same_display(d, &display))
                    && vars.get("DBUS_SESSION_BUS_ADDRESS").is_some_and(|a| !a.is_empty());
                if !matches { continue; }
                if SESSION_PROCESSES.contains(&comm.trim()) {
                    return Self { vars, source: format!("{} (pid {pid})", comm.trim()) };
                }
                fallback.get_or_insert((vars, format!("{} (pid {pid})", comm.trim())));
            }
        }
        if let Some((vars, source)) = fallback { return Self { vars, source }; }
        let mut vars = own;
        let bus = format!("/run/user/{uid}/bus");
        if std::path::Path::new(&bus).exists() {
            vars.insert("DBUS_SESSION_BUS_ADDRESS".into(), format!("unix:path={bus}"));
            return Self { vars, source: bus };
        }
        Self { vars, source: "engine environment (no session bus found)".into() }
    }

    pub fn get(&self, key: &str) -> Option<String> {
        self.vars.get(key).cloned()
    }

    /// Environment for launched apps: the session's, with accessibility on.
    pub fn launch_env(&self) -> Vec<(String, String)> {
        let mut vars = self.vars.clone();
        if let Ok(display) = std::env::var("DISPLAY") { vars.insert("DISPLAY".into(), display); }
        for (k, v) in [("GNOME_ACCESSIBILITY", "1"), ("ACCESSIBILITY_ENABLED", "1"), ("QT_LINUX_ACCESSIBILITY_ALWAYS_ON", "1"), ("NO_AT_BRIDGE", "0")] {
            vars.insert(k.into(), v.into());
        }
        vars.into_iter().collect()
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn display_numbers_ignore_the_default_screen_suffix() {
        assert!(super::same_display(":1", ":1.0"));
        assert!(!super::same_display(":1", ":10"));
    }
}
