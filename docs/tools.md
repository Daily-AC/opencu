# Tools

`list_apps`, `get_app_state`, `activate_app`, `click`, `drag`, `press_key`,
`type_text`, `paste`, `scroll`, `set_value`, `select_text`,
`perform_secondary_action`, `run_actions` and `agent_desktop`.

Start with `get_app_state`. It takes a bundle identifier, app name or `.app`
path, launches the app in the background if needed, and returns indexed
Accessibility elements, plus a window PNG with `includeScreenshot: true`. Input
tools require a preceding observation of the same app and return the updated
state. Coordinates refer to the latest screenshot. `run_actions` runs up to 16
known actions and returns one final state. `activate_app` brings the target to
the front when a step needs it.

On Windows, zero-size elements are omitted unless focused, while their children
remain traversable. Pass `scope: <element index>` on a read, input tool or batch
to return only that retained subtree, numbered from `[1]`; a missing root falls
back to the whole window with a notice. `scope` is Windows-only for now.
`waitForText` searches numbered element lines, excluding headers and summaries.
Both platforms accept `{"method":"wait","ms":1500}` inside `run_actions`
(1–15000 ms, no input). Coordinates must precede every other action, including
wait. Windows `press_key` defaults to a 50 ms hold and state warns when an open
native IME may consume letter keys. v0.3.3 passed 40 fixture checks, including
the six new compact-state and wait cases, in three consecutive runs on a fresh
Windows 11 VM; a host-injected mouse move during a batch wait returned
`PERSON_ACTIVE` ([evidence](../evidence/opencu-windows-gui-2026-10-20-v0.3.3.json)).
On a public chess site in an Edge app window, a read dropped from an estimated
33,000 characters (the omitted zero-size lines added back) to 19,900, and to
13,000 when scoped to the page document.

Errors begin with a stable code that the agent sees, for example
`STOPPED_BY_PERSON:`; the same code is in `_meta["opencu/error"]`. The full
behavior is in the [engine contract](independent-engine-contract.md).
