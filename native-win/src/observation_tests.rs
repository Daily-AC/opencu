use crate::{observation::*, Node, Rect};
fn rect(x: i32, y: i32, width: i32, height: i32) -> Rect {
    Rect {
        x,
        y,
        width,
        height,
    }
}
fn window(hwnd: usize, owner: Option<usize>) -> WindowInfo {
    WindowInfo {
        hwnd,
        owner,
        title: format!("Fixture window {hwnd}"),
        class_name: "FixtureWindow".into(),
        bounds: rect(0, 0, 1920, 1080),
        visible: true,
        opaque: true,
        ..Default::default()
    }
}
fn node(role: &str, name: &str, actions: &[&str]) -> Node {
    Node {
        role: role.into(),
        name: name.into(),
        enabled: true,
        bounds: rect(20, 20, 120, 30),
        actions: actions.iter().map(|s| s.to_string()).collect(),
        ..Default::default()
    }
}
#[test]
fn foreground_then_z_order_never_area() {
    let mut ws = vec![window(1, None), window(2, None), window(3, None)];
    ws[0].tool = true;
    ws[1].bounds = rect(0, 0, 300, 200);
    assert_eq!(capture_target(&ws, 3), Some(2));
    assert_eq!(capture_target(&ws, 1), Some(1)); // foreground tool cannot displace content
    assert_eq!(capture_target(&ws, 999), Some(1)); // small topmost content beats area
    ws[1].minimized = true;
    assert_eq!(capture_target(&ws, 2), Some(2));
    ws[2].visible = false;
    assert_eq!(capture_target(&ws, 999), Some(0));
    ws[0].visible = false;
    assert_eq!(capture_target(&ws, 999), Some(1)); // explicit minimized fallback
    ws[1].visible = false;
    assert_eq!(capture_target(&ws, 999), None);
}
#[test]
fn ownership_is_directional_and_bounded() {
    let mut ws = vec![
        window(1, None),
        window(2, Some(1)),
        window(3, Some(2)),
        window(4, None),
        window(5, Some(1)),
    ];
    assert!(owned_by(&ws, 3, 1));
    assert!(owned_by(&ws, 2, 2));
    assert!(!owned_by(&ws, 1, 2));
    assert!(!owned_by(&ws, 5, 2));
    assert!(!owned_by(&ws, 4, 1));
    ws[1].owner = Some(3);
    assert!(!owned_by(&ws, 3, 1));
    ws[1].owner = Some(999); // missing/foreign owner never joins this PID's tree
    assert!(!owned_by(&ws, 2, 1));
}
#[test]
fn coverage_and_summary_are_observation_only() {
    let r = rect(-100, 20, 200, 80);
    let mut a = window(1, None);
    a.bounds = rect(-100, 20, 100, 80);
    let mut b = window(2, None);
    b.bounds = rect(0, 20, 100, 80);
    assert!(!covered(r, &[a.clone()]));
    assert!(covered(r, &[a.clone(), b.clone()]));
    b.opaque = false;
    assert!(!covered(r, &[a, b]));
    let mut w = window(4, None);
    assert!(window_line(&w, true, true).contains("hwnd=4 covered"));
    w.visible = false;
    assert!(window_line(&w, true, true).ends_with("hidden\n"));
    w.title = "line\nbreak".into();
    assert_eq!(window_line(&w, false, true).lines().count(), 1);
}
#[test]
fn chromium_clips_only_fully_outside_and_keeps_unknown_native_geometry() {
    let client = Some(rect(-100, 20, 200, 100));
    assert!(chromium_context(false, "Document", "", "Chrome"));
    assert!(chromium_context(
        false,
        "Document",
        "Chrome_RenderWidgetHostHWND",
        ""
    ));
    assert!(!chromium_context(false, "Document", "", "Qt"));
    assert!(chromium_context(true, "Button", "", ""));
    assert!(!outside_chromium(true, rect(-110, 30, 20, 20), client));
    assert!(outside_chromium(true, rect(100, 30, 20, 20), client));
    assert!(outside_chromium(true, rect(0, 120, 20, 20), client));
    assert!(outside_chromium(true, Rect::default(), client));
    assert!(!outside_chromium(false, Rect::default(), client));
    assert!(!outside_chromium(true, Rect::default(), None));
    assert_eq!(omitted_line(0), "");
    assert!(omitted_line(930).contains("930 elements"));
    assert!(omitted_line(930).contains("scrolling reveals"));
}
#[test]
fn compact_attributes_preserve_actionable_state() {
    let mut n = node("Button", "Play", &["Invoke", "DoDefaultAction"]);
    n.value = Some(String::new());
    n.settable = true;
    assert_eq!(n.line(1, 0), "[1] Button title=\"Play\"");
    assert_eq!(n.actions, ["Invoke", "DoDefaultAction"]); // display doesn't mutate capabilities
    n.role = "Hyperlink".into();
    n.value = Some("https://fixture.invalid/".into());
    assert!(!n.line(1, 0).contains("settable"));
    assert!(n.line(1, 0).contains("value="));
    n.role = "Button".into();
    n.actions.push("Expand".into());
    assert!(n
        .line(1, 0)
        .contains("actions=Invoke,DoDefaultAction,Expand"));
    n.role = "Custom".into();
    n.actions = vec!["Invoke".into()];
    assert!(n.line(1, 0).contains("actions=Invoke"));
    n.role = "Edit".into();
    n.actions.clear();
    n.focused = true;
    n.enabled = false;
    assert!(n.line(1, 0).contains("settable focused"));
    assert!(n.line(1, 0).contains("disabled"));
    n.value = Some("中文 value".into());
    assert!(n.line(1, 0).contains("value=\"中文 value\""));
    n.role = "Slider".into();
    n.range = Some((0., 100., 1., 10.));
    assert!(n.line(1, 0).contains("range=(0,100) step=1 page=10"));
    assert!(n.line(1, 0).contains("bounds="));
    n.toggle = Some("mixed".into());
    n.selected = Some(false);
    n.expanded = Some("partial".into());
    assert!(n
        .line(1, 0)
        .contains("toggle=mixed selected=false expanded=partial"));
}

