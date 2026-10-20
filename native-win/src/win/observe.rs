use super::{
    apps::{self, App, Window},
    capture, safety,
};
use opencu_engine::{observation::*, Error, Node, Rect, Result, Screenshot};
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
#[derive(Clone)]
pub struct Scope {
    pub root: Option<Element>,
    pub identity: String,
}
pub struct Snapshot {
    pub app: App,
    pub keyboard_window: Window,
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
unsafe fn cache_request(uia: &IUIAutomation) -> Result<IUIAutomationCacheRequest> {
    let cache = uia.CreateCacheRequest()?;
    cache.SetTreeScope(TreeScope_Element)?;
    cache.SetTreeFilter(&uia.RawViewCondition()?)?;
    for property in [
        UIA_ControlTypePropertyId,
        UIA_NamePropertyId,
        UIA_AutomationIdPropertyId,
        UIA_ClassNamePropertyId,
        UIA_BoundingRectanglePropertyId,
        UIA_IsEnabledPropertyId,
        UIA_IsOffscreenPropertyId,
        UIA_IsKeyboardFocusablePropertyId,
        UIA_HasKeyboardFocusPropertyId,
        UIA_FrameworkIdPropertyId,
        UIA_ToggleToggleStatePropertyId,
        UIA_SelectionItemIsSelectedPropertyId,
        UIA_ExpandCollapseExpandCollapseStatePropertyId,
        UIA_RangeValueMinimumPropertyId,
        UIA_RangeValueMaximumPropertyId,
        UIA_RangeValueSmallChangePropertyId,
        UIA_RangeValueLargeChangePropertyId,
        UIA_IsPasswordPropertyId,
        UIA_ValueIsReadOnlyPropertyId,
        UIA_RangeValueIsReadOnlyPropertyId,
        UIA_LegacyIAccessibleDefaultActionPropertyId,
    ] {
        cache.AddProperty(property)?;
    }
    for pattern in [
        UIA_InvokePatternId,
        UIA_TogglePatternId,
        UIA_SelectionItemPatternId,
        UIA_ExpandCollapsePatternId,
        UIA_LegacyIAccessiblePatternId,
        UIA_ValuePatternId,
        UIA_RangeValuePatternId,
    ] {
        cache.AddPattern(pattern)?;
    }
    // Value content is deliberately not in this request. Read it only after the
    // password flag was successfully read as false.
    Ok(cache)
}
unsafe fn cached<T: Interface>(el: &IUIAutomationElement, id: UIA_PATTERN_ID) -> Option<T> {
    el.GetCachedPattern(id).ok()?.cast().ok()
}
unsafe fn node(el: &IUIAutomationElement, children: bool) -> Result<Node> {
    let public = opencu_engine::may_read_value(el.CachedIsPassword().ok().map(|v| v.as_bool()));
    let mut node = Node {
        role: role(el.CachedControlType()?.0),
        name: if public {
            el.CachedName().map(|s| s.to_string()).unwrap_or_default()
        } else {
            "[protected]".into()
        },
        automation_id: el
            .CachedAutomationId()
            .map(|s| s.to_string())
            .unwrap_or_default(),
        class_name: el
            .CachedClassName()
            .map(|s| s.to_string())
            .unwrap_or_default(),
        bounds: rect(el.CachedBoundingRectangle()?),
        enabled: el.CachedIsEnabled()?.as_bool(),
        offscreen: el.CachedIsOffscreen()?.as_bool(),
        has_children: children,
        focusable: el.CachedIsKeyboardFocusable().unwrap_or_default().as_bool(),
        focused: el.CachedHasKeyboardFocus().unwrap_or_default().as_bool(),
        ..Default::default()
    };
    if cached::<IUIAutomationInvokePattern>(el, UIA_InvokePatternId).is_some() {
        node.actions.push("Invoke".into());
    }
    if cached::<IUIAutomationTogglePattern>(el, UIA_TogglePatternId).is_some() {
        node.actions.push("Toggle".into());
    }
    if cached::<IUIAutomationSelectionItemPattern>(el, UIA_SelectionItemPatternId).is_some() {
        node.actions
            .extend(["Select", "AddToSelection", "RemoveFromSelection"].map(String::from));
    }
    if cached::<IUIAutomationExpandCollapsePattern>(el, UIA_ExpandCollapsePatternId).is_some() {
        node.actions
            .extend(["Expand", "Collapse"].map(String::from));
    }
    if let Some(p) =
        cached::<IUIAutomationLegacyIAccessiblePattern>(el, UIA_LegacyIAccessiblePatternId)
    {
        if p.CachedDefaultAction().is_ok_and(|s| !s.is_empty()) {
            node.actions.push("DoDefaultAction".into());
        }
    }
    if let Some(p) = cached::<IUIAutomationTogglePattern>(el, UIA_TogglePatternId) {
        node.toggle = p.CachedToggleState().ok().map(|v| match v.0 {
            0 => "off".into(),
            1 => "on".into(),
            2 => "mixed".into(),
            n => n.to_string(),
        });
    }
    if let Some(p) = cached::<IUIAutomationSelectionItemPattern>(el, UIA_SelectionItemPatternId) {
        node.selected = p.CachedIsSelected().ok().map(|v| v.as_bool());
    }
    if let Some(p) = cached::<IUIAutomationExpandCollapsePattern>(el, UIA_ExpandCollapsePatternId) {
        node.expanded = p.CachedExpandCollapseState().ok().map(|v| match v.0 {
            0 => "collapsed".into(),
            1 => "expanded".into(),
            2 => "partial".into(),
            3 => "leaf".into(),
            n => n.to_string(),
        });
    }
    if public {
        if let Some(p) = cached::<IUIAutomationValuePattern>(el, UIA_ValuePatternId) {
            // Recheck the live flag immediately before fetching content as a
            // provider can change its secure state since the metadata snapshot.
            if el.CurrentIsPassword().is_ok_and(|v| !v.as_bool()) {
                node.value = p.CurrentValue().ok().map(|v| v.to_string());
            }
            node.settable = p.CachedIsReadOnly().is_ok_and(|v| !v.as_bool());
        }
        if let Some(p) = cached::<IUIAutomationRangeValuePattern>(el, UIA_RangeValuePatternId) {
            if el.CurrentIsPassword().is_ok_and(|v| !v.as_bool()) {
                node.value = p.CurrentValue().ok().map(|v| v.to_string());
            }
            node.settable = p.CachedIsReadOnly().is_ok_and(|v| !v.as_bool());
            if let (Ok(min), Ok(max), Ok(small), Ok(large)) = (
                p.CachedMinimum(),
                p.CachedMaximum(),
                p.CachedSmallChange(),
                p.CachedLargeChange(),
            ) {
                node.range = Some((min, max, small, large));
            }
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
// UIA owns the identity semantics; never merge controls by title, role or bounds.
pub unsafe fn runtime_id(el: &IUIAutomationElement) -> Option<Vec<i32>> {
    use windows::Win32::System::Ole::*;
    let array = el.GetRuntimeId().ok()?;
    if array.is_null() {
        return None;
    }
    let result = (|| {
        if SafeArrayGetDim(array) != 1 || SafeArrayGetElemsize(array) != 4 {
            return None;
        }
        let low = SafeArrayGetLBound(array, 1).ok()?;
        let high = SafeArrayGetUBound(array, 1).ok()?;
        if !(1..=256).contains(&(high as i64 - low as i64 + 1)) {
            return None;
        }
        let mut id = vec![];
        for i in low..=high {
            let mut value = 0i32;
            SafeArrayGetElement(array, &i, &mut value as *mut _ as _).ok()?;
            id.push(value);
        }
        Some(id)
    })();
    let _ = SafeArrayDestroy(array);
    result
}
// Walk live ancestry to the exact retained window, not merely a same-PID HWND.
unsafe fn scope_attached(uia: &IUIAutomation, element: &Element) -> bool {
    if element.window.validate().is_err() { return false; }
    let Ok(root) = uia.ElementFromHandle(element.window.hwnd) else { return false; };
    let Ok(walker) = uia.RawViewWalker() else { return false; };
    let mut current = element.element.clone();
    for _ in 0..=120 {
        if uia.CompareElements(&current, &root).is_ok_and(|v| v.as_bool()) { return true; }
        let Ok(parent) = walker.GetParentElement(&current) else { return false; };
        current = parent;
    }
    false
}
pub unsafe fn observe(uia: &IUIAutomation, app: App, include: bool, scope: Option<&Scope>) -> Result<(Value, Snapshot)> {
    safety::desktop()?;
    // Start with the resolver's candidates; tool-only title matches may expand
    // to content below. Discover owned windows and summaries across the PID.
    let desktop = apps::observation_windows()?;
    let desktop_info: Vec<_> = desktop.iter().map(|w| apps::observation_info(w)).collect();
    let mut candidates: Vec<_> = desktop_info
        .iter()
        .filter(|info| {
            desktop
                .iter()
                .find(|w| w.hwnd.0 as usize == info.hwnd)
                .is_some_and(|w| {
                    app.windows
                        .iter()
                        .any(|c| c.hwnd == w.hwnd && c.pid == w.pid && c.created == w.created)
                })
        })
        .cloned()
        .collect();
    // An explicit tool title must not force a transparent capture when this
    // process has usable content. Preserve title restriction for content matches.
    if !candidates
        .iter()
        .any(|w| w.visible && !w.minimized && !w.tool)
    {
        candidates = desktop_info
            .iter()
            .zip(&desktop)
            .filter(|(_, w)| {
                w.pid == app.pid
                    && app
                        .windows
                        .iter()
                        .any(|c| c.pid == w.pid && c.created == w.created)
            })
            .map(|(info, _)| info.clone())
            .collect();
    }
    let selected = capture_target(&candidates, GetForegroundWindow().0 as usize)
        .ok_or_else(|| Error::new("NO_ACCESSIBLE_WINDOW", "No visible top-level window"))?;
    let primary = desktop
        .iter()
        .find(|w| w.hwnd.0 as usize == candidates[selected].hwnd)
        .unwrap();
    let family: Vec<_> = desktop_info
        .iter()
        .zip(&desktop)
        .filter(|(_, w)| w.pid == app.pid && w.created == primary.created)
        .map(|(info, _)| info.clone())
        .collect();
    // The existing input contract uses windows[0] for captured coordinates.
    // Keep that invariant without changing input routing or authorization.
    let mut app = app;
    app.windows.retain(|w| w.hwnd != primary.hwnd);
    app.windows.insert(0, primary.clone());
    let mut text = format!(
        "App: {} ({})\nWindow: {}\nWindows input requires foreground focus.\n",
        app.name,
        app.id,
        json!(primary.title)
    );
    text += &format!("Capture target: hwnd={:x} class={} (foreground non-tool, otherwise topmost visible non-tool window).\n", primary.hwnd.0 as usize, json!(primary.class_name));
    let mut snapshot = Snapshot {
        app: app.clone(),
        keyboard_window: primary.clone(),
        elements: vec![],
        image: None,
    };
    let walker = uia.RawViewWalker()?;
    let cache = cache_request(uia)?;
    let scoped = live_scope(scope.and_then(|s| s.root.as_ref()), |e| {
        e.window.pid == app.pid && e.window.created == primary.created
            && family.iter().any(|w| w.hwnd == e.window.hwnd.0 as usize && w.visible && !w.minimized)
            && owned_by(&family, e.window.hwnd.0 as usize, primary.hwnd.0 as usize)
            && scope_attached(uia, e)
    }).and_then(|e| {
        let root = e.element.BuildUpdatedCache(&cache).ok()?;
        let n = node(&root, true).ok()?;
        if zero_size_omitted(n.bounds, n.focused) { return None; }
        Some((e, root))
    });
    text += scope_gone_line(scope.is_some(), scoped.is_some());
    let started = Instant::now();
    let mut inspected = 0;
    let mut truncated = false;
    let mut identities = ElementIdentities::default();
    let mut identity_missing = Vec::<usize>::new();
    let mut hidden = 0;
    let mut zero_size = 0;
    // Target first, then its owned descendants; all unrelated windows are summaries.
    let mut order: Vec<_> = desktop
        .iter()
        .enumerate()
        .filter(|(_, w)| w.pid == app.pid && w.created == primary.created)
        .collect();
    order.sort_by_key(|(_, w)| w.hwnd != primary.hwnd);
    for (desktop_index, window) in order {
        let info = &desktop_info[desktop_index];
        if !info.visible {
            hidden += 1;
            continue;
        }
        let tree = info.visible
            && !info.minimized
            && owned_by(&family, info.hwnd, primary.hwnd.0 as usize);
        text += &window_line(
            info,
            covered(info.bounds, &desktop_info[..desktop_index]),
            !tree,
        );
        if !tree || scoped.as_ref().is_some_and(|(e, _)| e.window.hwnd != window.hwnd) {
            continue;
        }
        if inspected >= 8000
            || snapshot.elements.len() >= 1200
            || text.len() > 180000
            || started.elapsed() > Duration::from_secs(8)
        {
            truncated = true;
            continue;
        }
        let client = apps::client_rect(window);
        let mut omitted = 0usize;
        let root = match scoped.as_ref().map(|(_, root)| Ok(root.clone()))
            .unwrap_or_else(|| uia.ElementFromHandleBuildCache(window.hwnd, &cache)) {
            Ok(r) => r,
            Err(e) => {
                text += &format!("UIA unavailable: {}\n", e.code());
                continue;
            }
        };
        let mut stack = vec![(root, 0usize, 0usize, false)];
        while let Some((el, depth, visual_depth, chromium)) = stack.pop() {
            if inspected >= 8000
                || snapshot.elements.len() >= 1200
                || text.len() > 180000
                || started.elapsed() > Duration::from_secs(8)
            {
                truncated = true;
                break;
            }
            inspected += 1;
            let public =
                opencu_engine::may_read_value(el.CachedIsPassword().ok().map(|v| v.as_bool()));
            let child = if !public {
                None
            } else if depth < 120 {
                walker.GetFirstChildElementBuildCache(&el, &cache).ok()
            } else {
                truncated = true;
                None
            };
            // Push only the next sibling, not every sibling at once: bounded work
            // even for a broken provider. Structural depth doesn't consume display depth.
            if depth > 0 {
                if let Ok(next) = walker.GetNextSiblingElementBuildCache(&el, &cache) {
                    stack.push((next, depth, visual_depth, chromium));
                }
            }
            let node = match node(&el, child.is_some()) {
                Ok(n) => n,
                Err(_) => {
                    text += "[UIA element unavailable during read]\n";
                    if let Some(child) = child {
                        stack.push((child, depth + 1, visual_depth, chromium));
                    }
                    continue;
                }
            };
            let chromium = chromium_context(
                chromium,
                &node.role,
                &node.class_name,
                &el.CachedFrameworkId()
                    .map(|s| s.to_string())
                    .unwrap_or_default(),
            );
            let zero = zero_size_omitted(node.bounds, node.focused);
            zero_size += usize::from(zero);
            let outside = !zero && !node.focused && outside_chromium(chromium, node.bounds, client);
            if outside {
                omitted += 1;
            }
            let scope_root = scoped.is_some() && depth == 0;
            let eligible = !zero && (scope_root || (!outside && node.visible_in_tree()));
            let id = if eligible { runtime_id(&el) } else { None };
            let duplicate = eligible
                && (id.as_ref().and_then(|id| identities.index(id)).is_some()
                    || if id.is_none() {
                        snapshot.elements.iter().any(|previous| {
                            uia.CompareElements(&previous.element, &el)
                                .is_ok_and(|v| v.as_bool())
                        })
                    } else {
                        identity_missing.iter().any(|&i| {
                            uia.CompareElements(&snapshot.elements[i].element, &el)
                                .is_ok_and(|v| v.as_bool())
                        })
                    });
            // Do not prune descendants: a provider can expose new children via
            // another root. Only the first occurrence receives an action index.
            let visible = eligible && !duplicate;
            if visible {
                let index = snapshot.elements.len() + 1;
                if let Some(id) = id {
                    identities.remember(id, index);
                } else {
                    identity_missing.push(snapshot.elements.len());
                }
                text += &(node.line(index, visual_depth) + "\n");
                snapshot.elements.push(Element {
                    element: el.clone(),
                    window: window.clone(),
                    actions: node.actions,
                });
            }
            if let Some(child) = child {
                stack.push((
                    child,
                    depth + 1,
                    visual_depth + usize::from(visible),
                    chromium,
                ));
            }
        }
        text += &omitted_line(omitted);
        // Continue summaries even if a tree exhausts its traversal budget.
    }
    text += &zero_size_line(zero_size);
    text += &hidden_windows_line(hidden);
    if truncated {
        text+="Tree truncated: limit 1200 listed / 8000 inspected nodes, depth 120, 180000 bytes, or 8 seconds.\n";
    }
    let mut result = json!({"text":text,"app":app.json()});
    if let Some(scope) = scope {
        result["scopeRoot"] = json!(format!("{}:{}", if scoped.is_some() { "live" } else { "gone" }, scope.identity));
    }
    if include {
        if IsIconic(primary.hwnd).as_bool() {
            result["text"] = json!(format!(
                "{text}Screenshot unavailable: target window is minimized; activate it first.\n"
            ));
        } else {
            let bounds = primary.capture_rect()?;
            let dpi = primary.dpi();
            match capture::capture(primary, bounds) {
                Ok((png, width, height)) => {
                    if primary.capture_rect()? != bounds || primary.dpi() != dpi {
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
