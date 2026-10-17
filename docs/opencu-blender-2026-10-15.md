# Blender background input boundary — 2026-10-15

The engine refuses background pointer and keyboard input when a window exposes
only its title-bar decorations, using `BACKGROUND_INPUT_UNSUPPORTED` and
recommending explicit `activate_app`. The owner chose this structural boundary
because the engine cannot verify where input lands in such windows. Blender is
a measured example and is foreground-only. Keynote measurements below also
motivate background panel pointer refusal, unknown AX outcomes and an actionable
text-selection error. New live checks belong to the reviewer; none were run in
the afternoon follow-up implementation.

## Source baseline

Reviewed the supplied sparse checkout of tag `v5.2.0`, commit
`fbe6228777e7d9afefcd61a413844e790ae75db7`. The installed application reports
5.2.0; the supplied environment identifies its build as 2026-07-14. Source links
below refer to that tag. No Blender code is copied into or loaded by OpenCU.

## Explanation of the reported observations

1. **Off-screen state with a full screenshot.** OpenCU obtains presentation
   status from WindowServer, but captures a particular window with
   ScreenCaptureKit's `onScreenWindowsOnly: false`. Those are separate facts.
   Blender's [GHOST_WindowCocoa constructor](https://github.com/blender/blender/blob/v5.2.0/intern/ghost/intern/GHOST_WindowCocoa.mm#L413)
   installs a Metal-backed custom content view and initializes its drawing
   context. That is consistent with a retained full-size capture surface; source
   alone does not prove when macOS will retain or refresh it. The live read below
   confirms full-size capture for this instance. The old blanket assertion that
   off-stage windows cannot be captured was too strong. A single screenshot
   does not establish ongoing animation/rendering or input readiness.

