# Third-party test data

`test/data/traces.json` includes the two-finger `getevent -lt` output sample from
Android Open Source Project's [getevent documentation](https://source.android.com/docs/core/interaction/input/getevent),
retrieved 2026-11-01. Android Open Source Project contributors.

The documented timestamps and event payloads are unchanged. A
`/dev/input/event1:` prefix was added to match getevent's all-device output.
This is a published example recording, not a recording from the owner's PGBM10.

AOSP [licenses its documentation and samples](https://source.android.com/license)
under Apache License 2.0; a copy is in `test/data/LICENSE-AOSP.txt`.
Other trace cases are original synthetic edge cases. No Mika or scrcpy code is
included. The runtime jar contains no third-party implementation or test data.
