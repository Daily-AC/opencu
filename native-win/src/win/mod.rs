mod apps;
mod capture;
mod clipboard;
mod indicator;
mod input;
mod observe;
mod safety;
use opencu_engine::{string, Error, Result};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use windows::{
    core::*,
    Win32::{
        System::{Com::*, WinRT::*},
        UI::{Accessibility::*, HiDpi::*},
    },
};

pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}
pub fn from_wide(s: &[u16]) -> String {
    String::from_utf16_lossy(&s[..s.iter().position(|n| *n == 0).unwrap_or(s.len())])
}
struct Apartment;
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe {
            RoUninitialize();
        }
    }
}
struct Engine {
    automation: IUIAutomation,
    snapshot: Option<observe::Snapshot>,
    scope: Option<(String, String, observe::Scope)>,
    scope_serial: u64,
    monitor: safety::Monitor,
    indicator: indicator::Indicator,
    launches: std::collections::BTreeSet<String>,
    _apartment: Apartment,
}
impl Engine {
    unsafe fn new() -> Result<Self> {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)?;
        RoInitialize(RO_INIT_MULTITHREADED)?;
        let apartment = Apartment;
        let automation: IUIAutomation =
            CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER)?;
        let options: IUIAutomation2 = automation.cast()?;
        options.SetConnectionTimeout(2000)?;
        options.SetTransactionTimeout(2000)?;
        Ok(Self {
            automation,
            snapshot: None,
            scope: None,
            scope_serial: 0,
            monitor: safety::Monitor::new()?,
            indicator: indicator::Indicator::new()?,
            launches: Default::default(),
            _apartment: apartment,
        })
    }
    unsafe fn dispatch(&mut self, method: &str, args: &Value) -> Result<Value> {
        if method == "doctor" {
            return Ok(doctor());
        }
        if method == "list_apps" {
            safety::desktop()?;
            return apps::list();
        }
        if ![
            "wait",
            "get_app_state",
            "activate_app",
            "click",
            "drag",
            "paste",
            "press_key",
            "type_text",
            "scroll",
            "set_value",
            "select_text",
            "perform_secondary_action",
        ]
        .contains(&method)
        {
            return Err(Error::new(
                "METHOD_NOT_FOUND",
                format!("Unknown OpenCU operation: {method}"),
            ));
        }
        // Invalidate screenshot even when validation/target resolution subsequently fails.
        let previous_image = self.snapshot.as_mut().and_then(|s| s.image.take());
        if method == "wait" {
            let ms = opencu_engine::wait_ms(args)?;
            let mut guard = self.monitor.begin(&self.indicator)?;
            guard.pause(ms as f64 / 1000.0)?;
            guard.finish()?;
            return Ok(json!({"ok":true}));
        }
        if method == "select_text" {
            return Err(Error::new(
                "UNSUPPORTED_ON_WINDOWS",
                format!("{method} is not supported on Windows in phase 1"),
            ));
        }
        let observing = method == "get_app_state" || method == "activate_app";
        if observing {
            if let Some(index) = args.get("scope") {
                let index = index.as_u64().filter(|n| *n > 0 && *n <= usize::MAX as u64)
                    .ok_or_else(|| Error::new("INVALID_ARGUMENT", "scope must be a positive integer"))? as usize;
                let query = string(args, "app")?;
                let request = args["scopeRequest"].as_str();
                if !self.scope.as_ref().is_some_and(|(key, app, _)| request == Some(key.as_str()) && app == query) {
                    self.scope_serial += 1;
                    let root = self.snapshot.as_ref().and_then(|s| s.elements.get(index - 1)).cloned();
                    let identity = root.as_ref().and_then(|e| observe::runtime_id(&e.element)
                        .map(|id| format!("{}:{}:{:?}:{id:?}", e.window.pid, e.window.hwnd.0 as usize, e.window.created)))
                        .unwrap_or_else(|| format!("request:{}", self.scope_serial));
                    self.scope = Some((request.unwrap_or("").into(), query.into(), observe::Scope { root, identity }));
                }
            } else { self.scope = None; }
            self.snapshot = None;
        }
        // Guard includes resolution/launch and activation; no action is replayed.
        let mut guard = if method != "get_app_state" {
            Some(self.monitor.begin(&self.indicator)?)
        } else {
            None
        };
        safety::desktop()?;
        let query = string(args, "app")?;
        if query.trim().is_empty() {
            return Err(Error::new("INVALID_ARGUMENT", "app must not be empty"));
        }
        let app = apps::resolve(
            query,
            observing && !self.monitor.stopped(),
            &mut self.launches,
            guard.as_ref(),
        )?;
        for window in &app.windows {
            safety::target(window)?;
        }
        if method == "activate_app" {
            let g = guard.as_mut().unwrap();
            safety::target(&app.windows[0])?;
            g.activate(&app.windows[0])?;
        }
        if observing {
            let (state, snapshot) = observe::observe(
                &self.automation,
                app,
                args["includeScreenshot"].as_bool().unwrap_or(false),
                self.scope.as_ref().map(|(_, _, scope)| scope),
            )?;
            if let Some(g) = guard.as_mut() {
                g.finish()?;
            }
            self.snapshot = Some(snapshot);
            if method == "get_app_state" {
                self.monitor.observed();
            }
            return Ok(state);
        }
        let s = self
            .snapshot
            .as_mut()
            .filter(|s| {
                s.app.id == app.id
                    && s.app.pid == app.pid
                    && s.app.windows.iter().all(|old| {
                        app.windows
                            .iter()
                            .any(|w| w.hwnd == old.hwnd && w.created == old.created)
                    })
            })
            .ok_or_else(|| {
                Error::new(
                    "OBSERVATION_REQUIRED",
                    "Read this application's state before input",
                )
            })?;
        let g = guard.as_mut().unwrap();
        let outcome = input::perform(method, args, &self.automation, s, previous_image, g);
        // A physical event queued during the final API call wins over its return status.
        g.finish()?;
        outcome?;
        Ok(json!({"ok":true,"app":s.app.json()}))
    }
}
fn doctor() -> Value {
    let status = unsafe { safety::desktop() };
    json!({"engine":"independent","version":env!("CARGO_PKG_VERSION"),"platform":"win32","desktopAccessible":status.is_ok(),"desktopError":status.err().map(|e| e.json()),"accountRequired":false,"proprietaryRuntimeRequired":false,"foregroundOnly":true,"executable":std::env::current_exe().ok()})
}
pub fn main() {
    // The GUI subsystem suppresses a console window; inherited standard handles
    // still carry the protocol. Never open a console or display an error dialog.
    let mode = std::env::args().nth(1).unwrap_or_default();
    if mode == "--doctor" {
        println!("{}", doctor());
        return;
    }
    if mode != "serve" {
        eprintln!("Usage: opencu-engine.exe serve | --doctor");
        std::process::exit(2);
    }
    let mut engine = unsafe { Engine::new() };
    let stdin = io::stdin();
    let mut out = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let request = serde_json::from_str::<Value>(&line);
        let (id, result) = match request {
            Ok(v) => {
                let id = v.get("id").cloned().unwrap_or(Value::Null);
                let r = match v["method"].as_str() {
                    Some("doctor") => Ok(doctor()),
                    Some(method) => match &mut engine {
                        Ok(e) => unsafe { e.dispatch(method, &v["params"]) },
                        Err(e) => Err(e.clone()),
                    },
                    None => Err(Error::new("INVALID_REQUEST", "method must be a string")),
                };
                (id, r)
            }
            Err(_) => (
                Value::Null,
                Err(Error::new(
                    "INVALID_REQUEST",
                    "Request must be a JSON object",
                )),
            ),
        };
        let response = match result {
            Ok(result) => json!({"id":id,"result":result}),
            Err(e) => json!({"id":id,"error":e.json()}),
        };
        if writeln!(out, "{response}")
            .and_then(|_| out.flush())
            .is_err()
        {
            break;
        }
    }
}
