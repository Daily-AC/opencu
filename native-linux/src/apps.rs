//! App inventory, resolution and launch: running windows grouped by process,
//! plus XDG desktop entries.
use crate::display::{Display, Kind, WindowInfo};
use crate::monitor::Guard;
use crate::session::SessionEnv;
use opencu_engine::{Error, Result};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct DesktopEntry {
    pub id: String,
    pub name: String,
    pub exec: String,
    pub path: PathBuf,
    pub wm_class: Option<String>,
}

impl DesktopEntry {
    /// The program the entry runs, without arguments or field codes.
    pub fn program(&self) -> String {
        split_exec(&self.exec).first().map(|p| basename(p)).unwrap_or_default()
    }
}

#[derive(Debug, Clone)]
pub struct App {
    pub id: String,
    pub name: String,
    pub pid: u32,
    /// Process start time (clock ticks since boot) to detect PID reuse.
    pub started: u64,
    pub windows: Vec<WindowInfo>,
}

impl App {
    pub fn json(&self) -> Value {
        json!({"id": self.id, "displayName": self.name, "pid": self.pid})
    }
}

pub fn basename(path: &str) -> String {
    path.rsplit('/').next().unwrap_or(path).to_owned()
}

pub fn process_start(pid: u32) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // Fields after the parenthesised command name; starttime is field 22.
    stat.rsplit_once(')')?.1.split_whitespace().nth(19)?.parse().ok()
}

fn executable(pid: u32) -> String {
    std::fs::read_link(format!("/proc/{pid}/exe")).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()
}

fn comm(pid: u32) -> String {
    std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default().trim().to_owned()
}

/// Split a desktop-entry Exec value into arguments, dropping field codes.
pub fn split_exec(exec: &str) -> Vec<String> {
    let mut args = vec![];
    let mut current = String::new();
    let mut quoted = false;
    let mut chars = exec.chars().peekable();
    let mut has = false;
    while let Some(c) = chars.next() {
        match c {
            '"' => { quoted = !quoted; has = true; }
            '\\' if quoted => { if let Some(n) = chars.next() { current.push(n); } }
            ' ' | '\t' if !quoted => { if has || !current.is_empty() { args.push(std::mem::take(&mut current)); has = false; } }
            '%' => match chars.next() {
                Some('%') => current.push('%'),
                _ => {}
            },
            c => current.push(c),
        }
    }
    if has || !current.is_empty() { args.push(current); }
    args.into_iter().filter(|a| !a.is_empty()).collect()
}

fn data_dirs() -> Vec<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    let data_home = std::env::var("XDG_DATA_HOME").ok().filter(|v| !v.is_empty())
        .unwrap_or_else(|| format!("{home}/.local/share"));
    let dirs = std::env::var("XDG_DATA_DIRS").ok().filter(|v| !v.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    std::iter::once(data_home).chain(dirs.split(':').map(str::to_owned))
        .map(|d| Path::new(&d).join("applications")).collect()
}

fn parse_entry(path: &Path, id: String) -> Option<DesktopEntry> {
    let text = std::fs::read_to_string(path).ok()?;
    let lang = std::env::var("LANG").unwrap_or_default();
    let lang = lang.split(['.', '@']).next().unwrap_or("");
    let short = lang.split('_').next().unwrap_or("");
    let mut section = false;
    let mut fields = BTreeMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') { section = line == "[Desktop Entry]"; continue; }
        if !section { continue; }
        if let Some((k, v)) = line.split_once('=') { fields.entry(k.trim().to_owned()).or_insert(v.trim().to_owned()); }
    }
    if fields.get("Type").map(String::as_str) != Some("Application")
        || fields.get("NoDisplay").is_some_and(|v| v == "true")
        || fields.get("Hidden").is_some_and(|v| v == "true") { return None; }
    let name = fields.get(&format!("Name[{lang}]")).or_else(|| fields.get(&format!("Name[{short}]")))
        .or_else(|| fields.get("Name"))?.clone();
    Some(DesktopEntry { id, name, exec: fields.get("Exec")?.clone(), path: path.to_owned(), wm_class: fields.get("StartupWMClass").cloned() })
}

pub fn desktop_entries() -> Vec<DesktopEntry> {
    let mut seen = BTreeSet::new();
    let mut entries = vec![];
    for dir in data_dirs() {
        let mut stack = vec![(dir.clone(), String::new())];
        while let Some((current, prefix)) = stack.pop() {
            let Ok(read) = std::fs::read_dir(&current) else { continue };
            for item in read.flatten() {
                let path = item.path();
                let name = item.file_name().to_string_lossy().into_owned();
                if path.is_dir() && prefix.matches('-').count() < 4 { stack.push((path, format!("{prefix}{name}-"))); continue; }
                let Some(stem) = name.strip_suffix(".desktop") else { continue };
                let id = format!("{prefix}{stem}");
                if !seen.insert(id.clone()) { continue; }
                if let Some(entry) = parse_entry(&path, id) { entries.push(entry); }
            }
        }
    }
    entries.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    entries
}

