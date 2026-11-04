# Android integration

How to connect your own agent or host to OpenCU on Android. The interface is MCP
over stdio; there is no separate SDK to link. [Android](android.md) is the full
reference, and [Host integration](host-integration.md) covers relaying OpenCU in
general.

## What runs where

The engine is a small jar that runs on the phone as Android's `shell` user, started
through adb. It holds no account and opens no port: stdin and stdout are its only
channel, and closing stdin ends it. The phone needs Android 14 or later and USB or
wireless debugging. Only one phone has been tested (OPPO PGBM10, Android 14).

## Connect from a computer

Register this stdio command with any MCP client:

```sh
opencu android                    # exactly one phone on adb
opencu android --serial SERIAL    # or set ANDROID_SERIAL
```

From a source checkout the command is `bin/opencu android`. The launcher needs
Node.js 22 or later and `adb`; set `ADB` if `adb` is not on `PATH`. It pushes the jar
when the phone does not already have those exact bytes, then starts it. It neither
pairs nor restarts the adb server.

```sh
claude mcp add --scope user opencu-android -- opencu android
```

```json
{ "mcpServers": { "opencu-android": { "command": "opencu", "args": ["android"] } } }
```

`opencu android doctor` prints one JSON object describing the phone: version, SDK,
user, display geometry, lock state, hidden APIs and whether the companion app is
in use.

## Connect from the phone

A host already running on the phone with a way to become `shell` (wireless debugging
paired to itself, or root dropping to `shell`) starts the jar itself and relays the
stream unchanged:

```sh
CLASSPATH=/data/local/tmp/opencu-android-<sha256-16>.jar \
  app_process / dev.opencu.android.Main mcp
```

An ordinary app's identity is refused, and so is root that has not dropped to
`shell`. The wanctl app works this way.

## Talking to it

Messages are newline-delimited JSON-RPC 2.0: `initialize`,
`notifications/initialized`, `tools/list`, `tools/call` and `ping`. Stdout carries
only MCP; diagnostics go to stderr.

Read the tools from `tools/list` and give your agent the `instructions` from
`initialize`. Do not keep your own copy of either: they change between versions.
Tool errors are `isError: true`, start with `CODE: message`, and carry the code in
`_meta["opencu/error"]`. Images are JPEG, and coordinates are in the pixels of the
image.

`agent_desktop({action:"start"})` moves the agent to a virtual display, so the
person can keep using the phone. Without it the agent works on the main display.

## Rules a host must follow

**A person's stop is final until the person says otherwise.** Three volume-down
presses within 1.5 seconds, or Stop in the companion app, latch `USER_STOPPED` on
that connection. It reaches you as a tool error and also, between calls, as:

```json
{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"warning","logger":"opencu","data":{"event":"stop","error":{"code":"USER_STOPPED","message":"…"}}}}
```

Remember it as soon as it arrives. The latch belongs to the connection, so a new
connection starts without it: never reconnect to clear a stop, and do not open
another connection until the person has agreed. Keep reading stdout between calls,
or you can miss the notice.

**Never replay input whose outcome is unknown.** After a timeout, `ACTION_UNCONFIRMED`
or a lost connection, the input may or may not have reached the phone. Call
`get_app_state` again and decide from what it shows. If adb is gone, the launcher's
last stderr line is `DEVICE_UNAVAILABLE: …`, and it says whether anything may have
been sent. Relay that line as the call's error.

**`PERSON_ACTIVE` means ask.** Someone touched the phone during the call. Ask them
before continuing, and read the state again first.

**One connection per agent session.** Element numbers, screenshots and the stop
state belong to the connection. Do not operate one app through two connections, and
close the connection when the session ends: closing stdin stops the engine and
removes its virtual display.

**Allow enough time.** A call's deadline must cover every duration and wait the
agent asked for.

## Companion app (optional)

`opencu-companion.apk` draws a status island, a live preview of the virtual display
and a Stop button. Nothing else depends on it, and the engine reports its stop the
same way as the volume gesture. The engine only attaches an app signed with the
certificate its jar pins, so install the APK that came with your jar. It cannot be
embedded in another app or reused with another signing key.

```sh
adb install -r opencu-companion.apk
```

Then allow it to draw over other apps in Android's settings. See
[Companion app](android.md#companion-app).
