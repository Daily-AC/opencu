use super::{
    apps::{App, Window},
    capture, safety,
};
use opencu_engine::{Error, Node, Rect, Result, Screenshot};
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use windows::{
    core::*,
    Win32::UI::{Accessibility::*, WindowsAndMessaging::*},
};
#[derive(Clone)]
pub struct Element {
    pub element: IUIAutomationElement,
    pub window: Window,
    pub actions: Vec<String>,
}
pub struct Snapshot {
    pub app: App,
    pub elements: Vec<Element>,
    pub image: Option<Screenshot>,
}
pub unsafe fn pattern<T: Interface>(el: &IUIAutomationElement, id: UIA_PATTERN_ID) -> Option<T> {
    el.GetCurrentPattern(id).ok()?.cast().ok()
}
pub unsafe fn actions(el: &IUIAutomationElement) -> Vec<String> {
    let mut out = vec![];
    if pattern::<IUIAutomationInvokePattern>(el, UIA_InvokePatternId).is_some() {
        out.push("Invoke");
    }
    if pattern::<IUIAutomationTogglePattern>(el, UIA_TogglePatternId).is_some() {
        out.push("Toggle");
    }
    if pattern::<IUIAutomationSelectionItemPattern>(el, UIA_SelectionItemPatternId).is_some() {
        out.extend(["Select", "AddToSelection", "RemoveFromSelection"]);
    }
    if pattern::<IUIAutomationExpandCollapsePattern>(el, UIA_ExpandCollapsePatternId).is_some() {
        out.extend(["Expand", "Collapse"]);
    }
    if let Some(p) =
        pattern::<IUIAutomationLegacyIAccessiblePattern>(el, UIA_LegacyIAccessiblePatternId)
    {
        if p.CurrentDefaultAction().is_ok_and(|s| !s.is_empty()) {
            out.push("DoDefaultAction");
        }
    }
    out.into_iter().map(String::from).collect()
}
pub fn rect(r: windows::Win32::Foundation::RECT) -> Rect {
    Rect {
        x: r.left,
        y: r.top,
        width: r.right - r.left,
        height: r.bottom - r.top,
    }
}
fn role(id: i32) -> String {
    let names = [
        "Button",
        "Calendar",
        "CheckBox",
        "ComboBox",
        "Edit",
        "Hyperlink",
        "Image",
        "ListItem",
        "List",
        "Menu",
        "MenuBar",
        "MenuItem",
        "ProgressBar",
        "RadioButton",
        "ScrollBar",
        "Slider",
        "Spinner",
        "StatusBar",
        "Tab",
        "TabItem",
        "Text",
        "ToolBar",
        "ToolTip",
        "Tree",
        "TreeItem",
        "Custom",
        "Group",
        "Thumb",
        "DataGrid",
        "DataItem",
        "Document",
        "SplitButton",
        "Window",
        "Pane",
        "Header",
        "HeaderItem",
        "Table",
        "TitleBar",
        "Separator",
        "SemanticZoom",
        "AppBar",
    ];
    names
        .get((id - 50000) as usize)
        .map(|s| s.to_string())
        .unwrap_or_else(|| format!("Control({id})"))
}
unsafe fn node(el: &IUIAutomationElement, children: bool) -> Result<Node> {
    let mut node = Node {
        role: role(el.CurrentControlType()?.0),
        name: el.CurrentName().map(|s| s.to_string()).unwrap_or_default(),
        automation_id: el
            .CurrentAutomationId()
            .map(|s| s.to_string())
            .unwrap_or_default(),
        class_name: el
            .CurrentClassName()
            .map(|s| s.to_string())
            .unwrap_or_default(),
        bounds: rect(el.CurrentBoundingRectangle()?),
        enabled: el.CurrentIsEnabled()?.as_bool(),
        offscreen: el.CurrentIsOffscreen()?.as_bool(),
        actions: actions(el),
        has_children: children,
        ..Default::default()
    };
    if !el.CurrentIsPassword().unwrap_or_default().as_bool() {
        if let Some(p) = pattern::<IUIAutomationValuePattern>(el, UIA_ValuePatternId) {
            node.value = p.CurrentValue().ok().map(|v| v.to_string());
            node.settable = p.CurrentIsReadOnly().is_ok_and(|v| !v.as_bool());
        } else if let Some(p) =
            pattern::<IUIAutomationRangeValuePattern>(el, UIA_RangeValuePatternId)
        {
            node.value = p.CurrentValue().ok().map(|v| v.to_string());
            node.settable = p.CurrentIsReadOnly().is_ok_and(|v| !v.as_bool());
        }
    }
    // Bound individual provider strings, as well as overall traversal.
    for s in [
        &mut node.name,
        &mut node.automation_id,
        &mut node.class_name,
    ] {
        if s.chars().count() > 4096 {
            *s = s.chars().take(4096).collect::<String>() + "…";
        }
    }
    if let Some(v) = &mut node.value {
        if v.chars().count() > 8192 {
            *v = v.chars().take(8192).collect::<String>() + "…";
        }
    }
    Ok(node)
}
pub unsafe fn observe(uia: &IUIAutomation, app: App, include: bool) -> Result<(Value, Snapshot)> {
    safety::desktop()?;
    let primary = app
        .windows
        .first()
        .ok_or_else(|| Error::new("NO_ACCESSIBLE_WINDOW", "No visible top-level window"))?;
    let mut text = format!(
        "App: {} ({})\nWindow: {}\nWindows input requires foreground focus.\n",
        app.name,
        app.id,
        json!(primary.title)
    );
    let mut snapshot = Snapshot {
        app: app.clone(),
        elements: vec![],
        image: None,
    };
    let walker = uia.RawViewWalker()?;
    let started = Instant::now();
    let mut inspected = 0;
    let mut truncated = false;
    for window in &app.windows {
        text += &format!(
            "Window: {} hwnd={:x}\n",
            json!(window.title),
            window.hwnd.0 as usize
        );
        let root = match uia.ElementFromHandle(window.hwnd) {
            Ok(r) => r,
            Err(e) => {
                text += &format!("UIA unavailable: {}\n", e.code());
                continue;
            }
        };
        let mut stack = vec![(root, 0usize, 0usize)];
        while let Some((el, depth, visual_depth)) = stack.pop() {
            if inspected >= 8000
                || snapshot.elements.len() >= 1200
                || text.len() > 180000
                || started.elapsed() > Duration::from_secs(8)
            {
                truncated = true;
                break;
            }
            inspected += 1;
            let child = if depth < 120 {
                walker.GetFirstChildElement(&el).ok()
            } else {
                truncated = true;
                None
            };
            // Push only the next sibling, not every sibling at once: bounded work
            // even for a broken provider. Structural depth doesn't consume display depth.
            if depth > 0 {
                if let Ok(next) = walker.GetNextSiblingElement(&el) {
                    stack.push((next, depth, visual_depth));
                }
            }
            let node = match node(&el, child.is_some()) {
                Ok(n) => n,
                Err(_) => {
                    text += "[UIA element unavailable during read]\n";
                    if let Some(child) = child {
                        stack.push((child, depth + 1, visual_depth));
                    }
                    continue;
                }
            };
            let visible = node.visible_in_tree();
            if visible {
                let index = snapshot.elements.len() + 1;
                text += &(node.line(index, visual_depth) + "\n");
                snapshot.elements.push(Element {
                    element: el.clone(),
                    window: window.clone(),
                    actions: node.actions,
                });
            }
            if let Some(child) = child {
                stack.push((child, depth + 1, visual_depth + usize::from(visible)));
            }
        }
        if truncated {
            break;
        }
    }
    if truncated {
        text+="Tree truncated: limit 1200 listed / 8000 inspected nodes, depth 120, 180000 bytes, or 8 seconds.\n";
    }
    let mut result = json!({"text":text,"app":app.json()});
    if include {
        if IsIconic(primary.hwnd).as_bool() {
            result["text"] = json!(format!(
                "{text}Screenshot unavailable: target window is minimized; activate it first.\n"
            ));
        } else {
            let bounds = primary.rect()?;
            let dpi = primary.dpi();
            match capture::capture(primary, bounds) {
                Ok((png, width, height)) => {
                    if primary.rect()? != bounds || primary.dpi() != dpi {
                        return Err(Error::new(
                            "WINDOW_CHANGED",
                            "Window moved or resized during capture; read state again",
                        ));
                    }
                    snapshot.image = Some(Screenshot {
                        bounds,
                        width,
                        height,
                        dpi,
                    });
                    result["screenshot"] = json!({"data":opencu_engine::base64(&png),"mimeType":"image/png","width":width,"height":height});
                    result["text"]=json!(format!("{text}Screenshot: {width} x {height} pixels; physical window origin ({},{}), DPI {dpi}.\n",bounds.x,bounds.y));
                }
                Err(e) => {
                    result["text"] = json!(format!(
                        "{text}Screenshot unavailable: {}: {}\n",
                        e.code, e.message
                    ));
                }
            }
        }
    }
    safety::desktop()?;
    Ok((result, snapshot))
}