fn entry_matches_process(entry: &DesktopEntry, pid: u32, window: &WindowInfo) -> bool {
    let program = entry.program();
    let class = entry.wm_class.as_deref().unwrap_or("");
    (!class.is_empty() && (class.eq_ignore_ascii_case(&window.class) || class.eq_ignore_ascii_case(&window.instance)))
        || (!program.is_empty() && (basename(&executable(pid)) == program || comm(pid) == program
            || window.instance.eq_ignore_ascii_case(&program) || window.class.eq_ignore_ascii_case(&program)))
}

/// Visible app windows (not panels or the desktop) grouped by process.
fn running(display: &Display) -> BTreeMap<u32, Vec<WindowInfo>> {
    let mut apps: BTreeMap<u32, Vec<WindowInfo>> = BTreeMap::new();
    let own = std::process::id();
    for w in display.windows() {
        let Some(pid) = w.pid else { continue };
        if w.kind == Kind::Panel || pid == own { continue; }
        apps.entry(pid).or_default().push(w);
    }
    apps
}

fn app_name(pid: u32, windows: &[WindowInfo], entries: &[DesktopEntry]) -> String {
    let first = &windows[0];
    entries.iter().find(|e| entry_matches_process(e, pid, first)).map(|e| e.name.clone())
        .or_else(|| Some(first.class.clone()).filter(|c| !c.is_empty()))
        .unwrap_or_else(|| comm(pid))
}

pub fn list(display: &Display) -> Value {
    let entries = desktop_entries();
    let apps = running(display);
    let mut records = vec![];
    let mut running_entries = BTreeSet::new();
    for (pid, windows) in &apps {
        if let Some(entry) = entries.iter().find(|e| entry_matches_process(e, *pid, &windows[0])) {
            running_entries.insert(entry.id.clone());
        }
        records.push(json!({
            "id": format!("pid:{pid}"),
            "displayName": app_name(*pid, windows, &entries),
            "path": executable(*pid),
            "isRunning": true,
            "pid": pid,
            "windows": windows.iter().map(|w| w.title.clone()).collect::<Vec<_>>(),
        }));
    }
    for entry in &entries {
        if running_entries.contains(&entry.id) { continue; }
        records.push(json!({"id": entry.id, "displayName": entry.name, "path": entry.path, "isRunning": false}));
    }
    Value::Array(records)
}

fn make_app(pid: u32, windows: Vec<WindowInfo>, entries: &[DesktopEntry]) -> Result<App> {
    Ok(App {
        id: format!("pid:{pid}"),
        name: app_name(pid, &windows, entries),
        pid,
        started: process_start(pid).ok_or_else(|| Error::new("STALE_WINDOW", "The process exited."))?,
        windows,
    })
}

/// Running processes matching the query: `pid:N`, desktop entry name or ID,
/// executable name or path, WM_CLASS, exact window title or unique title fragment.
fn matching(query: &str, apps: &BTreeMap<u32, Vec<WindowInfo>>, entries: &[DesktopEntry]) -> Vec<u32> {
    let q = query.trim().to_lowercase();
    if let Some(pid) = q.strip_prefix("pid:").and_then(|p| p.parse::<u32>().ok()) {
        return apps.contains_key(&pid).then_some(pid).into_iter().collect();
    }
    let q_id = q.strip_suffix(".desktop").unwrap_or(&q).to_owned();
    let named: Vec<&DesktopEntry> = entries.iter()
        .filter(|e| e.name.to_lowercase() == q || e.id.to_lowercase() == q_id).collect();
    let mut found: Vec<u32> = apps.iter().filter(|(pid, windows)| {
        let exe = executable(**pid).to_lowercase();
        let w = &windows[0];
        named.iter().any(|e| entry_matches_process(e, **pid, w))
            || exe == q || basename(&exe) == q || comm(**pid).to_lowercase() == q
            || w.class.to_lowercase() == q || w.instance.to_lowercase() == q
    }).map(|(pid, _)| *pid).collect();
    if found.is_empty() {
        found = apps.iter().filter(|(_, ws)| ws.iter().any(|w| w.title.to_lowercase() == q)).map(|(p, _)| *p).collect();
    }
    if found.is_empty() && q.chars().count() >= 3 {
        found = apps.iter().filter(|(_, ws)| ws.iter().any(|w| w.title.to_lowercase().contains(&q))).map(|(p, _)| *p).collect();
    }
    found
}

pub struct Launcher {
    attempts: BTreeSet<String>,
}

impl Launcher {
    pub fn new() -> Self { Self { attempts: BTreeSet::new() } }

