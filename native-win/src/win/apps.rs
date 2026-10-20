use super::{from_wide, wide};
use opencu_engine::{Error, Rect, Result};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    thread,
    time::Duration,
};
use windows::{
    core::*,
    Win32::{
        Foundation::*,
        Graphics::Dwm::*,
        System::{Com::*, Threading::*},
        UI::{HiDpi::*, Shell::*, WindowsAndMessaging::*},
    },
};
#[derive(Clone)]
pub struct Window {
    pub hwnd: HWND,
    pub pid: u32,
    pub title: String,
    pub path: String,
    pub created: u64,
    pub class_name: String,
    pub tool: bool,
    pub owned: bool,
    pub area: i64,
}
impl Window {
    /// A child, owner or owned top-level window is part of the target only when
    /// its process and live root owner match. Same PID alone is insufficient.
    pub unsafe fn contains(&self, hwnd: HWND) -> bool {
        let owner = ownership_root(self.hwnd, self.pid);
        owner.is_some() && ownership_root(hwnd, self.pid) == owner
    }
    pub unsafe fn capture_rect(&self) -> Result<Rect> {
        self.validate()?;
        let mut r = RECT::default();
        DwmGetWindowAttribute(
            self.hwnd,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            &mut r as *mut _ as _,
            std::mem::size_of::<RECT>() as u32,
        )?;
        Ok(Rect {
            x: r.left,
            y: r.top,
            width: r.right - r.left,
            height: r.bottom - r.top,
        })
    }
    pub unsafe fn dpi(&self) -> u32 {
        GetDpiForWindow(self.hwnd)
    }
    pub unsafe fn validate(&self) -> Result<()> {
        let mut pid = 0;
        GetWindowThreadProcessId(self.hwnd, Some(&mut pid));
        if !IsWindow(Some(self.hwnd)).as_bool()
            || pid != self.pid
            || process(pid).map(|(_, c)| c).ok() != Some(self.created)
        {
            return Err(Error::new(
                "STALE_WINDOW",
                "Observed window or process no longer exists; read state again",
            ));
        }
        Ok(())
    }
}
unsafe fn ownership_root(mut hwnd: HWND, target_pid: u32) -> Option<HWND> {
    // GA_ROOTOWNER follows GetParent and misses owners of non-WS_POPUP
    // top-level windows. Walk the actual GW_OWNER chain instead, normalizing
    // children with GA_ROOT and rejecting any foreign-process link.
    for _ in 0..64 {
        let mut pid = 0;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if !IsWindow(Some(hwnd)).as_bool() || pid != target_pid {
            return None;
        }
        let root = GetAncestor(hwnd, GA_ROOT);
        if root != hwnd {
            hwnd = root;
            continue;
        }
        match GetWindow(hwnd, GW_OWNER) {
            Ok(owner) => hwnd = owner,
            Err(_) => return Some(hwnd),
        }
    }
    None
}
#[derive(Clone)]
pub struct App {
    pub id: String,
    pub name: String,
    pub pid: u32,
    pub windows: Vec<Window>,
}
impl App {
    pub fn json(&self) -> Value {
        json!({"id":self.id,"displayName":self.name,"pid":self.pid})
    }
}
pub struct Handle(pub HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}
unsafe fn process(pid: u32) -> Result<(String, u64)> {
    let p = Handle(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)?);
    let mut buf = vec![0u16; 32768];
    let mut len = buf.len() as u32;
    QueryFullProcessImageNameW(p.0, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len)?;
    let (mut creation, mut exit, mut kernel, mut user) = (
        FILETIME::default(),
        FILETIME::default(),
        FILETIME::default(),
        FILETIME::default(),
    );
    GetProcessTimes(p.0, &mut creation, &mut exit, &mut kernel, &mut user)?;
    Ok((
        from_wide(&buf[..len as usize]),
        ((creation.dwHighDateTime as u64) << 32) | creation.dwLowDateTime as u64,
    ))
}
struct Enumeration {
    list: Vec<Window>,
    include_hidden: bool,
}
unsafe extern "system" fn enumerate(hwnd: HWND, data: LPARAM) -> BOOL {
    let enumeration = &mut *(data.0 as *mut Enumeration);
    if !enumeration.include_hidden && !IsWindowVisible(hwnd).as_bool() {
        return true.into();
    }
    let mut cloaked = 0u32;
    if DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &mut cloaked as *mut _ as _, 4).is_ok()
        && cloaked != 0
        && !enumeration.include_hidden
    {
        return true.into();
    }
    let mut pid = 0;
    GetWindowThreadProcessId(hwnd, Some(&mut pid));
    if pid == GetCurrentProcessId() {
        return true.into();
    }
    let mut title = vec![0u16; (GetWindowTextLengthW(hwnd).max(0) + 1) as usize];
    GetWindowTextW(hwnd, &mut title);
    let title = from_wide(&title);
    if hwnd == GetShellWindow() {
        return true.into();
    }
    let mut class = [0u16; 256];
    GetClassNameW(hwnd, &mut class);
    let class_name = from_wide(&class);
    let style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32;
    let tool = style & (WS_EX_TOOLWINDOW.0 | WS_EX_NOACTIVATE.0) != 0
        || class_name.ends_with("ToolSaveBits");
    let owned = GetWindow(hwnd, GW_OWNER).is_ok_and(|owner| !owner.is_invalid());
    let mut bounds = RECT::default();
    let _ = GetWindowRect(hwnd, &mut bounds);
    let area =
        (bounds.right - bounds.left).max(0) as i64 * (bounds.bottom - bounds.top).max(0) as i64;
    if area == 0 && !enumeration.include_hidden {
        return true.into();
    }
    let (path, created) = process(pid).unwrap_or((String::new(), 0));
    enumeration.list.push(Window {
        hwnd,
        pid,
        title,
        path,
        created,
        class_name,
        tool,
        owned,
        area,
    });
    true.into()
}
pub unsafe fn windows() -> Result<Vec<Window>> {
    enumerate_windows(false)
}
/// Observation inventory preserves EnumWindows Z order and includes hidden
/// same-process windows for summaries. Existing resolve/input inventory is unchanged.
pub unsafe fn observation_windows() -> Result<Vec<Window>> {
    enumerate_windows(true)
}
unsafe fn enumerate_windows(include_hidden: bool) -> Result<Vec<Window>> {
    let mut enumeration = Enumeration {
        list: vec![],
        include_hidden,
    };
    EnumWindows(Some(enumerate), LPARAM(&mut enumeration as *mut _ as isize))?;
    Ok(enumeration.list)
}
pub unsafe fn observation_info(w: &Window) -> opencu_engine::observation::WindowInfo {
    let mut bounds = RECT::default();
    // DWM frame bounds exclude invisible resize borders, important when a
    // fullscreen player covers a maximized window of the same application.
    if DwmGetWindowAttribute(
        w.hwnd,
        DWMWA_EXTENDED_FRAME_BOUNDS,
        &mut bounds as *mut _ as _,
        std::mem::size_of::<RECT>() as u32,
    )
    .is_err()
    {
        let _ = GetWindowRect(w.hwnd, &mut bounds);
    }
    let mut cloaked = 0u32;
    let _ = DwmGetWindowAttribute(w.hwnd, DWMWA_CLOAKED, &mut cloaked as *mut _ as _, 4);
    let style = GetWindowLongPtrW(w.hwnd, GWL_EXSTYLE) as u32;
    opencu_engine::observation::WindowInfo {
        hwnd: w.hwnd.0 as usize,
        owner: GetWindow(w.hwnd, GW_OWNER)
            .ok()
            .filter(|h| !h.is_invalid())
            .map(|h| h.0 as usize),
        title: w.title.clone(),
        class_name: w.class_name.clone(),
        bounds: super::observe::rect(bounds),
        visible: IsWindowVisible(w.hwnd).as_bool() && cloaked == 0,
        minimized: IsIconic(w.hwnd).as_bool(),
        tool: w.tool,
        opaque: style & (WS_EX_LAYERED.0 | WS_EX_TRANSPARENT.0) == 0,
    }
}
pub unsafe fn client_rect(w: &Window) -> Option<Rect> {
    let mut r = RECT::default();
    GetClientRect(w.hwnd, &mut r).ok()?;
    let mut origin = POINT {
        x: r.left,
        y: r.top,
    };
    if !windows::Win32::Graphics::Gdi::ClientToScreen(w.hwnd, &mut origin).as_bool() {
        return None;
    }
    Some(Rect {
        x: origin.x,
        y: origin.y,
        width: r.right - r.left,
        height: r.bottom - r.top,
    })
}
#[derive(Clone)]
struct Shortcut {
    name: String,
    path: PathBuf,
    target: String,
}
unsafe fn shortcuts() -> Vec<Shortcut> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>, depth: usize) {
        if depth > 12 {
            return;
        }
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    walk(&p, out, depth + 1);
                } else if p.extension().is_some_and(|e| e.eq_ignore_ascii_case("lnk")) {
                    out.push(p);
                }
            }
        }
    }
    let mut paths = vec![];
    for var in ["APPDATA", "PROGRAMDATA"] {
        if let Some(root) = std::env::var_os(var) {
            walk(
                &PathBuf::from(root).join("Microsoft/Windows/Start Menu/Programs"),
                &mut paths,
                0,
            );
        }
    }
    paths.sort();
    paths.dedup();
    paths
        .into_iter()
        .map(|path| {
            let target = (|| -> windows::core::Result<String> {
                let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
                let persist: IPersistFile = link.cast()?;
                persist.Load(PCWSTR(wide(&path.to_string_lossy()).as_ptr()), STGM_READ)?;
                let mut buf = vec![0u16; 32768];
                link.GetPath(&mut buf, std::ptr::null_mut(), 0)?;
                Ok(from_wide(&buf))
            })()
            .unwrap_or_default();
            Shortcut {
                name: path
                    .file_stem()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into(),
                path,
                target,
            }
        })
        .collect()
}
fn basename(path: &str) -> String {
    Path::new(path)
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .into()
}
pub unsafe fn list() -> Result<Value> {
    let running = windows()?;
    let mut records = BTreeMap::<String, Value>::new();
    for s in shortcuts() {
        let p = s.path.to_string_lossy().to_string();
        records.insert(p.clone(),json!({"id":p,"displayName":s.name,"path":p,"isRunning":running.iter().any(|w|!s.target.is_empty()&&w.path.eq_ignore_ascii_case(&s.target))}));
    }
    for w in running {
        let id = if w.path.is_empty() {
            format!("pid:{}", w.pid)
        } else {
            w.path.clone()
        };
        let v=records.entry(id.clone()).or_insert_with(||json!({"id":id,"displayName":if w.path.is_empty(){w.title.clone()}else{basename(&w.path)},"path":w.path,"isRunning":true,"pids":[]}));
        let pids = v["pids"].as_array_mut().unwrap();
        if !pids.contains(&json!(w.pid)) {
            pids.push(json!(w.pid));
        }
        if pids.len() == 1 {
            v["pid"] = json!(w.pid);
        } else {
            v.as_object_mut().unwrap().remove("pid");
        }
    }
    Ok(Value::Array(records.into_values().collect()))
}
fn matching(query: &str, all: &[Window]) -> Result<Vec<Window>> {
    let q = query.to_lowercase();
    let process: Vec<_> = all
        .iter()
        .filter(|w| {
            w.path.eq_ignore_ascii_case(query)
                || basename(&w.path).eq_ignore_ascii_case(query)
                || Path::new(&w.path)
                    .file_name()
                    .is_some_and(|p| p.to_string_lossy().eq_ignore_ascii_case(query))
                || q == format!("pid:{}", w.pid)
        })
        .cloned()
        .collect();
    if !process.is_empty() {
        return Ok(process);
    }
    let exact: Vec<_> = all
        .iter()
        .filter(|w| w.title.eq_ignore_ascii_case(query))
        .cloned()
        .collect();
    let titles = if exact.is_empty() {
        all.iter()
            .filter(|w| w.title.to_lowercase().contains(&q))
            .cloned()
            .collect()
    } else {
        exact
    };
    if titles
        .iter()
        .map(|w| w.pid)
        .collect::<std::collections::BTreeSet<_>>()
        .len()
        > 1
    {
        return Err(Error::new("AMBIGUOUS_APP", "Multiple window titles match; use a unique title or an executable path to observe all its windows"));
    }
    Ok(titles)
}
fn unique(mut matches: Vec<Window>) -> Result<Option<App>> {
    let mut pids: Vec<_> = matches.iter().map(|w| w.pid).collect();
    pids.sort();
    pids.dedup();
    if pids.len() > 1 {
        return Err(Error::new(
            "AMBIGUOUS_APP",
            "More than one process matches; use a unique window title or pid:<pid> from list_apps",
        ));
    }
    matches.sort_by_key(|w| std::cmp::Reverse(opencu_engine::window_rank(w.tool, w.owned, w.area)));
    Ok(matches.first().map(|w| App {
        // A browser can have multiple processes for isolated profiles. The
        // observation's canonical ID must select this instance, not all chrome.exe.
        id: format!("pid:{}", w.pid),
        name: if w.path.is_empty() {
            w.title.clone()
        } else {
            basename(&w.path)
        },
        pid: w.pid,
        windows: matches.clone(),
    }))
}
pub unsafe fn resolve(
    query: &str,
    launch: bool,
    attempts: &mut BTreeSet<String>,
    guard: Option<&super::safety::Guard<'_>>,
) -> Result<App> {
    if let Some(app) = unique(matching(query, &windows()?)?)? {
        return Ok(app);
    }
    let links: Vec<_> = shortcuts()
        .into_iter()
        .filter(|s| {
            s.name.eq_ignore_ascii_case(query)
                || s.path.to_string_lossy().eq_ignore_ascii_case(query)
        })
        .collect();
    if links.len() > 1 {
        return Err(Error::new(
            "AMBIGUOUS_APP",
            "Multiple Start-menu shortcuts match; use their full shortcut path",
        ));
    }
    let link = links.first();
    if let Some(link) = link {
        if !link.target.is_empty() {
            if let Some(app) = unique(matching(&link.target, &windows()?)?)? {
                return Ok(app);
            }
        }
    }
    if !launch {
        return Err(Error::new(
            "APP_NOT_RUNNING",
            "The target is not running; read its state first",
        ));
    }
    let path = link
        .map(|s| s.path.clone())
        .unwrap_or_else(|| PathBuf::from(query));
    if !path.is_absolute()
        || !path.is_file()
        || !path
            .extension()
            .is_some_and(|e| e.eq_ignore_ascii_case("exe") || e.eq_ignore_ascii_case("lnk"))
    {
        return Err(Error::new(
            "APP_NOT_FOUND",
            "No running window, executable path or Start-menu shortcut matches",
        ));
    }
    if let Some(g) = guard {
        g.check()?;
    }
    let launch_key = path.to_string_lossy().to_lowercase();
    if attempts.contains(&launch_key) {
        return Err(Error::new("APP_LAUNCH_PENDING", "An earlier launch still has no visible window. Inspect list_apps; reconnect only to deliberately launch again."));
    }
    // Direct CreateProcess never invokes the shell's UAC/elevation/error UI.
    // Remember successful launch attempts so observation retries cannot relaunch.
    let pid = if path
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("exe"))
    {
        use std::os::windows::process::CommandExt;
        let child = std::process::Command::new(&path)
            .creation_flags(0x08000000)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(opencu_engine::launch_error)?;
        child.id()
    } else {
        // Resolve and launch the shortcut target without the shell's elevation UI.
        let sl: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
        let persist: IPersistFile = sl.cast()?;
        persist.Load(PCWSTR(wide(&path.to_string_lossy()).as_ptr()), STGM_READ)?;
        let mut exe = vec![0u16; 32768];
        sl.GetPath(&mut exe, std::ptr::null_mut(), 0)?;
        let mut args = vec![0u16; 32768];
        sl.GetArguments(&mut args)?;
        let mut cwd = vec![0u16; 32768];
        sl.GetWorkingDirectory(&mut cwd)?;
        let exe = from_wide(&exe);
        if exe.is_empty() {
            return Err(Error::new(
                "LAUNCH_FAILED",
                "Shortcut has no executable target; packaged/shell app shortcuts are not supported",
            ));
        }
        use std::os::windows::process::CommandExt;
        let mut cmd = std::process::Command::new(exe);
        cmd.raw_arg(from_wide(&args))
            .creation_flags(0x08000000)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        let cwd = from_wide(&cwd);
        if !cwd.is_empty() {
            cmd.current_dir(cwd);
        }
        cmd.spawn()
            .map_err(opencu_engine::launch_error)?
            .id()
    };
    attempts.insert(launch_key);
    for _ in 0..40 {
        if let Some(g) = guard {
            g.check()?;
        }
        super::safety::desktop()?;
        let all = windows()?;
        let owned: Vec<_> = all.iter().filter(|w| w.pid == pid).cloned().collect();
        if let Some(app) = unique(owned)? {
            return Ok(app);
        }
        let target = link
            .map(|s| s.target.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or(query);
        if let Some(app) = unique(matching(target, &all)?)? {
            return Ok(app);
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err(Error::new(
        "APP_LAUNCH_PENDING",
        "Application was launched but has no visible window yet. Read state later; this connection will not launch it again.",
    ))
}
