//! Platform-independent policy and bounded execution for UIA-only delivery.
use crate::{Error, Result};
use serde_json::{json, Value};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering::SeqCst},
        mpsc, Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

pub fn eligible(method: &str, args: &Value) -> bool {
    if args["element_index"].as_u64().filter(|n| *n > 0).is_none()
        || args.get("x").is_some()
        || args.get("y").is_some()
    {
        return false;
    }
    match method {
        "click" => {
            args.get("key").is_none()
                && args.get("duration").is_none()
                && args
                    .get("click_count")
                    .is_none_or(|v| v.as_u64() == Some(1))
                && args
                    .get("mouse_button")
                    .is_none_or(|v| matches!(v.as_str(), Some("left" | "l")))
        }
        "set_value" | "perform_secondary_action" => true,
        _ => false,
    }
}
/// Routing is restricted to a verified locked parent on an agent child connection.
pub fn use_patterns(guarded: bool, locked: Option<bool>, method: &str, args: &Value) -> bool {
    guarded && locked == Some(true) && eligible(method, args)
}
pub fn required() -> Error {
    Error::new("UNSUPPORTED_ACTION", "No supported control pattern for this indexed action. No synthetic input was sent; read state before choosing another action.")
}
/// Only successful null output or UIA_E_NOTSUPPORTED means no pattern. In
/// windows-rs 0.62, converting a null interface produces Error::empty (code 0).
/// Inspect the raw HRESULT/output separately instead of mistaking it for failure.
pub fn pattern_present(hresult: i32, non_null: bool) -> Result<bool> {
    if hresult >= 0 { return Ok(non_null); }
    if hresult as u32 == 0x80040204 { return Ok(false); }
    Err(Error::new(crate::hresult_code(hresult as u32),
        format!("Pattern query failed (0x{:08X})", hresult as u32)))
}
pub fn observable(text: &str) -> String {
    text.lines().filter(|line| line.trim_start().starts_with('[') || (line.starts_with("Window:") || line.starts_with("Window summary:")))
        .collect::<Vec<_>>().join("\n")
}
pub fn select_click<T>(
    mut query: impl FnMut(&'static str) -> Result<Option<T>>,
) -> Result<(&'static str, T)> {
    for name in ["Select", "Invoke", "Toggle", "ExpandCollapse", "DoDefaultAction"] {
        if let Some(pattern) = query(name)? {
            return Ok((name, pattern));
        }
    }
    Err(required())
}
/// The bridge also verifies the child relationship; the native flag alone must
/// not enable relaxed delivery in a console (or unverified) process session.
pub fn remote_session(protocol: Option<u16>) -> Result<()> {
    if protocol == Some(2) { return Ok(()); }
    Err(Error::new("INVALID_ARGUMENT", "Agent-parent mode requires a WTS-verified RDP process session"))
}
pub fn require_observation<T>(snapshot: Option<T>) -> Result<T> {
    snapshot.ok_or_else(|| Error::new("OBSERVATION_REQUIRED", "Read this application's state before input"))
}
pub fn unknown(result: &mut Value, reason: &str, stop: Option<&Error>) {
    result["outcome"] = json!("unknown");
    result["message"] = json!(format!("The pattern call was dispatched; its effect is unconfirmed ({reason}). Read fresh get_app_state before continuing; do not repeat the action automatically."));
    if let Some(error) = stop.filter(|e| e.code == "USER_STOPPED") {
        result["stop"] = error.json();
    }
}
/// Cancellation and issue() share a lock: after a preflight refusal the worker
/// cannot later mark a call issued. Once issued, every error is an unknown result.
pub fn delivery_result(app: Value, issued: Option<&str>, completion: Result<Option<()>>) -> Result<Value> {
    let Some(pattern) = issued else {
        let error = match completion {
            Err(e) => e,
            _ => Error::new("UIA_TIMEOUT", "Pattern preparation did not complete"),
        };
        return Err(if error.message.contains("No pattern was sent.") { error }
            else { Error::new(error.code, format!("{} No pattern was sent.", error.message)) });
    };
    let mut result = json!({"ok":true,"lockedPattern":true,"app":app,"pattern":pattern});
    match completion {
        Ok(Some(())) => (),
        Ok(None) => unknown(&mut result, "provider deadline elapsed; the call may complete later", None),
        Err(e) => unknown(&mut result, e.code, Some(&e)),
    }
    Ok(result)
}
/// Shared by native dispatch and host tests. Even an unlock/stop during the read
/// preserves any fresh state, but invalidates indexes on every unknown outcome.
pub fn finish_observation<T>(slot: &mut Option<T>, mut result: Value,
    observed: Result<(Value, T)>, fence: Result<()>, changed: impl FnOnce(&T) -> bool) -> Value {
    *slot = None;
    let mut fresh = None;
    match observed {
        Ok((state, snapshot)) => {
            result["state"] = state;
            if changed(&snapshot) { fresh = Some(snapshot); }
            else { unknown(&mut result, "no accessibility change was observed", None); }
        }
        Err(e) => unknown(&mut result, &format!("fresh observation failed: {}", e.code), Some(&e)),
    }
    if let Err(e) = fence { unknown(&mut result, e.code, Some(&e)); }
    if result["outcome"] != "unknown" { *slot = fresh; }
    result
}
#[derive(Default)]
struct Delivery {
    cancelled: bool,
    issued: Option<&'static str>,
}
#[derive(Clone)]
pub struct Permit {
    delivery: Arc<Mutex<Delivery>>,
    deadline: Instant,
}
impl Permit {
    /// Call immediately before each mutation; a timed-out preparation cannot deliver later.
    pub fn check(&self) -> Result<()> {
        if self.delivery.lock().unwrap().cancelled || Instant::now() >= self.deadline {
            Err(Error::new(
                "UIA_TIMEOUT",
                "Locked-parent operation expired; no further pattern was sent",
            ))
        } else {
            Ok(())
        }
    }
    pub fn issue(&self, pattern: &'static str) -> Result<()> {
        let mut delivery = self.delivery.lock().unwrap();
        if delivery.cancelled || Instant::now() >= self.deadline {
            return Err(Error::new("UIA_TIMEOUT", "Pattern preparation expired"));
        }
        delivery.issued = Some(pattern);
        Ok(())
    }
    fn cancel(&self) { self.delivery.lock().unwrap().cancelled = true; }
    fn issued(&self) -> Option<&'static str> { self.delivery.lock().unwrap().issued }

}
pub struct Pending<T> {
    rx: mpsc::Receiver<T>,
    done: Arc<AtomicBool>,
    permit: Permit,
}
impl<T: Send + 'static> Pending<T> {
    pub fn start(
        timeout: Duration,
        work: impl FnOnce(Permit) -> T + Send + 'static,
    ) -> Result<Self> {
        let permit = Permit {
            delivery: Arc::new(Mutex::new(Delivery::default())),
            deadline: Instant::now() + timeout,
        };
        let done = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::channel();
        let p = permit.clone();
        let finished = done.clone();
        thread::Builder::new()
            .name("opencu-locked-uia".into())
            .spawn(move || {
                struct Done(Arc<AtomicBool>);
                impl Drop for Done {
                    fn drop(&mut self) {
                        self.0.store(true, SeqCst);
                    }
                }
                let _done = Done(finished);
                let _ = tx.send(work(p));
            })
            .map_err(|e| {
                Error::new("WINDOWS_API_ERROR", format!("Cannot start UIA worker: {e}"))
            })?;
        Ok(Self { rx, done, permit })
    }
    pub fn issued(&self) -> Option<&'static str> { self.permit.issued() }
    pub fn finished(&self) -> bool {
        self.done.load(SeqCst)
    }
    /// None means unknown outcome. Do not join, replay, or queue another task.
    pub fn wait(&self, mut fence: impl FnMut() -> Result<()>) -> Result<Option<T>> {
        loop {
            if let Err(e) = fence() {
                self.permit.cancel();
                return Err(e);
            }
            let remaining = self
                .permit
                .deadline
                .saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                self.permit.cancel();
                return Ok(None);
            }
            match self
                .rx
                .recv_timeout(remaining.min(Duration::from_millis(10)))
            {
                Ok(result) => {
                    if let Err(e) = fence() {
                        self.permit.cancel();
                        return Err(e);
                    }
                    return Ok(Some(result));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => (),
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    self.permit.cancel();
                    return Ok(None);
                }
            }
        }
    }
}
impl<T> Drop for Pending<T> {
    fn drop(&mut self) {
        self.permit.cancel();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn only_locked_child_and_exact_request_shape_use_patterns() {
        for method in ["click", "set_value", "perform_secondary_action"] {
            let args = json!({"element_index":1});
            assert!(use_patterns(true, Some(true), method, &args));
            for locked in [Some(true), Some(false), None] {
                assert!(!use_patterns(false, locked, method, &args));
            }
            for locked in [Some(false), None] {
                assert!(!use_patterns(true, locked, method, &args));
            }
        }
        for args in [json!({"x":1,"y":2}), json!({"element_index":0}),
            json!({"element_index":1,"key":"ctrl"}), json!({"element_index":1,"duration":0}),
            json!({"element_index":1,"click_count":2}), json!({"element_index":1,"mouse_button":"right"}),
            json!({"element_index":1,"x":0})] {
            assert!(!use_patterns(true, Some(true), "click", &args));
        }
        for method in ["paste", "type_text", "press_key", "drag", "scroll", "wait", "activate_app", "select_text"] {
            assert!(!use_patterns(true, Some(true), method, &json!({"element_index":1})));
        }
    }
    #[test]
    fn absent_invoke_does_not_hide_toggle_or_mask_provider_errors() {
        assert!(!pattern_present(0, false).unwrap());
        assert!(pattern_present(0, true).unwrap());
        assert!(!pattern_present(0x80040204u32 as i32, false).unwrap());
        assert_eq!(pattern_present(0x80004003u32 as i32, false).unwrap_err().code, "WINDOWS_API_ERROR");
        assert_eq!(pattern_present(0x80040201u32 as i32, false).unwrap_err().code, "STALE_ELEMENT");
        let chosen = select_click(|name| Ok(pattern_present(0, name == "Toggle")?.then_some(()))).unwrap();
        assert_eq!(chosen.0, "Toggle");
    }
    #[test]
    fn observation_comparison_ignores_capture_and_lock_guidance() {
        let before = "Window: fixture\nWindows input requires foreground focus.\n[1] Edit value=a\nScreenshot: 10 x 20";
        let same = "Window: fixture\nLocked-parent patterns.\n[1] Edit value=a";
        assert_eq!(observable(before), observable(same));
        assert_ne!(observable(before), observable(&same.replace("value=a", "value=b")));
    }
    #[test]
    fn priority_and_no_capability_refusal() {
        let mut available: Vec<String> = vec![
            "DoDefaultAction".into(),
            "Select".into(),
            "ExpandCollapse".into(),
            "Toggle".into(),
            "Invoke".into(),
        ];
        for expected in ["Select", "Invoke", "Toggle", "ExpandCollapse", "DoDefaultAction"] {
            assert_eq!(
                select_click(|a| Ok(available.iter().any(|s| s == a).then_some(())))
                    .unwrap()
                    .0,
                expected
            );
            available.retain(|a| a != expected);
        }
        assert_eq!(
            select_click(|a| Ok(available.iter().any(|s| s == a).then_some(())))
                .unwrap_err()
                .code,
            "UNSUPPORTED_ACTION"
        );
    }
    #[test]
    fn capability_error_never_tries_another_pattern() {
        let mut calls = vec![];
        let result = select_click::<()>(|name| {
            calls.push(name);
            Err(Error::new("UIA_TIMEOUT", "provider timed out"))
        });
        assert_eq!(result.unwrap_err().code, "UIA_TIMEOUT");
        assert_eq!(calls, vec!["Select"]);
    }
    #[test]
    fn already_entered_provider_can_finish_after_unknown_without_replay() {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (finished_tx, finished_rx) = mpsc::channel();
        let job = Pending::start(Duration::from_millis(100), move |permit| {
            permit.check().unwrap();
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap(); // Provider owns the call now; cancellation cannot undo it.
            finished_tx.send(1).unwrap();
        })
        .unwrap();
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(job.wait(|| Ok(())).unwrap().is_none());
        assert!(!job.finished());
        release_tx.send(()).unwrap();
        assert_eq!(finished_rx.recv_timeout(Duration::from_secs(1)).unwrap(), 1);
        assert!(finished_rx.try_recv().is_err());
    }
    #[test]
    fn blocked_provider_is_bounded_and_late_preparation_cannot_send() {
        let (release, blocked) = mpsc::channel();
        let (sent, observed) = mpsc::channel();
        let job = Pending::start(Duration::from_millis(40), move |permit| {
            blocked.recv().unwrap();
            sent.send(permit.check().is_ok()).unwrap();
        })
        .unwrap();
        let start = Instant::now();
        assert!(job.wait(|| Ok(())).unwrap().is_none());
        assert!(start.elapsed() < Duration::from_secs(1));
        assert!(!job.finished()); // The admission slot must remain occupied.
        release.send(()).unwrap();
        assert!(!observed.recv_timeout(Duration::from_secs(1)).unwrap());
    }
    #[test]
    fn stop_cancels_pending_preparation_and_success_is_returned_once() {
        let (release, blocked) = mpsc::channel();
        let (sent, observed) = mpsc::channel();
        let job = Pending::start(Duration::from_secs(1), move |permit| {
            blocked.recv().unwrap();
            sent.send(permit.check().is_ok()).unwrap();
        })
        .unwrap();
        assert_eq!(
            job.wait(|| Err(Error::new("USER_STOPPED", "stop")))
                .unwrap_err()
                .code,
            "USER_STOPPED"
        );
        release.send(()).unwrap();
        assert!(!observed.recv_timeout(Duration::from_secs(1)).unwrap());
        let job = Pending::start(Duration::from_secs(1), |_| 42).unwrap();
        assert_eq!(job.wait(|| Ok(())).unwrap(), Some(42));
    }
}

#[cfg(test)]
mod review_tests {
    use super::*;
    #[test]
    fn selection_wins_over_invoke_without_querying_it() {
        let mut queries = vec![];
        assert_eq!(select_click(|name| {
            queries.push(name);
            Ok(matches!(name, "Select" | "Invoke").then_some(()))
        }).unwrap().0, "Select");
        assert_eq!(queries, ["Select"]);
    }
    #[test]
    fn console_unknown_and_non_rdp_sessions_cannot_enable_patterns() {
        for protocol in [None, Some(0), Some(1), Some(3)] {
            assert_eq!(remote_session(protocol).unwrap_err().code, "INVALID_ARGUMENT");
        }
        assert!(remote_session(Some(2)).is_ok());
    }
    #[test]
    fn issued_errors_are_unknown_but_preflight_is_honest() {
        for code in ["STALE_WINDOW", "ELEVATED_TARGET", "WINDOWS_API_ERROR", "UIA_TIMEOUT", "SCREEN_LOCKED", "USER_STOPPED"] {
            let result = delivery_result(json!({}), Some("Invoke"), Err(Error::new(code, "fixture"))).unwrap();
            assert_eq!(result["outcome"], "unknown");
            assert_eq!(result["pattern"], "Invoke");
            assert!(result["message"].as_str().unwrap().contains("was dispatched"));
            assert_eq!(result["stop"]["code"].as_str(), (code == "USER_STOPPED").then_some(code));
        }
        let error = delivery_result(json!({}), None, Err(Error::new("SCREEN_LOCKED", "Parent state changed"))).unwrap_err();
        assert!(error.message.contains("No pattern was sent."));
        assert!(!error.message.contains("may have run"));
        assert!(!delivery_result(json!({}), None, Ok(None)).unwrap_err().message.contains("was dispatched"));
    }
    #[test]
    fn unknown_invalidates_native_indexes_until_explicit_observation() {
        for failure in [Some("SCREEN_LOCKED"), Some("USER_STOPPED"), None] {
            let mut snapshot = Some(42);
            let result = delivery_result(json!({}), Some("Invoke"), Ok(Some(()))).unwrap();
            let fence = failure.map_or(Ok(()), |code| Err(Error::new(code, "fixture")));
            let result = finish_observation(&mut snapshot, result, Ok((json!({"text":"fresh"}), 43)), fence,
                |_| failure.is_some()); // None exercises unchanged observation.
            assert_eq!(result["outcome"], "unknown");
            assert_eq!(result["state"]["text"], "fresh");
            assert_eq!(require_observation(snapshot.as_ref()).unwrap_err().code, "OBSERVATION_REQUIRED");
            snapshot = Some(44); // Explicit get_app_state installs the fresh snapshot.
            assert_eq!(*require_observation(snapshot.as_ref()).unwrap(), 44);
        }
        let mut snapshot = Some(42);
        let result = finish_observation(&mut snapshot, json!({}), Err(Error::new("STALE_WINDOW", "closed")), Ok(()), |_| true);
        assert_eq!(result["outcome"], "unknown");
        assert!(snapshot.is_none());
    }
    #[test]
    fn cancellation_prevents_late_issue_and_issued_call_is_not_replayed() {
        let (release, blocked) = mpsc::channel();
        let (sent, observed) = mpsc::channel();
        let pending = Pending::start(Duration::from_secs(1), move |permit| {
            blocked.recv().unwrap();
            sent.send(permit.issue("Toggle").is_ok()).unwrap();
        }).unwrap();
        assert!(pending.wait(|| Err(Error::new("SCREEN_LOCKED", "unlock"))).is_err());
        assert_eq!(pending.issued(), None);
        release.send(()).unwrap();
        assert!(!observed.recv_timeout(Duration::from_secs(1)).unwrap());

        let (entered, ready) = mpsc::channel();
        let (release, blocked) = mpsc::channel();
        let pending = Pending::start(Duration::from_secs(1), move |permit| {
            permit.issue("Invoke").unwrap();
            entered.send(()).unwrap();
            blocked.recv().unwrap();
        }).unwrap();
        ready.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(pending.wait(|| Err(Error::new("SCREEN_LOCKED", "unlock"))).is_err());
        assert_eq!(pending.issued(), Some("Invoke"));
        assert!(!pending.finished());
        release.send(()).unwrap();
    }
}
