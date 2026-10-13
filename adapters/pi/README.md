# OpenCU for pi

This extension bridges OpenCU's local MCP server to
`@earendil-works/pi-coding-agent` (tested with pi 0.83). Build OpenCU and install
its npm dependencies first, as described in the repository README.

From the OpenCU checkout:

```sh
pi -e ./adapters/pi/opencu.ts
pi -p -e ./adapters/pi/opencu.ts --no-session "Use list_apps to name three running apps."
pi --mode rpc -e ./adapters/pi/opencu.ts --append-system-prompt "You are a voice assistant."
```

On Windows the same commands work; paths may use `\` instead of `/`.
For persistent loading, add the **absolute path to this file in the checkout**
to the `extensions` array in `~/.pi/agent/settings.json`. Keep the file in the
checkout so pi can resolve OpenCU's MCP SDK dependency and default server path.

The extension starts one stdio connection at session startup, discovers all
tools from `tools/list`, and registers their original names, descriptions and
JSON schemas. It appends server instructions to the current system prompt on
each turn, preserving custom prompts and `--append-system-prompt`. Text and
images reach pi as tool content; MCP errors become pi tool errors with their
original content. No extension diagnostics are printed to stdout.

The default command uses pi's Node executable to run `src/server.mjs`, resolved
relative to the extension file, independently of the working directory. Override
it with `OPENCU_COMMAND`, an executable name or path (no surrounding quotes or
embedded arguments). Optional `OPENCU_ARGS` must be a JSON array of strings and
requires `OPENCU_COMMAND`. Without it, an overridden command gets no arguments.
For example, in PowerShell:

```powershell
$env:OPENCU_COMMAND = 'node'
$env:OPENCU_ARGS = '["C:\\Program Files\\OpenCU\\src\\server.mjs"]'
pi --mode rpc -e C:\path\to\opencu\adapters\pi\opencu.ts
```

Calls run sequentially on the same connection so observation indexes and
screenshots remain valid. Session shutdown closes it idempotently. An unexpected
disconnect never causes an automatic reconnect or replay. After `USER_STOPPED`
(physical Escape on Windows), all further OpenCU calls in that session report
the stop; the extension never creates a replacement connection. A person must
explicitly decide to start a new session. Windows input uses the foreground;
this bridge does not change OpenCU's OS permissions or the host's approvals.

Run the GUI-free adapter and existing tests with `npm test`.
