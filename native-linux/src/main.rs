//! OpenCU Linux engine: X11 (XTest, Composite, XInput 2) and AT-SPI2, speaking
//! the same inherited-stdio JSON-lines protocol as the macOS and Windows engines.
mod a11y;
mod apps;
mod clipboard;
mod display;
mod input;
mod keys;
mod monitor;
mod observe;
mod session;

use opencu_engine::{string, Error, Result, Screenshot};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::time::Duration;

const METHODS: &[&str] = &["wait", "get_app_state", "activate_app", "click", "drag", "paste", "press_key", "type_text",
    "scroll", "set_value", "select_text", "perform_secondary_action"];

struct Engine {
    display: display::Display,
    monitor: monitor::Monitor,
    env: session::SessionEnv,
    a11y: Option<a11y::A11y>,
    a11y_error: Option<Error>,
    keymap: keys::Keymap,
    launcher: apps::Launcher,
    snapshot: Option<observe::Snapshot>,
    clipboard: Option<clipboard::Owner>,
}

impl Engine {
    fn new() -> Result<Self> {
        let display = display::Display::connect()?;
        let monitor = monitor::Monitor::new()?;
        let keymap = keys::Keymap::load(&display.conn)?;
        Ok(Self { display, monitor, env: session::SessionEnv::discover(), a11y: None, a11y_error: None, keymap,
            launcher: apps::Launcher::new(), snapshot: None, clipboard: None })
    }

    fn connect_a11y(&mut self) {
        if self.a11y.is_some() { return; }
        let property = self.display.text_property(self.display.root, self.display.atoms.AT_SPI_BUS);
        match a11y::A11y::connect(&self.env, property) {
            Ok(a) => { self.a11y = Some(a); self.a11y_error = None; }
            Err(e) => self.a11y_error = Some(e),
        }
    }

    fn doctor(&mut self) -> Value {
        self.connect_a11y();
        let d = &self.display;
        json!({
            "engine": "independent", "version": env!("CARGO_PKG_VERSION"), "platform": "linux",
            "display": std::env::var("DISPLAY").ok(), "vendor": d.vendor(), "windowManager": d.window_manager(),
            "screen": {"width": d.screen.width, "height": d.screen.height},
            "extensions": {"xtest": d.has_extension("XTEST"), "composite": d.composite, "xinput2": true,
                "screensaver": d.has_extension("MIT-SCREEN-SAVER")},
            "personInputDevices": self.monitor.devices(),
            "sessionEnvironment": self.env.source,
            "accessibility": match (&self.a11y, &self.a11y_error) {
                (Some(a), _) => json!({"available": true, "bus": a.via, "enabledByOpenCU": a.enabled_by_opencu()}),
                (None, Some(e)) => json!({"available": false, "error": e.json()}),
                _ => json!({"available": false}),
            },
            "accountRequired": false, "proprietaryRuntimeRequired": false, "foregroundOnly": true,
            "executable": std::env::current_exe().ok(),
        })
    }

    fn dispatch(&mut self, method: &str, args: &Value) -> Result<Value> {
        if method == "list_apps" { return Ok(apps::list(&self.display)); }
        if !METHODS.contains(&method) {
            return Err(Error::new("METHOD_NOT_FOUND", format!("Unknown OpenCU operation: {method}")));
        }
        // Every recognized state/action attempt consumes the screenshot grant.
        let image: Option<Screenshot> = self.snapshot.as_mut().and_then(|s| s.image.take());
        if method == "wait" {
            let ms = opencu_engine::wait_ms(args)?;
            let guard = self.monitor.begin()?;
            guard.pause(ms as f64 / 1000.0)?;
            guard.finish()?;
            return Ok(json!({"ok": true}));
        }
        if args.get("scope").is_some() {
            return Err(Error::new("INVALID_ARGUMENT", "scope is Windows-only for now."));
        }
        let observing = method == "get_app_state" || method == "activate_app";
        if observing { self.snapshot = None; }
        let query = string(args, "app")?;
        if query.trim().is_empty() { return Err(Error::new("INVALID_ARGUMENT", "app must not be empty")); }
        let Engine { display, monitor, env, a11y, a11y_error, keymap, launcher, snapshot, clipboard } = self;
        let guard = if method != "get_app_state" { Some(monitor.begin()?) } else { None };
        let stopped = monitor.stopped();
        let app = launcher.resolve(display, query, observing && !stopped, env, guard.as_ref())?;
        if observing {
            if a11y.is_none() {
                let property = display.text_property(display.root, display.atoms.AT_SPI_BUS);
                match a11y::A11y::connect(env, property) {
                    Ok(a) => { *a11y = Some(a); *a11y_error = None; }
                    Err(e) => *a11y_error = Some(e),
                }
            }
            if method == "activate_app" {
                let g = guard.as_ref().unwrap();
                let window = &app.windows[observe::primary(&app, display.active_window())];
                if display.active_window() != Some(window.id) || window.hidden {
                    g.require_idle()?;
                    display.activate(window, Duration::from_millis(1500))?;
                }
            }
            let observer = observe::Observer { display, a11y: a11y.as_ref(), a11y_error: a11y_error.as_ref() };
            let app = if method == "activate_app" { launcher.resolve(display, &format!("pid:{}", app.pid), false, env, None)? } else { app };
            let (state, snap) = observer.observe(app, args["includeScreenshot"].as_bool().unwrap_or(false))?;
            if let Some(g) = guard { g.finish()?; }
            *snapshot = Some(snap);
            return Ok(state);
        }
        let s = snapshot.as_ref().filter(|s| s.app.pid == app.pid && s.app.started == app.started
            && app.windows.iter().any(|w| w.id == s.window.id))
            .ok_or_else(|| Error::new("OBSERVATION_REQUIRED", "Read get_app_state for this app before input."))?;
        let guard = guard.unwrap();
        let result = if method == "paste" {
            paste(display, keymap, a11y.as_ref(), &guard, s, clipboard, args)
        } else {
            input::Ctx::new(display, keymap, a11y.as_ref(), &guard, s).perform(method, args, image)
        };
        let finished = guard.finish();
        let result = result?;
        finished?;
        if result["outcome"] == "unknown" { *snapshot = None; }
        Ok(result)
    }