// Frozen pre-change formatter for byte comparisons. Fixture models below contain
// only disposable fixture labels and invented data, never real-app content.
fn old_line(n: &Node, index: usize, depth: usize) -> String {
    use serde_json::json;
    let mut s = format!("{}[{index}] {}", "  ".repeat(depth.min(40)), n.role);
    for (key, value) in [
        ("title", &n.name),
        ("ID", &n.automation_id),
        ("class", &n.class_name),
    ] {
        if !value.is_empty() {
            s += &format!(" {key}={}", json!(value));
        }
    }
    if n.name.is_empty() {
        s += &format!(
            " bounds=({},{},{},{})",
            n.bounds.x, n.bounds.y, n.bounds.width, n.bounds.height
        );
    }
    if let Some(v) = &n.value {
        s += &format!(" value={}", json!(v));
    }
    if !n.enabled {
        s += " disabled";
    }
    if n.offscreen {
        s += " offscreen";
    }
    if n.settable {
        s += " settable";
    }
    if !n.actions.is_empty() {
        s += &format!(" actions={}", n.actions.join(","));
    }
    s
}
fn compare(nodes: &[Node]) -> (usize, usize) {
    (
        nodes
            .iter()
            .enumerate()
            .map(|(i, n)| old_line(n, i + 1, 1).len() + 1)
            .sum(),
        nodes
            .iter()
            .enumerate()
            .map(|(i, n)| n.line(i + 1, 1).len() + 1)
            .sum(),
    )
}
#[test]
fn existing_fixture_control_models_sizes() {
    // Controls defined in tests/fixtures/OpenCUFixture.ps1. Provider wrappers,
    // OS decorations and live UIA properties require device acceptance.
    let mut native = vec![
        node("Button", "Fixture counter", &["Invoke", "DoDefaultAction"]),
        node("Edit", "Fixture notes", &[]),
        node(
            "CheckBox",
            "Fixture checkbox",
            &["Toggle", "DoDefaultAction"],
        ),
        node("Edit", "[protected]", &[]),
        node("Pane", "", &[]),
        node("Slider", "Fixture slider", &[]),
        node("Pane", "Fixture scroll area", &[]),
        node("Text", "Fixture scroll content", &[]),
    ];
    native[1].value = Some(String::new());
    native[1].settable = true;
    native[2].toggle = Some("off".into());
    native[5].value = Some("0".into());
    native[5].settable = true;
    native[5].range = Some((0., 100., 1., 5.));
    // Local HTML in scripts/verify-gui-win.mjs (browser chrome is not modeled).
    let mut chrome = vec![
        node("Text", "OpenCU Chrome page text", &[]),
        node("Text", "这是一次本地页面验收", &[]),
        node("Hyperlink", "Fixture test link", &["Invoke"]),
        node("Edit", "Fixture web notes", &[]),
        node("Edit", "[protected]", &[]),
        node("Text", "Scroll fixture", &[]),
    ];
    chrome[3].value = Some(String::new());
    chrome[3].settable = true;
    let a = compare(&native);
    let b = compare(&chrome);
    println!(
        "fixture control model UTF-8 bytes: native {} -> {}; Chrome {} -> {}",
        a.0, a.1, b.0, b.1
    );
    assert!(a.1 < 1500 && b.1 < 1000); // state + coordinate information can increase small fixtures
}
#[test]
fn equivalent_player_scene_under_eight_kb() {
    let ws = vec![
        window(1, None),
        window(2, Some(1)),
        window(3, None),
        window(4, None),
        window(5, None),
    ];
    let mut old = String::new();
    let mut new=String::from("App: Fixture (pid:100)\nWindow: Fixture player\nWindows input requires foreground focus.\nCapture target: hwnd=1 class=FixtureWindow (foreground candidate, otherwise topmost visible non-tool window).\n");
    let mut indexes = vec![];
    for (wi, w) in ws.iter().enumerate() {
        let count = [43, 37, 930, 2, 3][wi];
        old += &format!("Window: {:?} hwnd={:x}\n", w.title, w.hwnd);
        let tree = owned_by(&ws, w.hwnd, 1);
        new += &window_line(w, wi > 1, !tree);
        for i in 0..count {
            let mut n = node(
                if i % 3 == 0 { "Button" } else { "Text" },
                &format!("Fixture control {i:03}"),
                &["Invoke", "DoDefaultAction"],
            );
            n.class_name = "FixtureWidget".into();
            n.value = Some(String::new());
            n.settable = true;
            old += &(old_line(&n, i + 1, 2) + "\n");
            if tree {
                indexes.push((w.hwnd, i));
                new += &(n.line(indexes.len(), 2) + "\n");
            }
        }
    }
    println!(
        "equivalent player UTF-8 bytes: {} -> {} (including 37 owned controls)",
        old.len(),
        new.len()
    );
    assert!(new.len() < 8000, "{} bytes", new.len());
    assert_eq!(indexes.len(), 80);
    assert_eq!(indexes[43], (2, 0)); // dense indices retain the correct owning window
    assert_eq!(new.matches("Window summary:").count(), 3);
}

