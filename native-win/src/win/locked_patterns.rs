//! Pattern-only path. This module must never activate, focus, or synthesize input.
use super::{
    observe::{Element, Snapshot},
    safety::{self, LockedGuard},
};
use opencu_engine::{
    locked_patterns::{self, Pending, Permit},
    string, Error, Result,
};
use serde_json::Value;
use std::time::Duration;
use windows::{
    core::*,
    Win32::{
        System::WinRT::*,
        UI::Accessibility::*,
    },
};

#[derive(Default)]
pub struct Worker {
    pending: Option<Pending<Result<String>>>,
}
impl Worker {
    pub fn idle(&mut self) -> Result<()> {
        if self.pending.as_ref().is_some_and(|p| !p.finished()) {
            return Err(Error::new("PATTERN_ACTION_PENDING", "The previous UIA call is still outstanding; no new input was sent. Read state and let the person resolve any dialog. Never replay or reconnect to bypass this fence."));
        }
        self.pending = None;
        Ok(())
    }
    pub unsafe fn perform(
        &mut self,
        method: &str,
        args: &Value,
        uia: &IUIAutomation,
        s: &mut Snapshot,
        g: &mut LockedGuard<'_>,
    ) -> Result<Value> {
        self.idle()?;
        let index = args["element_index"].as_u64().unwrap() as usize;
        let e = s
            .elements
            .get(index - 1)
            .ok_or_else(|| Error::new("STALE_ELEMENT", "Read state again"))?
            .clone();
        g.check()?;
        safety::target(&e.window)?;
        let work = MtaWork {
            element: e,
            uia: uia.clone(),
            method: method.into(),
            args: args.clone(),
            fence: g.worker_fence(),
        };
        self.pending = Some(Pending::start(Duration::from_secs(3), move |permit| {
            work.run(permit)
        })?);
        let pending = self.pending.as_ref().unwrap();
        let completion = pending.wait(|| g.check())
            .and_then(|result| result.transpose())
            .and_then(|result| g.finish().map(|_| result.map(|_| ())));
        locked_patterns::delivery_result(s.app.json(), pending.issued(), completion)
    }
}
// Engine and worker both join the process MTA, which remains alive for the
// connection. COM permits direct interface sharing inside one MTA; these retained
// UIA interfaces are never used on an STA. Only one mutation task can run;
// explicit reads may use the MTA while a timed-out provider remains outstanding. HWND is an
// identity, not an owned resource. Keep this exception local, not a blanket Send
// impl on UIA elements or Window. Drop interfaces before uninitializing COM.
struct MtaWork {
    element: Element,
    uia: IUIAutomation,
    method: String,
    args: Value,
    fence: safety::LockedFence,
}
unsafe impl Send for MtaWork {}
impl MtaWork {
    fn run(self, permit: Permit) -> Result<String> {
        unsafe {
            RoInitialize(RO_INIT_MULTITHREADED)?;
            let apartment = super::Apartment;
            let result = self.execute(&permit);
            drop(self);
            drop(apartment);
            result
        }
    }
    unsafe fn checkpoint(&self, permit: &Permit) -> Result<()> {
        permit.check()?;
        self.fence.check()?;
        safety::target(&self.element.window)?;
        permit.check()
    }
    unsafe fn execute(&self, permit: &Permit) -> Result<String> {
        self.checkpoint(permit)?;
        let e = &self.element.element;
        if !e.CurrentIsEnabled()?.as_bool() {
            return Err(Error::new(
                "ELEMENT_DISABLED",
                "The target element is disabled",
            ));
        }
        // Prove live attachment inside the exact observed top-level window.
        let root = self.uia.ElementFromHandle(self.element.window.hwnd)?;
        let walker = self.uia.RawViewWalker()?;
        let mut chain = vec![e.clone()];
        for _ in 0..128 {
            permit.check()?;
            let current = chain.last().unwrap();
            if self.uia.CompareElements(current, &root)?.as_bool() {
                break;
            }
            match walker.GetParentElement(current) {
                Ok(parent) => chain.push(parent),
                Err(e) if matches!(e.code().0 as u32, 0 | 0x80004003) => {
                    return Err(Error::new(
                        "STALE_ELEMENT",
                        "The indexed control is detached from its observed window",
                    ));
                }
                Err(e) => return Err(e.into()),
            }
        }
        if !self
            .uia
            .CompareElements(chain.last().unwrap(), &root)?
            .as_bool()
        {
            return Err(Error::new(
                "STALE_ELEMENT",
                "The indexed control is no longer attached to its observed window",
            ));
        }
        let action = match self.method.as_str() {
            "click" => {
                // Query in priority order, retain the chosen interface, and never
                // try another pattern after sending an operation.
                locked_patterns::select_click(|name| named(e, name))?.1
            }
            "perform_secondary_action" => {
                let name = string(&self.args, "action")?;
                if !self.element.actions.iter().any(|a| a == name) {
                    return Err(locked_patterns::required());
                }
                named(e, name)?.ok_or_else(locked_patterns::required)?
            }
            "set_value" => {
                let value = string(&self.args, "value")?;
                if let Some(p) = query::<IUIAutomationValuePattern>(e, UIA_ValuePatternId)? {
                    if p.CurrentIsReadOnly()?.as_bool() {
                        return Err(Error::new("ATTRIBUTE_NOT_SETTABLE", "Value is read-only"));
                    }
                    Action::Value(p, BSTR::from(value))
                } else {
                    return Err(locked_patterns::required());
                }
            }
            _ => return Err(locked_patterns::required()),
        };
        self.checkpoint(permit)?;
        permit.issue(action.name())?;
        // The provider may close this window or exit the app. Never revalidate
        // its target after dispatch, and never turn a dispatched error into failure.
        action.send().map(String::from)
    }
}
unsafe fn query<T: Interface>(e: &IUIAutomationElement, id: UIA_PATTERN_ID) -> Result<Option<T>> {
    let mut raw = std::ptr::null_mut();
    let hr = (Interface::vtable(e).GetCurrentPattern)(Interface::as_raw(e), id, &mut raw);
    let object = (!raw.is_null()).then(|| IUnknown::from_raw(raw));
    if !locked_patterns::pattern_present(hr.0, object.is_some())? { return Ok(None); }
    object.map(|p| p.cast().map_err(Error::from)).transpose()
}

