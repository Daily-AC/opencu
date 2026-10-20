//! Platform-independent policy and bounded execution for UIA-only delivery.
use crate::{Error, Result};
use serde_json::Value;
use std::{
    sync::{
        atomic::{AtomicBool, Ordering::SeqCst},
        mpsc, Arc,
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
    for name in ["Invoke", "Toggle", "Select", "ExpandCollapse", "DoDefaultAction"] {
        if let Some(pattern) = query(name)? {
            return Ok((name, pattern));
        }
    }
    Err(required())
}
#[derive(Clone)]
pub struct Permit {
    cancelled: Arc<AtomicBool>,
    deadline: Instant,
}
impl Permit {
    /// Call immediately before each mutation; a timed-out preparation cannot deliver later.
    pub fn check(&self) -> Result<()> {
        if self.cancelled.load(SeqCst) || Instant::now() >= self.deadline {
            Err(Error::new(
                "UIA_TIMEOUT",
                "Locked-parent operation expired; no further pattern was sent",
            ))
        } else {
            Ok(())
        }
    }
    fn cancel(&self) {
        self.cancelled.store(true, SeqCst);
    }
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
            cancelled: Arc::new(AtomicBool::new(false)),
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
                    fence()?;
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
        for expected in ["Invoke", "Toggle", "Select", "ExpandCollapse", "DoDefaultAction"] {
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
        assert_eq!(calls, vec!["Invoke"]);
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