#[test]
fn foreground_same_title_overlay_keeps_content_and_owned_controls() {
    let mut overlay = window(1, Some(2));
    overlay.tool = true;
    overlay.class_name = "Qt5QWindowToolSaveBits".into();
    overlay.title = "Fixture app".into();
    let mut content = window(2, None);
    content.title = overlay.title.clone();
    content.class_name = "Qt5QWindowIcon".into();
    let ws = vec![overlay, content];
    assert_eq!(capture_target(&ws, 1), Some(1));
    assert!(owned_by(&ws, 1, 2));
    assert!(covered(ws[1].bounds, &ws[..1])); // coverage does not remove its tree
}
#[test]
fn runtime_identity_reuses_first_index_across_window_roots() {
    let mut ids = ElementIdentities::default();
    let mut retained = vec![];
    for (window, id) in [
        (1, vec![42, 1]),
        (1, vec![42, 2]),
        (2, vec![42, 1]),
        (2, vec![42, 2]),
        (2, vec![42, 3]),
    ] {
        if ids.index(&id).is_none() {
            retained.push(window);
            ids.remember(id, retained.len());
        }
    }
    assert_eq!(retained, vec![1, 1, 2]);
    assert_eq!(ids.index(&[42, 1]), Some(1));
    ids.remember(vec![42, 1], 99);
    assert_eq!(ids.index(&[42, 1]), Some(1));
    assert_eq!(ids.index(&[43, 1]), None); // same label/geometry is not identity
    ids.remember(vec![], 4);
    assert_eq!(ids.index(&[]), None);
    assert!(hidden_windows_line(0).is_empty());
    assert_eq!(hidden_windows_line(17).lines().count(), 1);
    assert!(hidden_windows_line(17).contains("17"));
}

#[test]
fn zero_size_nodes_have_no_index_but_children_and_focus_survive() {
    let mut parent = node("Pane", "Zero container", &[]);
    parent.has_children = true;
    for bounds in [rect(0, 0, 0, 30), rect(0, 0, 30, 0), rect(0, 0, -1, 30)] {
        parent.bounds = bounds;
        assert!(zero_size_omitted(bounds, false));
        assert!(!parent.visible_in_tree());
        parent.focused = true;
        assert!(parent.visible_in_tree());
        parent.focused = false;
    }
    let child = node("Button", "Real child", &["Invoke"]);
    let listed: Vec<_> = [parent, child].into_iter().filter(Node::visible_in_tree).collect();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].line(1, 0), "[1] Button title=\"Real child\"");
    assert_eq!(zero_size_line(0), "");
    assert_eq!(zero_size_line(135).lines().count(), 1);
    assert!(zero_size_line(135).contains("135 elements omitted"));
}

#[test]
fn scope_retains_object_and_falls_back_when_missing_or_detached() {
    let retained = String::from("original UIA object");
    assert_eq!(live_scope(Some(&retained), |_| true), Some(&retained));
    assert_eq!(live_scope(Some(&retained), |_| false), None); // detached / other family
    assert_eq!(live_scope(None::<&String>, |_| panic!("no object to validate")), None);
    assert_eq!(scope_gone_line(true, false), "Scope element is gone; showing the whole window.\n");
    assert_eq!(scope_gone_line(true, true), "");
    assert_eq!(scope_gone_line(false, false), "");
}

#[test]
fn ime_warning_requires_positive_open_and_native_mode_evidence() {
    for (open, mode) in [(None, Some(1)), (Some(1), None), (Some(0), Some(1)), (Some(1), Some(0)), (Some(1), Some(8))] {
        assert_eq!(ime_warning(open, mode), "");
    }
    for mode in [1, 9, 17] {
        let warning = ime_warning(Some(1), Some(mode));
        assert_eq!(warning.lines().count(), 1);
        assert!(warning.contains("press_key"));
        assert!(warning.contains("type_text and paste are unaffected"));
    }
}