2. **Add does not open; title buttons become colored; status hint changes.**
   [GHOST_WindowViewCocoa acceptsFirstMouse](https://github.com/blender/blender/blob/v5.2.0/intern/ghost/intern/GHOST_WindowViewCocoa.hh#L90)
   returns YES, so a blanket first-click rejection is not the explanation.
   [GHOST_SystemCocoa::handleMouseEvent](https://github.com/blender/blender/blob/v5.2.0/intern/ghost/intern/GHOST_SystemCocoa.mm#L1556)
   turns down/up into `GHOST_EventButton`, which carries no position. Only move
   and drag use `event.locationInWindow` to create a cursor-position event.
   [wm_event_add_ghostevent](https://github.com/blender/blender/blob/v5.2.0/source/blender/windowmanager/intern/wm_event_system.cc#L6058)
   initializes each button/key event from the cached event state. OpenCU's click
   path sends down/up without a preceding move; changing their embedded position
   does not establish Blender's cached position.

   More decisively, [ghost_event_proc's button branch](https://github.com/blender/blender/blob/v5.2.0/source/blender/windowmanager/intern/wm_window.cc#L2085)
   refreshes the cursor state whenever `win->active == 0`. The path is
   `wm_window_update_eventstate`, `wm_cursor_position_get`,
   [GHOST_System::getCursorPositionClientRelative](https://github.com/blender/blender/blob/v5.2.0/intern/ghost/intern/GHOST_System.cc#L220),
   then [GHOST_SystemCocoa::getCursorPosition](https://github.com/blender/blender/blob/v5.2.0/intern/ghost/intern/GHOST_SystemCocoa.mm#L836),
   which reads the real `NSEvent.mouseLocation`. Thus even a preceding synthetic
   move can be overwritten at button dispatch while the window is inactive.
   A repeat click does not repair this state.

   Colored title buttons are consistent with OpenCU's synthetic AppKit
   application activation, but do not establish GHOST window activation. Status
   hints are consistent with cached-position handling or a move/redraw;
   [wm_event_do_handlers](https://github.com/blender/blender/blob/v5.2.0/source/blender/windowmanager/intern/wm_event_system.cc#L4337)
   selects area/region using `event->xy`. The original report has no receiver
   trace, so its changed hint does **not** prove motion arrived at the requested
   coordinate (the engine click itself sends no explicit move).

3. **Empty-space click does not deselect; Blender briefly becomes foreground.**
   The same cached/real-cursor mismatch explains why the requested empty-space
   location need not be the location handled by Blender. Window activation is
   not a harmless local state change in this toolkit:
   [BlenderWindowDelegate.windowDidBecomeKey](https://github.com/blender/blender/blob/v5.2.0/intern/ghost/intern/GHOST_WindowCocoa.mm#L68)
   both emits GHOST activation and calls `orderFrontRegardless`.
   [GHOST_WindowCocoa::setOrder](https://github.com/blender/blender/blob/v5.2.0/intern/ghost/intern/GHOST_WindowCocoa.mm#L864)
   explicitly activates the application and orders its window front for a raise.
   [handleApplicationBecomeActiveEvent](https://github.com/blender/blender/blob/v5.2.0/intern/ghost/intern/GHOST_SystemCocoa.mm#L1098)
   also orders dialog windows front. These are concrete raising side effects
   that make synthetic activation unsafe here; the historical observations
   cannot identify which AppKit/Blender raising branch actually fired. OpenCU's
   reactive `FocusGuard` can explain a subsequent restoration, but that does not
   undo the foreground violation or prove the click worked.

4. **All calls report success.** `InputController.click` posts PID-targeted
   CGEvents and returns without a receiver acknowledgment or an application
   effect assertion. `Engine.dispatch` then returns `ok: true`. Successful
   posting and even a new screenshot do not prove that a menu opened or an
   object was deselected. The new pre-send refusal removes that false success
   path for decoration-only background windows.

## Event prerequisites and why no activation workaround is shipped

- **Window state:** `windowDidBecomeKey` and `windowDidResignKey` call
  `handleWindowEvent`; `ghost_event_proc` sets/clears `win->active`. Application
  activation alone updates modifiers and may defer while no GHOST active window
  exists. Neither colored title buttons nor AX's focused-window flag proves this
  internal state. The key callback's ordering side effect conflicts with keeping
  Blender off-stage.
- **Pointer and enter:** the custom view forwards move/drag but has no
  `mouseEntered` handler establishing this state. A correctly associated move
  must be processed after activation's real-cursor refresh and before a button
  or shortcut. Another inactive button refresh defeats that sequence. Merely
  adding enter events or changing down/up coordinates is insufficient.
- **Event window:** mouse handling first resolves `event.window`, falling back
  to GHOST's active window. [handleKeyEvent](https://github.com/blender/blender/blob/v5.2.0/intern/ghost/intern/GHOST_SystemCocoa.mm#L1870)
  requires a matching `event.window` and has no such fallback. PID delivery alone
  is insufficient. OpenCU already associates pointer events with the exact
  window; plain CG keyboard creation depends on AppKit key/responder routing.
- **Timing:** [processEvents](https://github.com/blender/blender/blob/v5.2.0/intern/ghost/intern/GHOST_SystemCocoa.mm#L1040)
  dequeues Cocoa events and normally dispatches through `NSApp sendEvent` before
  GHOST/WM handling. OpenCU's 25 ms focus delay is not an acknowledgment. Longer
  sleeps cannot remove the real-cursor refresh or ordering side effects.
- **Drag:** drag movement can update cached coordinates, but its initial button
  is subject to the same issue. Cursor-grab modes additionally use the real
  mouse position and can warp it in `handleMouseEvent` /
  `GHOST_WindowCocoa::setWindowCursorGrab`. No grab workaround is safe under a
  no-real-cursor-movement requirement.

No safe external event sequence was established under the stated constraints.
This is not a proof that every possible OS SPI could never work. The engine
therefore refuses rather than experimenting with target activation or cursor
movement on an occupied desktop. Foreground Blender editing is not newly
accepted by this change either.

## Implemented rule and compatibility limits

The [contract](independent-engine-contract.md#macos-windows-exposing-only-decorations)
uses the indexed elements, paths and saved role/label/action traits from the
normal filtered observation. Every printed descendant must be an unlabelled
direct AXButton with AXPress (optionally AXZoomWindow), or beneath such a button,
for the window to be opaque. Nested zoom-button groups are decorations. Labelled
empty content, ordinary labelled buttons and a single text field are content.
The root's own title/AXRaise and the separate menu bar do not count as content.
This is a conservative visible-tree rule, not a general proof of input effects;
filtering/truncation and indistinguishable unlabelled content buttons limit it.
The input guards and state warning share the same snapshot classification.

The rule covers physical pointer fallbacks and all three keyboard methods before
focus notifications, held modifiers, events or clipboard writes. Direct AX
operations, including indexed menu-item AXPress, remain available and skip
synthetic focus for these windows. No application/bundle-name check, target
injection, global fallback or automatic replay is introduced.

## Measured results and remaining acceptance

Host: macOS 26.6.2, Apple silicon, Stage Manager enabled. Only a disposable,
untitled Blender scene was observed through this worktree's `bin/opencu`.
Launch requested `open -n -g -a Blender --args --factory-startup
--no-window-focus`, with splash and temporary autosave disabled in memory.
The captured state reports background/off-screen, 1728×1017 window points and a
3456×2034 screenshot. Visual inspection shows the default selected cube, Camera
and Light in the Outliner, Object Mode, and Scale Z 1.000. No input was sent.

The read-only run **failed** its foreground criterion: the 50 ms `lsappinfo front`
monitor detected a value different from its initial sample. A cleanup defect
then attempted to signal an already exited PID and prevented the in-memory
sample series from being written. Transition identities/counts and durations
are unavailable; no claim of uninterrupted background operation is made. The
observation's instance remained after the harness failed and was explicitly
terminated; process inspection confirmed that PID exited. Because instance
identity changed during this run, the captured instance's launch flags cannot
be certified. The capture is evidence of the default untitled scene only.
Further trials were stopped under the owner's safety boundary.

| Requested step | Live result | New policy, pending live confirmation |
| --- | --- | --- |
| Add > Mesh > Cylinder | Not attempted; no cylinder added | Refuse header pointer input |
| Pointer over viewport, Tab twice | Not attempted; no mode transition verified | Refuse background keys |
| Scale Z double-click, 2, Return | Not attempted; value change unverified | Refuse pointer/text/key events |
| Viewport coordinate drag | Not attempted; selection change unverified | Refuse drag before mouse-down |

## Reviewer measurements supplied in the afternoon

These are reviewer observations, not new trials by this implementation job:

- With Blender full-screen on its own Space, a screenshot-coordinate click on
  the Add header menu deselected the cube at the person's actual cursor location.
  Blender became frontmost for **2.04 seconds**. This confirms the source-based
  coordinate and activation explanation; using a different Space is not a safe
  background workaround.
- In Keynote's background Save sheet on its own Space, `OKButton` was disabled.
  Indexed `set_value` changed the filename, AXConfirm on that field did nothing,
  and a coordinate click on the disclosure button returned success with no AX
  changes or visible effect. Coordinate click, drag and scroll into such panels
  now return `BACKGROUND_REMOTE_FOCUS`, recommending `activate_app` or a person.
  Indexed set_value and AXPress remain available; their effect still needs checking.
- In Keynote's theme chooser, AXPress on 创建 returned -25204, yet the chooser
  closed and a document appeared. That action result now becomes non-error
  `outcome: "unknown"`, with the exact notice documented in the contract. The
  engine discards old observations and MCP stops any remaining batch without
  automatic retry or final observation; the caller must read state explicitly.
- Keynote outline rows do not allow setting AXSelectedTextRange. `select_text`
  now returns `TEXT_SELECTION_UNSUPPORTED` with fresh-screenshot/click guidance.

## Reviewer refusal failure and observation-based correction (15:3x)

The reviewer launched Blender through the engine without activation; the
person's app stayed frontmost. Nevertheless `press_key Tab` and `type_text "x"`
returned success on the previous build. The observed window was exactly:

```text
[1] Window title="未命名 - Blender 5.2.0 LTS" focused Secondary Actions: AXRaise
  [2] Button Secondary Actions: AXPress
  [3] Button Secondary Actions: AXPress, AXZoomWindow
    [4] Group kind="group"
      [5] Group kind="group"
  [6] Button Secondary Actions: AXPress
```

Raw AXChildren/decoration-attribute identity matching did not identify this
window. The replacement pure classifier uses the already indexed observation
and the same saved traits used for the listing. This exact six-node tree is now
a native regression fixture, including its title, actions and both nested groups,
and the test verifies `BACKGROUND_INPUT_UNSUPPORTED` in the background. No
additional live test was run for this correction; installed-build acceptance
remains the reviewer's check.

Key named checks in `tests/native-logic.swift`:

- `blender_observed_chrome_tree_is_opaque`
- `ordinary_labelled_button_window_is_not_opaque`
- `empty_but_labelled_content_window_is_not_opaque`
- `single_unlabelled_text_field_window_is_not_opaque`
- `separate_menu_bar_does_not_make_window_content`
- `filtered_wrappers_do_not_change_visible_chrome_classification`

## Verification and reviewer checks

`npm test`: 36 passed. `python3 scripts/test-native.py`: 134 checks passed.
`npm run build` passed with the local signing identity. Native checks cover
filtered window-content classification, foreground/refusal policy, panel point/segment
intersection, -25204 versus other AX errors, unknown-result metadata and
non-settable text selection. MCP transport tests verify the non-error notice,
stopping a batch, no automatic observation/replay and a full explicit next read.
These checks do not establish GUI delivery. No live check was run for this
follow-up; `node scripts/verify-gui.mjs` remains reviewer work.

Use disposable scenes/documents, one connection, fresh observations and this
worktree's `bin/opencu`. Record `lsappinfo front` every 50 ms and flush samples as
collected; every background test must preserve the person's foreground, stage
and real cursor. Stop on an unexpected activation. Perform foreground positive
controls only on a reviewer-authorized idle desktop.

1. Run `node scripts/verify-gui.mjs` for the existing AppKit/remote-panel/windowless
   regression checks.
2. With Blender background/off-stage (also its own full-screen Space), read a
   screenshot and try the Add header coordinate click, a modified/double click,
   viewport drag and scroll, Tab, type_text and paste. Each physical request
   must return `BACKGROUND_INPUT_UNSUPPORTED`; compare screenshots to confirm no
   menu, selection, mode or value change. Check clipboard preservation for paste.
   Use a harmless exposed menu-bar item to confirm indexed menu listing still
   works without synthetic focus. Do not repeat the old unsafe click on an old build.
3. With a disposable Keynote Save sheet and then Open panel in the background,
   read fresh screenshots before click/drag/scroll at the disclosure area. Expect
   `BACKGROUND_REMOTE_FOCUS`, unchanged screenshots and no activation. If the
   app selects the parent document, also check a drag crossing the attached panel.
   Verify indexed filename set_value changes its value and an enabled exposed
   AXPress (for example Cancel) still executes. Check the existing keyboard
   refusal. Explicit foreground operation should retain the previous input path.
4. On Keynote's theme chooser, AXPress 创建 once. If macOS returns -25204, expect
   a non-error unknown-outcome notice, not a failure or completion claim. Read
   state explicitly and verify the new document. With the chooser recreated,
   use a batch whose second action is harmless typing: if the first returns
   unknown, that text must not be sent. Direct-stdio input before the fresh read
   must fail `OBSERVATION_REQUIRED`. If -25204 does not recur, report that this
   live branch was not exercised; do not induce it through repeated creation.
5. On a disposable Keynote outline row, select_text must return
   `TEXT_SELECTION_UNSUPPORTED`, leave selection unchanged, and recommend a
   fresh screenshot and click. In a supported AppKit text field, select_text
   must still select the exact requested UTF-16 range.

## Real-use notes (reviewer, 2026-10-15)

Observations from operating real apps through the MCP server on the reviewer's
Mac (macOS 26.6.2, Stage Manager on). They are recorded here as observations, not
fixture evidence.

- **Keynote on its own Space.** With Keynote full screen on its own Space while
  the person used another app, OpenCU built a five-slide deck through the outline
  view in about 34 calls: coordinate clicks, Chinese typing, Cmd+A, Tab, Shift+Tab,
  Return and menu commands. A 50 ms foreground sampler recorded no change. The
  person performed the final Save. In the Stage Manager strip the same window
  could not become key; most menus were disabled and the canvas was not readable.
- **Blender in the foreground.** A mug model was built with Blender in front by
  switching an area to the Python console (Shift+F4) and pasting `bpy` lines.
  `paste` was reliable where long `type_text` lines dropped characters. Blender's
  shortcuts act on the area under the real pointer, so the person must not move
  the mouse meanwhile.
- **Input method.** With a Chinese pinyin input source selected, the input method
  consumed letter shortcuts; function keys and Escape still worked. Switching to a
  Latin layout fixed it. OpenCU does not detect this.
- **Several windows.** With Blender's main window and a render window open and no
  focused or main Accessibility window, reads and input failed with
  `AMBIGUOUS_WINDOW`. The tools have no parameter for choosing a window.
- A state read once failed with no accessible window and succeeded on the next call.
