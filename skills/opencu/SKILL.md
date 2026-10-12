---
name: opencu
description: Operate macOS application interfaces with the independent local OpenCU MCP engine. Use for observing windows, clicking controls, typing, pasting, scrolling, and verifying desktop UI outcomes.
---

# OpenCU

Use the configured `opencu` MCP tools. They communicate with OpenCU's own local
engine, using macOS Accessibility, CoreGraphics and ScreenCaptureKit. No account,
particular agent identity or official third-party desktop runtime is required.

1. Start with `get_app_state` for the requested app by name, bundle ID or full
   application path. Use `list_apps` when the target is unknown. Resolve ambiguous
   names explicitly.
2. Use element indexes from the returned tree. Request `includeScreenshot: true`
   for visual inspection and coordinate input. Coordinates are pixels in that
   window image, excluding shadows. Stale or out-of-bounds coordinates fail
   before input. A text-only read invalidates an earlier image.
3. Input actions return updated text; coordinate input and dragging also return
   a fresh screenshot. Use `run_actions` for up to 16 known actions followed by
   one final observation. Coordinate input must come first. Do not batch across
   decisions, changing dialogs, permission steps or unknown state.
4. Verify the returned application state before further input. If the final read
   fails after input, inspect state without repeating the action. New read calls
   cannot inherit another connection's element/screenshot observations.
5. Use `activate_app` only when foreground interaction is needed. When the state
   says the window is a Stage Manager thumbnail or not on screen, use
   `activate_app` for screenshots, web pages in Chromium-based apps and window
   commands such as Save. Activation changes focus; inspect the returned window
   and do not compete with user activity.

`get_app_state`, `activate_app` and `run_actions` accept `disableDiff`,
`includeScreenshot`, `waitForText` and `waitTimeoutMs`. Text is the default.
Use `disableDiff: true` when full text is needed; unchanged text can otherwise
return a short notice. Waits check literal expected text with a 5-second default,
up to 15 seconds, and never repeat UI input. A timed-out wait is not readiness.

Click with either `element_index` or both `x` and `y`. `click.key` can hold a
modifier such as `Shift`; `click.duration` and `press_key.duration` hold for
0–30 seconds. `press_key` supports common key/chord names including `Return`,
`Escape`, `Tab`, `super+a`, `Control_L+a` and arrow keys.

For menus, click the menu bar item, then the listed item; click a submenu first to
list its items. Menus are listed without being displayed, and a listed command has
run when the click returns. Disabled items are marked and refused.

Prefer `paste` for Unicode and multiline content. Formats are `text`, `md` and
`html`. The engine restores its previous clipboard snapshot unless another app
changed the clipboard meanwhile. Typing newline characters can submit forms.
Verify field focus and resulting values before committing anything.

Use `set_value` only on elements marked settable. Numeric and boolean controls
retain their value type. Use `select_text` on editable text; repeated text needs
`prefix` and/or `suffix`. `selection_type` can be `text`, `cursor_before` or
`cursor_after`. Secondary actions must use an exact name exposed by the tree.

Follow the user's task authorization and the calling agent's approval policy.
The engine has no agent-brand allowlist and does not grant additional task
permissions. macOS Accessibility and Screen Recording are still required; on
permission errors ask the user to run `opencu setup` and grant the OS permission.
Do not edit system permission databases or attempt to bypass the lock screen.

For separate edited documents, create and verify the destination before editing
when the source must remain unchanged. Reopen the saved result and verify its
content. Input completion alone is not proof of the task's outcome.