    fn close(&mut self) {
        self.keymap.restore(&self.display.conn);
        if let Some(a) = &self.a11y { a.close(); }
        self.display.close();
    }
}

fn paste(display: &display::Display, keymap: &mut keys::Keymap, a11y: Option<&a11y::A11y>, guard: &monitor::Guard,
    snapshot: &observe::Snapshot, owner: &mut Option<clipboard::Owner>, args: &Value) -> Result<Value> {
    let text = string(args, "text")?;
    if args["format"].as_str().is_some_and(|f| f != "text") {
        return Err(Error::new("UNSUPPORTED_ON_LINUX", "Linux paste supports plain text only (format: text)."));
    }
    if owner.is_none() { *owner = Some(clipboard::Owner::start()?); }
    let owner = owner.as_ref().unwrap();
    // Preserve what is on the clipboard now, before changing anything.
    let previous = if owner.owned() { Some(owner.content()) } else { clipboard::read_current()? };
    guard.check()?;
    let mut ctx = input::Ctx::new(display, keymap, a11y, guard, snapshot);
    ctx.front()?;
    owner.own(owner.text_items(text))?;
    let served = owner.served();
    let sent = ctx.ctrl_v();
    ctx.release_all();
    // Let the app fetch the text before restoring the clipboard.
    let deadline = std::time::Instant::now() + Duration::from_millis(1500);
    while owner.served() == served && std::time::Instant::now() < deadline { std::thread::sleep(Duration::from_millis(10)); }
    std::thread::sleep(Duration::from_millis(200));
    let fetched = owner.served() > served;
    if owner.owned() {
        match previous {
            Some(items) if !items.is_empty() => { owner.own(items).map_err(|e| Error::new("CLIPBOARD_RESTORE_FAILED", e.message))?; }
            _ => owner.disown(),
        }
    }
    sent?;
    let mut result = json!({"ok": true, "app": snapshot.app.json()});
    if !fetched { result["warning"] = json!("The app did not request the clipboard text; check whether a text field had focus."); }
    Ok(result)
}

fn main() {
    let mode = std::env::args().nth(1).unwrap_or_default();
    if mode != "serve" && mode != "--doctor" {
        eprintln!("Usage: opencu-engine serve | --doctor");
        std::process::exit(2);
    }
    let mut engine = Engine::new();
    if mode == "--doctor" {
        match &mut engine {
            Ok(e) => { println!("{}", e.doctor()); e.close(); }
            Err(e) => println!("{}", json!({"engine": "independent", "version": env!("CARGO_PKG_VERSION"), "platform": "linux", "error": e.json()})),
        }
        return;
    }
    let stdin = io::stdin();
    let mut out = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let (id, result) = match serde_json::from_str::<Value>(&line) {
            Ok(v) => {
                let id = v.get("id").cloned().unwrap_or(Value::Null);
                let r = match v["method"].as_str() {
                    Some("doctor") => match &mut engine { Ok(e) => Ok(e.doctor()), Err(e) => Err(e.clone()) },
                    Some(method) => match &mut engine { Ok(e) => e.dispatch(method, &v["params"]), Err(e) => Err(e.clone()) },
                    None => Err(Error::new("INVALID_REQUEST", "method must be a string")),
                };
                (id, r)
            }
            Err(_) => (Value::Null, Err(Error::new("INVALID_REQUEST", "Request must be a JSON object"))),
        };
        let response = match result {
            Ok(result) => json!({"id": id, "result": result}),
            Err(e) => json!({"id": id, "error": e.json()}),
        };
        if writeln!(out, "{response}").and_then(|_| out.flush()).is_err() { break; }
    }
    if let Ok(e) = &mut engine { e.close(); }
}