enum Action {
    Invoke(IUIAutomationInvokePattern),
    Toggle(IUIAutomationTogglePattern),
    Select(IUIAutomationSelectionItemPattern, String),
    Expand(IUIAutomationExpandCollapsePattern, bool),
    Legacy(IUIAutomationLegacyIAccessiblePattern),
    Value(IUIAutomationValuePattern, BSTR),
}
unsafe fn named(e: &IUIAutomationElement, name: &str) -> Result<Option<Action>> {
    Ok(match name {
        "Invoke" => query(e, UIA_InvokePatternId)?.map(Action::Invoke),
        "Toggle" => query(e, UIA_TogglePatternId)?.map(Action::Toggle),
        "Select" | "AddToSelection" | "RemoveFromSelection" => {
            query(e, UIA_SelectionItemPatternId)?.map(|p| Action::Select(p, name.into()))
        }
        "ExpandCollapse" => {
            match query::<IUIAutomationExpandCollapsePattern>(e, UIA_ExpandCollapsePatternId)? {
                Some(p) => {
                    let state = p.CurrentExpandCollapseState()?;
                    if state == ExpandCollapseState_Collapsed || state == ExpandCollapseState_PartiallyExpanded {
                        Some(Action::Expand(p, true))
                    } else if state == ExpandCollapseState_Expanded {
                        Some(Action::Expand(p, false))
                    } else { None } // A leaf has no expand/collapse action; try Legacy.
                },
                None => None,
            }
        }
        "Expand" | "Collapse" => {
            query(e, UIA_ExpandCollapsePatternId)?.map(|p| Action::Expand(p, name == "Expand"))
        }
        "DoDefaultAction" => {
            match query::<IUIAutomationLegacyIAccessiblePattern>(e, UIA_LegacyIAccessiblePatternId)?
            {
                Some(p) if !p.CurrentDefaultAction()?.is_empty() => Some(Action::Legacy(p)),
                _ => None,
            }
        }
        _ => None,
    })
}
impl Action {
    fn name(&self) -> &'static str {
        match self {
            Self::Invoke(_) => "Invoke",
            Self::Toggle(_) => "Toggle",
            Self::Select(_, action) => match action.as_str() {
                "Select" => "Select", "AddToSelection" => "AddToSelection", _ => "RemoveFromSelection",
            },
            Self::Expand(_, true) => "Expand",
            Self::Expand(_, false) => "Collapse",
            Self::Legacy(_) => "DoDefaultAction",
            Self::Value(_, _) => "Value.SetValue",
        }
    }
    unsafe fn send(self) -> Result<&'static str> {
        Ok(match self {
            Self::Invoke(p) => {
                p.Invoke()?;
                "Invoke"
            }
            Self::Toggle(p) => {
                p.Toggle()?;
                "Toggle"
            }
            Self::Select(p, action) => match action.as_str() {
                "Select" => {
                    p.Select()?;
                    "Select"
                }
                "AddToSelection" => {
                    p.AddToSelection()?;
                    "AddToSelection"
                }
                _ => {
                    p.RemoveFromSelection()?;
                    "RemoveFromSelection"
                }
            },
            Self::Expand(p, true) => {
                p.Expand()?;
                "Expand"
            }
            Self::Expand(p, false) => {
                p.Collapse()?;
                "Collapse"
            }
            Self::Legacy(p) => {
                p.DoDefaultAction()?;
                "DoDefaultAction"
            }
            Self::Value(p, value) => {
                p.SetValue(&value)?;
                "Value.SetValue"
            }

        })
    }
}