    pub fn resolve(&mut self, display: &Display, query: &str, launch: bool, env: &SessionEnv, guard: Option<&Guard>) -> Result<App> {
        let entries = desktop_entries();
        let mut apps = running(display);
        let found = matching(query, &apps, &entries);
        if found.len() > 1 {
            return Err(Error::new("AMBIGUOUS_APP", format!("{} processes match {query:?}; use pid:<pid> from list_apps or a unique window title.", found.len())));
        }
        if let Some(pid) = found.first() {
            return make_app(*pid, apps.remove(pid).unwrap(), &entries);
        }
        if query.trim().to_lowercase().starts_with("pid:") {
            return Err(Error::new("APP_NOT_RUNNING", "No visible window belongs to that process."));
        }
        let q = query.trim();
        let entry = entries.iter().find(|e| e.name.eq_ignore_ascii_case(q) || e.id.eq_ignore_ascii_case(q.strip_suffix(".desktop").unwrap_or(q)))
            .or_else(|| entries.iter().find(|e| e.program() == basename(q)));
        let argv = match entry {
            Some(e) => split_exec(&e.exec),
            None => match which(q) {
                Some(path) => vec![path],
                None => return Err(Error::new("APP_NOT_FOUND", "No running window, desktop entry or executable matches. Use list_apps to see names.")),
            },
        };
        if !launch {
            return Err(Error::new("APP_NOT_RUNNING", "The target is not running; read its state first"));
        }
        if argv.is_empty() { return Err(Error::new("LAUNCH_FAILED", "The desktop entry has an empty Exec line.")); }
        if let Some(g) = guard { g.check()?; }
        let key = argv.join(" ");
        if self.attempts.contains(&key) {
            return Err(Error::new("APP_LAUNCH_PENDING", "An earlier launch still has no visible window. Inspect list_apps; reconnect only to deliberately launch again."));
        }
        let mut argv = argv;
        let program = basename(&argv[0]);
        if ["chromium", "chromium-browser", "chrome", "google-chrome", "google-chrome-stable", "brave-browser", "microsoft-edge", "code", "electron"]
            .contains(&program.as_str()) && !argv.iter().any(|a| a == "--force-renderer-accessibility") {
            argv.insert(1, "--force-renderer-accessibility".into());
        }
        let before: BTreeSet<u32> = display.windows().iter().map(|w| w.id).collect();
        let mut command = std::process::Command::new(&argv[0]);
        command.args(&argv[1..]).env_clear().envs(env.launch_env())
            .current_dir(env.get("HOME").unwrap_or_else(|| "/".into()))
            .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
        unsafe { command.pre_exec(|| { libc::setsid(); Ok(()) }); }
        let mut child = command.spawn().map_err(opencu_engine::launch_error)?;
        let pid = child.id();
        std::thread::spawn(move || { let _ = child.wait(); });
        self.attempts.insert(key);
        let wanted: Vec<String> = [entry.and_then(|e| e.wm_class.clone()), Some(program.clone())].into_iter().flatten()
            .map(|s| s.to_lowercase()).collect();
        for _ in 0..150 {
            if let Some(g) = guard { g.check()?; }
            std::thread::sleep(Duration::from_millis(100));
            let mut apps = running(display);
            if let Some(windows) = apps.remove(&pid) {
                return make_app(pid, windows, &entries);
            }
            // Wrapper scripts and single-instance apps hand the window to another process.
            let fresh: Vec<u32> = apps.iter().filter(|(p, ws)| ws.iter().any(|w| !before.contains(&w.id)
                && (wanted.iter().any(|c| *c == w.class.to_lowercase() || *c == w.instance.to_lowercase())
                    || wanted.iter().any(|c| *c == basename(&executable(**p)).to_lowercase()))))
                .map(|(p, _)| *p).collect();
            if fresh.len() == 1 {
                return make_app(fresh[0], apps.remove(&fresh[0]).unwrap(), &entries);
            }
        }
        Err(Error::new("APP_LAUNCH_PENDING", "Application was launched but has no visible window yet. Read state later; this connection will not launch it again."))
    }
}

fn which(name: &str) -> Option<String> {
    if name.contains('/') {
        return Path::new(name).is_file().then(|| name.to_owned());
    }
    let path = std::env::var("PATH").unwrap_or_else(|_| "/usr/local/bin:/usr/bin:/bin".into());
    path.split(':').map(|d| Path::new(d).join(name)).find(|p| {
        use std::os::unix::fs::PermissionsExt;
        p.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }).map(|p| p.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exec_lines_drop_field_codes_and_keep_quotes() {
        assert_eq!(split_exec("firefox-esr %u"), vec!["firefox-esr"]);
        assert_eq!(split_exec("\"/opt/My App/run\" --x %F"), vec!["/opt/My App/run", "--x"]);
        assert_eq!(split_exec("sh -c \"echo 100%%\""), vec!["sh", "-c", "echo 100%"]);
    }
    #[test]
    fn process_start_parses_names_with_spaces() {
        // The command name can contain spaces and parentheses.
        let line = "123 (a (b) c) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 99999 0";
        let parsed: Option<u64> = line.rsplit_once(')').and_then(|(_, rest)| rest.split_whitespace().nth(19)?.parse().ok());
        assert_eq!(parsed, Some(99999));
    }
}
