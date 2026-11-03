# 0006: An optional Android companion app for status, preview and Stop

Date: 2026-11-03. Status: accepted; built and checked on one phone.

## Context

The Android engine ([ADR 0005](0005-android-engine-app-process.md)) is an
`app_process` running as shell. While it works on its agent display, the person's
own screen shows nothing of it: no sign that an agent is working, no way to see
what it does, and the only stop is three volume-down presses. macOS and Windows
have a watch-only preview and a Stop button.

A shell process cannot provide that itself. Shell can post a notification, but
on the acceptance phone it could neither cancel it nor give it a Stop action
(a button needs an app to receive it). Drawing above other apps needs an app
holding the overlay permission. The person asked for a status display at the top
of the screen and a live view of the background screen, as an app that people
who do not want it need not install.

## Decision

- **A separate, optional app, `dev.opencu.companion`.** It draws a status island
  under the status bar and, on request, a floating preview of the agent display.
  Without it the engine behaves as before.
- **The engine still never listens.** Once per connection it looks the app up and
  calls the app's provider as shell, handing it a Binder; the app answers with its
  own Binder for status. The provider accepts only uid 2000. The engine attaches
  only an app signed with the certificate the build pins: the build signs the app
  with a per-machine key kept outside the checkout and bakes its SHA-256 into the
  jar. Status goes to the app one way, so the engine never waits for it.
- **The app can do two things through the engine's Binder:** attach or detach a
  preview surface while the agent display runs, and stop the connection as the
  person. Its Stop latches the same `USER_STOPPED` as the volume gesture and sends
  the same notification, so hosts need no change.
- **The preview is a mirror display.** The engine creates an auto-mirror virtual
  display of its agent display into the app's surface with the hidden
  `DisplayManager.createVirtualDisplay(name, w, h, displayIdToMirror, surface)`
  (Android 14). Composition stays on the GPU; nothing is copied per frame, and the
  preview takes no input.
- **The island takes touches only on the background screen.** When the engine
  works on the main display, the island is drawn at 0.8 opacity with
  `FLAG_NOT_TOUCHABLE`, so taps pass through to the app below (0.8 is the most
  Android allows touches to pass through another app's window). A touchable island
  that grows with its text could take a tap the engine aimed at the app. Touching
  the screen there already pauses the agent. The engine leaves the app's windows
  out of the state it reports, so they are never mistaken for a popup.
- **The island's card does not close on a timer.** It closes when the person taps it
  or outside it, after a stop, and when the agent moves to the main display. A card
  that closed after a few idle seconds let a tap meant for it land on the app below
  (seen on the device).
- **Typed text is shown only for a known, non-password field.** Otherwise the island
  shows the number of characters.

## Rejected

- A shell notification with Stop: no cancel and no action from shell on the
  acceptance phone (probe of 2026-11-01).
- An engine listener the app connects to: any app could then reach the engine.
- Copying ImageReader frames into the app's surface: works, but costs CPU per
  frame; the mirror display does the same on the GPU.
- Granting the overlay permission from adb: ColorOS removes
  `MANAGE_APP_OPS_MODES` from shell, so the person turns it on in Settings once.

## Consequences

- The app adds a signing key to look after. A rebuilt key needs the app
  reinstalled (Android refuses an update signed differently), and a jar only
  attaches the app built with it.
- An OEM may freeze or end the app's process; the engine attaches again on its next
  call at most every five seconds.
- Main-display screenshots include the island.
- Touches under the island look obscured to the app below; views that filter
  obscured touches ignore taps right under it.
